-- ERP EI V10.25.8 · Cierre coherente + canario + resiliencia del certificador
--
-- Hallazgo real de la certificación V10.25.7:
-- CLIENT_PICKUP/CLIENT_POINT/LOCAL/NATIONAL avanzaban correctamente a CLOSURE,
-- y V10.11 asignaba el cierre a la misma persona/rol que despachó. Sin embargo,
-- default_role_for_step('CLOSURE', ...) conservaba la regla antigua jefe_logistica.
-- El certificador detectaba ROUTING_ROLE_MISMATCH antes de entrar a su bloque de
-- captura, por lo que dos workers se detenían aunque el pedido sí hubiera llegado
-- correctamente a CLOSURE.
--
-- Esta migración:
-- 1) alinea la regla canónica de CLOSURE con V10.11 (mismo frente de despacho),
-- 2) hace que send_to_closure herede el rol real de la tarea de despacho,
-- 3) envuelve el slice QA para que un error funcional se registre FAILED y NO
--    detenga los demás pedidos,
-- 4) agrega un pedido canario de extremo a extremo antes de soltar los 336.

begin;

-- ---------------------------------------------------------------------------
-- 1. CLOSURE: regla canónica coherente con Despachos V10.11.
--    Nacional conserva despacho_nacional; las otras rutas conservan logística.
-- ---------------------------------------------------------------------------
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
    when 'CLOSURE' then case when p_route='NATIONAL_DISPATCH' then 'despacho_nacional' else 'coordinador_logistico' end
    else null end
$$;

-- El diseño V10.11 ya permitía a estos roles operar CLOSURE. Lo reafirmamos
-- idempotentemente para bases existentes.
insert into erp_supply.step_roles(
  step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override
)
values
  ('CLOSURE','coordinador_logistico',true,true,false,true,true,true,false),
  ('CLOSURE','despacho_nacional',true,true,false,true,true,true,false)
on conflict(step_code,role_code) do update set
  can_view=excluded.can_view,
  can_claim=excluded.can_claim,
  can_start=excluded.can_start,
  can_complete=excluded.can_complete,
  can_block=excluded.can_block;

-- ---------------------------------------------------------------------------
-- 2. Despacho -> Cierre: hereda el rol REAL de la tarea que acaba de despachar.
--    Evita depender del orden no determinista de current_roles()[1].
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_shipping_send_to_closure(
  p_order_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_delivery erp_supply.deliveries%rowtype;
  v_result jsonb;
  v_closure erp_supply.order_tasks%rowtype;
  v_role text;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para gestionar despachos' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;

  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
    raise exception 'El pedido no está en despacho';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code=v_order.current_step_code
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found or v_task.status<>'IN_PROGRESS' then
    raise exception 'Primero debes tomar el pedido';
  end if;

  if v_task.assigned_profile_id is distinct from v_actor
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El pedido está asignado a otra persona' using errcode='42501';
  end if;

  -- La tarea activa es la fuente canónica del rol que realmente ejecutó despacho.
  v_role:=coalesce(
    v_task.assigned_role_code,
    erp_supply.default_role_for_step(v_order.current_step_code,v_order.delivery_route_code),
    erp_supply.default_role_for_step('CLOSURE',v_order.delivery_route_code)
  );

  if v_role is null then
    raise exception 'No fue posible resolver el rol operativo de despacho';
  end if;

  select * into v_delivery
  from erp_supply.deliveries
  where order_id=p_order_id
  order by created_at desc
  limit 1
  for update;

  if not found or nullif(trim(v_delivery.tracking_number),'') is null then
    raise exception 'Falta registrar la guía';
  end if;
  if nullif(v_delivery.metadata#>>'{destination,municipality}','') is null
     or nullif(v_delivery.metadata#>>'{destination,address}','') is null then
    raise exception 'Falta confirmar el lugar de entrega';
  end if;

  update erp_supply.deliveries
  set status='IN_TRANSIT',
      dispatched_at=coalesce(dispatched_at,now()),
      assigned_profile_id=v_actor,
      metadata=metadata||jsonb_build_object('sentToClosureAt',now()),
      updated_at=now()
  where id=v_delivery.id
  returning * into v_delivery;

  insert into erp_supply.delivery_milestones(
    organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata
  ) values(
    v_org,p_order_id,v_task.id,v_delivery.id,'DISPATCHED',v_actor,
    jsonb_build_object('trackingNumber',v_delivery.tracking_number,'route',v_order.delivery_route_code)
  );

  v_result:=erp_supply.execute_action_internal(
    p_order_id,'COMPLETE',
    jsonb_build_object(
      'detail',coalesce(nullif(p_payload->>'detail',''),'Pedido despachado y enviado a cierre'),
      'resultCode','DISPATCHED'
    ),
    v_actor,false,v_order.version,gen_random_uuid()::text
  );

  select * into v_closure
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code='CLOSURE'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found then raise exception 'No fue posible crear la etapa de cierre'; end if;

  -- V10.11: la misma persona que despacha puede realizar el cierre final.
  update erp_supply.order_tasks
  set assigned_profile_id=v_actor,
      assigned_role_code=v_role,
      assigned_at=coalesce(assigned_at,now()),
      status='ASSIGNED',
      metadata=metadata||jsonb_build_object(
        'source','SHIPPING_V10_25_8',
        'deliveryId',v_delivery.id,
        'inheritedDispatchRole',v_role
      )
  where id=v_closure.id
  returning * into v_closure;

  update erp_supply.orders
  set current_assignee_id=v_actor,
      current_role_code=v_role,
      status='ASSIGNED',
      version=version+1,
      updated_at=now()
  where id=p_order_id
  returning * into v_order;

  insert into erp_supply.delivery_milestones(
    organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata
  ) values(
    v_org,p_order_id,v_closure.id,v_delivery.id,'CLOSURE_ASSIGNED',v_actor,
    jsonb_build_object('previousTaskId',v_task.id,'role',v_role,'version','10.25.8')
  );

  return jsonb_build_object(
    'success',true,
    'orderId',p_order_id,
    'currentStep','CLOSURE',
    'closureRole',v_role,
    'closureProfileId',v_actor,
    'delivery',to_jsonb(v_delivery),
    'task',to_jsonb(v_closure),
    'version','10.25.8'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Resiliencia: preserva el core 10.25.7 y pone un wrapper que convierte
--    excepciones no capturadas en FAILED persistente en vez de tumbar workers.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.erp_x_qa_flow_execute_slice_v10257_core(uuid)') is null then
    if to_regprocedure('public.erp_x_qa_flow_execute_slice(uuid)') is null then
      raise exception 'No existe erp_x_qa_flow_execute_slice(uuid) para instalar V10.25.8';
    end if;
    execute 'alter function public.erp_x_qa_flow_execute_slice(uuid) rename to erp_x_qa_flow_execute_slice_v10257_core';
  end if;
end
$$;

revoke all on function public.erp_x_qa_flow_execute_slice_v10257_core(uuid) from public,anon,authenticated;

create or replace function public.erp_x_qa_flow_execute_slice(p_case_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_super uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_case erp_supply.qa_deep_cases%rowtype;
  v_state erp_supply.qa_flow_case_state%rowtype;
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_result jsonb;
  v_purpose text;
  v_step text;
  v_module text;
  v_expected_role text;
  v_actual_role text;
  v_error_state text;
  v_error_message text;
  v_cleanup_ok boolean:=true;
  v_cleanup_error text;
  v_step_index integer;
begin
  select c.* into v_case
  from erp_supply.qa_deep_cases c
  join erp_supply.qa_runs r on r.id=c.qa_run_id
  where c.id=p_case_id
    and c.family='FLOW_ORDER'
    and r.organization_id=v_org
    and r.run_type='TOTAL_ROBOT';
  if not found then raise exception 'Caso de certificación de flujo no disponible'; end if;

  select summary->>'qaPurpose' into v_purpose
  from erp_supply.qa_runs where id=v_case.qa_run_id;

  begin
    v_result:=public.erp_x_qa_flow_execute_slice_v10257_core(p_case_id);

    -- Cierra automáticamente la corrida de un solo pedido canario.
    if v_purpose='ORDER_FLOW_CANARY'
       and coalesce(erp_supply.safe_boolean(v_result->>'completed',false),false) then
      update erp_supply.qa_runs
      set status=case when v_result->>'status'='PASSED' then 'PASSED' else 'FAILED' end,
          total_scenarios=1,
          passed_scenarios=case when v_result->>'status'='PASSED' then 1 else 0 end,
          failed_scenarios=case when v_result->>'status'='FAILED' then 1 else 0 end,
          completed_at=now(),
          summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
            'qaPurpose','ORDER_FLOW_CANARY',
            'canary',jsonb_build_object(
              'status',v_result->>'status',
              'caseId',p_case_id,
              'version','10.25.8',
              'finishedAt',now()
            )
          )
      where id=v_case.qa_run_id;
    end if;

    return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('version','10.25.8');

  exception when others then
    v_error_state:=sqlstate;
    v_error_message:=sqlerrm;

    select * into v_state
    from erp_supply.qa_flow_case_state
    where case_id=p_case_id;

    if found then
      select * into v_order
      from erp_supply.orders
      where id=v_state.order_id;
    end if;

    v_step:=coalesce(v_order.current_step_code,v_state.current_step,'UNKNOWN');
    v_step_index:=coalesce(v_state.steps_executed,0)+1;

    select module_code into v_module
    from erp_supply.workflow_steps
    where code=v_step;

    if v_order.id is not null then
      select * into v_task
      from erp_supply.order_tasks
      where order_id=v_order.id
        and step_code=v_step
        and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      order by sequence_no desc
      limit 1;

      v_actual_role:=v_task.assigned_role_code;
      select role_code into v_expected_role
      from erp_supply.resolve_assignment(
        v_order.organization_id,
        v_step,
        v_order.delivery_route_code,
        v_order.order_type_code
      );
    end if;

    -- Registrar el fallo antes de limpiar para no perder evidencia.
    insert into erp_supply.qa_flow_step_audit(
      case_id,qa_run_id,order_id,order_number,step_index,step_code,module_code,
      expected_role_code,actual_role_code,expected_next_step,actual_next_step,
      before_status,after_status,permissions,actions,status,error_sqlstate,error_message,duration_ms
    ) values(
      v_case.id,v_case.qa_run_id,v_state.order_id,v_state.order_number,v_step_index,v_step,v_module,
      v_expected_role,v_actual_role,
      case when v_state.expected_path is not null then v_state.expected_path->>v_step_index else null end,
      v_order.current_step_code,
      v_order.status,v_order.status,
      jsonb_build_object('capturedBy','FLOW_SLICE_WRAPPER_10.25.8'),
      '[]'::jsonb,
      'FAILED',v_error_state,v_error_message,0
    )
    on conflict(case_id,step_index) do update set
      module_code=excluded.module_code,
      expected_role_code=excluded.expected_role_code,
      actual_role_code=excluded.actual_role_code,
      actual_next_step=excluded.actual_next_step,
      permissions=excluded.permissions,
      status='FAILED',
      error_sqlstate=excluded.error_sqlstate,
      error_message=excluded.error_message,
      captured_at=now();

    begin
      if v_state.order_id is not null
         and exists(select 1 from erp_supply.orders where id=v_state.order_id) then
        perform public.erp_x_sandbox_delete(v_state.order_id);
      end if;
    exception when others then
      v_cleanup_ok:=false;
      v_cleanup_error:=sqlstate||' · '||sqlerrm;
    end;

    update erp_supply.qa_flow_case_state
    set status='FAILED',
        last_error=v_error_state||' · '||v_error_message,
        completed_at=now(),
        updated_at=now()
    where case_id=p_case_id;

    update erp_supply.qa_deep_cases
    set status='FAILED',
        error_sqlstate=v_error_state,
        error_message=v_error_message,
        cleanup_verified=v_cleanup_ok,
        result=jsonb_build_object(
          'flowCertified',false,
          'failedStep',v_step,
          'module',v_module,
          'expectedRole',v_expected_role,
          'actualRole',v_actual_role,
          'wrapperCaptured',true,
          'cleanupVerified',v_cleanup_ok,
          'cleanupError',v_cleanup_error,
          'version','10.25.8'
        ),
        completed_at=now()
    where id=p_case_id;

    if v_purpose='ORDER_FLOW_CANARY' then
      update erp_supply.qa_runs
      set status='FAILED',
          total_scenarios=1,
          passed_scenarios=0,
          failed_scenarios=1,
          completed_at=now(),
          summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
            'qaPurpose','ORDER_FLOW_CANARY',
            'canary',jsonb_build_object(
              'status','FAILED',
              'caseId',p_case_id,
              'failedStep',v_step,
              'errorSqlstate',v_error_state,
              'errorMessage',v_error_message,
              'version','10.25.8',
              'finishedAt',now()
            )
          )
      where id=v_case.qa_run_id;
    end if;

    -- IMPORTANTE: devolver FAILED, no relanzar. El worker continúa con el siguiente.
    return jsonb_build_object(
      'caseId',v_case.id,
      'caseKey',v_case.case_key,
      'status','FAILED',
      'completed',true,
      'failedStep',v_step,
      'module',v_module,
      'expectedRole',v_expected_role,
      'actualRole',v_actual_role,
      'errorSqlstate',v_error_state,
      'errorMessage',v_error_message,
      'cleanupVerified',v_cleanup_ok,
      'version','10.25.8'
    );
  end;
end;
$$;

revoke all on function public.erp_x_qa_flow_execute_slice(uuid) from public,anon;
grant execute on function public.erp_x_qa_flow_execute_slice(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Canary: un pedido representativo que reproduce la ruta que llegó a CLOSURE
--    en la corrida real del usuario. Debe llegar a CLOSED antes de lanzar 336.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_flow_create_canary()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_run uuid;
  v_case uuid;
  v_key text:='CANARY-PVC-MORA-CASH-CLIENT_PICKUP-CUT_f-BUY_f';
begin
  insert into erp_supply.qa_runs(
    organization_id,run_type,status,requested_by,total_scenarios,summary
  ) values(
    v_org,'TOTAL_ROBOT','RUNNING',v_actor,1,
    jsonb_build_object(
      'qaPurpose','ORDER_FLOW_CANARY',
      'qaRobotVersion','10.25.8',
      'productionIsolation',true,
      'startedFrom','SUPER_ADMIN_FLOW_CANARY'
    )
  ) returning id into v_run;

  insert into erp_supply.qa_deep_cases(
    qa_run_id,case_key,campaign_mode,family,specification,status
  ) values(
    v_run,v_key,'TOTAL','FLOW_ORDER',
    jsonb_build_object(
      'baseCombination','PVC-MORA-CASH-CLIENT_PICKUP-CUT_f-BUY_f',
      'orderType','PVC',
      'paymentCondition','CASH',
      'deliveryRoute','CLIENT_PICKUP',
      'requiresCut',false,
      'requiresPurchase',false,
      'hasCreditArrears',true,
      'heldByCashier',false,
      'canary',true
    ),
    'PENDING'
  ) returning id into v_case;

  return jsonb_build_object(
    'success',true,
    'runId',v_run,
    'caseId',v_case,
    'caseKey',v_key,
    'expectedPurpose','ORDER_FLOW_CANARY',
    'version','10.25.8'
  );
end;
$$;

revoke all on function public.erp_x_qa_flow_create_canary() from public,anon;
grant execute on function public.erp_x_qa_flow_create_canary() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Contrato técnico sin requerir ejecutarlo desde SQL Editor.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_flow_v10258_contract()
returns jsonb
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select jsonb_build_object(
    'success',
      erp_supply.default_role_for_step('CLOSURE','CLIENT_PICKUP')='coordinador_logistico'
      and erp_supply.default_role_for_step('CLOSURE','NATIONAL_DISPATCH')='despacho_nacional'
      and position('inheritedDispatchRole' in pg_get_functiondef('public.erp_x_shipping_send_to_closure(uuid,jsonb)'::regprocedure))>0
      and to_regprocedure('public.erp_x_qa_flow_execute_slice_v10257_core(uuid)') is not null
      and position('wrapperCaptured' in pg_get_functiondef('public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure))>0
      and to_regprocedure('public.erp_x_qa_flow_create_canary()') is not null,
    'checks',jsonb_build_array(
      jsonb_build_object('key','CLOSURE_LOCAL_ROLE','value',erp_supply.default_role_for_step('CLOSURE','CLIENT_PICKUP')),
      jsonb_build_object('key','CLOSURE_NATIONAL_ROLE','value',erp_supply.default_role_for_step('CLOSURE','NATIONAL_DISPATCH')),
      jsonb_build_object('key','SHIPPING_INHERITS_ROLE','success',position('inheritedDispatchRole' in pg_get_functiondef('public.erp_x_shipping_send_to_closure(uuid,jsonb)'::regprocedure))>0),
      jsonb_build_object('key','SLICE_WRAPPER','success',position('wrapperCaptured' in pg_get_functiondef('public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure))>0),
      jsonb_build_object('key','CANARY_RPC','success',to_regprocedure('public.erp_x_qa_flow_create_canary()') is not null)
    ),
    'version','10.25.8'
  )
$$;

revoke all on function public.erp_x_qa_flow_v10258_contract() from public,anon;
grant execute on function public.erp_x_qa_flow_v10258_contract() to authenticated;

notify pgrst,'reload schema';
commit;
