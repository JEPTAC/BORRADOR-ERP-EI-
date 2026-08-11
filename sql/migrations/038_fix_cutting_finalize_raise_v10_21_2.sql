-- ERP EI V10.21.2
-- Corrección del cierre de Corte: elimina el manejador RAISE nullable del 037.
-- Mantiene la firma pública public.erp_x_cutting_finalize(uuid).
-- Base requerida: migración 036 aplicada. Puede ejecutarse aunque 037 ya esté aplicado.

begin;

create or replace function public.erp_x_cutting_finalize(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.cut_executions%rowtype;
  v_metrics jsonb;
  v_order_id uuid;
  v_order erp_supply.orders%rowtype;
  v_cutflow jsonb;
  v_roles text[];
  v_role text;
  v_pending integer:=0;
begin
  -- 1. Cargar y bloquear la ejecución.
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id
    and organization_id=erp_supply.current_org_id()
  for update;

  if not found then
    raise exception 'Ejecución de Corte no disponible';
  end if;

  v_roles:=erp_supply.current_roles();
  v_role:=coalesce(v_roles[1],'auxiliar_corte');

  if v_exec.started_by<>v_actor
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El corte está asignado a otro usuario' using errcode='42501';
  end if;

  -- Cierre idempotente.
  if v_exec.status='COMPLETED' then
    return jsonb_build_object(
      'success',true,
      'executionId',v_exec.id,
      'alreadyCompleted',true,
      'metrics',coalesce(erp_supply.cut_execution_metrics(v_exec.id),'{}'::jsonb),
      'finalizeVersion','10.21.2'
    );
  end if;

  -- 2. La evidencia es un gate real de cierre.
  if v_exec.evidence_file_id is null then
    raise exception 'Debes subir la foto final del material cortado antes de cerrar Corte';
  end if;

  if not exists(
    select 1
    from erp_supply.drive_files f
    where f.id=v_exec.evidence_file_id
      and f.organization_id=v_exec.organization_id
      and f.file_category='CUTTING_EVIDENCE'
  ) then
    raise exception 'La evidencia final registrada ya no está disponible o no corresponde a Corte';
  end if;

  -- 3. Ninguna línea congelada puede quedar físicamente incompleta.
  select count(*) into v_pending
  from erp_supply.cut_execution_requirements er
  join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
  where er.execution_id=v_exec.id
    and coalesce(r.length_completed,0)<r.total_length-0.0001;

  if v_pending>0 then
    raise exception 'Todavía faltan % requerimiento(s) de corte físico por completar',v_pending;
  end if;

  -- 4. Cerrar cualquier pausa abierta antes de calcular métricas.
  update erp_supply.cut_execution_pauses
  set ended_at=coalesce(ended_at,now()),
      ended_by=coalesce(ended_by,v_actor),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'closedByFinalize',true,
        'closedAt',now(),
        'finalizeVersion','10.21.2'
      )
  where execution_id=v_exec.id
    and ended_at is null;

  -- 5. Solo aquí los requerimientos pasan a READY para Alistamiento.
  update erp_supply.cut_requirements r
  set process_status='READY',
      ready_at=coalesce(r.ready_at,now()),
      ready_by=coalesce(r.ready_by,v_actor),
      collection_status=case when r.collection_status='COLLECTED' then 'COLLECTED' else 'PENDING' end,
      metadata=coalesce(r.metadata,'{}'::jsonb)||jsonb_build_object(
        'physicalComplete',true,
        'evidencePending',false,
        'evidenceClosed',true,
        'evidenceFileId',v_exec.evidence_file_id,
        'executionId',v_exec.id,
        'cutClosedAt',now(),
        'cutFlowVersion','10.21.2'
      ),
      updated_at=now()
  where exists(
    select 1
    from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id
      and er.cut_requirement_id=r.id
  );

  update erp_supply.order_items i
  set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
        'cutStatus','READY',
        'sandboxCutStatus',case when coalesce(i.metadata->>'sandbox','false')='true' then 'READY' else coalesce(i.metadata->>'sandboxCutStatus','READY') end,
        'cutExecutionId',v_exec.id,
        'cutEvidenceFileId',v_exec.evidence_file_id,
        'cutEvidencePending',false,
        'cutReadyAt',now(),
        'cutFlowVersion','10.21.2'
      ),
      updated_at=now()
  where i.requires_cut
    and exists(
      select 1
      from erp_supply.cut_execution_requirements er
      where er.execution_id=v_exec.id
        and er.order_item_id=i.id
    );

  -- 6. Cierre formal de la ejecución.
  update erp_supply.cut_executions
  set status='COMPLETED',
      completed_by=v_actor,
      completed_at=coalesce(completed_at,now()),
      updated_at=now()
  where id=v_exec.id
  returning * into v_exec;

  v_metrics:=coalesce(erp_supply.cut_execution_metrics(v_exec.id),'{}'::jsonb);

  update erp_supply.cut_executions
  set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'finalMetrics',v_metrics,
        'closedWithEvidence',true,
        'finalizeVersion','10.21.2',
        'finalizedAt',now()
      ),
      updated_at=now()
  where id=v_exec.id;

  -- 7. Actualizar cada pedido congelado por esta ejecución.
  for v_order_id in
    select distinct er.order_id
    from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id
  loop
    select * into v_order
    from erp_supply.orders
    where id=v_order_id
    for update;

    if not found then
      continue;
    end if;

    -- Si ya no quedan cortes físicos pendientes del pedido, su subflujo de
    -- Corte queda formalmente cerrado y listo para recogida.
    if not exists(
      select 1
      from erp_supply.cut_requirements r
      where r.order_id=v_order_id
        and r.process_status<>'READY'
    ) then
      v_cutflow:=case
        when jsonb_typeof(coalesce(v_order.metadata,'{}'::jsonb)->'cutFlow')='object'
          then coalesce(v_order.metadata,'{}'::jsonb)->'cutFlow'
        else '{}'::jsonb
      end;

      v_cutflow:=(coalesce(v_cutflow,'{}'::jsonb)-'waitingEvidence')||jsonb_build_object(
        'completedAt',now(),
        'completedBy',v_actor,
        'parallel',true,
        'waitingEvidence',false,
        'pendingCollection',(
          select count(*)
          from erp_supply.cut_requirements r
          where r.order_id=v_order_id
            and r.process_status='READY'
            and r.collection_status='PENDING'
        ),
        'cutExecutionId',v_exec.id,
        'evidenceFileId',v_exec.evidence_file_id,
        'executionCompletedAt',v_exec.completed_at,
        'executionMetrics',v_metrics,
        'version','10.21.2'
      );

      update erp_supply.orders
      set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('cutFlow',v_cutflow),
          version=coalesce(version,0)+1,
          updated_at=now()
      where id=v_order_id;
    end if;

    -- Idempotencia del evento de cierre por ejecución/pedido.
    if not exists(
      select 1
      from erp_supply.order_events e
      where e.order_id=v_order_id
        and e.action_code='CUT_EXECUTION_COMPLETED'
        and e.payload->>'executionId'=v_exec.id::text
    ) then
      insert into erp_supply.order_events(
        organization_id,order_id,event_type,action_code,
        from_step_code,to_step_code,actor_profile_id,actor_role_code,payload
      ) values(
        v_exec.organization_id,
        v_order_id,
        'DOMAIN_RECORD',
        'CUT_EXECUTION_COMPLETED',
        'ALISTAMIENTO',
        'ALISTAMIENTO',
        v_actor,
        v_role,
        jsonb_build_object(
          'executionId',v_exec.id,
          'groupKey',v_exec.group_key,
          'reference',v_exec.reference,
          'evidenceFileId',v_exec.evidence_file_id,
          'metrics',v_metrics,
          'finalizeVersion','10.21.2'
        )
      );
    end if;
  end loop;

  return jsonb_build_object(
    'success',true,
    'executionId',v_exec.id,
    'completedAt',v_exec.completed_at,
    'metrics',v_metrics,
    'releasedToPicking',true,
    'finalizeVersion','10.21.2'
  );
end;
$$;

revoke all on function public.erp_x_cutting_finalize(uuid) from public,anon;
grant execute on function public.erp_x_cutting_finalize(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
