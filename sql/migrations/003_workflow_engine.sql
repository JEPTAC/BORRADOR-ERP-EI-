-- ERP Supply Enterprise V10
-- Migration 003: identity, calendar calculations, routing and transactional workflow engine.

begin;

create or replace function erp_supply.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select p.id
  from erp_supply.profiles p
  where p.auth_user_id = auth.uid() and p.active
  limit 1
$$;

create or replace function erp_supply.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select p.organization_id
  from erp_supply.profiles p
  where p.auth_user_id = auth.uid() and p.active
  limit 1
$$;

create or replace function erp_supply.current_roles()
returns text[]
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select coalesce(array_agg(pr.role_code order by pr.is_primary desc, pr.role_code), '{}'::text[])
  from erp_supply.profiles p
  join erp_supply.profile_roles pr on pr.profile_id = p.id
  join erp_supply.roles r on r.code = pr.role_code and r.active
  where p.auth_user_id = auth.uid() and p.active
$$;

create or replace function erp_supply.has_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select coalesce(p_role = any(erp_supply.current_roles()), false)
$$;

create or replace function erp_supply.require_profile()
returns uuid
language plpgsql
stable
security definer
set search_path = erp_supply, public, auth
as $$
declare v_profile uuid;
begin
  v_profile := erp_supply.current_profile_id();
  if v_profile is null then
    raise exception 'Usuario sin perfil activo en ERP Supply Enterprise' using errcode='42501';
  end if;
  return v_profile;
end;
$$;

create or replace function erp_supply.can_access_module(p_module text, p_capability text default 'read')
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select exists (
    select 1
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    join erp_supply.role_module_permissions mp on mp.role_code=pr.role_code and mp.module_code=p_module
    where p.auth_user_id=auth.uid() and p.active
      and case lower(coalesce(p_capability,'read'))
        when 'create' then mp.can_create
        when 'update' then mp.can_update
        when 'approve' then mp.can_approve
        when 'admin' then mp.can_admin
        else mp.can_read
      end
  )
$$;


create or replace function erp_supply.can_view_order(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth
as $$
  with ctx as (
    select erp_supply.current_profile_id() profile_id,erp_supply.current_roles() roles
  )
  select exists(
    select 1 from erp_supply.orders o cross join ctx
    where o.id=p_order_id and o.organization_id=erp_supply.current_org_id() and (
      ctx.roles && array['super_admin','gerencia','jefe_logistica','auditoria']::text[]
      or o.seller_profile_id=ctx.profile_id
      or o.current_assignee_id=ctx.profile_id
      or o.current_role_code=any(ctx.roles)
      or exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.assigned_profile_id=ctx.profile_id)
      or exists(select 1 from erp_supply.step_roles sr where sr.step_code=o.current_step_code and sr.role_code=any(ctx.roles) and sr.can_view)
    )
  )
$$;

create or replace function erp_supply.business_seconds_between(
  p_organization_id uuid,
  p_start timestamptz,
  p_end timestamptz
)
returns bigint
language sql
stable
security definer
set search_path = erp_supply, public
as $$
with org as (
  select o.id, o.timezone,
         (select c.id from erp_supply.work_calendars c where c.organization_id=o.id and c.active order by c.created_at limit 1) calendar_id
  from erp_supply.organizations o where o.id=p_organization_id
), days as (
  select g::date work_date, org.*
  from org,
  lateral generate_series(
    (p_start at time zone org.timezone)::date,
    (p_end at time zone org.timezone)::date,
    interval '1 day'
  ) g
), segments as (
  select d.work_date,d.timezone,
    ((d.work_date + s.start_time) at time zone d.timezone) seg_start,
    ((d.work_date + s.end_time) at time zone d.timezone) seg_end
  from days d
  join erp_supply.work_calendar_segments s
    on s.calendar_id=d.calendar_id and s.iso_weekday=extract(isodow from d.work_date)::int
  where not exists (
    select 1 from erp_supply.holidays h
    where h.organization_id=d.id and h.holiday_date=d.work_date
  )
), overlaps as (
  select greatest(seg_start,p_start) a, least(seg_end,p_end) b
  from segments where seg_end>p_start and seg_start<p_end
)
select coalesce(sum(greatest(0,extract(epoch from (b-a))))::bigint,0)
from overlaps
$$;

create or replace function erp_supply.initial_step(
  p_order_type text,
  p_payment_condition text,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case
    when p_payment_condition in ('CREDIT','MIXED') then 'CARTERA'
    when p_payment_condition='CASH' then 'CAJA'
    when p_requires_purchase or p_order_type='PVE' then 'COMPRAS'
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
    when 'CARTERA' then case
      when p_payment_condition='MIXED' then 'CAJA'
      when p_requires_purchase or p_order_type='PVE' then 'COMPRAS'
      else 'RECEPCION_PEDIDO' end
    when 'CAJA' then case when p_requires_purchase or p_order_type='PVE' then 'COMPRAS' else 'RECEPCION_PEDIDO' end
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case when p_requires_cut then 'CORTE' else 'FACTURACION' end
    when 'CORTE' then 'FACTURACION'
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.default_role_for_step(p_step text, p_route text)
returns text
language sql
immutable
as $$
  select case p_step
    when 'CARTERA' then 'cartera'
    when 'CAJA' then 'caja'
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

create or replace function erp_supply.resolve_assignment(
  p_org uuid,
  p_step text,
  p_route text,
  p_order_type text
)
returns table(profile_id uuid, role_code text)
language sql
stable
security definer
set search_path=erp_supply,public
as $$
  with matching as (
    select rr.assigned_profile_id,rr.assigned_role_code,rr.priority
    from erp_supply.routing_rules rr
    where rr.organization_id=p_org and rr.active and rr.step_code=p_step
      and (rr.route_code is null or rr.route_code=p_route)
      and (rr.order_type_code is null or rr.order_type_code=p_order_type)
    order by
      (rr.route_code is not null)::int desc,
      (rr.order_type_code is not null)::int desc,
      rr.priority asc
    limit 1
  )
  select m.assigned_profile_id,coalesce(m.assigned_role_code,erp_supply.default_role_for_step(p_step,p_route)) from matching m
  union all
  select null,erp_supply.default_role_for_step(p_step,p_route)
  where not exists(select 1 from matching)
  limit 1
$$;

create or replace function erp_supply.actor_can(
  p_actor uuid,
  p_step text,
  p_action text,
  p_assignee uuid default null
)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public
as $$
  select exists(
    select 1
    from erp_supply.profile_roles pr
    join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=p_step
    where pr.profile_id=p_actor and (
      sr.can_override or
      case upper(p_action)
        when 'CLAIM' then sr.can_claim
        when 'ASSIGN' then sr.can_assign
        when 'START' then sr.can_start and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'COMPLETE' then sr.can_complete and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'WAIT' then sr.can_block and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'BLOCK' then sr.can_block
        when 'RESUME' then sr.can_start
        else sr.can_view
      end
    )
  )
$$;

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

create or replace function erp_supply.execute_action_internal(
  p_order_id uuid,
  p_action text,
  p_payload jsonb,
  p_actor uuid,
  p_bypass_permissions boolean default false,
  p_expected_version integer default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_action text := upper(trim(coalesce(p_action,'')));
  v_next text;
  v_new_task erp_supply.order_tasks%rowtype;
  v_target uuid;
  v_session erp_supply.task_sessions%rowtype;
  v_now timestamptz := now();
  v_business bigint := 0;
  v_event_id bigint;
  v_actor_role text;
begin
  if v_action='' then raise exception 'Acción requerida'; end if;
  if p_actor is null then raise exception 'Actor requerido' using errcode='42501'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if p_expected_version is not null and v_order.version<>p_expected_version then
    raise exception 'El pedido cambió mientras estaba abierto. Actualice la pantalla.' using errcode='40001';
  end if;
  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_order.organization_id and idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'version',v_order.version);
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  select pr.role_code into v_actor_role from erp_supply.profile_roles pr
  where pr.profile_id=p_actor order by pr.is_primary desc,pr.role_code limit 1;

  if v_action not in ('COMMENT','REQUEST_APPROVAL') and v_task.id is null and v_order.status not in ('CLOSED','CANCELLED') then
    raise exception 'El pedido no tiene una tarea operativa activa';
  end if;

  if not p_bypass_permissions and v_action in ('CLAIM','ASSIGN','START','COMPLETE','WAIT','BLOCK','RESUME')
     and not erp_supply.actor_can(p_actor,v_order.current_step_code,v_action,v_order.current_assignee_id) then
    raise exception 'El usuario no está autorizado para ejecutar % en %',v_action,v_order.current_step_code using errcode='42501';
  end if;

  if v_action='CLAIM' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede reclamarse en su estado actual'; end if;
    update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=coalesce(assigned_at,v_now),status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=p_actor,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='ASSIGN' then
    begin v_target := (p_payload->>'profileId')::uuid; exception when others then raise exception 'profileId inválido'; end;
    if not exists(select 1 from erp_supply.profiles where id=v_target and organization_id=v_order.organization_id and active) then raise exception 'Responsable no válido'; end if;
    update erp_supply.order_tasks set assigned_profile_id=v_target,assigned_at=v_now,status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=v_target,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='START' then
    if v_task.status not in ('QUEUED','ASSIGNED','WAITING') then raise exception 'La tarea no puede iniciarse en su estado actual'; end if;
    if v_task.assigned_profile_id is null then
      update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=v_now where id=v_task.id;
    end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then
      raise exception 'El usuario ya tiene otra sesión de trabajo activa';
    end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action in ('WAIT','BLOCK') then
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=extract(epoch from(v_now-s.started_at))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,
      blocked_at=case when v_action='BLOCK' then v_now else blocked_at end,
      result_detail=coalesce(p_payload->>'reason',p_payload->>'detail',result_detail)
    where id=v_task.id returning * into v_task;
    update erp_supply.orders set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='RESUME' then
    if v_task.status not in ('WAITING','BLOCKED') then raise exception 'La tarea no está en espera o bloqueo'; end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note) values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMPLETE' then
    if not p_bypass_permissions and v_task.status<>'IN_PROGRESS' then raise exception 'Debe iniciar la tarea antes de finalizarla'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=extract(epoch from(v_now-s.started_at))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    select coalesce(sum(business_seconds),0) into v_business from erp_supply.task_sessions where task_id=v_task.id;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-coalesce(started_at,created_at)))::bigint),
      business_seconds=v_business,result_code=coalesce(p_payload->>'resultCode','COMPLETED'),result_detail=p_payload->>'detail',metadata=metadata||coalesce(p_payload,'{}'::jsonb)
    where id=v_task.id returning * into v_task;

    v_next:=erp_supply.next_step(v_order.current_step_code,v_order.order_type_code,v_order.payment_condition_code,v_order.delivery_route_code,v_order.requires_cut,v_order.requires_purchase);
    if v_next='CLOSED' then
      update erp_supply.orders set current_step_code='CLOSED',status='CLOSED',closed_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
    else
      select * into v_new_task from erp_supply.create_task(v_order,v_next,v_task.sequence_no+1);
      select * into v_order from erp_supply.orders where id=v_order.id;
    end if;

  elsif v_action='NO_DELIVERY' then
    if v_order.current_step_code not in ('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'La no entrega solo aplica en despacho o entrega'; end if;
    insert into erp_supply.deliveries(order_id,route_code,status,no_delivery_reason,assigned_profile_id,metadata)
    values(v_order.id,v_order.delivery_route_code,'NOT_DELIVERED',coalesce(p_payload->>'reason','No entregado'),p_actor,p_payload);
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=p_payload->>'reason' where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='WAITING',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='REPROGRAM' then
    update erp_supply.deliveries set status='REPROGRAMMED',scheduled_at=(p_payload->>'scheduledAt')::timestamptz,metadata=metadata||p_payload
    where id=(select id from erp_supply.deliveries where order_id=v_order.id order by created_at desc limit 1);
    update erp_supply.order_tasks set status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMMENT' then
    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_order.id,p_actor,coalesce(p_payload->>'commentType','GENERAL'),coalesce(p_payload->>'visibility','ORDER'),p_payload->>'body',coalesce(p_payload->'metadata','{}'::jsonb));

  elsif v_action='REQUEST_APPROVAL' then
    insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
    values(v_order.organization_id,v_order.id,p_payload->>'requestType',p_actor,coalesce(p_payload->>'assignedRole','jefe_logistica'),p_payload->>'reason',p_payload);

  else
    raise exception 'Acción no reconocida: %',v_action;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_order.organization_id,v_order.id,coalesce(v_task.id,v_new_task.id),'WORKFLOW_ACTION',v_action,
    case when v_action='COMPLETE' then v_task.step_code else v_order.current_step_code end,
    v_order.current_step_code,null,v_order.status,p_actor,v_actor_role,p_idempotency_key,coalesce(p_payload,'{}'::jsonb))
  returning id into v_event_id;

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_order.organization_id,'ORDER_ACTION','ORDER',v_order.id,jsonb_build_object('eventId',v_event_id,'action',v_action,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'eventId',v_event_id);
end;
$$;

commit;
