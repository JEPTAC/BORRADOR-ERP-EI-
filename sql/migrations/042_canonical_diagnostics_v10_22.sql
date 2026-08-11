-- ERP EI V10.22.0
-- Consolidación canónica de diagnósticos operativos.
-- Sustituye las únicas piezas todavía dependientes del antiguo SQL raíz V10.4.

begin;

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
      'queueIntegrity',to_regprocedure('public.erp_x_queue_integrity(boolean)') is not null,
      'qaV1022',to_regprocedure('public.erp_x_run_qa_v10_22(boolean)') is not null,
      'selfCheckV1022',to_regprocedure('public.erp_x_v10_22_self_check()') is not null
    ),
    'queues',v_queue,
    'architecture',case when erp_supply.has_role('super_admin') then public.erp_x_v10_22_self_check() else null end,
    'runtimeVersion','10.22.0',
    'checkedAt',now()
  );
end;
$$;

revoke all on function public.erp_x_queue_integrity(boolean) from public,anon;
grant execute on function public.erp_x_queue_integrity(boolean) to authenticated;
revoke all on function public.erp_x_runtime_diagnostics() from public,anon;
grant execute on function public.erp_x_runtime_diagnostics() to authenticated;

notify pgrst,'reload schema';
commit;
