-- ERP EI V10.25.7 · Certificación de flujo con identidad transaccional real
--
-- CAUSA DEL 42501 MASIVO EN V10.25.5:
-- V10.16 protege Sandbox haciendo que TODO pedido TEST sea invisible para roles
-- distintos de super_admin. V10.25.5 luego intentó probar esos TEST como Cartera,
-- Caja, Compras, Logística, etc.; por eso la RPC productiva los rechazaba antes de
-- ejecutar ninguna acción. Era un fallo del harness QA, no 336 fallos productivos.
--
-- V10.25.7 conserva el aislamiento global y crea una excepción SOLO dentro de la
-- transacción del caso FLOW_ORDER autorizado. Además deja de seedear el pedido como
-- Super Admin: la creación se hace mediante public.erp_x_create_order como Ventas,
-- y el propio INSERT nace is_test=true/source=QA_BOT, sin instante productivo.

begin;

-- 1. Contexto QA verificable contra corrida/caso/pedido reales.
create or replace function erp_supply.qa_flow_context_active(p_order_id uuid default null)
returns boolean
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_case_id uuid:=erp_supply.safe_uuid(nullif(current_setting('erp.qa_flow_case_id',true),''));
  v_root_profile uuid:=erp_supply.safe_uuid(nullif(current_setting('erp.qa_flow_root_profile',true),''));
  v_actor uuid:=erp_supply.current_profile_id();
  v_roles text[]:=erp_supply.current_roles();
  v_context_order uuid;
begin
  if v_case_id is null or v_root_profile is null or v_actor is null then return false; end if;
  select o.id into v_context_order
  from erp_supply.qa_flow_case_state s
  join erp_supply.qa_deep_cases c on c.id=s.case_id and c.family='FLOW_ORDER'
  join erp_supply.qa_runs r on r.id=c.qa_run_id and r.id=s.qa_run_id
  join erp_supply.orders o on o.id=s.order_id and o.qa_run_id=r.id
  where s.case_id=v_case_id
    and r.status='RUNNING' and r.requested_by=v_root_profile
    and exists(
      select 1 from erp_supply.profiles rp
      join erp_supply.profile_roles rr on rr.profile_id=rp.id and rr.role_code='super_admin'
      where rp.id=v_root_profile and rp.active and rp.organization_id=r.organization_id
    )
    and o.organization_id=erp_supply.current_org_id()
    and o.is_test and o.source='QA_BOT'
    and coalesce((o.metadata->>'manualSandbox')::boolean,false)
    and coalesce((o.metadata->>'qaRobot')::boolean,false)
    and (
      o.current_assignee_id=v_actor
      or o.current_role_code=any(v_roles)
      or exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') and (t.assigned_profile_id=v_actor or t.assigned_role_code=any(v_roles)))
      or exists(select 1 from erp_supply.cut_requirements cr where cr.order_id=o.id and cr.assigned_profile_id=v_actor and cr.process_status<>'READY')
    )
  limit 1;
  if v_context_order is null then return false; end if;
  if p_order_id is not null and p_order_id is distinct from v_context_order then return false; end if;
  return true;
end;
$$;
revoke all on function erp_supply.qa_flow_context_active(uuid) from public;

-- 2. TEST sigue invisible globalmente; solo el actor del caso actual lo ve.
create or replace function erp_supply.can_view_order(p_order_id uuid)
returns boolean
language sql stable security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  with ctx as (select erp_supply.current_profile_id() profile_id,erp_supply.current_roles() roles)
  select exists(
    select 1 from erp_supply.orders o cross join ctx
    where o.id=p_order_id and o.organization_id=erp_supply.current_org_id() and (
      (o.is_test and ('super_admin'=any(ctx.roles) or erp_supply.qa_flow_context_active(o.id)))
      or (not o.is_test and (
        ctx.roles && array['super_admin','gerencia','jefe_logistica','auditoria']::text[]
        or o.seller_profile_id=ctx.profile_id or o.current_assignee_id=ctx.profile_id
        or o.current_role_code=any(ctx.roles)
        or exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.assigned_profile_id=ctx.profile_id)
        or exists(select 1 from erp_supply.step_roles sr where sr.step_code=o.current_step_code and sr.role_code=any(ctx.roles) and sr.can_view)
      ))
    )
  )
$$;

create or replace function erp_supply.can_view_order_or_reception_shadow(p_order_id uuid)
returns boolean language sql stable security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select erp_supply.can_view_order(p_order_id) or exists(
    select 1 from erp_supply.orders o
    where o.id=p_order_id and o.organization_id=erp_supply.current_org_id() and not o.is_test
      and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')
      and erp_supply.has_role('coordinador_logistico')
  )
$$;

-- 3. El create RPC productivo conserva comportamiento normal salvo cuando el propio
-- certificador instala un contexto FLOW_ORDER autorizado. En ese caso nace TEST.
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
  v_qa_case_id uuid:=erp_supply.safe_uuid(nullif(current_setting('erp.qa_flow_create_case_id',true),''));
  v_qa_root_profile uuid:=erp_supply.safe_uuid(nullif(current_setting('erp.qa_flow_root_profile',true),''));
  v_qa_run_id uuid;
  v_qa_flow boolean:=false;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then
    raise exception 'Rol no autorizado para crear pedidos' using errcode='42501';
  end if;
  if v_qa_case_id is not null and v_qa_root_profile is not null then
    select c.qa_run_id into v_qa_run_id
    from erp_supply.qa_deep_cases c
    join erp_supply.qa_runs r on r.id=c.qa_run_id
    where c.id=v_qa_case_id and c.family='FLOW_ORDER' and c.status='PENDING'
      and r.status='RUNNING' and r.requested_by=v_qa_root_profile
      and r.organization_id=v_org
      and exists(
        select 1 from erp_supply.profile_roles rr
        join erp_supply.profiles rp on rp.id=rr.profile_id
        where rr.profile_id=v_qa_root_profile and rr.role_code='super_admin'
          and rp.active and rp.organization_id=v_org
      )
    limit 1;
    v_qa_flow:=v_qa_run_id is not null;
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
    ) || case when v_qa_flow then jsonb_build_object(
      'manualSandbox',true,'qaRobot',true,'qaFlowCertification',true,
      'qaCaseId',v_qa_case_id,'qaRobotVersion','10.25.7',
      'excludedFromProduction',true,'createdByQaSalesProfile',v_actor
    ) else '{}'::jsonb end;

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,
    source,is_history,is_test,qa_run_id,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),v_city,
    v_address,nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
    v_priority,v_requires_cut,v_requires_purchase,v_promised_at,v_requested_date,
    case when v_qa_flow then 'QA_BOT' else 'ERP' end,false,v_qa_flow,v_qa_run_id,v_metadata
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

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version,'qaFlow',v_qa_flow,'qaRunId',v_qa_run_id);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

-- 4. Los gates Sandbox necesarios para Corte aceptan únicamente contexto QA activo.
create or replace function erp_supply.require_sandbox_admin()
returns uuid language plpgsql stable security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_profile();
begin
  if not (erp_supply.has_role('super_admin') or erp_supply.qa_flow_context_active(null)) then
    raise exception 'El Modo Sandbox es exclusivo de Superadministración' using errcode='42501';
  end if;
  return v_actor;
end;
$$;

-- 5. Alistamiento TEST sigue sin consumir inventario, pero se prueba con aux_logistica.
create or replace function public.erp_x_confirm_picking_round(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_row jsonb;v_item erp_supply.order_items%rowtype;v_id uuid;v_result text;v_origins jsonb;v_allocations jsonb:='[]'::jsonb;v_alloc jsonb;v_result_payload jsonb;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(p_payload->'items','[]'::jsonb))<>'array' then raise exception 'Resultados de Alistamiento inválidos'; end if;
  if v_order.is_test then
    if not (erp_supply.has_role('super_admin') or erp_supply.qa_flow_context_active(v_order.id)) then raise exception 'Sandbox exclusivo de Superadministración' using errcode='42501'; end if;
    v_result_payload:=public.erp_x_confirm_picking_round_v10_8(p_order_id,p_payload);
    return v_result_payload||jsonb_build_object('inventoryAllocations','[]'::jsonb,'inventoryTraceVersion','SANDBOX_V10_16','sandbox',true);
  end if;
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select i.* into v_item from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=v_id and i.order_id=p_order_id and o.organization_id=v_org and erp_supply.can_view_order(o.id) and i.item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea de Alistamiento no disponible'; end if;if v_result='FOUND' and not v_item.requires_cut then perform erp_supply.validate_picking_origins(v_item,v_origins,false); end if;
  end loop;
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if v_result='FOUND' and not v_item.requires_cut then v_alloc:=erp_supply.consume_picking_origins(v_item,v_origins,v_actor);v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('orderItemId',v_item.id,'origins',v_alloc));end if;
  end loop;
  v_result_payload:=public.erp_x_confirm_picking_round_v10_8(p_order_id,p_payload);
  return v_result_payload||jsonb_build_object('inventoryAllocations',v_allocations,'inventoryTraceVersion','10.15');
end;
$$;

-- 6. Una etapa de certificación: crea como Ventas y después opera con el rol real.
create or replace function public.erp_x_qa_flow_execute_slice(p_case_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_super uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_case erp_supply.qa_deep_cases%rowtype;v_state erp_supply.qa_flow_case_state%rowtype;v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;
  v_spec jsonb;v_seed jsonb;v_expected_path jsonb;v_actual_path jsonb;v_step text;v_expected_next text;v_actual_next text;v_module text;v_required_action text;
  v_expected_profile uuid;v_expected_role text;v_actor uuid;v_actor_auth uuid;v_actor_name text;v_actual_role text;v_approver uuid;v_approver_auth uuid;v_cut_actor uuid;
  v_orig_sub text:=current_setting('request.jwt.claim.sub',true);v_orig_claims text:=current_setting('request.jwt.claims',true);v_claims jsonb;
  v_actions jsonb:='[]'::jsonb;v_permissions jsonb:='{}'::jsonb;v_domain jsonb;v_advanced boolean:=false;v_issue jsonb;v_issue_id uuid;v_req uuid;
  v_step_index int;v_before_status text;v_after_status text;v_started timestamptz:=clock_timestamp();v_error_state text;v_error_message text;v_cleanup_ok boolean:=true;v_cleanup_error text;
  v_group text;v_exec uuid;v_pickups jsonb;v_file uuid;
begin
  select c.* into v_case
  from erp_supply.qa_deep_cases c join erp_supply.qa_runs r on r.id=c.qa_run_id
  where c.id=p_case_id and c.family='FLOW_ORDER' and r.organization_id=v_org and r.run_type='TOTAL_ROBOT'
  for update of c;
  if not found then raise exception 'Caso de certificación de flujo no disponible'; end if;
  if v_case.status in('PASSED','FAILED') then return jsonb_build_object('caseId',v_case.id,'status',v_case.status,'completed',true,'errorMessage',v_case.error_message); end if;
  v_spec:=v_case.specification;

  select * into v_state from erp_supply.qa_flow_case_state where case_id=v_case.id for update;
  if not found then
    -- V10.25.7: la creación se prueba por la MISMA RPC productiva de Ventas.
    -- El contexto interno hace que el registro nazca como TEST-QA desde el INSERT,
    -- evitando cualquier instante productivo y conservando aislamiento total.
    begin
      v_actor:=erp_supply.qa_flow_profile_for_role(v_org,'ventas',null);
      if v_actor is null then raise exception 'CONFIG_QA: no existe usuario Ventas autenticado para crear el pedido'; end if;
      select auth_user_id,display_name into v_actor_auth,v_actor_name from erp_supply.profiles where id=v_actor;
      if v_actor_auth is null then raise exception 'CONFIG_QA: el usuario Ventas no está vinculado a Authentication'; end if;

      perform set_config('erp.qa_flow_create_case_id',v_case.id::text,true);
      perform set_config('erp.qa_flow_root_profile',v_super::text,true);
      perform set_config('request.jwt.claim.sub',v_actor_auth::text,true);
      perform set_config('request.jwt.claims',jsonb_build_object('sub',v_actor_auth::text,'role','authenticated')::text,true);

      v_seed:=public.erp_x_create_order(jsonb_build_object(
        'orderNumber','TEST-QA-'||to_char(clock_timestamp(),'YYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,5),
        'externalReference','FLOW-'||v_case.case_key,
        'orderType',v_spec->>'orderType','paymentCondition',v_spec->>'paymentCondition','deliveryRoute',v_spec->>'deliveryRoute',
        'clientName','CLIENTE ROBOT QA · NO PRODUCTIVO','clientDocument','QA-ROBOT',
        'clientCountry','Colombia','clientDepartment','Valle del Cauca','clientCity','Tuluá','clientAddress','Zona QA · dirección ficticia',
        'clientPhone','0000000000','priority','MEDIUM',
        'requiresCut',coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false),
        'requiresPurchase',coalesce(erp_supply.safe_boolean(v_spec->>'requiresPurchase'),false),
        'hasCreditArrears',coalesce(erp_supply.safe_boolean(v_spec->>'hasCreditArrears'),false),
        'heldByCashier',coalesce(erp_supply.safe_boolean(v_spec->>'heldByCashier'),false),
        'metadata',jsonb_build_object('qaSynthetic',true,'flowCaseKey',v_case.case_key),
        'items',jsonb_build_array(
          jsonb_build_object('lineNumber',1,'sku','QA-MAT-001','reference','QA-REF-001','description','Material sintético Robot QA','quantity',case when coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false) then 3 else 5 end,'unit',case when coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false) then 'M' else 'UND' end,'requiresCut',coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false),'requestedCutLength',case when coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false) then 25 else null end,'metadata',jsonb_build_object('sandbox',true,'synthetic',true,'qaRobot',true,'receptionActive',true)),
          jsonb_build_object('lineNumber',2,'sku','QA-MAT-002','reference','QA-REF-002','description','Segundo material sintético Robot QA','quantity',4,'unit','UND','requiresCut',false,'metadata',jsonb_build_object('sandbox',true,'synthetic',true,'qaRobot',true,'receptionActive',true))
        )
      ),'FLOW257-CREATE-'||v_case.id::text);

      perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
      perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);
      perform set_config('erp.qa_flow_create_case_id','',true);

      if erp_supply.safe_uuid(v_seed->>'orderId') is null or not coalesce((v_seed->>'qaFlow')::boolean,false) then
        raise exception 'La RPC de Ventas no creó un pedido TEST de certificación';
      end if;
      select * into v_order from erp_supply.orders where id=erp_supply.safe_uuid(v_seed->>'orderId') for update;
      if not v_order.is_test or v_order.source<>'QA_BOT' or v_order.qa_run_id is distinct from v_case.qa_run_id then
        raise exception 'Aislamiento QA inválido al crear el pedido desde Ventas';
      end if;
      v_expected_path:=erp_supply.qa_flow_expected_path(v_spec);
      insert into erp_supply.qa_flow_case_state(case_id,qa_run_id,order_id,order_number,expected_path,actual_path,current_step)
      values(v_case.id,v_case.qa_run_id,v_order.id,v_order.order_number,v_expected_path,jsonb_build_array(v_order.current_step_code),v_order.current_step_code)
      returning * into v_state;

      insert into erp_supply.qa_flow_step_audit(case_id,qa_run_id,order_id,order_number,step_index,step_code,module_code,expected_role_code,actual_role_code,actor_profile_id,actor_name,expected_next_step,actual_next_step,before_status,after_status,permissions,actions,status,duration_ms)
      values(v_case.id,v_case.qa_run_id,v_order.id,v_order.order_number,0,'SALES_CREATE','sales','ventas','ventas',v_actor,v_actor_name,v_order.current_step_code,v_order.current_step_code,null,v_order.status,
        jsonb_build_object('moduleRead',erp_supply.qa_flow_module_allowed('ventas','sales','read'),'moduleCreate',erp_supply.qa_flow_module_allowed('ventas','sales','create')),
        jsonb_build_array(jsonb_build_object('action','CREATE_ORDER','rpc','erp_x_create_order','actor',v_actor_name,'role','ventas','isTest',true)),
        'PASSED',greatest(0,round(extract(epoch from(clock_timestamp()-v_started))*1000)::int))
      on conflict(case_id,step_index) do nothing;
    exception when others then
      v_error_state:=sqlstate;v_error_message:=sqlerrm;
      perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
      perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);
      perform set_config('erp.qa_flow_create_case_id','',true);
      update erp_supply.qa_deep_cases
        set status='FAILED',error_sqlstate=v_error_state,error_message=v_error_message,
            result=jsonb_build_object('flowCertified',false,'failedStep','SALES_CREATE','module','sales','expectedRole','ventas','actorName',v_actor_name,'cleanupVerified',true),
            cleanup_verified=true,completed_at=now(),duration_ms=greatest(0,round(extract(epoch from(clock_timestamp()-coalesce(started_at,clock_timestamp())))*1000)::int)
      where id=v_case.id;
      insert into erp_supply.qa_flow_step_audit(case_id,qa_run_id,order_id,order_number,step_index,step_code,module_code,expected_role_code,actual_role_code,actor_profile_id,actor_name,permissions,actions,status,error_sqlstate,error_message,duration_ms)
      values(v_case.id,v_case.qa_run_id,null,null,0,'SALES_CREATE','sales','ventas','ventas',v_actor,v_actor_name,
        jsonb_build_object('moduleRead',erp_supply.qa_flow_module_allowed('ventas','sales','read'),'moduleCreate',erp_supply.qa_flow_module_allowed('ventas','sales','create')),
        jsonb_build_array(jsonb_build_object('action','CREATE_ORDER','rpc','erp_x_create_order')),'FAILED',v_error_state,v_error_message,
        greatest(0,round(extract(epoch from(clock_timestamp()-v_started))*1000)::int))
      on conflict(case_id,step_index) do update set status='FAILED',error_sqlstate=excluded.error_sqlstate,error_message=excluded.error_message,captured_at=now();
      return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','FAILED','completed',true,'failedStep','SALES_CREATE','module','sales','expectedRole','ventas','actorName',v_actor_name,'errorSqlstate',v_error_state,'errorMessage',v_error_message,'version','10.25.7');
    end;
  end if;

  select * into v_order from erp_supply.orders where id=v_state.order_id for update;
  if not found then raise exception 'El pedido TEST persistente del flujo ya no existe'; end if;
  if v_order.current_step_code='CLOSED' then raise exception 'Caso en CLOSED sin cierre de certificación'; end if;

  v_step:=v_order.current_step_code;v_step_index:=v_state.steps_executed+1;v_before_status:=v_order.status;
  v_expected_next:=v_state.expected_path->>v_step_index;
  select module_code into v_module from erp_supply.workflow_steps where code=v_step;
  v_required_action:=erp_supply.qa_flow_required_module_action(v_step);

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and step_code=v_step and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found then raise exception 'La etapa % no tiene tarea activa',v_step; end if;

  select profile_id,role_code into v_expected_profile,v_expected_role
  from erp_supply.resolve_assignment(v_order.organization_id,v_step,v_order.delivery_route_code,v_order.order_type_code);
  v_actual_role:=v_task.assigned_role_code;
  if v_expected_role is distinct from v_actual_role then
    raise exception 'ROUTING_ROLE_MISMATCH: % esperaba rol %, pero la tarea quedó en %',v_step,coalesce(v_expected_role,'NULL'),coalesce(v_actual_role,'NULL');
  end if;

  if v_task.assigned_profile_id is not null then
    v_actor:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,v_expected_role,v_task.assigned_profile_id);
    if v_actor is distinct from v_task.assigned_profile_id then
      raise exception 'ASSIGNEE_INVALID: la tarea % está asignada a un perfil sin rol/autenticación válida',v_step;
    end if;
  else
    v_actor:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,v_expected_role,v_expected_profile);
  end if;
  if v_actor is null then raise exception 'CONFIG_QA: no existe usuario activo autenticado para el rol % (%).',v_expected_role,v_step; end if;
  select auth_user_id,display_name into v_actor_auth,v_actor_name from erp_supply.profiles where id=v_actor;
  if v_actor_auth is null then raise exception 'CONFIG_QA: el usuario % no está vinculado a Authentication',coalesce(v_actor_name,v_actor::text); end if;

  v_permissions:=jsonb_build_object(
    'moduleRead',erp_supply.qa_flow_module_allowed(v_expected_role,v_module,'read'),
    'moduleMutation',erp_supply.qa_flow_module_allowed(v_expected_role,v_module,v_required_action),
    'canStart',erp_supply.actor_can(v_actor,v_step,'START',case when v_task.assigned_profile_id is null then v_actor else v_task.assigned_profile_id end),
    'canComplete',erp_supply.actor_can(v_actor,v_step,'COMPLETE',case when v_task.assigned_profile_id is null then v_actor else v_task.assigned_profile_id end),
    'canWait',erp_supply.actor_can(v_actor,v_step,'WAIT',case when v_task.assigned_profile_id is null then v_actor else v_task.assigned_profile_id end),
    'canResume',erp_supply.actor_can(v_actor,v_step,'RESUME',case when v_task.assigned_profile_id is null then v_actor else v_task.assigned_profile_id end)
  );
  if not coalesce((v_permissions->>'moduleRead')::boolean,false) then raise exception 'MODULE_PERMISSION: % no puede leer módulo %',v_expected_role,v_module; end if;
  if not coalesce((v_permissions->>'moduleMutation')::boolean,false) then raise exception 'MODULE_PERMISSION: % no puede operar módulo % (% requerido)',v_expected_role,v_module,v_required_action; end if;

  -- Contexto QA transaccional: habilita exclusivamente ESTE pedido TEST para
  -- el actor operativo del caso. Fuera de esta invocación sigue invisible.
  perform set_config('erp.qa_flow_case_id',v_case.id::text,true);
  perform set_config('erp.qa_flow_root_profile',v_super::text,true);

  -- Impersonación local: las RPC públicas anidadas ven el auth.uid() del usuario
  -- operativo real. El cambio vive únicamente dentro de esta transacción QA.
  v_claims:=jsonb_build_object('sub',v_actor_auth::text,'role','authenticated');
  perform set_config('request.jwt.claim.sub',v_actor_auth::text,true);
  perform set_config('request.jwt.claims',v_claims::text,true);

  begin
    if v_task.assigned_profile_id is null then
      perform public.erp_x_execute_action(v_order.id,'CLAIM','{}'::jsonb,null,'FLOW255-CLAIM-'||v_case.id::text||'-'||v_step_index::text);
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','CLAIM','actor',v_actor_name,'role',v_expected_role));
    end if;

    perform public.erp_x_execute_action(v_order.id,'START',jsonb_build_object('detail','QA flujo 10.25.5'),null,'FLOW255-START-'||v_case.id::text||'-'||v_step_index::text);
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','START','actor',v_actor_name,'role',v_expected_role));

    -- Filtros transversales reales en cada etapa: nota, novedad, reporte y espera.
    v_issue:=public.erp_x_create_order_issue(v_order.id,jsonb_build_object('type','NOTE','title','Nota QA flujo','detail','Prueba de nota transversal 10.25.5','sourceCode','QA_FLOW'));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','NOTE','actor',v_actor_name));

    v_issue:=public.erp_x_create_order_issue(v_order.id,jsonb_build_object('type','NOVELTY','title','Novedad QA flujo','detail','Prueba de novedad y resolución 10.25.5','sourceCode','QA_FLOW'));
    v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}');
    if v_issue_id is null then raise exception 'No se creó la NOVELTY en %',v_step; end if;
    perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Novedad resuelta por usuario QA del rol','resolutionCode','RESOLVED'));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','NOVELTY_RESOLVED','actor',v_actor_name));

    perform public.erp_x_execute_action(v_order.id,'START',jsonb_build_object('detail','Reactivar después de novedad'),null,'FLOW255-RESTART-NOV-'||v_case.id::text||'-'||v_step_index::text);

    v_issue:=public.erp_x_create_order_issue(v_order.id,jsonb_build_object('type','REPORT','title','Reporte QA flujo','detail','Prueba de reporte y escalamiento 10.25.5','targetRole','jefe_logistica','sourceCode','QA_FLOW'));
    v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}');
    if v_issue_id is null then raise exception 'No se creó el REPORT en %',v_step; end if;

    v_approver:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,'jefe_logistica',null);
    if v_approver is null then raise exception 'CONFIG_QA: no existe Jefe Logístico autenticado para resolver reportes'; end if;
    select auth_user_id into v_approver_auth from erp_supply.profiles where id=v_approver;
    perform set_config('request.jwt.claim.sub',v_approver_auth::text,true);
    perform set_config('request.jwt.claims',jsonb_build_object('sub',v_approver_auth::text,'role','authenticated')::text,true);
    perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Reporte resuelto por Jefatura en QA','resolutionCode','RESOLVED'));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','REPORT_RESOLVED','actorRole','jefe_logistica'));

    perform set_config('request.jwt.claim.sub',v_actor_auth::text,true);
    perform set_config('request.jwt.claims',v_claims::text,true);
    perform public.erp_x_execute_action(v_order.id,'START',jsonb_build_object('detail','Reactivar después de reporte'),null,'FLOW255-RESTART-REP-'||v_case.id::text||'-'||v_step_index::text);
    perform public.erp_x_execute_action(v_order.id,'WAIT',jsonb_build_object('reason','Prueba QA espera'),null,'FLOW255-WAIT-'||v_case.id::text||'-'||v_step_index::text);
    perform public.erp_x_execute_action(v_order.id,'RESUME',jsonb_build_object('detail','Prueba QA reanudar'),null,'FLOW255-RESUME-'||v_case.id::text||'-'||v_step_index::text);
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','WAIT_RESUME','actor',v_actor_name));

    -- Una aprobación real por pedido valida la ida al módulo Aprobaciones y regreso.
    if v_step_index=1 then
      perform public.erp_x_execute_action(v_order.id,'REQUEST_APPROVAL',jsonb_build_object('requestType','PRIORITY','priority','URGENT','reason','QA flujo valida aprobación','assignedRole','gerencia'),null,'FLOW255-PRIORITY-'||v_case.id::text);
      select id into v_req from erp_supply.approval_requests where order_id=v_order.id and request_type='PRIORITY' and status='PENDING' order by created_at desc limit 1;
      if v_req is null then raise exception 'No se creó la aprobación PRIORITY'; end if;
      v_approver:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,'gerencia',null);
      if v_approver is null then v_approver:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,'jefe_logistica',null); end if;
      if v_approver is null then raise exception 'CONFIG_QA: no existe Gerencia/Jefatura autenticada para decidir aprobación'; end if;
      select auth_user_id into v_approver_auth from erp_supply.profiles where id=v_approver;
      perform set_config('request.jwt.claim.sub',v_approver_auth::text,true);
      perform set_config('request.jwt.claims',jsonb_build_object('sub',v_approver_auth::text,'role','authenticated')::text,true);
      perform public.erp_x_decide_approval(v_req,'APPROVED','Aprobación QA de prioridad');
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','PRIORITY_APPROVED','approver',v_approver));
      perform set_config('request.jwt.claim.sub',v_actor_auth::text,true);
      perform set_config('request.jwt.claims',v_claims::text,true);
    end if;

    -- Corte paralelo se ejecuta con un usuario real del rol auxiliar_corte y
    -- después se devuelve la identidad al auxiliar de alistamiento.
    if v_step='ALISTAMIENTO' and v_order.requires_cut then
      v_cut_actor:=erp_supply.qa_flow_profile_for_role(v_order.organization_id,'auxiliar_corte',null);
      if v_cut_actor is null then raise exception 'CONFIG_QA: no existe Auxiliar de Corte autenticado'; end if;
      select auth_user_id into v_approver_auth from erp_supply.profiles where id=v_cut_actor;
      perform set_config('request.jwt.claim.sub',v_approver_auth::text,true);
      perform set_config('request.jwt.claims',jsonb_build_object('sub',v_approver_auth::text,'role','authenticated')::text,true);
      for v_group in select distinct group_key from erp_supply.cut_requirements where order_id=v_order.id and process_status<>'READY' order by group_key loop
        perform public.erp_x_cutting_start(v_group);
        select id into v_exec from erp_supply.cut_executions where organization_id=v_order.organization_id and group_key=v_group and status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE') order by started_at desc limit 1;
        if v_exec is null then raise exception 'Corte no creó ejecución para %',v_group; end if;
        if exists(select 1 from erp_supply.cut_executions where id=v_exec and status='IN_PROGRESS') then
          perform public.erp_x_cutting_pause(v_exec,'QA flujo prueba pausa');perform public.erp_x_cutting_resume(v_exec);
        end if;
        -- La simulación física Sandbox es deliberadamente una capacidad exclusiva
        -- de Super Admin; inicio/pausa/reanudación/cierre sí se prueban como auxiliar_corte.
        select auth_user_id into v_approver_auth from erp_supply.profiles where id=v_super;
        perform set_config('request.jwt.claim.sub',v_approver_auth::text,true);
        perform set_config('request.jwt.claims',jsonb_build_object('sub',v_approver_auth::text,'role','authenticated')::text,true);
        perform public.erp_x_sandbox_execute_cut_group(v_group,jsonb_build_object('reelLength',500,'scrapLength',1));
        perform public.erp_x_sandbox_cutting_evidence(v_exec,jsonb_build_object('fileName','qa-flow-cut.jpg','mimeType','image/jpeg','sizeBytes',128));
        select auth_user_id into v_approver_auth from erp_supply.profiles where id=v_cut_actor;
        perform set_config('request.jwt.claim.sub',v_approver_auth::text,true);
        perform set_config('request.jwt.claims',jsonb_build_object('sub',v_approver_auth::text,'role','authenticated')::text,true);
        perform public.erp_x_cutting_finalize(v_exec);
      end loop;
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','CUTTING_FULL','actorRole','auxiliar_corte'));
      perform set_config('request.jwt.claim.sub',v_actor_auth::text,true);perform set_config('request.jwt.claims',v_claims::text,true);
      select coalesce(jsonb_agg(id order by created_at),'[]'::jsonb) into v_pickups from erp_supply.cut_requirements where order_id=v_order.id and process_status='READY' and collection_status='PENDING';
      if jsonb_array_length(v_pickups)>0 then perform public.erp_x_confirm_cut_pickup(v_order.id,v_pickups); end if;
    end if;

    v_domain:=erp_supply.qa_execute_step_domain(v_order.id,v_step,v_actor,v_case.id);
    v_advanced:=coalesce((v_domain->>'advanced')::boolean,false);
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action',coalesce(v_domain->>'operation','DOMAIN'),'actor',v_actor_name,'role',v_expected_role));
    if not v_advanced then
      perform public.erp_x_execute_action(v_order.id,'COMPLETE',jsonb_build_object('detail','QA flujo completar etapa','qaDomain',v_domain),null,'FLOW255-COMPLETE-'||v_case.id::text||'-'||v_step_index::text);
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('action','COMPLETE','actor',v_actor_name));
    end if;

    -- Restaurar Super Admin antes de consultar/escribir el ledger QA.
    perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
    perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);

    select * into v_order from erp_supply.orders where id=v_order.id;
    v_actual_next:=v_order.current_step_code;v_after_status:=v_order.status;
    if v_actual_next is distinct from v_expected_next then
      raise exception 'ROUTE_MISMATCH: % debía avanzar a % y avanzó a %',v_step,coalesce(v_expected_next,'NULL'),coalesce(v_actual_next,'NULL');
    end if;

    insert into erp_supply.qa_flow_step_audit(case_id,qa_run_id,order_id,order_number,step_index,step_code,module_code,expected_role_code,actual_role_code,actor_profile_id,actor_name,expected_next_step,actual_next_step,before_status,after_status,permissions,actions,status,duration_ms)
    values(v_case.id,v_case.qa_run_id,v_order.id,v_state.order_number,v_step_index,v_step,v_module,v_expected_role,v_actual_role,v_actor,v_actor_name,v_expected_next,v_actual_next,v_before_status,v_after_status,v_permissions,v_actions,'PASSED',greatest(0,round(extract(epoch from(clock_timestamp()-v_started))*1000)::int))
    on conflict(case_id,step_index) do update set module_code=excluded.module_code,expected_role_code=excluded.expected_role_code,actual_role_code=excluded.actual_role_code,actor_profile_id=excluded.actor_profile_id,actor_name=excluded.actor_name,expected_next_step=excluded.expected_next_step,actual_next_step=excluded.actual_next_step,before_status=excluded.before_status,after_status=excluded.after_status,permissions=excluded.permissions,actions=excluded.actions,status='PASSED',error_sqlstate=null,error_message=null,duration_ms=excluded.duration_ms,captured_at=now();

    v_actual_path:=v_state.actual_path||jsonb_build_array(v_actual_next);
    update erp_supply.qa_flow_case_state set actual_path=v_actual_path,steps_executed=v_step_index,current_step=v_actual_next,updated_at=now() where case_id=v_case.id returning * into v_state;

    if v_actual_next='CLOSED' then
      begin perform public.erp_x_sandbox_delete(v_order.id); exception when others then v_cleanup_ok:=false;v_cleanup_error:=sqlstate||' · '||sqlerrm; end;
      if not v_cleanup_ok then raise exception 'CLEANUP_FAILED: %',v_cleanup_error; end if;
      update erp_supply.qa_flow_case_state set status='PASSED',completed_at=now(),updated_at=now() where case_id=v_case.id;
      update erp_supply.qa_deep_cases set status='PASSED',result=jsonb_build_object('flowCertified',true,'orderNumber',v_state.order_number,'expectedPath',v_state.expected_path,'actualPath',v_actual_path,'stepsExecuted',v_step_index,'cleanupVerified',true),cleanup_verified=true,completed_at=now(),duration_ms=greatest(0,round(extract(epoch from(clock_timestamp()-coalesce(started_at,clock_timestamp())))*1000)::int) where id=v_case.id;
      return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','PASSED','completed',true,'currentStep','CLOSED','orderNumber',v_state.order_number,'version','10.25.7');
    end if;

    update erp_supply.qa_deep_cases set status='PENDING',started_at=coalesce(started_at,now()),last_attempt_at=now(),attempt_count=coalesce(attempt_count,0)+1 where id=v_case.id;
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','PENDING','completed',false,'currentStep',v_actual_next,'stepsExecuted',v_step_index,'orderNumber',v_state.order_number,'version','10.25.7');

  exception when others then
    v_error_state:=sqlstate;v_error_message:=sqlerrm;
    perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
    perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);

    insert into erp_supply.qa_flow_step_audit(case_id,qa_run_id,order_id,order_number,step_index,step_code,module_code,expected_role_code,actual_role_code,actor_profile_id,actor_name,expected_next_step,actual_next_step,before_status,after_status,permissions,actions,status,error_sqlstate,error_message,duration_ms)
    values(v_case.id,v_case.qa_run_id,v_state.order_id,v_state.order_number,coalesce(v_step_index,v_state.steps_executed+1),coalesce(v_step,v_state.current_step,'UNKNOWN'),v_module,v_expected_role,v_actual_role,v_actor,v_actor_name,v_expected_next,v_actual_next,v_before_status,v_after_status,coalesce(v_permissions,'{}'::jsonb),coalesce(v_actions,'[]'::jsonb),'FAILED',v_error_state,v_error_message,greatest(0,round(extract(epoch from(clock_timestamp()-v_started))*1000)::int))
    on conflict(case_id,step_index) do update set module_code=excluded.module_code,expected_role_code=excluded.expected_role_code,actual_role_code=excluded.actual_role_code,actor_profile_id=excluded.actor_profile_id,actor_name=excluded.actor_name,expected_next_step=excluded.expected_next_step,actual_next_step=excluded.actual_next_step,before_status=excluded.before_status,after_status=excluded.after_status,permissions=excluded.permissions,actions=excluded.actions,status='FAILED',error_sqlstate=excluded.error_sqlstate,error_message=excluded.error_message,duration_ms=excluded.duration_ms,captured_at=now();

    begin if v_state.order_id is not null and exists(select 1 from erp_supply.orders where id=v_state.order_id) then perform public.erp_x_sandbox_delete(v_state.order_id); end if; exception when others then v_cleanup_ok:=false;v_cleanup_error:=sqlstate||' · '||sqlerrm; end;
    update erp_supply.qa_flow_case_state set status='FAILED',last_error=v_error_state||' · '||v_error_message,completed_at=now(),updated_at=now() where case_id=v_case.id;
    update erp_supply.qa_deep_cases set status='FAILED',error_sqlstate=v_error_state,error_message=v_error_message,result=jsonb_build_object('flowCertified',false,'failedStep',v_step,'module',v_module,'expectedRole',v_expected_role,'actualRole',v_actual_role,'actorProfileId',v_actor,'actorName',v_actor_name,'expectedNextStep',v_expected_next,'actualNextStep',v_actual_next,'permissions',v_permissions,'cleanupVerified',v_cleanup_ok,'cleanupError',v_cleanup_error),cleanup_verified=v_cleanup_ok,completed_at=now(),duration_ms=greatest(0,round(extract(epoch from(clock_timestamp()-coalesce(started_at,clock_timestamp())))*1000)::int) where id=v_case.id;
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','FAILED','completed',true,'failedStep',v_step,'module',v_module,'expectedRole',v_expected_role,'actorName',v_actor_name,'errorSqlstate',v_error_state,'errorMessage',v_error_message,'version','10.25.7');
  end;
end;
$$;

-- 7. Contrato del hotfix.
create or replace function public.erp_x_qa_flow_identity_contract()
returns jsonb language plpgsql stable security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_checks jsonb:='[]'::jsonb;v_ok boolean;
begin
  v_ok:=position('qa_flow_context_active' in pg_get_functiondef('erp_supply.can_view_order(uuid)'::regprocedure))>0;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','TEST_CONTEXT_VISIBILITY','success',v_ok));
  v_ok:=position('erp.qa_flow_case_id' in pg_get_functiondef('public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure))>0;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','FLOW_CONTEXT_INSTALLED','success',v_ok));
  v_ok:=position('erp_x_create_order' in pg_get_functiondef('public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure))>0
    and position('qa_flow_create_case_id' in pg_get_functiondef('public.erp_x_create_order(jsonb,text)'::regprocedure))>0;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','SALES_REAL_CREATE_RPC','success',v_ok));
  v_ok:=position('qa_flow_context_active' in pg_get_functiondef('public.erp_x_confirm_picking_round(uuid,jsonb)'::regprocedure))>0;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','PICKING_TEST_ROLE_ALLOWED','success',v_ok));
  return jsonb_build_object('success',not exists(select 1 from jsonb_array_elements(v_checks) x where not coalesce((x->>'success')::boolean,false)),'checks',v_checks,'version','10.25.7');
end;
$$;
revoke all on function public.erp_x_qa_flow_identity_contract() from public,anon;
grant execute on function public.erp_x_qa_flow_identity_contract() to authenticated;

notify pgrst,'reload schema';
commit;
