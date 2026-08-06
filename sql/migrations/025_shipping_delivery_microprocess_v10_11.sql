begin;

-- V10.11 · Despachos y entregas guiados.
-- Mantiene dos etapas medibles: despacho/ruta y cierre de entrega.

create table if not exists erp_supply.delivery_milestones (
  id bigint generated always as identity primary key,
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  delivery_id uuid references erp_supply.deliveries(id) on delete set null,
  milestone_code text not null check (milestone_code in (
    'GUIDE_ADDED','LOCATION_CAPTURED','DISPATCHED','CLOSURE_ASSIGNED',
    'DELIVERY_EVIDENCE_UPLOADED','DELIVERED','NO_DELIVERY_REPORTED'
  )),
  occurred_at timestamptz not null default now(),
  actor_profile_id uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb
);

create index if not exists idx_delivery_milestones_order_time
  on erp_supply.delivery_milestones(order_id,occurred_at);

-- La misma persona que despacha puede realizar el cierre final.
insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
values
  ('CLOSURE','coordinador_logistico',true,true,false,true,true,true,false),
  ('CLOSURE','despacho_nacional',true,true,false,true,true,true,false)
on conflict(step_code,role_code) do update set
  can_view=excluded.can_view,can_claim=excluded.can_claim,can_start=excluded.can_start,
  can_complete=excluded.can_complete,can_block=excluded.can_block;

-- Ventas solo consulta el módulo para reportar novedades de no entrega.
insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('ventas','shipping',true,false,false,false,false)
on conflict(role_code,module_code) do update set can_read=true,can_create=false,can_update=false;

create or replace function public.erp_x_shipping_save_guide(p_order_id uuid,p_payload jsonb)
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
  v_tracking text:=nullif(trim(p_payload->>'trackingNumber'),'');
  v_carrier text:=nullif(trim(p_payload->>'carrier'),'');
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para gestionar despachos' using errcode='42501';
  end if;
  if v_tracking is null then raise exception 'Número de guía requerido'; end if;

  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
    raise exception 'El pedido no está en una etapa de despacho';
  end if;
  select * into v_task from erp_supply.order_tasks
  where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El pedido está asignado a otra persona' using errcode='42501';
  end if;

  select * into v_delivery from erp_supply.deliveries
  where order_id=p_order_id and status not in('CANCELLED')
  order by created_at desc limit 1 for update;
  if not found then
    insert into erp_supply.deliveries(order_id,route_code,status,carrier,tracking_number,assigned_profile_id,metadata)
    values(p_order_id,v_order.delivery_route_code,'PLANNED',v_carrier,v_tracking,v_actor,
      jsonb_build_object('taskId',v_task.id,'guideAddedAt',now(),'guideFileId',p_payload->>'guideFileId'))
    returning * into v_delivery;
  else
    update erp_supply.deliveries set
      carrier=v_carrier,tracking_number=v_tracking,assigned_profile_id=v_actor,
      metadata=metadata||jsonb_build_object('taskId',v_task.id,'guideAddedAt',now(),'guideFileId',p_payload->>'guideFileId'),
      updated_at=now()
    where id=v_delivery.id returning * into v_delivery;
  end if;

  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'GUIDE_ADDED',v_actor,jsonb_build_object('trackingNumber',v_tracking,'carrier',v_carrier,'guideFileId',p_payload->>'guideFileId'));
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','SHIPPING_GUIDE',v_order.current_step_code,v_order.current_step_code,v_order.status,v_order.status,v_actor,(erp_supply.current_roles())[1],jsonb_build_object('trackingNumber',v_tracking,'carrier',v_carrier));
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery));
end;
$$;

create or replace function public.erp_x_shipping_save_location(p_order_id uuid,p_payload jsonb)
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
  v_lat numeric;
  v_lon numeric;
  v_alt numeric;
  v_accuracy numeric;
  v_destination jsonb;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para gestionar despachos' using errcode='42501';
  end if;
  begin
    v_lat:=(p_payload->>'latitude')::numeric;
    v_lon:=(p_payload->>'longitude')::numeric;
    v_alt:=nullif(p_payload->>'altitude','')::numeric;
    v_accuracy:=nullif(p_payload->>'accuracy','')::numeric;
  exception when others then raise exception 'Coordenadas inválidas'; end;
  if v_lat not between -90 and 90 or v_lon not between -180 and 180 then raise exception 'Coordenadas fuera de rango'; end if;
  if nullif(trim(p_payload->>'municipality'),'') is null then raise exception 'Municipio requerido'; end if;
  if nullif(trim(p_payload->>'address'),'') is null then raise exception 'Dirección requerida'; end if;
  if nullif(trim(p_payload->>'placeLabel'),'') is null then raise exception 'Lugar o punto de referencia requerido'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'El pedido no está en despacho'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El pedido está asignado a otra persona' using errcode='42501'; end if;

  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1 for update;
  if not found or nullif(trim(v_delivery.tracking_number),'') is null then raise exception 'Primero debes registrar la guía'; end if;
  v_destination:=jsonb_build_object(
    'placeLabel',trim(p_payload->>'placeLabel'),'municipality',trim(p_payload->>'municipality'),
    'department',nullif(trim(p_payload->>'department'),''),'address',trim(p_payload->>'address'),
    'latitude',v_lat,'longitude',v_lon,'altitude',v_alt,'accuracy',v_accuracy,
    'source',coalesce(nullif(p_payload->>'source',''),'DEVICE_GEOLOCATION'),'capturedAt',now()
  );
  update erp_supply.deliveries set metadata=metadata||jsonb_build_object('destination',v_destination,'locationCapturedAt',now()),updated_at=now()
  where id=v_delivery.id returning * into v_delivery;

  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'LOCATION_CAPTURED',v_actor,v_destination);
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','SHIPPING_LOCATION',v_order.current_step_code,v_order.current_step_code,v_order.status,v_order.status,v_actor,(erp_supply.current_roles())[1],v_destination);
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery));
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
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para gestionar despachos' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'El pedido no está en despacho'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El pedido está asignado a otra persona' using errcode='42501'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1 for update;
  if not found or nullif(trim(v_delivery.tracking_number),'') is null then raise exception 'Falta registrar la guía'; end if;
  if nullif(v_delivery.metadata#>>'{destination,municipality}','') is null or nullif(v_delivery.metadata#>>'{destination,address}','') is null then raise exception 'Falta confirmar el lugar de entrega'; end if;

  update erp_supply.deliveries set status='IN_TRANSIT',dispatched_at=coalesce(dispatched_at,now()),assigned_profile_id=v_actor,
    metadata=metadata||jsonb_build_object('sentToClosureAt',now()),updated_at=now()
  where id=v_delivery.id returning * into v_delivery;
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'DISPATCHED',v_actor,jsonb_build_object('trackingNumber',v_delivery.tracking_number,'route',v_order.delivery_route_code));

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

create or replace function public.erp_x_shipping_register_evidence(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_delivery erp_supply.deliveries%rowtype;v_file erp_supply.drive_files%rowtype;
  v_file_id uuid;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para cerrar entregas' using errcode='42501'; end if;
  begin v_file_id:=(p_payload->>'fileId')::uuid; exception when others then raise exception 'Archivo de evidencia inválido'; end;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code<>'CLOSURE' then raise exception 'El pedido no está en cierre'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='CLOSURE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El pedido está asignado a otra persona' using errcode='42501'; end if;
  select * into v_file from erp_supply.drive_files where id=v_file_id and order_id=p_order_id and task_id=v_task.id and file_category='DELIVERY_EVIDENCE';
  if not found then raise exception 'No se encontró la foto cargada para este cierre'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1 for update;
  if not found then raise exception 'No existe un despacho registrado'; end if;
  update erp_supply.deliveries set metadata=metadata||jsonb_build_object('deliveryEvidenceFileId',v_file.id,'deliveryEvidenceAt',now()),updated_at=now() where id=v_delivery.id returning * into v_delivery;
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'DELIVERY_EVIDENCE_UPLOADED',v_actor,jsonb_build_object('fileId',v_file.id,'fileName',v_file.file_name));
  return jsonb_build_object('success',true,'file',to_jsonb(v_file),'delivery',to_jsonb(v_delivery));
end;
$$;

create or replace function public.erp_x_shipping_finalize(p_order_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_delivery erp_supply.deliveries%rowtype;v_result jsonb;v_file_id uuid;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para finalizar entregas' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or v_order.current_step_code<>'CLOSURE' then raise exception 'El pedido no está en cierre'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='CLOSURE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El pedido está asignado a otra persona' using errcode='42501'; end if;
  select f.id into v_file_id from erp_supply.drive_files f where f.order_id=p_order_id and f.task_id=v_task.id and f.file_category='DELIVERY_EVIDENCE' order by f.created_at desc limit 1;
  if v_file_id is null then raise exception 'Debes subir la foto de entrega antes de finalizar'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1 for update;
  if not found then raise exception 'No existe un despacho registrado'; end if;
  update erp_supply.deliveries set status='DELIVERED',delivered_at=now(),received_by=nullif(trim(p_payload->>'receivedBy'),''),assigned_profile_id=v_actor,
    metadata=metadata||jsonb_build_object('finalizedAt',now(),'deliveryEvidenceFileId',v_file_id),updated_at=now()
  where id=v_delivery.id returning * into v_delivery;
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'DELIVERED',v_actor,jsonb_build_object('receivedBy',v_delivery.received_by,'evidenceFileId',v_file_id));
  v_result:=erp_supply.execute_action_internal(p_order_id,'COMPLETE',jsonb_build_object('detail','Pedido entregado y finalizado','resultCode','DELIVERED','deliveryId',v_delivery.id,'evidenceFileId',v_file_id),v_actor,false,v_order.version,gen_random_uuid()::text);
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery),'workflow',v_result);
end;
$$;

create or replace function public.erp_x_shipping_sent_orders(p_search text default null,p_page integer default 1,p_page_size integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,30),1),100);v_total bigint;v_items jsonb;
begin
  if not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then raise exception 'Solo Ventas o Superadministración pueden consultar pedidos enviados' using errcode='42501'; end if;
  select count(*) into v_total
  from erp_supply.orders o
  join lateral(select d.* from erp_supply.deliveries d where d.order_id=o.id and d.dispatched_at is not null order by d.created_at desc limit 1)d on true
  where o.organization_id=v_org and not o.is_test and (erp_supply.has_role('super_admin') or o.seller_profile_id=v_actor)
    and (p_search is null or lower(o.order_number||' '||o.client_name||' '||coalesce(d.tracking_number,'')) like '%'||lower(p_search)||'%');

  select coalesce(jsonb_agg(to_jsonb(x) order by x."dispatchedAt" desc),'[]'::jsonb) into v_items from(
    select o.id,o.order_number "orderNumber",o.client_name "clientName",o.priority,o.delivery_route_code route,o.current_step_code "currentStep",o.status,
      d.status "deliveryStatus",d.tracking_number "trackingNumber",d.carrier,d.dispatched_at "dispatchedAt",d.delivered_at "deliveredAt",
      d.metadata#>>'{destination,municipality}' municipality,d.metadata#>>'{destination,address}' address,
      coalesce(p.display_name,sp.display_name) "assigneeName",
      (d.status='NOT_DELIVERED' or lower(coalesce(o.metadata->>'deliveryExceptionOpen','false'))='true') "hasNoDelivery",
      (d.status in('DISPATCHED','IN_TRANSIT','REPROGRAMMED') and o.status<>'CLOSED') "canReportNoDelivery"
    from erp_supply.orders o
    join lateral(select dl.* from erp_supply.deliveries dl where dl.order_id=o.id and dl.dispatched_at is not null order by dl.created_at desc limit 1)d on true
    left join erp_supply.profiles p on p.id=d.assigned_profile_id
    left join erp_supply.profiles sp on sp.id=o.seller_profile_id
    where o.organization_id=v_org and not o.is_test and (erp_supply.has_role('super_admin') or o.seller_profile_id=v_actor)
      and (p_search is null or lower(o.order_number||' '||o.client_name||' '||coalesce(d.tracking_number,'')) like '%'||lower(p_search)||'%')
    order by d.dispatched_at desc offset(v_page-1)*v_size limit v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_shipping_report_no_delivery(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_delivery erp_supply.deliveries%rowtype;v_task erp_supply.order_tasks%rowtype;
  v_reason text:=nullif(trim(p_payload->>'reason'),'');v_action text:=coalesce(nullif(p_payload->>'requestedAction',''),'REVIEW');v_previous text;
begin
  if not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501'; end if;
  if v_reason is null then raise exception 'Motivo de no entrega requerido'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org for update;
  if not found or (not erp_supply.has_role('super_admin') and v_order.seller_profile_id is distinct from v_actor) then raise exception 'Pedido no disponible para este asesor' using errcode='42501'; end if;
  select * into v_delivery from erp_supply.deliveries where order_id=p_order_id and dispatched_at is not null order by created_at desc limit 1 for update;
  if not found then raise exception 'El pedido todavía no figura como enviado'; end if;
  if v_delivery.status='DELIVERED' or v_order.status='CLOSED' then raise exception 'El pedido ya fue finalizado y no admite una no entrega'; end if;
  v_previous:=v_delivery.status;
  update erp_supply.deliveries set status='NOT_DELIVERED',no_delivery_reason=v_reason,
    metadata=metadata||jsonb_build_object('previousStatus',v_previous,'noDeliveryReportedAt',now(),'requestedAction',v_action,'reportedByRole',(erp_supply.current_roles())[1]),updated_at=now()
  where id=v_delivery.id returning * into v_delivery;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('deliveryExceptionOpen',true,'noDeliveryReason',v_reason,'noDeliveryRequestedAction',v_action,'noDeliveryReportedAt',now()),updated_at=now(),version=version+1 where id=p_order_id returning * into v_order;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
  if found and v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH','CLOSURE') then
    update erp_supply.task_sessions s set ended_at=now(),raw_seconds=greatest(0,extract(epoch from(now()-s.started_at))::bigint),business_seconds=erp_supply.business_seconds_between(v_org,s.started_at,now()) where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=v_reason,metadata=metadata||jsonb_build_object('requestedAction',v_action) where id=v_task.id;
    update erp_supply.orders set status='WAITING',version=version+1 where id=p_order_id returning * into v_order;
  end if;
  insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
  values(p_order_id,v_actor,'NOVELTY','ORDER',v_reason,jsonb_build_object('type','NO_DELIVERY','requestedAction',v_action,'deliveryId',v_delivery.id));
  insert into erp_supply.delivery_milestones(organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata)
  values(v_org,p_order_id,v_task.id,v_delivery.id,'NO_DELIVERY_REPORTED',v_actor,jsonb_build_object('reason',v_reason,'requestedAction',v_action,'previousStatus',v_previous));
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','NO_DELIVERY',v_order.current_step_code,v_order.current_step_code,v_previous,'NOT_DELIVERED',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('reason',v_reason,'requestedAction',v_action,'deliveryId',v_delivery.id));
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery),'order',to_jsonb(v_order));
end;
$$;

-- Regla de seguridad: la acción genérica NO_DELIVERY queda limitada a Ventas/Superadministración.
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
  if v_action='NO_DELIVERY' and not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501'; end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then raise exception 'No autorizado para reprogramar' using errcode='42501'; end if;
  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(p_payload->>'requestType',''));
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then raise exception 'Tipo de solicitud inválido'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if v_type='PRIORITY' and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
    if v_type='ROUTE_CHANGE' and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then raise exception 'Ruta inválida'; end if;
  end if;
  return erp_supply.execute_action_internal(p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

-- La función heredada tampoco permite que Logística marque una no entrega.
create or replace function public.erp_x_save_delivery(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_delivery erp_supply.deliveries%rowtype;v_status text:=upper(coalesce(p_payload->>'status','PLANNED'));
begin
  if v_status='NOT_DELIVERED' then
    if not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501'; end if;
  elsif not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para despacho' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  if v_status not in('PLANNED','DISPATCHED','IN_TRANSIT','DELIVERED','NOT_DELIVERED','REPROGRAMMED','CANCELLED') then raise exception 'Estado de entrega inválido'; end if;
  if v_status='NOT_DELIVERED' and nullif(trim(p_payload->>'noDeliveryReason'),'') is null then raise exception 'Debe registrar el motivo de no entrega'; end if;
  insert into erp_supply.deliveries(order_id,route_code,status,scheduled_at,dispatched_at,delivered_at,received_by,no_delivery_reason,carrier,tracking_number,assigned_profile_id,metadata)
  values(p_order_id,v_order.delivery_route_code,v_status,nullif(p_payload->>'scheduledAt','')::timestamptz,nullif(p_payload->>'dispatchedAt','')::timestamptz,case when v_status='DELIVERED' then coalesce(nullif(p_payload->>'deliveredAt','')::timestamptz,now()) else nullif(p_payload->>'deliveredAt','')::timestamptz end,p_payload->>'receivedBy',p_payload->>'noDeliveryReason',p_payload->>'carrier',p_payload->>'trackingNumber',v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_delivery;
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery));
end;
$$;

-- Expediente con hitos y tiempos productivos/transcurridos por despacho y cierre.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;
begin
  perform erp_supply.require_profile();
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb) from erp_supply.order_items i where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'metadata',c.metadata,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'cutRequirements',(select coalesce(jsonb_agg(to_jsonb(r) order by i.line_number),'[]'::jsonb) from erp_supply.cut_requirements r join erp_supply.order_items i on i.id=r.order_item_id where r.order_id=p_order_id),
    'cutBatches',(select coalesce(jsonb_agg(to_jsonb(b) order by b.executed_at),'[]'::jsonb) from erp_supply.cut_batches b where exists(select 1 from erp_supply.cut_requirements r where r.cut_batch_id=b.id and r.order_id=p_order_id)),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'deliveryMilestones',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'code',m.milestone_code,'occurredAt',m.occurred_at,'actorName',p.display_name,'metadata',m.metadata) order by m.occurred_at),'[]'::jsonb) from erp_supply.delivery_milestones m left join erp_supply.profiles p on p.id=m.actor_profile_id where m.order_id=p_order_id),
    'deliveryTimeTrace',(select jsonb_build_object(
      'dispatchBusinessSeconds',coalesce(sum(t.business_seconds) filter(where t.step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH')),0),
      'dispatchElapsedSeconds',coalesce(sum(t.raw_seconds) filter(where t.step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH')),0),
      'dispatchQueueBusinessSeconds',coalesce(sum(erp_supply.business_seconds_between(v_org,t.created_at,coalesce(t.started_at,t.completed_at,now()))) filter(where t.step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH')),0),
      'closureBusinessSeconds',coalesce(sum(t.business_seconds) filter(where t.step_code='CLOSURE'),0),
      'closureElapsedSeconds',coalesce(sum(t.raw_seconds) filter(where t.step_code='CLOSURE'),0),
      'closureQueueBusinessSeconds',coalesce(sum(erp_supply.business_seconds_between(v_org,t.created_at,coalesce(t.started_at,t.completed_at,now()))) filter(where t.step_code='CLOSURE'),0),
      'transitBusinessSeconds',coalesce((select erp_supply.business_seconds_between(v_org,d.dispatched_at,coalesce(d.delivered_at,now())) from erp_supply.deliveries d where d.order_id=p_order_id and d.dispatched_at is not null order by d.created_at desc limit 1),0),
      'transitElapsedSeconds',coalesce((select greatest(0,extract(epoch from(coalesce(d.delivered_at,now())-d.dispatched_at))::bigint) from erp_supply.deliveries d where d.order_id=p_order_id and d.dispatched_at is not null order by d.created_at desc limit 1),0),
      'productiveBusinessSeconds',coalesce(sum(t.business_seconds),0),
      'flowBusinessSeconds',erp_supply.business_seconds_between(v_org,v_order.created_at,coalesce(v_order.closed_at,now())),
      'totalElapsedSeconds',greatest(0,extract(epoch from(coalesce(v_order.closed_at,now())-v_order.created_at))::bigint),
      'deadBusinessSeconds',greatest(0,erp_supply.business_seconds_between(v_org,v_order.created_at,coalesce(v_order.closed_at,now()))-coalesce(sum(t.business_seconds),0)),
      'deadTimeSeconds',greatest(0,erp_supply.business_seconds_between(v_org,v_order.created_at,coalesce(v_order.closed_at,now()))-coalesce(sum(t.business_seconds),0))
    ) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'pickingRounds',(select coalesce(jsonb_agg(to_jsonb(r) order by r.round_no),'[]'::jsonb) from erp_supply.picking_rounds r where r.order_id=p_order_id),
    'pickingRoundItems',(select coalesce(jsonb_agg(to_jsonb(ri) order by r.round_no,i.line_number),'[]'::jsonb) from erp_supply.picking_round_items ri join erp_supply.picking_rounds r on r.id=ri.picking_round_id join erp_supply.order_items i on i.id=ri.order_item_id where r.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

-- Oculta el esquema interno y reconcilia permisos para los RPC nuevos.
revoke all on table erp_supply.delivery_milestones from public,anon,authenticated;
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig); end loop;
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('grant execute on function %s to authenticated',r.sig); end loop;
end $$;

notify pgrst,'reload schema';
commit;
