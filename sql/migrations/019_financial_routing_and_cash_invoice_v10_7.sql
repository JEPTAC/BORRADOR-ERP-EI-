-- ERP Supply Enterprise V10.7
-- Enrutamiento condicional de Cartera/Caja y facturación PVN desde Caja.

begin;

insert into erp_supply.workflow_steps(code,name,module_code,queue_code,sla_hours,sort_order,terminal,metadata)
values('CAJA_FACTURACION','Facturación en Caja','caja','CAJA',4,75,false,'{"phase":"outbound","orderType":"PVN"}'::jsonb)
on conflict(code) do update set
  name=excluded.name,module_code=excluded.module_code,queue_code=excluded.queue_code,
  sla_hours=excluded.sla_hours,sort_order=excluded.sort_order,terminal=false,active=true,metadata=excluded.metadata;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
values('CAJA_FACTURACION','caja',true,true,false,true,true,true,false)
on conflict(step_code,role_code) do update set
  can_view=true,can_claim=true,can_assign=false,can_start=true,can_complete=true,can_block=true,can_override=false;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select 'CAJA_FACTURACION',r.role_code,r.can_view,r.can_claim,r.can_assign,r.can_start,r.can_complete,r.can_block,r.can_override
from erp_supply.step_roles r
where r.step_code='CAJA' and r.role_code in('super_admin','gerencia','auditoria','jefe_logistica')
on conflict(step_code,role_code) do update set
  can_view=excluded.can_view,can_claim=excluded.can_claim,can_assign=excluded.can_assign,
  can_start=excluded.can_start,can_complete=excluded.can_complete,can_block=excluded.can_block,can_override=excluded.can_override;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('caja','billing',true,true,true,false,false)
on conflict(role_code,module_code) do update set
  can_read=true,can_create=true,can_update=true;

insert into erp_supply.checklist_templates(step_code,item_code,label,required,sort_order,active)
values('CAJA_FACTURACION','INVOICE_UPLOAD','Factura cargada y verificada por Caja',true,10,true)
on conflict(step_code,item_code) do update set label=excluded.label,required=true,sort_order=10,active=true;

create or replace function erp_supply.initial_step(
  p_order_type text,
  p_payment_condition text,
  p_requires_purchase boolean,
  p_has_credit_arrears boolean,
  p_held_by_cashier boolean
)
returns text
language sql
immutable
as $$
  select case
    when p_order_type in('PVC','PVP') and coalesce(p_has_credit_arrears,false) then 'CARTERA'
    when p_order_type='PVN' and coalesce(p_held_by_cashier,false) then 'CAJA'
    when p_order_type='PVE' then 'COMPRAS'
    when p_order_type not in('PVC','PVP','PVN','PVE') and coalesce(p_requires_purchase,false) then 'COMPRAS'
    else 'RECEPCION_PEDIDO'
  end
$$;

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
    when 'ALISTAMIENTO' then case
      when p_requires_cut then 'CORTE'
      when p_order_type='PVN' then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CORTE' then case when p_order_type='PVN' then 'CAJA_FACTURACION' else 'FACTURACION' end
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

create or replace function erp_supply.default_role_for_step(p_step text,p_route text)
returns text
language sql
immutable
as $$
  select case p_step
    when 'CARTERA' then 'cartera'
    when 'CAJA' then 'caja'
    when 'CAJA_FACTURACION' then 'caja'
    when 'COMPRAS' then 'compras'
    when 'RECEPCION_MERCANCIA' then 'recepcion_mercancia'
    when 'RECEPCION_PEDIDO' then 'coordinador_logistico'
    when 'ALISTAMIENTO' then 'aux_logistica'
    when 'CORTE' then 'auxiliar_corte'
    when 'FACTURACION' then case when p_route='NATIONAL_DISPATCH' then 'despacho_nacional' else 'coordinador_logistico' end
    when 'NATIONAL_DISPATCH' then 'despacho_nacional'
    when 'CLIENT_POINT' then 'coordinador_logistico'
    when 'CLIENT_PICKUP' then 'coordinador_logistico'
    when 'LOCAL_DISPATCH' then 'coordinador_logistico'
    when 'CLOSURE' then 'jefe_logistica'
    else null end
$$;

create or replace function public.erp_x_create_order(p_payload jsonb,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_item jsonb;
  v_items jsonb;
  v_initial text;
  v_number text;
  v_order_type text;
  v_payment text;
  v_route text;
  v_client text;
  v_priority text;
  v_requires_purchase boolean;
  v_requires_cut boolean;
  v_item_cut boolean;
  v_has_credit_arrears boolean;
  v_held_by_cashier boolean;
  v_quantity numeric;
  v_cut_length numeric;
  v_requested_date date;
  v_promised_at timestamptz;
  v_line integer:=0;
  v_metadata jsonb;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then
    raise exception 'Rol no autorizado para crear pedidos' using errcode='42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'El pedido debe enviarse como un objeto válido'; end if;

  v_number:=nullif(trim(p_payload->>'orderNumber'),'');
  v_order_type:=upper(nullif(trim(p_payload->>'orderType'),''));
  v_payment:=upper(nullif(trim(p_payload->>'paymentCondition'),''));
  v_route:=upper(nullif(trim(p_payload->>'deliveryRoute'),''));
  v_client:=nullif(trim(p_payload->>'clientName'),'');
  v_priority:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_requested_date:=erp_supply.safe_date(p_payload->>'requestedDeliveryDate');
  v_promised_at:=erp_supply.safe_timestamptz(p_payload->>'promisedAt');
  v_items:=coalesce(p_payload->'items','[]'::jsonb);

  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_order_type and active) then raise exception 'Tipo de pedido inválido: %',coalesce(v_order_type,'vacío'); end if;
  if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago inválida: %',coalesce(v_payment,'vacía'); end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Modalidad de entrega inválida: %',coalesce(v_route,'vacía'); end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
  if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)=0 then raise exception 'El pedido debe contener al menos un ítem'; end if;
  if (p_payload ? 'requestedDeliveryDate') and nullif(trim(p_payload->>'requestedDeliveryDate'),'') is not null and v_requested_date is null then raise exception 'Fecha solicitada inválida'; end if;
  if (p_payload ? 'promisedAt') and nullif(trim(p_payload->>'promisedAt'),'') is not null and v_promised_at is null then raise exception 'Fecha prometida inválida'; end if;

  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_org and idempotency_key=p_idempotency_key
  ) then
    select o.* into v_order
    from erp_supply.orders o
    join erp_supply.order_events e on e.order_id=o.id
    where e.organization_id=v_org and e.idempotency_key=p_idempotency_key
    limit 1;
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
  end if;

  v_requires_purchase:=coalesce(
    erp_supply.safe_boolean(p_payload->>'requiresPurchase',null),
    (select requires_purchase_default from erp_supply.order_types where code=v_order_type),
    false
  );
  v_requires_cut:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresCut',false),false);
  v_has_credit_arrears:=v_order_type in('PVC','PVP') and coalesce(erp_supply.safe_boolean(p_payload->>'hasCreditArrears',false),false);
  v_held_by_cashier:=v_order_type='PVN' and coalesce(erp_supply.safe_boolean(p_payload->>'heldByCashier',false),false);

  for v_item in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_item)<>'object' then raise exception 'Cada línea del pedido debe ser un objeto'; end if;
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    if v_item_cut then v_requires_cut:=true; end if;
  end loop;

  v_initial:=erp_supply.initial_step(v_order_type,v_payment,v_requires_purchase,v_has_credit_arrears,v_held_by_cashier);
  v_metadata:=(case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
    ||jsonb_build_object(
      'hasCreditArrears',v_has_credit_arrears,
      'heldByCashier',v_held_by_cashier,
      'initialRouting',v_initial,
      'routingVersion','10.7'
    );

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),nullif(trim(p_payload->>'clientCity'),''),
    nullif(trim(p_payload->>'clientAddress'),''),nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
    v_priority,v_requires_cut,v_requires_purchase,v_promised_at,v_requested_date,v_metadata
  ) returning * into v_order;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_line:=v_line+1;
    v_quantity:=erp_supply.safe_numeric(v_item->>'quantity');
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    v_cut_length:=erp_supply.safe_numeric(v_item->>'requestedCutLength');
    if nullif(trim(v_item->>'description'),'') is null then raise exception 'La línea % no tiene descripción',v_line; end if;
    if v_quantity is null or v_quantity<=0 then raise exception 'Cantidad inválida en la línea %',v_line; end if;
    if v_item_cut and (v_cut_length is null or v_cut_length<=0) then raise exception 'La línea % requiere una longitud de corte válida',v_line; end if;
    insert into erp_supply.order_items(
      order_id,line_number,sku,reference,description,quantity,unit,warehouse_location,requires_cut,
      requested_cut_length,dimensions,metadata
    ) values(
      v_order.id,coalesce(erp_supply.safe_integer(v_item->>'lineNumber'),v_line),nullif(trim(v_item->>'sku'),''),
      nullif(trim(v_item->>'reference'),''),trim(v_item->>'description'),v_quantity,
      coalesce(nullif(trim(v_item->>'unit'),''),'UND'),nullif(trim(v_item->>'warehouseLocation'),''),v_item_cut,
      v_cut_length,case when jsonb_typeof(coalesce(v_item->'dimensions','{}'::jsonb))='object' then coalesce(v_item->'dimensions','{}'::jsonb) else '{}'::jsonb end,
      case when jsonb_typeof(coalesce(v_item->'metadata','{}'::jsonb))='object' then coalesce(v_item->'metadata','{}'::jsonb) else '{}'::jsonb end
    );
  end loop;

  select * into v_task from erp_supply.create_task(v_order,v_initial,1);
  select * into v_order from erp_supply.orders where id=v_order.id;
  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,to_step_code,to_status,actor_profile_id,actor_role_code,idempotency_key,payload
  ) values(
    v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,
    p_payload||jsonb_build_object('resolvedInitialStep',v_initial,'hasCreditArrears',v_has_credit_arrears,'heldByCashier',v_held_by_cashier)
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_invoice erp_supply.invoices%rowtype;
  v_file_id uuid:=erp_supply.safe_uuid(p_payload->>'driveFileRecordId');
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  if v_order.current_step_code='CAJA_FACTURACION' then
    if not (erp_supply.has_role('caja') or erp_supply.has_role('super_admin')) then
      raise exception 'Solo Caja puede registrar esta factura' using errcode='42501';
    end if;
    if v_order.order_type_code<>'PVN' then raise exception 'La facturación en Caja solo aplica a pedidos PVN'; end if;
    if v_file_id is null or not exists(
      select 1 from erp_supply.drive_files f
      where f.id=v_file_id and f.order_id=p_order_id and upper(f.file_category)='INVOICE'
    ) then raise exception 'Debe subir la factura PDF antes de guardarla'; end if;
  else
    if v_order.current_step_code<>'FACTURACION' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Facturación'; end if;
    if not (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para facturar' using errcode='42501'; end if;
  end if;

  if nullif(trim(p_payload->>'invoiceNumber'),'') is null then raise exception 'Número de factura requerido'; end if;
  insert into erp_supply.invoices(order_id,invoice_number,invoice_date,amount,currency,status,drive_file_id,registered_by,metadata)
  values(
    p_order_id,trim(p_payload->>'invoiceNumber'),coalesce(erp_supply.safe_date(p_payload->>'invoiceDate'),current_date),
    erp_supply.safe_numeric(p_payload->>'amount'),coalesce(nullif(trim(p_payload->>'currency'),''),'COP'),'REGISTERED',
    v_file_id,v_actor,
    (case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
      ||jsonb_build_object('registeredStep',v_order.current_step_code)
  ) returning * into v_invoice;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','INVOICE',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('invoiceId',v_invoice.id,'invoiceNumber',v_invoice.invoice_number,'step',v_order.current_step_code));
  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

create or replace function erp_supply.validate_cash_invoice_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if new.step_code='CAJA_FACTURACION' and new.status='COMPLETED' and old.status<>'COMPLETED' then
    if not exists(select 1 from erp_supply.invoices i where i.order_id=new.order_id and i.status='REGISTERED') then
      raise exception 'Debe subir la factura antes de enviar el pedido a logística';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_cash_invoice_completion on erp_supply.order_tasks;
create trigger trg_validate_cash_invoice_completion
before update of status on erp_supply.order_tasks
for each row execute function erp_supply.validate_cash_invoice_completion();

commit;
