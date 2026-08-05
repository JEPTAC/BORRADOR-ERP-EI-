-- ERP Supply Enterprise V10
-- Migration 014: cross-cutting QA suite for concurrency, gates, approvals, history and inventory.

begin;

create or replace function erp_supply.qa_make_order(
  p_run_id uuid,p_actor uuid,p_key text,p_step text,p_is_test boolean default true,
  p_route text default 'LOCAL_DISPATCH',p_requires_cut boolean default false
)
returns uuid
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_org uuid;v_order erp_supply.orders%rowtype;
begin
  select organization_id into v_org from erp_supply.profiles where id=p_actor;
  insert into erp_supply.orders(
    organization_id,order_number,order_type_code,payment_condition_code,delivery_route_code,client_name,
    seller_profile_id,current_step_code,status,requires_cut,requires_purchase,source,is_test,qa_run_id,metadata
  ) values(
    v_org,'QAC-'||substr(replace(p_run_id::text,'-',''),1,10)||'-'||p_key,'PVC','CREDIT',p_route,'Cliente control '||p_key,
    p_actor,p_step,'QUEUED',p_requires_cut,false,'QA_BOT',p_is_test,p_run_id,jsonb_build_object('controlScenario',p_key)
  ) returning * into v_order;
  insert into erp_supply.order_items(order_id,line_number,sku,description,quantity,unit,requires_cut,requested_cut_length)
  values(v_order.id,1,'QAC-'||p_key,'Material control automatizado',10,'UND',p_requires_cut,case when p_requires_cut then 5 else null end);
  perform erp_supply.create_task(v_order,p_step,1);
  return v_order.id;
end;
$$;

create or replace function erp_supply.qa_record(
  p_run_id uuid,p_key text,p_input jsonb,p_expected jsonb,p_actual jsonb,p_ok boolean,p_error text default null,p_order_id uuid default null
)
returns void
language sql
security definer
set search_path=erp_supply,public
as $$
  insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,order_id,input,expected_path,actual_path,status,error_message,completed_at)
  values(p_run_id,p_key,p_order_id,coalesce(p_input,'{}'::jsonb),coalesce(p_expected,'[]'::jsonb),coalesce(p_actual,'[]'::jsonb),
    case when p_ok then 'PASSED' else 'FAILED' end,p_error,now())
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

  -- 3. Una sola sesión activa por operario.
  v_total:=v_total+1;v_key:='CTRL-03-SINGLE-OPERATOR-SESSION';v_ok:=false;v_error:=null;v_order_id:=null;v_order2_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-A','RECEPCION_PEDIDO',true);
    v_order2_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-B','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-A');
    begin
      perform erp_supply.execute_action_internal(v_order2_id,'START','{}',v_actor,true,null,v_key||'-B');
      v_error:='Se permitieron dos sesiones simultáneas';
    exception when others then
      v_ok:=position('otra sesión' in lower(sqlerrm))>0 or position('uq_open_session_per_user' in lower(sqlerrm))>0;
      if not v_ok then v_error:=sqlstate||' - '||sqlerrm; end if;
    end;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('SECOND_SESSION_REJECTED'),jsonb_build_array(case when v_ok then 'REJECTED' else 'ACCEPTED' end),v_ok,v_error,v_order_id);
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

revoke all on function public.erp_x_run_qa_control_suite(boolean) from public,anon,authenticated;
grant execute on function public.erp_x_run_qa_control_suite(boolean) to authenticated;

-- Reconcile every public native RPC.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;
