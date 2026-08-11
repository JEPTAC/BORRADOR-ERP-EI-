-- ERP EI V10.23.0
-- Libro mayor de tiempo, capacidad, productividad responsable y diagnósticos.

begin;

-- ---------------------------------------------------------------------------
-- 1. TIEMPO CLASIFICADO SIN DOBLE CONTEO
-- Une intervalos de procesos ERP y actividades antes de calcular utilización.
-- ---------------------------------------------------------------------------
create or replace function erp_supply.work_classified_business_seconds(
  p_profile_id uuid,
  p_start timestamptz,
  p_end timestamptz
)
returns bigint
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  with profile_ctx as(
    select p.organization_id,o.timezone
    from erp_supply.profiles p join erp_supply.organizations o on o.id=p.organization_id
    where p.id=p_profile_id
  ),
  calendar_ctx as(
    select c.id,c.timezone
    from erp_supply.work_calendars c join profile_ctx pc on pc.organization_id=c.organization_id
    where c.active order by c.created_at limit 1
  ),
  entries as(
    select s.started_at start_at,least(coalesce(s.ended_at,now()),p_end) end_at
    from erp_supply.task_sessions s
    join erp_supply.order_tasks t on t.id=s.task_id
    join erp_supply.orders o on o.id=t.order_id
    join profile_ctx pc on pc.organization_id=o.organization_id
    where s.profile_id=p_profile_id and s.started_at<p_end and coalesce(s.ended_at,now())>p_start
    union all
    select e.started_at,least(coalesce(e.ended_at,now()),p_end)
    from erp_supply.work_executions e join profile_ctx pc on pc.organization_id=e.organization_id
    where e.profile_id=p_profile_id and e.status<>'CANCELLED' and e.started_at<p_end and coalesce(e.ended_at,now())>p_start
  ),
  business_segments as(
    select
      ((d::date+s.start_time) at time zone c.timezone) seg_start,
      ((d::date+s.end_time) at time zone c.timezone) seg_end
    from calendar_ctx c
    join erp_supply.work_calendar_segments s on s.calendar_id=c.id
    cross join lateral generate_series(p_start::date,p_end::date,interval '1 day') d
    join profile_ctx pc on true
    where extract(isodow from d)::int=s.iso_weekday
      and not exists(select 1 from erp_supply.holidays h where h.organization_id=pc.organization_id and h.holiday_date=d::date)
  ),
  intersections as(
    select tstzrange(greatest(e.start_at,b.seg_start,p_start),least(e.end_at,b.seg_end,p_end),'[)') r
    from entries e cross join business_segments b
    where e.start_at<b.seg_end and e.end_at>b.seg_start and greatest(e.start_at,b.seg_start,p_start)<least(e.end_at,b.seg_end,p_end)
  ),
  merged as(
    select unnest(range_agg(r)) r from intersections
  )
  select coalesce(sum(extract(epoch from(upper(r)-lower(r)))::bigint),0) from merged
$$;

revoke all on function erp_supply.work_classified_business_seconds(uuid,timestamptz,timestamptz) from public;

-- ---------------------------------------------------------------------------
-- 2. LIBRO MAYOR DE TIEMPO
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_ledger(
  p_from date,
  p_to date,
  p_profile_id uuid default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=coalesce(p_profile_id,v_actor);
  v_tz text:=coalesce((select timezone from erp_supply.organizations where id=v_org),'America/Bogota');
  v_from date:=coalesce(p_from,current_date);
  v_to date:=coalesce(p_to,v_from);
  v_start timestamptz:=(v_from::timestamp at time zone v_tz);
  v_end timestamptz:=((v_to+1)::timestamp at time zone v_tz);
begin
  if v_to<v_from or v_to-v_from>92 then raise exception 'Rango de tiempo inválido'; end if;
  if v_profile<>v_actor and not (
    erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria')
    or erp_supply.can_manage_work_profile(v_profile,'ACTIVITY')
    or erp_supply.can_manage_work_profile(v_profile,'DELIVERABLE')
  ) then raise exception 'No autorizado para consultar esta jornada' using errcode='42501'; end if;
  if not exists(select 1 from erp_supply.profiles where id=v_profile and organization_id=v_org) then raise exception 'Perfil no disponible'; end if;

  return jsonb_build_object(
    'profileId',v_profile,'from',v_from,'to',v_to,
    'entries',(
      with entries as(
        select 'ERP:'||s.id::text entry_id,'ERP_PROCESS' source_type,
               o.order_number||' · '||ws.name title,s.started_at start_at,coalesce(s.ended_at,now()) end_at,
               case when s.ended_at is null then erp_supply.business_seconds_between(v_org,s.started_at,now()) else s.business_seconds end business_seconds,
               greatest(0,extract(epoch from(coalesce(s.ended_at,now())-s.started_at))::bigint) active_seconds,
               t.status status,o.id::text related_id,o.order_number related_label
        from erp_supply.task_sessions s
        join erp_supply.order_tasks t on t.id=s.task_id
        join erp_supply.orders o on o.id=t.order_id
        join erp_supply.workflow_steps ws on ws.code=t.step_code
        where s.profile_id=v_profile and o.organization_id=v_org and s.started_at<v_end and coalesce(s.ended_at,now())>v_start
        union all
        select 'ACT:'||e.id::text,'ACTIVITY',e.title_snapshot,e.started_at,coalesce(e.ended_at,now()),
               case when e.ended_at is null then coalesce((erp_supply.work_execution_metrics(e.id)->>'businessSeconds')::bigint,0) else e.business_seconds end,
               case when e.ended_at is null then coalesce((erp_supply.work_execution_metrics(e.id)->>'activeSeconds')::bigint,0) else e.active_seconds end,
               e.status,e.assignment_id::text,c.name
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        where e.profile_id=v_profile and e.organization_id=v_org and e.status<>'CANCELLED' and e.started_at<v_end and coalesce(e.ended_at,now())>v_start
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',e.entry_id,'sourceType',e.source_type,'title',e.title,'startedAt',e.start_at,'endedAt',e.end_at,
        'businessSeconds',e.business_seconds,'activeSeconds',e.active_seconds,'status',e.status,
        'relatedId',e.related_id,'relatedLabel',e.related_label,
        'overlap',exists(select 1 from entries o where o.entry_id<>e.entry_id and tstzrange(o.start_at,o.end_at,'[)') && tstzrange(e.start_at,e.end_at,'[)'))
      ) order by e.start_at),'[]'::jsonb) from entries e
    ),
    'scheduledBusinessSeconds',erp_supply.business_seconds_between(v_org,v_start,v_end),
    'classifiedBusinessSeconds',erp_supply.work_classified_business_seconds(v_profile,v_start,v_end),
    'unclassifiedBusinessSeconds',greatest(0,erp_supply.business_seconds_between(v_org,v_start,v_end)-erp_supply.work_classified_business_seconds(v_profile,v_start,v_end)),
    'serverTime',now(),'version','10.23.0'
  );
end;
$$;

revoke all on function public.erp_x_work_ledger(date,date,uuid) from public,anon;
grant execute on function public.erp_x_work_ledger(date,date,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. ANALÍTICA DE CAPACIDAD Y CUMPLIMIENTO
-- No construye rankings personales: mide carga, cumplimiento, desvíos y causas.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_analytics(
  p_from date,
  p_to date,
  p_profile_id uuid default null
)
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
  v_from date:=coalesce(p_from,current_date-29);
  v_to date:=coalesce(p_to,current_date);
  v_start timestamptz:=(v_from::timestamp at time zone v_tz);
  v_end timestamptz:=((v_to+1)::timestamp at time zone v_tz);
  v_manager boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria');
  v_profiles uuid[];
  v_scheduled bigint:=0;
  v_classified bigint:=0;
  v_p uuid;
begin
  if v_to<v_from or v_to-v_from>366 then raise exception 'Rango analítico inválido'; end if;
  if p_profile_id is not null then
    if p_profile_id<>v_actor and not(
      erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria')
      or erp_supply.can_manage_work_profile(p_profile_id,'ACTIVITY')
      or erp_supply.can_manage_work_profile(p_profile_id,'DELIVERABLE')
    ) then raise exception 'No autorizado' using errcode='42501'; end if;
    v_profiles:=array[p_profile_id];
  elsif v_manager then
    select coalesce(array_agg(p.id),'{}'::uuid[]) into v_profiles
    from erp_supply.profiles p where p.organization_id=v_org and p.active and(
      erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria')
      or erp_supply.can_manage_work_profile(p.id,'ACTIVITY') or erp_supply.can_manage_work_profile(p.id,'DELIVERABLE')
    );
  else
    v_profiles:=array[v_actor];
  end if;
  if coalesce(array_length(v_profiles,1),0)=0 then v_profiles:=array[v_actor]; end if;

  foreach v_p in array v_profiles loop
    v_scheduled:=v_scheduled+erp_supply.business_seconds_between(v_org,v_start,v_end);
    v_classified:=v_classified+erp_supply.work_classified_business_seconds(v_p,v_start,v_end);
  end loop;

  return jsonb_build_object(
    'from',v_from,'to',v_to,'profileIds',to_jsonb(v_profiles),
    'summary',jsonb_build_object(
      'people',coalesce(array_length(v_profiles,1),0),
      'scheduledBusinessSeconds',v_scheduled,
      'classifiedBusinessSeconds',v_classified,
      'unclassifiedBusinessSeconds',greatest(0,v_scheduled-v_classified),
      'utilizationPct',case when v_scheduled=0 then 0 else round((100.0*v_classified/v_scheduled)::numeric,1) end,
      'activityActiveSeconds',(select coalesce(sum(e.active_seconds),0) from erp_supply.work_executions e where e.organization_id=v_org and e.profile_id=any(v_profiles) and e.started_at<v_end and coalesce(e.ended_at,now())>v_start and e.status<>'CANCELLED'),
      'plannedMinutes',(select coalesce(sum(a.estimated_minutes),0) from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id where m.profile_id=any(v_profiles) and a.organization_id=v_org and a.status<>'CANCELLED' and coalesce(a.planned_start,a.due_at)>=v_start and coalesce(a.planned_start,a.due_at)<v_end),
      'completedAssignments',(select count(*) from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id where m.profile_id=any(v_profiles) and a.organization_id=v_org and m.completed_at>=v_start and m.completed_at<v_end),
      'onTimePct',(
        select case when count(*)=0 then 0 else round(100.0*count(*) filter(where m.completed_at<=coalesce(a.due_at,a.planned_end,m.completed_at))/count(*),1) end
        from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id
        where m.profile_id=any(v_profiles) and a.organization_id=v_org and m.completed_at>=v_start and m.completed_at<v_end
      ),
      'startAdherencePct',(
        select case when count(*)=0 then 0 else round(100.0*count(*) filter(where coalesce(e.start_delay_seconds,0)<=300)/count(*),1) end
        from erp_supply.work_executions e where e.profile_id=any(v_profiles) and e.assignment_id is not null and e.started_at>=v_start and e.started_at<v_end
      ),
      'pendingReviews',(select count(*) from erp_supply.work_executions e join erp_supply.work_assignments a on a.id=e.assignment_id where e.profile_id=any(v_profiles) and e.status='SUBMITTED' and a.assignment_kind='DELIVERABLE')
    ),
    'activityGroups',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."activeSeconds" desc),'[]'::jsonb) from(
        select c.activity_group "group",sum(e.active_seconds)::bigint "activeSeconds",count(*)::integer executions
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        where e.profile_id=any(v_profiles) and e.started_at>=v_start and e.started_at<v_end and e.status<>'CANCELLED'
        group by c.activity_group
      ) x
    ),
    'topActivities',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."activeSeconds" desc),'[]'::jsonb) from(
        select c.id,c.name,c.activity_group "group",sum(e.active_seconds)::bigint "activeSeconds",count(*)::integer executions,
               round((percentile_cont(.5) within group(order by e.active_seconds)/60.0)::numeric,1) "medianMinutes",
               round((percentile_cont(.8) within group(order by e.active_seconds)/60.0)::numeric,1) "p80Minutes"
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        where e.profile_id=any(v_profiles) and e.started_at>=v_start and e.started_at<v_end and e.status<>'CANCELLED' and e.active_seconds>0
        group by c.id,c.name,c.activity_group order by sum(e.active_seconds) desc limit 12
      ) x
    ),
    'deviationCauses',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x.executions desc),'[]'::jsonb) from(
        select e.deviation_reason reason,count(*)::integer executions,sum(e.active_seconds)::bigint "activeSeconds"
        from erp_supply.work_executions e
        where e.profile_id=any(v_profiles) and e.started_at>=v_start and e.started_at<v_end and nullif(trim(e.deviation_reason),'') is not null
        group by e.deviation_reason
      ) x
    ),
    'teamNow',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."profileName"),'[]'::jsonb) from(
        select p.id "profileId",p.display_name "profileName",e.id "executionId",e.title_snapshot title,e.status,e.started_at "startedAt",c.activity_group "group"
        from erp_supply.work_executions e join erp_supply.profiles p on p.id=e.profile_id join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        where e.profile_id=any(v_profiles) and e.status in('IN_PROGRESS','PAUSED')
      ) x
    ),
    'pendingReviews',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."dueAt" nulls last,x."submittedAt"),'[]'::jsonb) from(
        select e.id "executionId",a.id "assignmentId",a.title,p.id "profileId",p.display_name "profileName",a.due_at "dueAt",m.submitted_at "submittedAt",e.result_note "resultNote",
               (select coalesce(jsonb_agg(jsonb_build_object('type',w.evidence_type,'fileName',w.file_name,'webViewLink',w.web_view_link,'value',w.external_value) order by w.created_at),'[]'::jsonb) from erp_supply.work_evidence w where w.execution_id=e.id) evidence
        from erp_supply.work_executions e join erp_supply.work_assignments a on a.id=e.assignment_id
        join erp_supply.work_assignment_members m on m.id=e.assignment_member_id join erp_supply.profiles p on p.id=e.profile_id
        where e.profile_id=any(v_profiles) and e.status='SUBMITTED' and a.assignment_kind='DELIVERABLE'
          and (erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria') or erp_supply.can_manage_work_profile(e.profile_id,'DELIVERABLE'))
      ) x
    ),
    'version','10.23.0','serverTime',now()
  );
end;
$$;

revoke all on function public.erp_x_work_analytics(date,date,uuid) from public,anon;
grant execute on function public.erp_x_work_analytics(date,date,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. DIAGNÓSTICO ESPECÍFICO DEL SUBSISTEMA
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_health()
returns table(check_name text,ok boolean,detail text)
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
begin
  perform erp_supply.require_profile();
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria')) then
    raise exception 'No autorizado para diagnóstico de actividades' using errcode='42501';
  end if;

  return query
  select 'Módulo transversal para todos los roles',
         not exists(
           select 1 from erp_supply.roles r where r.active and not exists(
             select 1 from erp_supply.role_module_permissions p where p.role_code=r.code and p.module_code='workforce' and p.can_read and p.can_create
           )
         ),
         'Todos los roles activos deben poder consultar y registrar Mi Jornada';

  return query
  select 'Una actividad cronometrada por persona',
         not exists(select 1 from erp_supply.work_executions e where e.status in('IN_PROGRESS','PAUSED') group by e.profile_id having count(*)>1),
         'No puede existir más de una actividad varias cronometrada simultáneamente por perfil';

  return query
  select 'Pausas consistentes',
         not exists(
           select 1 from erp_supply.work_execution_pauses p join erp_supply.work_executions e on e.id=p.execution_id
           where p.ended_at is null and e.status<>'PAUSED'
         ),
         'Toda pausa abierta debe corresponder a una ejecución PAUSED';

  return query
  select 'Entregables aceptados coherentes',
         not exists(
           select 1 from erp_supply.work_executions e join erp_supply.work_assignments a on a.id=e.assignment_id
           where a.assignment_kind='DELIVERABLE' and e.status='COMPLETED' and a.acceptance_required
             and not exists(select 1 from erp_supply.work_delivery_reviews r where r.execution_id=e.id and r.decision='ACCEPTED')
         ),
         'Un entregable con aceptación obligatoria solo se completa después de ser aceptado';

  return query
  select 'Asignaciones canceladas sin ejecución activa',
         not exists(
           select 1 from erp_supply.work_assignments a join erp_supply.work_executions e on e.assignment_id=a.id
           where a.status='CANCELLED' and e.status in('IN_PROGRESS','PAUSED')
         ),
         'Una asignación cancelada no puede seguir corriendo';
end;
$$;

revoke all on function public.erp_x_work_health() from public,anon;
grant execute on function public.erp_x_work_health() to authenticated;

notify pgrst,'reload schema';
commit;
