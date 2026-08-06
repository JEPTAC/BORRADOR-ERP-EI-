-- ERP Supply Enterprise V10.9
-- Microproceso de Facturación: PVN/PNV a Caja, factura normal para PVC/PVE y Anexo PVP.

begin;

-- La lista de Facturación usa una denominación neutra porque PVP no carga factura.
update erp_supply.checklist_templates
set label='Factura o Anexo PVP cargado',required=true,active=true
where step_code='FACTURACION' and item_code='INVOICE';

update erp_supply.checklist_templates
set label='Documento validado para envío a despacho',required=true,active=true
where step_code='FACTURACION' and item_code='COMMERCIAL_MATCH';

update erp_supply.task_checklist c
set label=case c.item_code
  when 'INVOICE' then 'Anexo PVP cargado'
  when 'COMMERCIAL_MATCH' then 'Anexo PVP validado para despacho'
  else c.label end
from erp_supply.order_tasks t
join erp_supply.orders o on o.id=t.order_id
where c.task_id=t.id
  and t.step_code='FACTURACION'
  and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  and upper(o.order_type_code)='PVP'
  and c.item_code in('INVOICE','COMMERCIAL_MATCH');

-- El tipo operativo real es PVN. Se acepta PNV como alias defensivo para datos históricos.
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
      when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CORTE' then case
      when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION'
      else 'FACTURACION' end
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

-- Toda factura nueva debe estar vinculada al archivo cargado en Google Drive
-- y a la tarea activa de facturación de la ronda actual.
create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_invoice erp_supply.invoices%rowtype;
  v_file_id uuid:=erp_supply.safe_uuid(p_payload->>'driveFileRecordId');
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=erp_supply.current_org_id()
    and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code=v_order.current_step_code
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1;
  if not found then raise exception 'El pedido no tiene una tarea activa de facturación'; end if;

  if upper(v_order.order_type_code)='PVP' then
    raise exception 'Los pedidos PVP deben cargar Anexo PVP, no factura';
  end if;

  if v_order.current_step_code='CAJA_FACTURACION' then
    if not (erp_supply.has_role('caja') or erp_supply.has_role('super_admin')) then
      raise exception 'Solo Caja puede registrar esta factura' using errcode='42501';
    end if;
    if upper(v_order.order_type_code) not in('PVN','PNV') then
      raise exception 'La facturación en Caja solo aplica a pedidos pagados de contado';
    end if;
  else
    if v_order.current_step_code<>'FACTURACION' and not erp_supply.has_role('super_admin') then
      raise exception 'El pedido no está en Facturación';
    end if;
    if not (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then
      raise exception 'No autorizado para facturar' using errcode='42501';
    end if;
  end if;

  if v_file_id is null or not exists(
    select 1
    from erp_supply.drive_files f
    where f.id=v_file_id
      and f.order_id=p_order_id
      and f.task_id=v_task.id
      and upper(f.file_category)='INVOICE'
  ) then
    raise exception 'Debe subir la factura mediante Google Drive antes de guardarla';
  end if;

  if nullif(trim(p_payload->>'invoiceNumber'),'') is null then
    raise exception 'Número de factura requerido';
  end if;

  insert into erp_supply.invoices(
    order_id,invoice_number,invoice_date,amount,currency,status,
    drive_file_id,registered_by,metadata
  ) values(
    p_order_id,
    trim(p_payload->>'invoiceNumber'),
    coalesce(erp_supply.safe_date(p_payload->>'invoiceDate'),current_date),
    erp_supply.safe_numeric(p_payload->>'amount'),
    coalesce(nullif(trim(p_payload->>'currency'),''),'COP'),
    'REGISTERED',v_file_id,v_actor,
    (case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object'
      then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
      ||jsonb_build_object('registeredStep',v_order.current_step_code,'taskId',v_task.id)
  ) returning * into v_invoice;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_order.organization_id,p_order_id,v_task.id,'DOMAIN_RECORD','INVOICE',
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'invoiceId',v_invoice.id,
      'invoiceNumber',v_invoice.invoice_number,
      'step',v_order.current_step_code,
      'taskId',v_task.id
    )
  );

  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

-- Corrige manualmente un PVN que haya llegado a Facturación de Logística.
create or replace function public.erp_x_route_billing_to_cash(
  p_order_id uuid,
  p_reason text default null
)
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
  v_new_task erp_supply.order_tasks%rowtype;
  v_sequence integer;
  v_now timestamptz:=now();
  v_raw bigint:=0;
  v_business bigint:=0;
begin
  if not (
    erp_supply.can_access_module('billing','update')
    or erp_supply.has_role('coordinador_logistico')
    or erp_supply.has_role('despacho_nacional')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para enviar el pedido a Caja' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=v_org
    and erp_supply.can_view_order(id)
  for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'FACTURACION' then
    raise exception 'El pedido no está en Facturación de Logística';
  end if;
  if upper(v_order.order_type_code) not in('PVN','PNV') then
    raise exception 'Solo los pedidos pagados de contado pueden enviarse a Caja';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code='FACTURACION'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;
  if not found then raise exception 'No existe una tarea activa de Facturación'; end if;

  update erp_supply.task_sessions s
  set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from (v_now-s.started_at)))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_org,s.started_at,v_now),
      note=coalesce(nullif(trim(p_reason),''),'Reenrutado manualmente a Caja')
  where s.task_id=v_task.id and s.ended_at is null;

  select coalesce(sum(raw_seconds),0),coalesce(sum(business_seconds),0)
  into v_raw,v_business
  from erp_supply.task_sessions
  where task_id=v_task.id;

  update erp_supply.order_tasks
  set status='CANCELLED',completed_at=v_now,
      raw_seconds=v_raw,business_seconds=v_business,
      result_code='ROUTED_TO_CASH',
      result_detail=coalesce(nullif(trim(p_reason),''),'Pedido pagado de contado enviado a Caja'),
      metadata=metadata||jsonb_build_object(
        'routedToCashAt',v_now,
        'routedToCashBy',v_actor,
        'routingVersion','10.9'
      )
  where id=v_task.id;

  select coalesce(max(sequence_no),0)+1 into v_sequence
  from erp_supply.order_tasks where order_id=p_order_id;

  select * into v_new_task
  from erp_supply.create_task(v_order,'CAJA_FACTURACION',v_sequence);

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object(
        'billingRouting','CAJA_FACTURACION',
        'billingRoutedManually',true,
        'billingRoutedAt',v_now,
        'billingRoutedBy',v_actor,
        'routingVersion','10.9'
      ),
      updated_at=v_now
  where id=p_order_id;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,p_order_id,v_task.id,'ROUTE_CORRECTION','SEND_TO_CASH',
    'FACTURACION','CAJA_FACTURACION',v_order.status,v_new_task.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'reason',coalesce(nullif(trim(p_reason),''),'Pedido pagado de contado'),
      'cancelledTaskId',v_task.id,
      'newTaskId',v_new_task.id,
      'routingVersion','10.9'
    )
  );

  return jsonb_build_object(
    'success',true,
    'orderId',p_order_id,
    'currentStep','CAJA_FACTURACION',
    'taskId',v_new_task.id
  );
end;
$$;

-- Control transaccional por documento y por tarea/ronda.
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

  select count(*) into v_missing
  from erp_supply.task_checklist
  where task_id=new.id and required and not completed;
  if v_missing>0 then
    raise exception 'No puede finalizar: quedan % controles obligatorios sin completar',v_missing;
  end if;

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
      if upper(v_order.order_type_code)='PVP' then
        if not exists(
          select 1 from erp_supply.drive_files f
          where f.order_id=v_order.id and f.task_id=new.id and upper(f.file_category)='PVP_ANNEX'
        ) then raise exception 'Debe cargar el Anexo PVP antes de enviar el pedido a despacho'; end if;
      else
        if not exists(
          select 1
          from erp_supply.invoices i
          join erp_supply.drive_files f on f.id=i.drive_file_id
          where i.order_id=v_order.id and i.status='REGISTERED' and f.task_id=new.id
        ) then raise exception 'Debe cargar la factura antes de enviar el pedido a despacho'; end if;
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
      if upper(v_order.order_type_code)='PVP' then
        if not exists(select 1 from erp_supply.drive_files where order_id=v_order.id and upper(file_category)='PVP_ANNEX') then
          raise exception 'El pedido no tiene Anexo PVP';
        end if;
      elsif not exists(select 1 from erp_supply.invoices where order_id=v_order.id and status='REGISTERED') then
        raise exception 'El pedido no tiene factura registrada';
      end if;
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then
        raise exception 'El pedido no tiene entrega confirmada';
      end if;
    else null;
  end case;
  return new;
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
    if not exists(
      select 1
      from erp_supply.invoices i
      join erp_supply.drive_files f on f.id=i.drive_file_id
      where i.order_id=new.order_id and i.status='REGISTERED' and f.task_id=new.id
    ) then
      raise exception 'Debe subir la factura de esta gestión antes de enviar el pedido a despacho';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.erp_x_save_invoice(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_route_billing_to_cash(uuid,text) from public,anon,authenticated;
grant execute on function public.erp_x_save_invoice(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_route_billing_to_cash(uuid,text) to authenticated;

commit;
