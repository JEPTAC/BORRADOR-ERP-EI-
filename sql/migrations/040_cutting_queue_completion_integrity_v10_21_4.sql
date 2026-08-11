begin;

-- ============================================================================
-- V10.21.4 · Integridad de salida de Corte
--
-- Objetivos:
-- 1) La lista Sandbox deja de usar order_items.metadata.sandboxCutStatus como
--    fuente de verdad. La autoridad pasa a ser cut_requirements + cut_executions.
-- 2) Mantener sandboxCutStatus únicamente como espejo de compatibilidad.
-- 3) Reparar pruebas ya finalizadas que quedaron visualmente abiertas.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. ESPEJO DE COMPATIBILIDAD: EL ESTADO REAL DE LA EJECUCIÓN MANDA
-- ---------------------------------------------------------------------------
create or replace function erp_supply.trg_sync_sandbox_cut_status_from_execution()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_status text;
begin
  if new.status not in ('IN_PROGRESS','PAUSED','WAITING_EVIDENCE','COMPLETED') then
    return new;
  end if;

  v_status:=case
    when new.status='COMPLETED' then 'READY'
    when new.status='WAITING_EVIDENCE' then 'WAITING_EVIDENCE'
    else 'IN_PROGRESS'
  end;

  update erp_supply.order_items i
  set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
        'sandboxCutStatus',v_status,
        'cutExecutionId',new.id,
        'cutFlowVersion','10.21.4',
        'sandboxCutExecutionStatus',new.status,
        'sandboxCutStatusSyncedAt',now()
      )||case when new.status='COMPLETED'
        then jsonb_build_object(
          'cutStatus','READY',
          'sandboxCutClosedAt',coalesce(new.completed_at,now())
        )
        else '{}'::jsonb
      end,
      updated_at=now()
  where exists(
    select 1
    from erp_supply.cut_execution_requirements er
    join erp_supply.orders o on o.id=er.order_id
    where er.execution_id=new.id
      and er.order_item_id=i.id
      and o.is_test
      and o.source='QA_BOT'
      and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  );

  return new;
end;
$$;

revoke all on function erp_supply.trg_sync_sandbox_cut_status_from_execution() from public;

drop trigger if exists trg_sync_sandbox_cut_status_from_execution on erp_supply.cut_executions;
create trigger trg_sync_sandbox_cut_status_from_execution
after update of status on erp_supply.cut_executions
for each row
when (old.status is distinct from new.status)
execute function erp_supply.trg_sync_sandbox_cut_status_from_execution();

-- ---------------------------------------------------------------------------
-- 2. REPARACIÓN DE EJECUCIONES SANDBOX YA CERRADAS
-- ---------------------------------------------------------------------------
update erp_supply.order_items i
set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
      'sandboxCutStatus','READY',
      'cutStatus','READY',
      'cutExecutionId',e.id,
      'sandboxCutExecutionStatus','COMPLETED',
      'sandboxCutClosedAt',coalesce(e.completed_at,now()),
      'sandboxCutStatusSyncedAt',now(),
      'cutFlowVersion','10.21.4'
    ),
    updated_at=now()
from erp_supply.cut_execution_requirements er
join erp_supply.cut_executions e on e.id=er.execution_id
join erp_supply.orders o on o.id=er.order_id
where er.order_item_id=i.id
  and e.status='COMPLETED'
  and o.is_test
  and o.source='QA_BOT'
  and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  and coalesce(i.metadata->>'sandboxCutStatus','')<>'READY';

-- También sanea cualquier línea TEST cuyo requerimiento canónico ya quedó READY.
update erp_supply.order_items i
set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
      'sandboxCutStatus','READY',
      'cutStatus','READY',
      'sandboxCutStatusSyncedAt',now(),
      'cutFlowVersion','10.21.4'
    ),
    updated_at=now()
from erp_supply.cut_requirements r
join erp_supply.orders o on o.id=r.order_id
where r.order_item_id=i.id
  and r.process_status='READY'
  and greatest(r.total_length-coalesce(r.length_completed,0),0)<=0.0001
  and o.is_test
  and o.source='QA_BOT'
  and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  and coalesce(i.metadata->>'sandboxCutStatus','')<>'READY';

-- ---------------------------------------------------------------------------
-- 3. COLA SANDBOX RECONSTRUIDA: FUENTE CANÓNICA
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_sandbox_cutting_work(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_total bigint:=0;
  v_items jsonb:='[]'::jsonb;
begin
  -- La presencia en Corte se decide exclusivamente por:
  -- A) una ejecución realmente activa, o
  -- B) requerimiento físico realmente pendiente.
  -- Nunca por sandboxCutStatus.
  with canonical as(
    select
      r.group_key,
      max(r.reference) reference,
      max(r.sku) sku,
      max(r.description) description,
      count(*)::integer item_count,
      count(distinct r.order_id)::integer order_count,
      coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0) cut_count,
      coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) total_length,
      coalesce(sum(coalesce(r.length_completed,0)),0) completed_length,
      min(r.created_at) oldest_at,
      e.id execution_id,
      e.status execution_status,
      e.started_at execution_started_at
    from erp_supply.cut_requirements r
    join erp_supply.orders o
      on o.id=r.order_id
     and o.organization_id=v_org
     and o.is_test
     and o.source='QA_BOT'
     and coalesce((o.metadata->>'manualSandbox')::boolean,false)
    left join lateral(
      select ce.id,ce.status,ce.started_at
      from erp_supply.cut_executions ce
      where ce.organization_id=v_org
        and ce.group_key=r.group_key
        and ce.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
      order by ce.started_at desc,ce.id desc
      limit 1
    ) e on true
    where r.organization_id=v_org
      and (
        e.id is not null
        or (
          r.process_status<>'READY'
          and greatest(r.total_length-coalesce(r.length_completed,0),0)>0.0001
        )
      )
      and (
        p_search is null or p_search=''
        or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||coalesce(r.description,''))
           like '%'||lower(p_search)||'%'
      )
    group by r.group_key,e.id,e.status,e.started_at
  )
  select count(*) into v_total from canonical;

  with canonical as(
    select
      r.group_key,
      max(r.reference) reference,
      max(r.sku) sku,
      max(r.description) description,
      count(*)::integer item_count,
      count(distinct r.order_id)::integer order_count,
      coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0) cut_count,
      coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) total_length,
      coalesce(sum(coalesce(r.length_completed,0)),0) completed_length,
      min(r.created_at) oldest_at,
      e.id execution_id,
      e.status execution_status,
      e.started_at execution_started_at
    from erp_supply.cut_requirements r
    join erp_supply.orders o
      on o.id=r.order_id
     and o.organization_id=v_org
     and o.is_test
     and o.source='QA_BOT'
     and coalesce((o.metadata->>'manualSandbox')::boolean,false)
    left join lateral(
      select ce.id,ce.status,ce.started_at
      from erp_supply.cut_executions ce
      where ce.organization_id=v_org
        and ce.group_key=r.group_key
        and ce.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
      order by ce.started_at desc,ce.id desc
      limit 1
    ) e on true
    where r.organization_id=v_org
      and (
        e.id is not null
        or (
          r.process_status<>'READY'
          and greatest(r.total_length-coalesce(r.length_completed,0),0)>0.0001
        )
      )
      and (
        p_search is null or p_search=''
        or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||coalesce(r.description,''))
           like '%'||lower(p_search)||'%'
      )
    group by r.group_key,e.id,e.status,e.started_at
  ), paged as(
    select *
    from canonical
    order by
      case execution_status
        when 'WAITING_EVIDENCE' then 1
        when 'IN_PROGRESS' then 2
        when 'PAUSED' then 3
        else 4
      end,
      coalesce(execution_started_at,oldest_at),
      group_key
    offset (v_page-1)*v_size
    limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'groupKey',group_key,
    'reference',reference,
    'sku',sku,
    'description',description,
    'materialMasterId',null,
    'materialVariantId',null,
    'variantLabel',null,
    'itemCount',item_count,
    'orderCount',order_count,
    'cutCount',cut_count,
    'totalLength',total_length,
    'completedLength',completed_length,
    'oldestAt',oldest_at,
    'inProgress',(execution_id is not null),
    'executionStatus',execution_status,
    'executionId',execution_id,
    'elapsedSeconds',case
      when execution_id is null then 0
      else coalesce((erp_supply.cut_execution_metrics(execution_id)->>'businessSeconds')::bigint,0)
    end
  )),'[]'::jsonb)
  into v_items
  from paged;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object(
      'page',v_page,
      'pageSize',v_size,
      'totalItems',v_total,
      'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::integer end
    ),
    'sandbox',true,
    'stateSource','cut_requirements+cut_executions',
    'version','10.21.4'
  );
end;
$$;

revoke all on function public.erp_x_sandbox_cutting_work(text,integer,integer) from public,anon;
grant execute on function public.erp_x_sandbox_cutting_work(text,integer,integer) to authenticated;

commit;
