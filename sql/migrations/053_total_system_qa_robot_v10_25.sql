-- ERP EI V10.25.0 · Robot QA total del sistema
-- Super Admin only: exhaustive domain gates + isolated Sandbox order seeding + UI/E2E evidence ledger.

begin;

-- ---------------------------------------------------------------------------
-- 1. QA is exclusive to Super Admin.
-- ---------------------------------------------------------------------------
update erp_supply.role_module_permissions
set can_read=false,can_create=false,can_update=false,can_approve=false,can_admin=false
where module_code='qa' and role_code<>'super_admin';

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('super_admin','qa',true,true,true,true,true)
on conflict(role_code,module_code) do update set
  can_read=true,can_create=true,can_update=true,can_approve=true,can_admin=true;

-- ---------------------------------------------------------------------------
-- 2. Detailed ledger for the total robot. qa_runs remains the canonical run.
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.qa_robot_checks(
  id uuid primary key default gen_random_uuid(),
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  check_key text not null,
  layer text not null check(layer in('DOMAIN','INTEGRITY','CONTRACT','UI','SANDBOX','RESPONSIVE','SECURITY','PERFORMANCE')),
  suite text not null,
  module_code text,
  order_id uuid references erp_supply.orders(id) on delete set null,
  status text not null default 'RUNNING' check(status in('RUNNING','PASSED','FAILED','WARNING','SKIPPED')),
  severity text not null default 'HIGH' check(severity in('CRITICAL','HIGH','MEDIUM','LOW','INFO')),
  input jsonb not null default '{}'::jsonb,
  expected jsonb not null default '{}'::jsonb,
  actual jsonb not null default '{}'::jsonb,
  evidence jsonb not null default '{}'::jsonb,
  error_message text,
  duration_ms integer,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(qa_run_id,check_key)
);
create index if not exists idx_qa_robot_checks_run on erp_supply.qa_robot_checks(qa_run_id,status,layer,suite);
create index if not exists idx_qa_robot_checks_order on erp_supply.qa_robot_checks(order_id) where order_id is not null;

revoke all on erp_supply.qa_robot_checks from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 3. Test plan: exhaustive finite inputs + branch, UI and responsive coverage.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();
begin
  return jsonb_build_object(
    'version','10.25.0',
    'strategy','EXHAUSTIVE_INPUTS_PLUS_BRANCH_COVERAGE',
    'productionIsolation',true,
    'domain',jsonb_build_object(
      'routingCombinations',336,
      'enterpriseControls',10,
      'integrityGates',2,
      'branchChecks',10,
      'description','Todas las combinaciones finitas vigentes de entrada comercial + controles y gates estructurales.'
    ),
    'branchFamilies',jsonb_build_array(
      'PVC normal / mora','PVP normal / mora','PVN normal / retenido por Caja','PVE compra y recepción',
      'Alistamiento completo / parcial / reanudación','Corte sin corte / corte / multi-carreto / evidencia',
      'Entrega en punto / recoge / local / nacional','No entrega / reprogramación',
      'Cancelación aprobada / rechazada','Novedad / reporte / aprobación / devolución',
      'Recepción completa / parcial acumulada','Facturación normal / Caja PVN / Anexo PVP'
    ),
    'ui',jsonb_build_object(
      'modules','ALL_SUPER_ADMIN_MODULES',
      'safeControlCrawler',true,
      'sandboxMutationDriver',true,
      'consoleAndPromiseErrors',true,
      'moduleErrors',true,
      'horizontalOverflow',true
    ),
    'responsive',jsonb_build_object('widths',jsonb_build_array(360,390,424,768,960,1440),'criticalModules',jsonb_build_array('dashboard','orders','inventory','workforce','approvals','sandbox','cutting','receiving','shipping')),
    'externalE2E',jsonb_build_object('engine','Playwright','browsers',jsonb_build_array('Chromium Desktop','Pixel 7'),'traces',true,'screenshotsOnFailure',true,'videoOnFailure',true),
    'requestedBy',v_actor
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Create, record and close a total QA run.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_create_run(p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
begin
  insert into erp_supply.qa_runs(organization_id,run_type,status,requested_by,total_scenarios,summary)
  values(v_org,'TOTAL_ROBOT','RUNNING',v_actor,0,jsonb_build_object(
    'qaRobotVersion','10.25.0','options',coalesce(p_options,'{}'::jsonb),'productionIsolation',true,'startedFrom','SUPER_ADMIN_PORTAL'
  )) returning * into v_run;
  return jsonb_build_object('runId',v_run.id,'status',v_run.status,'startedAt',v_run.started_at,'version','10.25.0');
end;
$$;

create or replace function public.erp_x_qa_robot_record_check(p_run_id uuid,p_check jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_key text:=trim(coalesce(p_check->>'checkKey',''));
  v_status text:=upper(coalesce(nullif(trim(p_check->>'status'),''),'PASSED'));
  v_layer text:=upper(coalesce(nullif(trim(p_check->>'layer'),''),'UI'));
  v_severity text:=upper(coalesce(nullif(trim(p_check->>'severity'),''),'HIGH'));
  v_total integer;v_passed integer;v_failed integer;v_warnings integer;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA total no disponible';
  end if;
  if v_key='' then raise exception 'checkKey es obligatorio'; end if;
  if v_status not in('RUNNING','PASSED','FAILED','WARNING','SKIPPED') then raise exception 'Estado QA inválido'; end if;
  if v_layer not in('DOMAIN','INTEGRITY','CONTRACT','UI','SANDBOX','RESPONSIVE','SECURITY','PERFORMANCE') then raise exception 'Capa QA inválida'; end if;
  if v_severity not in('CRITICAL','HIGH','MEDIUM','LOW','INFO') then v_severity:='HIGH'; end if;

  insert into erp_supply.qa_robot_checks(
    qa_run_id,check_key,layer,suite,module_code,order_id,status,severity,input,expected,actual,evidence,error_message,duration_ms,started_at,completed_at
  ) values(
    p_run_id,v_key,v_layer,coalesce(nullif(trim(p_check->>'suite'),''),'TOTAL'),nullif(trim(p_check->>'moduleCode'),''),
    erp_supply.safe_uuid(p_check->>'orderId'),v_status,v_severity,
    coalesce(p_check->'input','{}'::jsonb),coalesce(p_check->'expected','{}'::jsonb),coalesce(p_check->'actual','{}'::jsonb),coalesce(p_check->'evidence','{}'::jsonb),
    nullif(p_check->>'errorMessage',''),erp_supply.safe_integer(p_check->>'durationMs'),
    coalesce((p_check->>'startedAt')::timestamptz,now()),case when v_status='RUNNING' then null else now() end
  )
  on conflict(qa_run_id,check_key) do update set
    layer=excluded.layer,suite=excluded.suite,module_code=excluded.module_code,order_id=coalesce(excluded.order_id,erp_supply.qa_robot_checks.order_id),
    status=excluded.status,severity=excluded.severity,input=excluded.input,expected=excluded.expected,actual=excluded.actual,evidence=excluded.evidence,
    error_message=excluded.error_message,duration_ms=excluded.duration_ms,completed_at=excluded.completed_at;

  select count(*) filter(where status<>'SKIPPED'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='WARNING')
  into v_total,v_passed,v_failed,v_warnings
  from erp_supply.qa_robot_checks where qa_run_id=p_run_id;

  update erp_supply.qa_runs
  set total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,
      summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('warnings',v_warnings,'lastCheck',v_key,'lastUpdatedAt',now())
  where id=p_run_id;

  return jsonb_build_object('success',true,'runId',p_run_id,'checkKey',v_key,'status',v_status,'total',v_total,'passed',v_passed,'failed',v_failed,'warnings',v_warnings);
end;
$$;

create or replace function public.erp_x_qa_robot_finish_run(p_run_id uuid,p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_total integer:=0;v_passed integer:=0;v_failed integer:=0;v_warnings integer:=0;v_running integer:=0;v_status text;v_deleted integer:=0;
  v_order uuid;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA total no disponible';
  end if;

  if p_cleanup then
    for v_order in
      select id from erp_supply.orders
      where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT'
    loop
      begin
        perform public.erp_x_sandbox_delete(v_order);
        v_deleted:=v_deleted+1;
      exception when others then
        -- The run must preserve the cleanup failure as a real QA defect.
        perform public.erp_x_qa_robot_record_check(p_run_id,jsonb_build_object(
          'checkKey','CLEANUP-'||v_order::text,'layer','INTEGRITY','suite','SANDBOX_CLEANUP','status','FAILED','severity','HIGH','orderId',v_order,'errorMessage',sqlerrm
        ));
      end;
    end loop;
  end if;

  select count(*) filter(where status<>'SKIPPED'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='WARNING'),count(*) filter(where status='RUNNING')
  into v_total,v_passed,v_failed,v_warnings,v_running
  from erp_supply.qa_robot_checks where qa_run_id=p_run_id;
  v_status:=case when v_failed>0 or v_running>0 then 'FAILED' else 'PASSED' end;

  update erp_supply.qa_runs set
    status=v_status,total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),
    summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('warnings',v_warnings,'runningChecksAtFinish',v_running,'sandboxOrdersDeleted',v_deleted,'qaRobotVersion','10.25.0','finishedAt',now())
  where id=p_run_id;

  return jsonb_build_object('runId',p_run_id,'status',v_status,'total',v_total,'passed',v_passed,'failed',v_failed,'warnings',v_warnings,'sandboxOrdersDeleted',v_deleted);
end;
$$;

create or replace function public.erp_x_qa_robot_detail(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run erp_supply.qa_runs%rowtype;
begin
  select * into v_run from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT';
  if not found then raise exception 'Ejecución QA total no disponible'; end if;
  return jsonb_build_object(
    'run',to_jsonb(v_run),
    'checks',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',c.id,'checkKey',c.check_key,'layer',c.layer,'suite',c.suite,'moduleCode',c.module_code,'orderId',c.order_id,
      'status',c.status,'severity',c.severity,'input',c.input,'expected',c.expected,'actual',c.actual,'evidence',c.evidence,
      'errorMessage',c.error_message,'durationMs',c.duration_ms,'startedAt',c.started_at,'completedAt',c.completed_at
    ) order by c.started_at,c.check_key),'[]'::jsonb) from erp_supply.qa_robot_checks c where c.qa_run_id=p_run_id)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Read-only structural contract audit.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_system_contract()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_checks jsonb:='[]'::jsonb;
  v_ok boolean;
  v_missing integer;
begin
  select not exists(
    select 1 from erp_supply.role_module_permissions p where p.module_code='qa' and p.role_code<>'super_admin' and p.can_read
  ) into v_ok;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','QA_SUPERADMIN_ONLY','success',v_ok,'detail','El módulo QA no puede ser leído por otros roles.'));

  select count(*) into v_missing from erp_supply.modules m
  where m.active and not exists(select 1 from erp_supply.role_module_permissions p where p.role_code='super_admin' and p.module_code=m.code and p.can_read);
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','SUPERADMIN_ALL_MODULES','success',v_missing=0,'detail',v_missing||' módulos activos sin lectura Super Admin.'));

  select count(*) into v_missing from erp_supply.workflow_steps s
  where s.active and not exists(select 1 from erp_supply.step_roles sr where sr.step_code=s.code and sr.role_code='super_admin' and sr.can_override);
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','SUPERADMIN_ALL_STEPS','success',v_missing=0,'detail',v_missing||' etapas sin override Super Admin.'));

  select count(*) into v_missing from erp_supply.orders o
  where o.organization_id=erp_supply.current_org_id() and o.source='QA_BOT' and not o.is_test;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','QA_BOT_ISOLATION','success',v_missing=0,'detail',v_missing||' pedidos QA_BOT no marcados como TEST.'));

  select count(*) into v_missing from erp_supply.orders o
  where o.organization_id=erp_supply.current_org_id() and coalesce((o.metadata->>'manualSandbox')::boolean,false) and not o.is_test;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','SANDBOX_FLAG_ISOLATION','success',v_missing=0,'detail',v_missing||' pedidos productivos con manualSandbox.'));

  v_ok:=to_regprocedure('public.erp_x_run_qa_v10_22(boolean)') is not null
     and to_regprocedure('public.erp_x_flow_integrity()') is not null
     and to_regprocedure('public.erp_x_work_health()') is not null
     and to_regprocedure('public.erp_x_sandbox_create(jsonb)') is not null
     and to_regprocedure('public.erp_x_qa_robot_create_run(jsonb)') is not null
     and to_regprocedure('public.erp_x_qa_robot_branch_suite(uuid)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','QA_ENGINE_CONTRACT','success',v_ok,'detail','Motores matriz, integridad, Workforce, Sandbox y Robot disponibles.'));

  select count(*) into v_missing
  from (values('PVC'),('PVN'),('PVE'),('PVP')) v(code)
  where not exists(select 1 from erp_supply.order_types t where t.code=v.code and t.active);
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','ORDER_TYPES_CANONICAL','success',v_missing=0,'detail',v_missing||' tipos de pedido canónicos faltantes.'));

  select count(*) into v_missing
  from (values('CLIENT_POINT'),('CLIENT_PICKUP'),('LOCAL_DISPATCH'),('NATIONAL_DISPATCH')) v(code)
  where not exists(select 1 from erp_supply.delivery_routes r where r.code=v.code and r.active);
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','DELIVERY_ROUTES_CANONICAL','success',v_missing=0,'detail',v_missing||' rutas de entrega canónicas faltantes.'));

  return jsonb_build_object(
    'success',not exists(select 1 from jsonb_array_elements(v_checks) c where coalesce((c->>'success')::boolean,false)=false),
    'checks',v_checks,'version','10.25.0'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Flexible isolated order seed for UI robot / branch probes.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_seed_order(p_run_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_type text:=upper(coalesce(nullif(trim(p_payload->>'orderType'),''),'PVC'));
  v_payment text:=upper(coalesce(nullif(trim(p_payload->>'paymentCondition'),''),'CREDIT'));
  v_route text:=upper(coalesce(nullif(trim(p_payload->>'deliveryRoute'),''),'LOCAL_DISPATCH'));
  v_priority text:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_cut boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresCut'),false);
  v_purchase boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresPurchase'),v_type='PVE');
  v_arrears boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'hasCreditArrears'),false);
  v_cash_hold boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'heldByCashier'),false);
  v_step text:=upper(nullif(trim(p_payload->>'stepCode'),''));
  v_scenario text:=coalesce(nullif(trim(p_payload->>'scenarioKey'),''),'QA-ROBOT');
  v_num text;v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_type and active) then raise exception 'Tipo de pedido QA inválido: %',v_type; end if;
  if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago QA inválida: %',v_payment; end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta QA inválida: %',v_route; end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then v_priority:='MEDIUM'; end if;
  if v_step is null then v_step:=erp_supply.initial_step(v_type,v_payment,v_purchase,v_arrears,v_cash_hold); end if;
  if not exists(select 1 from erp_supply.workflow_steps where code=v_step and active and not terminal) then raise exception 'Etapa QA inválida: %',v_step; end if;

  v_num:='TEST-QA-'||to_char(clock_timestamp(),'YYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,5);
  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,client_name,client_document,client_city,client_address,client_phone,
    seller_profile_id,current_step_code,status,priority,requires_cut,requires_purchase,current_assignee_id,current_role_code,source,is_history,is_test,qa_run_id,metadata
  ) values(
    v_org,v_num,'TOTAL-QA-'||v_scenario,v_type,v_payment,v_route,'CLIENTE ROBOT QA · NO PRODUCTIVO','QA-ROBOT','TULUÁ','DIRECCIÓN FICTICIA QA','0000000000',
    v_actor,v_step,'ASSIGNED',v_priority,v_cut,v_purchase,v_actor,'super_admin','QA_BOT',false,true,p_run_id,
    jsonb_build_object('manualSandbox',true,'qaRobot',true,'qaRobotVersion','10.25.0','scenario',v_scenario,'hasCreditArrears',v_arrears,'heldByCashier',v_cash_hold,'excludedFromProduction',true,'createdBy',v_actor)
  ) returning * into v_order;

  insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,item_status,metadata)
  values(v_order.id,1,'QA-MAT-001','QA-REF-001','Material sintético Robot QA',case when v_cut then 3 else 5 end,case when v_cut then 'M' else 'UND' end,v_cut,case when v_cut then 25 else null end,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'qaRobot',true,'receptionActive',true)),
        (v_order.id,2,'QA-MAT-002','QA-REF-002','Segundo material sintético Robot QA',4,'UND',false,null,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'qaRobot',true,'receptionActive',true));

  if v_cut then
    perform erp_supply.sync_parallel_cut_requirements(v_order.id);
  end if;

  select * into v_task from erp_supply.create_task(v_order,v_step,1);
  update erp_supply.order_tasks set status='ASSIGNED',assigned_profile_id=v_actor,assigned_role_code='super_admin',assigned_at=now(),metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('sandbox',true,'qaRobot',true) where id=v_task.id;
  update erp_supply.orders set status='ASSIGNED',current_assignee_id=v_actor,current_role_code='super_admin',metadata=metadata||jsonb_build_object('sandboxTaskId',v_task.id),updated_at=now() where id=v_order.id;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,v_order.id,v_task.id,'SANDBOX','QA_ROBOT_SEEDED',null,v_step,v_actor,'super_admin',jsonb_build_object('scenario',v_scenario,'qaRunId',p_run_id,'excludedFromProduction',true));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'stepCode',v_step,'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'sandbox',true);
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Branch suite: approvals, route return/reopen and cancellation cleanup.
--    This complements the 336 end-to-end happy paths and the 10 enterprise
--    controls with branch families introduced after the original QA suite.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_branch_suite(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_seed jsonb;v_order uuid;v_req uuid;v_ok boolean;v_error text;
  v_checks jsonb:='[]'::jsonb;
  v_type text;
  v_total integer:=0;v_passed integer:=0;v_failed integer:=0;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA total no disponible';
  end if;

  -- Priority approval: approved branch.
  begin
    v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-PRIORITY-APPROVED','stepCode','RECEPCION_PEDIDO','orderType','PVC'));
    v_order:=(v_seed->>'orderId')::uuid;
    perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','PRIORITY','priority','URGENT','reason','QA prioridad aprobada','assignedRole','gerencia'),null,'QA25-PRIORITY-A-'||v_order::text);
    select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='PRIORITY' and status='PENDING' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','QA aprueba prioridad');
    select o.priority='URGENT' and a.status='EXECUTED' into v_ok from erp_supply.orders o join erp_supply.approval_requests a on a.id=v_req where o.id=v_order;
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','PRIORITY_APPROVED','success',coalesce(v_ok,false),'orderId',v_order,'detail','Solicitud de prioridad aprobada y ejecutada.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','PRIORITY_APPROVED','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
  end;

  -- Priority approval: rejected branch must not mutate the order priority.
  v_order:=null;v_req:=null;
  begin
    v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-PRIORITY-REJECTED','stepCode','RECEPCION_PEDIDO','orderType','PVC','priority','MEDIUM'));
    v_order:=(v_seed->>'orderId')::uuid;
    perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','PRIORITY','priority','CRITICAL','reason','QA prioridad rechazada','assignedRole','gerencia'),null,'QA25-PRIORITY-R-'||v_order::text);
    select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='PRIORITY' and status='PENDING' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'REJECTED','QA rechaza prioridad');
    select o.priority='MEDIUM' and a.status='REJECTED' into v_ok from erp_supply.orders o join erp_supply.approval_requests a on a.id=v_req where o.id=v_order;
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','PRIORITY_REJECTED','success',coalesce(v_ok,false),'orderId',v_order,'detail','Rechazo preserva la prioridad original.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','PRIORITY_REJECTED','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
  end;

  -- Route change while the order is already in dispatch must rebuild its task.
  v_order:=null;v_req:=null;
  begin
    v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-ROUTE-CHANGE','stepCode','LOCAL_DISPATCH','orderType','PVC','deliveryRoute','LOCAL_DISPATCH'));
    v_order:=(v_seed->>'orderId')::uuid;
    perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','ROUTE_CHANGE','route','NATIONAL_DISPATCH','reason','QA cambio de ruta','assignedRole','gerencia'),null,'QA25-ROUTE-'||v_order::text);
    select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='ROUTE_CHANGE' and status='PENDING' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','QA aprueba cambio de ruta');
    select o.delivery_route_code='NATIONAL_DISPATCH' and o.current_step_code='NATIONAL_DISPATCH' and exists(
      select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.step_code='NATIONAL_DISPATCH' and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    ) into v_ok from erp_supply.orders o where o.id=v_order;
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','ROUTE_CHANGE_APPROVED','success',coalesce(v_ok,false),'orderId',v_order,'detail','Cambio de ruta recrea la tarea de despacho correcta.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','ROUTE_CHANGE_APPROVED','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
  end;

  -- Reopen a closed test order and make sure CLOSURE is active again.
  v_order:=null;v_req:=null;
  begin
    v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-REOPEN','stepCode','CLOSURE','orderType','PVC'));
    v_order:=(v_seed->>'orderId')::uuid;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=now(),result_code='QA_CLOSED' where order_id=v_order and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
    update erp_supply.orders set status='CLOSED',current_step_code='CLOSED',closed_at=now(),current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order;
    perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','REOPEN','reason','QA reapertura','assignedRole','auditoria'),null,'QA25-REOPEN-'||v_order::text);
    select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='REOPEN' and status='PENDING' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','QA aprueba reapertura');
    select o.status='QUEUED' and o.current_step_code='CLOSURE' and exists(
      select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.step_code='CLOSURE' and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    ) into v_ok from erp_supply.orders o where o.id=v_order;
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','REOPEN_APPROVED','success',coalesce(v_ok,false),'orderId',v_order,'detail','Reapertura devuelve el pedido a CLOSURE con tarea activa.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','REOPEN_APPROVED','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
  end;

  -- Generic exception approvals must complete their lifecycle without altering the route.
  foreach v_type in array array['STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION'] loop
    v_order:=null;v_req:=null;
    begin
      v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-'||v_type,'stepCode','RECEPCION_PEDIDO','orderType','PVC'));
      v_order:=(v_seed->>'orderId')::uuid;
      perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType',v_type,'reason','QA '||v_type,'assignedRole','auditoria'),null,'QA25-'||v_type||'-'||v_order::text);
      select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type=v_type and status='PENDING' order by created_at desc limit 1;
      perform public.erp_x_decide_approval(v_req,'APPROVED','QA aprueba '||v_type);
      select a.status='EXECUTED' into v_ok from erp_supply.approval_requests a where a.id=v_req;
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key',v_type||'_APPROVED','success',coalesce(v_ok,false),'orderId',v_order,'detail','Ciclo de aprobación ejecutado.'));
    exception when others then
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key',v_type||'_APPROVED','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
    end;
  end loop;

  -- Cancellation cannot use the product approval RPC on TEST orders by design, but
  -- the cleanup invariant itself must still be exercised over an isolated cut order.
  v_order:=null;
  begin
    v_seed:=public.erp_x_qa_robot_seed_order(p_run_id,jsonb_build_object('scenarioKey','BRANCH-CANCELLATION-CLEANUP','stepCode','ALISTAMIENTO','orderType','PVC','requiresCut',true));
    v_order:=(v_seed->>'orderId')::uuid;
    update erp_supply.orders set status='CANCELLED',cancelled_at=now(),version=version+1,updated_at=now() where id=v_order;
    select
      not exists(select 1 from erp_supply.order_tasks t where t.order_id=v_order and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED'))
      and not exists(select 1 from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=v_order and s.ended_at is null)
      and exists(select 1 from erp_supply.cut_requirements r where r.order_id=v_order)
      and not exists(select 1 from erp_supply.cut_requirements r where r.order_id=v_order and (r.process_status<>'READY' or r.collection_status<>'COLLECTED' or coalesce(r.resolution_code,'')<>'NO_CUT'))
    into v_ok;
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','CANCELLATION_CLEANUP','success',coalesce(v_ok,false),'orderId',v_order,'detail','Cancelación retira tareas, sesiones y Corte pendiente del pedido TEST.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','CANCELLATION_CLEANUP','success',false,'orderId',v_order,'detail',sqlstate||' · '||sqlerrm));
  end;

  -- Dedicated production cancellation policy is checked as a contract because its
  -- RPC intentionally refuses TEST orders and only Jefatura Logística can decide it.
  begin
    v_ok:=pg_get_functiondef('public.erp_x_request_order_cancellation(uuid,text)'::regprocedure) like '%Los pedidos Sandbox no usan la aprobación productiva de cancelación%'
      and pg_get_functiondef('public.erp_x_decide_order_cancellation(uuid,text,text)'::regprocedure) like '%has_role(''jefe_logistica'')%';
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','CANCELLATION_AUTH_CONTRACT','success',coalesce(v_ok,false),'detail','Cancelación productiva conserva aislamiento TEST y decisión exclusiva de Jefatura Logística.'));
  exception when others then
    v_checks:=v_checks||jsonb_build_array(jsonb_build_object('key','CANCELLATION_AUTH_CONTRACT','success',false,'detail',sqlstate||' · '||sqlerrm));
  end;

  select count(*),count(*) filter(where coalesce((x->>'success')::boolean,false)),count(*) filter(where not coalesce((x->>'success')::boolean,false))
  into v_total,v_passed,v_failed from jsonb_array_elements(v_checks) x;
  return jsonb_build_object('success',v_failed=0,'total',v_total,'passed',v_passed,'failed',v_failed,'checks',v_checks,'version','10.25.0');
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Explicit cleanup endpoint for abandoned runs.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_cleanup(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_id uuid;v_deleted integer:=0;v_failed integer:=0;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  for v_id in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
    begin perform public.erp_x_sandbox_delete(v_id);v_deleted:=v_deleted+1;exception when others then v_failed:=v_failed+1;end;
  end loop;
  return jsonb_build_object('success',v_failed=0,'deleted',v_deleted,'failed',v_failed,'runId',p_run_id);
end;
$$;

revoke all on function public.erp_x_qa_robot_plan() from public,anon;
revoke all on function public.erp_x_qa_robot_create_run(jsonb) from public,anon;
revoke all on function public.erp_x_qa_robot_record_check(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_qa_robot_finish_run(uuid,boolean) from public,anon;
revoke all on function public.erp_x_qa_robot_detail(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_system_contract() from public,anon;
revoke all on function public.erp_x_qa_robot_seed_order(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_qa_robot_branch_suite(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_cleanup(uuid) from public,anon;

grant execute on function public.erp_x_qa_robot_plan() to authenticated;
grant execute on function public.erp_x_qa_robot_create_run(jsonb) to authenticated;
grant execute on function public.erp_x_qa_robot_record_check(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_qa_robot_finish_run(uuid,boolean) to authenticated;
grant execute on function public.erp_x_qa_robot_detail(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_system_contract() to authenticated;
grant execute on function public.erp_x_qa_robot_seed_order(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_qa_robot_branch_suite(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_cleanup(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
