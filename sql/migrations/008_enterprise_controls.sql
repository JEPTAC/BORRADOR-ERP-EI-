-- ERP Supply Enterprise V10
-- Migration 008: enterprise stage gates, mandatory checklists, assignment pools and domain controls.

begin;

create table if not exists erp_supply.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  po_number text not null,
  supplier_name text not null,
  status text not null default 'ISSUED' check (status in ('DRAFT','ISSUED','CONFIRMED','PARTIAL','RECEIVED','CANCELLED')),
  total_amount numeric(18,2),
  currency text not null default 'COP',
  expected_at timestamptz,
  drive_file_id uuid references erp_supply.drive_files(id),
  created_by uuid not null references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id,po_number)
);

create table if not exists erp_supply.financial_validations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  validation_type text not null check (validation_type in ('CARTERA','CAJA')),
  decision text not null check (decision in ('APPROVED','REJECTED','PENDING')),
  amount numeric(18,2),
  reference text,
  notes text not null,
  evidence_file_id uuid references erp_supply.drive_files(id),
  created_by uuid not null references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_financial_order_type on erp_supply.financial_validations(order_id,validation_type,created_at desc);

create table if not exists erp_supply.checklist_templates (
  step_code text not null references erp_supply.workflow_steps(code) on delete cascade,
  item_code text not null,
  label text not null,
  required boolean not null default true,
  sort_order integer not null default 100,
  active boolean not null default true,
  primary key(step_code,item_code)
);

create table if not exists erp_supply.task_checklist (
  task_id uuid not null references erp_supply.order_tasks(id) on delete cascade,
  item_code text not null,
  label text not null,
  required boolean not null default true,
  sort_order integer not null default 100,
  completed boolean not null default false,
  completed_by uuid references erp_supply.profiles(id),
  completed_at timestamptz,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  primary key(task_id,item_code)
);

insert into erp_supply.checklist_templates(step_code,item_code,label,required,sort_order) values
  ('CARTERA','CLIENT_DATA','Datos del cliente y condición comercial verificados',true,10),
  ('CARTERA','CREDIT_STATUS','Cupo, mora y condición de crédito validados',true,20),
  ('CAJA','PAYMENT_REFERENCE','Referencia y valor del pago verificados',true,10),
  ('CAJA','PAYMENT_SUPPORT','Soporte de pago registrado',true,20),
  ('COMPRAS','SUPPLIER','Proveedor y disponibilidad confirmados',true,10),
  ('COMPRAS','PURCHASE_ORDER','Orden de compra registrada',true,20),
  ('RECEPCION_MERCANCIA','COUNT','Cantidades recibidas verificadas',true,10),
  ('RECEPCION_MERCANCIA','QUALITY','Inspección de calidad registrada',true,20),
  ('RECEPCION_MERCANCIA','LOCATION','Ubicación y lote asignados',true,30),
  ('RECEPCION_PEDIDO','DOCUMENTS','Documentación comercial revisada',true,10),
  ('RECEPCION_PEDIDO','ASSIGNMENT','Pedido asignado a la cola operativa',true,20),
  ('ALISTAMIENTO','ITEMS','Todos los ítems fueron encontrados y verificados',true,10),
  ('ALISTAMIENTO','QUANTITIES','Cantidades y referencias coinciden con el pedido',true,20),
  ('ALISTAMIENTO','PACKAGING','Empaque, identificación y protección completados',true,30),
  ('CORTE','MEASUREMENTS','Medidas solicitadas verificadas',true,10),
  ('CORTE','CUT_RECORD','Consumo, longitud real y desperdicio registrados',true,20),
  ('CORTE','IDENTIFICATION','Material cortado identificado y ubicado',true,30),
  ('FACTURACION','INVOICE','Factura registrada y asociada al pedido',true,10),
  ('FACTURACION','COMMERCIAL_MATCH','Valores, cliente e ítems coinciden con la orden',true,20),
  ('CLIENT_POINT','DELIVERY_EVIDENCE','Evidencia y receptor registrados',true,10),
  ('CLIENT_PICKUP','DELIVERY_EVIDENCE','Evidencia y receptor registrados',true,10),
  ('LOCAL_DISPATCH','DELIVERY_EVIDENCE','Evidencia, transportador y receptor registrados',true,10),
  ('NATIONAL_DISPATCH','DELIVERY_EVIDENCE','Guía, transportadora y evidencia registradas',true,10),
  ('CLOSURE','DOCUMENTS_COMPLETE','Expediente documental completo',true,10),
  ('CLOSURE','DELIVERY_CONFIRMED','Entrega confirmada y sin pendientes',true,20)
on conflict(step_code,item_code) do update set label=excluded.label,required=excluded.required,sort_order=excluded.sort_order,active=true;

-- Replace task creation so every task is born with its controlled checklist.
create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_assignment record; v_task erp_supply.order_tasks;
begin
  select * into v_assignment from erp_supply.resolve_assignment(p_order.organization_id,p_step,p_order.delivery_route_code,p_order.order_type_code);
  insert into erp_supply.order_tasks(order_id,step_code,sequence_no,queue_code,status,assigned_profile_id,assigned_role_code,assigned_at)
  select p_order.id,p_step,p_sequence,s.queue_code,
    case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_assignment.profile_id,v_assignment.role_code,
    case when v_assignment.profile_id is null then null else now() end
  from erp_supply.workflow_steps s where s.code=p_step
  returning * into v_task;

  insert into erp_supply.task_checklist(task_id,item_code,label,required,sort_order)
  select v_task.id,t.item_code,t.label,t.required,t.sort_order
  from erp_supply.checklist_templates t
  where t.step_code=p_step and t.active
  on conflict(task_id,item_code) do nothing;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_assignment.profile_id,
      current_role_code=v_assignment.role_code,
      version=version+1
  where id=p_order.id;
  return v_task;
end;
$$;

create or replace function erp_supply.validate_task_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_order erp_supply.orders%rowtype; v_missing integer;
begin
  if new.status<>'COMPLETED' or old.status='COMPLETED' then return new; end if;
  select * into v_order from erp_supply.orders where id=new.order_id;
  if v_order.is_test then return new; end if;

  select count(*) into v_missing from erp_supply.task_checklist
  where task_id=new.id and required and not completed;
  if v_missing>0 then raise exception 'No puede finalizar: quedan % controles obligatorios sin completar',v_missing; end if;

  case new.step_code
    when 'CARTERA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CARTERA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Cartera';
      end if;
    when 'CAJA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CAJA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Caja';
      end if;
    when 'COMPRAS' then
      if not exists(select 1 from erp_supply.purchase_orders where order_id=v_order.id and status in('ISSUED','CONFIRMED','PARTIAL','RECEIVED')) then
        raise exception 'Debe registrar una orden de compra válida';
      end if;
    when 'RECEPCION_MERCANCIA' then
      if not exists(select 1 from erp_supply.receipts where order_id=v_order.id and status in('PARTIAL','CONFORMING','CLOSED')) then
        raise exception 'Debe registrar la recepción física y su resultado de calidad';
      end if;
    when 'CORTE' then
      if v_order.requires_cut and not exists(select 1 from erp_supply.cut_jobs where order_id=v_order.id and status='COMPLETED') then
        raise exception 'Debe registrar al menos un corte completado';
      end if;
    when 'FACTURACION' then
      if not exists(select 1 from erp_supply.invoices where order_id=v_order.id and status='REGISTERED') then
        raise exception 'Debe registrar la factura antes de liberar el pedido';
      end if;
    when 'CLIENT_POINT' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'CLIENT_PICKUP' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'LOCAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'NATIONAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega nacional'; end if;
    when 'CLOSURE' then
      if not exists(select 1 from erp_supply.invoices where order_id=v_order.id) then raise exception 'El pedido no tiene factura registrada'; end if;
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'El pedido no tiene entrega confirmada'; end if;
    else null;
  end case;
  return new;
end;
$$;

drop trigger if exists trg_validate_task_completion on erp_supply.order_tasks;
create trigger trg_validate_task_completion before update of status on erp_supply.order_tasks
for each row execute function erp_supply.validate_task_completion();

create or replace function public.erp_x_assignment_pool(p_step_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) from (
    select distinct p.id,p.display_name name,p.email,array_agg(distinct pr.role_code) roles
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=p_step_code and sr.can_view
    where p.organization_id=v_org and p.active
    group by p.id
  ) x);
end;
$$;

create or replace function public.erp_x_update_checklist(p_task_id uuid,p_item_code text,p_completed boolean,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_task erp_supply.order_tasks%rowtype;v_item erp_supply.task_checklist%rowtype;
begin
  select * into v_task from erp_supply.order_tasks where id=p_task_id;
  if not found or not erp_supply.can_view_order(v_task.order_id) then raise exception 'Tarea no disponible' using errcode='42501'; end if;
  if not (erp_supply.actor_can(v_actor,v_task.step_code,'START',v_task.assigned_profile_id) or erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'No autorizado para actualizar esta lista' using errcode='42501';
  end if;
  update erp_supply.task_checklist set completed=p_completed,completed_by=case when p_completed then v_actor else null end,
    completed_at=case when p_completed then now() else null end,note=nullif(trim(p_note),'')
  where task_id=p_task_id and item_code=p_item_code returning * into v_item;
  if not found then raise exception 'Control de lista no encontrado'; end if;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  select o.organization_id,o.id,v_task.id,'CHECKLIST_UPDATED','CHECKLIST',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('itemCode',p_item_code,'completed',p_completed,'note',p_note)
  from erp_supply.orders o where o.id=v_task.order_id;
  return jsonb_build_object('success',true,'item',to_jsonb(v_item));
end;
$$;

create or replace function public.erp_x_save_financial_validation(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_row erp_supply.financial_validations%rowtype;v_type text:=upper(p_payload->>'validationType');
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_type not in('CARTERA','CAJA') or v_order.current_step_code<>v_type then raise exception 'La validación no corresponde a la etapa actual'; end if;
  if not (erp_supply.can_access_module(lower(v_type),'update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
  insert into erp_supply.financial_validations(order_id,validation_type,decision,amount,reference,notes,evidence_file_id,created_by,metadata)
  values(p_order_id,v_type,upper(coalesce(p_payload->>'decision','APPROVED')),nullif(p_payload->>'amount','')::numeric,p_payload->>'reference',coalesce(nullif(trim(p_payload->>'notes'),''),'Validación registrada'),nullif(p_payload->>'evidenceFileId','')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_row;
  return jsonb_build_object('success',true,'validation',to_jsonb(v_row));
end;
$$;

create or replace function public.erp_x_save_purchase_order(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_po erp_supply.purchase_orders%rowtype;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'COMPRAS' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Compras'; end if;
  if not (erp_supply.can_access_module('purchasing','create') or erp_supply.can_access_module('purchasing','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
  insert into erp_supply.purchase_orders(order_id,po_number,supplier_name,status,total_amount,currency,expected_at,drive_file_id,created_by,metadata)
  values(p_order_id,p_payload->>'poNumber',p_payload->>'supplierName',upper(coalesce(p_payload->>'status','ISSUED')),nullif(p_payload->>'totalAmount','')::numeric,coalesce(p_payload->>'currency','COP'),nullif(p_payload->>'expectedAt','')::timestamptz,nullif(p_payload->>'driveFileRecordId','')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  on conflict(order_id,po_number) do update set supplier_name=excluded.supplier_name,status=excluded.status,total_amount=excluded.total_amount,currency=excluded.currency,expected_at=excluded.expected_at,drive_file_id=coalesce(excluded.drive_file_id,erp_supply.purchase_orders.drive_file_id),metadata=erp_supply.purchase_orders.metadata||excluded.metadata,updated_at=now()
  returning * into v_po;
  return jsonb_build_object('success',true,'purchaseOrder',to_jsonb(v_po));
end;
$$;

create or replace function public.erp_x_inventory_lots(p_item_id uuid default null,p_search text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('inventory','read') and not erp_supply.can_access_module('cutting','read') and not erp_supply.has_role('super_admin') then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.description,x.location,x.lot_number),'[]'::jsonb) from (
    select l.id,l.inventory_item_id "itemId",i.sku,i.reference,i.description,i.unit,l.lot_number "lotNumber",l.serial_number "serialNumber",l.location,l.quantity_available "available",l.quantity_reserved "reserved",l.quantity_blocked "blocked",l.expires_at "expiresAt"
    from erp_supply.inventory_lots l join erp_supply.inventory_items i on i.id=l.inventory_item_id
    where i.organization_id=v_org and i.active and l.quantity_available>0
      and (p_item_id is null or i.id=p_item_id)
      and (p_search is null or p_search='' or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')||' '||coalesce(l.lot_number,'')||' '||l.location) like '%'||lower(p_search)||'%')
  ) x);
end;
$$;

-- Harden the public action gateway: every mutation requires visible order and explicit action permission.
create or replace function public.erp_x_execute_action(p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,p_expected_version integer default null,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_action text:=upper(trim(coalesce(p_action_code,'')));v_type text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;
  if v_action='NO_DELIVERY' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then raise exception 'No autorizado para registrar no entrega' using errcode='42501'; end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then raise exception 'No autorizado para reprogramar' using errcode='42501'; end if;
  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(p_payload->>'requestType','')));
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then raise exception 'Tipo de solicitud inválido'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if v_type='PRIORITY' and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
    if v_type='ROUTE_CHANGE' and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then raise exception 'Ruta inválida'; end if;
  end if;
  return erp_supply.execute_action_internal(p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

-- Rich action catalog, including assignment and domain prerequisites.
create or replace function public.erp_x_get_actions(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_actions jsonb:='[]';v_domains jsonb:='[]';v_can_override boolean;v_latest_delivery text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1;
  select status into v_latest_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1;
  v_can_override:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia');
  if v_order.status not in('CLOSED','CANCELLED') then
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'CLAIM',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLAIM','label','Tomar tarea','kind','primary')); end if;
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'START',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','START','label','Iniciar trabajo','kind','primary','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'COMPLETE',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE','label','Finalizar etapa','kind','success','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','WAIT','label','Poner en espera','kind','warning','requires',jsonb_build_array('reason'))); end if;
    if v_task.status in('WAITING','BLOCKED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','RESUME','label','Reanudar','kind','primary')); end if;
    if erp_supply.actor_can(v_actor,v_order.current_step_code,'ASSIGN',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','ASSIGN','label','Asignar responsable','kind','secondary','requires',jsonb_build_array('profileId'))); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and v_task.status in('ASSIGNED','IN_PROGRESS') and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','NO_DELIVERY','label','Registrar no entrega','kind','danger','requires',jsonb_build_array('reason'))); end if;
    if v_task.status='WAITING' and v_latest_delivery='NOT_DELIVERED' and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REPROGRAM','label','Reprogramar entrega','kind','warning','requires',jsonb_build_array('scheduledAt'))); end if;
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMMENT','label','Agregar comentario','kind','secondary','requires',jsonb_build_array('body')));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REQUEST_APPROVAL','label','Solicitar aprobación','kind','secondary','requires',jsonb_build_array('requestType','reason')));

    if v_order.current_step_code in('CARTERA','CAJA') and (erp_supply.can_access_module(lower(v_order.current_step_code),'update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FINANCIAL','label','Registrar validación financiera')); end if;
    if v_order.current_step_code='COMPRAS' and (erp_supply.can_access_module('purchasing','create') or erp_supply.can_access_module('purchasing','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','PURCHASE','label','Registrar orden de compra')); end if;
    if v_order.current_step_code='RECEPCION_MERCANCIA' and (erp_supply.can_access_module('receiving','create') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','RECEIPT','label','Registrar recepción'),jsonb_build_object('code','STICKERS','label','Imprimir stickers')); end if;
    if v_order.current_step_code='CORTE' and (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CUT','label','Registrar corte')); end if;
    if v_order.current_step_code='FACTURACION' and (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','INVOICE','label','Registrar factura')); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','DELIVERY','label','Registrar despacho o entrega')); end if;
    if exists(select 1 from erp_supply.task_checklist where task_id=v_task.id) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CHECKLIST','label','Lista de verificación')); end if;
    v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FILE','label','Subir evidencia'));
  end if;
  return jsonb_build_object('orderId',v_order.id,'version',v_order.version,'status',v_order.status,'currentStep',v_order.current_step_code,'taskId',v_task.id,'taskStatus',v_task.status,'canOverride',v_can_override,'actions',v_actions,'domainActions',v_domains);
end;
$$;

-- Rich detail, now including enterprise controls.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_order erp_supply.orders%rowtype;
begin
  erp_supply.require_profile();
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb) from erp_supply.order_items i where i.order_id=p_order_id),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

-- Secure optional UUID handling and order visibility for Drive metadata.
create or replace function public.erp_x_register_drive_file(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_file erp_supply.drive_files%rowtype;v_order_id uuid:=nullif(p_payload->>'orderId','')::uuid;v_task_id uuid:=nullif(p_payload->>'taskId','')::uuid;
begin
  if v_order_id is not null and not erp_supply.can_view_order(v_order_id) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if nullif(trim(p_payload->>'driveFileId'),'') is null or nullif(trim(p_payload->>'fileName'),'') is null then raise exception 'Identificador y nombre de archivo requeridos'; end if;
  insert into erp_supply.drive_files(organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,web_view_link,web_content_link,size_bytes,uploaded_by,metadata)
  values(v_org,v_order_id,v_task_id,coalesce(p_payload->>'category','EVIDENCE'),p_payload->>'driveFileId',p_payload->>'fileName',p_payload->>'mimeType',p_payload->>'webViewLink',p_payload->>'webContentLink',nullif(p_payload->>'sizeBytes','')::bigint,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_file;
  return jsonb_build_object('success',true,'file',to_jsonb(v_file));
end;
$$;

-- Final RPC security surface.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig); end loop;
end $$;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('grant execute on function %s to authenticated',r.sig); end loop;
end $$;

commit;
