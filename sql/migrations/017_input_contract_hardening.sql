-- ERP Supply Enterprise V10
-- Migration 017: strict and friendly input contracts for creation, administration and credit.

begin;

create or replace function erp_supply.safe_boolean(p_value text,p_default boolean default null)
returns boolean
language sql
immutable
as $$
  select case lower(trim(coalesce(p_value,'')))
    when 'true' then true when 't' then true when '1' then true when 'yes' then true when 'si' then true when 'sí' then true
    when 'false' then false when 'f' then false when '0' then false when 'no' then false
    else p_default end
$$;

create or replace function erp_supply.safe_numeric(p_value text)
returns numeric
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;

create or replace function erp_supply.safe_integer(p_value text)
returns integer
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::integer;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;

create or replace function erp_supply.safe_date(p_value text)
returns date
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::date;
exception when invalid_datetime_format or datetime_field_overflow then return null;
end;
$$;

create or replace function erp_supply.safe_timestamptz(p_value text)
returns timestamptz
language plpgsql
stable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::timestamptz;
exception when invalid_datetime_format or datetime_field_overflow then return null;
end;
$$;

create or replace function erp_supply.safe_uuid(p_value text)
returns uuid
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::uuid;
exception when invalid_text_representation then return null;
end;
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
  v_quantity numeric;
  v_cut_length numeric;
  v_requested_date date;
  v_promised_at timestamptz;
  v_line integer:=0;
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

  for v_item in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_item)<>'object' then raise exception 'Cada línea del pedido debe ser un objeto'; end if;
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    if v_item_cut then v_requires_cut:=true; end if;
  end loop;

  v_initial:=erp_supply.initial_step(v_order_type,v_payment,v_requires_purchase);

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),nullif(trim(p_payload->>'clientCity'),''),
    nullif(trim(p_payload->>'clientAddress'),''),nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
    v_priority,v_requires_cut,v_requires_purchase,v_promised_at,v_requested_date,
    case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end
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
    v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,p_payload
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_admin_save_profile(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile erp_supply.profiles%rowtype;
  v_profile_id uuid:=erp_supply.safe_uuid(p_payload->>'id');
  v_auth_id uuid:=erp_supply.safe_uuid(p_payload->>'authUserId');
  v_email text:=lower(nullif(trim(p_payload->>'email'),''));
  v_name text:=nullif(trim(p_payload->>'name'),'');
  v_active boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'active',true),true);
  v_roles jsonb:=coalesce(p_payload->'roles','[]'::jsonb);
  v_role text;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede administrar usuarios' using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Perfil inválido'; end if;
  if v_email is null or position('@' in v_email)<=1 then raise exception 'Correo inválido'; end if;
  if v_name is null then raise exception 'Nombre requerido'; end if;
  if (p_payload ? 'id') and nullif(trim(p_payload->>'id'),'') is not null and v_profile_id is null then raise exception 'ID de perfil inválido'; end if;
  if (p_payload ? 'authUserId') and nullif(trim(p_payload->>'authUserId'),'') is not null and v_auth_id is null then raise exception 'Auth User UUID inválido'; end if;
  if v_auth_id is not null and not exists(select 1 from auth.users where id=v_auth_id) then raise exception 'El UUID no corresponde a un usuario de Supabase Auth'; end if;
  if jsonb_typeof(v_roles)<>'array' then raise exception 'La lista de roles es inválida'; end if;
  if v_active and jsonb_array_length(v_roles)=0 then raise exception 'Un usuario activo debe tener al menos un rol'; end if;

  if v_profile_id is null then
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active)
    values(v_org,v_auth_id,v_email,v_name,nullif(trim(p_payload->>'employeeCode'),''),v_active)
    returning * into v_profile;
  else
    update erp_supply.profiles
    set auth_user_id=coalesce(v_auth_id,auth_user_id),email=v_email,display_name=v_name,
        employee_code=nullif(trim(p_payload->>'employeeCode'),''),active=v_active
    where id=v_profile_id and organization_id=v_org
    returning * into v_profile;
    if not found then raise exception 'Perfil no encontrado'; end if;
  end if;

  for v_role in select value#>>'{}' from jsonb_array_elements(v_roles) loop
    if not exists(select 1 from erp_supply.roles where code=v_role and active) then raise exception 'Rol inválido: %',v_role; end if;
  end loop;

  delete from erp_supply.profile_roles where profile_id=v_profile.id;
  for v_role in select value#>>'{}' from jsonb_array_elements(v_roles) loop
    insert into erp_supply.profile_roles(profile_id,role_code,is_primary,granted_by)
    values(v_profile.id,v_role,not exists(select 1 from erp_supply.profile_roles where profile_id=v_profile.id),erp_supply.current_profile_id());
  end loop;
  return jsonb_build_object('success',true,'profile',to_jsonb(v_profile));
exception
  when unique_violation then raise exception 'Ya existe un perfil con ese correo o usuario Auth';
end;
$$;

create or replace function public.erp_x_credit_create(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_req erp_supply.credit_requests%rowtype;
  v_number text;
  v_client text:=nullif(trim(p_payload->>'clientName'),'');
  v_amount numeric:=erp_supply.safe_numeric(p_payload->>'requestedAmount');
  v_term integer:=erp_supply.safe_integer(p_payload->>'requestedTermDays');
begin
  if not erp_supply.can_access_module('credit','create') then raise exception 'No autorizado para crear crédito' using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Solicitud de crédito inválida'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if v_amount is null or v_amount<=0 then raise exception 'Valor solicitado inválido'; end if;
  if v_term is null or v_term<=0 then raise exception 'Plazo solicitado inválido'; end if;
  v_number:=coalesce(nullif(trim(p_payload->>'requestNumber'),''),'CR-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
  insert into erp_supply.credit_requests(
    organization_id,request_number,client_name,client_document,requested_amount,requested_term_days,status,requested_by,metadata
  ) values(
    v_org,v_number,v_client,nullif(trim(p_payload->>'clientDocument'),''),v_amount,v_term,'SUBMITTED',v_actor,
    case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end
  ) returning * into v_req;
  return jsonb_build_object('success',true,'request',to_jsonb(v_req));
exception
  when unique_violation then raise exception 'Ya existe una solicitud con el número %',v_number;
end;
$$;

-- Final permission reconciliation after the hardening migration.
do $$
declare r record;
begin
  revoke all on schema erp_supply from public,anon,authenticated;
  for r in
    select p.oid::regprocedure sig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'erp_x_%'
  loop
    execute format('revoke all on function %s from public,anon,authenticated',r.sig);
    execute format('grant execute on function %s to authenticated',r.sig);
  end loop;
end $$;

commit;
