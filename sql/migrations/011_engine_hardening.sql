-- ERP Supply Enterprise V10
-- Migration 011: transactional engine hardening and precise workflow audit.

begin;

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
  v_from_step text;
  v_from_status text;
  v_scheduled_at timestamptz;
begin
  if v_action='' then raise exception 'Acción requerida'; end if;
  if p_actor is null then raise exception 'Actor requerido' using errcode='42501'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  v_from_step:=v_order.current_step_code;
  v_from_status:=v_order.status;

  if p_expected_version is not null and v_order.version<>p_expected_version then
    raise exception 'El pedido cambió mientras estaba abierto. Actualice la pantalla.' using errcode='40001';
  end if;
  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_order.organization_id and idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  select pr.role_code into v_actor_role from erp_supply.profile_roles pr
  where pr.profile_id=p_actor order by pr.is_primary desc,pr.role_code limit 1;

  if v_action not in ('COMMENT','REQUEST_APPROVAL') and v_task.id is null and v_order.status not in ('CLOSED','CANCELLED') then
    raise exception 'El pedido no tiene una tarea operativa activa';
  end if;

  if not p_bypass_permissions then
    if v_action in ('CLAIM','ASSIGN','START','COMPLETE','WAIT','BLOCK','RESUME')
       and not erp_supply.actor_can(p_actor,v_order.current_step_code,v_action,v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para ejecutar % en %',v_action,v_order.current_step_code using errcode='42501';
    end if;
    if v_action='NO_DELIVERY' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para registrar no entrega' using errcode='42501';
    end if;
    if v_action='REPROGRAM' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para reprogramar la entrega' using errcode='42501';
    end if;
  end if;

  if v_action='CLAIM' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede reclamarse en su estado actual'; end if;
    if v_task.assigned_profile_id is not null and v_task.assigned_profile_id<>p_actor and not p_bypass_permissions
       and not exists(select 1 from erp_supply.profile_roles pr join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_task.step_code where pr.profile_id=p_actor and sr.can_override) then
      raise exception 'La tarea ya está asignada a otro responsable';
    end if;
    update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=coalesce(assigned_at,v_now),status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=p_actor,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='ASSIGN' then
    begin v_target := nullif(p_payload->>'profileId','')::uuid; exception when others then raise exception 'profileId inválido'; end;
    if v_target is null then raise exception 'Debe seleccionar un responsable'; end if;
    if not exists(
      select 1 from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_order.current_step_code and sr.can_view
      where p.id=v_target and p.organization_id=v_order.organization_id and p.active
    ) then raise exception 'El responsable no está habilitado para la etapa %',v_order.current_step_code; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'No puede reasignar una tarea con sesión de trabajo activa'; end if;
    update erp_supply.order_tasks set assigned_profile_id=v_target,assigned_at=v_now,status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=v_target,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='START' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede iniciarse en su estado actual'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión de trabajo activa'; end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then
      raise exception 'El usuario ya tiene otra sesión de trabajo activa';
    end if;
    if v_task.assigned_profile_id is null then
      update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=v_now where id=v_task.id;
    end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action in ('WAIT','BLOCK') then
    if v_task.status<>'IN_PROGRESS' then raise exception 'Solo una tarea en proceso puede ponerse en espera o bloqueo'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,
      blocked_at=case when v_action='BLOCK' then v_now else blocked_at end,
      result_detail=coalesce(nullif(p_payload->>'reason',''),nullif(p_payload->>'detail',''),result_detail)
    where id=v_task.id returning * into v_task;
    update erp_supply.orders set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='RESUME' then
    if v_task.status not in ('WAITING','BLOCKED') then raise exception 'La tarea no está en espera o bloqueo'; end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then raise exception 'El usuario ya tiene otra sesión de trabajo activa'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión activa'; end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note) values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMPLETE' then
    if not p_bypass_permissions and v_task.status<>'IN_PROGRESS' then raise exception 'Debe iniciar la tarea antes de finalizarla'; end if;
    if not p_bypass_permissions and not exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea no tiene una sesión activa para finalizar'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    select coalesce(sum(business_seconds),0) into v_business from erp_supply.task_sessions where task_id=v_task.id;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-coalesce(started_at,created_at)))::bigint),
      business_seconds=v_business,result_code=coalesce(nullif(p_payload->>'resultCode',''),'COMPLETED'),result_detail=p_payload->>'detail',metadata=metadata||coalesce(p_payload,'{}'::jsonb)
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
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo de no entrega'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    insert into erp_supply.deliveries(order_id,route_code,status,no_delivery_reason,assigned_profile_id,metadata)
    values(v_order.id,v_order.delivery_route_code,'NOT_DELIVERED',trim(p_payload->>'reason'),p_actor,p_payload);
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=trim(p_payload->>'reason') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='WAITING',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='REPROGRAM' then
    begin v_scheduled_at:=nullif(p_payload->>'scheduledAt','')::timestamptz; exception when others then raise exception 'Fecha de reprogramación inválida'; end;
    if v_scheduled_at is null or v_scheduled_at<=v_now then raise exception 'La nueva fecha debe ser futura'; end if;
    if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED') then raise exception 'No existe una no entrega pendiente de reprogramación'; end if;
    update erp_supply.deliveries set status='REPROGRAMMED',scheduled_at=v_scheduled_at,metadata=metadata||p_payload,updated_at=v_now
    where id=(select id from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED' order by created_at desc limit 1);
    update erp_supply.order_tasks set status='ASSIGNED',result_detail=coalesce(nullif(p_payload->>'detail',''),'Entrega reprogramada') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMMENT' then
    if nullif(trim(p_payload->>'body'),'') is null then raise exception 'Debe escribir el comentario'; end if;
    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_order.id,p_actor,upper(coalesce(nullif(p_payload->>'commentType',''),'GENERAL')),upper(coalesce(nullif(p_payload->>'visibility',''),'ORDER')),trim(p_payload->>'body'),coalesce(p_payload->'metadata','{}'::jsonb));

  elsif v_action='REQUEST_APPROVAL' then
    insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
    values(v_order.organization_id,v_order.id,upper(p_payload->>'requestType'),p_actor,coalesce(nullif(p_payload->>'assignedRole',''),'jefe_logistica'),trim(p_payload->>'reason'),p_payload);

  else
    raise exception 'Acción no reconocida: %',v_action;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_order.organization_id,v_order.id,coalesce(v_task.id,v_new_task.id),'WORKFLOW_ACTION',v_action,
    v_from_step,v_order.current_step_code,v_from_status,v_order.status,p_actor,v_actor_role,p_idempotency_key,coalesce(p_payload,'{}'::jsonb))
  returning id into v_event_id;

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_order.organization_id,p_actor,v_action,'ORDER',v_order.id::text,
    jsonb_build_object('step',v_from_step,'status',v_from_status,'version',coalesce(p_expected_version,v_order.version-1)),
    jsonb_build_object('step',v_order.current_step_code,'status',v_order.status,'version',v_order.version),
    jsonb_build_object('eventId',v_event_id,'idempotencyKey',p_idempotency_key));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_order.organization_id,'ORDER_ACTION','ORDER',v_order.id,jsonb_build_object('eventId',v_event_id,'action',v_action,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'eventId',v_event_id);
end;
$$;

-- Correct VSM numeric handling and distinguish productive time from elapsed time.
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
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Rango de fechas inválido'; end if;
  return jsonb_build_object(
    'steps',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order),'[]'::jsonb) from (
      select s.code,s.name,s.sort_order,count(o.id) tasks,
        round((avg(t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "avgBusinessHours",
        round((avg(t.raw_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "avgElapsedHours",
        round((percentile_cont(.5) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "medianBusinessHours",
        round((percentile_cont(.9) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "p90BusinessHours",
        round((avg(greatest(0,t.raw_seconds-t.business_seconds)) filter(where o.id is not null)/3600.0)::numeric,2) "avgWaitHours"
      from erp_supply.workflow_steps s
      left join erp_supply.order_tasks t on t.step_code=s.code and t.completed_at::date between p_date_from and p_date_to
      left join erp_supply.orders o on o.id=t.order_id and o.organization_id=v_org and not o.is_test
      group by s.code,s.name,s.sort_order
    ) x),
    'throughput',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) from (
      select d::date day,count(o.id) filter(where o.created_at::date=d::date) created,count(o.id) filter(where o.closed_at::date=d::date) closed
      from generate_series(p_date_from,p_date_to,'1 day') d
      left join erp_supply.orders o on o.organization_id=v_org and not o.is_test and (o.created_at::date=d::date or o.closed_at::date=d::date)
      group by d
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Keep only authenticated access to native APIs.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;
