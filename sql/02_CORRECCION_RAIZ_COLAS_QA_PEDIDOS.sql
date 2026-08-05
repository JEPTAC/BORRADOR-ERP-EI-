-- ERP Electroingeniería V10.4
-- Corrección de raíz: colas, pruebas QA y creación de pedidos.
-- Ejecutar una sola vez en Supabase SQL Editor.
-- ============================================================

begin;

-- ------------------------------------------------------------
-- 1. Historial QA: corrige el ORDER BY sobre alias inexistente.
-- ------------------------------------------------------------
create or replace function public.erp_x_qa_runs(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
begin
  perform erp_supply.require_profile();

  if not (
    erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('auditoria')
  ) then
    raise exception 'No autorizado para consultar las pruebas'
      using errcode='42501';
  end if;

  return (
    select coalesce(
      jsonb_agg(to_jsonb(x) order by x."startedAt" desc),
      '[]'::jsonb
    )
    from (
      select
        q.id,
        q.run_type as "runType",
        q.status,
        q.total_scenarios as "totalScenarios",
        q.passed_scenarios as "passedScenarios",
        q.failed_scenarios as "failedScenarios",
        q.started_at as "startedAt",
        q.completed_at as "completedAt",
        q.summary
      from erp_supply.qa_runs q
      where q.organization_id=v_org
      order by q.started_at desc
      limit least(greatest(coalesce(p_limit,20),1),100)
    ) x
  );
end;
$$;

-- ------------------------------------------------------------
-- 2. Lotes de inventario: corrige aliases camelCase en ORDER BY.
-- ------------------------------------------------------------
create or replace function public.erp_x_inventory_lots(
  p_item_id uuid default null,
  p_search text default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
begin
  perform erp_supply.require_profile();

  if not (
    erp_supply.can_access_module('inventory','read')
    or erp_supply.can_access_module('cutting','read')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para consultar lotes'
      using errcode='42501';
  end if;

  return (
    select coalesce(
      jsonb_agg(
        to_jsonb(x)
        order by x.description,x.location,x."lotNumber"
      ),
      '[]'::jsonb
    )
    from (
      select
        l.id,
        l.inventory_item_id as "itemId",
        i.sku,
        i.reference,
        i.description,
        i.unit,
        l.lot_number as "lotNumber",
        l.serial_number as "serialNumber",
        l.location,
        l.quantity_available as "available",
        l.quantity_reserved as "reserved",
        l.quantity_blocked as "blocked",
        l.expires_at as "expiresAt"
      from erp_supply.inventory_lots l
      join erp_supply.inventory_items i
        on i.id=l.inventory_item_id
      where i.organization_id=v_org
        and i.active
        and l.quantity_available>0
        and (p_item_id is null or i.id=p_item_id)
        and (
          p_search is null
          or btrim(p_search)=''
          or lower(
            i.sku||' '||i.description||' '
            ||coalesce(i.reference,'')||' '
            ||coalesce(l.lot_number,'')||' '
            ||l.location
          ) like '%'||lower(btrim(p_search))||'%'
        )
    ) x
  );
end;
$$;

-- ------------------------------------------------------------
-- 3. Puertas del flujo: solo la matriz de rutas puede omitirlas.
--    La suite empresarial sí debe probar checklists y controles.
-- ------------------------------------------------------------
create or replace function erp_supply.validate_task_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_missing integer;
begin
  if new.status<>'COMPLETED' or old.status='COMPLETED' then
    return new;
  end if;

  select * into v_order
  from erp_supply.orders
  where id=new.order_id;

  if not found then
    raise exception 'Pedido asociado a la tarea no encontrado';
  end if;

  if v_order.is_test
     and coalesce(
       erp_supply.safe_boolean(v_order.metadata->>'bypassGates',false),
       false
     )
  then
    return new;
  end if;

  select count(*) into v_missing
  from erp_supply.task_checklist
  where task_id=new.id
    and required
    and not completed;

  if v_missing>0 then
    raise exception
      'No puede finalizar: quedan % controles obligatorios sin completar',
      v_missing;
  end if;

  case new.step_code
    when 'CARTERA' then
      if not exists(
        select 1 from erp_supply.financial_validations
        where order_id=v_order.id
          and validation_type='CARTERA'
          and decision='APPROVED'
      ) then
        raise exception 'Debe registrar una validación aprobada de Cartera';
      end if;

    when 'CAJA' then
      if not exists(
        select 1 from erp_supply.financial_validations
        where order_id=v_order.id
          and validation_type='CAJA'
          and decision='APPROVED'
      ) then
        raise exception 'Debe registrar una validación aprobada de Caja';
      end if;

    when 'COMPRAS' then
      if not exists(
        select 1 from erp_supply.purchase_orders
        where order_id=v_order.id
          and status in('ISSUED','CONFIRMED','PARTIAL','RECEIVED')
      ) then
        raise exception 'Debe registrar una orden de compra válida';
      end if;

    when 'RECEPCION_MERCANCIA' then
      if not exists(
        select 1 from erp_supply.receipts
        where order_id=v_order.id
          and status in('PARTIAL','CONFORMING','CLOSED')
      ) then
        raise exception 'Debe registrar la recepción física y su resultado de calidad';
      end if;

    when 'CORTE' then
      if v_order.requires_cut and not exists(
        select 1 from erp_supply.cut_jobs
        where order_id=v_order.id
          and status='COMPLETED'
      ) then
        raise exception 'Debe registrar al menos un corte completado';
      end if;

    when 'FACTURACION' then
      if not exists(
        select 1 from erp_supply.invoices
        where order_id=v_order.id
          and status='REGISTERED'
      ) then
        raise exception 'Debe registrar la factura antes de liberar el pedido';
      end if;

    when 'CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH' then
      if not exists(
        select 1 from erp_supply.deliveries
        where order_id=v_order.id
          and status='DELIVERED'
      ) then
        raise exception 'Debe confirmar la entrega';
      end if;

    when 'NATIONAL_DISPATCH' then
      if not exists(
        select 1 from erp_supply.deliveries
        where order_id=v_order.id
          and status='DELIVERED'
      ) then
        raise exception 'Debe confirmar la entrega nacional';
      end if;

    when 'CLOSURE' then
      if not exists(
        select 1 from erp_supply.invoices
        where order_id=v_order.id
      ) then
        raise exception 'El pedido no tiene factura registrada';
      end if;
      if not exists(
        select 1 from erp_supply.deliveries
        where order_id=v_order.id
          and status='DELIVERED'
      ) then
        raise exception 'El pedido no tiene entrega confirmada';
      end if;

    else
      null;
  end case;

  return new;
end;
$$;

-- ------------------------------------------------------------
-- 4. Matriz QA: marca explícitamente sus pedidos para omitir
--    puertas documentales y probar solamente las 192 rutas.
-- ------------------------------------------------------------
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
  v_type text;
  v_payment text;
  v_route text;
  v_cut boolean;
  v_purchase boolean;
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
    raise exception 'El bot QA solo puede ser ejecutado por Super Admin'
      using errcode='42501';
  end if;

  insert into erp_supply.qa_runs(
    organization_id,run_type,requested_by,total_scenarios,summary
  ) values(
    v_org,'MATRIX',v_actor,192,
    jsonb_build_object('suite','commercial-matrix')
  ) returning * into v_run;

  foreach v_type in array array['PVC','PVN','PVE','PVP'] loop
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array[
        'CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'
      ] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_total:=v_total+1;
            v_error:=null;
            v_actual:='[]'::jsonb;
            v_order:=null;

            v_key:=format(
              '%s-%s-%s-CUT_%s-BUY_%s',
              v_type,v_payment,v_route,v_cut,v_purchase
            );

            v_initial:=erp_supply.initial_step(
              v_type,v_payment,v_purchase or v_type='PVE'
            );
            v_expected:=jsonb_build_array(v_initial);
            v_step:=v_initial;
            v_guard:=0;

            while v_step<>'CLOSED' and v_guard<20 loop
              v_step:=erp_supply.next_step(
                v_step,v_type,v_payment,v_route,v_cut,
                v_purchase or v_type='PVE'
              );
              v_expected:=v_expected||jsonb_build_array(v_step);
              v_guard:=v_guard+1;
            end loop;

            insert into erp_supply.qa_scenarios(
              qa_run_id,scenario_key,input,expected_path
            ) values(
              v_run.id,
              v_key,
              jsonb_build_object(
                'orderType',v_type,
                'payment',v_payment,
                'route',v_route,
                'requiresCut',v_cut,
                'requiresPurchase',v_purchase
              ),
              v_expected
            ) returning * into v_scenario;

            begin
              insert into erp_supply.orders(
                organization_id,order_number,order_type_code,
                payment_condition_code,delivery_route_code,client_name,
                seller_profile_id,current_step_code,status,requires_cut,
                requires_purchase,source,is_test,qa_run_id,metadata
              ) values(
                v_org,
                'QA-'||replace(v_run.id::text,'-','')||'-'||lpad(v_total::text,3,'0'),
                v_type,v_payment,v_route,'Cliente QA '||v_key,
                v_actor,v_initial,'QUEUED',v_cut,
                v_purchase or v_type='PVE','QA_BOT',true,v_run.id,
                jsonb_build_object(
                  'scenario',v_key,
                  'bypassGates',true
                )
              ) returning * into v_order;

              insert into erp_supply.order_items(
                order_id,line_number,sku,description,quantity,unit,
                requires_cut,requested_cut_length
              ) values(
                v_order.id,1,'QA-'||v_type,
                'Material de prueba automatizada',1,'UND',v_cut,
                case when v_cut then 10 else null end
              );

              select * into v_task
              from erp_supply.create_task(v_order,v_initial,1);

              v_actual:=jsonb_build_array(v_initial);
              v_guard:=0;

              loop
                select * into v_order
                from erp_supply.orders
                where id=v_order.id;

                exit when v_order.status='CLOSED' or v_guard>=20;

                perform erp_supply.execute_action_internal(
                  v_order.id,'START',jsonb_build_object('detail','Inicio QA'),
                  v_actor,true,null,v_key||'-START-'||v_guard
                );
                perform erp_supply.execute_action_internal(
                  v_order.id,'COMPLETE',jsonb_build_object('detail','Finalización QA'),
                  v_actor,true,null,v_key||'-COMPLETE-'||v_guard
                );

                select * into v_order
                from erp_supply.orders
                where id=v_order.id;

                v_actual:=v_actual||jsonb_build_array(v_order.current_step_code);
                v_guard:=v_guard+1;
              end loop;

              if v_order.status='CLOSED' and v_actual=v_expected then
                update erp_supply.qa_scenarios
                set order_id=v_order.id,
                    actual_path=v_actual,
                    status='PASSED',
                    completed_at=now()
                where id=v_scenario.id;
                v_passed:=v_passed+1;
              else
                v_error:=format(
                  'Estado final %s; paso %s; ruta esperada %s; ruta real %s',
                  v_order.status,v_order.current_step_code,v_expected,v_actual
                );
                update erp_supply.qa_scenarios
                set order_id=v_order.id,
                    actual_path=v_actual,
                    status='FAILED',
                    error_message=v_error,
                    completed_at=now()
                where id=v_scenario.id;
                v_failed:=v_failed+1;
              end if;

            exception when others then
              v_error:=sqlstate||' - '||sqlerrm;
              update erp_supply.qa_scenarios
              set order_id=case when v_order.id is null then null else v_order.id end,
                  actual_path=coalesce(v_actual,'[]'::jsonb),
                  status='FAILED',
                  error_message=v_error,
                  completed_at=now()
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
      summary=jsonb_build_object(
        'matrix','4 tipos × 3 pagos × 4 rutas × 2 corte × 2 compra',
        'cleanup',p_cleanup
      )
  where id=v_run.id
  returning * into v_run;

  if p_cleanup then
    delete from erp_supply.orders
    where qa_run_id=v_run.id;
  end if;

  return jsonb_build_object(
    'runId',v_run.id,
    'status',v_run.status,
    'total',v_total,
    'passed',v_passed,
    'failed',v_failed,
    'completedAt',v_run.completed_at
  );
end;
$$;

-- ------------------------------------------------------------
-- 5. Integridad de colas: detecta y, opcionalmente, repara
--    pedidos activos sin tarea o desalineados con la tarea activa.
-- ------------------------------------------------------------
create or replace function public.erp_x_queue_integrity(p_apply boolean default false)
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
  v_sequence integer;
  v_repaired integer:=0;
  v_issues jsonb;
  v_active bigint;
  v_missing bigint;
  v_mismatch bigint;
begin
  if not (
    erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('auditoria')
  ) then
    raise exception 'No autorizado para verificar las colas'
      using errcode='42501';
  end if;

  if p_apply and not erp_supply.has_role('super_admin') then
    raise exception 'Solo Super Admin puede reparar las colas'
      using errcode='42501';
  end if;

  if p_apply then
    for v_order in
      select o.*
      from erp_supply.orders o
      where o.organization_id=v_org
        and not o.is_history
        and not o.is_test
        and o.status not in('DRAFT','CLOSED','CANCELLED')
        and not exists(
          select 1
          from erp_supply.order_tasks t
          where t.order_id=o.id
            and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
        )
      order by o.created_at
      for update
    loop
      select coalesce(max(sequence_no),0)+1
      into v_sequence
      from erp_supply.order_tasks
      where order_id=v_order.id;

      perform erp_supply.create_task(
        v_order,v_order.current_step_code,v_sequence
      );
      v_repaired:=v_repaired+1;
    end loop;

    for v_order in
      select o.*
      from erp_supply.orders o
      where o.organization_id=v_org
        and not o.is_history
        and not o.is_test
        and o.status not in('DRAFT','CLOSED','CANCELLED')
      order by o.created_at
      for update
    loop
      select * into v_task
      from erp_supply.order_tasks t
      where t.order_id=v_order.id
        and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      order by t.sequence_no desc
      limit 1;

      if found and (
        v_order.current_step_code is distinct from v_task.step_code
        or v_order.status is distinct from v_task.status
        or v_order.current_assignee_id is distinct from v_task.assigned_profile_id
        or v_order.current_role_code is distinct from v_task.assigned_role_code
      ) then
        update erp_supply.orders
        set current_step_code=v_task.step_code,
            status=v_task.status,
            current_assignee_id=v_task.assigned_profile_id,
            current_role_code=v_task.assigned_role_code,
            version=version+1
        where id=v_order.id;
        v_repaired:=v_repaired+1;
      end if;
    end loop;
  end if;

  select count(*) into v_active
  from erp_supply.orders o
  where o.organization_id=v_org
    and not o.is_history
    and not o.is_test
    and o.status not in('DRAFT','CLOSED','CANCELLED');

  select count(*) into v_missing
  from erp_supply.orders o
  where o.organization_id=v_org
    and not o.is_history
    and not o.is_test
    and o.status not in('DRAFT','CLOSED','CANCELLED')
    and not exists(
      select 1
      from erp_supply.order_tasks t
      where t.order_id=o.id
        and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    );

  select count(*) into v_mismatch
  from erp_supply.orders o
  join lateral (
    select t.*
    from erp_supply.order_tasks t
    where t.order_id=o.id
      and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    order by t.sequence_no desc
    limit 1
  ) t on true
  where o.organization_id=v_org
    and not o.is_history
    and not o.is_test
    and o.status not in('DRAFT','CLOSED','CANCELLED')
    and (
      o.current_step_code is distinct from t.step_code
      or o.status is distinct from t.status
      or o.current_assignee_id is distinct from t.assigned_profile_id
      or o.current_role_code is distinct from t.assigned_role_code
    );

  select coalesce(jsonb_agg(to_jsonb(i) order by i."orderNumber"),'[]'::jsonb)
  into v_issues
  from (
    select
      o.id as "orderId",
      o.order_number as "orderNumber",
      'Pedido activo sin tarea operativa'::text as issue,
      o.current_step_code as "orderStep",
      null::text as "taskStep"
    from erp_supply.orders o
    where o.organization_id=v_org
      and not o.is_history
      and not o.is_test
      and o.status not in('DRAFT','CLOSED','CANCELLED')
      and not exists(
        select 1
        from erp_supply.order_tasks t
        where t.order_id=o.id
          and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      )

    union all

    select
      o.id as "orderId",
      o.order_number as "orderNumber",
      'Pedido y tarea activa están desalineados'::text as issue,
      o.current_step_code as "orderStep",
      t.step_code as "taskStep"
    from erp_supply.orders o
    join lateral (
      select at.*
      from erp_supply.order_tasks at
      where at.order_id=o.id
        and at.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      order by at.sequence_no desc
      limit 1
    ) t on true
    where o.organization_id=v_org
      and not o.is_history
      and not o.is_test
      and o.status not in('DRAFT','CLOSED','CANCELLED')
      and (
        o.current_step_code is distinct from t.step_code
        or o.status is distinct from t.status
        or o.current_assignee_id is distinct from t.assigned_profile_id
        or o.current_role_code is distinct from t.assigned_role_code
      )
  ) i;

  return jsonb_build_object(
    'ok',v_missing=0 and v_mismatch=0,
    'applied',p_apply,
    'repaired',v_repaired,
    'activeOrders',v_active,
    'missingTaskCount',v_missing,
    'mismatchCount',v_mismatch,
    'issues',v_issues,
    'checkedAt',now(),
    'checkedBy',v_actor
  );
end;
$$;

-- ------------------------------------------------------------
-- 6. Diagnóstico de ejecución real para el módulo QA.
-- ------------------------------------------------------------
create or replace function public.erp_x_runtime_diagnostics()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_profile uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_roles text[]:=erp_supply.current_roles();
  v_queue jsonb;
begin
  v_queue:=public.erp_x_queue_integrity(false);

  return jsonb_build_object(
    'profileId',v_profile,
    'organizationId',v_org,
    'roles',v_roles,
    'canCreateOrders',
      erp_supply.has_role('super_admin')
      or erp_supply.can_access_module('orders','create')
      or erp_supply.can_access_module('sales','create'),
    'canRunQa',erp_supply.has_role('super_admin'),
    'catalogs',jsonb_build_object(
      'orderTypes',(select count(*) from erp_supply.order_types where active),
      'payments',(select count(*) from erp_supply.payment_conditions where active),
      'routes',(select count(*) from erp_supply.delivery_routes where active),
      'steps',(select count(*) from erp_supply.workflow_steps where active)
    ),
    'functions',jsonb_build_object(
      'createOrder',to_regprocedure('public.erp_x_create_order(jsonb,text)') is not null,
      'qaRuns',to_regprocedure('public.erp_x_qa_runs(integer)') is not null,
      'qaMatrix',to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null,
      'queueIntegrity',to_regprocedure('public.erp_x_queue_integrity(boolean)') is not null
    ),
    'queues',v_queue,
    'checkedAt',now()
  );
end;
$$;

-- ------------------------------------------------------------
-- 7. Creación de pedido: Super Admin no depende de una fila de
--    permisos incompleta y las validaciones retornan mensajes claros.
-- ------------------------------------------------------------
create or replace function public.erp_x_create_order(
  p_payload jsonb,
  p_idempotency_key text default null
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
  v_item jsonb;
  v_items jsonb;
  v_initial text;
  v_number text;
  v_order_type text;
  v_payment text;
  v_route text;
  v_client text;
  v_priority text;
  v_requires_purchase boolean;
  v_requires_cut boolean;
  v_item_cut boolean;
  v_quantity numeric;
  v_cut_length numeric;
  v_requested_date date;
  v_promised_at timestamptz;
  v_line integer:=0;
  v_key text:=nullif(btrim(p_idempotency_key),'');
begin
  if not (
    erp_supply.has_role('super_admin')
    or erp_supply.can_access_module('orders','create')
    or erp_supply.can_access_module('sales','create')
  ) then
    raise exception 'Rol no autorizado para crear pedidos'
      using errcode='42501';
  end if;

  if p_payload is null or jsonb_typeof(p_payload)<>'object' then
    raise exception 'El pedido debe enviarse como un objeto válido';
  end if;

  v_number:=nullif(btrim(p_payload->>'orderNumber'),'');
  v_order_type:=upper(nullif(btrim(p_payload->>'orderType'),''));
  v_payment:=upper(nullif(btrim(p_payload->>'paymentCondition'),''));
  v_route:=upper(nullif(btrim(p_payload->>'deliveryRoute'),''));
  v_client:=nullif(btrim(p_payload->>'clientName'),'');
  v_priority:=upper(coalesce(nullif(btrim(p_payload->>'priority'),''),'MEDIUM'));
  v_requested_date:=erp_supply.safe_date(p_payload->>'requestedDeliveryDate');
  v_promised_at:=erp_supply.safe_timestamptz(p_payload->>'promisedAt');
  v_items:=coalesce(p_payload->'items','[]'::jsonb);

  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_order_type and active) then
    raise exception 'Tipo de pedido inválido: %',coalesce(v_order_type,'vacío');
  end if;
  if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then
    raise exception 'Condición de pago inválida: %',coalesce(v_payment,'vacía');
  end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then
    raise exception 'Modalidad de entrega inválida: %',coalesce(v_route,'vacía');
  end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then
    raise exception 'Prioridad inválida';
  end if;
  if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)=0 then
    raise exception 'El pedido debe contener al menos un material';
  end if;
  if (p_payload ? 'requestedDeliveryDate')
     and nullif(btrim(p_payload->>'requestedDeliveryDate'),'') is not null
     and v_requested_date is null
  then
    raise exception 'Fecha solicitada inválida';
  end if;
  if (p_payload ? 'promisedAt')
     and nullif(btrim(p_payload->>'promisedAt'),'') is not null
     and v_promised_at is null
  then
    raise exception 'Fecha prometida inválida';
  end if;

  if v_key is not null and exists(
    select 1
    from erp_supply.order_events
    where organization_id=v_org
      and idempotency_key=v_key
  ) then
    select o.* into v_order
    from erp_supply.orders o
    join erp_supply.order_events e on e.order_id=o.id
    where e.organization_id=v_org
      and e.idempotency_key=v_key
    limit 1;

    return jsonb_build_object(
      'success',true,
      'idempotent',true,
      'orderId',v_order.id,
      'orderNumber',v_order.order_number,
      'currentStep',v_order.current_step_code,
      'status',v_order.status,
      'version',v_order.version
    );
  end if;

  v_requires_purchase:=coalesce(
    erp_supply.safe_boolean(p_payload->>'requiresPurchase',null),
    (select requires_purchase_default
     from erp_supply.order_types
     where code=v_order_type),
    false
  );
  v_requires_cut:=coalesce(
    erp_supply.safe_boolean(p_payload->>'requiresCut',false),
    false
  );

  for v_item in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_item)<>'object' then
      raise exception 'Cada material debe ser un objeto válido';
    end if;
    v_item_cut:=coalesce(
      erp_supply.safe_boolean(v_item->>'requiresCut',false),false
    );
    if v_item_cut then
      v_requires_cut:=true;
    end if;
  end loop;

  v_initial:=erp_supply.initial_step(
    v_order_type,v_payment,v_requires_purchase
  );

  if v_initial is null or not exists(
    select 1 from erp_supply.workflow_steps
    where code=v_initial and active
  ) then
    raise exception 'No existe una etapa inicial válida para esta combinación';
  end if;

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,
    payment_condition_code,delivery_route_code,client_name,client_document,
    client_city,client_address,client_phone,seller_profile_id,
    current_step_code,status,priority,requires_cut,requires_purchase,
    promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(btrim(p_payload->>'externalReference'),''),
    v_order_type,v_payment,v_route,v_client,
    nullif(btrim(p_payload->>'clientDocument'),''),
    nullif(btrim(p_payload->>'clientCity'),''),
    nullif(btrim(p_payload->>'clientAddress'),''),
    nullif(btrim(p_payload->>'clientPhone'),''),
    v_actor,v_initial,'QUEUED',v_priority,v_requires_cut,
    v_requires_purchase,v_promised_at,v_requested_date,
    case
      when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object'
        then coalesce(p_payload->'metadata','{}'::jsonb)
      else '{}'::jsonb
    end
  ) returning * into v_order;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_line:=v_line+1;
    v_quantity:=erp_supply.safe_numeric(v_item->>'quantity');
    v_item_cut:=coalesce(
      erp_supply.safe_boolean(v_item->>'requiresCut',false),false
    );
    v_cut_length:=erp_supply.safe_numeric(v_item->>'requestedCutLength');

    if nullif(btrim(v_item->>'description'),'') is null then
      raise exception 'El material % no tiene descripción',v_line;
    end if;
    if v_quantity is null or v_quantity<=0 then
      raise exception 'Cantidad inválida en el material %',v_line;
    end if;
    if v_item_cut and (v_cut_length is null or v_cut_length<=0) then
      raise exception 'Registre una longitud de corte válida en el material %',v_line;
    end if;

    insert into erp_supply.order_items(
      order_id,line_number,sku,reference,description,quantity,unit,
      warehouse_location,requires_cut,requested_cut_length,dimensions,metadata
    ) values(
      v_order.id,
      coalesce(erp_supply.safe_integer(v_item->>'lineNumber'),v_line),
      nullif(btrim(v_item->>'sku'),''),
      nullif(btrim(v_item->>'reference'),''),
      btrim(v_item->>'description'),
      v_quantity,
      coalesce(nullif(btrim(v_item->>'unit'),''),'UND'),
      nullif(btrim(v_item->>'warehouseLocation'),''),
      v_item_cut,
      v_cut_length,
      case
        when jsonb_typeof(coalesce(v_item->'dimensions','{}'::jsonb))='object'
          then coalesce(v_item->'dimensions','{}'::jsonb)
        else '{}'::jsonb
      end,
      case
        when jsonb_typeof(coalesce(v_item->'metadata','{}'::jsonb))='object'
          then coalesce(v_item->'metadata','{}'::jsonb)
        else '{}'::jsonb
      end
    );
  end loop;

  select * into v_task
  from erp_supply.create_task(v_order,v_initial,1);

  if v_task.id is null then
    raise exception 'No fue posible crear la primera tarea del pedido';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=v_order.id;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    to_step_code,to_status,actor_profile_id,actor_role_code,
    idempotency_key,payload
  ) values(
    v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',
    v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],
    v_key,p_payload
  );

  return jsonb_build_object(
    'success',true,
    'orderId',v_order.id,
    'orderNumber',v_order.order_number,
    'currentStep',v_order.current_step_code,
    'status',v_order.status,
    'version',v_order.version,
    'taskId',v_task.id,
    'assignedTo',v_order.current_assignee_id,
    'assignedRole',v_order.current_role_code
  );

exception
  when unique_violation then
    raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

-- ------------------------------------------------------------
-- 8. Permisos públicos de los RPC corregidos.
-- ------------------------------------------------------------
revoke all on function public.erp_x_qa_runs(integer)
from public,anon,authenticated;
revoke all on function public.erp_x_inventory_lots(uuid,text)
from public,anon,authenticated;
revoke all on function public.erp_x_run_qa_matrix(boolean)
from public,anon,authenticated;
revoke all on function public.erp_x_queue_integrity(boolean)
from public,anon,authenticated;
revoke all on function public.erp_x_runtime_diagnostics()
from public,anon,authenticated;
revoke all on function public.erp_x_create_order(jsonb,text)
from public,anon,authenticated;

grant execute on function public.erp_x_qa_runs(integer)
to authenticated;
grant execute on function public.erp_x_inventory_lots(uuid,text)
to authenticated;
grant execute on function public.erp_x_run_qa_matrix(boolean)
to authenticated;
grant execute on function public.erp_x_queue_integrity(boolean)
to authenticated;
grant execute on function public.erp_x_runtime_diagnostics()
to authenticated;
grant execute on function public.erp_x_create_order(jsonb,text)
to authenticated;

commit;

-- ============================================================
-- Verificación posterior. Debe devolver todos los booleanos true.
-- ============================================================
select
  to_regprocedure('public.erp_x_qa_runs(integer)') is not null
    as historial_qa_corregido,
  to_regprocedure('public.erp_x_inventory_lots(uuid,text)') is not null
    as lotes_corregidos,
  to_regprocedure('public.erp_x_queue_integrity(boolean)') is not null
    as diagnostico_colas_disponible,
  to_regprocedure('public.erp_x_runtime_diagnostics()') is not null
    as diagnostico_runtime_disponible,
  has_function_privilege(
    'authenticated','public.erp_x_create_order(jsonb,text)','EXECUTE'
  ) as crear_pedido_habilitado,
  has_function_privilege(
    'authenticated','public.erp_x_qa_runs(integer)','EXECUTE'
  ) as pruebas_habilitadas,
  not has_function_privilege(
    'anon','public.erp_x_create_order(jsonb,text)','EXECUTE'
  ) as anon_sin_creacion,
  not has_function_privilege(
    'anon','public.erp_x_qa_runs(integer)','EXECUTE'
  ) as anon_sin_pruebas;
