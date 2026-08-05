-- ERP Supply Enterprise V10
-- Migration 004: browser-facing native Supabase RPC API.

begin;

create or replace function public.erp_x_session()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_profile erp_supply.profiles%rowtype; v_roles text[]; v_modules jsonb; v_org erp_supply.organizations%rowtype;
begin
  select * into v_profile from erp_supply.profiles where auth_user_id=auth.uid() and active limit 1;
  if not found then raise exception 'Usuario sin perfil operativo activo' using errcode='42501'; end if;
  select * into v_org from erp_supply.organizations where id=v_profile.organization_id;
  v_roles:=erp_supply.current_roles();
  select coalesce(jsonb_agg(x.obj order by x.sort_order),'[]'::jsonb) into v_modules from (
    select m.sort_order,jsonb_build_object('code',m.code,'name',m.name,'description',m.description,'icon',m.icon,'sortOrder',m.sort_order,
      'canRead',bool_or(mp.can_read),'canCreate',bool_or(mp.can_create),'canUpdate',bool_or(mp.can_update),'canApprove',bool_or(mp.can_approve),'canAdmin',bool_or(mp.can_admin)) obj
    from erp_supply.modules m join erp_supply.role_module_permissions mp on mp.module_code=m.code and mp.role_code=any(v_roles)
    where m.active group by m.code,m.name,m.description,m.icon,m.sort_order
  ) x;
  return jsonb_build_object(
    'profile',jsonb_build_object('id',v_profile.id,'email',v_profile.email,'name',v_profile.display_name,'employeeCode',v_profile.employee_code,'roles',v_roles,'preferences',v_profile.preferences),
    'organization',jsonb_build_object('id',v_org.id,'code',v_org.code,'name',v_org.name,'timezone',v_org.timezone,'settings',v_org.settings),
    'modules',v_modules,
    'catalogs',jsonb_build_object(
      'orderTypes',(select jsonb_agg(to_jsonb(t) order by sort_order) from erp_supply.order_types t where active),
      'paymentConditions',(select jsonb_agg(to_jsonb(p) order by sort_order) from erp_supply.payment_conditions p where active),
      'deliveryRoutes',(select jsonb_agg(to_jsonb(r) order by sort_order) from erp_supply.delivery_routes r where active),
      'steps',(select jsonb_agg(to_jsonb(s) order by sort_order) from erp_supply.workflow_steps s where active),
      'priorities',jsonb_build_array('LOW','MEDIUM','HIGH','URGENT','CRITICAL')
    ),
    'serverTime',now()
  );
end;
$$;

create or replace function public.erp_x_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile();
begin
  return jsonb_build_object(
    'kpis',jsonb_build_object(
      'activeOrders',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and status not in('CLOSED','CANCELLED')),
      'closedToday',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and closed_at::date=current_date),
      'critical',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and priority in('URGENT','CRITICAL') and status not in('CLOSED','CANCELLED')),
      'blocked',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and status='BLOCKED'),
      'myTasks',(select count(*) from erp_supply.order_tasks t join erp_supply.orders o on o.id=t.order_id where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) and t.assigned_profile_id=v_profile and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')),
      'pendingApprovals',(select count(*) from erp_supply.approval_requests a where a.organization_id=v_org and a.status='PENDING' and (a.assigned_profile_id=v_profile or a.assigned_role_code=any(erp_supply.current_roles())))
    ),
    'queues',(select coalesce(jsonb_agg(q order by (q->>'sortOrder')::int),'[]'::jsonb) from (
      select jsonb_build_object('stepCode',s.code,'name',s.name,'sortOrder',s.sort_order,'quantity',count(o.id),
        'overdue',count(o.id) filter(where s.sla_hours is not null and erp_supply.business_seconds_between(v_org,o.updated_at,now())>s.sla_hours*3600),
        'inProgress',count(o.id) filter(where o.status='IN_PROGRESS'),'waiting',count(o.id) filter(where o.status in('WAITING','BLOCKED'))
      ) q
      from erp_supply.workflow_steps s left join erp_supply.orders o on o.current_step_code=s.code and o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) and o.status not in('CLOSED','CANCELLED')
      where not s.terminal group by s.code,s.name,s.sort_order,s.sla_hours
    ) z),
    'recent',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
      select o.id,o.order_number "orderNumber",o.client_name "clientName",o.order_type_code "orderType",o.current_step_code "currentStep",o.status,o.priority,o.updated_at "updatedAt"
      from erp_supply.orders o where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) order by o.updated_at desc limit 12
    ) x),
    'generatedAt',now()
  );
end;
$$;

create or replace function public.erp_x_list_orders(
  p_search text default null,
  p_step text default null,
  p_status text default null,
  p_order_type text default null,
  p_route text default null,
  p_assignment text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 50,
  p_include_history boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),250); v_total bigint; v_items jsonb;
begin
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o
    left join erp_supply.profiles p on p.id=o.current_assignee_id
    join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
  ) select count(*) into v_total from filtered;

  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.updated_at desc
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'externalReference',external_reference,'orderType',order_type_code,'clientName',client_name,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep',current_step_code,'stepName',step_name,
    'status',status,'priority',priority,'requiresCut',requires_cut,'requiresPurchase',requires_purchase,'assigneeId',current_assignee_id,
    'assigneeName',assignee_name,'roleCode',current_role_code,'ageBusinessSeconds',age_business_seconds,
    'slaExceeded',(sla_hours is not null and age_business_seconds>sla_hours*3600),'version',version,'isHistory',is_history,'createdAt',created_at,'updatedAt',updated_at
  )),'[]'::jsonb) into v_items from filtered;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_get_actions(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_actions jsonb:='[]'; v_can_override boolean;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1;
  v_can_override:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia');
  if v_order.status not in('CLOSED','CANCELLED') then
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'CLAIM',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLAIM','label','Tomar tarea','kind','primary')); end if;
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'START',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','START','label','Iniciar trabajo','kind','primary','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'COMPLETE',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE','label','Finalizar etapa','kind','success','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','WAIT','label','Poner en espera','kind','warning','requires',jsonb_build_array('reason'))); end if;
    if v_task.status in('WAITING','BLOCKED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','RESUME','label','Reanudar','kind','primary')); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and v_task.status in('ASSIGNED','IN_PROGRESS') then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','NO_DELIVERY','label','Registrar no entrega','kind','danger','requires',jsonb_build_array('reason'))); end if;
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMMENT','label','Agregar comentario','kind','secondary','requires',jsonb_build_array('body')));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REQUEST_APPROVAL','label','Solicitar aprobación','kind','secondary','requires',jsonb_build_array('requestType','reason')));
  end if;
  return jsonb_build_object('orderId',v_order.id,'version',v_order.version,'status',v_order.status,'currentStep',v_order.current_step_code,'taskStatus',v_task.status,'canOverride',v_can_override,'actions',v_actions);
end;
$$;

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
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

create or replace function public.erp_x_create_order(p_payload jsonb, p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_order erp_supply.orders%rowtype; v_initial text; v_task erp_supply.order_tasks%rowtype; v_item jsonb; v_line int:=0; v_requires_purchase boolean; v_number text;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then raise exception 'Rol no autorizado para crear pedidos' using errcode='42501'; end if;
  v_number:=nullif(trim(p_payload->>'orderNumber'),'');
  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if p_idempotency_key is not null and exists(select 1 from erp_supply.order_events where organization_id=v_org and idempotency_key=p_idempotency_key) then
    select o.* into v_order from erp_supply.orders o join erp_supply.order_events e on e.order_id=o.id where e.organization_id=v_org and e.idempotency_key=p_idempotency_key limit 1;
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number);
  end if;
  v_requires_purchase:=coalesce((p_payload->>'requiresPurchase')::boolean,(select requires_purchase_default from erp_supply.order_types where code=p_payload->>'orderType'),false);
  v_initial:=erp_supply.initial_step(p_payload->>'orderType',p_payload->>'paymentCondition',v_requires_purchase);
  insert into erp_supply.orders(organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata)
  values(v_org,v_number,p_payload->>'externalReference',p_payload->>'orderType',p_payload->>'paymentCondition',p_payload->>'deliveryRoute',p_payload->>'clientName',p_payload->>'clientDocument',p_payload->>'clientCity',p_payload->>'clientAddress',p_payload->>'clientPhone',v_actor,v_initial,'QUEUED',coalesce(p_payload->>'priority','MEDIUM'),coalesce((p_payload->>'requiresCut')::boolean,false),v_requires_purchase,(p_payload->>'promisedAt')::timestamptz,(p_payload->>'requestedDeliveryDate')::date,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_order;
  for v_item in select value from jsonb_array_elements(coalesce(p_payload->'items','[]'::jsonb)) loop
    v_line:=v_line+1;
    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,warehouse_location,requires_cut,requested_cut_length,dimensions,metadata)
    values(v_order.id,coalesce((v_item->>'lineNumber')::int,v_line),v_item->>'sku',v_item->>'reference',coalesce(v_item->>'description','Ítem sin descripción'),(v_item->>'quantity')::numeric,coalesce(v_item->>'unit','UND'),v_item->>'warehouseLocation',coalesce((v_item->>'requiresCut')::boolean,false),(v_item->>'requestedCutLength')::numeric,coalesce(v_item->'dimensions','{}'::jsonb),coalesce(v_item->'metadata','{}'::jsonb));
  end loop;
  if v_line=0 then raise exception 'El pedido debe contener al menos un ítem'; end if;
  select * into v_task from erp_supply.create_task(v_order,v_initial,1);
  select * into v_order from erp_supply.orders where id=v_order.id;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,to_step_code,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,p_payload);
  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_execute_action(p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,p_expected_version integer default null,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
begin
  return erp_supply.execute_action_internal(p_order_id,p_action_code,coalesce(p_payload,'{}'::jsonb),erp_supply.require_profile(),false,p_expected_version,p_idempotency_key);
end;
$$;

create or replace function public.erp_x_list_approvals(p_status text default 'PENDING',p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_roles text[]:=erp_supply.current_roles(); v_total bigint; v_items jsonb; v_page int:=greatest(p_page,1); v_size int:=least(greatest(p_page_size,1),200);
begin
  select count(*) into v_total from erp_supply.approval_requests a where a.organization_id=v_org and (p_status is null or a.status=p_status) and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria'));
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select a.id,a.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",a.request_type "requestType",a.status,a.reason,a.request_payload "requestPayload",rq.display_name "requestedBy",a.assigned_role_code "assignedRole",a.decision_reason "decisionReason",a.created_at "createdAt",a.decided_at "decidedAt"
    from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id join erp_supply.profiles rq on rq.id=a.requested_by
    where a.organization_id=v_org and (p_status is null or a.status=p_status) and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria'))
    order by a.created_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_roles text[]:=erp_supply.current_roles(); v_req erp_supply.approval_requests%rowtype; v_order erp_supply.orders%rowtype; v_dec text:=upper(p_decision);
begin
  select * into v_req from erp_supply.approval_requests where id=p_request_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if not (v_req.assigned_profile_id=v_actor or v_req.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then raise exception 'No autorizado para decidir' using errcode='42501'; end if;
  update erp_supply.approval_requests set status=v_dec,decision_reason=p_reason,decided_by=v_actor,decided_at=now() where id=p_request_id returning * into v_req;
  if v_dec='APPROVED' then
    select * into v_order from erp_supply.orders where id=v_req.order_id for update;
    case v_req.request_type
      when 'CANCELLATION' then
        update erp_supply.order_tasks set status='CANCELLED',completed_at=now() where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
        update erp_supply.orders set status='CANCELLED',cancelled_at=now(),current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id;
      when 'PRIORITY' then update erp_supply.orders set priority=coalesce(v_req.request_payload->>'priority','HIGH'),version=version+1 where id=v_order.id;
      when 'ROUTE_CHANGE' then update erp_supply.orders set delivery_route_code=v_req.request_payload->>'route',version=version+1 where id=v_order.id;
      when 'REOPEN' then
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code=coalesce(v_req.request_payload->>'targetStep','CLOSURE'),version=version+1 where id=v_order.id returning * into v_order;
        perform erp_supply.create_task(v_order,v_order.current_step_code,(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id));
      else null;
    end case;
    update erp_supply.approval_requests set status='EXECUTED',executed_at=now() where id=p_request_id;
  end if;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason));
  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec);
end;
$$;

create or replace function public.erp_x_register_drive_file(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_file erp_supply.drive_files%rowtype;
begin
  insert into erp_supply.drive_files(organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,web_view_link,web_content_link,size_bytes,uploaded_by,metadata)
  values(v_org,(p_payload->>'orderId')::uuid,(p_payload->>'taskId')::uuid,p_payload->>'category',p_payload->>'driveFileId',p_payload->>'fileName',p_payload->>'mimeType',p_payload->>'webViewLink',p_payload->>'webContentLink',(p_payload->>'sizeBytes')::bigint,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_file;
  return jsonb_build_object('success',true,'file',to_jsonb(v_file));
end;
$$;

create or replace function public.erp_x_inventory(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_total bigint; v_items jsonb; v_page int:=greatest(p_page,1);v_size int:=least(greatest(p_page_size,1),200);
begin
  erp_supply.require_profile();
  select count(*) into v_total from erp_supply.inventory_items i where i.organization_id=v_org and i.active and (p_search is null or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select i.id,i.sku,i.reference,i.description,i.unit,i.item_type "itemType",i.barcode,
      coalesce(sum(l.quantity_available),0) "available",coalesce(sum(l.quantity_reserved),0) "reserved",coalesce(sum(l.quantity_blocked),0) "blocked",count(l.id) "lots"
    from erp_supply.inventory_items i left join erp_supply.inventory_lots l on l.inventory_item_id=i.id
    where i.organization_id=v_org and i.active and (p_search is null or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')) like '%'||lower(p_search)||'%')
    group by i.id order by i.description offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_vsm(p_date_from date default current_date-30,p_date_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return jsonb_build_object(
    'steps',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order),'[]'::jsonb) from (
      select s.code,s.name,s.sort_order,count(o.id) tasks,
        round(avg(t.business_seconds) filter(where o.id is not null)/3600.0,2) "avgBusinessHours",round(avg(t.raw_seconds) filter(where o.id is not null)/3600.0,2) "avgElapsedHours",
        round(percentile_cont(.5) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0,2) "medianBusinessHours",
        round(percentile_cont(.9) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0,2) "p90BusinessHours"
      from erp_supply.workflow_steps s left join erp_supply.order_tasks t on t.step_code=s.code and t.completed_at::date between p_date_from and p_date_to
      left join erp_supply.orders o on o.id=t.order_id and o.organization_id=v_org and not o.is_test
      group by s.code,s.name,s.sort_order
    ) x),
    'throughput',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) from (
      select d::date day,count(o.id) filter(where o.created_at::date=d::date) created,count(o.id) filter(where o.closed_at::date=d::date) closed
      from generate_series(p_date_from,p_date_to,'1 day') d left join erp_supply.orders o on o.organization_id=v_org and not o.is_test and (o.created_at::date=d::date or o.closed_at::date=d::date)
      group by d
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Historical CSV import receives normalized JSON rows in batches.
create or replace function public.erp_x_import_history(p_file_name text,p_rows jsonb,p_batch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_batch erp_supply.import_batches%rowtype; v_row jsonb; v_n int:=0; v_ok int:=0; v_bad int:=0; v_order erp_supply.orders%rowtype; v_step text; v_status text;
begin
  if not erp_supply.can_access_module('imports','create') then raise exception 'No autorizado para importar históricos' using errcode='42501'; end if;
  if p_batch_id is null then
    insert into erp_supply.import_batches(organization_id,import_type,file_name,imported_by,total_rows) values(v_org,'ORDER_HISTORY',p_file_name,v_actor,jsonb_array_length(p_rows)) returning * into v_batch;
  else select * into v_batch from erp_supply.import_batches where id=p_batch_id and organization_id=v_org for update;
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_n:=v_n+1;
    begin
      v_status:=upper(coalesce(v_row->>'status','CLOSED'));
      if v_status not in('CLOSED','CANCELLED') then v_status:='CLOSED'; end if;
      v_step:=case when v_status='CLOSED' then 'CLOSED' else coalesce(v_row->>'currentStep','CLOSED') end;
      insert into erp_supply.orders(organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,client_name,client_document,client_city,current_step_code,status,priority,requires_cut,requires_purchase,source,is_history,metadata,created_at,updated_at,closed_at,cancelled_at)
      values(v_org,v_row->>'orderNumber',v_row->>'externalReference',coalesce(v_row->>'orderType','PVC'),coalesce(v_row->>'paymentCondition','CREDIT'),coalesce(v_row->>'deliveryRoute','LOCAL_DISPATCH'),coalesce(v_row->>'clientName','Cliente histórico'),v_row->>'clientDocument',v_row->>'clientCity',v_step,v_status,coalesce(v_row->>'priority','MEDIUM'),coalesce((v_row->>'requiresCut')::boolean,false),coalesce((v_row->>'requiresPurchase')::boolean,false),'CSV_HISTORY',true,v_row,coalesce((v_row->>'createdAt')::timestamptz,now()),coalesce((v_row->>'updatedAt')::timestamptz,now()),case when v_status='CLOSED' then coalesce((v_row->>'closedAt')::timestamptz,(v_row->>'updatedAt')::timestamptz,now()) end,case when v_status='CANCELLED' then coalesce((v_row->>'cancelledAt')::timestamptz,now()) end)
      on conflict(organization_id,order_number) do update set metadata=erp_supply.orders.metadata||excluded.metadata,is_history=true;
      v_ok:=v_ok+1;
    exception when others then
      v_bad:=v_bad+1;
      insert into erp_supply.import_errors(batch_id,row_number,error_code,error_message,raw_row) values(v_batch.id,v_n,sqlstate,sqlerrm,v_row);
    end;
  end loop;
  update erp_supply.import_batches set inserted_rows=inserted_rows+v_ok,rejected_rows=rejected_rows+v_bad,status=case when v_bad=0 then 'COMPLETED' when v_ok=0 then 'FAILED' else 'PARTIAL' end,completed_at=now(),summary=summary||jsonb_build_object('lastBatchRows',v_n) where id=v_batch.id returning * into v_batch;
  return jsonb_build_object('success',v_bad=0,'batchId',v_batch.id,'processed',v_n,'inserted',v_ok,'rejected',v_bad,'status',v_batch.status);
end;
$$;

create or replace function public.erp_x_users()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  if not (erp_supply.can_access_module('admin','read') or erp_supply.has_role('jefe_logistica')) then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) from (
    select p.id,p.email,p.display_name name,p.employee_code "employeeCode",p.active,p.auth_user_id "authUserId",coalesce(array_agg(pr.role_code) filter(where pr.role_code is not null),'{}') roles
    from erp_supply.profiles p left join erp_supply.profile_roles pr on pr.profile_id=p.id where p.organization_id=v_org group by p.id
  ) x);
end;
$$;

-- Revoke everything by default, then expose only the native API.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public, anon, authenticated',r.sig); end loop;
end $$;

grant execute on function public.erp_x_session() to authenticated;
grant execute on function public.erp_x_dashboard() to authenticated;
grant execute on function public.erp_x_list_orders(text,text,text,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.erp_x_get_actions(uuid) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;
grant execute on function public.erp_x_create_order(jsonb,text) to authenticated;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;
grant execute on function public.erp_x_list_approvals(text,integer,integer) to authenticated;
grant execute on function public.erp_x_decide_approval(uuid,text,text) to authenticated;
grant execute on function public.erp_x_register_drive_file(jsonb) to authenticated;
grant execute on function public.erp_x_inventory(text,integer,integer) to authenticated;
grant execute on function public.erp_x_vsm(date,date) to authenticated;
grant execute on function public.erp_x_import_history(text,jsonb,uuid) to authenticated;
grant execute on function public.erp_x_users() to authenticated;

commit;
