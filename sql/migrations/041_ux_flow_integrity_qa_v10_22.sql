-- ERP EI V10.22.0
-- Revisión integral UX + integridad funcional: QA alineado con el motor vigente.
-- Base requerida: migraciones 035, 036, 038, 039 y 040 aplicadas.

begin;

-- ============================================================================
-- 1. MATRIZ DE ENRUTAMIENTO VIGENTE
--    Ya no valida la firma histórica de 3 parámetros. Incluye las combinaciones
--    financieras que realmente alteran el ingreso del pedido al proceso.
-- ============================================================================
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
  v_type text;
  v_payment text;
  v_route text;
  v_cut boolean;
  v_purchase boolean;
  v_has_credit_arrears boolean;
  v_held_by_cashier boolean;
  v_requires_purchase boolean;
  v_key text;
  v_initial text;
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_scenario erp_supply.qa_scenarios%rowtype;
  v_expected jsonb;
  v_actual jsonb;
  v_step text;
  v_guard integer;
  v_passed integer:=0;
  v_failed integer:=0;
  v_total integer:=0;
  v_error text;
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'El bot QA solo puede ser ejecutado por Super Admin' using errcode='42501';
  end if;

  -- 7 variantes financieras × 3 condiciones de pago × 4 rutas × 2 corte × 2 compra = 336.
  insert into erp_supply.qa_runs(organization_id,requested_by,total_scenarios,summary)
  values(
    v_org,
    v_actor,
    336,
    jsonb_build_object(
      'matrix','7 financial entry states × 3 payments × 4 routes × 2 cut × 2 purchase',
      'routingVersion','10.22.0',
      'initialStepSignature','initial_step(text,text,boolean,boolean,boolean)'
    )
  )
  returning * into v_run;

  for v_financial in select value from jsonb_array_elements(v_states)
  loop
    v_type:=v_financial->>'orderType';
    v_has_credit_arrears:=coalesce((v_financial->>'hasCreditArrears')::boolean,false);
    v_held_by_cashier:=coalesce((v_financial->>'heldByCashier')::boolean,false);

    foreach v_payment in array array['CREDIT','CASH','MIXED']
    loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH']
      loop
        foreach v_cut in array array[false,true]
        loop
          foreach v_purchase in array array[false,true]
          loop
            v_total:=v_total+1;
            v_error:=null;
            v_requires_purchase:=v_purchase or v_type='PVE';
            v_key:=format(
              '%s-%s-%s-CUT_%s-BUY_%s',
              v_financial->>'code',v_payment,v_route,v_cut,v_purchase
            );

            v_initial:=erp_supply.initial_step(
              v_type,
              v_payment,
              v_requires_purchase,
              v_has_credit_arrears,
              v_held_by_cashier
            );

            v_expected:=jsonb_build_array(v_initial);
            v_step:=v_initial;
            v_guard:=0;
            while v_step<>'CLOSED' and v_guard<20
            loop
              v_step:=erp_supply.next_step(
                v_step,v_type,v_payment,v_route,v_cut,v_requires_purchase
              );
              v_expected:=v_expected||jsonb_build_array(v_step);
              v_guard:=v_guard+1;
            end loop;

            insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,input,expected_path)
            values(
              v_run.id,
              v_key,
              jsonb_build_object(
                'orderType',v_type,
                'payment',v_payment,
                'route',v_route,
                'requiresCut',v_cut,
                'requiresPurchase',v_purchase,
                'hasCreditArrears',v_has_credit_arrears,
                'heldByCashier',v_held_by_cashier,
                'routingVariant',v_financial->>'code'
              ),
              v_expected
            )
            returning * into v_scenario;

            begin
              insert into erp_supply.orders(
                organization_id,order_number,order_type_code,payment_condition_code,
                delivery_route_code,client_name,seller_profile_id,current_step_code,status,
                requires_cut,requires_purchase,source,is_test,qa_run_id,metadata
              )
              values(
                v_org,
                'QA-'||replace(v_run.id::text,'-','')||'-'||lpad(v_total::text,3,'0'),
                v_type,v_payment,v_route,'Cliente QA '||v_key,v_actor,v_initial,'QUEUED',
                v_cut,v_requires_purchase,'QA_BOT',true,v_run.id,
                jsonb_build_object(
                  'scenario',v_key,
                  'hasCreditArrears',v_has_credit_arrears,
                  'heldByCashier',v_held_by_cashier,
                  'routingVersion','10.22.0'
                )
              )
              returning * into v_order;

              insert into erp_supply.order_items(
                order_id,line_number,sku,reference,description,quantity,unit,
                requires_cut,requested_cut_length,metadata
              )
              values(
                v_order.id,1,'QA-'||v_type,'QA-'||v_type,
                'Material de prueba automatizada',1,'UND',v_cut,
                case when v_cut then 10 else null end,
                jsonb_build_object('qa',true,'routingVersion','10.22.0')
              );

              select * into v_task from erp_supply.create_task(v_order,v_initial,1);
              v_actual:=jsonb_build_array(v_initial);
              v_guard:=0;

              loop
                select * into v_order from erp_supply.orders where id=v_order.id;
                exit when v_order.status='CLOSED' or v_guard>=20;

                perform erp_supply.execute_action_internal(
                  v_order.id,'START',jsonb_build_object('detail','Inicio QA'),
                  v_actor,true,null,v_key||'-START-'||v_guard
                );
                perform erp_supply.execute_action_internal(
                  v_order.id,'COMPLETE',jsonb_build_object('detail','Finalización QA'),
                  v_actor,true,null,v_key||'-COMPLETE-'||v_guard
                );

                select * into v_order from erp_supply.orders where id=v_order.id;
                v_actual:=v_actual||jsonb_build_array(v_order.current_step_code);
                v_guard:=v_guard+1;
              end loop;

              if v_order.status='CLOSED' and v_actual=v_expected then
                update erp_supply.qa_scenarios
                set order_id=v_order.id,actual_path=v_actual,status='PASSED',completed_at=now()
                where id=v_scenario.id;
                v_passed:=v_passed+1;
              else
                v_error:=format(
                  'Estado final %s; paso %s; ruta esperada %s; ruta real %s',
                  v_order.status,v_order.current_step_code,v_expected,v_actual
                );
                update erp_supply.qa_scenarios
                set order_id=v_order.id,actual_path=v_actual,status='FAILED',error_message=v_error,completed_at=now()
                where id=v_scenario.id;
                v_failed:=v_failed+1;
              end if;
            exception when others then
              v_error:=sqlstate||' - '||sqlerrm;
              update erp_supply.qa_scenarios
              set order_id=v_order.id,actual_path=coalesce(v_actual,'[]'::jsonb),status='FAILED',error_message=v_error,completed_at=now()
              where id=v_scenario.id;
              v_failed:=v_failed+1;
            end;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;

  update erp_supply.qa_runs
  set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,
      total_scenarios=v_total,
      passed_scenarios=v_passed,
      failed_scenarios=v_failed,
      completed_at=now(),
      summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
        'cleanup',p_cleanup,
        'currentRouting',true,
        'financialEntryVariants',7
      )
  where id=v_run.id
  returning * into v_run;

  if p_cleanup then
    delete from erp_supply.orders where qa_run_id=v_run.id;
  end if;

  return jsonb_build_object(
    'runId',v_run.id,
    'status',v_run.status,
    'total',v_total,
    'passed',v_passed,
    'failed',v_failed,
    'completedAt',v_run.completed_at,
    'matrixVersion','10.22.0'
  );
end;
$$;

-- La firma histórica ya no debe poder ser llamada accidentalmente por código nuevo.
drop function if exists erp_supply.initial_step(text,text,boolean);

-- ============================================================================
-- 2. AUTODIAGNÓSTICO ESTRUCTURAL V10.22
--    Comprueba que las piezas que sostienen los flujos actuales no hayan
--    retrocedido a implementaciones heredadas.
-- ============================================================================
create or replace function public.erp_x_v10_22_self_check()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_checks jsonb:='[]'::jsonb;
  v_ok boolean;
  v_definition text;
  v_all_ok boolean;
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'El autodiagnóstico V10.22 solo puede ser ejecutado por Super Admin' using errcode='42501';
  end if;

  v_ok:=to_regprocedure('erp_supply.initial_step(text,text,boolean,boolean,boolean)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','ROUTING_CURRENT_SIGNATURE','ok',v_ok));

  v_ok:=to_regprocedure('erp_supply.initial_step(text,text,boolean)') is null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','ROUTING_LEGACY_SIGNATURE_REMOVED','ok',v_ok));

  v_ok:=to_regclass('erp_supply.cut_requirements') is not null
    and to_regclass('erp_supply.cut_executions') is not null
    and to_regclass('erp_supply.cut_execution_requirements') is not null
    and to_regclass('erp_supply.cut_execution_pauses') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','CUT_EXECUTION_MODEL','ok',v_ok));

  v_ok:=to_regprocedure('erp_supply.cut_execution_requirement_state(uuid)') is not null
    and to_regprocedure('erp_supply.sync_cut_execution_state(uuid,uuid)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','CUT_STATE_SYNCHRONIZER','ok',v_ok));

  v_ok:=to_regprocedure('public.erp_x_cutting_finalize(uuid)') is not null
    and to_regprocedure('public.erp_x_cutting_register_evidence(uuid,uuid)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','CUT_EVIDENCE_GATE','ok',v_ok));

  select exists(
    select 1
    from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply'
      and c.relname='cut_executions'
      and t.tgname='trg_sync_sandbox_cut_status_from_execution'
      and not t.tgisinternal
      and t.tgenabled<>'D'
  ) into v_ok;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','CUT_SANDBOX_MIRROR_TRIGGER','ok',v_ok));

  if to_regprocedure('public.erp_x_sandbox_cutting_work(text,integer,integer)') is not null then
    select pg_get_functiondef(to_regprocedure('public.erp_x_sandbox_cutting_work(text,integer,integer)')) into v_definition;
    v_ok:=position('metadata->>''sandboxCutStatus''' in coalesce(v_definition,''))=0
      and position('metadata ->> ''sandboxCutStatus''' in coalesce(v_definition,''))=0;
  else
    v_ok:=false;
  end if;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object(
    'check','CUT_QUEUE_CANONICAL_SOURCE','ok',v_ok,
    'expected','cut_requirements+cut_executions'
  ));

  select exists(
    select 1 from pg_indexes
    where schemaname='erp_supply' and indexname='uq_open_session_per_task'
  ) and not exists(
    select 1 from pg_indexes
    where schemaname='erp_supply' and indexname='uq_open_session_per_user'
  ) into v_ok;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','MULTI_ORDER_SESSIONS','ok',v_ok));

  v_ok:=to_regprocedure('public.erp_x_confirm_order_reception(uuid,jsonb)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','RECEPTION_TRANSACTION_RPC','ok',v_ok));

  v_ok:=to_regprocedure('public.erp_x_receipt_progress(uuid)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','PVE_RECEIPT_PROGRESS','ok',v_ok));

  select exists(
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='order_tasks'
      and t.tgname='trg_require_complete_receipt_before_task_complete'
      and not t.tgisinternal and t.tgenabled<>'D'
  ) into v_ok;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','PVE_RECEIPT_COMPLETION_GATE','ok',v_ok));

  select exists(
    select 1 from pg_trigger t
    join pg_class c on c.oid=t.tgrelid
    join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='picking_round_items'
      and t.tgname='trg_require_collected_cut_for_picking'
      and not t.tgisinternal and t.tgenabled<>'D'
  ) into v_ok;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','PICKING_REQUIRES_COLLECTED_CUT','ok',v_ok));

  v_ok:=to_regprocedure('public.erp_x_flow_integrity()') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','FLOW_INTEGRITY_DIAGNOSTIC','ok',v_ok));

  v_ok:=to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null
    and to_regprocedure('public.erp_x_run_qa_control_suite(boolean)') is not null;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('check','QA_ENTRYPOINTS','ok',v_ok));

  select coalesce(bool_and((x->>'ok')::boolean),false)
  into v_all_ok
  from jsonb_array_elements(v_checks) x;

  return jsonb_build_object(
    'success',v_all_ok,
    'version','10.22.0',
    'checkedBy',v_actor,
    'checkedAt',now(),
    'checks',v_checks
  );
end;
$$;

-- ============================================================================
-- 3. EJECUCIÓN QA UNIFICADA
--    Da una única entrada para matriz de rutas, controles empresariales y
--    autodiagnóstico estructural. No oculta los resultados individuales.
-- ============================================================================
create or replace function public.erp_x_run_qa_v10_22(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_matrix jsonb;
  v_controls jsonb;
  v_self jsonb;
  v_ok boolean;
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'La QA integral V10.22 solo puede ser ejecutada por Super Admin' using errcode='42501';
  end if;

  v_matrix:=public.erp_x_run_qa_matrix(p_cleanup);
  v_controls:=public.erp_x_run_qa_control_suite(p_cleanup);
  v_self:=public.erp_x_v10_22_self_check();

  v_ok:=coalesce(v_matrix->>'status','FAILED')='PASSED'
    and coalesce(v_controls->>'status','FAILED')='PASSED'
    and coalesce((v_self->>'success')::boolean,false);

  return jsonb_build_object(
    'success',v_ok,
    'version','10.22.0',
    'matrix',v_matrix,
    'controls',v_controls,
    'selfCheck',v_self,
    'note','La suite de controles conserva pruebas de bajo nivel; la matriz V10.22 valida el enrutamiento financiero vigente y el autodiagnóstico protege la arquitectura actual de Corte.'
  );
end;
$$;

revoke all on function public.erp_x_run_qa_matrix(boolean) from public,anon;
grant execute on function public.erp_x_run_qa_matrix(boolean) to authenticated;
revoke all on function public.erp_x_v10_22_self_check() from public,anon;
grant execute on function public.erp_x_v10_22_self_check() to authenticated;
revoke all on function public.erp_x_run_qa_v10_22(boolean) from public,anon;
grant execute on function public.erp_x_run_qa_v10_22(boolean) to authenticated;

notify pgrst,'reload schema';
commit;
