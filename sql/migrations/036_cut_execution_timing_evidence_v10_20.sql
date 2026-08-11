-- ERP EI V10.20
-- Ejecución formal de Corte por referencia: inicio/pausa/evidencia/cierre y tiempo real.
-- Base requerida: V10.19 + migración 035 aplicada.

begin;

-- ---------------------------------------------------------------------------
-- 1. EJECUCIÓN FORMAL DE CORTE POR REFERENCIA
-- ---------------------------------------------------------------------------

create table if not exists erp_supply.cut_executions (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id) on delete cascade,
  group_key text not null,
  reference text,
  sku text,
  description text not null,
  material_master_id uuid references erp_supply.material_master(id) on delete set null,
  material_variant_id uuid references erp_supply.material_variants(id) on delete set null,
  status text not null default 'IN_PROGRESS' check(status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE','COMPLETED','CANCELLED')),
  started_by uuid not null references erp_supply.profiles(id),
  started_at timestamptz not null default now(),
  evidence_file_id uuid references erp_supply.drive_files(id) on delete set null,
  evidence_registered_at timestamptz,
  completed_by uuid references erp_supply.profiles(id),
  completed_at timestamptz,
  initial_order_count integer not null default 0,
  initial_requirement_count integer not null default 0,
  initial_cut_count numeric(18,4) not null default 0,
  initial_length numeric(18,4) not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_cut_executions_active_group
  on erp_supply.cut_executions(organization_id,group_key)
  where status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE');
create index if not exists idx_cut_executions_status
  on erp_supply.cut_executions(organization_id,status,started_at desc);

create table if not exists erp_supply.cut_execution_requirements (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null references erp_supply.cut_executions(id) on delete cascade,
  cut_requirement_id uuid not null references erp_supply.cut_requirements(id) on delete cascade,
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  initial_units numeric(18,4) not null,
  initial_length numeric(18,4) not null,
  created_at timestamptz not null default now(),
  unique(execution_id,cut_requirement_id)
);
create index if not exists idx_cut_execution_requirements_exec
  on erp_supply.cut_execution_requirements(execution_id,created_at);
create index if not exists idx_cut_execution_requirements_req
  on erp_supply.cut_execution_requirements(cut_requirement_id,execution_id);

create table if not exists erp_supply.cut_execution_pauses (
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null references erp_supply.cut_executions(id) on delete cascade,
  pause_type text not null default 'USER' check(pause_type in('USER','APPROVAL','ISSUE','REPORT','SYSTEM')),
  reason text not null,
  started_by uuid references erp_supply.profiles(id),
  started_at timestamptz not null default now(),
  ended_by uuid references erp_supply.profiles(id),
  ended_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);
create unique index if not exists uq_cut_execution_open_pause
  on erp_supply.cut_execution_pauses(execution_id)
  where ended_at is null;

alter table erp_supply.cut_batches
  add column if not exists execution_id uuid references erp_supply.cut_executions(id) on delete set null;
create index if not exists idx_cut_batches_execution
  on erp_supply.cut_batches(execution_id,executed_at);

-- ---------------------------------------------------------------------------
-- 2. AYUDANTES
-- ---------------------------------------------------------------------------

create or replace function erp_supply.active_cut_execution_id(p_org uuid,p_group_key text)
returns uuid
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select e.id
  from erp_supply.cut_executions e
  where e.organization_id=p_org and e.group_key=p_group_key
    and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
  order by e.started_at desc
  limit 1
$$;
revoke all on function erp_supply.active_cut_execution_id(uuid,text) from public;

create or replace function erp_supply.cut_execution_metrics(p_execution_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_exec erp_supply.cut_executions%rowtype;
  v_end timestamptz;
  v_calendar bigint;
  v_business bigint;
  v_pause_calendar bigint;
  v_pause_business bigint;
  v_active_business bigint;
  v_batch_count integer;
  v_reel_count integer;
  v_cut numeric;
  v_scrap numeric;
begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id;
  if not found then return '{}'::jsonb; end if;
  v_end:=coalesce(v_exec.completed_at,now());
  v_calendar:=greatest(0,extract(epoch from(v_end-v_exec.started_at))::bigint);
  v_business:=erp_supply.business_seconds_between(v_exec.organization_id,v_exec.started_at,v_end);

  select coalesce(sum(greatest(0,extract(epoch from(coalesce(p.ended_at,v_end)-p.started_at))::bigint)),0),
         coalesce(sum(erp_supply.business_seconds_between(v_exec.organization_id,p.started_at,least(coalesce(p.ended_at,v_end),v_end))),0)
  into v_pause_calendar,v_pause_business
  from erp_supply.cut_execution_pauses p
  where p.execution_id=v_exec.id and p.started_at<v_end;

  v_active_business:=greatest(v_business-v_pause_business,0);

  select count(*),count(distinct inventory_lot_id),coalesce(sum(requested_length),0),coalesce(sum(scrap_length),0)
  into v_batch_count,v_reel_count,v_cut,v_scrap
  from erp_supply.cut_batches
  where execution_id=v_exec.id;

  return jsonb_build_object(
    'calendarSeconds',v_calendar,
    'businessSeconds',v_business,
    'pausedSeconds',v_pause_calendar,
    'pausedBusinessSeconds',v_pause_business,
    'activeBusinessSeconds',v_active_business,
    'batchCount',v_batch_count,
    'reelCount',v_reel_count,
    'cutLength',v_cut,
    'scrapLength',v_scrap
  );
end;
$$;
revoke all on function erp_supply.cut_execution_metrics(uuid) from public;

-- El planificador V10.18 conserva su firma, pero cuando existe una ejecución
-- activa congela el alcance a los requerimientos que estaban presentes al iniciar.
create or replace function erp_supply.cut_plan_rows(
  p_org uuid,
  p_group_key text,
  p_capacity numeric,
  p_actor uuid,
  p_override boolean
)
returns table(
  requirement_id uuid,
  order_id uuid,
  order_item_id uuid,
  units_to_cut numeric,
  length_each numeric,
  length_to_cut numeric,
  units_remaining_before numeric,
  units_remaining_after numeric
)
language plpgsql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_req record;
  v_available numeric:=greatest(coalesce(p_capacity,0),0);
  v_units_left numeric;
  v_units_fit numeric;
  v_units_take numeric;
  v_execution_id uuid:=erp_supply.active_cut_execution_id(p_org,p_group_key);
begin
  if v_available<=0 then return; end if;

  for v_req in
    select r.*,o.priority,o.order_number
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=p_org
      and r.group_key=p_group_key
      and r.process_status<>'READY'
      and (v_execution_id is null or exists(
        select 1 from erp_supply.cut_execution_requirements er
        where er.execution_id=v_execution_id and er.cut_requirement_id=r.id
      ))
      and not exists(
        select 1 from erp_supply.order_issues oi
        where oi.order_id=o.id and oi.blocking and oi.status='OPEN'
      )
      and (p_override or r.assigned_profile_id is null or r.assigned_profile_id=p_actor)
    order by
      case upper(coalesce(o.priority,'MEDIUM'))
        when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3
        when 'MEDIUM' then 4 when 'LOW' then 5 else 6 end,
      r.created_at,o.order_number,r.id
  loop
    v_units_left:=greatest(v_req.units_required-coalesce(v_req.units_completed,0),0);
    if v_units_left<=0 or v_req.length_each<=0 then continue; end if;
    if v_req.length_each>v_available then continue; end if;
    v_units_fit:=floor(v_available/v_req.length_each);
    v_units_take:=least(v_units_left,v_units_fit);
    if v_units_take<=0 then continue; end if;

    requirement_id:=v_req.id;
    order_id:=v_req.order_id;
    order_item_id:=v_req.order_item_id;
    units_to_cut:=v_units_take;
    length_each:=v_req.length_each;
    length_to_cut:=round((v_units_take*v_req.length_each)::numeric,4);
    units_remaining_before:=v_units_left;
    units_remaining_after:=greatest(v_units_left-v_units_take,0);
    return next;
    v_available:=v_available-length_to_cut;
    exit when v_available<=0;
  end loop;
end;
$$;
revoke all on function erp_supply.cut_plan_rows(uuid,text,numeric,uuid,boolean) from public;

-- ---------------------------------------------------------------------------
-- 3. INICIO / PAUSA / REANUDACIÓN
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_start(p_group_key text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_existing uuid;
  v_is_test boolean;
  v_ref text;v_sku text;v_desc text;v_material uuid;v_variant uuid;
  v_exec erp_supply.cut_executions%rowtype;
  v_orders integer;v_reqs integer;v_cuts numeric;v_length numeric;
begin
  if nullif(trim(p_group_key),'') is null then raise exception 'Referencia de corte requerida'; end if;

  v_existing:=erp_supply.active_cut_execution_id(v_org,p_group_key);
  if v_existing is not null then return public.erp_x_cutting_execution(v_existing); end if;

  select bool_or(o.is_test),max(r.reference),max(r.sku),max(r.description),
         min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid
  into v_is_test,v_ref,v_sku,v_desc,v_material,v_variant
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_desc is null then raise exception 'La referencia ya no tiene cortes disponibles'; end if;

  if coalesce(v_is_test,false) then
    perform erp_supply.require_sandbox_admin();
  elsif not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para iniciar Corte' using errcode='42501';
  end if;

  insert into erp_supply.cut_executions(
    organization_id,group_key,reference,sku,description,material_master_id,material_variant_id,
    status,started_by,started_at,metadata
  ) values(
    v_org,p_group_key,v_ref,v_sku,v_desc,v_material,v_variant,'IN_PROGRESS',v_actor,now(),
    jsonb_build_object('version','10.20','isTest',coalesce(v_is_test,false),'scopeFrozen',true)
  ) returning * into v_exec;

  insert into erp_supply.cut_execution_requirements(
    execution_id,cut_requirement_id,order_id,order_item_id,initial_units,initial_length
  )
  select v_exec.id,r.id,r.order_id,r.order_item_id,
         greatest(r.units_required-coalesce(r.units_completed,0),0),
         greatest(r.total_length-coalesce(r.length_completed,0),0)
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);

  select count(distinct er.order_id),count(*),coalesce(sum(er.initial_units),0),coalesce(sum(er.initial_length),0)
  into v_orders,v_reqs,v_cuts,v_length
  from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id;
  if v_reqs=0 then raise exception 'No hay cortes disponibles para iniciar'; end if;

  update erp_supply.cut_executions
  set initial_order_count=v_orders,initial_requirement_count=v_reqs,initial_cut_count=v_cuts,initial_length=v_length,
      metadata=metadata||jsonb_build_object('initialOrderCount',v_orders,'initialRequirementCount',v_reqs,'initialCutCount',v_cuts,'initialLength',v_length),updated_at=now()
  where id=v_exec.id;

  update erp_supply.cut_requirements r
  set process_status='IN_PROGRESS',assigned_profile_id=coalesce(r.assigned_profile_id,v_actor),
      metadata=r.metadata||jsonb_build_object('executionId',v_exec.id,'executionStartedAt',now(),'cutFlowVersion','10.20'),updated_at=now()
  where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.cut_requirement_id=r.id);

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  select distinct v_org,er.order_id,'DOMAIN_RECORD','CUT_EXECUTION_STARTED','ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('executionId',v_exec.id,'groupKey',p_group_key,'reference',v_ref,'orders',v_orders,'cuts',v_cuts,'length',v_length)
  from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id;

  return public.erp_x_cutting_execution(v_exec.id);
end;
$$;

create or replace function public.erp_x_cutting_pause(p_execution_id uuid,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_profile();v_exec erp_supply.cut_executions%rowtype;v_reason text:=nullif(trim(p_reason),'');begin
  if v_reason is null then raise exception 'Indica por qué pausas el corte'; end if;
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;
  if v_exec.status<>'IN_PROGRESS' then raise exception 'La ejecución no está disponible para pausar'; end if;
  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El corte está asignado a otro usuario' using errcode='42501'; end if;
  insert into erp_supply.cut_execution_pauses(execution_id,pause_type,reason,started_by) values(v_exec.id,'USER',v_reason,v_actor);
  update erp_supply.cut_executions set status='PAUSED',updated_at=now(),metadata=metadata||jsonb_build_object('lastPauseReason',v_reason,'lastPausedAt',now()) where id=v_exec.id;
  return public.erp_x_cutting_execution(v_exec.id);
end;$$;

create or replace function public.erp_x_cutting_resume(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_profile();v_exec erp_supply.cut_executions%rowtype;begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;
  if v_exec.status<>'PAUSED' then raise exception 'La ejecución no está pausada'; end if;
  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El corte está asignado a otro usuario' using errcode='42501'; end if;
  update erp_supply.cut_execution_pauses set ended_at=now(),ended_by=v_actor where execution_id=v_exec.id and ended_at is null;
  update erp_supply.cut_executions set status='IN_PROGRESS',updated_at=now(),metadata=metadata||jsonb_build_object('lastResumedAt',now()) where id=v_exec.id;
  return public.erp_x_cutting_execution(v_exec.id);
end;$$;

-- Novedades y reportes bloqueantes pausan automáticamente el tiempo activo de Corte.
-- La reanudación es manual para no contar como productivo el tiempo entre la solución
-- de la incidencia y el regreso físico del auxiliar al trabajo.
create or replace function erp_supply.trg_pause_cut_execution_on_issue()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare v_exec record;begin
  if new.blocking and new.status='OPEN' and new.issue_type in('NOVELTY','REPORT') then
    for v_exec in
      select distinct e.id
      from erp_supply.cut_executions e
      join erp_supply.cut_execution_requirements er on er.execution_id=e.id
      where er.order_id=new.order_id and e.status='IN_PROGRESS'
    loop
      if not exists(select 1 from erp_supply.cut_execution_pauses p where p.execution_id=v_exec.id and p.ended_at is null) then
        insert into erp_supply.cut_execution_pauses(execution_id,pause_type,reason,started_by,metadata)
        values(v_exec.id,case when new.issue_type='REPORT' then 'REPORT' else 'ISSUE' end,
          format('%s: %s',case when new.issue_type='REPORT' then 'Reporte' else 'Novedad' end,new.title),new.created_by,
          jsonb_build_object('issueId',new.id,'orderId',new.order_id,'automatic',true));
        update erp_supply.cut_executions set status='PAUSED',updated_at=now(),metadata=metadata||jsonb_build_object('automaticPauseIssueId',new.id,'automaticPausedAt',now()) where id=v_exec.id;
      end if;
    end loop;
  end if;
  return new;
end;$$;

drop trigger if exists trg_pause_cut_execution_on_issue on erp_supply.order_issues;
create trigger trg_pause_cut_execution_on_issue
after insert or update of status,blocking on erp_supply.order_issues
for each row execute function erp_supply.trg_pause_cut_execution_on_issue();

-- ---------------------------------------------------------------------------
-- 4. DETALLE DE UNA EJECUCIÓN
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_execution(p_execution_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_exec erp_supply.cut_executions%rowtype;
  v_is_test boolean;
  v_anchor_order uuid;v_anchor_number text;
  v_pending_length numeric;v_pending_cuts numeric;v_physical_complete boolean;
begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=v_org;
  if not found then raise exception 'Ejecución de Corte no encontrada'; end if;
  select bool_or(o.is_test) into v_is_test from erp_supply.cut_execution_requirements er join erp_supply.orders o on o.id=er.order_id where er.execution_id=v_exec.id;
  if coalesce(v_is_test,false) then perform erp_supply.require_sandbox_admin();
  elsif not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para consultar Corte' using errcode='42501'; end if;

  select er.order_id,o.order_number into v_anchor_order,v_anchor_number
  from erp_supply.cut_execution_requirements er join erp_supply.orders o on o.id=er.order_id
  where er.execution_id=v_exec.id order by er.created_at,er.id limit 1;

  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0),
         coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0),
         coalesce(bool_and(coalesce(r.length_completed,0)>=r.total_length-0.0001),false)
  into v_pending_length,v_pending_cuts,v_physical_complete
  from erp_supply.cut_execution_requirements er
  join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
  where er.execution_id=v_exec.id;

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
      'cutCount',v_pending_cuts,'totalLength',v_pending_length,'physicalComplete',v_physical_complete
    ),
    'items',(select coalesce(jsonb_agg(jsonb_build_object(
      'requirementId',r.id,'orderId',r.order_id,'orderNumber',o.order_number,'clientName',o.client_name,'priority',o.priority,
      'orderItemId',r.order_item_id,'lineNumber',i.line_number,'reference',r.reference,'sku',r.sku,'description',r.description,'unit',r.unit,
      'unitsRequired',r.units_required,'unitsCompleted',coalesce(r.units_completed,0),'unitsRemaining',greatest(r.units_required-coalesce(r.units_completed,0),0),
      'lengthEach',r.length_each,'totalLength',r.total_length,'lengthCompleted',coalesce(r.length_completed,0),'remainingLength',greatest(r.total_length-coalesce(r.length_completed,0),0),
      'processStatus',r.process_status,'resolutionCode',r.resolution_code,'metadata',r.metadata
    ) order by case upper(o.priority) when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.order_number,i.line_number),'[]'::jsonb)
      from erp_supply.cut_execution_requirements er
      join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
      join erp_supply.orders o on o.id=r.order_id
      join erp_supply.order_items i on i.id=r.order_item_id
      where er.execution_id=v_exec.id),
    'recentBatches',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',b.id,'lotId',b.inventory_lot_id,'lotNumber',l.lot_number,'location',l.location,
      'reelInitialLength',b.reel_initial_length,'cutLength',b.requested_length,'scrapLength',b.scrap_length,'remainingLength',b.remaining_length,'executedAt',b.executed_at
    ) order by b.executed_at desc),'[]'::jsonb)
      from erp_supply.cut_batches b left join erp_supply.inventory_lots l on l.id=b.inventory_lot_id where b.execution_id=v_exec.id),
    'currentPause',(select to_jsonb(x) from(select p.id,p.pause_type "pauseType",p.reason,p.started_at "startedAt",pr.display_name "startedBy" from erp_supply.cut_execution_pauses p left join erp_supply.profiles pr on pr.id=p.started_by where p.execution_id=v_exec.id and p.ended_at is null order by p.started_at desc limit 1)x),
    'evidence',(select jsonb_build_object('id',f.id,'fileName',f.file_name,'mimeType',f.mime_type,'webViewLink',f.web_view_link,'createdAt',f.created_at) from erp_supply.drive_files f where f.id=v_exec.evidence_file_id),
    'anchorOrderId',v_anchor_order,'anchorOrderNumber',v_anchor_number,
    'isTest',coalesce(v_is_test,false),
    'physicalComplete',v_physical_complete,
    'canFinalize',(v_physical_complete and v_exec.evidence_file_id is not null)
  );
end;
$$;

create or replace function public.erp_x_cutting_active_execution(p_group_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_id uuid;begin
  perform erp_supply.require_profile();
  v_id:=erp_supply.active_cut_execution_id(erp_supply.current_org_id(),p_group_key);
  if v_id is null then return null; end if;
  return public.erp_x_cutting_execution(v_id);
end;$$;

-- ---------------------------------------------------------------------------
-- 5. LISTA OPERATIVA: MANTIENE VISIBLE LA REFERENCIA HASTA LA FOTO FINAL
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_work(
  p_search text default null,p_page integer default 1,p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();v_actor uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');v_total bigint;v_items jsonb;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then raise exception 'No autorizado para consultar Corte' using errcode='42501'; end if;

  with active_rows as(
    select e.group_key,e.reference,e.sku,e.description,e.material_master_id,e.material_variant_id,
      e.initial_requirement_count item_count,e.initial_order_count order_count,
      coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0) cut_count,
      coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) total_length,
      coalesce(sum(r.length_completed),0) completed_length,e.started_at oldest_at,true in_progress,
      e.status execution_status,e.id execution_id
    from erp_supply.cut_executions e
    join erp_supply.cut_execution_requirements er on er.execution_id=e.id
    join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
    join erp_supply.orders o on o.id=er.order_id
    where e.organization_id=v_org and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE') and not o.is_test
      and (v_override or e.started_by=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(e.reference,'')||' '||coalesce(e.sku,'')||' '||e.description) like '%'||lower(p_search)||'%')
    group by e.id
  ), pending_rows as(
    select r.group_key,max(r.reference) reference,max(r.sku) sku,max(r.description) description,
      min(r.material_master_id::text)::uuid material_master_id,min(r.material_variant_id::text)::uuid material_variant_id,
      count(*)::integer item_count,count(distinct r.order_id)::integer order_count,
      sum(greatest(r.units_required-coalesce(r.units_completed,0),0)) cut_count,
      sum(greatest(r.total_length-coalesce(r.length_completed,0),0)) total_length,
      sum(coalesce(r.length_completed,0)) completed_length,min(r.created_at) oldest_at,false in_progress,
      null::text execution_status,null::uuid execution_id
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') and not o.is_test
    where r.organization_id=v_org and r.process_status<>'READY' and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
      and not exists(select 1 from erp_supply.cut_executions e where e.organization_id=v_org and e.group_key=r.group_key and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE'))
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
    group by r.group_key
  ), all_rows as(select * from active_rows union all select * from pending_rows)
  select count(*) into v_total from all_rows;

  with active_rows as(
    select e.group_key,e.reference,e.sku,e.description,e.material_master_id,e.material_variant_id,
      e.initial_requirement_count item_count,e.initial_order_count order_count,
      coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0) cut_count,
      coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) total_length,
      coalesce(sum(r.length_completed),0) completed_length,e.started_at oldest_at,true in_progress,
      e.status execution_status,e.id execution_id,(erp_supply.cut_execution_metrics(e.id)->>'businessSeconds')::bigint elapsed_seconds
    from erp_supply.cut_executions e
    join erp_supply.cut_execution_requirements er on er.execution_id=e.id
    join erp_supply.cut_requirements r on r.id=er.cut_requirement_id
    join erp_supply.orders o on o.id=er.order_id
    where e.organization_id=v_org and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE') and not o.is_test
      and (v_override or e.started_by=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(e.reference,'')||' '||coalesce(e.sku,'')||' '||e.description) like '%'||lower(p_search)||'%')
    group by e.id
  ), pending_rows as(
    select r.group_key,max(r.reference) reference,max(r.sku) sku,max(r.description) description,
      min(r.material_master_id::text)::uuid material_master_id,min(r.material_variant_id::text)::uuid material_variant_id,
      count(*)::integer item_count,count(distinct r.order_id)::integer order_count,
      sum(greatest(r.units_required-coalesce(r.units_completed,0),0)) cut_count,
      sum(greatest(r.total_length-coalesce(r.length_completed,0),0)) total_length,
      sum(coalesce(r.length_completed,0)) completed_length,min(r.created_at) oldest_at,false in_progress,
      null::text execution_status,null::uuid execution_id,0::bigint elapsed_seconds
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') and not o.is_test
    where r.organization_id=v_org and r.process_status<>'READY' and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
      and not exists(select 1 from erp_supply.cut_executions e where e.organization_id=v_org and e.group_key=r.group_key and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE'))
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
    group by r.group_key
  ), all_rows as(select * from active_rows union all select * from pending_rows), paged as(
    select * from all_rows order by case execution_status when 'WAITING_EVIDENCE' then 1 when 'IN_PROGRESS' then 2 when 'PAUSED' then 3 else 4 end,oldest_at
    offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'groupKey',group_key,'reference',reference,'sku',sku,'description',description,
    'materialMasterId',material_master_id,'materialVariantId',material_variant_id,
    'itemCount',item_count,'orderCount',order_count,'cutCount',cut_count,'totalLength',total_length,
    'completedLength',completed_length,'oldestAt',oldest_at,'inProgress',in_progress,
    'executionStatus',execution_status,'executionId',execution_id,'elapsedSeconds',elapsed_seconds
  )),'[]'::jsonb) into v_items from paged;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),'generatedAt',now());
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. PLAN DE CARRETO LIMITADO A LA EJECUCIÓN CONGELADA
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_execution_plan(
  p_execution_id uuid,p_inventory_lot_id uuid,p_reel_length numeric,p_scrap_length numeric default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_exec erp_supply.cut_executions%rowtype;v_result jsonb;v_before numeric;v_after numeric;v_planned numeric;
begin
  perform erp_supply.require_profile();
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id();
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;
  if v_exec.status='PAUSED' then raise exception 'Reanuda el corte antes de planear un carreto'; end if;
  if v_exec.status='WAITING_EVIDENCE' then raise exception 'El corte físico ya terminó. Solo falta la evidencia final.'; end if;
  if v_exec.status<>'IN_PROGRESS' then raise exception 'La ejecución ya no está activa'; end if;

  v_result:=public.erp_x_cutting_batch_plan(v_exec.group_key,p_inventory_lot_id,p_reel_length,p_scrap_length);
  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0)
  into v_before from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id;
  v_planned:=coalesce(erp_supply.safe_numeric(v_result->>'plannedLength'),0);
  v_after:=greatest(v_before-v_planned,0);
  return v_result||jsonb_build_object('executionId',v_exec.id,'groupRemainingBefore',v_before,'groupRemainingAfter',v_after,'groupCompleted',(v_after<=0),'partialBatch',(v_after>0));
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. ENVOLTORIOS SOBRE V10.18: EL ÚLTIMO CARRETO NO LIBERA HASTA LA FOTO
-- ---------------------------------------------------------------------------

do $$
begin
  if to_regprocedure('public.erp_x_execute_cut_group_v1018(text,jsonb)') is null
     and to_regprocedure('public.erp_x_execute_cut_group(text,jsonb)') is not null then
    execute 'alter function public.erp_x_execute_cut_group(text,jsonb) rename to erp_x_execute_cut_group_v1018';
  end if;
  if to_regprocedure('public.erp_x_resolve_cut_requirement_v1018(uuid,text,jsonb)') is null
     and to_regprocedure('public.erp_x_resolve_cut_requirement(uuid,text,jsonb)') is not null then
    execute 'alter function public.erp_x_resolve_cut_requirement(uuid,text,jsonb) rename to erp_x_resolve_cut_requirement_v1018';
  end if;
end $$;

revoke all on function public.erp_x_execute_cut_group_v1018(text,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_resolve_cut_requirement_v1018(uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.erp_x_execute_cut_group(p_group_key text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();v_actor uuid:=erp_supply.require_profile();v_exec erp_supply.cut_executions%rowtype;v_result jsonb;v_remaining numeric;v_batch uuid;v_order uuid;
begin
  select * into v_exec from erp_supply.cut_executions where organization_id=v_org and group_key=p_group_key and status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE') order by started_at desc limit 1 for update;
  if not found then raise exception 'Primero debes iniciar el corte de esta referencia'; end if;
  if v_exec.status='PAUSED' then raise exception 'El corte está pausado. Reanúdalo antes de continuar.'; end if;
  if v_exec.status='WAITING_EVIDENCE' then raise exception 'El corte físico ya terminó. Sube la foto final para cerrar la referencia.'; end if;

  v_result:=public.erp_x_execute_cut_group_v1018(p_group_key,p_payload);
  v_batch:=erp_supply.safe_uuid(v_result->>'batchId');
  if v_batch is not null then update erp_supply.cut_batches set execution_id=v_exec.id,metadata=metadata||jsonb_build_object('executionId',v_exec.id,'cutFlowVersion','10.20') where id=v_batch; end if;

  -- V10.18 marca READY al completar físicamente una línea. V10.20 la retiene
  -- hasta que la ejecución completa tenga evidencia fotográfica.
  update erp_supply.cut_requirements r
  set process_status='IN_PROGRESS',ready_at=null,ready_by=null,
      metadata=r.metadata||jsonb_build_object('physicalComplete',true,'evidencePending',true,'executionId',v_exec.id,'cutFlowVersion','10.20'),updated_at=now()
  where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.cut_requirement_id=r.id)
    and r.process_status='READY' and coalesce(r.length_completed,0)>=r.total_length-0.0001;

  update erp_supply.order_items i
  set metadata=(i.metadata||jsonb_build_object('cutStatus','WAITING_EVIDENCE','cutExecutionId',v_exec.id,'cutEvidencePending',true,'cutFlowVersion','10.20')),updated_at=now()
  where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.order_item_id=i.id)
    and exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=i.id and coalesce(r.length_completed,0)>=r.total_length-0.0001);

  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0)
  into v_remaining from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id;

  if v_remaining<=0 then
    update erp_supply.cut_executions set status='WAITING_EVIDENCE',updated_at=now(),metadata=metadata||jsonb_build_object('physicalCompletedAt',now(),'evidenceRequired',true) where id=v_exec.id;
    for v_order in select distinct er.order_id from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id loop
      update erp_supply.orders o set metadata=jsonb_set(o.metadata,'{cutFlow}',((coalesce(o.metadata->'cutFlow','{}'::jsonb)-'completedAt'-'completedBy')||jsonb_build_object('waitingEvidence',true,'cutExecutionId',v_exec.id,'physicalCompletedAt',now())),true),updated_at=now() where o.id=v_order;
    end loop;
  end if;

  return v_result||jsonb_build_object('executionId',v_exec.id,'groupRemainingLength',v_remaining,'groupCompleted',(v_remaining<=0),'waitingEvidence',(v_remaining<=0));
end;
$$;

create or replace function public.erp_x_resolve_cut_requirement(p_requirement_id uuid,p_resolution text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();v_exec erp_supply.cut_executions%rowtype;v_result jsonb;v_remaining numeric;v_req erp_supply.cut_requirements%rowtype;v_batch uuid;
begin
  select e.* into v_exec
  from erp_supply.cut_executions e
  join erp_supply.cut_execution_requirements er on er.execution_id=e.id
  where er.cut_requirement_id=p_requirement_id and e.organization_id=v_org and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
  order by e.started_at desc limit 1 for update;
  if not found then raise exception 'Primero debes iniciar el corte de esta referencia'; end if;
  if v_exec.status='PAUSED' then raise exception 'El corte está pausado. Reanúdalo antes de continuar.'; end if;
  if v_exec.status='WAITING_EVIDENCE' then raise exception 'El corte físico ya terminó. Sube la evidencia final.'; end if;

  v_result:=public.erp_x_resolve_cut_requirement_v1018(p_requirement_id,p_resolution,p_payload);
  select * into v_req from erp_supply.cut_requirements where id=p_requirement_id for update;
  v_batch:=v_req.cut_batch_id;
  if v_batch is not null then update erp_supply.cut_batches set execution_id=v_exec.id,metadata=metadata||jsonb_build_object('executionId',v_exec.id,'cutFlowVersion','10.20') where id=v_batch; end if;

  if v_req.process_status='READY' then
    update erp_supply.cut_requirements set process_status='IN_PROGRESS',ready_at=null,ready_by=null,metadata=metadata||jsonb_build_object('physicalComplete',true,'evidencePending',true,'executionId',v_exec.id,'cutFlowVersion','10.20'),updated_at=now() where id=v_req.id;
    update erp_supply.order_items set metadata=metadata||jsonb_build_object('cutStatus','WAITING_EVIDENCE','cutExecutionId',v_exec.id,'cutEvidencePending',true,'cutFlowVersion','10.20'),updated_at=now() where id=v_req.order_item_id and requires_cut;
  end if;

  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0)
  into v_remaining from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id;
  if v_remaining<=0 then update erp_supply.cut_executions set status='WAITING_EVIDENCE',updated_at=now(),metadata=metadata||jsonb_build_object('physicalCompletedAt',now(),'evidenceRequired',true) where id=v_exec.id; end if;
  return v_result||jsonb_build_object('executionId',v_exec.id,'groupRemainingLength',v_remaining,'groupCompleted',(v_remaining<=0),'waitingEvidence',(v_remaining<=0));
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. EVIDENCIA Y CIERRE
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_register_evidence(p_execution_id uuid,p_file_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_profile();v_exec erp_supply.cut_executions%rowtype;v_file erp_supply.drive_files%rowtype;begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;
  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El corte está asignado a otro usuario' using errcode='42501'; end if;
  if v_exec.status not in('WAITING_EVIDENCE','IN_PROGRESS') then raise exception 'La ejecución ya no acepta evidencia'; end if;
  if exists(select 1 from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id and coalesce(r.length_completed,0)<r.total_length-0.0001) then raise exception 'Todavía faltan cortes físicos por completar'; end if;
  select * into v_file from erp_supply.drive_files where id=p_file_id and organization_id=v_exec.organization_id and file_category='CUTTING_EVIDENCE';
  if not found then raise exception 'La foto cargada no corresponde a una evidencia de Corte'; end if;
  if not exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.order_id=v_file.order_id) then raise exception 'La evidencia no pertenece a un pedido de esta ejecución'; end if;
  update erp_supply.cut_executions set evidence_file_id=v_file.id,evidence_registered_at=now(),status='WAITING_EVIDENCE',updated_at=now(),metadata=metadata||jsonb_build_object('evidenceRegisteredBy',v_actor,'evidenceFileId',v_file.id) where id=v_exec.id;
  return public.erp_x_cutting_execution(v_exec.id);
end;$$;

create or replace function public.erp_x_cutting_finalize(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_exec erp_supply.cut_executions%rowtype;v_metrics jsonb;v_order uuid;
begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Ejecución de Corte no disponible'; end if;
  if v_exec.started_by<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'El corte está asignado a otro usuario' using errcode='42501'; end if;
  if v_exec.status='COMPLETED' then return jsonb_build_object('success',true,'executionId',v_exec.id,'alreadyCompleted',true,'metrics',erp_supply.cut_execution_metrics(v_exec.id)); end if;
  if v_exec.evidence_file_id is null then raise exception 'Debes subir la foto final del material cortado antes de cerrar Corte'; end if;
  if exists(select 1 from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id and coalesce(r.length_completed,0)<r.total_length-0.0001) then raise exception 'Todavía faltan cortes físicos por completar'; end if;

  update erp_supply.cut_execution_pauses set ended_at=coalesce(ended_at,now()),ended_by=coalesce(ended_by,v_actor) where execution_id=v_exec.id and ended_at is null;

  update erp_supply.cut_requirements r
  set process_status='READY',ready_at=now(),ready_by=v_actor,collection_status='PENDING',
      metadata=r.metadata||jsonb_build_object('evidenceClosed',true,'evidenceFileId',v_exec.evidence_file_id,'executionId',v_exec.id,'cutClosedAt',now(),'cutFlowVersion','10.20'),updated_at=now()
  where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.cut_requirement_id=r.id);

  update erp_supply.order_items i
  set metadata=i.metadata||jsonb_build_object('cutStatus','READY','cutExecutionId',v_exec.id,'cutEvidenceFileId',v_exec.evidence_file_id,'cutEvidencePending',false,'cutReadyAt',now(),'cutFlowVersion','10.20'),updated_at=now()
  where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.order_item_id=i.id) and i.requires_cut;

  update erp_supply.cut_executions set status='COMPLETED',completed_by=v_actor,completed_at=now(),updated_at=now() where id=v_exec.id returning * into v_exec;
  v_metrics:=erp_supply.cut_execution_metrics(v_exec.id);
  update erp_supply.cut_executions set metadata=metadata||jsonb_build_object('finalMetrics',v_metrics,'closedWithEvidence',true) where id=v_exec.id;

  for v_order in select distinct er.order_id from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id loop
    perform erp_supply.advance_cut_order_if_ready(v_order,v_actor);
    update erp_supply.orders o set metadata=jsonb_set(o.metadata,'{cutFlow}',((coalesce(o.metadata->'cutFlow','{}'::jsonb)-'waitingEvidence')||jsonb_build_object('cutExecutionId',v_exec.id,'evidenceFileId',v_exec.evidence_file_id,'executionCompletedAt',v_exec.completed_at,'executionMetrics',v_metrics)),true),updated_at=now() where o.id=v_order;
    insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
    values(v_exec.organization_id,v_order,'DOMAIN_RECORD','CUT_EXECUTION_COMPLETED','ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('executionId',v_exec.id,'groupKey',v_exec.group_key,'reference',v_exec.reference,'evidenceFileId',v_exec.evidence_file_id,'metrics',v_metrics));
  end loop;

  return jsonb_build_object('success',true,'executionId',v_exec.id,'completedAt',v_exec.completed_at,'metrics',v_metrics,'releasedToPicking',true);
end;$$;

-- Sandbox: registra una evidencia ficticia; nunca sube bytes a Drive.
create or replace function public.erp_x_sandbox_cutting_evidence(p_execution_id uuid,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_exec erp_supply.cut_executions%rowtype;v_order uuid;v_file erp_supply.drive_files%rowtype;begin
  select * into v_exec from erp_supply.cut_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Ejecución Sandbox no disponible'; end if;
  select er.order_id into v_order from erp_supply.cut_execution_requirements er join erp_supply.orders o on o.id=er.order_id where er.execution_id=v_exec.id and o.is_test order by er.created_at limit 1;
  if v_order is null then raise exception 'La ejecución no es Sandbox'; end if;
  insert into erp_supply.drive_files(organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,size_bytes,uploaded_by,metadata)
  values(v_exec.organization_id,v_order,null,'CUTTING_EVIDENCE','SANDBOX-CUT-'||gen_random_uuid()::text,coalesce(nullif(trim(p_payload->>'fileName'),''),'foto-corte-sandbox.jpg'),coalesce(nullif(trim(p_payload->>'mimeType'),''),'image/jpeg'),coalesce(erp_supply.safe_integer(p_payload->>'sizeBytes'),0),v_actor,jsonb_build_object('sandbox',true,'bytesUploaded',false,'executionId',v_exec.id)) returning * into v_file;
  update erp_supply.cut_executions set evidence_file_id=v_file.id,evidence_registered_at=now(),status='WAITING_EVIDENCE',updated_at=now() where id=v_exec.id;
  return public.erp_x_cutting_execution(v_exec.id);
end;$$;

-- Sandbox: la ejecución física antigua también queda retenida hasta evidencia.
do $$
begin
  if to_regprocedure('public.erp_x_sandbox_execute_cut_group_v10162(text,jsonb)') is null
     and to_regprocedure('public.erp_x_sandbox_execute_cut_group(text,jsonb)') is not null then
    execute 'alter function public.erp_x_sandbox_execute_cut_group(text,jsonb) rename to erp_x_sandbox_execute_cut_group_v10162';
  end if;
  if to_regprocedure('public.erp_x_sandbox_resolve_cut_requirement_v10162(uuid,text,jsonb)') is null
     and to_regprocedure('public.erp_x_sandbox_resolve_cut_requirement(uuid,text,jsonb)') is not null then
    execute 'alter function public.erp_x_sandbox_resolve_cut_requirement(uuid,text,jsonb) rename to erp_x_sandbox_resolve_cut_requirement_v10162';
  end if;
end $$;

revoke all on function public.erp_x_sandbox_execute_cut_group_v10162(text,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_sandbox_resolve_cut_requirement_v10162(uuid,text,jsonb) from public,anon,authenticated;

create or replace function public.erp_x_sandbox_execute_cut_group(p_group_key text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_exec erp_supply.cut_executions%rowtype;v_result jsonb;begin
  select * into v_exec from erp_supply.cut_executions where organization_id=erp_supply.current_org_id() and group_key=p_group_key and status='IN_PROGRESS' order by started_at desc limit 1 for update;
  if not found then raise exception 'Primero inicia el corte Sandbox'; end if;
  v_result:=public.erp_x_sandbox_execute_cut_group_v10162(p_group_key,p_payload);
  update erp_supply.cut_requirements r set process_status='IN_PROGRESS',ready_at=null,ready_by=null,metadata=metadata||jsonb_build_object('physicalComplete',true,'evidencePending',true,'executionId',v_exec.id) where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.cut_requirement_id=r.id);
  update erp_supply.order_items i set metadata=metadata||jsonb_build_object('sandboxCutStatus','WAITING_EVIDENCE','cutExecutionId',v_exec.id) where exists(select 1 from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.order_item_id=i.id);
  update erp_supply.cut_executions set status='WAITING_EVIDENCE',updated_at=now(),metadata=metadata||jsonb_build_object('physicalCompletedAt',now(),'evidenceRequired',true) where id=v_exec.id;
  return v_result||jsonb_build_object('executionId',v_exec.id,'groupCompleted',true,'waitingEvidence',true,'groupRemainingLength',0);
end;$$;

create or replace function public.erp_x_sandbox_resolve_cut_requirement(p_requirement_id uuid,p_resolution text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_exec erp_supply.cut_executions%rowtype;v_result jsonb;v_remaining numeric;v_item_id uuid;begin
  select e.* into v_exec from erp_supply.cut_executions e join erp_supply.cut_execution_requirements er on er.execution_id=e.id where er.cut_requirement_id=p_requirement_id and e.organization_id=erp_supply.current_org_id() and e.status='IN_PROGRESS' limit 1 for update of e;
  if not found then raise exception 'Primero inicia el corte Sandbox'; end if;
  select er.order_item_id into v_item_id from erp_supply.cut_execution_requirements er where er.execution_id=v_exec.id and er.cut_requirement_id=p_requirement_id limit 1;
  if v_item_id is null then raise exception 'Línea Sandbox no disponible'; end if;
  v_result:=public.erp_x_sandbox_resolve_cut_requirement_v10162(v_item_id,p_resolution,p_payload);
  update erp_supply.cut_requirements set process_status='IN_PROGRESS',units_completed=units_required,length_completed=total_length,resolution_code=upper(p_resolution),ready_at=null,ready_by=null,metadata=metadata||jsonb_build_object('physicalComplete',true,'evidencePending',true,'executionId',v_exec.id) where id=p_requirement_id;
  update erp_supply.order_items set metadata=metadata||jsonb_build_object('sandboxCutStatus','WAITING_EVIDENCE','cutExecutionId',v_exec.id) where id=v_item_id;
  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) into v_remaining from erp_supply.cut_execution_requirements er join erp_supply.cut_requirements r on r.id=er.cut_requirement_id where er.execution_id=v_exec.id;
  if v_remaining<=0 then update erp_supply.cut_executions set status='WAITING_EVIDENCE',updated_at=now(),metadata=metadata||jsonb_build_object('physicalCompletedAt',now(),'evidenceRequired',true) where id=v_exec.id; end if;
  return v_result||jsonb_build_object('executionId',v_exec.id,'groupRemainingLength',v_remaining,'groupCompleted',(v_remaining<=0),'waitingEvidence',(v_remaining<=0));
end;$$;

-- Sandbox: lista de Corte con estado de ejecución y tiempo, sin mezclar producción.
create or replace function public.erp_x_sandbox_cutting_work(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  with q as(
    select i.id
    from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id
    where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false)
      and i.requires_cut and coalesce(i.metadata->>'sandboxCutStatus','PENDING')<>'READY'
      and (p_search is null or p_search='' or lower(coalesce(i.reference,'')||' '||coalesce(i.sku,'')||' '||i.description) like '%'||lower(p_search)||'%')
  ) select count(*) into v_total from q;

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from(
    select 'SBX:'||i.id::text "groupKey",i.reference,i.sku,i.description,null::uuid "materialMasterId",null::uuid "materialVariantId",null::text "variantLabel",
      1 "itemCount",1 "orderCount",
      case when e.status='WAITING_EVIDENCE' then 0 else i.quantity end "cutCount",
      case when e.status='WAITING_EVIDENCE' then 0 else round((i.quantity*coalesce(i.requested_cut_length,1))::numeric,4) end "totalLength",
      case when e.id is not null then round((i.quantity*coalesce(i.requested_cut_length,1))::numeric,4) else 0 end "completedLength",
      i.created_at "oldestAt",(e.id is not null) "inProgress",e.status "executionStatus",e.id "executionId",
      coalesce((erp_supply.cut_execution_metrics(e.id)->>'businessSeconds')::bigint,0) "elapsedSeconds"
    from erp_supply.order_items i
    join erp_supply.orders o on o.id=i.order_id
    left join erp_supply.cut_executions e on e.organization_id=v_org and e.group_key='SBX:'||i.id::text and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
    where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false)
      and i.requires_cut and coalesce(i.metadata->>'sandboxCutStatus','PENDING')<>'READY'
      and (p_search is null or p_search='' or lower(coalesce(i.reference,'')||' '||coalesce(i.sku,'')||' '||i.description) like '%'||lower(p_search)||'%')
    order by case e.status when 'WAITING_EVIDENCE' then 1 when 'IN_PROGRESS' then 2 when 'PAUSED' then 3 else 4 end,i.created_at
    offset(v_page-1)*v_size limit v_size
  )x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),'sandbox',true);
end;$$;

-- ---------------------------------------------------------------------------
-- 9. PERMISOS Y CACHÉ
-- ---------------------------------------------------------------------------

revoke all on function public.erp_x_cutting_start(text) from public,anon;
revoke all on function public.erp_x_cutting_pause(uuid,text) from public,anon;
revoke all on function public.erp_x_cutting_resume(uuid) from public,anon;
revoke all on function public.erp_x_cutting_execution(uuid) from public,anon;
revoke all on function public.erp_x_cutting_active_execution(text) from public,anon;
revoke all on function public.erp_x_cutting_work(text,integer,integer) from public,anon;
revoke all on function public.erp_x_cutting_execution_plan(uuid,uuid,numeric,numeric) from public,anon;
revoke all on function public.erp_x_cutting_register_evidence(uuid,uuid) from public,anon;
revoke all on function public.erp_x_cutting_finalize(uuid) from public,anon;
revoke all on function public.erp_x_sandbox_cutting_evidence(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_sandbox_cutting_work(text,integer,integer) from public,anon;

grant execute on function public.erp_x_cutting_start(text) to authenticated;
grant execute on function public.erp_x_cutting_pause(uuid,text) to authenticated;
grant execute on function public.erp_x_cutting_resume(uuid) to authenticated;
grant execute on function public.erp_x_cutting_execution(uuid) to authenticated;
grant execute on function public.erp_x_cutting_active_execution(text) to authenticated;
grant execute on function public.erp_x_cutting_work(text,integer,integer) to authenticated;
grant execute on function public.erp_x_cutting_execution_plan(uuid,uuid,numeric,numeric) to authenticated;
grant execute on function public.erp_x_cutting_register_evidence(uuid,uuid) to authenticated;
grant execute on function public.erp_x_cutting_finalize(uuid) to authenticated;
grant execute on function public.erp_x_sandbox_cutting_evidence(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_sandbox_cutting_work(text,integer,integer) to authenticated;
grant execute on function public.erp_x_execute_cut_group(text,jsonb) to authenticated;
grant execute on function public.erp_x_resolve_cut_requirement(uuid,text,jsonb) to authenticated;
grant execute on function public.erp_x_sandbox_execute_cut_group(text,jsonb) to authenticated;
grant execute on function public.erp_x_sandbox_resolve_cut_requirement(uuid,text,jsonb) to authenticated;

-- Verificaciones mínimas de instalación.
do $$
begin
  if to_regclass('erp_supply.cut_executions') is null then raise exception 'No se creó cut_executions'; end if;
  if to_regclass('erp_supply.cut_execution_requirements') is null then raise exception 'No se creó cut_execution_requirements'; end if;
  if to_regprocedure('public.erp_x_cutting_start(text)') is null then raise exception 'Falta erp_x_cutting_start'; end if;
  if to_regprocedure('public.erp_x_cutting_finalize(uuid)') is null then raise exception 'Falta erp_x_cutting_finalize'; end if;
end $$;

notify pgrst,'reload schema';
commit;
