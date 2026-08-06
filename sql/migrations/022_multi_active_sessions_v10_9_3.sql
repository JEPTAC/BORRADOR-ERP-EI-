-- ERP EI V10.9.3
-- Permite que un mismo usuario mantenga varias sesiones de trabajo activas,
-- conservando una sola sesión abierta por tarea/pedido.

begin;

-- Elimina únicamente la restricción global por usuario.
drop index if exists erp_supply.uq_open_session_per_user;

-- Conserva y reafirma el bloqueo por tarea.
create unique index if not exists uq_open_session_per_task
  on erp_supply.task_sessions(task_id)
  where ended_at is null;

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

create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
with
required_api(name) as (
  values
    ('erp_x_session'),('erp_x_health_check'),('erp_x_dashboard'),('erp_x_list_orders'),
    ('erp_x_get_order'),('erp_x_get_actions'),('erp_x_create_order'),('erp_x_execute_action'),
    ('erp_x_list_approvals'),('erp_x_decide_approval'),('erp_x_register_drive_file'),
    ('erp_x_inventory'),('erp_x_inventory_adjust'),('erp_x_inventory_lots'),('erp_x_vsm'),
    ('erp_x_import_history'),('erp_x_users'),('erp_x_assignment_pool'),('erp_x_update_checklist'),
    ('erp_x_save_financial_validation'),('erp_x_save_purchase_order'),('erp_x_admin_save_profile'),
    ('erp_x_admin_sync_auth'),('erp_x_calendar'),('erp_x_run_qa_matrix'),('erp_x_qa_runs'),
    ('erp_x_qa_run_detail'),('erp_x_run_qa_control_suite'),('erp_x_credit_list'),('erp_x_credit_create'),
    ('erp_x_credit_transition'),('erp_x_save_receipt'),('erp_x_stickers'),('erp_x_save_cut_job'),
    ('erp_x_save_invoice'),('erp_x_save_delivery'),('erp_x_audit')
),
public_api as (
  select p.oid,p.proname,p.prosecdef,
         has_function_privilege('authenticated',p.oid,'EXECUTE') auth_execute,
         has_function_privilege('anon',p.oid,'EXECUTE') anon_execute
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'erp_x_%'
),
calendar_stats as (
  select c.id,c.timezone,count(s.id) segments,
         coalesce(sum(extract(epoch from(s.end_time-s.start_time))),0)::bigint weekly_seconds
  from erp_supply.work_calendars c
  left join erp_supply.work_calendar_segments s on s.calendar_id=c.id
  where c.code='OPERATIONS_CO' and c.active
  group by c.id,c.timezone
),
active_task_issues as (
  select o.id,o.order_number,count(t.id) task_count
  from erp_supply.orders o
  left join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.status not in('DRAFT','CLOSED','CANCELLED')
  group by o.id,o.order_number
  having count(t.id)<>1
),
step_mismatches as (
  select o.id
  from erp_supply.orders o
  join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.current_step_code<>t.step_code
),
open_session_issues as (
  select s.id
  from erp_supply.task_sessions s
  join erp_supply.order_tasks t on t.id=s.task_id
  where s.ended_at is null and t.status<>'IN_PROGRESS'
),
latest_matrix as (
  select q.* from erp_supply.qa_runs q where q.run_type='MATRIX' order by q.started_at desc limit 1
),
latest_controls as (
  select q.* from erp_supply.qa_runs q where q.run_type='CONTROL_SUITE' order by q.started_at desc limit 1
),
checks as (
  select '01_INSTALACION'::text section,'Organización activa'::text check_name,
    exists(select 1 from erp_supply.organizations where code='EI' and active) ok,
    (select count(*)||' organización(es) activas' from erp_supply.organizations where active) detail

  union all select '01_INSTALACION','Tablas del núcleo instaladas',
    to_regclass('erp_supply.orders') is not null and to_regclass('erp_supply.order_tasks') is not null
      and to_regclass('erp_supply.inventory_movements') is not null and to_regclass('erp_supply.system_audit') is not null,
    'Pedidos, tareas, inventario y auditoría'

  union all select '01_INSTALACION','Roles empresariales configurados',
    (select count(*)>=13 from erp_supply.roles where active),
    (select count(*)||' roles activos' from erp_supply.roles where active)

  union all select '01_INSTALACION','Módulos empresariales configurados',
    (select count(*)>=20 from erp_supply.modules where active),
    (select count(*)||' módulos activos' from erp_supply.modules where active)

  union all select '01_INSTALACION','Catálogos comerciales completos',
    (select count(*)=4 from erp_supply.order_types where active)
      and (select count(*)=3 from erp_supply.payment_conditions where active)
      and (select count(*)=4 from erp_supply.delivery_routes where active),
    format('%s tipos · %s pagos · %s rutas',
      (select count(*) from erp_supply.order_types where active),
      (select count(*) from erp_supply.payment_conditions where active),
      (select count(*) from erp_supply.delivery_routes where active))

  union all select '01_INSTALACION','Flujo operativo completo',
    (select count(*)>=14 from erp_supply.workflow_steps where active),
    (select count(*)||' etapas activas' from erp_supply.workflow_steps where active)

  union all select '02_IDENTIDAD','Perfil de la sesión vinculado',
    exists(select 1 from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active limit 1),'Sesión sin perfil activo')

  union all select '02_IDENTIDAD','Super Admin principal configurado',
    exists(select 1 from erp_supply.profiles p join erp_supply.profile_roles pr on pr.profile_id=p.id
      where lower(p.email)='j.perez@ei.com.co' and p.active and pr.role_code='super_admin'),
    coalesce((select p.display_name||' · activo='||p.active from erp_supply.profiles p where lower(p.email)='j.perez@ei.com.co' limit 1),'Cuenta no encontrada')

  union all select '02_IDENTIDAD','Usuarios activos vinculados a Supabase Auth',
    not exists(select 1 from erp_supply.profiles where active and auth_user_id is null and not is_system),
    (select count(*)||' activo(s) sin vínculo Auth' from erp_supply.profiles where active and auth_user_id is null and not is_system)

  union all select '03_CALENDARIO','Zona horaria operativa',
    exists(select 1 from calendar_stats where timezone='America/Bogota'),
    coalesce((select timezone from calendar_stats),'Calendario no encontrado')

  union all select '03_CALENDARIO','Horario exacto lunes a viernes',
    exists(select 1 from calendar_stats where segments=10 and weekly_seconds=159000),
    coalesce((select segments||' segmentos · '||round(weekly_seconds/3600.0,2)||' horas/semana' from calendar_stats),'Calendario no encontrado')

  union all select '03_CALENDARIO','Festivos colombianos 2026',
    (select count(*)>=19 from erp_supply.holidays where holiday_date between date '2026-01-01' and date '2026-12-31'),
    (select count(*)||' festivos configurados, incluido el nuevo festivo de Chiquinquirá' from erp_supply.holidays where holiday_date between date '2026-01-01' and date '2026-12-31')

  union all select '04_SEGURIDAD','Esquema interno oculto',
    not has_schema_privilege('authenticated','erp_supply','USAGE') and not has_schema_privilege('anon','erp_supply','USAGE'),
    'authenticated='||has_schema_privilege('authenticated','erp_supply','USAGE')||' · anon='||has_schema_privilege('anon','erp_supply','USAGE')

  union all select '04_SEGURIDAD','API pública completa',
    not exists(select 1 from required_api r where not exists(select 1 from public_api a where a.proname=r.name)),
    coalesce((select string_agg(r.name,', ' order by r.name) from required_api r where not exists(select 1 from public_api a where a.proname=r.name)),'37 RPC requeridos disponibles')

  union all select '04_SEGURIDAD','RPC protegidos con SECURITY DEFINER',
    not exists(select 1 from public_api where not prosecdef),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not prosecdef),'Todos los RPC erp_x_* protegidos')

  union all select '04_SEGURIDAD','RPC disponibles para usuarios autenticados',
    not exists(select 1 from public_api where not auth_execute),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not auth_execute),'Todos los RPC erp_x_* habilitados para authenticated')

  union all select '04_SEGURIDAD','Rol anónimo completamente bloqueado',
    not exists(select 1 from public_api where anon_execute),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where anon_execute),'Ningún RPC erp_x_* expuesto a anon')

  union all select '05_CONCURRENCIA','Una sola tarea activa por pedido',
    to_regclass('erp_supply.uq_active_task_per_order') is not null and not exists(select 1 from active_task_issues),
    (select count(*)||' pedido(s) con cantidad inválida de tareas activas' from active_task_issues)

  union all select '05_CONCURRENCIA','Una sola sesión abierta por tarea',
    to_regclass('erp_supply.uq_open_session_per_task') is not null,
    'Índice parcial uq_open_session_per_task'

  union all select '05_CONCURRENCIA','Múltiples pedidos activos por operario',
    to_regclass('erp_supply.uq_open_session_per_user') is null,
    'Sesiones simultáneas permitidas por usuario; el bloqueo se conserva por tarea'

  union all select '05_CONCURRENCIA','Sesiones abiertas coherentes',
    not exists(select 1 from open_session_issues),
    (select count(*)||' sesión(es) abiertas fuera de una tarea IN_PROGRESS' from open_session_issues)

  union all select '05_CONCURRENCIA','Etapa del pedido coincide con tarea activa',
    not exists(select 1 from step_mismatches),
    (select count(*)||' pedido(s) desalineados' from step_mismatches)

  union all select '05_CONCURRENCIA','Idempotencia de eventos configurada',
    to_regclass('erp_supply.uq_event_idempotency') is not null,
    'Índice único por organización e idempotency_key'

  union all select '06_CONTROLES','Puertas de cierre activas',
    exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and c.relname='order_tasks' and t.tgname='trg_validate_task_completion' and t.tgenabled<>'D'),
    'Checklist y documentos obligatorios antes de completar cada etapa'

  union all select '06_CONTROLES','Listas de verificación configuradas',
    (select count(*)>=8 from erp_supply.checklist_templates where active and required),
    (select count(*)||' controles obligatorios activos' from erp_supply.checklist_templates where active and required)

  union all select '06_CONTROLES','Dominios operativos instalados',
    to_regclass('erp_supply.financial_validations') is not null and to_regclass('erp_supply.purchase_orders') is not null
      and to_regclass('erp_supply.receipts') is not null and to_regclass('erp_supply.cut_jobs') is not null
      and to_regclass('erp_supply.invoices') is not null and to_regclass('erp_supply.deliveries') is not null,
    'Finanzas, compras, recepción, corte, facturación y entrega'

  union all select '06_CONTROLES','Auditoría automática de dominios sensibles',
    (select count(*)>=16 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and t.tgname like 'trg_audit_%' and not t.tgisinternal and t.tgenabled<>'D'),
    (select count(*)||' disparadores de auditoría activos' from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and t.tgname like 'trg_audit_%' and not t.tgisinternal and t.tgenabled<>'D')

  union all select '07_ENRUTAMIENTO','Reglas locales y nacionales configuradas',
    (select count(*)>=8 from erp_supply.routing_rules where active and metadata->>'source'='established-routing'),
    (select count(*)||' reglas establecidas' from erp_supply.routing_rules where active and metadata->>'source'='established-routing')

  union all select '07_ENRUTAMIENTO','Responsable local Duvan Díaz vinculado',
    exists(select 1 from erp_supply.routing_rules rr join erp_supply.profiles p on p.id=rr.assigned_profile_id
      where rr.active and lower(p.email)='d.diaz@ei.com.co' and rr.route_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH')),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where lower(p.email)='d.diaz@ei.com.co' limit 1),'Perfil pendiente de vincular')

  union all select '07_ENRUTAMIENTO','Responsable nacional Javier Laverde vinculado',
    exists(select 1 from erp_supply.routing_rules rr join erp_supply.profiles p on p.id=rr.assigned_profile_id
      where rr.active and lower(p.email)='j.laverde@ei.com.co' and rr.route_code='NATIONAL_DISPATCH'),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where lower(p.email)='j.laverde@ei.com.co' limit 1),'Perfil pendiente de vincular')

  union all select '08_QA','Bot matricial de 192 escenarios instalado',
    to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null,
    '4 tipos × 3 pagos × 4 rutas × 2 corte × 2 compra'

  union all select '08_QA','Última matriz QA aprobada',
    exists(select 1 from latest_matrix where status='PASSED' and total_scenarios=192 and passed_scenarios=192 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_matrix),'Aún no se ha ejecutado la matriz QA')

  union all select '08_QA','Última suite de controles empresariales aprobada',
    exists(select 1 from latest_controls where status='PASSED' and total_scenarios=10 and passed_scenarios=10 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_controls),'Aún no se ha ejecutado la suite de controles')

  union all select '09_HISTORICO','Importador histórico aislado',
    to_regprocedure('public.erp_x_import_history(text,jsonb,uuid)') is not null,
    'Los pedidos CSV quedan como is_history=true y no generan tareas activas'

  union all select '09_AUDITORIA','Auditoría y outbox instalados',
    to_regclass('erp_supply.system_audit') is not null and to_regclass('erp_supply.outbox_events') is not null,
    format('%s registros de auditoría · %s eventos outbox pendientes',
      (select count(*) from erp_supply.system_audit),
      (select count(*) from erp_supply.outbox_events where processed_at is null))
)
select section,check_name,ok,detail from checks order by section,check_name
$$;

create or replace function public.erp_x_run_qa_control_suite(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
  v_order_id uuid;v_order2_id uuid;v_task uuid;v_version integer;v_result jsonb;v_result2 jsonb;
  v_ok boolean;v_error text;v_passed integer:=0;v_failed integer:=0;v_total integer:=0;
  v_req uuid;v_hist_number text;v_item uuid;v_lot uuid;v_available numeric;
  v_key text;
begin
  if not erp_supply.has_role('super_admin') then raise exception 'La suite integral solo puede ser ejecutada por Super Admin' using errcode='42501'; end if;
  insert into erp_supply.qa_runs(organization_id,run_type,requested_by,total_scenarios,summary)
  values(v_org,'CONTROL_SUITE',v_actor,10,jsonb_build_object('suite','enterprise-controls')) returning * into v_run;

  -- 1. Idempotencia por doble envío.
  v_total:=v_total+1;v_key:='CTRL-01-IDEMPOTENCY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'IDEMPOTENCY','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    v_result:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"inicio"}',v_actor,true,v_version,v_key);
    v_result2:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"reintento"}',v_actor,true,null,v_key);
    v_ok:=coalesce((v_result2->>'idempotent')::boolean,false) and (select count(*)=1 from erp_supply.order_events where idempotency_key=v_key);
    if not v_ok then v_error:='La acción duplicada creó más de un evento o no fue reconocida como idempotente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('ONE_EVENT','IDEMPOTENT_RESPONSE'),jsonb_build_array(v_result,v_result2),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 2. Conflicto de versión optimista.
  v_total:=v_total+1;v_key:='CTRL-02-OPTIMISTIC-VERSION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'VERSION','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,v_version,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"stale"}',v_actor,true,v_version,v_key||'-WAIT');
      v_error:='No se bloqueó la versión desactualizada';
    exception when sqlstate '40001' then v_ok:=true;
    end;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('SQLSTATE_40001'),jsonb_build_array(case when v_ok then 'BLOCKED' else 'NOT_BLOCKED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 3. Múltiples sesiones activas por operario, una por tarea.
  v_total:=v_total+1;v_key:='CTRL-03-MULTI-ORDER-SESSIONS';v_ok:=false;v_error:=null;v_order_id:=null;v_order2_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-A','RECEPCION_PEDIDO',true);
    v_order2_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-B','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-A');
    perform erp_supply.execute_action_internal(v_order2_id,'START','{}',v_actor,true,null,v_key||'-B');
    v_ok=(select count(*)=2 from erp_supply.task_sessions s
      join erp_supply.order_tasks t on t.id=s.task_id
      where s.profile_id=v_actor and s.ended_at is null and t.order_id in(v_order_id,v_order2_id));
    if not v_ok then v_error:='No se conservaron las dos sesiones simultáneas'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('TWO_ACTIVE_SESSIONS'),jsonb_build_array(case when v_ok then 'ACCEPTED' else 'REJECTED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then delete from erp_supply.orders where id in(v_order_id,v_order2_id); end if;

  -- 4. Espera, reanudación y sesiones de tiempo.
  v_total:=v_total+1;v_key:='CTRL-04-WAIT-RESUME-TIME';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'TIMING','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"espera control"}',v_actor,true,null,v_key||'-WAIT');
    perform erp_supply.execute_action_internal(v_order_id,'RESUME','{}',v_actor,true,null,v_key||'-RESUME');
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"fin"}',v_actor,true,null,v_key||'-COMPLETE');
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='RECEPCION_PEDIDO' order by sequence_no limit 1;
    v_ok=(select count(*)=2 and bool_and(ended_at is not null) from erp_supply.task_sessions where task_id=v_task)
      and exists(select 1 from erp_supply.order_tasks where id=v_task and status='COMPLETED');
    if not v_ok then v_error:='Las sesiones de espera/reanudación no cerraron correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('TWO_CLOSED_SESSIONS','TASK_COMPLETED'),jsonb_build_array(case when v_ok then 'OK' else 'INVALID' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 5. Puerta real: checklist y validación financiera obligatorios.
  v_total:=v_total+1;v_key:='CTRL-05-STAGE-GATE';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'GATE','CARTERA',false);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{}',v_actor,true,null,v_key||'-BLOCKED');
      v_error:='La etapa se completó sin checklist ni validación';
    exception when others then
      v_ok:=position('controles obligatorios' in lower(sqlerrm))>0 or position('validación aprobada' in lower(sqlerrm))>0;
    end;
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='CARTERA' and status='IN_PROGRESS';
    update erp_supply.task_checklist set completed=true,completed_by=v_actor,completed_at=now() where task_id=v_task;
    insert into erp_supply.financial_validations(order_id,validation_type,decision,notes,created_by)
    values(v_order_id,'CARTERA','APPROVED','QA control',v_actor);
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"gate satisfied"}',v_actor,true,null,v_key||'-PASS');
    v_ok:=v_ok and exists(select 1 from erp_supply.orders where id=v_order_id and current_step_code='RECEPCION_PEDIDO');
    if not v_ok and v_error is null then v_error:='La puerta no bloqueó o no liberó correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('BLOCK_WITHOUT_CONTROLS','ADVANCE_WITH_CONTROLS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 6. No entrega y reprogramación futura.
  v_total:=v_total+1;v_key:='CTRL-06-NO-DELIVERY-REPROGRAM';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'NODELIVERY','LOCAL_DISPATCH',true,'LOCAL_DISPATCH');
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'NO_DELIVERY','{"reason":"cliente ausente"}',v_actor,true,null,v_key||'-NO');
    perform erp_supply.execute_action_internal(v_order_id,'REPROGRAM',jsonb_build_object('scheduledAt',now()+interval '1 day'),v_actor,true,null,v_key||'-REPROGRAM');
    v_ok:=exists(select 1 from erp_supply.deliveries where order_id=v_order_id and status='REPROGRAMMED')
      and exists(select 1 from erp_supply.orders where id=v_order_id and status='ASSIGNED');
    if not v_ok then v_error:='La no entrega no quedó reprogramada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('NOT_DELIVERED','REPROGRAMMED'),jsonb_build_array(case when v_ok then 'REPROGRAMMED' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 7. Solicitud y ejecución de prioridad.
  v_total:=v_total+1;v_key:='CTRL-07-APPROVAL-PRIORITY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'APPROVAL','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'REQUEST_APPROVAL','{"requestType":"PRIORITY","priority":"HIGH","reason":"QA"}',v_actor,true,null,v_key||'-REQUEST');
    select id into v_req from erp_supply.approval_requests where order_id=v_order_id and request_type='PRIORITY' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','Aprobación QA');
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and priority='HIGH')
      and exists(select 1 from erp_supply.approval_requests where id=v_req and status='EXECUTED');
    if not v_ok then v_error:='La aprobación no actualizó prioridad o no quedó ejecutada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('REQUESTED','EXECUTED','PRIORITY_HIGH'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 8. Importación histórica sin tareas operativas.
  v_total:=v_total+1;v_key:='CTRL-08-HISTORY-ISOLATION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_hist_number:='QAH-'||substr(replace(v_run.id::text,'-',''),1,12);
    perform public.erp_x_import_history('qa-history.csv',jsonb_build_array(jsonb_build_object(
      'orderNumber',v_hist_number,'orderType','PVC','paymentCondition','CREDIT','deliveryRoute','LOCAL_DISPATCH',
      'clientName','Histórico QA','status','CLOSED','createdAt',now()-interval '30 days','closedAt',now()-interval '29 days'
    )),null);
    select id into v_order_id from erp_supply.orders where organization_id=v_org and order_number=v_hist_number;
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and is_history and status='CLOSED')
      and not exists(select 1 from erp_supply.order_tasks where order_id=v_order_id);
    if not v_ok then v_error:='El histórico creó tareas o no quedó aislado'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('HISTORY','NO_TASKS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 9. Recepción publica inventario y movimiento.
  v_total:=v_total+1;v_key:='CTRL-09-RECEIPT-INVENTORY';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'RECEIPT','RECEPCION_MERCANCIA',true);
    perform public.erp_x_save_receipt(v_order_id,jsonb_build_object('receiptNumber','QAR-'||substr(v_run.id::text,1,8),'status','CONFORMING','lines',jsonb_build_array(jsonb_build_object(
      'sku','QA-RECEIPT-'||substr(v_run.id::text,1,8),'description','Material recepción QA','receivedQuantity',10,'acceptedQuantity',10,'rejectedQuantity',0,'unit','UND','location','QA','lotNumber','LOT-QA'
    ))));
    select inventory_item_id into v_item from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' order by id desc limit 1;
    v_ok:=v_item is not null and exists(select 1 from erp_supply.inventory_lots where inventory_item_id=v_item and quantity_available=10)
      and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' and quantity=10);
    if not v_ok then v_error:='La recepción no publicó inventario correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('RECEIPT','LOT','MOVEMENT'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then
    delete from erp_supply.inventory_movements where order_id=v_order_id;
    if v_item is not null then delete from erp_supply.inventory_lots where inventory_item_id=v_item;delete from erp_supply.inventory_items where id=v_item;end if;
    delete from erp_supply.orders where id=v_order_id;
  end if;

  -- 10. Corte consume lote y registra desperdicio.
  v_total:=v_total+1;v_key:='CTRL-10-CUT-CONSUMPTION';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;v_lot:=null;
  begin
    insert into erp_supply.inventory_items(organization_id,sku,description,unit,item_type)
    values(v_org,'QA-CUT-'||substr(v_run.id::text,1,8),'Chipa QA','M','CABLE') returning id into v_item;
    insert into erp_supply.inventory_lots(inventory_item_id,lot_number,location,quantity_available)
    values(v_item,'LOT-CUT-QA','QA-CORTE',100) returning id into v_lot;
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'CUT','CORTE',true,'LOCAL_DISPATCH',true);
    perform public.erp_x_save_cut_job(v_order_id,jsonb_build_object('inventoryLotId',v_lot,'requestedLength',10,'actualLength',10,'scrapLength',1));
    select quantity_available into v_available from erp_supply.inventory_lots where id=v_lot;
    v_ok:=v_available=89 and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='CUT_CONSUMPTION' and quantity=11);
    if not v_ok then v_error:='El corte no descontó longitud y desperdicio correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('AVAILABLE_89','MOVEMENT_11'),jsonb_build_array(coalesce(v_available,-1)),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then
    if v_order_id is not null then delete from erp_supply.inventory_movements where order_id=v_order_id;delete from erp_supply.orders where id=v_order_id;end if;
    if v_lot is not null then delete from erp_supply.inventory_lots where id=v_lot;end if;
    if v_item is not null then delete from erp_supply.inventory_items where id=v_item;end if;
  end if;

  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,
    total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),
    summary=summary||jsonb_build_object('cleanup',p_cleanup,'controls','idempotency,version,sessions,timing,gates,delivery,approval,history,receipt,cut')
  where id=v_run.id returning * into v_run;

  return jsonb_build_object('runId',v_run.id,'runType',v_run.run_type,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
end;
$$;

-- Mantener acceso únicamente para usuarios autenticados.
revoke all on function public.erp_x_health_check() from public,anon,authenticated;
grant execute on function public.erp_x_health_check() to authenticated;
revoke all on function public.erp_x_run_qa_control_suite(boolean) from public,anon,authenticated;
grant execute on function public.erp_x_run_qa_control_suite(boolean) to authenticated;

commit;
