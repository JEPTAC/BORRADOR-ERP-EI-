-- ERP EI V10.25.2 · Certificación integral de liberación
-- Objetivo: que "prueba total" signifique cobertura verificable y reanudable.
-- 336 rutas se ejecutan como casos independientes; la campaña nunca se corta
-- por un timeout/transporte aislado y la liberación solo se certifica cuando
-- ejecutados=planificados, pendientes=0, transporte=0, UI/integridad/responsive
-- están en verde y la limpieza Sandbox es 100%.

begin;

alter table erp_supply.qa_deep_cases
  add column if not exists attempt_count integer not null default 0,
  add column if not exists transport_failures integer not null default 0,
  add column if not exists timeout_failures integer not null default 0,
  add column if not exists last_transport_error text,
  add column if not exists last_attempt_at timestamptz,
  add column if not exists cleanup_verified boolean not null default false;

create index if not exists idx_qa_deep_cases_release_family
  on erp_supply.qa_deep_cases(qa_run_id,family,status);

-- Construye una campaña de liberación: EXTREME existente + 336 rutas canónicas
-- aisladas + 336 recorridos secuenciales realistas que mezclan nota, novedad,
-- reporte, espera/reanudación y aprobación antes de avanzar por toda la ruta.
create or replace function public.erp_x_qa_robot_build_release_campaign(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_financial jsonb;v_type text;v_payment text;v_route text;v_cut boolean;v_purchase boolean;v_requires_purchase boolean;
  v_states jsonb:=jsonb_build_array(
    jsonb_build_object('code','PVC-NORMAL','orderType','PVC','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVC-MORA','orderType','PVC','hasCreditArrears',true,'heldByCashier',false),
    jsonb_build_object('code','PVN-NORMAL','orderType','PVN','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVN-CAJA','orderType','PVN','hasCreditArrears',false,'heldByCashier',true),
    jsonb_build_object('code','PVE','orderType','PVE','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-NORMAL','orderType','PVP','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-MORA','orderType','PVP','hasCreditArrears',true,'heldByCashier',false)
  );
  v_key text;v_total integer;v_routes integer;v_journeys integer;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA total no disponible';
  end if;

  perform public.erp_x_qa_robot_build_deep_campaign(p_run_id,'EXTREME');

  for v_financial in select value from jsonb_array_elements(v_states) loop
    v_type:=v_financial->>'orderType';
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_requires_purchase:=v_purchase or v_type='PVE';
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_financial->>'code',v_payment,v_route,v_cut,v_purchase);
            insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
            values(p_run_id,'ROUTE-'||v_key,'EXTREME','ROUTE_CANONICAL',jsonb_build_object(
              'baseCombination',v_key,'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,
              'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
              'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),
              'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false)
            )) on conflict(qa_run_id,case_key) do nothing;

            insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
            values(p_run_id,'JOURNEY-'||v_key,'EXTREME','JOURNEY_FULL',jsonb_build_object(
              'baseCombination',v_key,'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,
              'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
              'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),
              'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false)
            )) on conflict(qa_run_id,case_key) do nothing;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;

  select count(*) into v_total from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  select count(*) into v_routes from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL';
  select count(*) into v_journeys from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL';
  update erp_supply.qa_runs set summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
    'releaseCampaign',jsonb_build_object('version','10.25.2','planned',v_total,'canonicalRoutes',v_routes,'fullJourneys',v_journeys,'builtAt',now())
  ) where id=p_run_id;
  return jsonb_build_object('success',true,'runId',p_run_id,'totalCases',v_total,'canonicalRoutes',v_routes,'fullJourneys',v_journeys,'version','10.25.2');
end;
$$;

-- Constructor dirigido de las 336 rutas. Evita volver a usar la función
-- monolítica histórica que podía exceder statement_timeout.
create or replace function public.erp_x_qa_robot_build_route_campaign(p_run_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_financial jsonb;v_type text;v_payment text;v_route text;v_cut boolean;v_purchase boolean;v_requires_purchase boolean;
  v_states jsonb:=jsonb_build_array(
    jsonb_build_object('code','PVC-NORMAL','orderType','PVC','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVC-MORA','orderType','PVC','hasCreditArrears',true,'heldByCashier',false),
    jsonb_build_object('code','PVN-NORMAL','orderType','PVN','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVN-CAJA','orderType','PVN','hasCreditArrears',false,'heldByCashier',true),
    jsonb_build_object('code','PVE','orderType','PVE','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-NORMAL','orderType','PVP','hasCreditArrears',false,'heldByCashier',false),
    jsonb_build_object('code','PVP-MORA','orderType','PVP','hasCreditArrears',true,'heldByCashier',false)
  );
  v_key text;v_total integer;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then
    raise exception 'Ejecución QA total no disponible';
  end if;
  delete from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  for v_financial in select value from jsonb_array_elements(v_states) loop
    v_type:=v_financial->>'orderType';
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_requires_purchase:=v_purchase or v_type='PVE';
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_financial->>'code',v_payment,v_route,v_cut,v_purchase);
            insert into erp_supply.qa_deep_cases(qa_run_id,case_key,campaign_mode,family,specification)
            values(p_run_id,'ROUTE-'||v_key,'EXTREME','ROUTE_CANONICAL',jsonb_build_object(
              'baseCombination',v_key,'orderType',v_type,'paymentCondition',v_payment,'deliveryRoute',v_route,
              'requiresCut',v_cut,'requiresPurchase',v_requires_purchase,
              'hasCreditArrears',coalesce((v_financial->>'hasCreditArrears')::boolean,false),
              'heldByCashier',coalesce((v_financial->>'heldByCashier')::boolean,false)
            )) on conflict(qa_run_id,case_key) do nothing;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  select count(*) into v_total from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL';
  if v_total<>336 then raise exception 'El inventario de rutas no contiene exactamente 336 casos: %',v_total; end if;
  return jsonb_build_object('success',true,'runId',p_run_id,'canonicalRoutes',v_total,'version','10.25.2');
end;
$$;

-- Si una llamada de navegador falla por transporte, se registra y se deja
-- reanudable. Solo el último intento puede convertirlo en fallo terminal.
create or replace function public.erp_x_qa_robot_transport_failure(p_case_id uuid,p_error text,p_terminal boolean default false)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_case erp_supply.qa_deep_cases%rowtype;
begin
  update erp_supply.qa_deep_cases c set
    transport_failures=coalesce(c.transport_failures,0)+1,
    timeout_failures=coalesce(c.timeout_failures,0)+case when lower(coalesce(p_error,'')) like '%statement timeout%' or lower(coalesce(p_error,'')) like '%timeout%' then 1 else 0 end,
    last_transport_error=nullif(trim(coalesce(p_error,'')),''),last_attempt_at=now(),
    status=case when p_terminal then 'FAILED' else 'PENDING' end,
    error_sqlstate=case when p_terminal then 'TRANSPORT' else null end,
    error_message=case when p_terminal then 'TRANSPORT · '||coalesce(nullif(trim(p_error),''),'Fallo de transporte sin detalle') else null end,
    completed_at=case when p_terminal then now() else null end
  from erp_supply.qa_runs r
  where c.id=p_case_id and r.id=c.qa_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT'
  returning c.* into v_case;
  if not found then raise exception 'Caso QA no disponible'; end if;
  return jsonb_build_object('caseId',v_case.id,'status',v_case.status,'transportFailures',v_case.transport_failures,'timeoutFailures',v_case.timeout_failures,'terminal',p_terminal);
end;
$$;

create or replace function public.erp_x_qa_robot_reset_stale_cases(p_run_id uuid,p_older_seconds integer default 120)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_reset integer:=0;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  update erp_supply.qa_deep_cases set status='PENDING',error_message=null,error_sqlstate=null,completed_at=null
  where qa_run_id=p_run_id and status='RUNNING' and coalesce(last_attempt_at,started_at,now()) < now()-make_interval(secs=>greatest(coalesce(p_older_seconds,120),30));
  get diagnostics v_reset=row_count;
  return jsonb_build_object('success',true,'reset',v_reset,'runId',p_run_id);
end;
$$;

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
  v_route_step text;v_expected_path jsonb:='[]'::jsonb;v_actual_path jsonb:='[]'::jsonb;v_guard integer:=0;
  v_sequence jsonb:='[]'::jsonb;v_local_issue jsonb;v_local_issue_id uuid;v_first_step boolean:=true;
begin
  select c.* into v_case from erp_supply.qa_deep_cases c join erp_supply.qa_runs r on r.id=c.qa_run_id
  where c.id=p_case_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT' for update of c;
  if not found then raise exception 'Caso QA profundo no disponible'; end if;
  if v_case.status in('PASSED','FAILED','SKIPPED') then return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'status',v_case.status,'result',v_case.result,'errorMessage',v_case.error_message); end if;
  update erp_supply.qa_deep_cases set status='RUNNING',started_at=coalesce(started_at,now()),error_message=null,error_sqlstate=null,
    attempt_count=coalesce(attempt_count,0)+1,last_attempt_at=now() where id=v_case.id;
  v_spec:=v_case.specification;v_family:=v_case.family;v_order:=null;v_order_number:=null;

  begin
    v_seed:=public.erp_x_qa_robot_seed_order(v_case.qa_run_id,v_spec||jsonb_build_object('scenarioKey',v_case.case_key));
    v_order:=erp_supply.safe_uuid(v_seed->>'orderId');v_order_number:=v_seed->>'orderNumber';

    if v_family='ROUTE_CANONICAL' then
      select current_step_code into v_route_step from erp_supply.orders where id=v_order;
      v_expected_path:=jsonb_build_array(v_route_step);v_actual_path:=jsonb_build_array(v_route_step);v_guard:=0;
      while v_route_step<>'CLOSED' and v_guard<20 loop
        v_route_step:=erp_supply.next_step(
          v_route_step,
          upper(v_spec->>'orderType'),upper(v_spec->>'paymentCondition'),upper(v_spec->>'deliveryRoute'),
          coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false),coalesce(erp_supply.safe_boolean(v_spec->>'requiresPurchase'),false)
        );
        v_expected_path:=v_expected_path||jsonb_build_array(v_route_step);v_guard:=v_guard+1;
      end loop;
      v_guard:=0;
      loop
        select current_step_code into v_route_step from erp_supply.orders where id=v_order;
        exit when v_route_step='CLOSED' or v_guard>=20;
        perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA release route START'),v_actor,true,null,'REL-ROUTE-START-'||v_case.id::text||'-'||v_guard::text);
        perform erp_supply.execute_action_internal(v_order,'COMPLETE',jsonb_build_object('detail','QA release route COMPLETE'),v_actor,true,null,'REL-ROUTE-COMPLETE-'||v_case.id::text||'-'||v_guard::text);
        select current_step_code into v_route_step from erp_supply.orders where id=v_order;
        v_actual_path:=v_actual_path||jsonb_build_array(v_route_step);v_guard:=v_guard+1;
      end loop;
      select exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='CLOSED' and o.current_step_code='CLOSED')
        and v_actual_path=v_expected_path into v_ok;
      v_result:=jsonb_build_object('family',v_family,'expectedPath',v_expected_path,'actualPath',v_actual_path,'closed',v_ok,'stepsExecuted',v_guard);

    elsif v_family='JOURNEY_FULL' then
      select current_step_code into v_route_step from erp_supply.orders where id=v_order;
      v_expected_path:=jsonb_build_array(v_route_step);v_actual_path:=jsonb_build_array(v_route_step);v_guard:=0;v_sequence:='[]'::jsonb;v_first_step:=true;
      while v_route_step<>'CLOSED' and v_guard<20 loop
        v_route_step:=erp_supply.next_step(
          v_route_step,
          upper(v_spec->>'orderType'),upper(v_spec->>'paymentCondition'),upper(v_spec->>'deliveryRoute'),
          coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false),coalesce(erp_supply.safe_boolean(v_spec->>'requiresPurchase'),false)
        );
        v_expected_path:=v_expected_path||jsonb_build_array(v_route_step);v_guard:=v_guard+1;
      end loop;
      v_guard:=0;
      loop
        select current_step_code into v_route_step from erp_supply.orders where id=v_order;
        exit when v_route_step='CLOSED' or v_guard>=20;
        perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA journey START'),v_actor,true,null,'REL-JOURNEY-START-'||v_case.id::text||'-'||v_guard::text);
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','START'));

        v_local_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','NOTE','title','Nota QA release','detail','Secuencia E2E funcional','sourceCode','QA_RELEASE'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','NOTE'));

        v_local_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','NOVELTY','title','Novedad QA release','detail','Novedad creada y resuelta en secuencia','sourceCode','QA_RELEASE'));
        v_local_issue_id:=erp_supply.safe_uuid(v_local_issue#>>'{issue,id}');
        if v_local_issue_id is null then raise exception 'La secuencia no pudo crear NOVELTY en %',v_route_step; end if;
        perform public.erp_x_resolve_order_issue(v_local_issue_id,jsonb_build_object('resolution','Resuelta por QA release','resolutionCode','RESOLVED'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','NOVELTY_RESOLVED'));

        v_local_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','REPORT','title','Reporte QA release','detail','Reporte creado y resuelto en secuencia','targetRole','jefe_logistica','sourceCode','QA_RELEASE'));
        v_local_issue_id:=erp_supply.safe_uuid(v_local_issue#>>'{issue,id}');
        if v_local_issue_id is null then raise exception 'La secuencia no pudo crear REPORT en %',v_route_step; end if;
        perform public.erp_x_resolve_order_issue(v_local_issue_id,jsonb_build_object('resolution','Reporte resuelto por QA release','resolutionCode','RESOLVED'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','REPORT_RESOLVED'));

        -- Volver a estado operativo y comprobar WAIT/RESUME dentro del mismo recorrido.
        begin
          perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA journey reactivar'),v_actor,true,null,'REL-JOURNEY-RESTART-'||v_case.id::text||'-'||v_guard::text);
        exception when others then null;
        end;
        perform erp_supply.execute_action_internal(v_order,'WAIT',jsonb_build_object('reason','QA journey espera'),v_actor,true,null,'REL-JOURNEY-WAIT-'||v_case.id::text||'-'||v_guard::text);
        perform erp_supply.execute_action_internal(v_order,'RESUME',jsonb_build_object('detail','QA journey reanudar'),v_actor,true,null,'REL-JOURNEY-RESUME-'||v_case.id::text||'-'||v_guard::text);
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','WAIT_RESUME'));

        if v_first_step then
          begin
            perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','PRIORITY','priority','URGENT','reason','QA journey prioridad','assignedRole','gerencia'),null,'REL-JOURNEY-PRIORITY-'||v_case.id::text);
            select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='PRIORITY' and status='PENDING' order by created_at desc limit 1;
            if v_req is not null then
              perform public.erp_x_decide_approval(v_req,'APPROVED','QA release aprueba prioridad');
              v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','PRIORITY_APPROVED'));
            end if;
          exception when others then
            raise exception 'Secuencia PRIORITY en %: %',v_route_step,sqlerrm;
          end;
          v_first_step:=false;
        end if;

        begin
          perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA journey preparar cierre de etapa'),v_actor,true,null,'REL-JOURNEY-START2-'||v_case.id::text||'-'||v_guard::text);
        exception when others then null;
        end;
        perform erp_supply.execute_action_internal(v_order,'COMPLETE',jsonb_build_object('detail','QA journey completar etapa'),v_actor,true,null,'REL-JOURNEY-COMPLETE-'||v_case.id::text||'-'||v_guard::text);
        select current_step_code into v_route_step from erp_supply.orders where id=v_order;
        v_actual_path:=v_actual_path||jsonb_build_array(v_route_step);
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_route_step,'action','ADVANCED'));
        v_guard:=v_guard+1;
      end loop;
      select exists(select 1 from erp_supply.orders o where o.id=v_order and o.status='CLOSED' and o.current_step_code='CLOSED')
        and v_actual_path=v_expected_path into v_ok;
      v_result:=jsonb_build_object('family',v_family,'expectedPath',v_expected_path,'actualPath',v_actual_path,'closed',v_ok,
        'stepsExecuted',v_guard,'actionCount',jsonb_array_length(v_sequence),'sequence',v_sequence);

    elsif v_family='ISSUE' then
      v_issue_type:=upper(v_spec->>'issueType');
      v_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type',v_issue_type,'title','QA profundo '||v_issue_type,
        'detail','Prueba automática V10.25.2 · '||v_case.case_key,'targetRole',case when v_issue_type='REPORT' then 'jefe_logistica' else null end,'sourceCode','QA_DEEP'));
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
    error_sqlstate=v_sqlstate,error_message=v_error,duration_ms=round(extract(epoch from(clock_timestamp()-v_started))*1000)::integer,
    cleanup_verified=v_cleanup_ok,completed_at=now()
  where id=v_case.id returning * into v_case;

  return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,'status',v_case.status,'result',v_case.result,
    'errorSqlstate',v_case.error_sqlstate,'errorMessage',v_case.error_message,'durationMs',v_case.duration_ms);
end;
$$;


-- Progreso completo y auditable. No oculta pendientes ni fallos de transporte.
create or replace function public.erp_x_qa_robot_deep_progress(p_run_id uuid,p_limit integer default 24)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_limit int:=least(greatest(coalesce(p_limit,24),1),100);
  v_total int;v_pending int;v_running int;v_passed int;v_failed int;v_transport int;v_timeout int;v_executed int;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  select count(*),count(*) filter(where status='PENDING'),count(*) filter(where status='RUNNING'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),
    coalesce(sum(transport_failures),0)::int,coalesce(sum(timeout_failures),0)::int
  into v_total,v_pending,v_running,v_passed,v_failed,v_transport,v_timeout from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  v_executed:=v_passed+v_failed;
  return jsonb_build_object(
    'runId',p_run_id,'total',v_total,'planned',v_total,'executed',v_executed,'pending',v_pending,'running',v_running,'passed',v_passed,'failed',v_failed,
    'transportFailures',v_transport,'timeoutFailures',v_timeout,'done',v_pending=0 and v_running=0,
    'coveragePercent',case when v_total=0 then 0 else round((v_executed::numeric/v_total::numeric)*100,2) end,
    'routes',jsonb_build_object(
      'planned',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL'),
      'executed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL' and status in('PASSED','FAILED')),
      'passed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL' and status='PASSED'),
      'failed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL' and status='FAILED')
    ),
    'journeys',jsonb_build_object(
      'planned',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL'),
      'executed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL' and status in('PASSED','FAILED')),
      'passed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL' and status='PASSED'),
      'failed',(select count(*) from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL' and status='FAILED')
    ),
    'byFamily',(select coalesce(jsonb_object_agg(x.family,jsonb_build_object('planned',x.total,'executed',x.executed,'passed',x.passed,'failed',x.failed,'pending',x.pending,'transport',x.transport,'timeout',x.timeout)),'{}'::jsonb) from(
      select family,count(*)::int total,count(*) filter(where status in('PASSED','FAILED'))::int executed,count(*) filter(where status='PASSED')::int passed,
        count(*) filter(where status='FAILED')::int failed,count(*) filter(where status in('PENDING','RUNNING'))::int pending,coalesce(sum(transport_failures),0)::int transport,coalesce(sum(timeout_failures),0)::int timeout
      from erp_supply.qa_deep_cases where qa_run_id=p_run_id group by family order by family
    )x),
    'pendingIds',(select coalesce(jsonb_agg(id order by case_key),'[]'::jsonb) from (select id,case_key from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='PENDING' order by case_key limit v_limit) x),
    'failures',(select coalesce(jsonb_agg(jsonb_build_object('caseId',id,'caseKey',case_key,'family',family,'sqlstate',error_sqlstate,'error',error_message,'transportFailures',transport_failures,'timeoutFailures',timeout_failures,'result',result) order by completed_at desc),'[]'::jsonb)
      from (select * from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='FAILED' order by completed_at desc limit 50) f),
    'version','10.25.2'
  );
end;
$$;

-- Gate canónico de liberación. PASSED del run ya no es suficiente: este RPC
-- enumera exactamente qué falta para poder llamar CERTIFICADO al ERP.
create or replace function public.erp_x_qa_robot_release_certificate(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_routes_total int;v_routes_pass int;v_routes_fail int;v_routes_pending int;
  v_journeys_total int;v_journeys_pass int;v_journeys_fail int;v_journeys_pending int;
  v_deep_total int;v_deep_pass int;v_deep_fail int;v_deep_pending int;v_transport int;v_timeout int;
  v_ui_expected int;v_ui_pass int;v_ui_fail int;v_resp_pass int;v_resp_fail int;v_sandbox_pass int;v_sandbox_fail int;
  v_health_pass int;v_health_fail int;v_contract_fail int;v_domain_fail int;v_controls_pass int;v_branch_pass int;v_cleanup_remaining int;v_certified boolean;v_gates jsonb;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;

  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING'))
  into v_routes_total,v_routes_pass,v_routes_fail,v_routes_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL';
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING'))
  into v_journeys_total,v_journeys_pass,v_journeys_fail,v_journeys_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL';
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING')),coalesce(sum(transport_failures),0)::int,coalesce(sum(timeout_failures),0)::int
  into v_deep_total,v_deep_pass,v_deep_fail,v_deep_pending,v_transport,v_timeout from erp_supply.qa_deep_cases where qa_run_id=p_run_id;

  select count(*) into v_ui_expected from erp_supply.modules m join erp_supply.role_module_permissions p on p.module_code=m.code and p.role_code='super_admin' where m.active and p.can_read;
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_ui_pass,v_ui_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key like 'UI-MODULE-%';
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_resp_pass,v_resp_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key like 'RESP-%';
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_sandbox_pass,v_sandbox_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and (check_key like 'SANDBOX-STEP-%' or check_key='SANDBOX-CUTTING-PARALLEL');
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_health_pass,v_health_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key in('HEALTH-GLOBAL','HEALTH-WORKFORCE','HEALTH-QUEUES','HEALTH-RESERVATIONS','HEALTH-RUNTIME','INTEGRITY-STRUCTURAL','INTEGRITY-FLOW');
  select count(*) into v_contract_fail from erp_supply.qa_robot_checks where qa_run_id=p_run_id and layer='CONTRACT' and status='FAILED';
  select count(*) into v_domain_fail from erp_supply.qa_robot_checks where qa_run_id=p_run_id and layer='DOMAIN' and status='FAILED';
  select count(*) into v_controls_pass from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-CONTROLS-10' and status='PASSED';
  select count(*) into v_branch_pass from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-BRANCH-SUITE' and status='PASSED';
  select count(*) into v_cleanup_remaining from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT';

  v_gates:=jsonb_build_object(
    'routing',jsonb_build_object('expected',336,'planned',v_routes_total,'executed',v_routes_pass+v_routes_fail,'passed',v_routes_pass,'failed',v_routes_fail,'pending',v_routes_pending,'ok',v_routes_total=336 and v_routes_pass=336 and v_routes_fail=0 and v_routes_pending=0),
    'journeys',jsonb_build_object('expected',336,'planned',v_journeys_total,'executed',v_journeys_pass+v_journeys_fail,'passed',v_journeys_pass,'failed',v_journeys_fail,'pending',v_journeys_pending,'ok',v_journeys_total=336 and v_journeys_pass=336 and v_journeys_fail=0 and v_journeys_pending=0),
    'extreme',jsonb_build_object('planned',v_deep_total,'executed',v_deep_pass+v_deep_fail,'passed',v_deep_pass,'failed',v_deep_fail,'pending',v_deep_pending,'transport',v_transport,'timeouts',v_timeout,'ok',v_deep_total>672 and v_deep_fail=0 and v_deep_pending=0 and v_transport=0 and v_timeout=0),
    'interface',jsonb_build_object('expectedModules',v_ui_expected,'passedModules',v_ui_pass,'failedModules',v_ui_fail,'ok',v_ui_pass=v_ui_expected and v_ui_fail=0),
    'responsive',jsonb_build_object('expected',54,'passed',v_resp_pass,'failed',v_resp_fail,'ok',v_resp_pass=54 and v_resp_fail=0),
    'sandboxUi',jsonb_build_object('expected',14,'passed',v_sandbox_pass,'failed',v_sandbox_fail,'ok',v_sandbox_pass=14 and v_sandbox_fail=0),
    'integrity',jsonb_build_object('expected',7,'passed',v_health_pass,'failed',v_health_fail,'ok',v_health_pass=7 and v_health_fail=0),
    'domainChecks',jsonb_build_object('controlsPassed',v_controls_pass=1,'branchSuitePassed',v_branch_pass=1,'failed',v_domain_fail,'ok',v_controls_pass=1 and v_branch_pass=1 and v_domain_fail=0),
    'contracts',jsonb_build_object('failed',v_contract_fail,'ok',v_contract_fail=0),
    'cleanup',jsonb_build_object('remainingTestOrders',v_cleanup_remaining,'ok',v_cleanup_remaining=0)
  );

  v_certified:=
    v_routes_total=336 and v_routes_pass=336 and v_routes_fail=0 and v_routes_pending=0
    and v_journeys_total=336 and v_journeys_pass=336 and v_journeys_fail=0 and v_journeys_pending=0
    and v_deep_total>672 and v_deep_fail=0 and v_deep_pending=0 and v_transport=0 and v_timeout=0
    and v_ui_pass=v_ui_expected and v_ui_fail=0
    and v_resp_pass=54 and v_resp_fail=0
    and v_sandbox_pass=14 and v_sandbox_fail=0
    and v_health_pass=7 and v_health_fail=0 and v_controls_pass=1 and v_branch_pass=1 and v_domain_fail=0 and v_contract_fail=0 and v_cleanup_remaining=0;

  return jsonb_build_object('certified',v_certified,'releaseState',case when v_certified then 'CERTIFIED' when v_deep_pending>0 then 'INCOMPLETE' else 'FAILED' end,
    'runId',p_run_id,'gates',v_gates,'version','10.25.2','checkedAt',now());
end;
$$;

-- Cierre de una prueba dirigida (solo rutas o solo campaña profunda). No emite
-- certificado de liberación; solo asegura que su inventario particular terminó.
create or replace function public.erp_x_qa_robot_finish_directed_run(p_run_id uuid,p_suite text default 'DIRECTED')
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_order uuid;v_deleted int:=0;v_cleanup_remaining int:=0;
  v_total int:=0;v_passed int:=0;v_failed int:=0;v_pending int:=0;v_transport int:=0;v_timeout int:=0;v_ok boolean:=false;v_suite text:=upper(coalesce(nullif(trim(p_suite),''),'DIRECTED'));
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  for v_order in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
    begin perform public.erp_x_sandbox_delete(v_order);v_deleted:=v_deleted+1; exception when others then null; end;
  end loop;
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING')),coalesce(sum(transport_failures),0)::int,coalesce(sum(timeout_failures),0)::int
    into v_total,v_passed,v_failed,v_pending,v_transport,v_timeout from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  select count(*) into v_cleanup_remaining from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT';
  v_ok:=v_total>0 and v_passed=v_total and v_failed=0 and v_pending=0 and v_transport=0 and v_timeout=0 and v_cleanup_remaining=0;
  update erp_supply.qa_runs set status=case when v_ok then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,
    completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('directedSuite',v_suite,'planned',v_total,'executed',v_passed+v_failed,'passed',v_passed,
      'failed',v_failed,'pending',v_pending,'transport',v_transport,'timeouts',v_timeout,'sandboxOrdersDeleted',v_deleted,'cleanupRemaining',v_cleanup_remaining,'qaRobotVersion','10.25.2')
  where id=p_run_id;
  return jsonb_build_object('runId',p_run_id,'suite',v_suite,'status',case when v_ok then 'PASSED' else 'FAILED' end,'passed',v_passed,'failed',v_failed,
    'planned',v_total,'executed',v_passed+v_failed,'pending',v_pending,'transportFailures',v_transport,'timeoutFailures',v_timeout,'cleanupRemaining',v_cleanup_remaining,'version','10.25.2');
end;
$$;

-- El cierre del Robot se subordina al certificado, no solo al número de checks.
create or replace function public.erp_x_qa_robot_finish_run(p_run_id uuid,p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_order uuid;v_deleted int:=0;
  v_total int:=0;v_passed int:=0;v_failed int:=0;v_warnings int:=0;v_running int:=0;v_certificate jsonb;v_certified boolean;v_release_state text;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  if p_cleanup then
    for v_order in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
      begin perform public.erp_x_sandbox_delete(v_order);v_deleted:=v_deleted+1;
      exception when others then
        perform public.erp_x_qa_robot_record_check(p_run_id,jsonb_build_object('checkKey','CLEANUP-'||v_order::text,'layer','INTEGRITY','suite','SANDBOX_CLEANUP','status','FAILED','severity','CRITICAL','orderId',v_order,'errorMessage',sqlstate||' · '||sqlerrm));
      end;
    end loop;
  end if;

  select count(*) filter(where status<>'SKIPPED'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='WARNING'),count(*) filter(where status='RUNNING')
  into v_total,v_passed,v_failed,v_warnings,v_running from erp_supply.qa_robot_checks where qa_run_id=p_run_id;
  v_certificate:=public.erp_x_qa_robot_release_certificate(p_run_id);
  v_certified:=coalesce((v_certificate->>'certified')::boolean,false);v_release_state:=coalesce(v_certificate->>'releaseState','FAILED');

  update erp_supply.qa_runs set status=case when v_certified then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,
    failed_scenarios=v_failed+case when v_certified then 0 else 1 end,completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
      'warnings',v_warnings,'runningChecksAtFinish',v_running,'sandboxOrdersDeleted',v_deleted,'qaRobotVersion','10.25.2','releaseState',v_release_state,'releaseCertificate',v_certificate,'finishedAt',now())
  where id=p_run_id;
  return jsonb_build_object('runId',p_run_id,'status',case when v_certified then 'PASSED' else 'FAILED' end,'releaseState',v_release_state,'certified',v_certified,
    'total',v_total,'passed',v_passed,'failed',v_failed+case when v_certified then 0 else 1 end,'warnings',v_warnings,'sandboxOrdersDeleted',v_deleted,'certificate',v_certificate);
end;
$$;

create or replace function public.erp_x_qa_robot_latest_resumable()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run uuid;v_progress jsonb;
begin
  select r.id into v_run from erp_supply.qa_runs r where r.organization_id=v_org and r.run_type='TOTAL_ROBOT'
    and exists(select 1 from erp_supply.qa_deep_cases c where c.qa_run_id=r.id and c.status in('PENDING','RUNNING'))
  order by r.started_at desc limit 1;
  if v_run is null then return jsonb_build_object('available',false,'version','10.25.2'); end if;
  v_progress:=public.erp_x_qa_robot_deep_progress(v_run,1);
  return jsonb_build_object('available',true,'runId',v_run,'progress',v_progress,'version','10.25.2');
end;
$$;

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
    'version','10.25.2','strategy','RELEASE_CERTIFICATION_RESUMABLE_ZERO_SKIPS','productionIsolation',true,
    'domain',jsonb_build_object('routingCombinations',336,'fullSequentialJourneys',336,'enterpriseControls',10,'integrityGates',2,'branchChecks',10,
      'activeSteps',v_steps,'releaseRule','planned = executed; pending = 0; transport = 0; all finite branches covered'),
    'ui',jsonb_build_object('modules','ALL_SUPER_ADMIN_MODULES','mustOpenSandboxOrders',true,'mustExecutePrimaryAction',true,'consoleAndRpcErrors',true),
    'responsive',jsonb_build_object('widths',jsonb_build_array(360,390,424,768,960,1440),'expectedChecks',54),
    'certificate',jsonb_build_object('required',true,'states',jsonb_build_array('CERTIFIED','INCOMPLETE','FAILED'),'passState','CERTIFIED'),
    'capacity',jsonb_build_object('engine','k6','separateReleaseGate',true,'profiles',jsonb_build_array('SMOKE','NORMAL','BUSY','PEAK','SPIKE','SOAK','BREAKPOINT')),
    'requestedBy',v_actor
  );
end;
$$;

revoke all on function public.erp_x_qa_robot_build_release_campaign(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_build_route_campaign(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_transport_failure(uuid,text,boolean) from public,anon;
revoke all on function public.erp_x_qa_robot_reset_stale_cases(uuid,integer) from public,anon;
revoke all on function public.erp_x_qa_robot_release_certificate(uuid) from public,anon;
revoke all on function public.erp_x_qa_robot_latest_resumable() from public,anon;
revoke all on function public.erp_x_qa_robot_finish_directed_run(uuid,text) from public,anon;
grant execute on function public.erp_x_qa_robot_build_release_campaign(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_build_route_campaign(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_transport_failure(uuid,text,boolean) to authenticated;
grant execute on function public.erp_x_qa_robot_reset_stale_cases(uuid,integer) to authenticated;
grant execute on function public.erp_x_qa_robot_release_certificate(uuid) to authenticated;
grant execute on function public.erp_x_qa_robot_latest_resumable() to authenticated;
grant execute on function public.erp_x_qa_robot_finish_directed_run(uuid,text) to authenticated;

notify pgrst,'reload schema';
commit;
