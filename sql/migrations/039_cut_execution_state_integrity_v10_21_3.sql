-- ERP EI V10.21.3
-- Integridad estructural de Corte: unifica estado físico, evidencia y cierre.
-- Corrige específicamente ejecuciones Sandbox que quedaban en WAITING_EVIDENCE
-- sin actualizar units_completed / length_completed.
-- Base requerida: migraciones 035, 036 y hotfix 038 aplicados.

begin;

-- ---------------------------------------------------------------------------
-- 1. ESTADO CANÓNICO POR REQUERIMIENTO CONGELADO EN LA EJECUCIÓN
-- ---------------------------------------------------------------------------

create or replace function erp_supply.cut_execution_requirement_state(p_execution_id uuid)
returns table(
  requirement_id uuid,
  order_id uuid,
  order_number text,
  order_item_id uuid,
  line_number integer,
  reference text,
  description text,
  is_test boolean,
  initial_units numeric,
  initial_length numeric,
  units_required numeric,
  units_completed numeric,
  total_length numeric,
  length_completed numeric,
  resolution_code text,
  physical_complete boolean,
  pending_units numeric,
  pending_length numeric
)
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select
    r.id,
    er.order_id,
    o.order_number,
    er.order_item_id,
    i.line_number,
    coalesce(r.reference,r.sku),
    r.description,
    o.is_test,
    er.initial_units,
    er.initial_length,
    r.units_required,
    coalesce(r.units_completed,0),
    r.total_length,
    coalesce(r.length_completed,0),
    r.resolution_code,
    (
      upper(coalesce(r.resolution_code,''))='NO_CUT'
      or (
        coalesce(r.units_completed,0)>=r.units_required-0.0001
        and coalesce(r.length_completed,0)>=r.total_length-0.0001
      )
      or (
        coalesce((r.metadata->>'physicalComplete')::boolean,false)
        and r.metadata->>'executionId'=p_execution_id::text
      )
      or (
        o.is_test
        and upper(coalesce(i.metadata->>'sandboxCutStatus','')) in('WAITING_EVIDENCE','READY')
      )
    ) as physical_complete,
    case
      when upper(coalesce(r.resolution_code,''))='NO_CUT' then 0
      when coalesce((r.metadata->>'physicalComplete')::boolean,false)
        and r.metadata->>'executionId'=p_execution_id::text then 0
      when o.is_test and upper(coalesce(i.metadata->>'sandboxCutStatus','')) in('WAITING_EVIDENCE','READY') then 0
      else greatest(r.units_required-coalesce(r.units_completed,0),0)
    end as pending_units,
    case
      when upper(coalesce(r.resolution_code,''))='NO_CUT' then 0
      when coalesce((r.metadata->>'physicalComplete')::boolean,false)
        and r.metadata->>'executionId'=p_execution_id::text then 0
      when o.is_test and upper(coalesce(i.metadata->>'sandboxCutStatus','')) in('WAITING_EVIDENCE','READY') then 0
      else greatest(r.total_length-coalesce(r.length_completed,0),0)
    end as pending_length
  from erp_supply.cut_execution_requirements er
  join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
  join erp_supply.orders o on o.id=er.order_id
  join erp_supply.order_items i on i.id=er.order_item_id
  where er.execution_id=p_execution_id;
$$;
revoke all on function erp_supply.cut_execution_requirement_state(uuid) from public;

-- ---------------------------------------------------------------------------
-- 2. SINCRONIZADOR ÚNICO DEL ESTADO FÍSICO
-- ---------------------------------------------------------------------------

create or replace function erp_supply.sync_cut_execution_state(p_execution_id uuid,p_actor uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_exec erp_supply.cut_executions%rowtype;
  v_pending_count integer:=0;
  v_pending_units numeric:=0;
  v_pending_length numeric:=0;
  v_open_pause boolean:=false;
  v_complete boolean:=false;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id
  for update;

  if not found then
    raise exception 'Ejecución de Corte no disponible';
  end if;

  -- Reconciliación segura: si V10.20 ya dejó la marca physicalComplete ligada
  -- a esta ejecución, o si es un Sandbox aislado ya ejecutado, sincroniza contadores.
  update erp_supply.cut_requirements r
  set units_completed=r.units_required,
      length_completed=r.total_length,
      metadata=coalesce(r.metadata,'{}'::jsonb)||jsonb_build_object(
        'physicalComplete',true,
        'stateRepaired',true,
        'stateRepairVersion','10.21.3',
        'stateRepairedAt',now()
      ),
      updated_at=now()
  where exists(
    select 1
    from erp_supply.cut_execution_requirements er
    join erp_supply.orders o on o.id=er.order_id
    join erp_supply.order_items i on i.id=er.order_item_id
    where er.execution_id=v_exec.id
      and er.cut_requirement_id=r.id
      and (
        (
          coalesce((r.metadata->>'physicalComplete')::boolean,false)
          and r.metadata->>'executionId'=v_exec.id::text
        )
        or (
          o.is_test
          and coalesce((o.metadata->>'manualSandbox')::boolean,false)
          and upper(coalesce(i.metadata->>'sandboxCutStatus','')) in('WAITING_EVIDENCE','READY')
        )
      )
  )
  and (
    r.units_completed<r.units_required-0.0001
    or r.length_completed<r.total_length-0.0001
  );

  select
    count(*) filter(where not s.physical_complete),
    coalesce(sum(s.pending_units) filter(where not s.physical_complete),0),
    coalesce(sum(s.pending_length) filter(where not s.physical_complete),0)
  into v_pending_count,v_pending_units,v_pending_length
  from erp_supply.cut_execution_requirement_state(v_exec.id) s;

  v_complete:=v_pending_count=0;
  select exists(
    select 1 from erp_supply.cut_execution_pauses p
    where p.execution_id=v_exec.id and p.ended_at is null
  ) into v_open_pause;

  if v_exec.status not in('COMPLETED','CANCELLED') then
    if v_complete then
      -- Si el corte físico terminó, cualquier pausa abierta deja de tener sentido.
      update erp_supply.cut_execution_pauses
      set ended_at=coalesce(ended_at,now()),
          ended_by=coalesce(ended_by,p_actor),
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'autoClosedOnPhysicalComplete',true,
            'stateSyncVersion','10.21.3'
          )
      where execution_id=v_exec.id and ended_at is null;

      update erp_supply.cut_executions
      set status='WAITING_EVIDENCE',
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'physicalCompletedAt',coalesce(metadata->'physicalCompletedAt',to_jsonb(now())),
            'evidenceRequired',true,
            'pendingPhysicalRequirements',0,
            'pendingPhysicalUnits',0,
            'pendingPhysicalLength',0,
            'stateSyncVersion','10.21.3',
            'stateSyncedAt',now()
          ),
          updated_at=now()
      where id=v_exec.id;
    else
      update erp_supply.cut_executions
      set status=case when v_open_pause then 'PAUSED' else 'IN_PROGRESS' end,
          metadata=(coalesce(metadata,'{}'::jsonb)-'physicalCompletedAt')||jsonb_build_object(
            'evidenceRequired',false,
            'pendingPhysicalRequirements',v_pending_count,
            'pendingPhysicalUnits',v_pending_units,
            'pendingPhysicalLength',v_pending_length,
            'stateSyncVersion','10.21.3',
            'stateSyncedAt',now()
          ),
          updated_at=now()
      where id=v_exec.id;
    end if;
  end if;

  return jsonb_build_object(
    'executionId',v_exec.id,
    'physicalComplete',v_complete,
    'pendingRequirements',v_pending_count,
    'pendingUnits',v_pending_units,
    'pendingLength',v_pending_length,
    'stateSyncVersion','10.21.3'
  );
end;
$$;
revoke all on function erp_supply.sync_cut_execution_state(uuid,uuid) from public;

-- ---------------------------------------------------------------------------
-- 3. SANDBOX: CORREGIR LA FUENTE DEL ESTADO INCONSISTENTE
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_sandbox_execute_cut_group(p_group_key text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_exec erp_supply.cut_executions%rowtype;
  v_result jsonb;
  v_sync jsonb;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where organization_id=erp_supply.current_org_id()
    and group_key=p_group_key
    and status='IN_PROGRESS'
  order by started_at desc
  limit 1
  for update;

  if not found then raise exception 'Primero inicia el corte Sandbox'; end if;

  v_result:=public.erp_x_sandbox_execute_cut_group_v10162(p_group_key,p_payload);

  -- El simulador no toca inventario, pero sí debe cerrar los contadores físicos
  -- de los requerimientos congelados exactamente igual que producción.
  update erp_supply.cut_requirements r
  set process_status='IN_PROGRESS',
      units_completed=r.units_required,
      length_completed=r.total_length,
      resolution_code=coalesce(r.resolution_code,'CUT'),
      ready_at=null,
      ready_by=null,
      assigned_profile_id=coalesce(r.assigned_profile_id,v_actor),
      metadata=coalesce(r.metadata,'{}'::jsonb)||jsonb_build_object(
        'physicalComplete',true,
        'evidencePending',true,
        'executionId',v_exec.id,
        'cutFlowVersion','10.21.3',
        'sandboxCountersSynchronized',true
      ),
      updated_at=now()
  where exists(
    select 1 from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id and er.cut_requirement_id=r.id
  );

  update erp_supply.order_items i
  set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
        'sandboxCutStatus','WAITING_EVIDENCE',
        'cutExecutionId',v_exec.id,
        'cutEvidencePending',true,
        'cutFlowVersion','10.21.3'
      ),
      updated_at=now()
  where exists(
    select 1 from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id and er.order_item_id=i.id
  );

  v_sync:=erp_supply.sync_cut_execution_state(v_exec.id,v_actor);

  return v_result||jsonb_build_object(
    'executionId',v_exec.id,
    'groupCompleted',coalesce((v_sync->>'physicalComplete')::boolean,false),
    'waitingEvidence',coalesce((v_sync->>'physicalComplete')::boolean,false),
    'groupRemainingLength',coalesce(erp_supply.safe_numeric(v_sync->>'pendingLength'),0),
    'stateSyncVersion','10.21.3'
  );
end;
$$;

create or replace function public.erp_x_sandbox_cutting_evidence(p_execution_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_exec erp_supply.cut_executions%rowtype;
  v_order uuid;
  v_file erp_supply.drive_files%rowtype;
  v_sync jsonb;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Ejecución Sandbox no disponible'; end if;

  select er.order_id into v_order
  from erp_supply.cut_execution_requirements er
  join erp_supply.orders o on o.id=er.order_id
  where er.execution_id=v_exec.id and o.is_test
  order by er.created_at
  limit 1;
  if v_order is null then raise exception 'La ejecución no es Sandbox'; end if;

  v_sync:=erp_supply.sync_cut_execution_state(v_exec.id,v_actor);
  if not coalesce((v_sync->>'physicalComplete')::boolean,false) then
    raise exception 'Todavía faltan % requerimiento(s) de corte físico por completar (% m pendientes)',
      coalesce(erp_supply.safe_integer(v_sync->>'pendingRequirements'),0),
      round(coalesce(erp_supply.safe_numeric(v_sync->>'pendingLength'),0),3);
  end if;

  if v_exec.evidence_file_id is not null then
    return public.erp_x_cutting_execution(v_exec.id);
  end if;

  insert into erp_supply.drive_files(
    organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,size_bytes,uploaded_by,metadata
  ) values(
    v_exec.organization_id,v_order,null,'CUTTING_EVIDENCE','SANDBOX-CUT-'||gen_random_uuid()::text,
    coalesce(nullif(trim(p_payload->>'fileName'),''),'foto-corte-sandbox.jpg'),
    coalesce(nullif(trim(p_payload->>'mimeType'),''),'image/jpeg'),
    coalesce(erp_supply.safe_integer(p_payload->>'sizeBytes'),0),v_actor,
    jsonb_build_object('sandbox',true,'bytesUploaded',false,'executionId',v_exec.id,'version','10.21.3')
  ) returning * into v_file;

  update erp_supply.cut_executions
  set evidence_file_id=v_file.id,
      evidence_registered_at=now(),
      status='WAITING_EVIDENCE',
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'evidenceRegisteredBy',v_actor,
        'evidenceFileId',v_file.id,
        'evidenceVersion','10.21.3'
      ),
      updated_at=now()
  where id=v_exec.id;

  return public.erp_x_cutting_execution(v_exec.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. CONSULTA DE EJECUCIÓN: RECONCILIA ANTES DE MOSTRAR EL PASO AL USUARIO
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_execution(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_exec erp_supply.cut_executions%rowtype;
  v_is_test boolean;
  v_anchor_order uuid;
  v_anchor_number text;
  v_pending_length numeric:=0;
  v_pending_cuts numeric:=0;
  v_pending_requirements integer:=0;
  v_physical_complete boolean:=false;
  v_sync jsonb;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id and organization_id=v_org;
  if not found then raise exception 'Ejecución de Corte no encontrada'; end if;

  select bool_or(o.is_test) into v_is_test
  from erp_supply.cut_execution_requirements er
  join erp_supply.orders o on o.id=er.order_id
  where er.execution_id=v_exec.id;

  if coalesce(v_is_test,false) then
    perform erp_supply.require_sandbox_admin();
  elsif not (
    erp_supply.can_access_module('cutting','read')
    or erp_supply.has_role('auxiliar_corte')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para consultar Corte' using errcode='42501';
  end if;

  v_sync:=erp_supply.sync_cut_execution_state(v_exec.id,v_actor);
  select * into v_exec from erp_supply.cut_executions where id=v_exec.id;

  select er.order_id,o.order_number into v_anchor_order,v_anchor_number
  from erp_supply.cut_execution_requirements er
  join erp_supply.orders o on o.id=er.order_id
  where er.execution_id=v_exec.id
  order by er.created_at,er.id
  limit 1;

  select
    coalesce(sum(s.pending_length),0),
    coalesce(sum(s.pending_units),0),
    count(*) filter(where not s.physical_complete),
    coalesce(bool_and(s.physical_complete),false)
  into v_pending_length,v_pending_cuts,v_pending_requirements,v_physical_complete
  from erp_supply.cut_execution_requirement_state(v_exec.id) s;

  return jsonb_build_object(
    'execution',jsonb_build_object(
      'id',v_exec.id,'groupKey',v_exec.group_key,'status',v_exec.status,'reference',v_exec.reference,'sku',v_exec.sku,'description',v_exec.description,
      'materialMasterId',v_exec.material_master_id,'materialVariantId',v_exec.material_variant_id,
      'startedBy',v_exec.started_by,'startedAt',v_exec.started_at,'completedAt',v_exec.completed_at,
      'evidenceFileId',v_exec.evidence_file_id,'evidenceRegisteredAt',v_exec.evidence_registered_at,
      'initialOrderCount',v_exec.initial_order_count,'initialRequirementCount',v_exec.initial_requirement_count,
      'initialCutCount',v_exec.initial_cut_count,'initialLength',v_exec.initial_length,'metadata',v_exec.metadata
    ),
    'metrics',erp_supply.cut_execution_metrics(v_exec.id),
    'group',jsonb_build_object(
      'groupKey',v_exec.group_key,'reference',v_exec.reference,'sku',v_exec.sku,'description',v_exec.description,
      'materialMasterId',v_exec.material_master_id,'materialVariantId',v_exec.material_variant_id,
      'orderCount',v_exec.initial_order_count,'itemCount',v_exec.initial_requirement_count,
      'cutCount',v_pending_cuts,'totalLength',v_pending_length,'physicalComplete',v_physical_complete,
      'pendingRequirementCount',v_pending_requirements
    ),
    'items',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'requirementId',s.requirement_id,'orderId',s.order_id,'orderNumber',s.order_number,
        'clientName',o.client_name,'priority',o.priority,'orderItemId',s.order_item_id,'lineNumber',s.line_number,
        'reference',s.reference,'description',s.description,'unitsRequired',s.units_required,
        'unitsCompleted',s.units_completed,'unitsRemaining',s.pending_units,
        'lengthEach',r.length_each,'totalLength',s.total_length,'lengthCompleted',s.length_completed,
        'remainingLength',s.pending_length,'processStatus',r.process_status,'resolutionCode',s.resolution_code,
        'physicalComplete',s.physical_complete,'metadata',r.metadata
      ) order by case upper(o.priority) when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.order_number,s.line_number),'[]'::jsonb)
      from erp_supply.cut_execution_requirement_state(v_exec.id) s
      join erp_supply.cut_requirements r on r.id=s.requirement_id
      join erp_supply.orders o on o.id=s.order_id
    ),
    'recentBatches',(
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',b.id,'lotId',b.inventory_lot_id,'lotNumber',l.lot_number,'location',l.location,
        'reelInitialLength',b.reel_initial_length,'cutLength',b.requested_length,
        'scrapLength',b.scrap_length,'remainingLength',b.remaining_length,'executedAt',b.executed_at
      ) order by b.executed_at desc),'[]'::jsonb)
      from erp_supply.cut_batches b
      left join erp_supply.inventory_lots l on l.id=b.inventory_lot_id
      where b.execution_id=v_exec.id
    ),
    'currentPause',(
      select to_jsonb(x) from(
        select p.id,p.pause_type "pauseType",p.reason,p.started_at "startedAt",pr.display_name "startedBy"
        from erp_supply.cut_execution_pauses p
        left join erp_supply.profiles pr on pr.id=p.started_by
        where p.execution_id=v_exec.id and p.ended_at is null
        order by p.started_at desc limit 1
      )x
    ),
    'evidence',(
      select jsonb_build_object('id',f.id,'fileName',f.file_name,'mimeType',f.mime_type,'webViewLink',f.web_view_link,'createdAt',f.created_at)
      from erp_supply.drive_files f where f.id=v_exec.evidence_file_id
    ),
    'anchorOrderId',v_anchor_order,'anchorOrderNumber',v_anchor_number,
    'isTest',coalesce(v_is_test,false),
    'physicalComplete',v_physical_complete,
    'pendingRequirementCount',v_pending_requirements,
    'pendingLength',v_pending_length,
    'canFinalize',(v_physical_complete and v_exec.evidence_file_id is not null),
    'stateSyncVersion','10.21.3'
  );
end;
$$;

create or replace function public.erp_x_cutting_active_execution(p_group_key text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_id uuid;begin
  perform erp_supply.require_profile();
  v_id:=erp_supply.active_cut_execution_id(erp_supply.current_org_id(),p_group_key);
  if v_id is null then return null; end if;
  return public.erp_x_cutting_execution(v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. EVIDENCIA: NUNCA ACEPTA UN ESTADO VISUAL INCONSISTENTE
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_register_evidence(p_execution_id uuid,p_file_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.cut_executions%rowtype;
  v_file erp_supply.drive_files%rowtype;
  v_sync jsonb;
  v_detail text;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;

  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El corte está asignado a otro usuario' using errcode='42501';
  end if;

  if v_exec.status='COMPLETED' then return public.erp_x_cutting_execution(v_exec.id); end if;

  v_sync:=erp_supply.sync_cut_execution_state(v_exec.id,v_actor);
  if not coalesce((v_sync->>'physicalComplete')::boolean,false) then
    select string_agg(format('%s · línea %s · %s m',s.order_number,coalesce(s.line_number::text,'?'),round(s.pending_length,3)),'; ')
    into v_detail
    from (
      select * from erp_supply.cut_execution_requirement_state(v_exec.id)
      where not physical_complete
      order by order_number,line_number
      limit 3
    ) s;
    raise exception 'Todavía faltan % requerimiento(s) de corte físico por completar (% m). Pendiente: %',
      coalesce(erp_supply.safe_integer(v_sync->>'pendingRequirements'),0),
      round(coalesce(erp_supply.safe_numeric(v_sync->>'pendingLength'),0),3),
      coalesce(v_detail,'revisa los cortes pendientes');
  end if;

  select * into v_file
  from erp_supply.drive_files
  where id=p_file_id
    and organization_id=v_exec.organization_id
    and file_category='CUTTING_EVIDENCE';
  if not found then raise exception 'La foto cargada no corresponde a una evidencia de Corte'; end if;

  if not exists(
    select 1 from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id and er.order_id=v_file.order_id
  ) then
    raise exception 'La evidencia no pertenece a un pedido de esta ejecución';
  end if;

  update erp_supply.cut_executions
  set evidence_file_id=v_file.id,
      evidence_registered_at=coalesce(evidence_registered_at,now()),
      status='WAITING_EVIDENCE',
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'evidenceRegisteredBy',v_actor,
        'evidenceFileId',v_file.id,
        'evidenceVersion','10.21.3'
      ),
      updated_at=now()
  where id=v_exec.id;

  return public.erp_x_cutting_execution(v_exec.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. FINALIZACIÓN: MISMO ESTADO CANÓNICO QUE EL POPUP Y LA EVIDENCIA
-- ---------------------------------------------------------------------------

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
  v_sync jsonb;
  v_detail text;
begin
  select * into v_exec
  from erp_supply.cut_executions
  where id=p_execution_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;

  v_roles:=erp_supply.current_roles();
  v_role:=coalesce(v_roles[1],'auxiliar_corte');

  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El corte está asignado a otro usuario' using errcode='42501';
  end if;

  if v_exec.status='COMPLETED' then
    return jsonb_build_object(
      'success',true,'executionId',v_exec.id,'alreadyCompleted',true,
      'metrics',coalesce(erp_supply.cut_execution_metrics(v_exec.id),'{}'::jsonb),
      'finalizeVersion','10.21.3'
    );
  end if;

  v_sync:=erp_supply.sync_cut_execution_state(v_exec.id,v_actor);

  if not coalesce((v_sync->>'physicalComplete')::boolean,false) then
    select string_agg(format('%s · línea %s · %s m',s.order_number,coalesce(s.line_number::text,'?'),round(s.pending_length,3)),'; ')
    into v_detail
    from (
      select * from erp_supply.cut_execution_requirement_state(v_exec.id)
      where not physical_complete
      order by order_number,line_number
      limit 3
    ) s;
    raise exception 'Todavía faltan % requerimiento(s) de corte físico por completar (% m). Pendiente: %',
      coalesce(erp_supply.safe_integer(v_sync->>'pendingRequirements'),0),
      round(coalesce(erp_supply.safe_numeric(v_sync->>'pendingLength'),0),3),
      coalesce(v_detail,'revisa los cortes pendientes');
  end if;

  select * into v_exec from erp_supply.cut_executions where id=v_exec.id for update;

  if v_exec.evidence_file_id is null then
    raise exception 'Debes subir la foto final del material cortado antes de cerrar Corte';
  end if;

  if not exists(
    select 1 from erp_supply.drive_files f
    where f.id=v_exec.evidence_file_id
      and f.organization_id=v_exec.organization_id
      and f.file_category='CUTTING_EVIDENCE'
  ) then
    raise exception 'La evidencia final registrada ya no está disponible o no corresponde a Corte';
  end if;

  update erp_supply.cut_execution_pauses
  set ended_at=coalesce(ended_at,now()),
      ended_by=coalesce(ended_by,v_actor),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'closedByFinalize',true,'closedAt',now(),'finalizeVersion','10.21.3'
      )
  where execution_id=v_exec.id and ended_at is null;

  update erp_supply.cut_requirements r
  set process_status='READY',
      units_completed=r.units_required,
      length_completed=r.total_length,
      ready_at=coalesce(r.ready_at,now()),
      ready_by=coalesce(r.ready_by,v_actor),
      collection_status=case when r.collection_status='COLLECTED' then 'COLLECTED' else 'PENDING' end,
      metadata=coalesce(r.metadata,'{}'::jsonb)||jsonb_build_object(
        'physicalComplete',true,'evidencePending',false,'evidenceClosed',true,
        'evidenceFileId',v_exec.evidence_file_id,'executionId',v_exec.id,
        'cutClosedAt',now(),'cutFlowVersion','10.21.3'
      ),
      updated_at=now()
  where exists(
    select 1 from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id and er.cut_requirement_id=r.id
  );

  update erp_supply.order_items i
  set metadata=coalesce(i.metadata,'{}'::jsonb)||jsonb_build_object(
        'cutStatus','READY','cutExecutionId',v_exec.id,
        'cutEvidenceFileId',v_exec.evidence_file_id,'cutEvidencePending',false,
        'cutReadyAt',now(),'cutFlowVersion','10.21.3'
      ),
      updated_at=now()
  where i.requires_cut
    and exists(
      select 1 from erp_supply.cut_execution_requirements er
      where er.execution_id=v_exec.id and er.order_item_id=i.id
    );

  update erp_supply.cut_executions
  set status='COMPLETED',completed_by=v_actor,completed_at=coalesce(completed_at,now()),updated_at=now()
  where id=v_exec.id
  returning * into v_exec;

  v_metrics:=coalesce(erp_supply.cut_execution_metrics(v_exec.id),'{}'::jsonb);

  update erp_supply.cut_executions
  set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'finalMetrics',v_metrics,'closedWithEvidence',true,
        'finalizeVersion','10.21.3','finalizedAt',now()
      ),updated_at=now()
  where id=v_exec.id;

  for v_order_id in
    select distinct er.order_id
    from erp_supply.cut_execution_requirements er
    where er.execution_id=v_exec.id
  loop
    select * into v_order from erp_supply.orders where id=v_order_id for update;
    if not found then continue; end if;

    if not exists(
      select 1 from erp_supply.cut_requirements r
      where r.order_id=v_order_id and r.process_status<>'READY'
    ) then
      v_cutflow:=case
        when jsonb_typeof(coalesce(v_order.metadata,'{}'::jsonb)->'cutFlow')='object'
          then coalesce(v_order.metadata,'{}'::jsonb)->'cutFlow'
        else '{}'::jsonb
      end;

      v_cutflow:=(coalesce(v_cutflow,'{}'::jsonb)-'waitingEvidence')||jsonb_build_object(
        'completedAt',now(),'completedBy',v_actor,'parallel',true,'waitingEvidence',false,
        'pendingCollection',(
          select count(*) from erp_supply.cut_requirements r
          where r.order_id=v_order_id and r.process_status='READY' and r.collection_status='PENDING'
        ),
        'cutExecutionId',v_exec.id,'evidenceFileId',v_exec.evidence_file_id,
        'executionCompletedAt',v_exec.completed_at,'executionMetrics',v_metrics,'version','10.21.3'
      );

      update erp_supply.orders
      set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('cutFlow',v_cutflow),
          version=coalesce(version,0)+1,updated_at=now()
      where id=v_order_id;
    end if;

    if not exists(
      select 1 from erp_supply.order_events e
      where e.order_id=v_order_id
        and e.action_code='CUT_EXECUTION_COMPLETED'
        and e.payload->>'executionId'=v_exec.id::text
    ) then
      insert into erp_supply.order_events(
        organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
        actor_profile_id,actor_role_code,payload
      ) values(
        v_exec.organization_id,v_order_id,'DOMAIN_RECORD','CUT_EXECUTION_COMPLETED',
        'ALISTAMIENTO','ALISTAMIENTO',v_actor,v_role,
        jsonb_build_object(
          'executionId',v_exec.id,'groupKey',v_exec.group_key,'reference',v_exec.reference,
          'evidenceFileId',v_exec.evidence_file_id,'metrics',v_metrics,'finalizeVersion','10.21.3'
        )
      );
    end if;
  end loop;

  return jsonb_build_object(
    'success',true,'executionId',v_exec.id,'completedAt',v_exec.completed_at,
    'metrics',v_metrics,'releasedToPicking',true,'finalizeVersion','10.21.3'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. REPARAR EJECUCIONES ACTIVAS YA CREADAS ANTES DEL 039
-- ---------------------------------------------------------------------------

do $$
declare v_id uuid;begin
  for v_id in
    select e.id
    from erp_supply.cut_executions e
    where e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
  loop
    perform erp_supply.sync_cut_execution_state(v_id,null);
  end loop;
end $$;

revoke all on function public.erp_x_sandbox_execute_cut_group(text,jsonb) from public,anon;
grant execute on function public.erp_x_sandbox_execute_cut_group(text,jsonb) to authenticated;
revoke all on function public.erp_x_sandbox_cutting_evidence(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_sandbox_cutting_evidence(uuid,jsonb) to authenticated;
revoke all on function public.erp_x_cutting_execution(uuid) from public,anon;
grant execute on function public.erp_x_cutting_execution(uuid) to authenticated;
revoke all on function public.erp_x_cutting_active_execution(text) from public,anon;
grant execute on function public.erp_x_cutting_active_execution(text) to authenticated;
revoke all on function public.erp_x_cutting_register_evidence(uuid,uuid) from public,anon;
grant execute on function public.erp_x_cutting_register_evidence(uuid,uuid) to authenticated;
revoke all on function public.erp_x_cutting_finalize(uuid) from public,anon;
grant execute on function public.erp_x_cutting_finalize(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
