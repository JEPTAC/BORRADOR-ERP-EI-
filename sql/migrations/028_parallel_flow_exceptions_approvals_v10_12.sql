-- ERP EI V10.12
-- Motor transversal de excepciones, aprobaciones, Compras/Recepción paralela y Corte/Alistamiento paralelo.
-- Base requerida: V10.11.9 + migraciones previas aplicadas.

begin;

create table if not exists erp_supply.order_issues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  issue_type text not null check (issue_type in ('NOTE','NOVELTY','REPORT')),
  source_code text,
  title text not null,
  detail text not null,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED','CLOSED')),
  blocking boolean not null default false,
  target_role_code text references erp_supply.roles(code),
  created_by uuid not null references erp_supply.profiles(id),
  resolved_by uuid references erp_supply.profiles(id),
  resolution text,
  resolution_code text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);
create index if not exists idx_order_issues_open on erp_supply.order_issues(organization_id,status,issue_type,created_at);
create index if not exists idx_order_issues_order on erp_supply.order_issues(order_id,created_at desc);

-- Visibilidad especial y acotada: Recepción puede seguir un PVE mientras Compras sigue siendo la tarea principal.
create or replace function erp_supply.can_view_order_or_reception_shadow(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth
as $$
  select erp_supply.can_view_order(p_order_id) or exists(
    select 1 from erp_supply.orders o
    where o.id=p_order_id
      and o.organization_id=erp_supply.current_org_id()
      and o.order_type_code='PVE'
      and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')
      and erp_supply.has_role('coordinador_logistico')
  )
$$;

-- Permite varias aprobaciones pendientes del mismo tipo si corresponden a excepciones distintas.
drop index if exists erp_supply.uq_pending_approval_type;
create unique index if not exists uq_pending_approval_exception
on erp_supply.approval_requests(order_id,request_type,(coalesce(request_payload->>'exceptionCode','')))
where status='PENDING';

-- Gate transaccional común: una incidencia bloqueante impide retomar o avanzar el flujo.
create or replace function public.erp_x_execute_action(
  p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,p_idempotency_key text default null
)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_action text:=upper(trim(coalesce(p_action_code,'')));
  v_type text;
  v_assigned text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order_or_reception_shadow(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;

  if v_action in('CLAIM','START','RESUME','COMPLETE') and exists(
    select 1 from erp_supply.order_issues i where i.order_id=p_order_id and i.blocking and i.status='OPEN'
  ) then
    raise exception 'El pedido está en espera por una novedad o reporte. Debes solucionar y cerrar la gestión antes de continuar.';
  end if;

  if v_action='NO_DELIVERY' and not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then
    raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501';
  end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
    raise exception 'No autorizado para reprogramar' using errcode='42501';
  end if;
  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(p_payload->>'requestType','')));
    v_assigned:=coalesce(nullif(trim(p_payload->>'assignedRole'),''),'jefe_logistica');
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then raise exception 'Tipo de solicitud inválido'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if v_assigned not in('auditoria','gerencia','jefe_logistica') then raise exception 'La aprobación debe dirigirse a Auditoría, Gerencia o Jefatura Logística'; end if;
    if v_type='PRIORITY' and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
    if v_type='ROUTE_CHANGE' and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then raise exception 'Ruta inválida'; end if;
  end if;
  return erp_supply.execute_action_internal(p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,p_expected_version,p_idempotency_key);
end;$$;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;

create table if not exists erp_supply.purchase_arrival_state (
  order_id uuid primary key references erp_supply.orders(id) on delete cascade,
  organization_id uuid not null references erp_supply.organizations(id),
  status text not null check (status in ('WAITING','ARRIVED')),
  marked_by uuid not null references erp_supply.profiles(id),
  marked_at timestamptz not null default now(),
  arrived_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.picking_prechecks (
  order_item_id uuid primary key references erp_supply.order_items(id) on delete cascade,
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  result text not null check (result in ('FOUND','MISSING')),
  novelty text,
  checked_by uuid not null references erp_supply.profiles(id),
  checked_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb,
  check (result='FOUND' or nullif(trim(novelty),'') is not null)
);
create index if not exists idx_picking_prechecks_order on erp_supply.picking_prechecks(order_id,checked_at);

-- El pedido principal siempre entra a Alistamiento; las líneas de Corte se gestionan en paralelo.
create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case p_current_step
    when 'CARTERA' then 'RECEPCION_PEDIDO'
    when 'CAJA' then 'RECEPCION_PEDIDO'
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'CORTE' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION' else 'FACTURACION' end
    when 'CAJA_FACTURACION' then p_delivery_route
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.sync_parallel_cut_requirements(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_cut_profile uuid;
  v_count integer:=0;
begin
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then return 0; end if;
  v_cut_profile:=erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,cutProfileId}');

  delete from erp_supply.cut_requirements r
  where r.order_id=p_order_id and r.process_status='PENDING'
    and not exists(select 1 from erp_supply.order_items i where i.id=r.order_item_id and i.requires_cut and coalesce(i.metadata->>'receptionActive','true')<>'false');

  insert into erp_supply.cut_requirements(
    organization_id,order_id,order_item_id,task_id,group_key,sku,reference,description,
    unit,units_required,length_each,total_length,assigned_profile_id,metadata
  )
  select v_order.organization_id,v_order.id,i.id,null,
    erp_supply.cut_group_key(i.reference,i.sku,i.description),i.sku,i.reference,i.description,
    'M',i.quantity,i.requested_cut_length,round((i.quantity*i.requested_cut_length)::numeric,4),v_cut_profile,
    jsonb_build_object('lineNumber',i.line_number,'source','PARALLEL_CUT_V10_12')
  from erp_supply.order_items i
  where i.order_id=v_order.id and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.requires_cut and i.requested_cut_length is not null and i.requested_cut_length>0
  on conflict(order_item_id) do update set
    group_key=excluded.group_key,sku=excluded.sku,reference=excluded.reference,description=excluded.description,
    units_required=excluded.units_required,length_each=excluded.length_each,total_length=excluded.total_length,
    assigned_profile_id=coalesce(excluded.assigned_profile_id,erp_supply.cut_requirements.assigned_profile_id),
    metadata=erp_supply.cut_requirements.metadata||excluded.metadata,updated_at=now();
  get diagnostics v_count=row_count;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.12','parallel',true,'syncedAt',now(),'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY')
  )),updated_at=now() where id=p_order_id;
  return v_count;
end;
$$;

create or replace function erp_supply.trg_parallel_cut_sync()
returns trigger language plpgsql security definer set search_path=erp_supply,public as $$
begin
  if new.current_step_code='RECEPCION_PEDIDO' and (
    new.requires_cut is distinct from old.requires_cut or new.metadata#>'{receptionAssignment}' is distinct from old.metadata#>'{receptionAssignment}'
  ) then perform erp_supply.sync_parallel_cut_requirements(new.id); end if;
  return new;
end;
$$;
drop trigger if exists trg_parallel_cut_sync on erp_supply.orders;
create trigger trg_parallel_cut_sync after update of requires_cut,metadata on erp_supply.orders
for each row execute function erp_supply.trg_parallel_cut_sync();

-- Migra pedidos activos que habían quedado con CORTE como etapa principal en V10.10.
-- Se conserva toda la trazabilidad de Corte, pero la tarea principal pasa a Alistamiento.
do $$
declare
  r record;
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_new_task erp_supply.order_tasks%rowtype;
  v_seq integer;
begin
  for r in select id from erp_supply.orders where current_step_code='CORTE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') loop
    select * into v_task from erp_supply.order_tasks where order_id=r.id and step_code='CORTE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
    if found then
      update erp_supply.task_sessions s set ended_at=now(),raw_seconds=greatest(0,extract(epoch from(now()-s.started_at))::bigint),business_seconds=erp_supply.business_seconds_between((select organization_id from erp_supply.orders where id=r.id),s.started_at,now()),note=coalesce(s.note,'')||' · Migrada a Corte paralelo V10.12' where s.task_id=v_task.id and s.ended_at is null;
      update erp_supply.order_tasks set status='CANCELLED',completed_at=now(),result_code='PARALLEL_CUT_MIGRATION',result_detail='Corte continúa como subflujo paralelo; Alistamiento pasa a ser la etapa principal' where id=v_task.id;
    end if;
    select * into v_order from erp_supply.orders where id=r.id for update;
    v_seq:=(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=r.id);
    perform erp_supply.create_task(v_order,'ALISTAMIENTO',v_seq);
    select * into v_new_task from erp_supply.order_tasks where order_id=r.id and step_code='ALISTAMIENTO' and sequence_no=v_seq order by created_at desc limit 1;
    perform erp_supply.sync_parallel_cut_requirements(r.id);
    update erp_supply.orders set
      current_step_code='ALISTAMIENTO',
      current_role_code=v_new_task.assigned_role_code,
      current_assignee_id=v_new_task.assigned_profile_id,
      status=v_new_task.status,
      updated_at=now(),
      version=version+1,
      metadata=metadata||jsonb_build_object('cutFlowMigration',jsonb_build_object('from','CORTE','to','ALISTAMIENTO','at',now(),'version','10.12'))
    where id=r.id;
  end loop;
end;$$;

-- Funciones de Corte ajustadas para consumir cut_requirements aunque el pedido principal esté en Alistamiento.
create or replace function public.erp_x_cutting_groups(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_total bigint;
  v_items jsonb;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar Corte' using errcode='42501';
  end if;
  with eligible as (
    select r.* from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=v_org and r.process_status<>'READY'
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
  ), grouped as (select group_key from eligible group by group_key)
  select count(*) into v_total from grouped;
  with eligible as (
    select r.*,o.order_number,o.client_name,o.priority from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=v_org and r.process_status<>'READY'
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
  ), grouped as (
    select group_key,max(reference) reference,max(sku) sku,max(description) description,
      count(*)::integer item_count,count(distinct order_id)::integer order_count,
      sum(units_required) cut_count,sum(total_length) total_length,min(created_at) oldest_at,
      bool_or(process_status='IN_PROGRESS') in_progress
    from eligible group by group_key order by in_progress desc,oldest_at offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object('groupKey',group_key,'reference',reference,'sku',sku,'description',description,
    'itemCount',item_count,'orderCount',order_count,'cutCount',cut_count,'totalLength',total_length,'oldestAt',oldest_at,'inProgress',in_progress)),'[]'::jsonb)
  into v_items from grouped;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_cutting_group(p_group_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reference text;v_sku text;v_description text;
begin
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then raise exception 'No autorizado para consultar Corte' using errcode='42501'; end if;
  select max(r.reference),max(r.sku),max(r.description) into v_reference,v_sku,v_description
  from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_description is null then raise exception 'El grupo ya no tiene cortes pendientes'; end if;
  return jsonb_build_object(
    'group',jsonb_build_object('groupKey',p_group_key,'reference',v_reference,'sku',v_sku,'description',v_description,
      'itemCount',(select count(*) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'orderCount',(select count(distinct r.order_id) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'cutCount',(select coalesce(sum(r.units_required),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'totalLength',(select coalesce(sum(r.total_length),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor))
    ),
    'items',(select coalesce(jsonb_agg(jsonb_build_object('requirementId',r.id,'orderId',r.order_id,'orderNumber',o.order_number,'clientName',o.client_name,
      'priority',o.priority,'orderItemId',r.order_item_id,'lineNumber',i.line_number,'sku',r.sku,'reference',r.reference,'description',r.description,'unit',r.unit,
      'unitsRequired',r.units_required,'lengthEach',r.length_each,'totalLength',r.total_length,'processStatus',r.process_status,
      'taskStatus',case when r.process_status='IN_PROGRESS' then 'IN_PROGRESS' else 'PENDING' end,'assigneeId',r.assigned_profile_id,'assigneeName',p.display_name
    ) order by o.priority desc,o.order_number,i.line_number),'[]'::jsonb)
      from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
      join erp_supply.order_items i on i.id=r.order_item_id left join erp_supply.profiles p on p.id=r.assigned_profile_id
      where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
        and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
        and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
    'reels',(select coalesce(jsonb_agg(jsonb_build_object('lotId',l.id,'inventoryItemId',ii.id,'lotNumber',l.lot_number,'location',l.location,'quantityAvailable',l.quantity_available,'unit',ii.unit,'updatedAt',ii.updated_at) order by l.quantity_available desc),'[]'::jsonb)
      from erp_supply.inventory_items ii join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
      where ii.organization_id=v_org and ii.active and l.quantity_available>0 and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference) or ii.metadata->>'cutGroupKey'=p_group_key)),
    'recentBatches',(select coalesce(jsonb_agg(to_jsonb(b) order by b.executed_at desc),'[]'::jsonb) from (select * from erp_supply.cut_batches where organization_id=v_org and group_key=p_group_key order by executed_at desc limit 5) b)
  );
end;
$$;

create or replace function public.erp_x_execute_cut_group(p_group_key text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);
  v_needed numeric;
  v_reference text;
  v_sku text;
  v_description text;
  v_inventory_item erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_batch erp_supply.cut_batches%rowtype;
  v_req erp_supply.cut_requirements%rowtype;
  v_job erp_supply.cut_jobs%rowtype;
  v_orders uuid[]:='{}'::uuid[];
  v_order_id uuid;
  v_difference numeric;
  v_count integer:=0;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para ejecutar cortes' using errcode='42501';
  end if;
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if v_reel is null or v_reel<=0 then raise exception 'Indica cuánto tiene el carreto'; end if;
  if v_scrap<0 then raise exception 'La merma no puede ser negativa'; end if;

  select coalesce(sum(r.total_length),0),max(r.reference),max(r.sku),max(r.description)
  into v_needed,v_reference,v_sku,v_description
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
   
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_needed<=0 then raise exception 'El grupo ya no tiene cortes pendientes'; end if;
  if v_reel<v_needed+v_scrap then
    raise exception 'El carreto tiene % y se necesitan % incluyendo la merma',v_reel,v_needed+v_scrap;
  end if;
  if (v_reel-v_needed-v_scrap)>0 and (v_reel-v_needed-v_scrap)<50 and not exists(
    select 1 from erp_supply.approval_requests a
    where a.order_id in (
      select r2.order_id from erp_supply.cut_requirements r2
      where r2.organization_id=v_org and r2.group_key=p_group_key and r2.process_status<>'READY'
    )
      and a.request_type='STOCK_EXCEPTION'
      and upper(coalesce(a.request_payload->>'exceptionCode',''))='LOW_REEL_REMAINDER'
      and a.request_payload->>'groupKey'=p_group_key
      and a.status in('APPROVED','EXECUTED')
  ) then
    raise exception 'APROBACION_REQUERIDA: el remanente quedaría en % m, menor a 50 m. Solicita aprobación antes de ejecutar el corte.', round(v_reel-v_needed-v_scrap,3);
  end if;

  select * into v_inventory_item
  from erp_supply.inventory_items ii
  where ii.organization_id=v_org
    and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference)
      or ii.metadata->>'cutGroupKey'=p_group_key)
  order by (ii.metadata->>'cutGroupKey'=p_group_key) desc limit 1 for update;

  if not found then
    insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,metadata)
    values(v_org,coalesce(v_sku,v_reference,'CUT-'||substr(p_group_key,1,12)),v_reference,v_description,'M','CUT_REEL',jsonb_build_object('cutGroupKey',p_group_key,'source','CUT_FIRST_V10_10'))
    returning * into v_inventory_item;
  else
    update erp_supply.inventory_items set metadata=metadata||jsonb_build_object('cutGroupKey',p_group_key),updated_at=now()
    where id=v_inventory_item.id returning * into v_inventory_item;
  end if;

  if v_lot_id is not null then
    select * into v_lot from erp_supply.inventory_lots
    where id=v_lot_id and inventory_item_id=v_inventory_item.id for update;
    if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia'; end if;
    v_difference:=v_reel-v_lot.quantity_available;
    if abs(v_difference)>0.0001 then
      update erp_supply.inventory_lots set quantity_available=v_reel where id=v_lot.id returning * into v_lot;
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,
        actor_profile_id,reference,metadata
      ) values(
        v_org,v_inventory_item.id,v_lot.id,case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,
        abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',
        jsonb_build_object('previousLength',v_reel-v_difference,'confirmedLength',v_reel,'source','CUT_FIRST_V10_10')
      );
    end if;
  else
    insert into erp_supply.inventory_lots(
      inventory_item_id,lot_number,location,quantity_available,received_at,metadata
    ) values(
      v_inventory_item.id,
      coalesce(nullif(trim(p_payload->>'lotNumber'),''),'CARRETO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS')),
      coalesce(nullif(trim(p_payload->>'location'),''),'CORTE'),v_reel,now(),
      jsonb_build_object('cutGroupKey',p_group_key,'source','CUT_FIRST_V10_10')
    ) returning * into v_lot;
    insert into erp_supply.inventory_movements(
      organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,to_location,
      actor_profile_id,reference,metadata
    ) values(v_org,v_inventory_item.id,v_lot.id,'CUT_REEL_ENTRY',v_reel,'M',v_lot.location,v_actor,v_lot.lot_number,jsonb_build_object('source','CUT_FIRST_V10_10'));
  end if;

  insert into erp_supply.cut_batches(
    organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,
    resolution_code,reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata
  ) values(
    v_org,p_group_key,v_reference,v_description,v_inventory_item.id,v_lot.id,'CUT',
    v_reel,v_needed,v_scrap,v_reel-v_needed-v_scrap,v_actor,
    jsonb_build_object('lotNumber',v_lot.lot_number,'location',v_lot.location,'version','10.10')
  ) returning * into v_batch;

  for v_req in
    select r.*
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
     
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
    order by r.created_at for update of r
  loop
    -- V10.12: Corte es subflujo paralelo; no reclama la tarea principal de Alistamiento.
    insert into erp_supply.cut_jobs(
      order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,
      status,assigned_profile_id,started_at,completed_at,metadata
    ) values(
      v_req.order_id,v_req.order_item_id,v_lot.id,v_req.total_length,v_req.total_length,0,
      'COMPLETED',v_actor,now(),now(),jsonb_build_object(
        'mode','CUT','batchId',v_batch.id,'units',v_req.units_required,'lengthEach',v_req.length_each,'cutFlowVersion','10.10'
      )
    ) returning * into v_job;

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='CUT',collection_status='PENDING',
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set metadata=metadata||jsonb_build_object(
      'cutStatus','READY','cutResolution','CUT','cutRequirementId',v_req.id,
      'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor
    ),updated_at=now() where id=v_req.order_item_id;

    if not (v_req.order_id=any(v_orders)) then v_orders:=array_append(v_orders,v_req.order_id); end if;
    v_count:=v_count+1;
  end loop;

  update erp_supply.inventory_lots
  set quantity_available=v_reel-v_needed-v_scrap,
      metadata=metadata||jsonb_build_object('lastCutBatchId',v_batch.id,'lastCutAt',now())
  where id=v_lot.id;

  insert into erp_supply.inventory_movements(
    organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,
    actor_profile_id,reference,metadata
  ) values(
    v_org,v_inventory_item.id,v_lot.id,'CUT_CONSUMPTION',v_needed+v_scrap,'M',v_lot.location,
    v_actor,v_batch.id::text,jsonb_build_object('requestedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_reel-v_needed-v_scrap,'groupKey',p_group_key)
  );

  foreach v_order_id in array v_orders loop
    perform erp_supply.advance_cut_order_if_ready(v_order_id,v_actor);
  end loop;

  return jsonb_build_object('success',true,'batchId',v_batch.id,'processedItems',v_count,
    'requestedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_reel-v_needed-v_scrap,
    'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number);
end;
$$;

create or replace function public.erp_x_resolve_cut_requirement(
  p_requirement_id uuid,
  p_resolution text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_resolution text:=upper(trim(coalesce(p_resolution,'')));
  v_req erp_supply.cut_requirements%rowtype;
  v_order erp_supply.orders%rowtype;
  v_reason text:=nullif(trim(p_payload->>'reason'),'');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_inventory_item erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_batch erp_supply.cut_batches%rowtype;
  v_job erp_supply.cut_jobs%rowtype;
  v_difference numeric;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para resolver cortes' using errcode='42501';
  end if;
  if v_resolution not in('FULL_REEL','NO_CUT') then raise exception 'Resolución de corte inválida'; end if;

  select r.* into v_req
  from erp_supply.cut_requirements r
  where r.id=p_requirement_id and r.organization_id=v_org and r.process_status<>'READY'
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
  for update of r;
  if not found then raise exception 'El corte ya fue resuelto o no está disponible'; end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id and status not in('CLOSED','CANCELLED') for update;
  if not found then raise exception 'El pedido ya no está activo'; end if;
  if exists(select 1 from erp_supply.order_issues oi where oi.order_id=v_order.id and oi.blocking and oi.status='OPEN') then
    raise exception 'El pedido está detenido por una novedad o reporte pendiente. Resuélvelo antes de continuar Corte.';
  end if;
  -- V10.12: Corte es subflujo paralelo; no reclama la tarea principal de Alistamiento.

  if v_resolution='NO_CUT' then
    if v_reason is null then raise exception 'Explica por qué la referencia no necesita corte'; end if;

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='NO_CUT',collection_status='PENDING',
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
        metadata=metadata||jsonb_build_object('reason',v_reason),updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set requires_cut=false,requested_cut_length=null,
        metadata=metadata||jsonb_build_object(
          'cutStatus','READY','cutResolution','NO_CUT','cutRequirementId',v_req.id,
          'cutReadyAt',now(),'cutReadyBy',v_actor,'cutNoNeedReason',v_reason,
          'originalRequestedCutLength',v_req.length_each
        ),updated_at=now()
    where id=v_req.order_item_id;

    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_req.order_id,v_actor,'NOVELTY','INTERNAL',
      format('Corte corregido: la referencia %s no necesita corte. %s',coalesce(v_req.reference,v_req.sku,v_req.description),v_reason),
      jsonb_build_object('source','CORTE','resolution','NO_CUT','requirementId',v_req.id));
  else
    if v_reel is null or v_reel<=0 then raise exception 'Indica la medida del carreto completo'; end if;
    if abs(v_reel-v_req.total_length)>0.0001 then
      raise exception 'Carreto completo solo aplica cuando la medida del carreto (%) coincide con lo solicitado (%)',v_reel,v_req.total_length;
    end if;

    select * into v_inventory_item from erp_supply.inventory_items ii
    where ii.organization_id=v_org and ((v_req.sku is not null and ii.sku=v_req.sku)
      or (v_req.reference is not null and ii.reference=v_req.reference)
      or ii.metadata->>'cutGroupKey'=v_req.group_key)
    order by (ii.metadata->>'cutGroupKey'=v_req.group_key) desc limit 1 for update;

    if not found then
      insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,metadata)
      values(v_org,coalesce(v_req.sku,v_req.reference,'CUT-'||substr(v_req.group_key,1,12)),v_req.reference,v_req.description,'M','CUT_REEL',jsonb_build_object('cutGroupKey',v_req.group_key,'source','CUT_FIRST_V10_10'))
      returning * into v_inventory_item;
    end if;

    if v_lot_id is not null then
      select * into v_lot from erp_supply.inventory_lots where id=v_lot_id and inventory_item_id=v_inventory_item.id for update;
      if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia'; end if;
      v_difference:=v_reel-v_lot.quantity_available;
      if abs(v_difference)>0.0001 then
        update erp_supply.inventory_lots set quantity_available=v_reel where id=v_lot.id returning * into v_lot;
        insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata)
        values(v_org,v_inventory_item.id,v_lot.id,case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',jsonb_build_object('confirmedLength',v_reel));
      end if;
    else
      insert into erp_supply.inventory_lots(inventory_item_id,lot_number,location,quantity_available,received_at,metadata)
      values(v_inventory_item.id,coalesce(nullif(trim(p_payload->>'lotNumber'),''),'CARRETO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS')),coalesce(nullif(trim(p_payload->>'location'),''),'CORTE'),v_reel,now(),jsonb_build_object('cutGroupKey',v_req.group_key,'source','CUT_FIRST_V10_10'))
      returning * into v_lot;
      insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,to_location,actor_profile_id,reference,metadata)
      values(v_org,v_inventory_item.id,v_lot.id,'CUT_REEL_ENTRY',v_reel,'M',v_lot.location,v_actor,v_lot.lot_number,jsonb_build_object('source','CUT_FIRST_V10_10'));
    end if;

    insert into erp_supply.cut_batches(organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,resolution_code,reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata)
    values(v_org,v_req.group_key,v_req.reference,v_req.description,v_inventory_item.id,v_lot.id,'FULL_REEL',v_reel,v_req.total_length,0,0,v_actor,jsonb_build_object('requirementId',v_req.id,'version','10.10'))
    returning * into v_batch;

    insert into erp_supply.cut_jobs(order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,status,assigned_profile_id,started_at,completed_at,metadata)
    values(v_req.order_id,v_req.order_item_id,v_lot.id,v_req.total_length,v_req.total_length,0,'COMPLETED',v_actor,now(),now(),jsonb_build_object('mode','FULL_REEL','batchId',v_batch.id,'cutFlowVersion','10.10'))
    returning * into v_job;

    update erp_supply.inventory_lots set quantity_available=0,metadata=metadata||jsonb_build_object('issuedCompleteAt',now(),'cutBatchId',v_batch.id) where id=v_lot.id;
    insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,actor_profile_id,reference,metadata)
    values(v_org,v_inventory_item.id,v_lot.id,v_req.order_id,'FULL_REEL_ISSUE',v_req.total_length,'M',v_lot.location,v_actor,v_batch.id::text,jsonb_build_object('requirementId',v_req.id));

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='FULL_REEL',collection_status='PENDING',
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set metadata=metadata||jsonb_build_object(
      'cutStatus','READY','cutResolution','FULL_REEL','cutRequirementId',v_req.id,
      'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor
    ),updated_at=now() where id=v_req.order_item_id;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,v_req.order_id,v_req.task_id,'DOMAIN_RECORD',v_resolution,'CORTE','CORTE',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('requirementId',v_req.id,'reason',v_reason));

  perform erp_supply.advance_cut_order_if_ready(v_req.order_id,v_actor);
  return jsonb_build_object('success',true,'requirementId',v_req.id,'resolution',v_resolution,'orderId',v_req.order_id);
end;
$$;


-- Al terminar Corte ya no se mueve la tarea principal; solo queda lista la recogida.
create or replace function erp_supply.advance_cut_order_if_ready(p_order_id uuid,p_actor uuid)
returns boolean language plpgsql security definer set search_path=erp_supply,public as $$
begin
  if exists(select 1 from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY') then return false; end if;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
    'completedAt',now(),'completedBy',p_actor,'parallel',true,
    'pendingCollection',(select count(*) from erp_supply.cut_requirements where order_id=p_order_id and collection_status='PENDING')
  )),updated_at=now(),version=version+1 where id=p_order_id;
  return found;
end;
$$;

-- Avance parcial de Alistamiento mientras Corte trabaja.
create or replace function public.erp_x_picking_precheck(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth as $$
declare v_org uuid:=erp_supply.current_org_id();begin
  perform erp_supply.require_profile();
  if not exists(select 1 from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  return jsonb_build_object('items',(select coalesce(jsonb_agg(jsonb_build_object(
    'orderItemId',p.order_item_id,'result',p.result,'novelty',p.novelty,'checkedAt',p.checked_at,'checkedBy',pr.display_name
  ) order by p.checked_at),'[]'::jsonb) from erp_supply.picking_prechecks p left join erp_supply.profiles pr on pr.id=p.checked_by where p.order_id=p_order_id));
end;$$;

create or replace function public.erp_x_save_picking_precheck(p_order_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_task erp_supply.order_tasks%rowtype;v_row jsonb;v_item erp_supply.order_items%rowtype;v_id uuid;v_result text;v_novelty text;v_count int:=0;begin
  if not (erp_supply.can_access_module('picking','update') or erp_supply.has_role('aux_logistica') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para guardar Alistamiento' using errcode='42501'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='ALISTAMIENTO' and status='IN_PROGRESS' order by sequence_no desc limit 1;
  if not found then raise exception 'Primero debes tomar el pedido en Alistamiento'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'Pedido asignado a otro auxiliar' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Resultados inválidos'; end if;
  for v_row in select value from jsonb_array_elements(p_items) loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_novelty:=nullif(trim(v_row->>'novelty'),'');
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea no disponible'; end if;
    if v_item.requires_cut and not exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=v_item.id and r.process_status='READY' and r.collection_status='COLLECTED') then raise exception 'La línea % todavía está en Corte',v_item.line_number; end if;
    if v_result not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado'; end if;
    if v_result='MISSING' and v_novelty is null then raise exception 'Explica el faltante de la línea %',v_item.line_number; end if;
    insert into erp_supply.picking_prechecks(order_item_id,organization_id,order_id,task_id,result,novelty,checked_by,metadata)
    values(v_item.id,v_org,p_order_id,v_task.id,v_result,v_novelty,v_actor,jsonb_build_object('lineNumber',v_item.line_number,'source','PARALLEL_PICKING_V10_12'))
    on conflict(order_item_id) do update set result=excluded.result,novelty=excluded.novelty,checked_by=excluded.checked_by,checked_at=now(),task_id=excluded.task_id,metadata=erp_supply.picking_prechecks.metadata||excluded.metadata;
    v_count:=v_count+1;
  end loop;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','PICKING_PRECHECK','ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('items',v_count));
  return jsonb_build_object('success',true,'saved',v_count);
end;$$;

grant execute on function public.erp_x_picking_precheck(uuid) to authenticated;
grant execute on function public.erp_x_save_picking_precheck(uuid,jsonb) to authenticated;

create or replace function erp_supply.trg_clear_picking_prechecks()
returns trigger language plpgsql security definer set search_path=erp_supply,public as $$ begin delete from erp_supply.picking_prechecks where order_id=new.order_id; return new; end; $$;
drop trigger if exists trg_clear_picking_prechecks on erp_supply.picking_rounds;
create trigger trg_clear_picking_prechecks after insert on erp_supply.picking_rounds for each row execute function erp_supply.trg_clear_picking_prechecks();

-- Nota / Novedad / Reporte transversales.
create or replace function public.erp_x_create_order_issue(p_order_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_type text:=upper(trim(coalesce(p_payload->>'type','')));v_title text:=nullif(trim(p_payload->>'title'),'');v_detail text:=nullif(trim(p_payload->>'detail'),'');v_target text:=nullif(trim(p_payload->>'targetRole'),'');v_issue erp_supply.order_issues%rowtype;v_status text;begin
  if v_type not in('NOTE','NOVELTY','REPORT') then raise exception 'Tipo de registro inválido'; end if;
  if v_detail is null then raise exception 'Escribe el detalle'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order_or_reception_shadow(id) for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if v_target is not null and not exists(select 1 from erp_supply.roles where code=v_target and active) then v_target:=null; end if;
  if v_type='REPORT' and v_target is null then v_target:='jefe_logistica'; end if;
  if v_type='NOVELTY' and v_target is null then v_target:=v_order.current_role_code; end if;
  insert into erp_supply.order_issues(organization_id,order_id,task_id,issue_type,source_code,title,detail,status,blocking,target_role_code,created_by,metadata)
  values(v_org,p_order_id,v_task.id,v_type,nullif(trim(p_payload->>'sourceCode'),''),coalesce(v_title,case v_type when 'NOTE' then 'Nota' when 'NOVELTY' then 'Novedad' else 'Reporte' end),v_detail,case when v_type='NOTE' then 'CLOSED' else 'OPEN' end,v_type<>'NOTE',v_target,v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_issue;
  insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
  values(p_order_id,v_actor,v_type,'INTERNAL',v_detail,jsonb_build_object('issueId',v_issue.id,'source','ISSUE_ENGINE_V10_12'));
  if v_type<>'NOTE' and v_task.id is not null then
    update erp_supply.task_sessions s set ended_at=now(),raw_seconds=greatest(0,extract(epoch from(now()-s.started_at))::bigint),business_seconds=erp_supply.business_seconds_between(v_org,s.started_at,now()),note=coalesce(s.note,'')||' · Pausa por '||lower(v_type) where s.task_id=v_task.id and s.ended_at is null;
    v_status:=case when v_type='REPORT' then 'BLOCKED' else 'WAITING' end;
    update erp_supply.order_tasks set status=v_status,result_code=v_type,result_detail=v_detail,blocked_at=case when v_type='REPORT' then now() else blocked_at end where id=v_task.id;
    update erp_supply.orders set status=v_status,metadata=metadata||jsonb_build_object('exceptionState',jsonb_build_object('type',v_type,'label',case when v_type='REPORT' then 'REPORTE' else 'ESPERA_CON_NOVEDAD' end,'issueId',v_issue.id,'openedAt',now())),version=version+1,updated_at=now() where id=p_order_id returning * into v_order;
  end if;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'ISSUE',v_type,v_order.current_step_code,v_order.current_step_code,v_actor,(erp_supply.current_roles())[1],jsonb_build_object('issueId',v_issue.id,'blocking',v_issue.blocking,'targetRole',v_target));
  return jsonb_build_object('success',true,'issue',to_jsonb(v_issue),'orderStatus',v_order.status);
end;$$;

create or replace function public.erp_x_order_issues(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth as $$
begin
  perform erp_supply.require_profile();
  if not exists(select 1 from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order_or_reception_shadow(id)) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  return jsonb_build_object('items',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'type',i.issue_type,'title',i.title,'detail',i.detail,'status',i.status,'blocking',i.blocking,'sourceCode',i.source_code,'targetRole',i.target_role_code,'createdBy',p.display_name,'createdAt',i.created_at,'resolvedBy',rp.display_name,'resolvedAt',i.resolved_at,'resolution',i.resolution,'resolutionCode',i.resolution_code,'metadata',i.metadata) order by i.created_at desc),'[]'::jsonb) from erp_supply.order_issues i join erp_supply.profiles p on p.id=i.created_by left join erp_supply.profiles rp on rp.id=i.resolved_by where i.order_id=p_order_id));
end;$$;

create or replace function public.erp_x_resolve_order_issue(p_issue_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_roles text[]:=erp_supply.current_roles();v_issue erp_supply.order_issues%rowtype;v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_resolution text:=nullif(trim(p_payload->>'resolution'),'');v_code text:=upper(coalesce(nullif(trim(p_payload->>'resolutionCode'),''),'RESOLVED'));v_remaining int;begin
  if v_resolution is null then raise exception 'Describe cómo se solucionó'; end if;
  select * into v_issue from erp_supply.order_issues where id=p_issue_id and organization_id=erp_supply.current_org_id() for update;
  if not found or v_issue.status<>'OPEN' then raise exception 'La gestión ya fue cerrada o no existe'; end if;
  select * into v_order from erp_supply.orders where id=v_issue.order_id for update;
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or v_issue.target_role_code=any(v_roles) or v_order.current_assignee_id=v_actor or (v_issue.source_code='NO_DELIVERY' and erp_supply.can_access_module('shipping','update'))) then raise exception 'No autorizado para cerrar esta gestión' using errcode='42501'; end if;
  update erp_supply.order_issues set status='RESOLVED',resolved_by=v_actor,resolved_at=now(),resolution=v_resolution,resolution_code=v_code where id=v_issue.id returning * into v_issue;
  if v_issue.source_code='NO_DELIVERY' then
    update erp_supply.deliveries set status=case when v_code='RETURN' then 'CANCELLED' when v_code='REPROGRAM' then 'REPROGRAMMED' else 'IN_TRANSIT' end,metadata=metadata||jsonb_build_object('noDeliveryResolvedAt',now(),'noDeliveryResolution',v_resolution),updated_at=now() where id=(select id from erp_supply.deliveries where order_id=v_order.id order by created_at desc limit 1);
    update erp_supply.orders set metadata=(metadata-'deliveryExceptionOpen')||jsonb_build_object('noDeliveryResolvedAt',now(),'noDeliveryResolution',v_resolution) where id=v_order.id;
  end if;
  select count(*) into v_remaining from erp_supply.order_issues where order_id=v_order.id and blocking and status='OPEN';
  if v_remaining=0 then
    select * into v_task from erp_supply.order_tasks where order_id=v_order.id and status in('WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
    if found then update erp_supply.order_tasks set status=case when assigned_profile_id is null then 'QUEUED' else 'ASSIGNED' end,result_code='ISSUE_RESOLVED',result_detail=v_resolution,blocked_at=null where id=v_task.id; end if;
    update erp_supply.orders set status=case when current_assignee_id is null then 'QUEUED' else 'ASSIGNED' end,metadata=metadata-'exceptionState',version=version+1,updated_at=now() where id=v_order.id returning * into v_order;
  end if;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,v_order.id,v_issue.task_id,'ISSUE_RESOLVED',v_issue.issue_type,v_order.current_step_code,v_order.current_step_code,v_actor,(v_roles)[1],jsonb_build_object('issueId',v_issue.id,'resolution',v_resolution,'resolutionCode',v_code));
  return jsonb_build_object('success',true,'issue',to_jsonb(v_issue),'remainingBlocking',v_remaining,'orderStatus',v_order.status);
end;$$;

grant execute on function public.erp_x_create_order_issue(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_order_issues(uuid) to authenticated;
grant execute on function public.erp_x_resolve_order_issue(uuid,jsonb) to authenticated;

-- No entrega se convierte en Reporte bloqueante para Logística.
create or replace function public.erp_x_shipping_report_no_delivery(p_order_id uuid,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_delivery erp_supply.deliveries%rowtype;v_reason text:=nullif(trim(p_payload->>'reason'),'');v_action text:=coalesce(nullif(p_payload->>'requestedAction',''),'REVIEW');v_issue jsonb;begin
  if not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501'; end if;
  if v_reason is null then raise exception 'Motivo de no entrega requerido'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or (not erp_supply.has_role('super_admin') and v_order.seller_profile_id is distinct from v_actor) then raise exception 'Pedido no disponible para este asesor' using errcode='42501'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id and dispatched_at is not null order by created_at desc limit 1 for update;
  if not found then raise exception 'El pedido todavía no figura como enviado'; end if;
  if v_delivery.status='DELIVERED' or v_order.status='CLOSED' then raise exception 'El pedido ya fue finalizado y no admite una no entrega'; end if;
  update erp_supply.deliveries set status='NOT_DELIVERED',no_delivery_reason=v_reason,metadata=metadata||jsonb_build_object('noDeliveryReportedAt',now(),'requestedAction',v_action),updated_at=now() where id=v_delivery.id returning * into v_delivery;
  select public.erp_x_create_order_issue(p_order_id,jsonb_build_object('type','REPORT','title','No entrega reportada','detail',v_reason,'targetRole','jefe_logistica','sourceCode','NO_DELIVERY','metadata',jsonb_build_object('requestedAction',v_action,'deliveryId',v_delivery.id))) into v_issue;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('deliveryExceptionOpen',true,'noDeliveryReason',v_reason,'noDeliveryRequestedAction',v_action,'noDeliveryReportedAt',now()),updated_at=now() where id=p_order_id;
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery),'issue',v_issue);
end;$$;

-- Espera de mercancía PVE visible en Recepción mientras Compras trabaja.
create or replace function erp_supply.finalize_arrived_purchase(p_order_id uuid,p_actor uuid)
returns boolean language plpgsql security definer set search_path=erp_supply,public as $$
declare v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_receipt uuid;v_version int;begin
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found or v_order.current_step_code<>'RECEPCION_MERCANCIA' then return false; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='RECEPCION_MERCANCIA' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found then return false; end if;
  insert into erp_supply.receipts(order_id,receipt_number,purchase_order,supplier_name,status,received_by,received_at,metadata)
  values(p_order_id,'ARR-'||replace(p_order_id::text,'-',''),(select po_number from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),(select supplier_name from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),'CONFORMING',p_actor,now(),jsonb_build_object('source','MERCANCIA_OK_V10_12'))
  on conflict(order_id,receipt_number) do update set status='CONFORMING',received_by=excluded.received_by,received_at=excluded.received_at returning id into v_receipt;
  insert into erp_supply.receipt_lines(receipt_id,order_item_id,sku,description,expected_quantity,received_quantity,accepted_quantity,rejected_quantity,unit,location,quality_status,metadata)
  select v_receipt,i.id,i.sku,i.description,i.quantity,i.quantity,i.quantity,0,i.unit,'RECEPCION','ACCEPTED',jsonb_build_object('source','MERCANCIA_OK_V10_12') from erp_supply.order_items i where i.order_id=p_order_id
  on conflict do nothing;
  update erp_supply.task_checklist set completed=true,completed_by=p_actor,completed_at=now(),note='Mercancía OK confirmada desde Recepción',metadata=metadata||jsonb_build_object('source','MERCANCIA_OK_V10_12') where task_id=v_task.id and required;
  select version into v_version from erp_supply.orders where id=p_order_id;
  perform erp_supply.execute_action_internal(p_order_id,'COMPLETE',jsonb_build_object('resultCode','MERCHANDISE_OK','detail','Mercancía recibida en sede'),p_actor,true,v_version,'ARRIVAL-'||p_order_id::text);
  return true;
end;$$;

create or replace function erp_supply.trg_auto_finalize_arrival()
returns trigger language plpgsql security definer set search_path=erp_supply,public as $$
declare v_actor uuid;begin
  -- Se dispara cuando create_task ya actualizó la etapa principal del pedido.
  if new.current_step_code='RECEPCION_MERCANCIA' and old.current_step_code is distinct from new.current_step_code then
    select marked_by into v_actor from erp_supply.purchase_arrival_state where order_id=new.id and status='ARRIVED';
    if v_actor is not null then perform erp_supply.finalize_arrived_purchase(new.id,v_actor); end if;
  end if;
  return new;
end;$$;
drop trigger if exists trg_auto_finalize_arrival on erp_supply.order_tasks;
drop trigger if exists trg_auto_finalize_arrival_order on erp_supply.orders;
create trigger trg_auto_finalize_arrival_order after update of current_step_code on erp_supply.orders for each row execute function erp_supply.trg_auto_finalize_arrival();

create or replace function public.erp_x_set_purchase_arrival(p_order_id uuid,p_status text)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_status text:=upper(trim(coalesce(p_status,'')));v_row erp_supply.purchase_arrival_state%rowtype;begin
  if not (erp_supply.can_access_module('receiving','update') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para confirmar llegada' using errcode='42501'; end if;
  if v_status not in('WAITING','ARRIVED') then raise exception 'Estado de llegada inválido'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and order_type_code='PVE' and current_step_code in('COMPRAS','RECEPCION_MERCANCIA','RECEPCION_PEDIDO') for update;
  if not found then raise exception 'Este pedido no está disponible para seguimiento de Compras'; end if;
  if exists(select 1 from erp_supply.order_issues oi where oi.order_id=p_order_id and oi.blocking and oi.status='OPEN') then
    raise exception 'El pedido está detenido por una novedad o reporte pendiente. Resuélvelo antes de cambiar la llegada de mercancía.';
  end if;
  insert into erp_supply.purchase_arrival_state(order_id,organization_id,status,marked_by,marked_at,arrived_at,metadata)
  values(p_order_id,v_org,v_status,v_actor,now(),case when v_status='ARRIVED' then now() else null end,jsonb_build_object('source','RECEIVING_PURCHASE_WATCH_V10_12'))
  on conflict(order_id) do update set status=excluded.status,marked_by=excluded.marked_by,marked_at=now(),arrived_at=case when excluded.status='ARRIVED' then now() else erp_supply.purchase_arrival_state.arrived_at end,metadata=erp_supply.purchase_arrival_state.metadata||excluded.metadata returning * into v_row;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('purchaseArrival',jsonb_build_object('status',v_status,'markedAt',now(),'markedBy',v_actor)),updated_at=now(),version=version+1 where id=p_order_id;
  if v_status='ARRIVED' then perform erp_supply.finalize_arrived_purchase(p_order_id,v_actor); end if;
  return jsonb_build_object('success',true,'arrival',to_jsonb(v_row),'currentStep',(select current_step_code from erp_supply.orders where id=p_order_id));
end;$$;
grant execute on function public.erp_x_set_purchase_arrival(uuid,text) to authenticated;

-- Aprobación especializada para remanentes críticos de Corte.
create or replace function public.erp_x_request_cut_remainder_approval(p_group_key text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order_id uuid;v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);v_needed numeric;v_remaining numeric;v_assigned text:=coalesce(nullif(trim(p_payload->>'assignedRole'),''),'jefe_logistica');v_req erp_supply.approval_requests%rowtype;begin
  select min(r.order_id),coalesce(sum(r.total_length),0) into v_order_id,v_needed from erp_supply.cut_requirements r where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY';
  if v_order_id is null then raise exception 'Grupo sin cortes pendientes'; end if;
  if v_reel is null then raise exception 'Indica la medida del carreto'; end if;v_remaining:=v_reel-v_needed-v_scrap;
  if v_remaining>=50 or v_remaining<=0 then raise exception 'La aprobación solo aplica cuando el remanente queda entre 0 y 50 m'; end if;
  if v_assigned not in('auditoria','gerencia','jefe_logistica') then raise exception 'La aprobación debe dirigirse a Auditoría, Gerencia o Jefatura Logística'; end if;
  if exists(select 1 from erp_supply.approval_requests where order_id=v_order_id and request_type='STOCK_EXCEPTION' and status='PENDING' and request_payload->>'groupKey'=p_group_key) then raise exception 'Ya existe una aprobación pendiente para este remanente'; end if;
  insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
  values(v_org,v_order_id,'STOCK_EXCEPTION',v_actor,v_assigned,coalesce(nullif(trim(p_payload->>'reason'),''),format('Autorizar remanente de %s m en Corte',round(v_remaining,3))),jsonb_build_object('exceptionCode','LOW_REEL_REMAINDER','groupKey',p_group_key,'reelLength',v_reel,'requestedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_remaining)) returning * into v_req;
  return jsonb_build_object('success',true,'requestId',v_req.id,'remainingLength',v_remaining);
end;$$;
grant execute on function public.erp_x_request_cut_remainder_approval(text,jsonb) to authenticated;

-- Solo Auditoría, Gerencia, Jefatura Logística y Superadministración deciden aprobaciones.
create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_req erp_supply.approval_requests%rowtype;
  v_order erp_supply.orders%rowtype;
  v_dec text:=upper(trim(coalesce(p_decision,'')));
  v_route text;
  v_old_task erp_supply.order_tasks%rowtype;
  v_next_sequence integer;
  v_final_status text;
  v_before_step text;
  v_before_status text;
  v_now timestamptz:=now();
begin
  select * into v_req from erp_supply.approval_requests
  where id=p_request_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
  if not (
    erp_supply.has_role('auditoria')
    or erp_supply.has_role('gerencia')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'Solo Auditoría, Gerencia, Jefatura Logística o Superadministración pueden aprobar' using errcode='42501';
  end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id for update;
  if not found then raise exception 'Pedido asociado no encontrado'; end if;
  v_before_step:=v_order.current_step_code;
  v_before_status:=v_order.status;

  update erp_supply.approval_requests
  set status=v_dec,decision_reason=trim(p_reason),decided_by=v_actor,decided_at=v_now
  where id=p_request_id returning * into v_req;

  if v_dec='APPROVED' then
    case v_req.request_type
      when 'CANCELLATION' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.task_sessions s
        set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
            business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
            note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cancelación aprobada'
        from erp_supply.order_tasks t
        where s.task_id=t.id and t.order_id=v_order.id and s.ended_at is null;
        update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='CANCELLED_BY_APPROVAL'
        where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
        update erp_supply.orders set status='CANCELLED',cancelled_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1
        where id=v_order.id returning * into v_order;

      when 'PRIORITY' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.orders set priority=upper(v_req.request_payload->>'priority'),version=version+1
        where id=v_order.id returning * into v_order;

      when 'ROUTE_CHANGE' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        v_route:=upper(v_req.request_payload->>'route');
        if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta aprobada inválida'; end if;
        if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
          select * into v_old_task from erp_supply.order_tasks
          where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
          order by sequence_no desc limit 1 for update;
          update erp_supply.task_sessions s set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
            business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
            note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cambio de ruta'
          where s.task_id=v_old_task.id and s.ended_at is null;
          update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='ROUTE_CHANGED'
          where id=v_old_task.id;
          v_next_sequence:=coalesce(v_old_task.sequence_no,0)+1;
          update erp_supply.orders set delivery_route_code=v_route,current_step_code=v_route,status='QUEUED',
            current_assignee_id=null,current_role_code=null,version=version+1
          where id=v_order.id returning * into v_order;
          perform erp_supply.create_task(v_order,v_route,v_next_sequence);
          select * into v_order from erp_supply.orders where id=v_order.id;
        else
          update erp_supply.orders set delivery_route_code=v_route,version=version+1
          where id=v_order.id returning * into v_order;
        end if;

      when 'REOPEN' then
        if v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
        v_next_sequence:=(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id);
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code='CLOSURE',
          current_assignee_id=null,current_role_code=null,version=version+1
        where id=v_order.id returning * into v_order;
        perform erp_supply.create_task(v_order,'CLOSURE',v_next_sequence);
        select * into v_order from erp_supply.orders where id=v_order.id;

      when 'STOCK_EXCEPTION' then null;
      when 'FLOW_EXCEPTION' then null;
      when 'PAYMENT_EXCEPTION' then null;
      when 'DATA_CORRECTION' then null;
      else raise exception 'Tipo de solicitud no implementado: %',v_req.request_type;
    end case;

    update erp_supply.approval_requests set status='EXECUTED',executed_at=v_now where id=p_request_id returning status into v_final_status;
  else
    v_final_status:='REJECTED';
  end if;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_before_step,v_order.current_step_code,
    v_before_status,v_order.status,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason,'finalRequestStatus',v_final_status));

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_req.organization_id,v_actor,'APPROVAL_'||v_dec,'APPROVAL_REQUEST',v_req.id::text,
    jsonb_build_object('status','PENDING'),jsonb_build_object('status',v_final_status,'orderStatus',v_order.status,'orderVersion',v_order.version),
    jsonb_build_object('requestType',v_req.request_type,'reason',p_reason));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_req.organization_id,'APPROVAL_DECIDED','ORDER',v_order.id,
    jsonb_build_object('requestId',v_req.id,'decision',v_dec,'requestType',v_req.request_type,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec,'requestStatus',v_final_status,
    'orderId',v_order.id,'orderStatus',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
end;
$$;


-- Gate central: novedades/reportes abiertos, prioridad y salida sin factura aprobada.
create or replace function erp_supply.validate_task_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_missing integer;
begin
  if new.status<>'COMPLETED' or old.status='COMPLETED' then return new; end if;
  select * into v_order from erp_supply.orders where id=new.order_id;
  if v_order.is_test then return new; end if;

  if exists(
    select 1 from erp_supply.order_issues i
    where i.order_id=v_order.id and i.blocking and i.status='OPEN'
  ) then
    raise exception 'El pedido tiene una novedad o reporte pendiente de solución';
  end if;

  if v_order.priority in('URGENT','CRITICAL') and not exists(
    select 1 from erp_supply.approval_requests a
    where a.order_id=v_order.id
      and a.request_type='FLOW_EXCEPTION'
      and upper(coalesce(a.request_payload->>'exceptionCode',''))='PRIORITY_RELEASE'
      and a.status in('APPROVED','EXECUTED')
  ) then
    raise exception 'APROBACION_REQUERIDA: los pedidos urgentes o críticos requieren aprobación antes de avanzar';
  end if;

  select count(*) into v_missing
  from erp_supply.task_checklist
  where task_id=new.id and required and not completed;
  if v_missing>0 then
    raise exception 'No puede finalizar: quedan % controles obligatorios sin completar',v_missing;
  end if;

  case new.step_code
    when 'CARTERA' then
      if not exists(
        select 1 from erp_supply.financial_validations
        where order_id=v_order.id and validation_type='CARTERA' and decision='APPROVED'
      ) then
        raise exception 'Debe registrar una validación aprobada de Cartera';
      end if;

    when 'CAJA' then
      if not exists(
        select 1 from erp_supply.financial_validations
        where order_id=v_order.id and validation_type='CAJA' and decision='APPROVED'
      ) then
        raise exception 'Debe registrar una validación aprobada de Caja';
      end if;

    when 'COMPRAS' then
      if not exists(
        select 1 from erp_supply.purchase_orders
        where order_id=v_order.id and status in('ISSUED','CONFIRMED','PARTIAL','RECEIVED')
      ) then
        raise exception 'Debe registrar una orden de compra válida';
      end if;

    when 'RECEPCION_MERCANCIA' then
      if not exists(
        select 1 from erp_supply.receipts
        where order_id=v_order.id and status in('PARTIAL','CONFORMING','CLOSED')
      ) then
        raise exception 'Debe registrar la recepción física y su resultado de calidad';
      end if;

    when 'CORTE' then
      if v_order.requires_cut and not exists(
        select 1 from erp_supply.cut_jobs
        where order_id=v_order.id and status='COMPLETED'
      ) then
        raise exception 'Debe registrar al menos un corte completado';
      end if;

    when 'FACTURACION' then
      if upper(v_order.order_type_code)='PVP' then
        if not exists(
          select 1 from erp_supply.drive_files f
          where f.order_id=v_order.id
            and f.task_id=new.id
            and upper(f.file_category)='PVP_ANNEX'
        ) then
          raise exception 'Debe cargar el Anexo PVP antes de enviar el pedido a despacho';
        end if;
      else
        if not exists(
          select 1
          from erp_supply.invoices i
          join erp_supply.drive_files f on f.id=i.drive_file_id
          where i.order_id=v_order.id
            and i.status='REGISTERED'
            and f.task_id=new.id
        ) and not exists(
          select 1 from erp_supply.approval_requests a
          where a.order_id=v_order.id and a.request_type='PAYMENT_EXCEPTION'
            and upper(coalesce(a.request_payload->>'exceptionCode',''))='NO_INVOICE'
            and a.status in('APPROVED','EXECUTED')
        ) then
          raise exception 'Debe cargar la factura o contar con aprobación para salida sin factura';
        end if;
      end if;

    when 'CAJA_FACTURACION' then
      if not exists(
        select 1
        from erp_supply.invoices i
        join erp_supply.drive_files f on f.id=i.drive_file_id
        where i.order_id=v_order.id and i.status='REGISTERED' and f.task_id=new.id
      ) and not exists(
        select 1 from erp_supply.approval_requests a
        where a.order_id=v_order.id and a.request_type='PAYMENT_EXCEPTION'
          and upper(coalesce(a.request_payload->>'exceptionCode',''))='NO_INVOICE'
          and a.status in('APPROVED','EXECUTED')
      ) then
        raise exception 'Debe cargar la factura o contar con aprobación para salida sin factura';
      end if;

    -- V10.11.7: en despacho ya NO se exige entrega/foto.
    -- La guía + estado de salida son suficientes para crear CLOSURE.
    when 'CLIENT_POINT' then
      if not exists(
        select 1 from erp_supply.deliveries d
        where d.order_id=v_order.id
          and nullif(trim(d.tracking_number),'') is not null
          and d.status in('DISPATCHED','IN_TRANSIT','DELIVERED')
      ) then
        raise exception 'Debe registrar la guía antes de pasar a cierre';
      end if;

    when 'CLIENT_PICKUP' then
      if not exists(
        select 1 from erp_supply.deliveries d
        where d.order_id=v_order.id
          and nullif(trim(d.tracking_number),'') is not null
          and d.status in('DISPATCHED','IN_TRANSIT','DELIVERED')
      ) then
        raise exception 'Debe registrar la guía antes de pasar a cierre';
      end if;

    when 'LOCAL_DISPATCH' then
      if not exists(
        select 1 from erp_supply.deliveries d
        where d.order_id=v_order.id
          and nullif(trim(d.tracking_number),'') is not null
          and d.status in('DISPATCHED','IN_TRANSIT','DELIVERED')
      ) then
        raise exception 'Debe registrar la guía antes de pasar a cierre';
      end if;

    when 'NATIONAL_DISPATCH' then
      if not exists(
        select 1 from erp_supply.deliveries d
        where d.order_id=v_order.id
          and nullif(trim(d.tracking_number),'') is not null
          and d.status in('DISPATCHED','IN_TRANSIT','DELIVERED')
      ) then
        raise exception 'Debe registrar la guía antes de pasar a cierre';
      end if;

    -- Cierre conserva controles reales: documento comercial previo, foto y entrega.
    when 'CLOSURE' then
      if upper(v_order.order_type_code)='PVP' then
        if not exists(
          select 1 from erp_supply.drive_files
          where order_id=v_order.id and upper(file_category)='PVP_ANNEX'
        ) then
          raise exception 'El pedido no tiene Anexo PVP';
        end if;
      elsif not exists(
        select 1 from erp_supply.invoices
        where order_id=v_order.id and status='REGISTERED'
      ) and not exists(
        select 1 from erp_supply.approval_requests a
        where a.order_id=v_order.id and a.request_type='PAYMENT_EXCEPTION'
          and upper(coalesce(a.request_payload->>'exceptionCode',''))='NO_INVOICE'
          and a.status in('APPROVED','EXECUTED')
      ) then
        raise exception 'El pedido no tiene factura registrada ni aprobación de salida sin factura';
      end if;

      if not exists(
        select 1 from erp_supply.drive_files f
        where f.order_id=v_order.id
          and f.task_id=new.id
          and upper(f.file_category)='DELIVERY_EVIDENCE'
      ) then
        raise exception 'Debes subir la foto de entrega antes de finalizar';
      end if;

      if not exists(
        select 1 from erp_supply.deliveries
        where order_id=v_order.id and status='DELIVERED'
      ) then
        raise exception 'El pedido no tiene entrega confirmada';
      end if;

    else null;
  end case;

  return new;
end;
$$;


drop trigger if exists trg_validate_task_completion on erp_supply.order_tasks;
create trigger trg_validate_task_completion before update of status on erp_supply.order_tasks for each row execute function erp_supply.validate_task_completion();

-- Listado de pedidos enriquecido con etiqueta de excepción y PVE visible en Recepción mientras está en Compras.
create or replace function public.erp_x_list_orders(
  p_search text default null,p_step text default null,p_status text default null,p_order_type text default null,p_route text default null,
  p_assignment text default 'ALL',p_page integer default 1,p_page_size integer default 50,p_include_history boolean default true
)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth as $$
declare v_org uuid:=erp_supply.current_org_id();v_profile uuid:=erp_supply.require_profile();v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),250);v_total bigint;v_items jsonb;begin
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds,
      pa.status arrival_status,
      (p_step='RECEPCION_PEDIDO' and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')) purchase_shadow,
      o.metadata#>>'{exceptionState,label}' exception_label,
      (select count(*) from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') open_issue_count
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code left join erp_supply.purchase_arrival_state pa on pa.order_id=o.id
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order_or_reception_shadow(o.id) and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step or (p_step='RECEPCION_PEDIDO' and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')))
      and (p_status is null or p_status='' or o.status=p_status) and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type) and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
  ) select count(*) into v_total from filtered;
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds,pa.status arrival_status,
      (p_step='RECEPCION_PEDIDO' and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')) purchase_shadow,o.metadata#>>'{exceptionState,label}' exception_label,
      (select count(*) from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') open_issue_count
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code left join erp_supply.purchase_arrival_state pa on pa.order_id=o.id
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order_or_reception_shadow(o.id) and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step or (p_step='RECEPCION_PEDIDO' and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')))
      and (p_status is null or p_status='' or o.status=p_status) and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type) and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.updated_at desc offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'externalReference',external_reference,'orderType',order_type_code,'clientName',client_name,'paymentCondition',payment_condition_code,'route',delivery_route_code,
    'currentStep',current_step_code,'stepName',case when purchase_shadow then 'Recepción · seguimiento de Compras' else step_name end,'status',status,'priority',priority,'requiresCut',requires_cut,'requiresPurchase',requires_purchase,
    'assigneeId',current_assignee_id,'assigneeName',assignee_name,'roleCode',current_role_code,'ageBusinessSeconds',age_business_seconds,'slaExceeded',(sla_hours is not null and age_business_seconds>sla_hours*3600),
    'version',version,'isHistory',is_history,'createdAt',created_at,'updatedAt',updated_at,'fulfillmentStatus',metadata#>>'{fulfillment,status}','partialLabel',coalesce((metadata#>>'{fulfillment,partialLabel}')::boolean,false),
    'pendingItemCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,pendingItemCount}'),0),'pickingRoundCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,roundCount}'),0),
    'exceptionLabel',exception_label,'openIssueCount',open_issue_count,'purchaseShadow',purchase_shadow,'arrivalStatus',arrival_status
  )),'[]'::jsonb) into v_items from filtered;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int),'generatedAt',now());
end;$$;

-- Verificación de integridad de los RPC nuevos.
do $$
begin
  if to_regprocedure('public.erp_x_create_order_issue(uuid,jsonb)') is null then raise exception 'Falta RPC de incidencias'; end if;
  if to_regprocedure('public.erp_x_set_purchase_arrival(uuid,text)') is null then raise exception 'Falta RPC de llegada PVE'; end if;
  if to_regprocedure('public.erp_x_save_picking_precheck(uuid,jsonb)') is null then raise exception 'Falta RPC de prealistamiento paralelo'; end if;
end;$$;

notify pgrst,'reload schema';
commit;
