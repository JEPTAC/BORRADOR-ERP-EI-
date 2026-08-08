begin;

-- V10.11.6 · La dirección se registra obligatoriamente en Ventas.
-- Despachos solo agrega la guía y envía el pedido a Cierre.

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
  v_department text;
  v_city text;
  v_address text;
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
  v_department:=nullif(trim(p_payload->>'clientDepartment'),'');
  v_city:=nullif(trim(p_payload->>'clientCity'),'');
  v_address:=nullif(trim(p_payload->>'clientAddress'),'');
  v_priority:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_requested_date:=erp_supply.safe_date(p_payload->>'requestedDeliveryDate');
  v_promised_at:=erp_supply.safe_timestamptz(p_payload->>'promisedAt');
  v_items:=coalesce(p_payload->'items','[]'::jsonb);

  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if v_department is null then raise exception 'Departamento de entrega requerido'; end if;
  if v_city is null then raise exception 'Municipio o ciudad de entrega requerido'; end if;
  if v_address is null or length(v_address)<5 then raise exception 'Dirección de entrega requerida'; end if;
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
      'routingVersion','10.7',
      'clientCountry',coalesce(nullif(trim(p_payload->>'clientCountry'),''),'Colombia'),
      'clientDepartment',v_department,
      'clientCity',v_city,
      'clientAddress',v_address,
      'addressCaptureVersion','10.11.6'
    );

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),v_city,
    v_address,nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
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
    p_payload||jsonb_build_object('resolvedInitialStep',v_initial,'hasCreditArrears',v_has_credit_arrears,'heldByCashier',v_held_by_cashier,'clientDepartment',v_department,'clientCity',v_city,'clientAddress',v_address)
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_shipping_send_to_closure(p_order_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_delivery erp_supply.deliveries%rowtype;
  v_result jsonb;
  v_closure erp_supply.order_tasks%rowtype;
  v_role text:=coalesce((erp_supply.current_roles())[1],'coordinador_logistico');
  v_department text;
  v_municipality text;
  v_address text;
  v_destination jsonb;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para gestionar despachos' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'El pedido no está en despacho'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El pedido está asignado a otra persona' using errcode='42501'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1 for update;
  if not found or nullif(trim(v_delivery.tracking_number),'') is null then raise exception 'Falta registrar la guía'; end if;

  v_department:=coalesce(
    nullif(trim(v_delivery.metadata#>>'{destination,department}'),''),
    nullif(trim(v_order.metadata->>'clientDepartment'),'')
  );
  v_municipality:=coalesce(
    nullif(trim(v_delivery.metadata#>>'{destination,municipality}'),''),
    nullif(trim(v_order.client_city),'')
  );
  v_address:=coalesce(
    nullif(trim(v_delivery.metadata#>>'{destination,address}'),''),
    nullif(trim(v_order.client_address),'')
  );
  if v_municipality is null or v_address is null then
    raise exception 'El pedido no tiene dirección completa. Ventas debe registrar municipio y dirección antes del despacho';
  end if;
  v_destination:=jsonb_build_object(
    'country',coalesce(nullif(trim(v_order.metadata->>'clientCountry'),''),'Colombia'),
    'department',v_department,
    'municipality',v_municipality,
    'address',v_address,
    'source','SALES_ORDER_ADDRESS',
    'capturedAt',coalesce(v_order.metadata->>'addressCapturedAt',v_order.created_at::text)
  );

  update erp_supply.deliveries set status='IN_TRANSIT',dispatched_at=coalesce(dispatched_at,now()),assigned_profile_id=v_actor,
    metadata=metadata||jsonb_build_object('sentToClosureAt',now(),'destination',v_destination),updated_at=now()
  where id=v_delivery.id returning * into v_delivery;
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'DISPATCHED',v_actor,jsonb_build_object('trackingNumber',v_delivery.tracking_number,'route',v_order.delivery_route_code,'destination',v_destination));

  v_result:=erp_supply.execute_action_internal(p_order_id,'COMPLETE',jsonb_build_object('detail',coalesce(nullif(p_payload->>'detail',''),'Pedido despachado y enviado a cierre'),'resultCode','DISPATCHED'),v_actor,false,v_order.version,gen_random_uuid()::text);

  select * into v_closure from erp_supply.order_tasks where order_id=p_order_id and step_code='CLOSURE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found then raise exception 'No fue posible crear la etapa de cierre'; end if;
  update erp_supply.order_tasks set assigned_profile_id=v_actor,assigned_role_code=v_role,assigned_at=coalesce(assigned_at,now()),status='ASSIGNED',metadata=metadata||jsonb_build_object('source','SHIPPING_V10_11','deliveryId',v_delivery.id)
  where id=v_closure.id returning * into v_closure;
  update erp_supply.orders set current_assignee_id=v_actor,current_role_code=v_role,status='ASSIGNED',version=version+1,updated_at=now() where id=p_order_id returning * into v_order;
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_closure.id,v_delivery.id,'CLOSURE_ASSIGNED',v_actor,jsonb_build_object('previousTaskId',v_task.id));
  return jsonb_build_object('success',true,'orderId',p_order_id,'currentStep','CLOSURE','delivery',to_jsonb(v_delivery),'task',to_jsonb(v_closure));
end;
$$;


-- Normaliza metadatos de pedidos existentes que ya tenían ciudad y dirección.
update erp_supply.orders
set metadata=metadata||jsonb_strip_nulls(jsonb_build_object(
  'clientCountry',coalesce(nullif(metadata->>'clientCountry',''),'Colombia'),
  'clientCity',coalesce(nullif(metadata->>'clientCity',''),client_city),
  'clientAddress',coalesce(nullif(metadata->>'clientAddress',''),client_address)
)),updated_at=updated_at
where (client_city is not null or client_address is not null)
  and (metadata->>'clientCity' is null or metadata->>'clientAddress' is null);

grant execute on function public.erp_x_create_order(jsonb,text) to authenticated;
grant execute on function public.erp_x_shipping_send_to_closure(uuid,jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
