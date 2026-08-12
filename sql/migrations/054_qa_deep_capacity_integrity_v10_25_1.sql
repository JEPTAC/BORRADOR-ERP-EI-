-- ERP EI V10.25.1 · QA profundo, diagnóstico fiel y capacidad
-- Corrige el error FK de qa_scenarios, conserva el error original de cada caso,
-- agrega campañas profundas por caso aislado y registra pruebas de capacidad.

begin;

-- ---------------------------------------------------------------------------
-- 1. qa_scenarios debe conservar el diagnóstico aunque el pedido de una
--    subtransacción haya sido revertido.
-- ---------------------------------------------------------------------------
alter table erp_supply.qa_scenarios
  add column if not exists failure_step_code text,
  add column if not exists failure_action text,
  add column if not exists error_sqlstate text,
  add column if not exists diagnostics jsonb not null default '{}'::jsonb;

create or replace function erp_supply.qa_existing_order_id(p_order_id uuid)
returns uuid
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select o.id from erp_supply.orders o where o.id=p_order_id
$$;
revoke all on function erp_supply.qa_existing_order_id(uuid) from public,anon,authenticated;

-- El registrador histórico tampoco debe romperse si el pedido fue revertido o
-- eliminado antes de guardar el resultado del control.
create or replace function erp_supply.qa_record(
  p_run_id uuid,p_key text,p_input jsonb,p_expected jsonb,p_actual jsonb,p_ok boolean,p_error text default null,p_order_id uuid default null
)
returns void
language sql
security definer
set search_path=erp_supply,public
as $$
  insert into erp_supply.qa_scenarios(
    qa_run_id,scenario_key,order_id,input,expected_path,actual_path,status,error_message,error_sqlstate,diagnostics,completed_at
  )
  values(
    p_run_id,p_key,erp_supply.qa_existing_order_id(p_order_id),
    coalesce(p_input,'{}'::jsonb),coalesce(p_expected,'[]'::jsonb),coalesce(p_actual,'[]'::jsonb),
    case when p_ok then 'PASSED' else 'FAILED' end,p_error,
    case when p_error ~ '^[0-9A-Z]{5}[[:space:]]*[-·]' then substring(p_error from '^([0-9A-Z]{5})') else null end,
    case when p_order_id is not null and erp_supply.qa_existing_order_id(p_order_id) is null
      then jsonb_build_object('rolledBackOrDeletedOrderId',p_order_id,'orderReferencePreserved',true)
      else '{}'::jsonb end,
    now()
  )
  on conflict(qa_run_id,scenario_key) do update set
    order_id=excluded.order_id,input=excluded.input,expected_path=excluded.expected_path,actual_path=excluded.actual_path,
    status=excluded.status,error_message=excluded.error_message,error_sqlstate=excluded.error_sqlstate,
    diagnostics=erp_supply.qa_scenarios.diagnostics||excluded.diagnostics,completed_at=excluded.completed_at
$$;
revoke all on function erp_supply.qa_record(uuid,text,jsonb,jsonb,jsonb,boolean,text,uuid) from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 2. Matriz 336: raíz corregida. Cada escenario limpia variables antes de
--    comenzar y el EXCEPTION nunca referencia un pedido que dejó de existir.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_run_qa_matrix(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
  v_financial jsonb;
  v_states jsonb:=jsonb_build_array(
    jsonb_build_object('code','PVC-NORMAL','orderType','PVC','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVC-MORA','orderType','PVC','hasCreditArrears',true,'heldByCashier',false),
    jsonb_build_object('code','PVN-NORMAL','orderType','PVN','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVN-CAJA','orderType','PVN','hasCreditArrears',false,'heldByCashier',true),
    jsonb_build_object('code','PVE','orderType','PVE','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-NORMAL','orderType','PVP','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-MORA','orderType','PVP','hasCreditArrears',true,'heldByCashier',false)
  );
  v_type text;v_payment text;v_route text;v_cut boolean;v_purchase boolean;
  v_has_credit_arrears boolean;v_held_by_cashier boolean;v_requires_purchase boolean;
  v_key text;v_initial text;v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;
  v_scenario erp_supply.qa_scenarios%rowtype;v_expected jsonb;v_actual jsonb;v_step text;v_guard integer;
  v_passed integer:=0;v_failed integer:=0;v_total integer:=0;v_error text;
  v_failure_step text;v_failure_action text;v_safe_order uuid;
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'El bot QA solo puede ser ejecutado por Super Admin' using errcode='42501';
  end if;

  insert into erp_supply.qa_runs(organization_id,requested_by,total_scenarios,summary)
  values(v_org,v_actor,336,jsonb_build_object(
    'matrix','7 financial entry states × 3 payments × 4 routes × 2 cut × 2 purchase',
    'routingVersion','10.22.0','qaRecorderVersion','10.25.1',
    'initialStepSignature','initial_step(text,text,boolean,boolean,boolean)'
  )) returning * into v_run;

  for v_financial in select value from jsonb_array_elements(v_states) loop
    v_type:=v_financial->>'orderType';
    v_has_credit_arrears:=coalesce((v_financial->>'hasCreditArrears')::boolean,false);
    v_held_by_cashier:=coalesce((v_financial->>'heldByCashier')::boolean,false);
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_total:=v_total+1;v_error:=null;v_order:=null;v_task:=null;v_actual:='[]'::jsonb;v_safe_order:=null;
            v_requires_purchase:=v_purchase or v_type='PVE';
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_financial->>'code',v_payment,v_route,v_cut,v_purchase);
            v_initial:=erp_supply.initial_step(v_type,v_payment,v_requires_purchase,v_has_credit_arrears,v_held_by_cashier);
            v_failure_step:=v_initial;v_failure_action:='BUILD_EXPECTED_PATH';

            v_expected:=jsonb_build_array(v_initial);v_step:=v_initial;v_guard:=0;
            while v_step<>'CLOSED' and v_guard<20 loop
              v_step:=erp_supply.next_step(v_step,v_type,v_payment,v_route,v_cut,v_requires_purchase);
              v_expected:=v_expected||jsonb_build_array(v_step);v_guard:=v_guard+1;
            end loop;

            insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,input,expected_path,diagnostics)
            values(v_run.id,v_key,jsonb_build_object(
              'orderType',v_type,'payment',v_payment,'route',v_route,'requiresCut',v_cut,'requiresPurchase',v_purchase,
              'hasCreditArrears',v_has_credit_arrears,'heldByCashier',v_held_by_cashier,'routingVariant',v_financial->>'code'
            ),v_expected,jsonb_build_object('qaRecorderVersion','10.25.1')) returning * into v_scenario;

            begin
              v_failure_action:='CREATE_ORDER';
              insert into erp_supply.orders(
                organization_id,order_number,order_type_code,payment_condition_code,delivery_route_code,client_name,
                seller_profile_id,current_step_code,status,requires_cut,requires_purchase,source,is_test,qa_run_id,metadata
              ) values(
                v_org,'QA-'||replace(v_run.id::text,'-','')||'-'||lpad(v_total::text,3,'0'),v_type,v_payment,v_route,
                'Cliente QA '||v_key,v_actor,v_initial,'QUEUED',v_cut,v_requires_purchase,'QA_BOT',true,v_run.id,
                jsonb_build_object('scenario',v_key,'hasCreditArrears',v_has_credit_arrears,'heldByCashier',v_held_by_cashier,'routingVersion','10.22.0','qaRobot',true)
              ) returning * into v_order;

              v_failure_action:='CREATE_ITEM';
              insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,metadata)
              values(v_order.id,1,'QA-'||v_type,'QA-'||v_type,'Material de prueba automatizada',1,'UND',v_cut,
                case when v_cut then 10 else null end,jsonb_build_object('qa',true,'routingVersion','10.22.0'));

              v_failure_action:='CREATE_TASK';
              select * into v_task from erp_supply.create_task(v_order,v_initial,1);
              v_actual:=jsonb_build_array(v_initial);v_guard:=0;

              loop
                select * into v_order from erp_supply.orders where id=v_order.id;
                exit when v_order.status='CLOSED' or v_guard>=20;
                v_failure_step:=v_order.current_step_code;v_failure_action:='START';
                perform erp_supply.execute_action_internal(v_order.id,'START',jsonb_build_object('detail','Inicio QA'),v_actor,true,null,v_key||'-START-'||v_guard);
                v_failure_action:='COMPLETE';
                perform erp_supply.execute_action_internal(v_order.id,'COMPLETE',jsonb_build_object('detail','Finalización QA'),v_actor,true,null,v_key||'-COMPLETE-'||v_guard);
                select * into v_order from erp_supply.orders where id=v_order.id;
                v_actual:=v_actual||jsonb_build_array(v_order.current_step_code);v_guard:=v_guard+1;
              end loop;

              if v_order.status='CLOSED' and v_actual=v_expected then
                update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=v_actual,status='PASSED',completed_at=now(),
                  failure_step_code=null,failure_action=null,error_sqlstate=null,error_message=null,
                  diagnostics=diagnostics||jsonb_build_object('guardIterations',v_guard,'qaRecorderVersion','10.25.1')
                where id=v_scenario.id;v_passed:=v_passed+1;
              else
                v_error:=format('Estado final %s; paso %s; ruta esperada %s; ruta real %s',v_order.status,v_order.current_step_code,v_expected,v_actual);
                update erp_supply.qa_scenarios set order_id=erp_supply.qa_existing_order_id(v_order.id),actual_path=v_actual,status='FAILED',error_message=v_error,
                  failure_step_code=v_order.current_step_code,failure_action='VERIFY_FINAL_ROUTE',diagnostics=diagnostics||jsonb_build_object('guardIterations',v_guard,'qaRecorderVersion','10.25.1'),completed_at=now()
                where id=v_scenario.id;v_failed:=v_failed+1;
              end if;
            exception when others then
              v_error:=sqlstate||' · '||sqlerrm;
              v_safe_order:=erp_supply.qa_existing_order_id(v_order.id);
              update erp_supply.qa_scenarios set
                order_id=v_safe_order,actual_path=coalesce(v_actual,'[]'::jsonb),status='FAILED',error_message=v_error,error_sqlstate=sqlstate,
                failure_step_code=v_failure_step,failure_action=v_failure_action,
                diagnostics=diagnostics||jsonb_build_object(
                  'originalOrderId',v_order.id,'orderRolledBack',v_order.id is not null and v_safe_order is null,
                  'failureStep',v_failure_step,'failureAction',v_failure_action,'qaRecorderVersion','10.25.1'
                ),completed_at=now()
              where id=v_scenario.id;v_failed:=v_failed+1;
            end;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;

  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,total_scenarios=v_total,
    passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
      'cleanup',p_cleanup,'currentRouting',true,'financialEntryVariants',7,'qaRecorderVersion','10.25.1','foreignKeySafeDiagnostics',true
    ) where id=v_run.id returning * into v_run;

  if p_cleanup then delete from erp_supply.orders where qa_run_id=v_run.id and is_test and source='QA_BOT'; end if;
  return jsonb_build_object('runId',v_run.id,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,
    'completedAt',v_run.completed_at,'matrixVersion','10.25.1','diagnosticsPreserved',true);
end;
$$;
revoke all on function public.erp_x_run_qa_matrix(boolean) from public,anon;
grant execute on function public.erp_x_run_qa_matrix(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. El ledger del Robot también valida el FK antes de guardar order_id.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_record_check(p_run_id uuid,p_check jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_key text:=trim(coalesce(p_check->>'checkKey',''));
  v_status text:=upper(coalesce(nullif(trim(p_check->>'status'),''),'PASSED'));
  v_layer text:=upper(coalesce(nullif(trim(p_check->>'layer'),''),'UI'));
  v_severity text:=upper(coalesce(nullif(trim(p_check->>'severity'),''),'HIGH'));
  v_requested_order uuid:=erp_supply.safe_uuid(p_check->>'orderId');v_safe_order uuid;
  v_total integer;v_passed integer;v_failed integer;v_warnings integer;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  if v_key='' then raise exception 'checkKey es obligatorio'; end if;
  if v_status not in('RUNNING','PASSED','FAILED','WARNING','SKIPPED') then raise exception 'Estado QA inválido'; end if;
  if v_layer not in('DOMAIN','INTEGRITY','CONTRACT','UI','SANDBOX','RESPONSIVE','SECURITY','PERFORMANCE') then raise exception 'Capa QA inválida'; end if;
  if v_severity not in('CRITICAL','HIGH','MEDIUM','LOW','INFO') then v_severity:='HIGH'; end if;
  v_safe_order:=erp_supply.qa_existing_order_id(v_requested_order);

  insert into erp_supply.qa_robot_checks(qa_run_id,check_key,layer,suite,module_code,order_id,status,severity,input,expected,actual,evidence,error_message,duration_ms,started_at,completed_at)
  values(p_run_id,v_key,v_layer,coalesce(nullif(trim(p_check->>'suite'),''),'TOTAL'),nullif(trim(p_check->>'moduleCode'),''),v_safe_order,v_status,v_severity,
    coalesce(p_check->'input','{}'::jsonb),coalesce(p_check->'expected','{}'::jsonb),
    case when v_requested_order is not null and v_safe_order is null then
      case when jsonb_typeof(coalesce(p_check->'actual','{}'::jsonb))='object'
        then coalesce(p_check->'actual','{}'::jsonb)||jsonb_build_object('rolledBackOrDeletedOrderId',v_requested_order)
        else jsonb_build_object('value',coalesce(p_check->'actual','null'::jsonb),'rolledBackOrDeletedOrderId',v_requested_order)
      end
    else coalesce(p_check->'actual','{}'::jsonb) end,
    coalesce(p_check->'evidence','{}'::jsonb),nullif(p_check->>'errorMessage',''),erp_supply.safe_integer(p_check->>'durationMs'),
    coalesce((p_check->>'startedAt')::timestamptz,now()),case when v_status='RUNNING' then null else now() end)
  on conflict(qa_run_id,check_key) do update set
    layer=excluded.layer,suite=excluded.suite,module_code=excluded.module_code,
    order_id=case when excluded.order_id is not null then excluded.order_id else erp_supply.qa_robot_checks.order_id end,
    status=excluded.status,severity=excluded.severity,input=excluded.input,expected=excluded.expected,actual=excluded.actual,evidence=excluded.evidence,
    error_message=excluded.error_message,duration_ms=excluded.duration_ms,completed_at=excluded.completed_at;

  select count(*) filter(where status<>'SKIPPED'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='WARNING')
  into v_total,v_passed,v_failed,v_warnings from erp_supply.qa_robot_checks where qa_run_id=p_run_id;
  update erp_supply.qa_runs set total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,
    summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('warnings',v_warnings,'lastCheck',v_key,'lastUpdatedAt',now(),'qaRecorderVersion','10.25.1')
  where id=p_run_id;
  return jsonb_build_object('success',true,'runId',p_run_id,'checkKey',v_key,'status',v_status,'total',v_total,'passed',v_passed,'failed',v_failed,'warnings',v_warnings);
end;
$$;
revoke all on function public.erp_x_qa_robot_record_check(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_qa_robot_record_check(uuid,jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Campaña profunda por casos aislados. Un error en un caso nunca revierte
--    ni tapa los resultados de los demás.
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.qa_deep_cases(
  id uuid primary key default gen_random_uuid(),
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  case_key text not null,
  campaign_mode text not null check(campaign_mode in('TOTAL','EXTREME')),
  family text not null,
  specification jsonb not null default '{}'::jsonb,
  order_id uuid references erp_supply.orders(id) on delete set null,
  status text not null default 'PENDING' check(status in('PENDING','RUNNING','PASSED','FAILED','SKIPPED')),
  result jsonb not null default '{}'::jsonb,
  error_sqlstate text,
  error_message text,
  duration_ms integer,
  started_at timestamptz,
  completed_at timestamptz,
  unique(qa_run_id,case_key)
);
create index if not exists idx_qa_deep_cases_run_status on erp_supply.qa_deep_cases(qa_run_id,status,family);
revoke all on erp_supply.qa_deep_cases from public,anon,authenticated;

create or replace function public.erp_x_qa_robot_build_deep_campaign(p_run_id uuid,p_mode text default 'TOTAL')
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_mode text:=upper(coalesce(nullif(trim(p_mode),''),'TOTAL'));v_type text;v_step text;v_issue text;v_req text;v_decision text;
  v_count integer:=0;v_financial jsonb;v_payment text;v_route text;v_cut boolean;v_purchase boolean;v_requires_purchase boolean;
  v_initial text;v_path_step text;v_guard int;v_base_key text;
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
  if v_mode not in('TOTAL','EXTREME') then raise exception 'Modo de campaña QA inválido'; end if;
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  if exists(select 1 from erp_supply.qa_deep_cases c where c.qa_run_id=p_run_id and c.status='RUNNING') then raise exception 'La campaña ya tiene casos en ejecución'; end if;
  delete from erp_supply.qa_deep_cases where qa_run_id=p_run_id;

  -- TOTAL: cada tipo de pedido en cada etapa activa prueba Nota, Novedad,
  -- Reporte y Espera/Reanudación. Esto cruza reglas transversales con todas las
  -- posiciones operativas, sin depender de botones del frontend.
  foreach v_type in array array['PVC','PVN','PVE','PVP'] loop
    for v_step in select code from erp_supply.workflow_steps where active and not terminal order by sort_order loop
      foreach v_issue in array array['NOTE','NOVELTY','REPORT'] loop
        insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
        values(p_run_id,format('DEEP-%s-%s-ISSUE-%s',v_type,v_step,v_issue),v_mode,'ISSUE',jsonb_build_object(
          'orderType',v_type,'stepCode',v_step,'issueType',v_issue,'paymentCondition',case when v_type='PVN' then 'CASH' else 'CREDIT' end,
          'deliveryRoute',case when v_step='NATIONAL_DISPATCH' then 'NATIONAL_DISPATCH' else 'LOCAL_DISPATCH' end,
          'requiresPurchase',(v_type='PVE' or v_step in('COMPRAS','RECEPCION_MERCANCIA')),'requiresCut',(v_step='CORTE')
        )) on conflict(qa_run_id,case_key) do nothing;
      end loop;
      insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
      values(p_run_id,format('DEEP-%s-%s-WAIT-RESUME',v_type,v_step),v_mode,'WAIT_RESUME',jsonb_build_object(
        'orderType',v_type,'stepCode',v_step,'paymentCondition',case when v_type='PVN' then 'CASH' else 'CREDIT' end,
        'deliveryRoute',case when v_step='NATIONAL_DISPATCH' then 'NATIONAL_DISPATCH' else 'LOCAL_DISPATCH' end,
        'requiresPurchase',(v_type='PVE' or v_step in('COMPRAS','RECEPCION_MERCANCIA')),'requiresCut',(v_step='CORTE')
      )) on conflict(qa_run_id,case_key) do nothing;
    end loop;

    foreach v_req in array array['PRIORITY','ROUTE_CHANGE','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION','REOPEN','CANCELLATION'] loop
      foreach v_decision in array array['APPROVED','REJECTED'] loop
        insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
        values(p_run_id,format('DEEP-%s-APPROVAL-%s-%s',v_type,v_req,v_decision),v_mode,
          case when v_req='CANCELLATION' then 'CANCELLATION' when v_req='REOPEN' then 'REOPEN' else 'APPROVAL' end,
          jsonb_build_object(
            'orderType',v_type,'requestType',v_req,'decision',v_decision,
            'stepCode',case when v_req='ROUTE_CHANGE' then 'LOCAL_DISPATCH' when v_req='REOPEN' then 'CLOSURE' else 'RECEPCION_PEDIDO' end,
            'paymentCondition',case when v_type='PVN' then 'CASH' else 'CREDIT' end,'deliveryRoute','LOCAL_DISPATCH','requiresPurchase',(v_type='PVE')
          )) on conflict(qa_run_id,case_key) do nothing;
      end loop;
    end loop;
  end loop;

  -- EXTREME agrega el cruce semánticamente exhaustivo de las 336 entradas
  -- comerciales con CADA etapa real de su ruta. En cada posición prueba:
  -- NOTE, NOVELTY, REPORT, WAIT/RESUME, PRIORITY approve/reject y CANCELLATION
  -- approve/reject. Además, por cada combinación base prueba las cuatro
  -- excepciones genéricas, cambio de ruta, reapertura y no-entrega/retorno.
  -- No genera permutaciones infinitas (p.ej. 17 novedades repetidas), sino cada
  -- transición y rama de negocio finita al menos una vez por contexto aplicable.
  if v_mode='EXTREME' then
    for v_financial in select value from jsonb_array_elements(v_states) loop
      v_type:=v_financial->>'orderType';
      foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
        foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
          foreach v_cut in array array[false,true] loop
            foreach v_purchase in array array[false,true] loop
              v_requires_purchase:=v_purchase or v_type='PVE';
              v_base_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_financial->>'code',v_payment,v_route,v_cut,v_purchase);
              v_initial:=erp_supply.initial_step(v_type,v_payment,v_requires_purchase,
                coalesce((v_financial->>'hasCreditArrears')::boolean,false),coalesce((v_financial->>'heldByCashier')::boolean,false));
              v_path_step:=v_initial;v_guard:=0;
              while v_path_step<>'CLOSED' and v_guard<20 loop
                -- Registros transversales y pausa/reanudación en cada etapa.
                foreach v_issue in array array['NOTE','NOVELTY','REPORT'] loop
                  insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                  values(p_run_id,format('X-%s-%s-%s',v_base_key,v_path_step,v_issue),v_mode,'ISSUE',jsonb_build_object(
                    'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                    'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                    'stepCode',v_path_step,'issueType',v_issue,'baseCombination',v_base_key
                  )) on conflict(qa_run_id,case_key) do nothing;
                end loop;
                insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                values(p_run_id,format('X-%s-%s-WAIT-RESUME',v_base_key,v_path_step),v_mode,'WAIT_RESUME',jsonb_build_object(
                  'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                  'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                  'stepCode',v_path_step,'baseCombination',v_base_key
                )) on conflict(qa_run_id,case_key) do nothing;

                -- Las dos ramas que pueden aparecer durante cualquier etapa activa.
                foreach v_decision in array array['APPROVED','REJECTED'] loop
                  insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                  values(p_run_id,format('X-%s-%s-PRIORITY-%s',v_base_key,v_path_step,v_decision),v_mode,'APPROVAL',jsonb_build_object(
                    'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                    'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                    'stepCode',v_path_step,'requestType','PRIORITY','decision',v_decision,'baseCombination',v_base_key
                  )) on conflict(qa_run_id,case_key) do nothing;
                  insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                  values(p_run_id,format('X-%s-%s-CANCELLATION-%s',v_base_key,v_path_step,v_decision),v_mode,'CANCELLATION',jsonb_build_object(
                    'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                    'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                    'stepCode',v_path_step,'requestType','CANCELLATION','decision',v_decision,'baseCombination',v_base_key
                  )) on conflict(qa_run_id,case_key) do nothing;
                end loop;
                v_path_step:=erp_supply.next_step(v_path_step,v_type,v_payment,v_route,v_cut,v_requires_purchase);v_guard:=v_guard+1;
              end loop;

              -- Excepciones/aprobaciones con resultado aprobado y rechazado.
              foreach v_req in array array['STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION'] loop
                foreach v_decision in array array['APPROVED','REJECTED'] loop
                  insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                  values(p_run_id,format('X-%s-%s-%s',v_base_key,v_req,v_decision),v_mode,'APPROVAL',jsonb_build_object(
                    'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                    'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                    'stepCode',v_initial,'requestType',v_req,'decision',v_decision,'baseCombination',v_base_key
                  )) on conflict(qa_run_id,case_key) do nothing;
                end loop;
              end loop;

              -- Cambio de ruta aprobado/rechazado en la etapa de despacho y reapertura.
              foreach v_decision in array array['APPROVED','REJECTED'] loop
                insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                values(p_run_id,format('X-%s-ROUTE-CHANGE-%s',v_base_key,v_decision),v_mode,'APPROVAL',jsonb_build_object(
                  'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,
                  'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),
                  'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),'stepCode',v_route,'requestType','ROUTE_CHANGE','decision',v_decision,
                  'targetRoute',case when v_route='NATIONAL_DISPATCH' then 'LOCAL_DISPATCH' else 'NATIONAL_DISPATCH' end,'baseCombination',v_base_key
                )) on conflict(qa_run_id,case_key) do nothing;
                insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                values(p_run_id,format('X-%s-REOPEN-%s',v_base_key,v_decision),v_mode,'REOPEN',jsonb_build_object(
                  'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                  'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                  'stepCode','CLOSURE','requestType','REOPEN','decision',v_decision,'baseCombination',v_base_key
                )) on conflict(qa_run_id,case_key) do nothing;
              end loop;

              -- No entrega / reprogramación / devolución son aplicables a despacho.
              if v_route in('LOCAL_DISPATCH','NATIONAL_DISPATCH') then
                foreach v_decision in array array['REPROGRAM','RETURN','RESOLVED'] loop
                  insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
                  values(p_run_id,format('X-%s-NO-DELIVERY-%s',v_base_key,v_decision),v_mode,'NO_DELIVERY',jsonb_build_object(
                    'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
                    'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false),
                    'stepCode',v_route,'resolutionCode',v_decision,'baseCombination',v_base_key
                  )) on conflict(qa_run_id,case_key) do nothing;
                end loop;
              end if;
            end loop;
          end loop;
        end loop;
      end loop;
    end loop;
  end if;

  select count(*) into v_count from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  update erp_supply.qa_runs set summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
    'deepCampaign',jsonb_build_object('mode',v_mode,'totalCases',v_count,'builtAt',now(),'version','10.25.1')
  ) where id=p_run_id;
  return jsonb_build_object('success',true,'runId',p_run_id,'mode',v_mode,'totalCases',v_count,'version','10.25.1');
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. Cancelación exacta en Sandbox QA: Super Admin puede emular a Jefatura
--    únicamente sobre pedidos TEST-QA. Producción sigue siendo exclusiva de
--    jefe_logistica.
-- ---------------------------------------------------------------------------
create or replace function erp_supply.trg_guard_cancellation_decision()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
begin
  if old.request_type='CANCELLATION' and old.status='PENDING' and new.status is distinct from old.status
     and new.status in('APPROVED','REJECTED','EXECUTED') and auth.uid() is not null and not erp_supply.has_role('jefe_logistica') then
    if not (
      erp_supply.has_role('super_admin') and exists(
        select 1 from erp_supply.orders o where o.id=new.order_id and o.is_test and o.source='QA_BOT'
          and coalesce((o.metadata->>'qaRobot')::boolean,false)
      )
    ) then
      raise exception 'Solo Jefatura Logística puede decidir la cancelación de un pedido' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;
revoke all on function erp_supply.trg_guard_cancellation_decision() from public;

create or replace function public.erp_x_request_order_cancellation(p_order_id uuid,p_note text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;
  v_req erp_supply.approval_requests%rowtype;v_note text:=trim(coalesce(p_note,''));v_roles text[]:=erp_supply.current_roles();
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order_or_reception_shadow(id) for update;
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;
  if v_order.is_test and not (erp_supply.has_role('super_admin') and v_order.source='QA_BOT' and coalesce((v_order.metadata->>'qaRobot')::boolean,false)) then
    raise exception 'Los pedidos Sandbox no usan la aprobación productiva de cancelación';
  end if;
  if v_order.status in('CLOSED','CANCELLED') then raise exception 'Solo se puede solicitar la cancelación de un pedido activo'; end if;
  if v_note='' then raise exception 'Debe registrar la nota de cancelación'; end if;
  if length(v_note)>1000 then raise exception 'La nota de cancelación no puede superar 1000 caracteres'; end if;
  if exists(select 1 from erp_supply.approval_requests where order_id=v_order.id and request_type='CANCELLATION' and status='PENDING') then raise exception 'Este pedido ya tiene una solicitud de cancelación pendiente'; end if;

  insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
  values(v_org,v_order.id,'CANCELLATION',v_actor,'jefe_logistica',v_note,jsonb_build_object(
    'requestType','CANCELLATION','assignedRole','jefe_logistica','note',v_note,'requestedStep',v_order.current_step_code,
    'requestedStatus',v_order.status,'requestedVersion',v_order.version,'source','ORDER_CANCELLATION_V10_25_1','qaSandbox',v_order.is_test,'requestedAt',now()
  )) returning * into v_req;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_org,v_order.id,'APPROVAL_REQUEST','REQUEST_CANCELLATION',v_order.current_step_code,v_order.current_step_code,v_order.status,v_order.status,
    v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType','CANCELLATION','note',v_note,'assignedRole','jefe_logistica','qaSandbox',v_order.is_test,'version','10.25.1'));
  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_org,v_actor,'REQUEST_CANCELLATION','ORDER',v_order.id::text,jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),
    jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),jsonb_build_object('requestId',v_req.id,'note',v_note,'assignedRole','jefe_logistica','qaSandbox',v_order.is_test,'version','10.25.1'));
  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_org,'ORDER_CANCELLATION_REQUESTED','ORDER',v_order.id,jsonb_build_object('requestId',v_req.id,'orderNumber',v_order.order_number,'requestedBy',v_actor,'assignedRole','jefe_logistica','qaSandbox',v_order.is_test));
  return jsonb_build_object('success',true,'requestId',v_req.id,'orderId',v_order.id,'orderNumber',v_order.order_number,'status','PENDING','assignedRole','jefe_logistica','qaSandbox',v_order.is_test,'version','10.25.1');
end;
$$;

create or replace function public.erp_x_decide_order_cancellation(p_request_id uuid,p_decision text default 'APPROVED',p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_req erp_supply.approval_requests%rowtype;v_order erp_supply.orders%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'APPROVED')));v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_before_status text;v_before_step text;v_roles text[]:=erp_supply.current_roles();v_qa_override boolean:=false;
begin
  if v_decision not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  select * into v_req from erp_supply.approval_requests where id=p_request_id and organization_id=v_org and request_type='CANCELLATION' for update;
  if not found then raise exception 'Solicitud de cancelación no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud de cancelación ya fue decidida'; end if;
  select * into v_order from erp_supply.orders where id=v_req.order_id and organization_id=v_org for update;
  if not found then raise exception 'Pedido asociado no encontrado'; end if;
  v_qa_override:=erp_supply.has_role('super_admin') and v_order.is_test and v_order.source='QA_BOT' and coalesce((v_order.metadata->>'qaRobot')::boolean,false);
  if not erp_supply.has_role('jefe_logistica') and not v_qa_override then
    raise exception 'Solo Jefatura Logística puede decidir la cancelación de un pedido' using errcode='42501';
  end if;
  v_before_status:=v_order.status;v_before_step:=v_order.current_step_code;

  if v_decision='REJECTED' then
    update erp_supply.approval_requests set status='REJECTED',decision_reason=coalesce(v_reason,'Cancelación no autorizada por Jefatura Logística'),
      decided_by=v_actor,decided_at=now() where id=v_req.id returning * into v_req;
  else
    if v_order.status='CANCELLED' then
      update erp_supply.approval_requests set status='EXECUTED',decision_reason='El pedido ya se encontraba cancelado',decided_by=v_actor,decided_at=now(),executed_at=now()
      where id=v_req.id returning * into v_req;
    else
      if v_order.status='CLOSED' then raise exception 'El pedido ya está cerrado y no puede cancelarse'; end if;
      update erp_supply.approval_requests set status='EXECUTED',decision_reason=coalesce(v_reason,'Cancelación aprobada por Jefatura Logística'),decided_by=v_actor,decided_at=now(),executed_at=now()
      where id=v_req.id returning * into v_req;
      update erp_supply.orders set status='CANCELLED',cancelled_at=coalesce(cancelled_at,now()),current_assignee_id=null,current_role_code=null,
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('cancellation',jsonb_build_object(
          'requestId',v_req.id,'requestedBy',v_req.requested_by,'requestNote',v_req.reason,'approvedBy',v_actor,'approvedAt',now(),'qaSandboxOverride',v_qa_override,'version','10.25.1')),
        version=coalesce(version,0)+1,updated_at=now() where id=v_order.id returning * into v_order;
    end if;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_org,v_order.id,'APPROVAL_DECISION',v_decision,v_before_step,v_order.current_step_code,v_before_status,v_order.status,v_actor,(v_roles)[1],
    jsonb_build_object('requestId',v_req.id,'requestType','CANCELLATION','requestNote',v_req.reason,'decisionReason',v_req.decision_reason,'requestStatus',v_req.status,'qaSandboxOverride',v_qa_override,'version','10.25.1'));
  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_org,v_actor,'CANCELLATION_'||v_decision,'ORDER',v_order.id::text,jsonb_build_object('status',v_before_status,'step',v_before_step),
    jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),jsonb_build_object('requestId',v_req.id,'requestNote',v_req.reason,'decisionReason',v_req.decision_reason,'qaSandboxOverride',v_qa_override,'version','10.25.1'));
  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_org,case when v_decision='APPROVED' then 'ORDER_CANCELLED' else 'ORDER_CANCELLATION_REJECTED' end,'ORDER',v_order.id,
    jsonb_build_object('requestId',v_req.id,'orderNumber',v_order.order_number,'decision',v_decision,'decidedBy',v_actor,'qaSandboxOverride',v_qa_override));
  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_decision,'requestStatus',v_req.status,'orderId',v_order.id,
    'orderNumber',v_order.order_number,'orderStatus',v_order.status,'currentStep',v_order.current_step_code,'qaSandboxOverride',v_qa_override,'version',v_order.version);
end;
$$;
revoke all on function public.erp_x_request_order_cancellation(uuid,text) from public,anon;
revoke all on function public.erp_x_decide_order_cancellation(uuid,text,text) from public,anon;
grant execute on function public.erp_x_request_order_cancellation(uuid,text) to authenticated;
grant execute on function public.erp_x_decide_order_cancellation(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Ejecución de UN caso. Cada llamada es una transacción independiente.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_execute_deep_case(p_case_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_case erp_supply.qa_deep_cases%rowtype;
  v_spec jsonb;v_seed jsonb;v_order uuid;v_order_number text;v_issue jsonb;v_issue_id uuid;v_req uuid;v_ok boolean:=false;
  v_family text;v_decision text;v_request_type text;v_issue_type text;v_before_priority text;v_target_route text;v_error text;v_sqlstate text;
  v_started timestamptz:=clock_timestamp();v_cleanup_ok boolean:=true;v_cleanup_error text;v_result jsonb:='{}'::jsonb;
begin
  select c.* into v_case from erp_supply.qa_deep_cases c join erp_supply.qa_runs r on r.id=c.qa_run_id
  where c.id=p_case_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT' for update of c;
  if not found then raise exception 'Caso QA profundo no disponible'; end if;
  if v_case.status in('PASSED','FAILED','SKIPPED') then return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status',v_case.status,'result',v_case.result,'errorMessage',v_case.error_message); end if;
  update erp_supply.qa_deep_cases set status='RUNNING',started_at=coalesce(started_at,now()),error_message=null,error_sqlstate=null where id=v_case.id;
  v_spec:=v_case.specification;v_family:=v_case.family;v_order:=null;v_order_number:=null;

  begin
    v_seed:=public.erp_x_qa_robot_seed_order(v_case.qa_run_id,v_spec||jsonb_build_object('scenarioKey',v_case.case_key));
    v_order:=erp_supply.safe_uuid(v_seed->>'orderId');v_order_number:=v_seed->>'orderNumber';

    if v_family='ISSUE' then
      v_issue_type:=upper(v_spec->>'issueType');
      v_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type',v_issue_type,'title','QA profundo '||v_issue_type,
        'detail','Prueba automática V10.25.1 · '||v_case.case_key,'targetRole',case when v_issue_type='REPORT' then 'jefe_logistica' else null end,'sourceCode','QA_DEEP'));
      v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}');
      if v_issue_type='NOTE' then
        select exists(select 1 from erp_supply.order_issues i where i.id=v_issue_id and i.status='CLOSED' and not i.blocking)
          and exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='ASSIGNED') into v_ok;
      else
        select exists(select 1 from erp_supply.order_issues i where i.id=v_issue_id and i.status='OPEN' and i.blocking)
          and exists(select 1 from erp_supply.orders o where o.id=v_order and o.status=case when v_issue_type='REPORT' then 'BLOCKED' else 'WAITING' end) into v_ok;
        if not v_ok then raise exception 'La % no bloqueó el pedido como se esperaba',v_issue_type; end if;
        perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Resuelto automáticamente por QA profundo','resolutionCode','RESOLVED'));
        select exists(select 1 from erp_supply.order_issues i where i.id=v_issue_id and i.status='RESOLVED')
          and exists(select 1 from erp_supply.orders o where o.id=v_order and o.status in('ASSIGNED','QUEUED')) into v_ok;
      end if;
      v_result:=jsonb_build_object('family',v_family,'issueType',v_issue_type,'issueId',v_issue_id,'lifecycleComplete',v_ok);

    elsif v_family='WAIT_RESUME' then
      perform public.erp_x_execute_action(v_order,'START',jsonb_build_object('detail','QA deep start'),null,'DEEP-START-'||v_case.id::text);
      perform public.erp_x_execute_action(v_order,'WAIT',jsonb_build_object('reason','QA deep wait'),null,'DEEP-WAIT-'||v_case.id::text);
      perform public.erp_x_execute_action(v_order,'RESUME',jsonb_build_object('detail','QA deep resume'),null,'DEEP-RESUME-'||v_case.id::text);
      select exists(select 1 from erp_supply.order_tasks t where t.order_id=v_order and t.status='IN_PROGRESS')
        and exists(select 1 from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=v_order and s.ended_at is null) into v_ok;
      v_result:=jsonb_build_object('family',v_family,'resumed',v_ok);

    elsif v_family='APPROVAL' then
      v_request_type:=upper(v_spec->>'requestType');v_decision:=upper(v_spec->>'decision');
      v_target_route:=upper(coalesce(nullif(v_spec->>'targetRoute',''),'NATIONAL_DISPATCH'));
      select priority into v_before_priority from erp_supply.orders where id=v_order;
      perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_strip_nulls(jsonb_build_object(
        'requestType',v_request_type,'priority',case when v_request_type='PRIORITY' then 'URGENT' else null end,
        'route',case when v_request_type='ROUTE_CHANGE' then v_target_route else null end,
        'reason','QA profundo '||v_request_type,'assignedRole',case when v_request_type in('PRIORITY','ROUTE_CHANGE') then 'gerencia' else 'auditoria' end
      )),null,'DEEP-APPROVAL-'||v_case.id::text);
      select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type=v_request_type and status='PENDING' order by created_at desc limit 1;
      if v_req is null then raise exception 'No se creó la solicitud %',v_request_type; end if;
      perform public.erp_x_decide_approval(v_req,v_decision,'Decisión automática QA profundo');
      select case
        when v_decision='REJECTED' then exists(select 1 from erp_supply.approval_requests a where a.id=v_req and a.status='REJECTED')
        when v_request_type='PRIORITY' then exists(select 1 from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id where a.id=v_req and a.status='EXECUTED' and o.priority='URGENT')
        when v_request_type='ROUTE_CHANGE' then exists(select 1 from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id where a.id=v_req and a.status='EXECUTED' and o.delivery_route_code=v_target_route)
        else exists(select 1 from erp_supply.approval_requests a where a.id=v_req and a.status='EXECUTED')
      end into v_ok;
      v_result:=jsonb_build_object('family',v_family,'requestType',v_request_type,'decision',v_decision,'requestId',v_req,'lifecycleComplete',v_ok,'beforePriority',v_before_priority,'targetRoute',case when v_request_type='ROUTE_CHANGE' then v_target_route else null end);

    elsif v_family='REOPEN' then
      v_decision:=upper(v_spec->>'decision');
      update erp_supply.order_tasks set status='COMPLETED',completed_at=now(),result_code='QA_CLOSED' where order_id=v_order and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
      update erp_supply.orders set status='CLOSED',current_step_code='CLOSED',closed_at=now(),current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order;
      perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','REOPEN','reason','QA profundo reapertura','assignedRole','auditoria'),null,'DEEP-REOPEN-'||v_case.id::text);
      select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='REOPEN' and status='PENDING' order by created_at desc limit 1;
      perform public.erp_x_decide_approval(v_req,v_decision,'Decisión automática QA profundo');
      select case when v_decision='APPROVED' then exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='QUEUED' and o.current_step_code='CLOSURE')
        else exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='CLOSED') end into v_ok;
      v_result:=jsonb_build_object('family',v_family,'decision',v_decision,'requestId',v_req,'lifecycleComplete',v_ok);

    elsif v_family='CANCELLATION' then
      v_decision:=upper(v_spec->>'decision');
      v_issue:=public.erp_x_request_order_cancellation(v_order,'Cancelación automática QA profundo · '||v_case.case_key);
      v_req:=erp_supply.safe_uuid(v_issue->>'requestId');
      perform public.erp_x_decide_order_cancellation(v_req,v_decision,'Decisión automática QA profundo');
      select case when v_decision='APPROVED' then
        exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='CANCELLED')
        and not exists(select 1 from erp_supply.order_tasks t where t.order_id=v_order and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED'))
        and not exists(select 1 from erp_supply.order_issues i where i.order_id=v_order and i.status='OPEN')
      else exists(select 1 from erp_supply.orders o where o.id=v_order and o.status<>'CANCELLED')
        and exists(select 1 from erp_supply.approval_requests a where a.id=v_req and a.status='REJECTED') end into v_ok;
      v_result:=jsonb_build_object('family',v_family,'decision',v_decision,'requestId',v_req,'lifecycleComplete',v_ok);

    elsif v_family='NO_DELIVERY' then
      v_decision:=upper(coalesce(v_spec->>'resolutionCode','RESOLVED'));
      insert into erp_supply.deliveries(order_id,route_code,status,scheduled_at,dispatched_at,assigned_profile_id,metadata)
      values(v_order,case when upper(coalesce(v_spec->>'deliveryRoute','LOCAL_DISPATCH'))='NATIONAL_DISPATCH' then 'NATIONAL_DISPATCH' else 'LOCAL_DISPATCH' end,
        'IN_TRANSIT',now()-interval '30 minutes',now()-interval '20 minutes',v_actor,jsonb_build_object('qaRobot',true,'qaDeepCase',v_case.id))
      on conflict do nothing;
      v_issue:=public.erp_x_shipping_report_no_delivery(v_order,jsonb_build_object('reason','No entrega sintética QA profundo','requestedAction',v_decision));
      v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,issue,id}');
      if v_issue_id is null then v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}'); end if;
      if v_issue_id is null then
        select id into v_issue_id from erp_supply.order_issues where order_id=v_order and source_code='NO_DELIVERY' and status='OPEN' order by created_at desc limit 1;
      end if;
      if v_issue_id is null then raise exception 'No se creó el reporte de no entrega'; end if;
      perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Resolución automática QA profundo','resolutionCode',v_decision));
      select case v_decision
        when 'RETURN' then exists(select 1 from erp_supply.deliveries d where d.order_id=v_order and d.status='CANCELLED')
        when 'REPROGRAM' then exists(select 1 from erp_supply.deliveries d where d.order_id=v_order and d.status='REPROGRAMMED')
        else exists(select 1 from erp_supply.deliveries d where d.order_id=v_order and d.status='IN_TRANSIT')
      end and not exists(select 1 from erp_supply.order_issues i where i.order_id=v_order and i.blocking and i.status='OPEN') into v_ok;
      v_result:=jsonb_build_object('family',v_family,'resolutionCode',v_decision,'issueId',v_issue_id,'lifecycleComplete',v_ok);
    else
      raise exception 'Familia QA profunda no soportada: %',v_family;
    end if;

    if not coalesce(v_ok,false) then raise exception 'El caso terminó sin cumplir su invariante esperada'; end if;
  exception when others then
    v_error:=sqlerrm;v_sqlstate:=sqlstate;v_ok:=false;
  end;

  -- Limpieza fuera del bloque que capturó el error. Si el pedido fue revertido,
  -- v_order puede conservar UUID pero qa_existing_order_id devuelve NULL.
  if erp_supply.qa_existing_order_id(v_order) is not null then
    begin
      perform public.erp_x_sandbox_delete(v_order);
    exception when others then
      v_cleanup_ok:=false;v_cleanup_error:=sqlstate||' · '||sqlerrm;
    end;
  end if;
  if not v_cleanup_ok then v_ok:=false;v_error:=concat_ws(' · ',v_error,'CLEANUP: '||v_cleanup_error);v_sqlstate:=coalesce(v_sqlstate,'P0001'); end if;

  update erp_supply.qa_deep_cases set
    order_id=erp_supply.qa_existing_order_id(v_order),status=case when v_ok then 'PASSED' else 'FAILED' end,
    result=coalesce(v_result,'{}'::jsonb)||jsonb_build_object('orderNumber',v_order_number,'originalOrderId',v_order,'cleaned',v_cleanup_ok),
    error_sqlstate=v_sqlstate,error_message=v_error,duration_ms=round(extract(epoch from(clock_timestamp()-v_started))*1000)::integer,completed_at=now()
  where id=v_case.id returning * into v_case;

  return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,'status',v_case.status,'result',v_case.result,
    'errorSqlstate',v_case.error_sqlstate,'errorMessage',v_case.error_message,'durationMs',v_case.duration_ms);
end;
$$;

create or replace function public.erp_x_qa_robot_deep_progress(p_run_id uuid,p_limit integer default 12)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_limit int:=least(greatest(coalesce(p_limit,12),1),50);
  v_total int;v_pending int;v_running int;v_passed int;v_failed int;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  select count(*),count(*) filter(where status='PENDING'),count(*) filter(where status='RUNNING'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED')
  into v_total,v_pending,v_running,v_passed,v_failed from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  return jsonb_build_object(
    'runId',p_run_id,'total',v_total,'pending',v_pending,'running',v_running,'passed',v_passed,'failed',v_failed,'done',v_pending=0 and v_running=0,
    'pendingIds',(select coalesce(jsonb_agg(id order by case_key),'[]'::jsonb) from (select id,case_key from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='PENDING' order by case_key limit v_limit) x),
    'failures',(select coalesce(jsonb_agg(jsonb_build_object('caseKey',case_key,'family',family,'sqlstate',error_sqlstate,'error',error_message,'result',result) order by completed_at desc),'[]'::jsonb)
      from (select * from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='FAILED' order by completed_at desc limit 30) f),
    'version','10.25.1'
  );
end;
$$;


-- El detalle del Robot no descarga decenas de miles de casos exitosos. Expone
-- el resumen completo y hasta 250 fallos reproducibles con especificación,
-- SQLSTATE, resultado y duración.
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
    ) order by c.started_at,c.check_key),'[]'::jsonb) from erp_supply.qa_robot_checks c where c.qa_run_id=p_run_id),
    'deepSummary',jsonb_build_object(
      'total',(select count(*) from erp_supply.qa_deep_cases d where d.qa_run_id=p_run_id),
      'passed',(select count(*) from erp_supply.qa_deep_cases d where d.qa_run_id=p_run_id and d.status='PASSED'),
      'failed',(select count(*) from erp_supply.qa_deep_cases d where d.qa_run_id=p_run_id and d.status='FAILED'),
      'pending',(select count(*) from erp_supply.qa_deep_cases d where d.qa_run_id=p_run_id and d.status in('PENDING','RUNNING')),
      'byFamily',(select coalesce(jsonb_object_agg(x.family,jsonb_build_object('total',x.total,'passed',x.passed,'failed',x.failed)),'{}'::jsonb) from(
        select family,count(*)::int total,count(*) filter(where status='PASSED')::int passed,count(*) filter(where status='FAILED')::int failed
        from erp_supply.qa_deep_cases where qa_run_id=p_run_id group by family order by family
      )x)
    ),
    'deepFailures',(select coalesce(jsonb_agg(to_jsonb(x) order by x."completedAt" desc),'[]'::jsonb) from(
      select id,case_key "caseKey",campaign_mode "campaignMode",family,specification,status,result,error_sqlstate "errorSqlstate",
        error_message "errorMessage",duration_ms "durationMs",started_at "startedAt",completed_at "completedAt"
      from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='FAILED' order by completed_at desc,case_key limit 250
    )x),
    'version','10.25.1'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Registro de capacidad/concurrencia. El generador de carga es externo
--    (k6) para medir concurrencia real; el ERP solo recibe el resumen firmado
--    por la cuenta Super Admin QA.
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.qa_capacity_runs(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id) on delete cascade,
  qa_run_id uuid references erp_supply.qa_runs(id) on delete set null,
  requested_by uuid not null references erp_supply.profiles(id),
  source text not null default 'K6',
  profile text not null,
  status text not null check(status in('PASSED','FAILED','INFO')),
  max_virtual_users integer,
  total_requests bigint,
  request_rate numeric,
  error_rate numeric,
  p50_ms numeric,p90_ms numeric,p95_ms numeric,p99_ms numeric,max_ms numeric,
  checks_rate numeric,
  thresholds jsonb not null default '{}'::jsonb,
  stages jsonb not null default '[]'::jsonb,
  summary jsonb not null default '{}'::jsonb,
  started_at timestamptz,
  completed_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index if not exists idx_qa_capacity_runs_org_time on erp_supply.qa_capacity_runs(organization_id,created_at desc);
revoke all on erp_supply.qa_capacity_runs from public,anon,authenticated;

create or replace function public.erp_x_qa_capacity_record(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_row erp_supply.qa_capacity_runs%rowtype;
  v_status text:=upper(coalesce(nullif(trim(p_payload->>'status'),''),'INFO'));v_profile text:=upper(coalesce(nullif(trim(p_payload->>'profile'),''),'CUSTOM'));
  v_requested_run uuid:=erp_supply.safe_uuid(p_payload->>'qaRunId');v_safe_run uuid;
begin
  if v_status not in('PASSED','FAILED','INFO') then v_status:='INFO'; end if;
  select r.id into v_safe_run from erp_supply.qa_runs r where r.id=v_requested_run and r.organization_id=v_org;
  insert into erp_supply.qa_capacity_runs(
    organization_id,qa_run_id,requested_by,source,profile,status,max_virtual_users,total_requests,request_rate,error_rate,
    p50_ms,p90_ms,p95_ms,p99_ms,max_ms,checks_rate,thresholds,stages,summary,started_at,completed_at
  ) values(
    v_org,v_safe_run,v_actor,upper(coalesce(nullif(trim(p_payload->>'source'),''),'K6')),v_profile,v_status,
    erp_supply.safe_integer(p_payload->>'maxVirtualUsers'),coalesce((p_payload->>'totalRequests')::bigint,0),
    erp_supply.safe_numeric(p_payload->>'requestRate'),erp_supply.safe_numeric(p_payload->>'errorRate'),erp_supply.safe_numeric(p_payload->>'p50Ms'),
    erp_supply.safe_numeric(p_payload->>'p90Ms'),erp_supply.safe_numeric(p_payload->>'p95Ms'),erp_supply.safe_numeric(p_payload->>'p99Ms'),
    erp_supply.safe_numeric(p_payload->>'maxMs'),erp_supply.safe_numeric(p_payload->>'checksRate'),coalesce(p_payload->'thresholds','{}'::jsonb),
    coalesce(p_payload->'stages','[]'::jsonb),coalesce(p_payload->'summary','{}'::jsonb),
    nullif(p_payload->>'startedAt','')::timestamptz,coalesce(nullif(p_payload->>'completedAt','')::timestamptz,now())
  ) returning * into v_row;
  return jsonb_build_object('success',true,'id',v_row.id,'profile',v_row.profile,'status',v_row.status,'p95Ms',v_row.p95_ms,'errorRate',v_row.error_rate,'maxVirtualUsers',v_row.max_virtual_users);
end;
$$;

create or replace function public.erp_x_qa_capacity_runs(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_limit int:=least(greatest(coalesce(p_limit,20),1),100);
begin
  return jsonb_build_object('items',(select coalesce(jsonb_agg(to_jsonb(x) order by x."createdAt" desc),'[]'::jsonb) from(
    select id,qa_run_id "qaRunId",source,profile,status,max_virtual_users "maxVirtualUsers",total_requests "totalRequests",request_rate "requestRate",
      error_rate "errorRate",p50_ms "p50Ms",p90_ms "p90Ms",p95_ms "p95Ms",p99_ms "p99Ms",max_ms "maxMs",checks_rate "checksRate",
      thresholds,stages,summary,started_at "startedAt",completed_at "completedAt",created_at "createdAt"
    from erp_supply.qa_capacity_runs where organization_id=v_org order by created_at desc limit v_limit
  )x),'version','10.25.1');
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. Plan Robot actualizado.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_steps int;begin
  select count(*) into v_steps from erp_supply.workflow_steps where active and not terminal;
  return jsonb_build_object(
    'version','10.25.1','strategy','EXHAUSTIVE_INPUTS_PLUS_ISOLATED_DEEP_CASES_PLUS_E2E_PLUS_LOAD','productionIsolation',true,
    'domain',jsonb_build_object('routingCombinations',336,'enterpriseControls',10,'integrityGates',2,'branchChecks',10,
      'deepTotalFormula','4 order types × active steps × (NOTE + NOVELTY + REPORT + WAIT/RESUME) + approvals approve/reject',
      'activeSteps',v_steps,'deepTotalCases',4*v_steps*4 + 4*8*2,
      'extremeMode','336 entradas × cada etapa real × NOTE/NOVELTY/REPORT/WAIT + PRIORITY/CANCELLATION approve/reject + excepciones/cambio de ruta/reapertura/no-entrega'),
    'ui',jsonb_build_object('modules','ALL_SUPER_ADMIN_MODULES','safeControlCrawler',true,'sandboxMutationDriver',true,'consoleAndPromiseErrors',true,'moduleErrors',true,'horizontalOverflow',true),
    'responsive',jsonb_build_object('widths',jsonb_build_array(360,390,424,768,960,1440),'criticalModules',jsonb_build_array('dashboard','orders','inventory','workforce','approvals','sandbox','cutting','receiving','shipping')),
    'capacity',jsonb_build_object('engine','k6','profiles',jsonb_build_array('SMOKE','NORMAL','BUSY','PEAK','BREAKPOINT'),'metrics',jsonb_build_array('RPS','errorRate','p50','p90','p95','p99','max','checksRate'),'mixedReadWriteSandbox',true),
    'externalE2E',jsonb_build_object('engine','Playwright','browsers',jsonb_build_array('Chromium Desktop','Pixel 7'),'traces',true,'screenshotsOnFailure',true,'videoOnFailure',true),
    'requestedBy',v_actor
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Grants.
-- ---------------------------------------------------------------------------
revoke all on function public.erp_x_qa_robot_build_deep_campaign(uuid,text) from public,anon;
revoke all on function public.erp_x_qa_robot_execute_deep_case(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_deep_progress(uuid,integer) from public,anon;
revoke all on function public.erp_x_qa_robot_detail(uuid) from public,anon;
revoke all on function public.erp_x_qa_capacity_record(jsonb) from public,anon;
revoke all on function public.erp_x_qa_capacity_runs(integer) from public,anon;
revoke all on function public.erp_x_qa_robot_plan() from public,anon;
grant execute on function public.erp_x_qa_robot_build_deep_campaign(uuid,text) to authenticated;
grant execute on function public.erp_x_qa_robot_execute_deep_case(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_deep_progress(uuid,integer) to authenticated;
grant execute on function public.erp_x_qa_robot_detail(uuid) to authenticated;
grant execute on function public.erp_x_qa_capacity_record(jsonb) to authenticated;
grant execute on function public.erp_x_qa_capacity_runs(integer) to authenticated;
grant execute on function public.erp_x_qa_robot_plan() to authenticated;

notify pgrst,'reload schema';
commit;
