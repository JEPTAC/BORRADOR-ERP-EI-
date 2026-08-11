-- ERP EI V10.23.0
-- API transaccional de Mi Jornada: cronómetro, pausas, evidencias,
-- planificación por equipo, recurrencias y entregables con aceptación.

begin;

-- ---------------------------------------------------------------------------
-- 1. REGLAS DE ACCESO Y MÉTRICAS
-- ---------------------------------------------------------------------------
create or replace function erp_supply.work_catalog_allowed(
  p_catalog_id uuid,
  p_profile_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select exists(
    select 1
    from erp_supply.work_activity_catalog c
    join erp_supply.profiles p on p.id=coalesce(p_profile_id,erp_supply.current_profile_id())
    where c.id=p_catalog_id
      and c.organization_id=p.organization_id
      and c.active
      and (
        coalesce(array_length(c.allowed_roles,1),0)=0
        or exists(
          select 1 from erp_supply.profile_roles pr
          where pr.profile_id=p.id and pr.role_code=any(c.allowed_roles)
        )
      )
  )
$$;

revoke all on function erp_supply.work_catalog_allowed(uuid,uuid) from public;

create or replace function erp_supply.can_manage_work_profile(
  p_profile_id uuid,
  p_assignment_kind text default 'ACTIVITY'
)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select
    erp_supply.has_role('super_admin')
    or (
      erp_supply.has_role('jefe_logistica')
      and upper(coalesce(p_assignment_kind,'ACTIVITY'))='ACTIVITY'
      and exists(
        select 1 from erp_supply.profile_roles pr
        where pr.profile_id=p_profile_id
          and pr.role_code=any(array[
            'jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte',
            'recepcion_mercancia','despacho_nacional'
          ]::text[])
      )
    )
    or (
      erp_supply.has_role('gerencia')
      and upper(coalesce(p_assignment_kind,'DELIVERABLE'))='DELIVERABLE'
      and exists(
        select 1 from erp_supply.profile_roles pr
        where pr.profile_id=p_profile_id
          and pr.role_code=any(array['ventas','jefe_logistica','compras','cartera']::text[])
      )
    )
$$;

revoke all on function erp_supply.can_manage_work_profile(uuid,text) from public;

create or replace function erp_supply.work_execution_metrics(p_execution_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_exec erp_supply.work_executions%rowtype;
  v_end timestamptz;
  v_elapsed bigint:=0;
  v_pause bigint:=0;
  v_pause_business bigint:=0;
  v_business bigint:=0;
  v_active bigint:=0;
begin
  select * into v_exec from erp_supply.work_executions where id=p_execution_id;
  if not found then return '{}'::jsonb; end if;

  v_end:=coalesce(v_exec.ended_at,now());
  v_elapsed:=greatest(0,extract(epoch from(v_end-v_exec.started_at))::bigint);

  select
    coalesce(sum(greatest(0,extract(epoch from(coalesce(p.ended_at,v_end)-p.started_at))::bigint)),0),
    coalesce(sum(erp_supply.business_seconds_between(
      v_exec.organization_id,
      p.started_at,
      least(coalesce(p.ended_at,v_end),v_end)
    )),0)
  into v_pause,v_pause_business
  from erp_supply.work_execution_pauses p
  where p.execution_id=v_exec.id and p.started_at<v_end;

  v_business:=greatest(0,erp_supply.business_seconds_between(v_exec.organization_id,v_exec.started_at,v_end)-v_pause_business);
  v_active:=greatest(0,v_elapsed-v_pause);

  return jsonb_build_object(
    'elapsedSeconds',v_elapsed,
    'pausedSeconds',v_pause,
    'activeSeconds',v_active,
    'businessSeconds',v_business,
    'endedAt',v_end
  );
end;
$$;

revoke all on function erp_supply.work_execution_metrics(uuid) from public;

create or replace function erp_supply.work_evidence_complete(p_execution_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_policy text;
begin
  select coalesce(a.evidence_policy,c.evidence_policy,'NONE')
  into v_policy
  from erp_supply.work_executions e
  join erp_supply.work_activity_catalog c on c.id=e.catalog_id
  left join erp_supply.work_assignments a on a.id=e.assignment_id
  where e.id=p_execution_id;

  if v_policy is null then return false; end if;
  if v_policy='NONE' then return true; end if;
  if v_policy='FINAL_PHOTO' then
    return exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type in('FINAL_PHOTO','AFTER_PHOTO'));
  end if;
  if v_policy='BEFORE_AFTER' then
    return exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type='BEFORE_PHOTO')
       and exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type='AFTER_PHOTO');
  end if;
  if v_policy='FILE' then
    return exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type='FILE');
  end if;
  if v_policy='LINK' then
    return exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type='LINK' and nullif(trim(external_value),'') is not null);
  end if;
  if v_policy='ERP_REFERENCE' then
    return exists(select 1 from erp_supply.work_evidence where execution_id=p_execution_id and evidence_type='ERP_REFERENCE' and nullif(trim(external_value),'') is not null);
  end if;
  return false;
end;
$$;

revoke all on function erp_supply.work_evidence_complete(uuid) from public;

create or replace function erp_supply.sync_work_execution_completion(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_exec erp_supply.work_executions%rowtype;
  v_assignment erp_supply.work_assignments%rowtype;
  v_catalog erp_supply.work_activity_catalog%rowtype;
  v_evidence_ok boolean:=false;
  v_acceptance boolean:=false;
  v_status text;
begin
  select * into v_exec from erp_supply.work_executions where id=p_execution_id for update;
  if not found then raise exception 'Actividad no disponible'; end if;
  if v_exec.ended_at is null then return jsonb_build_object('status',v_exec.status,'evidenceComplete',false); end if;
  if v_exec.status in('RETURNED','CANCELLED') then return jsonb_build_object('status',v_exec.status,'evidenceComplete',false); end if;

  select * into v_catalog from erp_supply.work_activity_catalog where id=v_exec.catalog_id;
  if v_exec.assignment_id is not null then select * into v_assignment from erp_supply.work_assignments where id=v_exec.assignment_id; end if;

  v_evidence_ok:=erp_supply.work_evidence_complete(v_exec.id);
  v_acceptance:=coalesce(v_assignment.acceptance_required,v_catalog.acceptance_required,false);
  v_status:=case when not v_evidence_ok then 'WAITING_EVIDENCE' when v_acceptance then 'SUBMITTED' else 'COMPLETED' end;

  update erp_supply.work_executions set status=v_status where id=v_exec.id;
  if v_exec.assignment_member_id is not null then
    update erp_supply.work_assignment_members
    set status=case when v_status='WAITING_EVIDENCE' then 'WAITING_EVIDENCE' when v_status='SUBMITTED' then 'SUBMITTED' else 'COMPLETED' end,
        submitted_at=case when v_status='SUBMITTED' then coalesce(submitted_at,now()) else submitted_at end,
        completed_at=case when v_status='COMPLETED' then coalesce(completed_at,now()) else completed_at end
    where id=v_exec.assignment_member_id;
  end if;

  return jsonb_build_object('status',v_status,'evidenceComplete',v_evidence_ok,'acceptanceRequired',v_acceptance);
end;
$$;

revoke all on function erp_supply.sync_work_execution_completion(uuid) from public;

-- ---------------------------------------------------------------------------
-- 2. CATÁLOGO Y MI JORNADA
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_catalog()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
begin
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x."sortOrder",x.name)
    from(
      select
        c.id,c.code,c.name,c.description,c.activity_group "activityGroup",c.activity_kind "activityKind",
        c.standard_minutes "standardMinutes",c.evidence_policy "evidencePolicy",
        c.acceptance_required "acceptanceRequired",c.team_allowed "teamAllowed",c.sort_order "sortOrder",
        h.samples,
        h."medianMinutes",
        h."p80Minutes"
      from erp_supply.work_activity_catalog c
      left join lateral(
        select
          count(*)::integer samples,
          round((percentile_cont(.5) within group(order by e.active_seconds)/60.0)::numeric,1) "medianMinutes",
          round((percentile_cont(.8) within group(order by e.active_seconds)/60.0)::numeric,1) "p80Minutes"
        from erp_supply.work_executions e
        where e.catalog_id=c.id and e.status='COMPLETED' and e.active_seconds>0
      ) h on true
      where c.organization_id=v_org and c.active and (
        erp_supply.work_catalog_allowed(c.id,v_actor)
        or erp_supply.has_role('super_admin')
        or (erp_supply.has_role('gerencia') and c.activity_kind='DELIVERABLE')
        or (erp_supply.has_role('jefe_logistica') and c.activity_kind='ACTIVITY' and c.activity_group in('LOGISTICS','IMPROVEMENT','GENERAL'))
      )
    ) x
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.erp_x_work_catalog() from public,anon;
grant execute on function public.erp_x_work_catalog() to authenticated;

create or replace function public.erp_x_work_my_day(p_day date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_tz text:=coalesce((select timezone from erp_supply.organizations where id=v_org),'America/Bogota');
  v_day date:=coalesce(p_day,current_date);
  v_start timestamptz:=(v_day::timestamp at time zone v_tz);
  v_end timestamptz:=((v_day+1)::timestamp at time zone v_tz);
  v_active jsonb;
begin
  select to_jsonb(x) into v_active from(
    select e.id,e.status,e.source,e.title_snapshot "title",e.started_at "startedAt",e.ended_at "endedAt",
           e.assignment_id "assignmentId",e.catalog_id "catalogId",c.name "catalogName",
           coalesce(a.evidence_policy,c.evidence_policy) "evidencePolicy",
           coalesce(a.estimated_minutes,c.standard_minutes) "estimatedMinutes",
           a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",
           erp_supply.work_execution_metrics(e.id) metrics,
           (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'type',w.evidence_type,'fileName',w.file_name,'webViewLink',w.web_view_link,'value',w.external_value,'createdAt',w.created_at) order by w.created_at),'[]'::jsonb) from erp_supply.work_evidence w where w.execution_id=e.id) evidence
    from erp_supply.work_executions e
    join erp_supply.work_activity_catalog c on c.id=e.catalog_id
    left join erp_supply.work_assignments a on a.id=e.assignment_id
    where e.profile_id=v_actor and e.status in('IN_PROGRESS','PAUSED')
    order by e.started_at desc limit 1
  ) x;

  return jsonb_build_object(
    'day',v_day,
    'active',v_active,
    'catalog',public.erp_x_work_catalog(),
    'today',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."plannedStart" nulls last,x."dueAt" nulls last,x.priority),'[]'::jsonb)
      from(
        select a.id,m.id "memberId",a.title,a.description,a.assignment_kind "kind",a.priority,
               a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",
               a.estimated_minutes "estimatedMinutes",a.evidence_policy "evidencePolicy",a.acceptance_required "acceptanceRequired",
               m.status "memberStatus",c.name "catalogName",c.code "catalogCode",c.id "catalogId",
               a.related_entity_type "relatedEntityType",a.related_entity_id "relatedEntityId"
        from erp_supply.work_assignment_members m
        join erp_supply.work_assignments a on a.id=m.assignment_id
        left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED'
          and m.status not in('COMPLETED','CANCELLED')
          and (
            (a.planned_start>=v_start and a.planned_start<v_end)
            or (a.planned_start is null and a.due_at>=v_start and a.due_at<v_end)
          )
      ) x
    ),
    'overdue',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."dueAt"),'[]'::jsonb)
      from(
        select a.id,m.id "memberId",a.title,a.assignment_kind "kind",a.priority,a.due_at "dueAt",a.estimated_minutes "estimatedMinutes",
               m.status "memberStatus",c.name "catalogName",c.id "catalogId",a.evidence_policy "evidencePolicy"
        from erp_supply.work_assignment_members m
        join erp_supply.work_assignments a on a.id=m.assignment_id
        left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED'
          and m.status not in('COMPLETED','CANCELLED','SUBMITTED') and a.due_at<v_start
      ) x
    ),
    'upcoming',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."nextAt"),'[]'::jsonb)
      from(
        select a.id,a.title,a.assignment_kind "kind",a.priority,a.planned_start "plannedStart",a.due_at "dueAt",
               coalesce(a.planned_start,a.due_at) "nextAt",m.status "memberStatus",c.name "catalogName"
        from erp_supply.work_assignment_members m
        join erp_supply.work_assignments a on a.id=m.assignment_id
        left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED'
          and m.status not in('COMPLETED','CANCELLED')
          and coalesce(a.planned_start,a.due_at)>=v_end
          and coalesce(a.planned_start,a.due_at)<v_end+interval '7 days'
        order by coalesce(a.planned_start,a.due_at) limit 12
      ) x
    ),
    'history',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."startedAt" desc),'[]'::jsonb)
      from(
        select e.id,e.title_snapshot "title",e.status,e.started_at "startedAt",e.ended_at "endedAt",
               e.active_seconds "activeSeconds",e.business_seconds "businessSeconds",e.paused_seconds "pausedSeconds",
               c.name "catalogName",c.activity_group "activityGroup",e.result_note "resultNote",
               coalesce(a.evidence_policy,c.evidence_policy) "evidencePolicy",
               coalesce(a.acceptance_required,c.acceptance_required,false) "acceptanceRequired",
               (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'type',w.evidence_type,'fileName',w.file_name,'webViewLink',w.web_view_link,'value',w.external_value,'createdAt',w.created_at) order by w.created_at),'[]'::jsonb) from erp_supply.work_evidence w where w.execution_id=e.id) evidence
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        left join erp_supply.work_assignments a on a.id=e.assignment_id
        where e.profile_id=v_actor and e.started_at>=v_start and e.started_at<v_end
        order by e.started_at desc limit 30
      ) x
    ),
    'summary',jsonb_build_object(
      'completed',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='COMPLETED' and e.ended_at>=v_start and e.ended_at<v_end),
      'activeSeconds',(select coalesce(sum(e.active_seconds),0) from erp_supply.work_executions e where e.profile_id=v_actor and e.ended_at>=v_start and e.ended_at<v_end and e.status in('COMPLETED','SUBMITTED','WAITING_EVIDENCE')),
      'plannedMinutes',(select coalesce(sum(a.estimated_minutes),0) from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id where m.profile_id=v_actor and a.status='PUBLISHED' and a.planned_start>=v_start and a.planned_start<v_end),
      'pendingEvidence',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='WAITING_EVIDENCE'),
      'pendingReview',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='SUBMITTED')
    ),
    'permissions',jsonb_build_object(
      'canPlanLogistics',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin'),
      'canPlanDeliverables',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'canViewTeam',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')
    ),
    'serverTime',now(),
    'version','10.23.0'
  );
end;
$$;

revoke all on function public.erp_x_work_my_day(date) from public,anon;
grant execute on function public.erp_x_work_my_day(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. CRONÓMETRO PERSONAL
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_start(
  p_catalog_id uuid,
  p_assignment_id uuid default null,
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
  v_catalog erp_supply.work_activity_catalog%rowtype;
  v_assignment erp_supply.work_assignments%rowtype;
  v_member erp_supply.work_assignment_members%rowtype;
  v_exec erp_supply.work_executions%rowtype;
  v_title text;
  v_delay bigint:=0;
begin
  if exists(select 1 from erp_supply.work_executions where profile_id=v_actor and status in('IN_PROGRESS','PAUSED')) then
    raise exception 'Ya tienes una actividad cronometrada. Finalízala antes de iniciar otra.';
  end if;

  select * into v_catalog from erp_supply.work_activity_catalog
  where id=p_catalog_id and organization_id=v_org and active;
  if not found or not erp_supply.work_catalog_allowed(p_catalog_id,v_actor) then
    raise exception 'Actividad no disponible para tu perfil' using errcode='42501';
  end if;

  if p_assignment_id is not null then
    select * into v_assignment from erp_supply.work_assignments
    where id=p_assignment_id and organization_id=v_org and status='PUBLISHED' for update;
    if not found then raise exception 'La actividad programada ya no está disponible'; end if;
    select * into v_member from erp_supply.work_assignment_members
    where assignment_id=v_assignment.id and profile_id=v_actor for update;
    if not found then raise exception 'Esta actividad no está asignada a tu perfil' using errcode='42501'; end if;
    if v_member.status in('COMPLETED','CANCELLED') then raise exception 'Esta actividad ya fue cerrada'; end if;
    if v_assignment.catalog_id is not null and v_assignment.catalog_id<>p_catalog_id then raise exception 'El tipo de actividad no coincide con la programación'; end if;
    v_title:=v_assignment.title;
    if v_assignment.planned_start is not null then v_delay:=abs(extract(epoch from(now()-v_assignment.planned_start))::bigint); end if;
  else
    v_title:=coalesce(nullif(trim(p_payload->>'title'),''),v_catalog.name);
  end if;

  insert into erp_supply.work_executions(
    organization_id,assignment_id,assignment_member_id,catalog_id,profile_id,source,status,title_snapshot,
    started_at,start_delay_seconds,related_entity_type,related_entity_id,metadata
  ) values(
    v_org,p_assignment_id,case when p_assignment_id is null then null else v_member.id end,
    v_catalog.id,v_actor,case when p_assignment_id is null then 'MANUAL' else 'PLANNED' end,'IN_PROGRESS',v_title,
    now(),v_delay,nullif(trim(p_payload->>'relatedEntityType'),''),nullif(trim(p_payload->>'relatedEntityId'),''),
    jsonb_build_object('startedVersion','10.23.0','startNote',nullif(trim(p_payload->>'note'),''))
  ) returning * into v_exec;

  if p_assignment_id is not null then
    update erp_supply.work_assignment_members
    set status='IN_PROGRESS',first_started_at=coalesce(first_started_at,now())
    where id=v_member.id;
  end if;

  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_org,v_exec.id,p_assignment_id,v_actor,v_actor,'STARTED',jsonb_build_object('title',v_title,'catalogId',v_catalog.id,'version','10.23.0'));

  return jsonb_build_object('success',true,'executionId',v_exec.id,'status',v_exec.status,'startedAt',v_exec.started_at,'title',v_title);
end;
$$;

revoke all on function public.erp_x_work_start(uuid,uuid,jsonb) from public,anon;
grant execute on function public.erp_x_work_start(uuid,uuid,jsonb) to authenticated;

create or replace function public.erp_x_work_pause(
  p_execution_id uuid,
  p_reason_code text default 'OTHER',
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.work_executions%rowtype;
begin
  select * into v_exec from erp_supply.work_executions
  where id=p_execution_id and profile_id=v_actor and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Actividad no disponible'; end if;
  if v_exec.status<>'IN_PROGRESS' then raise exception 'Solo una actividad en ejecución puede pausarse'; end if;

  insert into erp_supply.work_execution_pauses(execution_id,reason_code,note,created_by)
  values(v_exec.id,upper(coalesce(nullif(trim(p_reason_code),''),'OTHER')),nullif(trim(p_note),''),v_actor);
  update erp_supply.work_executions set status='PAUSED' where id=v_exec.id;
  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_exec.organization_id,v_exec.id,v_exec.assignment_id,v_actor,v_actor,'PAUSED',jsonb_build_object('reasonCode',p_reason_code,'note',p_note));
  return jsonb_build_object('success',true,'status','PAUSED','metrics',erp_supply.work_execution_metrics(v_exec.id));
end;
$$;

revoke all on function public.erp_x_work_pause(uuid,text,text) from public,anon;
grant execute on function public.erp_x_work_pause(uuid,text,text) to authenticated;

create or replace function public.erp_x_work_resume(p_execution_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.work_executions%rowtype;
begin
  select * into v_exec from erp_supply.work_executions
  where id=p_execution_id and profile_id=v_actor and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Actividad no disponible'; end if;
  if v_exec.status<>'PAUSED' then raise exception 'La actividad no está pausada'; end if;

  update erp_supply.work_execution_pauses set ended_at=now(),ended_by=v_actor
  where execution_id=v_exec.id and ended_at is null;
  update erp_supply.work_executions set status='IN_PROGRESS' where id=v_exec.id;
  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_exec.organization_id,v_exec.id,v_exec.assignment_id,v_actor,v_actor,'RESUMED','{}'::jsonb);
  return jsonb_build_object('success',true,'status','IN_PROGRESS','metrics',erp_supply.work_execution_metrics(v_exec.id));
end;
$$;

revoke all on function public.erp_x_work_resume(uuid) from public,anon;
grant execute on function public.erp_x_work_resume(uuid) to authenticated;

create or replace function public.erp_x_work_finish(
  p_execution_id uuid,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.work_executions%rowtype;
  v_metrics jsonb;
  v_estimated integer;
  v_ratio numeric;
  v_sync jsonb;
begin
  select * into v_exec from erp_supply.work_executions
  where id=p_execution_id and profile_id=v_actor and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Actividad no disponible'; end if;
  if v_exec.status not in('IN_PROGRESS','PAUSED') then raise exception 'La actividad ya fue finalizada'; end if;
  if coalesce((
    select coalesce(a.evidence_policy,c.evidence_policy)
    from erp_supply.work_activity_catalog c
    left join erp_supply.work_assignments a on a.id=v_exec.assignment_id
    where c.id=v_exec.catalog_id
  ),'NONE')='BEFORE_AFTER' and not exists(
    select 1 from erp_supply.work_evidence w where w.execution_id=v_exec.id and w.evidence_type='BEFORE_PHOTO'
  ) then
    raise exception 'Debes tomar la foto inicial antes de finalizar la actividad';
  end if;

  update erp_supply.work_execution_pauses set ended_at=now(),ended_by=v_actor
  where execution_id=v_exec.id and ended_at is null;
  update erp_supply.work_executions set ended_at=now() where id=v_exec.id;

  v_metrics:=erp_supply.work_execution_metrics(v_exec.id);
  select coalesce(a.estimated_minutes,c.standard_minutes) into v_estimated
  from erp_supply.work_executions e
  join erp_supply.work_activity_catalog c on c.id=e.catalog_id
  left join erp_supply.work_assignments a on a.id=e.assignment_id
  where e.id=v_exec.id;
  if coalesce(v_estimated,0)>0 then
    v_ratio:=round(((v_metrics->>'activeSeconds')::numeric/(v_estimated*60.0))::numeric,4);
  end if;

  update erp_supply.work_executions
  set elapsed_seconds=coalesce((v_metrics->>'elapsedSeconds')::bigint,0),
      active_seconds=coalesce((v_metrics->>'activeSeconds')::bigint,0),
      business_seconds=coalesce((v_metrics->>'businessSeconds')::bigint,0),
      paused_seconds=coalesce((v_metrics->>'pausedSeconds')::bigint,0),
      deviation_ratio=v_ratio,
      deviation_reason=nullif(trim(p_payload->>'deviationReason'),''),
      result_note=nullif(trim(p_payload->>'resultNote'),''),
      metadata=metadata||jsonb_build_object('finishedVersion','10.23.0','finishedAt',now())
  where id=v_exec.id;

  v_sync:=erp_supply.sync_work_execution_completion(v_exec.id);
  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_exec.organization_id,v_exec.id,v_exec.assignment_id,v_actor,v_actor,'FINISHED',jsonb_build_object('metrics',v_metrics,'completion',v_sync,'deviationReason',p_payload->>'deviationReason'));

  return jsonb_build_object('success',true,'executionId',v_exec.id,'metrics',v_metrics,'completion',v_sync);
end;
$$;

revoke all on function public.erp_x_work_finish(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_work_finish(uuid,jsonb) to authenticated;

create or replace function public.erp_x_work_register_evidence(
  p_execution_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.work_executions%rowtype;
  v_type text:=upper(trim(coalesce(p_payload->>'evidenceType','')));
  v_evidence erp_supply.work_evidence%rowtype;
  v_sync jsonb;
begin
  select * into v_exec from erp_supply.work_executions
  where id=p_execution_id and profile_id=v_actor and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Actividad no disponible'; end if;
  if v_exec.status in('CANCELLED','RETURNED') then raise exception 'La ejecución no acepta nuevas evidencias'; end if;
  if v_type not in('BEFORE_PHOTO','AFTER_PHOTO','FINAL_PHOTO','FILE','LINK','ERP_REFERENCE') then raise exception 'Tipo de evidencia inválido'; end if;
  if v_type='BEFORE_PHOTO' and v_exec.ended_at is not null then raise exception 'La foto inicial debe tomarse antes de finalizar la actividad'; end if;
  if v_type in('AFTER_PHOTO','FINAL_PHOTO') and v_exec.ended_at is null then raise exception 'La foto final se anexa al terminar la actividad'; end if;
  if v_type in('LINK','ERP_REFERENCE') and nullif(trim(p_payload->>'externalValue'),'') is null then raise exception 'Debe registrar el enlace o referencia'; end if;
  if v_type in('BEFORE_PHOTO','AFTER_PHOTO','FINAL_PHOTO','FILE') and nullif(trim(p_payload->>'driveFileId'),'') is null then raise exception 'No se recibió el archivo de evidencia'; end if;

  insert into erp_supply.work_evidence(
    organization_id,execution_id,profile_id,evidence_type,drive_file_id,file_name,mime_type,size_bytes,
    web_view_link,external_value,note,metadata
  ) values(
    v_exec.organization_id,v_exec.id,v_actor,v_type,nullif(trim(p_payload->>'driveFileId'),''),
    nullif(trim(p_payload->>'fileName'),''),nullif(trim(p_payload->>'mimeType'),''),
    erp_supply.safe_numeric(p_payload->>'sizeBytes')::bigint,nullif(trim(p_payload->>'webViewLink'),''),
    nullif(trim(p_payload->>'externalValue'),''),nullif(trim(p_payload->>'note'),''),
    coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('version','10.23.0')
  ) returning * into v_evidence;

  if v_exec.ended_at is not null then v_sync:=erp_supply.sync_work_execution_completion(v_exec.id); else v_sync:=jsonb_build_object('status',v_exec.status); end if;
  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_exec.organization_id,v_exec.id,v_exec.assignment_id,v_actor,v_actor,'EVIDENCE_ADDED',jsonb_build_object('evidenceId',v_evidence.id,'evidenceType',v_type));

  return jsonb_build_object('success',true,'evidenceId',v_evidence.id,'completion',v_sync);
end;
$$;

revoke all on function public.erp_x_work_register_evidence(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_work_register_evidence(uuid,jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. EQUIPO Y PLANIFICACIÓN
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_people(p_assignment_kind text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_kind text:=upper(nullif(trim(coalesce(p_assignment_kind,'')),''));
begin
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria')) then
    raise exception 'No tienes permisos para consultar el equipo' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.name)
    from(
      select p.id,p.display_name name,p.email,p.employee_code "employeeCode",
             array_agg(distinct pr.role_code order by pr.role_code) roles,
             ae.title_snapshot "activeTitle",ae.started_at "activeStartedAt",
             coalesce(load7.planned_minutes,0) "plannedMinutes7d"
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      left join lateral(
        select e.title_snapshot,e.started_at from erp_supply.work_executions e
        where e.profile_id=p.id and e.status in('IN_PROGRESS','PAUSED') order by e.started_at desc limit 1
      ) ae on true
      left join lateral(
        select coalesce(sum(a.estimated_minutes),0)::bigint planned_minutes
        from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id
        where m.profile_id=p.id and a.status='PUBLISHED' and coalesce(a.planned_start,a.due_at)>=now() and coalesce(a.planned_start,a.due_at)<now()+interval '7 days'
      ) load7 on true
      where p.organization_id=v_org and p.active
        and (
          erp_supply.has_role('auditoria')
          or (v_kind is not null and erp_supply.can_manage_work_profile(p.id,v_kind))
          or (v_kind is null and (erp_supply.can_manage_work_profile(p.id,'ACTIVITY') or erp_supply.can_manage_work_profile(p.id,'DELIVERABLE')))
        )
      group by p.id,p.display_name,p.email,p.employee_code,ae.title_snapshot,ae.started_at,load7.planned_minutes
    ) x
  ),'[]'::jsonb);
end;
$$;

revoke all on function public.erp_x_work_people(text) from public,anon;
grant execute on function public.erp_x_work_people(text) to authenticated;

create or replace function public.erp_x_work_planner(p_from date,p_to date)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_from date:=coalesce(p_from,current_date-date_part('dow',current_date)::int);
  v_to date:=coalesce(p_to,v_from+6);
  v_tz text:=coalesce((select timezone from erp_supply.organizations where id=v_org),'America/Bogota');
  v_start timestamptz:=(v_from::timestamp at time zone v_tz);
  v_end timestamptz:=((v_to+1)::timestamp at time zone v_tz);
begin
  if v_to<v_from or v_to-v_from>62 then raise exception 'Rango de planificación inválido'; end if;
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia')) then
    raise exception 'No tienes permisos de planificación' using errcode='42501';
  end if;

  return jsonb_build_object(
    'from',v_from,'to',v_to,
    'people',public.erp_x_work_people(null),
    'assignments',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."plannedStart" nulls last,x."dueAt" nulls last,x.title),'[]'::jsonb)
      from(
        select a.id,a.series_id "seriesId",a.title,a.description,a.assignment_kind "kind",a.status,a.priority,
               a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",a.estimated_minutes "estimatedMinutes",
               a.evidence_policy "evidencePolicy",a.acceptance_required "acceptanceRequired",a.catalog_id "catalogId",c.name "catalogName",
               p.id "profileId",p.display_name "profileName",m.id "memberId",m.status "memberStatus",a.assigned_by "assignedBy",
               a.recurrence,a.metadata
        from erp_supply.work_assignments a
        join erp_supply.work_assignment_members m on m.assignment_id=a.id
        join erp_supply.profiles p on p.id=m.profile_id
        left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where a.organization_id=v_org and a.status<>'CANCELLED'
          and erp_supply.can_manage_work_profile(p.id,a.assignment_kind)
          and (
            (a.planned_start is not null and a.planned_start<v_end and coalesce(a.planned_end,a.planned_start+interval '1 minute')>v_start)
            or (a.planned_start is null and a.due_at>=v_start and a.due_at<v_end)
          )
      ) x
    ),
    'permissions',jsonb_build_object(
      'logistics',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin'),
      'deliverables',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'all',erp_supply.has_role('super_admin')
    ),
    'serverTime',now(),'version','10.23.0'
  );
end;
$$;

revoke all on function public.erp_x_work_planner(date,date) from public,anon;
grant execute on function public.erp_x_work_planner(date,date) to authenticated;

create or replace function public.erp_x_work_save_assignment(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_kind text:=upper(coalesce(nullif(trim(p_payload->>'kind'),''),'ACTIVITY'));
  v_catalog erp_supply.work_activity_catalog%rowtype;
  v_catalog_id uuid:=erp_supply.safe_uuid(p_payload->>'catalogId');
  v_title text:=trim(coalesce(p_payload->>'title',''));
  v_description text:=nullif(trim(p_payload->>'description'),'');
  v_priority text:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_base_start timestamptz:=nullif(trim(p_payload->>'plannedStart'),'')::timestamptz;
  v_base_end timestamptz:=nullif(trim(p_payload->>'plannedEnd'),'')::timestamptz;
  v_base_due timestamptz:=nullif(trim(p_payload->>'dueAt'),'')::timestamptz;
  v_estimated integer:=nullif(trim(p_payload->>'estimatedMinutes'),'')::integer;
  v_evidence text:=upper(nullif(trim(p_payload->>'evidencePolicy'),''));
  v_acceptance boolean:=coalesce((p_payload->>'acceptanceRequired')::boolean,v_kind='DELIVERABLE');
  v_force boolean:=coalesce((p_payload->>'force')::boolean,false);
  v_frequency text:=upper(coalesce(nullif(trim(p_payload#>>'{recurrence,frequency}'),''),'NONE'));
  v_until date:=nullif(trim(p_payload#>>'{recurrence,until}'),'')::date;
  v_series uuid:=case when v_frequency='NONE' then null else gen_random_uuid() end;
  v_occurrence integer:=0;
  v_occurrence_start timestamptz;
  v_occurrence_end timestamptz;
  v_occurrence_due timestamptz;
  v_anchor_date date;
  v_conflicts jsonb:='[]'::jsonb;
  v_created jsonb:='[]'::jsonb;
  v_assignment_id uuid;
  v_profile_id uuid;
  v_roles text[]:=erp_supply.current_roles();
begin
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia')) then raise exception 'No tienes permisos para asignar actividades' using errcode='42501'; end if;
  if v_kind not in('ACTIVITY','DELIVERABLE') then raise exception 'Tipo de asignación inválido'; end if;
  if v_kind='ACTIVITY' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then raise exception 'Solo Jefatura Logística puede programar actividades operativas'; end if;
  if v_kind='DELIVERABLE' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then raise exception 'Solo Gerencia puede asignar entregables con fecha límite'; end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
  if coalesce(jsonb_typeof(p_payload->'profileIds'),'')<>'array' or coalesce(jsonb_array_length(p_payload->'profileIds'),0)=0 then raise exception 'Selecciona al menos una persona'; end if;
  if v_frequency not in('NONE','DAILY','WEEKLY','MONTHLY') then raise exception 'Recurrencia inválida'; end if;

  if v_catalog_id is not null then
    select * into v_catalog from erp_supply.work_activity_catalog where id=v_catalog_id and organization_id=v_org and active;
    if not found then raise exception 'Tipo de actividad no disponible'; end if;
    if v_kind<>v_catalog.activity_kind and not (v_kind='ACTIVITY' and v_catalog.activity_kind='ACTIVITY') then raise exception 'El catálogo no corresponde al tipo de asignación'; end if;
  end if;
  if v_title='' then v_title:=coalesce(v_catalog.name,'Actividad programada'); end if;
  v_estimated:=coalesce(v_estimated,v_catalog.standard_minutes,60);
  v_evidence:=coalesce(v_evidence,v_catalog.evidence_policy,case when v_kind='DELIVERABLE' then 'FILE' else 'FINAL_PHOTO' end);
  if v_evidence not in('NONE','FINAL_PHOTO','BEFORE_AFTER','FILE','LINK','ERP_REFERENCE') then raise exception 'Política de evidencia inválida'; end if;
  if v_kind='DELIVERABLE' and v_base_due is null then raise exception 'El entregable necesita una fecha límite'; end if;
  if v_base_end is not null and (v_base_start is null or v_base_end<=v_base_start) then raise exception 'El horario de finalización debe ser posterior al inicio'; end if;
  if v_kind='ACTIVITY' and (v_base_start is null or v_base_end is null) then raise exception 'La actividad programada necesita fecha y hora de inicio y finalización'; end if;
  if v_frequency<>'NONE' and v_until is null then raise exception 'La recurrencia necesita una fecha final'; end if;

  for v_profile_id in select (value#>>'{}')::uuid from jsonb_array_elements(p_payload->'profileIds') loop
    if not exists(select 1 from erp_supply.profiles where id=v_profile_id and organization_id=v_org and active) then raise exception 'Uno de los usuarios no está disponible'; end if;
    if not erp_supply.can_manage_work_profile(v_profile_id,v_kind) then raise exception 'No tienes permiso para planificar a una de las personas seleccionadas' using errcode='42501'; end if;
    if v_catalog_id is not null and not erp_supply.work_catalog_allowed(v_catalog_id,v_profile_id) then raise exception 'La actividad seleccionada no está habilitada para uno de los perfiles'; end if;
  end loop;

  -- Primera pasada: detectar conflictos en toda la serie antes de escribir.
  loop
    exit when v_occurrence>=120;
    v_occurrence_start:=case v_frequency
      when 'DAILY' then v_base_start+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_start+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_start+(v_occurrence||' months')::interval
      else v_base_start end;
    v_occurrence_end:=case when v_base_end is null then null else case v_frequency
      when 'DAILY' then v_base_end+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_end+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_end+(v_occurrence||' months')::interval
      else v_base_end end end;
    v_occurrence_due:=case when v_base_due is null then null else case v_frequency
      when 'DAILY' then v_base_due+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_due+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_due+(v_occurrence||' months')::interval
      else v_base_due end end;
    v_anchor_date:=coalesce(v_occurrence_start::date,v_occurrence_due::date);
    exit when v_frequency<>'NONE' and v_anchor_date>v_until;

    if v_occurrence_start is not null and v_occurrence_end is not null then
      for v_profile_id in select (value#>>'{}')::uuid from jsonb_array_elements(p_payload->'profileIds') loop
        if exists(
          select 1 from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id
          where m.profile_id=v_profile_id and a.status='PUBLISHED'
            and a.planned_start is not null and a.planned_end is not null
            and tstzrange(a.planned_start,a.planned_end,'[)') && tstzrange(v_occurrence_start,v_occurrence_end,'[)')
        ) then
          v_conflicts:=v_conflicts||jsonb_build_array(jsonb_build_object(
            'profileId',v_profile_id,'plannedStart',v_occurrence_start,'plannedEnd',v_occurrence_end,'conflictType','OVERLAP','message','Ya existe una actividad en ese horario'
          ));
        end if;
        if erp_supply.business_seconds_between(v_org,v_occurrence_start,v_occurrence_end)
             < greatest(0,extract(epoch from(v_occurrence_end-v_occurrence_start))::bigint)-60 then
          v_conflicts:=v_conflicts||jsonb_build_array(jsonb_build_object(
            'profileId',v_profile_id,'plannedStart',v_occurrence_start,'plannedEnd',v_occurrence_end,
            'conflictType','OUTSIDE_WORKING_TIME','message','El bloque invade tiempo no laborable, almuerzo, fin de semana o festivo'
          ));
        end if;
      end loop;
    end if;

    exit when v_frequency='NONE';
    v_occurrence:=v_occurrence+1;
  end loop;

  if jsonb_array_length(v_conflicts)>0 and not v_force then
    return jsonb_build_object('success',false,'requiresConfirmation',true,'conflicts',v_conflicts,'createdIds','[]'::jsonb);
  end if;

  v_occurrence:=0;
  loop
    exit when v_occurrence>=120;
    v_occurrence_start:=case v_frequency
      when 'DAILY' then v_base_start+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_start+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_start+(v_occurrence||' months')::interval
      else v_base_start end;
    v_occurrence_end:=case when v_base_end is null then null else case v_frequency
      when 'DAILY' then v_base_end+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_end+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_end+(v_occurrence||' months')::interval
      else v_base_end end end;
    v_occurrence_due:=case when v_base_due is null then null else case v_frequency
      when 'DAILY' then v_base_due+(v_occurrence||' days')::interval
      when 'WEEKLY' then v_base_due+(v_occurrence*7||' days')::interval
      when 'MONTHLY' then v_base_due+(v_occurrence||' months')::interval
      else v_base_due end end;
    v_anchor_date:=coalesce(v_occurrence_start::date,v_occurrence_due::date);
    exit when v_frequency<>'NONE' and v_anchor_date>v_until;

    insert into erp_supply.work_assignments(
      organization_id,catalog_id,series_id,title,description,assignment_kind,status,priority,
      planned_start,planned_end,due_at,estimated_minutes,evidence_policy,acceptance_required,assigned_by,
      related_entity_type,related_entity_id,recurrence,metadata
    ) values(
      v_org,v_catalog_id,v_series,v_title,v_description,v_kind,'PUBLISHED',v_priority,
      v_occurrence_start,v_occurrence_end,v_occurrence_due,v_estimated,v_evidence,v_acceptance,v_actor,
      nullif(trim(p_payload->>'relatedEntityType'),''),nullif(trim(p_payload->>'relatedEntityId'),''),
      coalesce(p_payload->'recurrence','{}'::jsonb),
      coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('createdVersion','10.23.0','forcedConflict',v_force)
    ) returning id into v_assignment_id;

    insert into erp_supply.work_assignment_members(assignment_id,profile_id,status)
    select v_assignment_id,(value#>>'{}')::uuid,'PLANNED'
    from jsonb_array_elements(p_payload->'profileIds');

    insert into erp_supply.work_activity_events(organization_id,assignment_id,actor_profile_id,event_type,payload)
    values(v_org,v_assignment_id,v_actor,'ASSIGNMENT_PUBLISHED',jsonb_build_object('kind',v_kind,'profileIds',p_payload->'profileIds','plannedStart',v_occurrence_start,'dueAt',v_occurrence_due,'seriesId',v_series));

    v_created:=v_created||jsonb_build_array(v_assignment_id);
    exit when v_frequency='NONE';
    v_occurrence:=v_occurrence+1;
  end loop;

  return jsonb_build_object('success',true,'requiresConfirmation',false,'conflicts',v_conflicts,'createdIds',v_created,'seriesId',v_series,'version','10.23.0');
end;
$$;

revoke all on function public.erp_x_work_save_assignment(jsonb) from public,anon;
grant execute on function public.erp_x_work_save_assignment(jsonb) to authenticated;

create or replace function public.erp_x_work_cancel_assignment(p_assignment_id uuid,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_assignment erp_supply.work_assignments%rowtype;
begin
  select * into v_assignment from erp_supply.work_assignments where id=p_assignment_id and organization_id=v_org for update;
  if not found then raise exception 'Asignación no disponible'; end if;
  if not exists(select 1 from erp_supply.work_assignment_members m where m.assignment_id=v_assignment.id and erp_supply.can_manage_work_profile(m.profile_id,v_assignment.assignment_kind)) then raise exception 'No autorizado' using errcode='42501'; end if;
  if exists(select 1 from erp_supply.work_executions e where e.assignment_id=v_assignment.id and e.status in('IN_PROGRESS','PAUSED')) then raise exception 'No puedes cancelar una actividad que alguien está ejecutando en este momento'; end if;

  update erp_supply.work_assignments set status='CANCELLED',metadata=metadata||jsonb_build_object('cancelledBy',v_actor,'cancelledAt',now(),'cancelNote',nullif(trim(p_note),''),'version','10.23.0') where id=v_assignment.id;
  update erp_supply.work_assignment_members set status='CANCELLED',cancelled_at=now() where assignment_id=v_assignment.id and status not in('COMPLETED','CANCELLED');
  update erp_supply.work_executions set status='CANCELLED',metadata=metadata||jsonb_build_object('cancelledWithAssignment',true,'version','10.23.0') where assignment_id=v_assignment.id and status in('WAITING_EVIDENCE','SUBMITTED','RETURNED');
  insert into erp_supply.work_activity_events(organization_id,assignment_id,actor_profile_id,event_type,payload)
  values(v_org,v_assignment.id,v_actor,'ASSIGNMENT_CANCELLED',jsonb_build_object('note',p_note));
  return jsonb_build_object('success',true,'assignmentId',v_assignment.id,'status','CANCELLED');
end;
$$;

revoke all on function public.erp_x_work_cancel_assignment(uuid,text) from public,anon;
grant execute on function public.erp_x_work_cancel_assignment(uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. ACEPTACIÓN DE ENTREGABLES
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_review_delivery(
  p_execution_id uuid,
  p_decision text,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_exec erp_supply.work_executions%rowtype;
  v_assignment erp_supply.work_assignments%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'')));
begin
  select * into v_exec from erp_supply.work_executions where id=p_execution_id and organization_id=erp_supply.current_org_id() for update;
  if not found or v_exec.assignment_id is null then raise exception 'Entregable no disponible'; end if;
  select * into v_assignment from erp_supply.work_assignments where id=v_exec.assignment_id;
  if v_assignment.assignment_kind<>'DELIVERABLE' then raise exception 'Esta ejecución no es un entregable'; end if;
  if not erp_supply.can_manage_work_profile(v_exec.profile_id,'DELIVERABLE') then raise exception 'No autorizado para revisar este entregable' using errcode='42501'; end if;
  if v_exec.status<>'SUBMITTED' then raise exception 'El entregable no está pendiente de revisión'; end if;
  if v_decision not in('ACCEPTED','RETURNED') then raise exception 'Decisión inválida'; end if;
  if v_decision='RETURNED' and nullif(trim(p_note),'') is null then raise exception 'Indica qué debe corregirse'; end if;

  insert into erp_supply.work_delivery_reviews(organization_id,execution_id,assignment_id,decision,note,reviewed_by)
  values(v_exec.organization_id,v_exec.id,v_assignment.id,v_decision,nullif(trim(p_note),''),v_actor);

  if v_decision='ACCEPTED' then
    update erp_supply.work_executions set status='COMPLETED',metadata=metadata||jsonb_build_object('acceptedBy',v_actor,'acceptedAt',now(),'version','10.23.0') where id=v_exec.id;
    update erp_supply.work_assignment_members set status='COMPLETED',completed_at=coalesce(completed_at,now()) where id=v_exec.assignment_member_id;
  else
    update erp_supply.work_executions set status='RETURNED',metadata=metadata||jsonb_build_object('returnedBy',v_actor,'returnedAt',now(),'returnNote',p_note,'version','10.23.0') where id=v_exec.id;
    update erp_supply.work_assignment_members set status='RETURNED' where id=v_exec.assignment_member_id;
  end if;

  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_exec.organization_id,v_exec.id,v_assignment.id,v_exec.profile_id,v_actor,'DELIVERY_REVIEWED',jsonb_build_object('decision',v_decision,'note',p_note));
  return jsonb_build_object('success',true,'executionId',v_exec.id,'decision',v_decision,'status',case when v_decision='ACCEPTED' then 'COMPLETED' else 'RETURNED' end);
end;
$$;

revoke all on function public.erp_x_work_review_delivery(uuid,text,text) from public,anon;
grant execute on function public.erp_x_work_review_delivery(uuid,text,text) to authenticated;

-- Reconciliación de permisos para los RPC nuevos.
do $$
declare r record;begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_work_%'
  loop
    execute format('revoke all on function %s from public,anon',r.sig);
    execute format('grant execute on function %s to authenticated',r.sig);
  end loop;
end $$;

notify pgrst,'reload schema';
commit;
