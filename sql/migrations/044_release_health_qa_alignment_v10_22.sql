-- ERP EI V10.22.0
-- Alinea QA empresarial, health check y diagnósticos con la arquitectura vigente.

begin;

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

  -- 9. Recepción PVE parcial/acumulada e aislamiento QA.
  v_total:=v_total+1;v_key:='CTRL-09-RECEIPT-PARTIAL-PROGRESS';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'RECEIPT','RECEPCION_MERCANCIA',true);
    select id into v_item from erp_supply.order_items where order_id=v_order_id order by line_number limit 1;

    perform public.erp_x_save_receipt(v_order_id,jsonb_build_object(
      'receiptNumber','QAR-P1-'||substr(v_run.id::text,1,8),
      'requestId',v_key||'-P1','status','PARTIAL',
      'lines',jsonb_build_array(jsonb_build_object(
        'orderItemId',v_item,'receivedQuantity',6,'acceptedQuantity',6,'rejectedQuantity',0,
        'qualityStatus','ACCEPTED','location','QA','lotNumber','LOT-QA-P1'
      ))
    ));
    v_result:=public.erp_x_receipt_progress(v_order_id);
    v_ok:=coalesce((v_result->>'complete')::boolean,false)=false
      and coalesce((v_result->'items'->0->>'acceptedQuantity')::numeric,0)=6
      and coalesce((v_result->'items'->0->>'remainingQuantity')::numeric,0)=4
      and not exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT');

    perform public.erp_x_save_receipt(v_order_id,jsonb_build_object(
      'receiptNumber','QAR-P2-'||substr(v_run.id::text,1,8),
      'requestId',v_key||'-P2','status','CONFORMING',
      'lines',jsonb_build_array(jsonb_build_object(
        'orderItemId',v_item,'receivedQuantity',4,'acceptedQuantity',4,'rejectedQuantity',0,
        'qualityStatus','ACCEPTED','location','QA','lotNumber','LOT-QA-P2'
      ))
    ));
    v_result2:=public.erp_x_receipt_progress(v_order_id);
    v_ok:=v_ok
      and coalesce((v_result2->>'complete')::boolean,false)
      and coalesce((v_result2->'items'->0->>'acceptedQuantity')::numeric,0)=10
      and coalesce((v_result2->'items'->0->>'remainingQuantity')::numeric,0)=0
      and not exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT');
    if not v_ok then v_error:='La recepción parcial/acumulada o el aislamiento de inventario QA no se conservaron'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('PARTIAL_6','REMAINING_4','COMPLETE_10','NO_QA_INVENTORY'),jsonb_build_array(v_result,v_result2),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

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
    summary=summary||jsonb_build_object('cleanup',p_cleanup,'controls','idempotency,version,sessions,timing,gates,delivery,approval,history,receipt-progress,cut-engine','suiteVersion','10.22.0')
  where id=v_run.id returning * into v_run;

  return jsonb_build_object('runId',v_run.id,'runType',v_run.run_type,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
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
public_api as (
  select p.oid,p.proname,p.prosecdef,
         has_function_privilege('authenticated',p.oid,'EXECUTE') auth_execute,
         has_function_privilege('anon',p.oid,'EXECUTE') anon_execute
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'erp_x_%'
),
latest_matrix as (
  select q.* from erp_supply.qa_runs q where q.run_type='MATRIX' order by q.started_at desc limit 1
),
latest_controls as (
  select q.* from erp_supply.qa_runs q where q.run_type='CONTROL_SUITE' order by q.started_at desc limit 1
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
  select o.id
  from erp_supply.orders o
  left join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.status not in('DRAFT','CLOSED','CANCELLED')
  group by o.id
  having count(t.id)<>1
),
step_mismatches as (
  select o.id
  from erp_supply.orders o
  join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.current_step_code<>t.step_code
),
duplicate_task_sessions as (
  select s.task_id from erp_supply.task_sessions s where s.ended_at is null group by s.task_id having count(*)>1
),
cut_without_collection as (
  select i.id
  from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id
  where not o.is_test and not o.is_history and i.requires_cut and i.item_status='FULFILLED'
    and not exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=i.id and r.process_status='READY' and r.collection_status='COLLECTED')
),
cut_without_evidence as (
  select e.id from erp_supply.cut_executions e where e.status='COMPLETED' and e.evidence_file_id is null
),
receipt_lot_without_master as (
  select l.id
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where l.source_system='ERP_RECEIPT' and ii.material_master_id is null
),
checks as (
  select '01_BASE'::text section,'Organización activa'::text check_name,
    exists(select 1 from erp_supply.organizations where code='EI' and active) ok,
    (select count(*)||' organización(es) activas' from erp_supply.organizations where active) detail

  union all select '01_BASE','Núcleo operativo instalado',
    to_regclass('erp_supply.orders') is not null and to_regclass('erp_supply.order_tasks') is not null
      and to_regclass('erp_supply.inventory_movements') is not null and to_regclass('erp_supply.cut_executions') is not null,
    'Pedidos, tareas, inventario y ejecuciones de Corte'

  union all select '01_BASE','Perfil de la sesión vinculado',
    exists(select 1 from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active limit 1),'Sesión sin perfil activo')

  union all select '02_SEGURIDAD','Esquema interno oculto',
    not has_schema_privilege('authenticated','erp_supply','USAGE') and not has_schema_privilege('anon','erp_supply','USAGE'),
    'erp_supply sin acceso directo desde roles cliente'

  union all select '02_SEGURIDAD','RPC protegidos con SECURITY DEFINER',
    not exists(select 1 from public_api where not prosecdef),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not prosecdef),'Todos los RPC erp_x_* protegidos')

  union all select '02_SEGURIDAD','RPC autenticados y rol anónimo bloqueado',
    not exists(select 1 from public_api where not auth_execute or anon_execute),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not auth_execute or anon_execute),'Sin RPC erp_x_* expuesto a anon y todos disponibles para authenticated')

  union all select '03_CALENDARIO','Calendario operativo Colombia',
    exists(select 1 from calendar_stats where timezone='America/Bogota' and segments=10 and weekly_seconds=159000),
    coalesce((select timezone||' · '||segments||' segmentos · '||round(weekly_seconds/3600.0,2)||' h/semana' from calendar_stats),'Calendario no encontrado')

  union all select '04_ENRUTAMIENTO','Motor financiero V10.22 vigente',
    to_regprocedure('erp_supply.initial_step(text,text,boolean,boolean,boolean)') is not null
      and to_regprocedure('erp_supply.initial_step(text,text,boolean)') is null,
    'Firma actual de 5 parámetros; firma histórica de 3 parámetros ausente'

  union all select '04_ENRUTAMIENTO','Catálogos comerciales completos',
    (select count(*)=4 from erp_supply.order_types where active)
      and (select count(*)=3 from erp_supply.payment_conditions where active)
      and (select count(*)=4 from erp_supply.delivery_routes where active),
    format('%s tipos · %s pagos · %s rutas',
      (select count(*) from erp_supply.order_types where active),
      (select count(*) from erp_supply.payment_conditions where active),
      (select count(*) from erp_supply.delivery_routes where active))

  union all select '05_CONCURRENCIA','Múltiples pedidos activos por operario',
    to_regclass('erp_supply.uq_open_session_per_user') is null and to_regclass('erp_supply.uq_open_session_per_task') is not null,
    'Sin bloqueo por usuario; una sesión abierta máxima por tarea'

  union all select '05_CONCURRENCIA','Tareas activas coherentes',
    not exists(select 1 from active_task_issues) and not exists(select 1 from step_mismatches),
    format('%s pedido(s) con cantidad inválida de tareas · %s desalineado(s)',
      (select count(*) from active_task_issues),(select count(*) from step_mismatches))

  union all select '05_CONCURRENCIA','Sesiones duplicadas por tarea',
    not exists(select 1 from duplicate_task_sessions),
    (select count(*)||' tarea(s) con más de una sesión abierta' from duplicate_task_sessions)

  union all select '06_RECEPCION','Recepción PVE acumulada instalada',
    to_regprocedure('public.erp_x_receipt_progress(uuid)') is not null
      and to_regprocedure('public.erp_x_save_receipt(uuid,jsonb)') is not null
      and exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='erp_supply' and c.relname='order_tasks' and t.tgname='trg_require_complete_receipt_before_task_complete' and t.tgenabled<>'D'),
    'Progreso acumulado, recepción idempotente y gate de cierre'

  union all select '06_RECEPCION','Lotes ERP_RECEIPT conservan identidad Siesa',
    not exists(select 1 from receipt_lot_without_master),
    (select count(*)||' lote(s) ERP_RECEIPT sin material oficial' from receipt_lot_without_master)

  union all select '07_CORTE','Modelo de ejecución + evidencia instalado',
    to_regprocedure('erp_supply.sync_cut_execution_state(uuid,uuid)') is not null
      and to_regprocedure('public.erp_x_cutting_finalize(uuid)') is not null
      and exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
        where n.nspname='erp_supply' and c.relname='cut_executions' and t.tgname='trg_sync_sandbox_cut_status_from_execution' and t.tgenabled<>'D'),
    'Ejecución, evidencia final y espejo Sandbox sincronizado'

  union all select '07_CORTE','Cola Sandbox usa fuente canónica',
    to_regprocedure('public.erp_x_sandbox_cutting_work(text,integer,integer)') is not null
      and position('metadata->>''sandboxCutStatus''' in pg_get_functiondef(to_regprocedure('public.erp_x_sandbox_cutting_work(text,integer,integer)')))=0,
    'Autoridad: cut_requirements + cut_executions'

  union all select '07_CORTE','Cortes cerrados conservan evidencia',
    not exists(select 1 from cut_without_evidence),
    (select count(*)||' ejecución(es) COMPLETED sin evidencia' from cut_without_evidence)

  union all select '08_ALISTAMIENTO','Recogida de Corte protegida en servidor',
    exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and c.relname='picking_round_items' and t.tgname='trg_require_collected_cut_for_picking' and t.tgenabled<>'D')
      and not exists(select 1 from cut_without_collection),
    (select count(*)||' línea(s) de corte fulfilled sin recogida válida' from cut_without_collection)

  union all select '09_QA','QA integral V10.22 instalada',
    to_regprocedure('public.erp_x_run_qa_v10_22(boolean)') is not null
      and to_regprocedure('public.erp_x_flow_integrity()') is not null,
    '336 rutas + 10 controles + autodiagnóstico + integridad entre flujos'

  union all select '09_QA','Última matriz de 336 rutas aprobada',
    exists(select 1 from latest_matrix where status='PASSED' and total_scenarios=336 and passed_scenarios=336 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_matrix),'Aún no se ha ejecutado la matriz V10.22')

  union all select '09_QA','Últimos 10 controles empresariales aprobados',
    exists(select 1 from latest_controls where status='PASSED' and total_scenarios=10 and passed_scenarios=10 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_controls),'Aún no se ha ejecutado la suite V10.22')
)
select section,check_name,ok,detail from checks order by section,check_name
$$;

revoke all on function public.erp_x_run_qa_control_suite(boolean) from public,anon,authenticated;
grant execute on function public.erp_x_run_qa_control_suite(boolean) to authenticated;
revoke all on function public.erp_x_health_check() from public,anon,authenticated;
grant execute on function public.erp_x_health_check() to authenticated;

notify pgrst,'reload schema';
commit;
