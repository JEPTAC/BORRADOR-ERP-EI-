-- ERP EI V10.25.5 · Certificación real del flujo del pedido por roles y módulos
-- Objetivo: certificar la salida del ERP recorriendo 336 combinaciones de pedido
-- con los usuarios/roles que realmente deben operar cada etapa. La prueba usa
-- pedidos TEST-QA, RPC públicos del ERP e identidad temporal del perfil operativo.

begin;

create table if not exists erp_supply.qa_flow_case_state(
  case_id uuid primary key references erp_supply.qa_deep_cases(id) on delete cascade,
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  order_id uuid,
  order_number text,
  expected_path jsonb not null default '[]'::jsonb,
  actual_path jsonb not null default '[]'::jsonb,
  steps_executed integer not null default 0,
  status text not null default 'PENDING' check(status in('PENDING','PASSED','FAILED')),
  current_step text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists idx_qa_flow_case_state_run
  on erp_supply.qa_flow_case_state(qa_run_id,status,steps_executed);

create table if not exists erp_supply.qa_flow_step_audit(
  id bigint generated always as identity primary key,
  case_id uuid not null references erp_supply.qa_deep_cases(id) on delete cascade,
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  order_id uuid,
  order_number text,
  step_index integer not null,
  step_code text not null,
  module_code text,
  expected_role_code text,
  actual_role_code text,
  actor_profile_id uuid references erp_supply.profiles(id) on delete set null,
  actor_name text,
  expected_next_step text,
  actual_next_step text,
  before_status text,
  after_status text,
  permissions jsonb not null default '{}'::jsonb,
  actions jsonb not null default '[]'::jsonb,
  status text not null check(status in('PASSED','FAILED')),
  error_sqlstate text,
  error_message text,
  duration_ms integer,
  captured_at timestamptz not null default now(),
  unique(case_id,step_index)
);

create index if not exists idx_qa_flow_step_audit_run
  on erp_supply.qa_flow_step_audit(qa_run_id,status,module_code,expected_role_code);

revoke all on erp_supply.qa_flow_case_state from public,anon,authenticated;
revoke all on erp_supply.qa_flow_step_audit from public,anon,authenticated;

create or replace function erp_supply.qa_flow_profile_for_role(
  p_org uuid,
  p_role text,
  p_preferred uuid default null
)
returns uuid
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_profile uuid;
begin
  if p_preferred is not null then
    select p.id into v_profile
    from erp_supply.profiles p
    where p.id=p_preferred and p.organization_id=p_org and p.active and p.auth_user_id is not null
      and exists(select 1 from erp_supply.profile_roles pr where pr.profile_id=p.id and pr.role_code=p_role);
    if v_profile is not null then return v_profile; end if;
  end if;

  select p.id into v_profile
  from erp_supply.profiles p
  join erp_supply.profile_roles pr on pr.profile_id=p.id and pr.role_code=p_role
  where p.organization_id=p_org and p.active and p.auth_user_id is not null
  order by pr.is_primary desc,p.created_at,p.id
  limit 1;
  return v_profile;
end;
$$;

create or replace function erp_supply.qa_flow_module_allowed(
  p_role text,
  p_module text,
  p_action text
)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select exists(
    select 1
    from erp_supply.role_module_permissions r
    where r.role_code=p_role and r.module_code=p_module and r.can_read
      and case lower(coalesce(p_action,'read'))
        when 'create' then r.can_create
        when 'update' then r.can_update
        when 'approve' then r.can_approve
        when 'admin' then r.can_admin
        else r.can_read
      end
  )
$$;

create or replace function erp_supply.qa_flow_required_module_action(p_step text)
returns text
language sql
immutable
as $$
  select case upper(coalesce(p_step,''))
    when 'COMPRAS' then 'create'
    when 'RECEPCION_MERCANCIA' then 'create'
    when 'FACTURACION' then 'create'
    else 'update'
  end
$$;

create or replace function erp_supply.qa_flow_expected_path(p_spec jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_step text;v_next text;v_path jsonb:='[]'::jsonb;v_guard int:=0;
  v_type text:=upper(p_spec->>'orderType');
  v_payment text:=upper(p_spec->>'paymentCondition');
  v_route text:=upper(p_spec->>'deliveryRoute');
  v_cut boolean:=coalesce(erp_supply.safe_boolean(p_spec->>'requiresCut'),false);
  v_purchase boolean:=coalesce(erp_supply.safe_boolean(p_spec->>'requiresPurchase'),false);
  v_arrears boolean:=coalesce(erp_supply.safe_boolean(p_spec->>'hasCreditArrears'),false);
  v_cash boolean:=coalesce(erp_supply.safe_boolean(p_spec->>'heldByCashier'),false);
begin
  v_step:=erp_supply.initial_step(v_type,v_payment,v_purchase,v_arrears,v_cash);
  v_path:=jsonb_build_array(v_step);
  v_next:=v_step;
  while v_next<>'CLOSED' and v_guard<20 loop
    v_next:=erp_supply.next_step(v_next,v_type,v_payment,v_route,v_cut,v_purchase);
    v_path:=v_path||jsonb_build_array(v_next);
    v_guard:=v_guard+1;
  end loop;
  if v_next<>'CLOSED' then raise exception 'La ruta QA no alcanza CLOSED en 20 etapas'; end if;
  return v_path;
end;
$$;

create or replace function public.erp_x_qa_flow_create_run()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run uuid;v_plan jsonb;
begin
  insert into erp_supply.qa_runs(organization_id,run_type,status,requested_by,total_scenarios,summary)
  values(v_org,'TOTAL_ROBOT','RUNNING',v_actor,336,jsonb_build_object(
    'qaPurpose','ORDER_FLOW_CERTIFICATION','qaRobotVersion','10.25.5','productionIsolation',true,'startedFrom','SUPER_ADMIN_FLOW_CERT'
  )) returning id into v_run;
  v_plan:=public.erp_x_qa_flow_build_campaign(v_run);
  return jsonb_build_object('success',true,'runId',v_run,'planned',v_plan->'planned','version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_build_campaign(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_financial jsonb;v_type text;v_payment text;v_route text;v_cut boolean;v_purchase boolean;v_requires_purchase boolean;v_key text;v_total int;
  v_states jsonb:=jsonb_build_array(
    jsonb_build_object('code','PVC-NORMAL','orderType','PVC','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVC-MORA','orderType','PVC','hasCreditArrears',true,'heldByCashier',false),
    jsonb_build_object('code','PVN-NORMAL','orderType','PVN','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVN-CAJA','orderType','PVN','hasCreditArrears',false,'heldByCashier',true),
    jsonb_build_object('code','PVE','orderType','PVE','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-NORMAL','orderType','PVP','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-MORA','orderType','PVP','hasCreditArrears',true,'heldByCashier',false)
  );
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA de flujo no disponible';
  end if;

  delete from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='FLOW_ORDER';
  for v_financial in select value from jsonb_array_elements(v_states) loop
    v_type:=v_financial->>'orderType';
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_requires_purchase:=v_purchase or v_type='PVE';
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_financial->>'code',v_payment,v_route,v_cut,v_purchase);
            insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification,status)
            values(p_run_id,'FLOW-'||v_key,'EXTREME','FLOW_ORDER',jsonb_build_object(
              'baseCombination',v_key,'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,
              'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
              'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),
              'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false)
            ),'PENDING') on conflict(qa_run_id,case_key) do nothing;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  select count(*) into v_total from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='FLOW_ORDER';
  if v_total<>336 then raise exception 'La certificación de flujo debe contener 336 pedidos y contiene %',v_total; end if;
  update erp_supply.qa_runs set total_scenarios=v_total,summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('flowPlan',jsonb_build_object('planned',v_total,'builtAt',now())) where id=p_run_id;
  return jsonb_build_object('success',true,'runId',p_run_id,'planned',v_total,'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_pending_cases(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA no disponible'; end if;
  return jsonb_build_object('runId',p_run_id,'items',(
    select coalesce(jsonb_agg(jsonb_build_object('caseId',c.id,'caseKey',c.case_key,'status',c.status,'specification',c.specification) order by c.case_key),'[]'::jsonb)
    from erp_supply.qa_deep_cases c where c.qa_run_id=p_run_id and c.family='FLOW_ORDER' and c.status='PENDING'
  ),'version','10.25.5');
end;
$$;

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
    v_seed:=public.erp_x_qa_robot_seed_order(v_case.qa_run_id,v_spec||jsonb_build_object('scenarioKey',v_case.case_key));
    if erp_supply.safe_uuid(v_seed->>'orderId') is null then raise exception 'No se pudo crear el pedido TEST del flujo'; end if;
    select * into v_order from erp_supply.orders where id=erp_supply.safe_uuid(v_seed->>'orderId') for update;
    v_expected_path:=erp_supply.qa_flow_expected_path(v_spec);

    -- El seed nace como Super Admin. Se devuelve inmediatamente a la asignación
    -- real que produciría el motor de routing para que la prueba no use override.
    select profile_id,role_code into v_expected_profile,v_expected_role
    from erp_supply.resolve_assignment(v_order.organization_id,v_order.current_step_code,v_order.delivery_route_code,v_order.order_type_code);
    update erp_supply.order_tasks
      set assigned_profile_id=v_expected_profile,assigned_role_code=v_expected_role,
          status=case when v_expected_profile is null then 'QUEUED' else 'ASSIGNED' end,
          assigned_at=case when v_expected_profile is null then null else now() end
    where order_id=v_order.id and step_code=v_order.current_step_code and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
    update erp_supply.orders
      set current_assignee_id=v_expected_profile,current_role_code=v_expected_role,
          status=case when v_expected_profile is null then 'QUEUED' else 'ASSIGNED' end,updated_at=now()
    where id=v_order.id returning * into v_order;

    insert into erp_supply.qa_flow_case_state(case_id,qa_run_id,order_id,order_number,expected_path,actual_path,current_step)
    values(v_case.id,v_case.qa_run_id,v_order.id,v_order.order_number,v_expected_path,jsonb_build_array(v_order.current_step_code),v_order.current_step_code)
    returning * into v_state;
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
      return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','PASSED','completed',true,'currentStep','CLOSED','orderNumber',v_state.order_number,'version','10.25.5');
    end if;

    update erp_supply.qa_deep_cases set status='PENDING',started_at=coalesce(started_at,now()),last_attempt_at=now(),attempt_count=coalesce(attempt_count,0)+1 where id=v_case.id;
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','PENDING','completed',false,'currentStep',v_actual_next,'stepsExecuted',v_step_index,'orderNumber',v_state.order_number,'version','10.25.5');

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
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status','FAILED','completed',true,'failedStep',v_step,'module',v_module,'expectedRole',v_expected_role,'actorName',v_actor_name,'errorSqlstate',v_error_state,'errorMessage',v_error_message,'version','10.25.5');
  end;
end;
$$;

create or replace function public.erp_x_qa_flow_progress(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_total int;v_pass int;v_fail int;v_pending int;v_steps int;v_step_fail int;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA no disponible'; end if;
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='PENDING')
    into v_total,v_pass,v_fail,v_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='FLOW_ORDER';
  select count(*),count(*) filter(where status='FAILED') into v_steps,v_step_fail from erp_supply.qa_flow_step_audit where qa_run_id=p_run_id;
  return jsonb_build_object('runId',p_run_id,'planned',v_total,'passed',v_pass,'failed',v_fail,'pending',v_pending,'executed',v_pass+v_fail,'stepsAudited',v_steps,'stepFailures',v_step_fail,
    'launchable',v_total=336 and v_pass=336 and v_fail=0 and v_pending=0 and v_step_fail=0,'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_matrix(p_run_id uuid,p_status text default 'ALL')
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_status text:=upper(coalesce(nullif(trim(p_status),''),'ALL'));
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA no disponible'; end if;
  return jsonb_build_object('runId',p_run_id,'items',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'caseId',c.id,'caseKey',c.case_key,'status',c.status,'specification',c.specification,'orderNumber',s.order_number,
      'expectedPath',s.expected_path,'actualPath',s.actual_path,'stepsExecuted',coalesce(s.steps_executed,0),'currentStep',s.current_step,
      'errorSqlstate',c.error_sqlstate,'errorMessage',c.error_message,'result',c.result
    ) order by c.case_key),'[]'::jsonb)
    from erp_supply.qa_deep_cases c left join erp_supply.qa_flow_case_state s on s.case_id=c.id
    where c.qa_run_id=p_run_id and c.family='FLOW_ORDER' and (v_status='ALL' or c.status=v_status)
  ),'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_case_detail(p_case_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_case erp_supply.qa_deep_cases%rowtype;
begin
  select c.* into v_case from erp_supply.qa_deep_cases c join erp_supply.qa_runs r on r.id=c.qa_run_id where c.id=p_case_id and c.family='FLOW_ORDER' and r.organization_id=v_org;
  if not found then raise exception 'Caso de flujo no disponible'; end if;
  return jsonb_build_object('case',to_jsonb(v_case),'state',(select to_jsonb(s) from erp_supply.qa_flow_case_state s where s.case_id=p_case_id),'steps',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'stepIndex',a.step_index,'stepCode',a.step_code,'moduleCode',a.module_code,'expectedRole',a.expected_role_code,'actualRole',a.actual_role_code,
      'actorProfileId',a.actor_profile_id,'actorName',a.actor_name,'expectedNextStep',a.expected_next_step,'actualNextStep',a.actual_next_step,
      'beforeStatus',a.before_status,'afterStatus',a.after_status,'permissions',a.permissions,'actions',a.actions,'status',a.status,
      'errorSqlstate',a.error_sqlstate,'errorMessage',a.error_message,'durationMs',a.duration_ms,'capturedAt',a.captured_at
    ) order by a.step_index),'[]'::jsonb) from erp_supply.qa_flow_step_audit a where a.case_id=p_case_id
  ),'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_summary(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA no disponible'; end if;
  return jsonb_build_object(
    'run',(select jsonb_build_object('status',r.status,'startedAt',r.started_at,'completedAt',r.completed_at,'flowCertification',r.summary->'flowCertification') from erp_supply.qa_runs r where r.id=p_run_id),
    'byModule',(select coalesce(jsonb_agg(to_jsonb(x) order by x.module),'[]'::jsonb) from(
      select module_code module,count(*) total,count(*) filter(where status='PASSED') passed,count(*) filter(where status='FAILED') failed
      from erp_supply.qa_flow_step_audit where qa_run_id=p_run_id group by module_code
    )x),
    'byRole',(select coalesce(jsonb_agg(to_jsonb(x) order by x.role),'[]'::jsonb) from(
      select expected_role_code role,count(*) total,count(*) filter(where status='PASSED') passed,count(*) filter(where status='FAILED') failed,count(distinct actor_profile_id) users
      from erp_supply.qa_flow_step_audit where qa_run_id=p_run_id group by expected_role_code
    )x),
    'failures',(select coalesce(jsonb_agg(to_jsonb(x) order by x."capturedAt" desc),'[]'::jsonb) from(
      select a.case_id "caseId",c.case_key "caseKey",a.step_code "stepCode",a.module_code "moduleCode",a.expected_role_code "roleCode",a.actor_name "actorName",a.error_sqlstate "errorSqlstate",a.error_message "errorMessage",a.permissions,a.captured_at "capturedAt"
      from erp_supply.qa_flow_step_audit a join erp_supply.qa_deep_cases c on c.id=a.case_id where a.qa_run_id=p_run_id and a.status='FAILED' order by a.captured_at desc limit 200
    )x),
    'version','10.25.5'
  );
end;
$$;

create or replace function public.erp_x_qa_flow_user_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_missing jsonb;v_invalid jsonb;v_success boolean;
begin
  with required(role_code) as (
    values('ventas'),('cartera'),('caja'),('compras'),('recepcion_mercancia'),('coordinador_logistico'),
          ('aux_logistica'),('auxiliar_corte'),('despacho_nacional'),('jefe_logistica'),('gerencia')
  )
  select coalesce(jsonb_agg(r.role_code order by r.role_code),'[]'::jsonb)
  into v_missing
  from required r
  where not exists(
    select 1 from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id and pr.role_code=r.role_code
    where p.organization_id=v_org and p.active and p.auth_user_id is not null
  );

  with required(role_code) as (
    values('ventas'),('cartera'),('caja'),('compras'),('recepcion_mercancia'),('coordinador_logistico'),
          ('aux_logistica'),('auxiliar_corte'),('despacho_nacional'),('jefe_logistica'),('gerencia')
  )
  select coalesce(jsonb_agg(jsonb_build_object('profileId',p.id,'name',p.display_name,'email',p.email,'role',pr.role_code) order by p.display_name,pr.role_code),'[]'::jsonb)
  into v_invalid
  from erp_supply.profiles p
  join erp_supply.profile_roles pr on pr.profile_id=p.id
  join required r on r.role_code=pr.role_code
  where p.organization_id=v_org and p.active and p.auth_user_id is null;

  v_success:=jsonb_array_length(v_missing)=0 and jsonb_array_length(v_invalid)=0;
  return jsonb_build_object('success',v_success,'missingAuthenticatedRoles',v_missing,'activeProfilesWithoutAuth',v_invalid,'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_delivery_exception_suite(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_super uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_orig_sub text:=current_setting('request.jwt.claim.sub',true);
  v_orig_claims text:=current_setting('request.jwt.claims',true);
  v_sales uuid;v_sales_auth uuid;v_jefe uuid;v_jefe_auth uuid;
  v_ship uuid;v_ship_auth uuid;v_ship_role text;v_assignment_profile uuid;
  v_route text;v_resolution text;v_expected_delivery text;
  v_seed jsonb;v_order uuid;v_task uuid;v_report jsonb;v_issue uuid;
  v_ok boolean;v_total int:=0;v_passed int:=0;v_failed int:=0;v_checks jsonb:='[]'::jsonb;
  v_error_state text;v_error_message text;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA no disponible';
  end if;

  v_sales:=erp_supply.qa_flow_profile_for_role(v_org,'ventas',null);
  v_jefe:=erp_supply.qa_flow_profile_for_role(v_org,'jefe_logistica',null);
  if v_sales is null then raise exception 'CONFIG_QA: no existe usuario Ventas autenticado para probar no-entrega'; end if;
  if v_jefe is null then raise exception 'CONFIG_QA: no existe Jefe Logístico autenticado para resolver no-entrega'; end if;
  select auth_user_id into v_sales_auth from erp_supply.profiles where id=v_sales;
  select auth_user_id into v_jefe_auth from erp_supply.profiles where id=v_jefe;

  foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
    foreach v_resolution in array array['REPROGRAM','RETURN','RESOLVED'] loop
      v_total:=v_total+1;v_order:=null;v_issue:=null;v_ok:=false;v_error_state:=null;v_error_message:=null;
      begin
        v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object(
          'scenarioKey',format('FLOW-DELIVERY-%s-%s',v_route,v_resolution),
          'stepCode',v_route,'orderType','PVC','paymentCondition','CREDIT','deliveryRoute',v_route,
          'requiresCut',false,'requiresPurchase',false
        ));
        v_order:=erp_supply.safe_uuid(v_seed->>'orderId');
        if v_order is null then raise exception 'No fue posible crear pedido de no-entrega'; end if;
        update erp_supply.orders set seller_profile_id=v_sales where id=v_order;

        select profile_id,role_code into v_assignment_profile,v_ship_role
        from erp_supply.resolve_assignment(v_org,v_route,v_route,'PVC');
        v_ship:=erp_supply.qa_flow_profile_for_role(v_org,v_ship_role,v_assignment_profile);
        if v_ship is null then raise exception 'CONFIG_QA: no existe usuario autenticado del rol % para %',v_ship_role,v_route; end if;
        select auth_user_id into v_ship_auth from erp_supply.profiles where id=v_ship;
        select id into v_task from erp_supply.order_tasks where order_id=v_order and step_code=v_route and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1;
        if v_task is null then raise exception 'No existe tarea de despacho %',v_route; end if;
        update erp_supply.order_tasks set assigned_profile_id=v_ship,assigned_role_code=v_ship_role,status='ASSIGNED',assigned_at=now() where id=v_task;
        update erp_supply.orders set current_assignee_id=v_ship,current_role_code=v_ship_role,status='ASSIGNED' where id=v_order;

        perform set_config('request.jwt.claim.sub',v_ship_auth::text,true);
        perform set_config('request.jwt.claims',jsonb_build_object('sub',v_ship_auth::text,'role','authenticated')::text,true);
        perform public.erp_x_execute_action(v_order,'START','{}'::jsonb,null,format('FLOW255-DELIVERY-START-%s-%s',v_route,v_resolution));
        perform public.erp_x_shipping_save_guide(v_order,jsonb_build_object('trackingNumber','GUIA-QA-'||substr(replace(v_order::text,'-',''),1,10),'carrier','TRANSPORTADORA QA'));
        perform public.erp_x_shipping_save_location(v_order,jsonb_build_object(
          'placeLabel','Punto sintético QA','municipality','Tuluá','department','Valle del Cauca',
          'address','Zona QA · sin despacho físico','latitude',4.08466,'longitude',-76.19536,'accuracy',1,'source','QA_SYNTHETIC'
        ));
        perform public.erp_x_shipping_send_to_closure(v_order,jsonb_build_object('detail','QA envía a cierre antes de no-entrega'));

        perform set_config('request.jwt.claim.sub',v_sales_auth::text,true);
        perform set_config('request.jwt.claims',jsonb_build_object('sub',v_sales_auth::text,'role','authenticated')::text,true);
        v_report:=public.erp_x_shipping_report_no_delivery(v_order,jsonb_build_object('reason','Cliente QA no recibió pedido','requestedAction',v_resolution));
        v_issue:=erp_supply.safe_uuid(v_report#>>'{issue,issue,id}');
        if v_issue is null then raise exception 'Ventas no logró crear el reporte de no-entrega'; end if;

        perform set_config('request.jwt.claim.sub',v_jefe_auth::text,true);
        perform set_config('request.jwt.claims',jsonb_build_object('sub',v_jefe_auth::text,'role','authenticated')::text,true);
        perform public.erp_x_resolve_order_issue(v_issue,jsonb_build_object(
          'resolution','Jefatura resuelve no-entrega en QA','resolutionCode',v_resolution
        ));

        v_expected_delivery:=case v_resolution when 'RETURN' then 'CANCELLED' when 'REPROGRAM' then 'REPROGRAMMED' else 'IN_TRANSIT' end;
        select exists(select 1 from erp_supply.deliveries d where d.order_id=v_order and d.status=v_expected_delivery) into v_ok;
        if not v_ok then raise exception 'No-entrega % en % no dejó delivery en %',v_resolution,v_route,v_expected_delivery; end if;

        perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
        perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);
        perform public.erp_x_sandbox_delete(v_order);
        v_passed:=v_passed+1;
        v_checks:=v_checks||jsonb_build_array(jsonb_build_object(
          'key',format('%s-%s',v_route,v_resolution),'success',true,'route',v_route,'resolution',v_resolution,
          'salesProfileId',v_sales,'shippingProfileId',v_ship,'shippingRole',v_ship_role,'jefeProfileId',v_jefe,'deliveryStatus',v_expected_delivery
        ));
      exception when others then
        v_error_state:=sqlstate;v_error_message:=sqlerrm;v_failed:=v_failed+1;
        perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
        perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);
        begin if v_order is not null and exists(select 1 from erp_supply.orders where id=v_order) then perform public.erp_x_sandbox_delete(v_order); end if; exception when others then null; end;
        v_checks:=v_checks||jsonb_build_array(jsonb_build_object(
          'key',format('%s-%s',v_route,v_resolution),'success',false,'route',v_route,'resolution',v_resolution,
          'sqlstate',v_error_state,'error',v_error_message
        ));
      end;
    end loop;
  end loop;
  perform set_config('request.jwt.claim.sub',coalesce(v_orig_sub,''),true);
  perform set_config('request.jwt.claims',coalesce(nullif(v_orig_claims,''),'{}'),true);
  return jsonb_build_object('success',v_failed=0,'total',v_total,'passed',v_passed,'failed',v_failed,'checks',v_checks,'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_finish(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_total int;v_pass int;v_fail int;v_pending int;v_step_fail int;v_remaining int;v_branches jsonb;v_branch_ok boolean:=false;v_delivery_branches jsonb;v_delivery_ok boolean:=false;v_user_readiness jsonb;v_users_ok boolean:=false;v_launchable boolean:=false;v_order uuid;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA no disponible'; end if;
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='PENDING') into v_total,v_pass,v_fail,v_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='FLOW_ORDER';
  select count(*) into v_step_fail from erp_supply.qa_flow_step_audit where qa_run_id=p_run_id and status='FAILED';

  -- Ramas que no caben en un flujo feliz único: prioridad/rechazo, cambio de ruta,
  -- reapertura, excepciones y cancelación/limpieza.
  v_branches:=public.erp_x_qa_robot_branch_suite(p_run_id);
  v_branch_ok:=coalesce((v_branches->>'failed')::int,1)=0 and coalesce((v_branches->>'passed')::int,0)=10;
  v_delivery_branches:=public.erp_x_qa_flow_delivery_exception_suite(p_run_id);
  v_delivery_ok:=coalesce((v_delivery_branches->>'failed')::int,1)=0 and coalesce((v_delivery_branches->>'passed')::int,0)=12;
  v_user_readiness:=public.erp_x_qa_flow_user_readiness();
  v_users_ok:=coalesce((v_user_readiness->>'success')::boolean,false);

  for v_order in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
    begin perform public.erp_x_sandbox_delete(v_order); exception when others then null; end;
  end loop;
  select count(*) into v_remaining from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT';
  v_launchable:=v_total=336 and v_pass=336 and v_fail=0 and v_pending=0 and v_step_fail=0 and v_branch_ok and v_delivery_ok and v_users_ok and v_remaining=0;

  update erp_supply.qa_runs set status=case when v_launchable then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_pass,failed_scenarios=v_fail,completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
    'qaPurpose','ORDER_FLOW_CERTIFICATION','flowCertification',jsonb_build_object('launchable',v_launchable,'planned',v_total,'passed',v_pass,'failed',v_fail,'pending',v_pending,'stepFailures',v_step_fail,'branchSuite',v_branches,'deliveryExceptionSuite',v_delivery_branches,'userReadiness',v_user_readiness,'remainingTestOrders',v_remaining,'version','10.25.5','finishedAt',now())
  ) where id=p_run_id;

  return jsonb_build_object('runId',p_run_id,'launchable',v_launchable,'releaseState',case when v_launchable then 'LANZABLE' else 'NO_LANZABLE' end,'planned',v_total,'passed',v_pass,'failed',v_fail,'pending',v_pending,'stepFailures',v_step_fail,'branchSuite',v_branches,'deliveryExceptionSuite',v_delivery_branches,'userReadiness',v_user_readiness,'remainingTestOrders',v_remaining,'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_latest()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run erp_supply.qa_runs%rowtype;
begin
  select * into v_run from erp_supply.qa_runs
  where organization_id=v_org and run_type='TOTAL_ROBOT' and summary->>'qaPurpose'='ORDER_FLOW_CERTIFICATION'
  order by started_at desc limit 1;
  if not found then return jsonb_build_object('available',false,'version','10.25.5'); end if;
  return jsonb_build_object('available',true,'runId',v_run.id,'status',v_run.status,'startedAt',v_run.started_at,'completedAt',v_run.completed_at,'summary',v_run.summary,'progress',public.erp_x_qa_flow_progress(v_run.id),'version','10.25.5');
end;
$$;

create or replace function public.erp_x_qa_flow_latest_resumable()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run erp_supply.qa_runs%rowtype;
begin
  select * into v_run from erp_supply.qa_runs
  where organization_id=v_org and run_type='TOTAL_ROBOT' and status='RUNNING' and summary->>'qaPurpose'='ORDER_FLOW_CERTIFICATION'
  order by started_at desc limit 1;
  if not found then return jsonb_build_object('available',false,'version','10.25.5'); end if;
  return jsonb_build_object('available',true,'runId',v_run.id,'startedAt',v_run.started_at,'progress',public.erp_x_qa_flow_progress(v_run.id),'version','10.25.5');
end;
$$;

revoke all on function erp_supply.qa_flow_profile_for_role(uuid,text,uuid) from public;
revoke all on function erp_supply.qa_flow_module_allowed(text,text,text) from public;
revoke all on function erp_supply.qa_flow_required_module_action(text) from public;
revoke all on function erp_supply.qa_flow_expected_path(jsonb) from public;

revoke all on function public.erp_x_qa_flow_create_run() from public,anon;
revoke all on function public.erp_x_qa_flow_build_campaign(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_pending_cases(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_execute_slice(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_progress(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_matrix(uuid,text) from public,anon;
revoke all on function public.erp_x_qa_flow_case_detail(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_summary(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_user_readiness() from public,anon;
revoke all on function public.erp_x_qa_flow_delivery_exception_suite(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_finish(uuid) from public,anon;
revoke all on function public.erp_x_qa_flow_latest() from public,anon;
revoke all on function public.erp_x_qa_flow_latest_resumable() from public,anon;

grant execute on function public.erp_x_qa_flow_create_run() to authenticated;
grant execute on function public.erp_x_qa_flow_build_campaign(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_pending_cases(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_execute_slice(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_progress(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_matrix(uuid,text) to authenticated;
grant execute on function public.erp_x_qa_flow_case_detail(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_summary(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_user_readiness() to authenticated;
grant execute on function public.erp_x_qa_flow_delivery_exception_suite(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_finish(uuid) to authenticated;
grant execute on function public.erp_x_qa_flow_latest() to authenticated;
grant execute on function public.erp_x_qa_flow_latest_resumable() to authenticated;

notify pgrst,'reload schema';
commit;
