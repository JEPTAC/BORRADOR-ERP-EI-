-- ERP EI V10.24.0
-- Gobierno de actividades, aprobación por responsables, planificación personal
-- y ocupación integrada (proceso ERP + actividades varias) sin doble conteo.

begin;

-- ---------------------------------------------------------------------------
-- 1. NUEVO ROL DE LIDERAZGO LOGÍSTICO
-- ---------------------------------------------------------------------------
insert into erp_supply.roles(code,name,description)
values('lider_logistica','Líder logístico','Liderazgo operativo: asignación y aprobación de actividades del equipo logístico')
on conflict(code) do update set name=excluded.name,description=excluded.description,active=true;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('lider_logistica','workforce',true,true,true,true,true)
on conflict(role_code,module_code) do update set
  can_read=true,can_create=true,can_update=true,can_approve=true,can_admin=true;

-- Los líderes comparten el catálogo operativo con Jefatura.
update erp_supply.work_activity_catalog c
set allowed_roles=(select array_agg(distinct x order by x) from unnest(c.allowed_roles||array['lider_logistica']::text[]) x),
    updated_at=now()
where c.activity_kind='ACTIVITY'
  and c.activity_group in('LOGISTICS','GENERAL','IMPROVEMENT')
  and coalesce(array_length(c.allowed_roles,1),0)>0
  and c.allowed_roles && array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[]
  and not ('lider_logistica'=any(c.allowed_roles));

-- ---------------------------------------------------------------------------
-- 2. GOBIERNO DE ASIGNACIONES: SOLICITUD, APROBACIÓN Y ORIGEN
-- ---------------------------------------------------------------------------
alter table erp_supply.work_assignments
  add column if not exists request_origin text not null default 'MANAGER_ASSIGNED',
  add column if not exists request_reason text,
  add column if not exists approval_status text not null default 'NOT_REQUIRED',
  add column if not exists approval_scope text,
  add column if not exists requested_by uuid references erp_supply.profiles(id),
  add column if not exists requested_at timestamptz,
  add column if not exists decided_by uuid references erp_supply.profiles(id),
  add column if not exists decided_at timestamptz,
  add column if not exists decision_note text;

alter table erp_supply.work_assignments drop constraint if exists work_assignments_request_origin_check;
alter table erp_supply.work_assignments add constraint work_assignments_request_origin_check
  check(request_origin in('MANAGER_ASSIGNED','SELF_PROPOSED','SYSTEM'));
alter table erp_supply.work_assignments drop constraint if exists work_assignments_approval_status_check;
alter table erp_supply.work_assignments add constraint work_assignments_approval_status_check
  check(approval_status in('NOT_REQUIRED','PENDING','APPROVED','REJECTED'));
alter table erp_supply.work_assignments drop constraint if exists work_assignments_approval_scope_check;
alter table erp_supply.work_assignments add constraint work_assignments_approval_scope_check
  check(approval_scope is null or approval_scope in('LOGISTICS','MANAGEMENT'));

update erp_supply.work_assignments
set request_origin=coalesce(nullif(request_origin,''),'MANAGER_ASSIGNED'),
    approval_status=coalesce(nullif(approval_status,''),'NOT_REQUIRED'),
    requested_by=coalesce(requested_by,assigned_by),
    requested_at=coalesce(requested_at,created_at)
where request_origin is null or approval_status is null or requested_by is null or requested_at is null;

create index if not exists idx_work_assignments_approval_queue
on erp_supply.work_assignments(organization_id,approval_scope,approval_status,requested_at desc)
where approval_status='PENDING';

-- ---------------------------------------------------------------------------
-- 3. ALCANCES Y AUTORIZADORES
-- ---------------------------------------------------------------------------
create or replace function erp_supply.work_is_logistics_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select exists(
    select 1 from erp_supply.profile_roles pr
    where pr.profile_id=p_profile_id
      and pr.role_code=any(array[
        'jefe_logistica','lider_logistica','coordinador_logistico','aux_logistica','auxiliar_corte',
        'recepcion_mercancia','despacho_nacional'
      ]::text[])
  )
$$;
revoke all on function erp_supply.work_is_logistics_profile(uuid) from public;

create or replace function erp_supply.work_is_management_profile(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select exists(
    select 1 from erp_supply.profile_roles pr
    where pr.profile_id=p_profile_id
      and pr.role_code=any(array['ventas','compras','cartera','caja','jefe_logistica']::text[])
  )
$$;
revoke all on function erp_supply.work_is_management_profile(uuid) from public;

create or replace function erp_supply.work_approval_scope_for_profile(p_profile_id uuid)
returns text
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select case
    when erp_supply.work_is_logistics_profile(p_profile_id) then 'LOGISTICS'
    else 'MANAGEMENT'
  end
$$;
revoke all on function erp_supply.work_approval_scope_for_profile(uuid) from public;

create or replace function erp_supply.work_can_approve_scope(p_scope text)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  select erp_supply.has_role('super_admin')
    or (upper(coalesce(p_scope,''))='LOGISTICS' and (erp_supply.has_role('lider_logistica') or erp_supply.has_role('jefe_logistica')))
    or (upper(coalesce(p_scope,''))='MANAGEMENT' and erp_supply.has_role('gerencia'))
$$;
revoke all on function erp_supply.work_can_approve_scope(text) from public;

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
  select erp_supply.has_role('super_admin')
    or (
      upper(coalesce(p_assignment_kind,'ACTIVITY'))='ACTIVITY'
      and erp_supply.work_is_logistics_profile(p_profile_id)
      and (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica'))
    )
    or (
      erp_supply.has_role('gerencia')
      and erp_supply.work_is_management_profile(p_profile_id)
      and upper(coalesce(p_assignment_kind,'ACTIVITY')) in('ACTIVITY','DELIVERABLE')
    )
$$;
revoke all on function erp_supply.can_manage_work_profile(uuid,text) from public;

-- ---------------------------------------------------------------------------
-- 4. CATÁLOGO DINÁMICO POR ÁMBITO
-- ---------------------------------------------------------------------------
create or replace function erp_supply.work_manager_catalog_roles(p_kind text,p_scope text default null)
returns text[]
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_kind text:=upper(coalesce(p_kind,'ACTIVITY'));
  v_scope text:=upper(coalesce(nullif(trim(p_scope),''),case when erp_supply.has_role('gerencia') and not (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica')) then 'MANAGEMENT' else 'LOGISTICS' end));
begin
  if v_kind='DELIVERABLE' then
    if erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') then
      return array['ventas','jefe_logistica','compras','cartera','caja']::text[];
    end if;
    return '{}'::text[];
  end if;

  if v_scope='LOGISTICS' and (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica')) then
    return array['jefe_logistica','lider_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[];
  end if;

  if v_scope='MANAGEMENT' and (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then
    return array['ventas','jefe_logistica','compras','cartera','caja']::text[];
  end if;

  return '{}'::text[];
end;
$$;
revoke all on function erp_supply.work_manager_catalog_roles(text,text) from public;

create or replace function public.erp_x_work_create_catalog_item(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_kind text:=upper(coalesce(nullif(trim(p_payload->>'kind'),''),'ACTIVITY'));
  v_scope text:=upper(coalesce(nullif(trim(p_payload->>'scope'),''),case when v_kind='DELIVERABLE' then 'MANAGEMENT' else 'LOGISTICS' end));
  v_name text:=regexp_replace(trim(coalesce(p_payload->>'name','')),'\s+',' ','g');
  v_description text:=nullif(trim(p_payload->>'description'),'');
  v_group text:=upper(coalesce(nullif(trim(p_payload->>'activityGroup'),''),case when v_scope='MANAGEMENT' then 'MANAGEMENT' else 'LOGISTICS' end));
  v_minutes integer:=greatest(1,least(coalesce(erp_supply.safe_numeric(p_payload->>'standardMinutes')::integer,60),1440));
  v_evidence text:=upper(coalesce(nullif(trim(p_payload->>'evidencePolicy'),''),case when v_kind='DELIVERABLE' then 'FILE' else 'FINAL_PHOTO' end));
  v_acceptance boolean:=coalesce((p_payload->>'acceptanceRequired')::boolean,v_kind='DELIVERABLE');
  v_team boolean:=coalesce((p_payload->>'teamAllowed')::boolean,v_kind='ACTIVITY');
  v_roles text[];
  v_existing erp_supply.work_activity_catalog%rowtype;
  v_created erp_supply.work_activity_catalog%rowtype;
  v_code text;
begin
  if v_kind not in('ACTIVITY','DELIVERABLE') then raise exception 'Tipo de actividad inválido'; end if;
  if v_scope not in('LOGISTICS','MANAGEMENT') then raise exception 'Ámbito de actividad inválido'; end if;
  if v_kind='DELIVERABLE' and v_scope<>'MANAGEMENT' then raise exception 'Los entregables pertenecen al ámbito de Gerencia'; end if;
  if v_scope='LOGISTICS' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica')) then
    raise exception 'Solo Liderazgo o Jefatura Logística puede crear actividades logísticas' using errcode='42501';
  end if;
  if v_scope='MANAGEMENT' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then
    raise exception 'Solo Gerencia puede crear actividades para áreas administrativas' using errcode='42501';
  end if;
  if char_length(v_name)<3 or char_length(v_name)>120 then raise exception 'El nombre de la actividad debe tener entre 3 y 120 caracteres'; end if;
  if v_evidence not in('NONE','FINAL_PHOTO','BEFORE_AFTER','FILE','LINK','ERP_REFERENCE') then raise exception 'Política de evidencia inválida'; end if;
  if v_scope='LOGISTICS' and v_group not in('LOGISTICS','GENERAL','IMPROVEMENT') then raise exception 'Categoría no habilitada para logística'; end if;
  if v_scope='MANAGEMENT' and v_group not in('COMMERCIAL','FINANCE','PURCHASING','MANAGEMENT','GENERAL','IMPROVEMENT') then raise exception 'Categoría no habilitada para Gerencia'; end if;

  v_roles:=erp_supply.work_manager_catalog_roles(v_kind,v_scope);
  if coalesce(array_length(v_roles,1),0)=0 then raise exception 'No fue posible resolver los roles para esta actividad'; end if;

  select * into v_existing
  from erp_supply.work_activity_catalog c
  where c.organization_id=v_org and c.activity_kind=v_kind and c.active
    and lower(regexp_replace(trim(c.name),'\s+',' ','g'))=lower(v_name)
  order by c.created_at limit 1;
  if found then
    return jsonb_build_object('success',true,'alreadyExists',true,'item',jsonb_build_object(
      'id',v_existing.id,'code',v_existing.code,'name',v_existing.name,'description',v_existing.description,
      'activityGroup',v_existing.activity_group,'activityKind',v_existing.activity_kind,'standardMinutes',v_existing.standard_minutes,
      'evidencePolicy',v_existing.evidence_policy,'acceptanceRequired',v_existing.acceptance_required,'teamAllowed',v_existing.team_allowed,
      'catalogOrigin',v_existing.catalog_origin),'version','10.24.0');
  end if;

  v_code:='CUSTOM_'||upper(substr(md5(v_org::text||':'||v_actor::text||':'||clock_timestamp()::text||':'||v_name),1,16));
  insert into erp_supply.work_activity_catalog(
    organization_id,code,name,description,activity_group,activity_kind,standard_minutes,evidence_policy,
    acceptance_required,team_allowed,allowed_roles,active,sort_order,metadata,created_by,catalog_origin
  ) values(
    v_org,v_code,v_name,v_description,v_group,v_kind,v_minutes,v_evidence,v_acceptance,v_team,v_roles,true,80,
    jsonb_build_object('custom',true,'createdFromPlanner',true,'managerScope',v_scope,'createdVersion','10.24.0','createdAt',now()),
    v_actor,'MANAGER_CREATED'
  ) returning * into v_created;

  insert into erp_supply.work_activity_events(organization_id,actor_profile_id,event_type,payload)
  values(v_org,v_actor,'CATALOG_ACTIVITY_CREATED',jsonb_build_object(
    'catalogId',v_created.id,'code',v_created.code,'name',v_created.name,'kind',v_created.activity_kind,'group',v_created.activity_group,
    'scope',v_scope,'standardMinutes',v_created.standard_minutes,'evidencePolicy',v_created.evidence_policy,'allowedRoles',to_jsonb(v_roles),'version','10.24.0'));

  return jsonb_build_object('success',true,'alreadyExists',false,'item',jsonb_build_object(
    'id',v_created.id,'code',v_created.code,'name',v_created.name,'description',v_created.description,
    'activityGroup',v_created.activity_group,'activityKind',v_created.activity_kind,'standardMinutes',v_created.standard_minutes,
    'evidencePolicy',v_created.evidence_policy,'acceptanceRequired',v_created.acceptance_required,'teamAllowed',v_created.team_allowed,
    'catalogOrigin',v_created.catalog_origin,'createdBy',v_created.created_by,'createdAt',v_created.created_at),'version','10.24.0');
end;
$$;
revoke all on function public.erp_x_work_create_catalog_item(jsonb) from public,anon;
grant execute on function public.erp_x_work_create_catalog_item(jsonb) to authenticated;

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
      select c.id,c.code,c.name,c.description,c.activity_group "activityGroup",c.activity_kind "activityKind",
             c.standard_minutes "standardMinutes",c.evidence_policy "evidencePolicy",c.acceptance_required "acceptanceRequired",
             c.team_allowed "teamAllowed",c.sort_order "sortOrder",c.catalog_origin "catalogOrigin",
             (c.catalog_origin='MANAGER_CREATED') "custom",c.created_by "createdBy",c.created_at "createdAt",
             case
               when upper(coalesce(c.metadata->>'managerScope','')) in('LOGISTICS','MANAGEMENT') then upper(c.metadata->>'managerScope')
               when c.activity_group='LOGISTICS' then 'LOGISTICS'
               when c.activity_group in('COMMERCIAL','FINANCE','PURCHASING','MANAGEMENT') then 'MANAGEMENT'
               when c.allowed_roles && array['aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional','coordinador_logistico','lider_logistica']::text[] then 'LOGISTICS'
               when c.allowed_roles && array['ventas','compras','cartera','caja']::text[] then 'MANAGEMENT'
               else null
             end "catalogScope",
             h.samples,h."medianMinutes",h."p80Minutes"
      from erp_supply.work_activity_catalog c
      left join lateral(
        select count(*)::integer samples,
               round((percentile_cont(.5) within group(order by e.active_seconds)/60.0)::numeric,1) "medianMinutes",
               round((percentile_cont(.8) within group(order by e.active_seconds)/60.0)::numeric,1) "p80Minutes"
        from erp_supply.work_executions e where e.catalog_id=c.id and e.status='COMPLETED' and e.active_seconds>0
      ) h on true
      where c.organization_id=v_org and c.active and(
        erp_supply.work_catalog_allowed(c.id,v_actor)
        or erp_supply.has_role('super_admin')
        or ((erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica')) and c.activity_kind='ACTIVITY' and c.activity_group in('LOGISTICS','GENERAL','IMPROVEMENT'))
        or (erp_supply.has_role('gerencia') and c.activity_kind in('ACTIVITY','DELIVERABLE') and c.activity_group in('COMMERCIAL','FINANCE','PURCHASING','MANAGEMENT','GENERAL','IMPROVEMENT'))
      )
    ) x
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.erp_x_work_catalog() from public,anon;
grant execute on function public.erp_x_work_catalog() to authenticated;

-- ---------------------------------------------------------------------------
-- 5. PROPUESTA PERSONAL: BUSCAR -> JUSTIFICAR -> PROGRAMAR -> APROBAR
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_propose_assignment(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_catalog_id uuid:=erp_supply.safe_uuid(p_payload->>'catalogId');
  v_catalog erp_supply.work_activity_catalog%rowtype;
  v_reason text:=regexp_replace(trim(coalesce(p_payload->>'reason','')),'\s+',' ','g');
  v_priority text:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_start timestamptz:=nullif(trim(p_payload->>'plannedStart'),'')::timestamptz;
  v_end timestamptz:=nullif(trim(p_payload->>'plannedEnd'),'')::timestamptz;
  v_minutes integer:=greatest(1,least(coalesce(erp_supply.safe_numeric(p_payload->>'estimatedMinutes')::integer,60),720));
  v_scope text:=erp_supply.work_approval_scope_for_profile(v_actor);
  v_assignment uuid;
  v_start_mode text:=upper(coalesce(nullif(trim(p_payload->>'startMode'),''),'SCHEDULED'));
  v_overlap boolean:=false;
  v_outside boolean:=false;
begin
  if v_catalog_id is null then raise exception 'Selecciona una actividad del catálogo'; end if;
  select * into v_catalog from erp_supply.work_activity_catalog where id=v_catalog_id and organization_id=v_org and active and activity_kind='ACTIVITY';
  if not found or not erp_supply.work_catalog_allowed(v_catalog_id,v_actor) then raise exception 'Actividad no disponible para tu perfil' using errcode='42501'; end if;
  if char_length(v_reason)<10 then raise exception 'Explica brevemente por qué necesitas realizar esta actividad (mínimo 10 caracteres)'; end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
  if v_start is null then raise exception 'Indica cuándo deseas realizar la actividad'; end if;
  if v_end is null then v_end:=v_start+(coalesce(v_catalog.standard_minutes,v_minutes)||' minutes')::interval; end if;
  if v_end<=v_start then raise exception 'La hora final debe ser posterior al inicio'; end if;
  v_minutes:=greatest(1,round(extract(epoch from(v_end-v_start))/60.0)::integer);

  select exists(
    select 1 from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id
    where m.profile_id=v_actor and a.status='PUBLISHED' and a.planned_start is not null and a.planned_end is not null
      and tstzrange(a.planned_start,a.planned_end,'[)') && tstzrange(v_start,v_end,'[)')
  ) into v_overlap;
  v_outside:=erp_supply.business_seconds_between(v_org,v_start,v_end)<greatest(0,extract(epoch from(v_end-v_start))::bigint)-60;

  insert into erp_supply.work_assignments(
    organization_id,catalog_id,title,description,assignment_kind,status,priority,planned_start,planned_end,
    estimated_minutes,evidence_policy,acceptance_required,assigned_by,request_origin,request_reason,approval_status,
    approval_scope,requested_by,requested_at,metadata
  ) values(
    v_org,v_catalog.id,v_catalog.name,v_catalog.description,'ACTIVITY','DRAFT',v_priority,v_start,v_end,
    v_minutes,v_catalog.evidence_policy,false,v_actor,'SELF_PROPOSED',v_reason,'PENDING',v_scope,v_actor,now(),
    jsonb_build_object('startMode',v_start_mode,'requestedOverlap',v_overlap,'requestedOutsideWorkingTime',v_outside,'createdVersion','10.24.0')
  ) returning id into v_assignment;

  insert into erp_supply.work_assignment_members(assignment_id,profile_id,status)
  values(v_assignment,v_actor,'PLANNED');

  insert into erp_supply.work_activity_events(organization_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_org,v_assignment,v_actor,v_actor,'ASSIGNMENT_APPROVAL_REQUESTED',jsonb_build_object(
    'catalogId',v_catalog.id,'reason',v_reason,'approvalScope',v_scope,'plannedStart',v_start,'plannedEnd',v_end,
    'overlap',v_overlap,'outsideWorkingTime',v_outside,'version','10.24.0'));

  return jsonb_build_object('success',true,'assignmentId',v_assignment,'approvalStatus','PENDING','approvalScope',v_scope,
    'overlap',v_overlap,'outsideWorkingTime',v_outside,'version','10.24.0');
end;
$$;
revoke all on function public.erp_x_work_propose_assignment(jsonb) from public,anon;
grant execute on function public.erp_x_work_propose_assignment(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. BANDEJA DE APROBACIÓN
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_work_pending_approvals()
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
  if not (erp_supply.work_can_approve_scope('LOGISTICS') or erp_supply.work_can_approve_scope('MANAGEMENT') or erp_supply.has_role('auditoria')) then
    raise exception 'No tienes permisos para revisar solicitudes de actividades' using errcode='42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x."plannedStart",x."requestedAt")
    from(
      select a.id,a.title,a.priority,a.planned_start "plannedStart",a.planned_end "plannedEnd",a.estimated_minutes "estimatedMinutes",
             a.request_reason "reason",a.approval_scope "approvalScope",a.requested_at "requestedAt",a.metadata,
             c.id "catalogId",c.name "catalogName",c.activity_group "activityGroup",c.evidence_policy "evidencePolicy",
             p.id "profileId",p.display_name "profileName",p.email,
             array(select pr.role_code from erp_supply.profile_roles pr where pr.profile_id=p.id order by pr.role_code) roles,
             exists(
               select 1 from erp_supply.work_assignment_members m2 join erp_supply.work_assignments a2 on a2.id=m2.assignment_id
               where m2.profile_id=p.id and a2.id<>a.id and a2.status='PUBLISHED' and a2.planned_start is not null and a2.planned_end is not null
                 and tstzrange(a2.planned_start,a2.planned_end,'[)') && tstzrange(a.planned_start,a.planned_end,'[)')
             ) "hasOverlap",
             (erp_supply.business_seconds_between(v_org,a.planned_start,a.planned_end)<greatest(0,extract(epoch from(a.planned_end-a.planned_start))::bigint)-60) "outsideWorkingTime"
      from erp_supply.work_assignments a
      join erp_supply.work_assignment_members m on m.assignment_id=a.id
      join erp_supply.profiles p on p.id=m.profile_id
      join erp_supply.work_activity_catalog c on c.id=a.catalog_id
      where a.organization_id=v_org and a.status='DRAFT' and a.approval_status='PENDING' and a.request_origin='SELF_PROPOSED'
        and (erp_supply.has_role('auditoria') or erp_supply.work_can_approve_scope(a.approval_scope))
    ) x
  ),'[]'::jsonb);
end;
$$;
revoke all on function public.erp_x_work_pending_approvals() from public,anon;
grant execute on function public.erp_x_work_pending_approvals() to authenticated;

create or replace function public.erp_x_work_decide_assignment(
  p_assignment_id uuid,
  p_decision text,
  p_note text default null,
  p_force boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_assignment erp_supply.work_assignments%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'')));
  v_note text:=nullif(regexp_replace(trim(coalesce(p_note,'')),'\s+',' ','g'),'');
  v_profile uuid;
  v_overlap boolean:=false;
  v_outside boolean:=false;
  v_shift interval;
begin
  select * into v_assignment from erp_supply.work_assignments
  where id=p_assignment_id and organization_id=v_org for update;
  if not found then raise exception 'Solicitud no disponible'; end if;
  if v_assignment.approval_status<>'PENDING' or v_assignment.status<>'DRAFT' then raise exception 'La solicitud ya fue decidida'; end if;
  if not erp_supply.work_can_approve_scope(v_assignment.approval_scope) then raise exception 'No autorizado para esta aprobación' using errcode='42501'; end if;
  if v_assignment.requested_by=v_actor and not erp_supply.has_role('super_admin') then raise exception 'No puedes aprobar tu propia solicitud'; end if;
  if v_decision not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if v_decision='REJECTED' and coalesce(char_length(v_note),0)<5 then raise exception 'Explica brevemente por qué se rechaza la actividad'; end if;

  select profile_id into v_profile from erp_supply.work_assignment_members where assignment_id=v_assignment.id order by assigned_at limit 1;

  if v_decision='APPROVED' then
    -- Si se pidió "Ahora" y la aprobación llegó después, el compromiso empieza desde la aprobación.
    if upper(coalesce(v_assignment.metadata->>'startMode',''))='NOW' and v_assignment.planned_start<now() then
      v_shift:=now()-v_assignment.planned_start;
      v_assignment.planned_start:=now();
      v_assignment.planned_end:=coalesce(v_assignment.planned_end,now())+v_shift;
    end if;

    select exists(
      select 1 from erp_supply.work_assignment_members m2 join erp_supply.work_assignments a2 on a2.id=m2.assignment_id
      where m2.profile_id=v_profile and a2.id<>v_assignment.id and a2.status='PUBLISHED' and a2.planned_start is not null and a2.planned_end is not null
        and tstzrange(a2.planned_start,a2.planned_end,'[)') && tstzrange(v_assignment.planned_start,v_assignment.planned_end,'[)')
    ) into v_overlap;
    v_outside:=erp_supply.business_seconds_between(v_org,v_assignment.planned_start,v_assignment.planned_end)
      <greatest(0,extract(epoch from(v_assignment.planned_end-v_assignment.planned_start))::bigint)-60;

    if (v_overlap or v_outside) and not p_force then
      return jsonb_build_object('success',false,'requiresConfirmation',true,'hasOverlap',v_overlap,'outsideWorkingTime',v_outside,
        'message',case when v_overlap and v_outside then 'La actividad se cruza con otra asignación y además invade tiempo no laborable.' when v_overlap then 'La actividad se cruza con otra asignación.' else 'La actividad invade tiempo no laborable.' end,
        'version','10.24.0');
    end if;

    update erp_supply.work_assignments set
      status='PUBLISHED',approval_status='APPROVED',decided_by=v_actor,decided_at=now(),decision_note=v_note,
      planned_start=v_assignment.planned_start,planned_end=v_assignment.planned_end,
      metadata=metadata||jsonb_build_object('approvedBy',v_actor,'approvedAt',now(),'forcedApproval',p_force,'version','10.24.0')
    where id=v_assignment.id;

    insert into erp_supply.work_activity_events(organization_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
    values(v_org,v_assignment.id,v_profile,v_actor,'ASSIGNMENT_APPROVED',jsonb_build_object('note',v_note,'forced',p_force,'version','10.24.0'));
  else
    update erp_supply.work_assignments set status='CANCELLED',approval_status='REJECTED',decided_by=v_actor,decided_at=now(),decision_note=v_note,
      metadata=metadata||jsonb_build_object('rejectedBy',v_actor,'rejectedAt',now(),'version','10.24.0') where id=v_assignment.id;
    update erp_supply.work_assignment_members set status='CANCELLED',cancelled_at=now(),metadata=metadata||jsonb_build_object('rejected',true,'version','10.24.0')
    where assignment_id=v_assignment.id;
    insert into erp_supply.work_activity_events(organization_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
    values(v_org,v_assignment.id,v_profile,v_actor,'ASSIGNMENT_REJECTED',jsonb_build_object('note',v_note,'version','10.24.0'));
  end if;

  return jsonb_build_object('success',true,'assignmentId',v_assignment.id,'decision',v_decision,'version','10.24.0');
end;
$$;
revoke all on function public.erp_x_work_decide_assignment(uuid,text,text,boolean) from public,anon;
grant execute on function public.erp_x_work_decide_assignment(uuid,text,text,boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. ARRANQUE CONTROLADO: USUARIOS OPERATIVOS SOLO DESDE ASIGNACIÓN APROBADA
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
  v_direct boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica');
begin
  if exists(select 1 from erp_supply.work_executions where profile_id=v_actor and status in('IN_PROGRESS','PAUSED')) then
    raise exception 'Ya tienes una actividad cronometrada. Finalízala antes de iniciar otra.';
  end if;
  if exists(select 1 from erp_supply.cut_executions where started_by=v_actor and status='IN_PROGRESS') then
    raise exception 'Tienes un corte en ejecución. Pausa o termina Corte antes de iniciar una actividad varias.';
  end if;

  select * into v_catalog from erp_supply.work_activity_catalog where id=p_catalog_id and organization_id=v_org and active;
  if not found or not erp_supply.work_catalog_allowed(p_catalog_id,v_actor) then raise exception 'Actividad no disponible para tu perfil' using errcode='42501'; end if;

  if p_assignment_id is not null then
    select * into v_assignment from erp_supply.work_assignments where id=p_assignment_id and organization_id=v_org and status='PUBLISHED' for update;
    if not found then raise exception 'La actividad programada no está aprobada o ya no está disponible'; end if;
    if v_assignment.approval_status='PENDING' or v_assignment.approval_status='REJECTED' then raise exception 'Esta actividad todavía no tiene autorización para iniciar'; end if;
    select * into v_member from erp_supply.work_assignment_members where assignment_id=v_assignment.id and profile_id=v_actor for update;
    if not found then raise exception 'Esta actividad no está asignada a tu perfil' using errcode='42501'; end if;
    if v_member.status in('COMPLETED','CANCELLED') then raise exception 'Esta actividad ya fue cerrada'; end if;
    if v_assignment.catalog_id is not null and v_assignment.catalog_id<>p_catalog_id then raise exception 'El tipo de actividad no coincide con la programación'; end if;
    if v_assignment.planned_start is not null and now()<v_assignment.planned_start-interval '15 minutes' then
      raise exception 'Esta actividad estará disponible 15 minutos antes del horario programado';
    end if;
    v_title:=v_assignment.title;
    if v_assignment.planned_start is not null then v_delay:=abs(extract(epoch from(now()-v_assignment.planned_start))::bigint); end if;
  else
    if not v_direct then raise exception 'Para iniciar una actividad adicional primero debes agregarla a tu jornada y obtener la aprobación correspondiente' using errcode='42501'; end if;
    v_title:=coalesce(nullif(trim(p_payload->>'title'),''),v_catalog.name);
  end if;

  insert into erp_supply.work_executions(
    organization_id,assignment_id,assignment_member_id,catalog_id,profile_id,source,status,title_snapshot,
    started_at,start_delay_seconds,related_entity_type,related_entity_id,metadata
  ) values(
    v_org,p_assignment_id,v_member.id,p_catalog_id,v_actor,case when p_assignment_id is null then 'MANUAL' else 'PLANNED' end,
    'IN_PROGRESS',v_title,now(),v_delay,nullif(trim(p_payload->>'relatedEntityType'),''),nullif(trim(p_payload->>'relatedEntityId'),''),
    coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('startedVersion','10.24.0')
  ) returning * into v_exec;

  if p_assignment_id is not null then
    update erp_supply.work_assignment_members set status='IN_PROGRESS',first_started_at=coalesce(first_started_at,now()) where id=v_member.id;
  end if;
  insert into erp_supply.work_activity_events(organization_id,execution_id,assignment_id,profile_id,actor_profile_id,event_type,payload)
  values(v_org,v_exec.id,p_assignment_id,v_actor,v_actor,'EXECUTION_STARTED',jsonb_build_object('catalogId',p_catalog_id,'source',v_exec.source,'version','10.24.0'));

  return jsonb_build_object('success',true,'executionId',v_exec.id,'status',v_exec.status,'startedAt',v_exec.started_at,'title',v_exec.title_snapshot,
    'metrics',erp_supply.work_execution_metrics(v_exec.id),'version','10.24.0');
end;
$$;
revoke all on function public.erp_x_work_start(uuid,uuid,jsonb) from public,anon;
grant execute on function public.erp_x_work_start(uuid,uuid,jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. PLANIFICADOR: LÍDERES LOGÍSTICOS + JEFATURA + GERENCIA
--    Gerencia puede asignar ACTIVIDAD o ENTREGABLE a Ventas/Compras/Cartera/Caja.
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
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria')) then
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
      where p.organization_id=v_org and p.active and(
        erp_supply.has_role('auditoria') or (v_kind is not null and erp_supply.can_manage_work_profile(p.id,v_kind))
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
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia')) then
    raise exception 'No tienes permisos de planificación' using errcode='42501';
  end if;
  return jsonb_build_object(
    'from',v_from,'to',v_to,'people',public.erp_x_work_people(null),
    'assignments',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."plannedStart" nulls last,x."dueAt" nulls last,x.title),'[]'::jsonb)
      from(
        select a.id,a.series_id "seriesId",a.title,a.description,a.assignment_kind "kind",a.status,a.priority,
               a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",a.estimated_minutes "estimatedMinutes",
               a.evidence_policy "evidencePolicy",a.acceptance_required "acceptanceRequired",a.catalog_id "catalogId",c.name "catalogName",
               p.id "profileId",p.display_name "profileName",m.id "memberId",m.status "memberStatus",a.assigned_by "assignedBy",
               a.request_origin "requestOrigin",a.request_reason "requestReason",a.approval_status "approvalStatus",a.approval_scope "approvalScope",
               a.recurrence,a.metadata
        from erp_supply.work_assignments a join erp_supply.work_assignment_members m on m.assignment_id=a.id
        join erp_supply.profiles p on p.id=m.profile_id left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where a.organization_id=v_org and a.status='PUBLISHED' and erp_supply.can_manage_work_profile(p.id,a.assignment_kind)
          and ((a.planned_start is not null and a.planned_start<v_end and coalesce(a.planned_end,a.planned_start+interval '1 minute')>v_start)
            or (a.planned_start is null and a.due_at>=v_start and a.due_at<v_end))
      ) x
    ),
    'permissions',jsonb_build_object(
      'logistics',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('super_admin'),
      'management',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'deliverables',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'approvals',erp_supply.work_can_approve_scope('LOGISTICS') or erp_supply.work_can_approve_scope('MANAGEMENT'),
      'all',erp_supply.has_role('super_admin')
    ),
    'serverTime',now(),'version','10.24.0'
  );
end;
$$;
revoke all on function public.erp_x_work_planner(date,date) from public,anon;
grant execute on function public.erp_x_work_planner(date,date) to authenticated;

-- Reutiliza el motor de asignación existente, pero abre permisos a Líder Logístico
-- y a Gerencia para actividades de sus propias áreas. El resto del contrato se conserva.
create or replace function erp_supply.work_can_publish_assignment(p_kind text,p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$ select erp_supply.can_manage_work_profile(p_profile_id,upper(coalesce(p_kind,'ACTIVITY'))) $$;
revoke all on function erp_supply.work_can_publish_assignment(text,uuid) from public;

-- ---------------------------------------------------------------------------
-- 8B. PUBLICACIÓN DIRECTA POR RESPONSABLE AUTORIZADO
-- ---------------------------------------------------------------------------
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
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia')) then raise exception 'No tienes permisos para asignar actividades' using errcode='42501'; end if;
  if v_kind not in('ACTIVITY','DELIVERABLE') then raise exception 'Tipo de asignación inválido'; end if;
  if v_kind='ACTIVITY' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia')) then raise exception 'No tienes permisos para programar actividades'; end if;
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
      related_entity_type,related_entity_id,recurrence,metadata,request_origin,approval_status,requested_by,requested_at
    ) values(
      v_org,v_catalog_id,v_series,v_title,v_description,v_kind,'PUBLISHED',v_priority,
      v_occurrence_start,v_occurrence_end,v_occurrence_due,v_estimated,v_evidence,v_acceptance,v_actor,
      nullif(trim(p_payload->>'relatedEntityType'),''),nullif(trim(p_payload->>'relatedEntityId'),''),
      coalesce(p_payload->'recurrence','{}'::jsonb),
      coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('createdVersion','10.24.0','forcedConflict',v_force),
      'MANAGER_ASSIGNED','NOT_REQUIRED',v_actor,now()
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

  return jsonb_build_object('success',true,'requiresConfirmation',false,'conflicts',v_conflicts,'createdIds',v_created,'seriesId',v_series,'version','10.24.0');
end;
$$;

revoke all on function public.erp_x_work_save_assignment(jsonb) from public,anon;
grant execute on function public.erp_x_work_save_assignment(jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- 8C. ANALÍTICA HEREDA EL NUEVO ÁMBITO DE LÍDER LOGÍSTICO
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
  v_manager boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria');
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
    'version','10.24.0','serverTime',now()
  );
end;
$$;

revoke all on function public.erp_x_work_analytics(date,date,uuid) from public,anon;
grant execute on function public.erp_x_work_analytics(date,date,uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- 9. OCUPACIÓN: PROCESO ERP + ACTIVIDADES VARIAS + SOLAPAMIENTO EXPLÍCITO
-- ---------------------------------------------------------------------------
create or replace function erp_supply.work_source_business_seconds(
  p_profile_id uuid,
  p_start timestamptz,
  p_end timestamptz,
  p_source text
)
returns bigint
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
  with profile_ctx as(
    select p.organization_id from erp_supply.profiles p where p.id=p_profile_id
  ),
  entries as(
    select s.started_at start_at,least(coalesce(s.ended_at,now()),p_end) end_at
    from erp_supply.task_sessions s
    join erp_supply.order_tasks t on t.id=s.task_id join erp_supply.orders o on o.id=t.order_id
    join profile_ctx pc on pc.organization_id=o.organization_id
    where upper(p_source)='ERP' and s.profile_id=p_profile_id and s.started_at<p_end and coalesce(s.ended_at,now())>p_start
    union all
    select c.started_at,least(coalesce(c.completed_at,now()),p_end)
    from erp_supply.cut_executions c join profile_ctx pc on pc.organization_id=c.organization_id
    where upper(p_source)='ERP' and c.started_by=p_profile_id and c.status<>'CANCELLED' and c.started_at<p_end and coalesce(c.completed_at,now())>p_start
    union all
    select e.started_at,least(coalesce(e.ended_at,now()),p_end)
    from erp_supply.work_executions e join profile_ctx pc on pc.organization_id=e.organization_id
    where upper(p_source)='ACTIVITY' and e.profile_id=p_profile_id and e.status<>'CANCELLED' and e.started_at<p_end and coalesce(e.ended_at,now())>p_start
  ),
  clipped as(
    select tstzrange(greatest(start_at,p_start),least(end_at,p_end),'[)') r from entries
    where greatest(start_at,p_start)<least(end_at,p_end)
  ),
  merged as(select unnest(range_agg(r)) r from clipped)
  select coalesce(sum(erp_supply.business_seconds_between((select organization_id from profile_ctx),lower(r),upper(r))),0) from merged
$$;
revoke all on function erp_supply.work_source_business_seconds(uuid,timestamptz,timestamptz,text) from public;

-- Incluye ahora Corte agrupado como trabajo fijo del auxiliar de corte.
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
  with profile_ctx as(select p.organization_id from erp_supply.profiles p where p.id=p_profile_id),
  entries as(
    select s.started_at start_at,least(coalesce(s.ended_at,now()),p_end) end_at
    from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id join erp_supply.orders o on o.id=t.order_id
    join profile_ctx pc on pc.organization_id=o.organization_id
    where s.profile_id=p_profile_id and s.started_at<p_end and coalesce(s.ended_at,now())>p_start
    union all
    select c.started_at,least(coalesce(c.completed_at,now()),p_end)
    from erp_supply.cut_executions c join profile_ctx pc on pc.organization_id=c.organization_id
    where c.started_by=p_profile_id and c.status<>'CANCELLED' and c.started_at<p_end and coalesce(c.completed_at,now())>p_start
    union all
    select e.started_at,least(coalesce(e.ended_at,now()),p_end)
    from erp_supply.work_executions e join profile_ctx pc on pc.organization_id=e.organization_id
    where e.profile_id=p_profile_id and e.status<>'CANCELLED' and e.started_at<p_end and coalesce(e.ended_at,now())>p_start
  ),
  clipped as(select tstzrange(greatest(start_at,p_start),least(end_at,p_end),'[)') r from entries where greatest(start_at,p_start)<least(end_at,p_end)),
  merged as(select unnest(range_agg(r)) r from clipped)
  select coalesce(sum(erp_supply.business_seconds_between((select organization_id from profile_ctx),lower(r),upper(r))),0) from merged
$$;
revoke all on function erp_supply.work_classified_business_seconds(uuid,timestamptz,timestamptz) from public;

create or replace function erp_supply.work_profile_occupation_summary(
  p_profile_id uuid,p_start timestamptz,p_end timestamptz
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_sched bigint:=0;v_fixed bigint:=0;v_misc bigint:=0;v_total bigint:=0;v_overlap bigint:=0;
begin
  v_sched:=erp_supply.business_seconds_between(v_org,p_start,p_end);
  v_fixed:=erp_supply.work_source_business_seconds(p_profile_id,p_start,p_end,'ERP');
  v_misc:=erp_supply.work_source_business_seconds(p_profile_id,p_start,p_end,'ACTIVITY');
  v_total:=erp_supply.work_classified_business_seconds(p_profile_id,p_start,p_end);
  v_overlap:=greatest(v_fixed+v_misc-v_total,0);
  return jsonb_build_object(
    'scheduledBusinessSeconds',v_sched,'fixedProcessSeconds',v_fixed,'miscActivitySeconds',v_misc,
    'classifiedSeconds',v_total,'overlapSeconds',v_overlap,'unclassifiedSeconds',greatest(v_sched-v_total,0),
    'occupationPct',case when v_sched=0 then 0 else round((100.0*v_total/v_sched)::numeric,1) end,
    'fixedPct',case when v_sched=0 then 0 else round((100.0*v_fixed/v_sched)::numeric,1) end,
    'miscPct',case when v_sched=0 then 0 else round((100.0*v_misc/v_sched)::numeric,1) end
  );
end;
$$;
revoke all on function erp_supply.work_profile_occupation_summary(uuid,timestamptz,timestamptz) from public;

create or replace function public.erp_x_work_occupation(p_from date,p_to date,p_profile_id uuid default null)
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
  v_from date:=coalesce(p_from,current_date);
  v_to date:=coalesce(p_to,v_from);
  v_start timestamptz:=(v_from::timestamp at time zone v_tz);
  v_end timestamptz:=((v_to+1)::timestamp at time zone v_tz);
  v_team_mode boolean:=p_profile_id is null and (erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia'));
  v_profile uuid:=coalesce(p_profile_id,v_actor);
  v_summary jsonb;v_team jsonb:='[]'::jsonb;
  v_sched bigint:=0;v_fixed bigint:=0;v_misc bigint:=0;v_total bigint:=0;v_overlap bigint:=0;v_unclassified bigint:=0;
begin
  if v_to<v_from or v_to-v_from>366 then raise exception 'Rango de ocupación inválido'; end if;

  if v_team_mode then
    select coalesce(jsonb_agg(to_jsonb(x) order by x."occupationPct" desc,x.name),'[]'::jsonb),
           coalesce(sum(x."scheduledBusinessSeconds"),0),coalesce(sum(x."fixedProcessSeconds"),0),coalesce(sum(x."miscActivitySeconds"),0),
           coalesce(sum(x."classifiedSeconds"),0),coalesce(sum(x."overlapSeconds"),0),coalesce(sum(x."unclassifiedSeconds"),0)
    into v_team,v_sched,v_fixed,v_misc,v_total,v_overlap,v_unclassified
    from(
      select p.id,p.display_name name,
             array(select pr.role_code from erp_supply.profile_roles pr where pr.profile_id=p.id order by pr.role_code) roles,
             (sm.metrics->>'scheduledBusinessSeconds')::bigint "scheduledBusinessSeconds",
             (sm.metrics->>'fixedProcessSeconds')::bigint "fixedProcessSeconds",
             (sm.metrics->>'miscActivitySeconds')::bigint "miscActivitySeconds",
             (sm.metrics->>'classifiedSeconds')::bigint "classifiedSeconds",
             (sm.metrics->>'overlapSeconds')::bigint "overlapSeconds",
             (sm.metrics->>'unclassifiedSeconds')::bigint "unclassifiedSeconds",
             (sm.metrics->>'occupationPct')::numeric "occupationPct",
             (sm.metrics->>'fixedPct')::numeric "fixedPct",
             (sm.metrics->>'miscPct')::numeric "miscPct"
      from erp_supply.profiles p
      cross join lateral (select erp_supply.work_profile_occupation_summary(p.id,v_start,v_end) metrics) sm
      where p.organization_id=v_org and p.active and(
        erp_supply.has_role('auditoria') or erp_supply.has_role('super_admin')
        or erp_supply.can_manage_work_profile(p.id,'ACTIVITY') or erp_supply.can_manage_work_profile(p.id,'DELIVERABLE')
      )
    ) x;
    v_summary:=jsonb_build_object(
      'scheduledBusinessSeconds',v_sched,'fixedProcessSeconds',v_fixed,'miscActivitySeconds',v_misc,'classifiedSeconds',v_total,
      'overlapSeconds',v_overlap,'unclassifiedSeconds',v_unclassified,
      'occupationPct',case when v_sched=0 then 0 else round((100.0*v_total/v_sched)::numeric,1) end,
      'fixedPct',case when v_sched=0 then 0 else round((100.0*v_fixed/v_sched)::numeric,1) end,
      'miscPct',case when v_sched=0 then 0 else round((100.0*v_misc/v_sched)::numeric,1) end
    );
    return jsonb_build_object('mode','TEAM','from',v_from,'to',v_to,'summary',v_summary,'team',v_team,'fixedBreakdown','[]'::jsonb,'miscBreakdown','[]'::jsonb,'version','10.24.0','serverTime',now());
  end if;

  if v_profile<>v_actor and not (erp_supply.has_role('super_admin') or erp_supply.has_role('auditoria') or erp_supply.can_manage_work_profile(v_profile,'ACTIVITY') or erp_supply.can_manage_work_profile(v_profile,'DELIVERABLE')) then
    raise exception 'No autorizado para consultar esta ocupación' using errcode='42501';
  end if;
  v_summary:=erp_supply.work_profile_occupation_summary(v_profile,v_start,v_end);

  return jsonb_build_object(
    'mode','PERSON','profileId',v_profile,'from',v_from,'to',v_to,'summary',v_summary,'team','[]'::jsonb,
    'fixedBreakdown',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x.seconds desc),'[]'::jsonb) from(
        select label,sum(seconds)::bigint seconds from(
          select ws.name label,coalesce(sum(erp_supply.business_seconds_between(v_org,greatest(s.started_at,v_start),least(coalesce(s.ended_at,now()),v_end))),0)::bigint seconds
          from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id join erp_supply.orders o on o.id=t.order_id join erp_supply.workflow_steps ws on ws.code=t.step_code
          where s.profile_id=v_profile and o.organization_id=v_org and s.started_at<v_end and coalesce(s.ended_at,now())>v_start group by ws.name
          union all
          select 'Corte por referencia',coalesce(sum(erp_supply.business_seconds_between(v_org,greatest(c.started_at,v_start),least(coalesce(c.completed_at,now()),v_end))),0)::bigint
          from erp_supply.cut_executions c where c.organization_id=v_org and c.started_by=v_profile and c.status<>'CANCELLED' and c.started_at<v_end and coalesce(c.completed_at,now())>v_start
        ) q group by label
      ) x
    ),
    'miscBreakdown',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x.seconds desc),'[]'::jsonb) from(
        select c.activity_group "group",sum(erp_supply.business_seconds_between(v_org,greatest(e.started_at,v_start),least(coalesce(e.ended_at,now()),v_end)))::bigint seconds,count(*)::integer executions
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id
        where e.organization_id=v_org and e.profile_id=v_profile and e.status<>'CANCELLED' and e.started_at<v_end and coalesce(e.ended_at,now())>v_start
        group by c.activity_group
      ) x
    ),
    'version','10.24.0','serverTime',now()
  );
end;
$$;
revoke all on function public.erp_x_work_occupation(date,date,uuid) from public,anon;
grant execute on function public.erp_x_work_occupation(date,date,uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. MI JORNADA ENRIQUECIDA CON APROBACIONES Y OCUPACIÓN
-- ---------------------------------------------------------------------------
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
  v_erp_active jsonb;
  v_sched bigint;v_fixed bigint;v_misc bigint;v_total bigint;
begin
  select to_jsonb(x) into v_active from(
    select e.id,e.status,e.source,e.title_snapshot "title",e.started_at "startedAt",e.ended_at "endedAt",
           e.assignment_id "assignmentId",e.catalog_id "catalogId",c.name "catalogName",coalesce(a.evidence_policy,c.evidence_policy) "evidencePolicy",
           coalesce(a.estimated_minutes,c.standard_minutes) "estimatedMinutes",a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",
           erp_supply.work_execution_metrics(e.id) metrics,
           (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'type',w.evidence_type,'fileName',w.file_name,'webViewLink',w.web_view_link,'value',w.external_value,'createdAt',w.created_at) order by w.created_at),'[]'::jsonb) from erp_supply.work_evidence w where w.execution_id=e.id) evidence
    from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id left join erp_supply.work_assignments a on a.id=e.assignment_id
    where e.profile_id=v_actor and e.status in('IN_PROGRESS','PAUSED') order by e.started_at desc limit 1
  ) x;

  select to_jsonb(x) into v_erp_active from(
    select * from(
      select 'CUTTING' type,'Corte por referencia · '||coalesce(c.reference,c.description) title,c.started_at "startedAt",c.status
      from erp_supply.cut_executions c where c.started_by=v_actor and c.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
      union all
      select 'ERP_TASK',o.order_number||' · '||ws.name,s.started_at,t.status
      from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id join erp_supply.orders o on o.id=t.order_id join erp_supply.workflow_steps ws on ws.code=t.step_code
      where s.profile_id=v_actor and s.ended_at is null
    ) q order by "startedAt" desc limit 1
  ) x;

  v_sched:=erp_supply.business_seconds_between(v_org,v_start,v_end);
  v_fixed:=erp_supply.work_source_business_seconds(v_actor,v_start,v_end,'ERP');
  v_misc:=erp_supply.work_source_business_seconds(v_actor,v_start,v_end,'ACTIVITY');
  v_total:=erp_supply.work_classified_business_seconds(v_actor,v_start,v_end);

  return jsonb_build_object(
    'day',v_day,'active',v_active,'erpActive',v_erp_active,'catalog',public.erp_x_work_catalog(),
    'today',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."plannedStart" nulls last,x."dueAt" nulls last,x.priority),'[]'::jsonb) from(
        select a.id,m.id "memberId",a.title,a.description,a.assignment_kind "kind",a.priority,a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",
               a.estimated_minutes "estimatedMinutes",a.evidence_policy "evidencePolicy",a.acceptance_required "acceptanceRequired",m.status "memberStatus",
               c.name "catalogName",c.code "catalogCode",c.id "catalogId",a.request_origin "requestOrigin",a.request_reason "requestReason",a.approval_status "approvalStatus"
        from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED' and m.status not in('COMPLETED','CANCELLED')
          and ((a.planned_start>=v_start and a.planned_start<v_end) or (a.planned_start is null and a.due_at>=v_start and a.due_at<v_end))
      ) x
    ),
    'overdue',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."dueAt"),'[]'::jsonb) from(
        select a.id,m.id "memberId",a.title,a.assignment_kind "kind",a.priority,a.due_at "dueAt",a.planned_start "plannedStart",a.planned_end "plannedEnd",
               a.estimated_minutes "estimatedMinutes",m.status "memberStatus",c.name "catalogName",c.id "catalogId",a.approval_status "approvalStatus"
        from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED' and m.status not in('COMPLETED','CANCELLED','SUBMITTED')
          and coalesce(a.due_at,a.planned_end)<v_start
      ) x
    ),
    'upcoming',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."nextAt"),'[]'::jsonb) from(
        select a.id,a.title,a.assignment_kind "kind",a.priority,a.planned_start "plannedStart",a.planned_end "plannedEnd",a.due_at "dueAt",coalesce(a.planned_start,a.due_at) "nextAt",m.status "memberStatus",c.name "catalogName"
        from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.organization_id=v_org and a.status='PUBLISHED' and m.status not in('COMPLETED','CANCELLED')
          and coalesce(a.planned_start,a.due_at)>=v_end and coalesce(a.planned_start,a.due_at)<v_end+interval '7 days'
        order by coalesce(a.planned_start,a.due_at) limit 12
      ) x
    ),
    'pendingRequests',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."plannedStart"),'[]'::jsonb) from(
        select a.id,a.title,a.request_reason "reason",a.priority,a.planned_start "plannedStart",a.planned_end "plannedEnd",a.approval_scope "approvalScope",
               a.approval_status "approvalStatus",a.requested_at "requestedAt",c.name "catalogName"
        from erp_supply.work_assignments a join erp_supply.work_assignment_members m on m.assignment_id=a.id left join erp_supply.work_activity_catalog c on c.id=a.catalog_id
        where m.profile_id=v_actor and a.request_origin='SELF_PROPOSED' and a.approval_status='PENDING' and a.status='DRAFT'
      ) x
    ),
    'requestHistory',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."decidedAt" desc),'[]'::jsonb) from(
        select a.id,a.title,a.approval_status "approvalStatus",a.decision_note "decisionNote",a.decided_at "decidedAt",
               a.planned_start "plannedStart",a.planned_end "plannedEnd",d.display_name "decidedBy"
        from erp_supply.work_assignments a
        left join erp_supply.profiles d on d.id=a.decided_by
        where a.requested_by=v_actor and a.request_origin='SELF_PROPOSED' and a.approval_status in('APPROVED','REJECTED')
          and a.decided_at>=now()-interval '7 days'
        order by a.decided_at desc limit 6
      ) x
    ),
    'history',(
      select coalesce(jsonb_agg(to_jsonb(x) order by x."startedAt" desc),'[]'::jsonb) from(
        select e.id,e.title_snapshot "title",e.status,e.started_at "startedAt",e.ended_at "endedAt",e.active_seconds "activeSeconds",e.business_seconds "businessSeconds",e.paused_seconds "pausedSeconds",
               c.name "catalogName",c.activity_group "activityGroup",e.result_note "resultNote",coalesce(a.evidence_policy,c.evidence_policy) "evidencePolicy",
               coalesce(a.acceptance_required,c.acceptance_required,false) "acceptanceRequired",
               (select coalesce(jsonb_agg(jsonb_build_object('id',w.id,'type',w.evidence_type,'fileName',w.file_name,'webViewLink',w.web_view_link,'value',w.external_value,'createdAt',w.created_at) order by w.created_at),'[]'::jsonb) from erp_supply.work_evidence w where w.execution_id=e.id) evidence
        from erp_supply.work_executions e join erp_supply.work_activity_catalog c on c.id=e.catalog_id left join erp_supply.work_assignments a on a.id=e.assignment_id
        where e.profile_id=v_actor and e.started_at>=v_start and e.started_at<v_end order by e.started_at desc limit 30
      ) x
    ),
    'summary',jsonb_build_object(
      'completed',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='COMPLETED' and e.ended_at>=v_start and e.ended_at<v_end),
      'scheduledBusinessSeconds',v_sched,'fixedProcessSeconds',v_fixed,'miscActivitySeconds',v_misc,'classifiedSeconds',v_total,
      'overlapSeconds',greatest(v_fixed+v_misc-v_total,0),'unclassifiedSeconds',greatest(v_sched-v_total,0),
      'occupationPct',case when v_sched=0 then 0 else round((100.0*v_total/v_sched)::numeric,1) end,
      'plannedMinutes',(select coalesce(sum(a.estimated_minutes),0) from erp_supply.work_assignment_members m join erp_supply.work_assignments a on a.id=m.assignment_id where m.profile_id=v_actor and a.status='PUBLISHED' and a.planned_start>=v_start and a.planned_start<v_end),
      'pendingApproval',(select count(*) from erp_supply.work_assignments a where a.requested_by=v_actor and a.approval_status='PENDING'),
      'pendingEvidence',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='WAITING_EVIDENCE'),
      'pendingReview',(select count(*) from erp_supply.work_executions e where e.profile_id=v_actor and e.status='SUBMITTED')
    ),
    'permissions',jsonb_build_object(
      'canPropose',true,
      'approvalScope',erp_supply.work_approval_scope_for_profile(v_actor),
      'canDirectStart',erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica'),
      'canPlanLogistics',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('super_admin'),
      'canPlanManagement',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'canPlanDeliverables',erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'),
      'canApproveActivities',erp_supply.work_can_approve_scope('LOGISTICS') or erp_supply.work_can_approve_scope('MANAGEMENT'),
      'canViewTeam',erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')
    ),
    'serverTime',now(),'version','10.24.0'
  );
end;
$$;
revoke all on function public.erp_x_work_my_day(date) from public,anon;
grant execute on function public.erp_x_work_my_day(date) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. DIAGNÓSTICO
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
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('lider_logistica') or erp_supply.has_role('auditoria')) then
    raise exception 'No autorizado para diagnóstico de actividades' using errcode='42501';
  end if;
  return query select 'Módulo transversal para todos los roles',not exists(
    select 1 from erp_supply.roles r where r.active and not exists(select 1 from erp_supply.role_module_permissions p where p.role_code=r.code and p.module_code='workforce' and p.can_read and p.can_create)
  ),'Todos los roles activos deben poder consultar y registrar Mi Jornada';
  return query select 'Solicitudes personales gobernadas',not exists(
    select 1 from erp_supply.work_assignments a where a.request_origin='SELF_PROPOSED' and a.status='PUBLISHED' and a.approval_status<>'APPROVED'
  ),'Ninguna propuesta personal puede publicarse sin aprobación';
  return query select 'Aprobaciones con responsable correcto',not exists(
    select 1 from erp_supply.work_assignments a where a.request_origin='SELF_PROPOSED' and a.approval_status='APPROVED' and a.decided_by is null
  ),'Toda actividad auto-propuesta aprobada conserva quién decidió';
  return query select 'Una actividad varias cronometrada por persona',not exists(
    select 1 from erp_supply.work_executions e where e.status in('IN_PROGRESS','PAUSED') group by e.profile_id having count(*)>1
  ),'No puede existir más de una actividad varias cronometrada simultáneamente por perfil';
  return query select 'Pausas consistentes',not exists(
    select 1 from erp_supply.work_execution_pauses p join erp_supply.work_executions e on e.id=p.execution_id where p.ended_at is null and e.status<>'PAUSED'
  ),'Toda pausa abierta debe corresponder a una ejecución PAUSED';
  return query select 'Catálogo dinámico trazable',not exists(
    select 1 from erp_supply.work_activity_catalog c where c.catalog_origin='MANAGER_CREATED' and c.created_by is null
  ),'Toda actividad creada por liderazgo conserva quién la creó';
  return query select 'Liderazgo logístico habilitado',exists(
    select 1 from erp_supply.roles r join erp_supply.role_module_permissions p on p.role_code=r.code and p.module_code='workforce'
    where r.code='lider_logistica' and r.active and p.can_approve and p.can_admin
  ),'El rol Líder logístico debe poder asignar y aprobar actividades';
  return query select 'Ocupación incluye Corte',pg_get_functiondef('erp_supply.work_classified_business_seconds(uuid,timestamptz,timestamptz)'::regprocedure) like '%cut_executions%',
    'La ocupación fija del auxiliar de corte debe incluir ejecuciones de Corte agrupado';
end;
$$;
revoke all on function public.erp_x_work_health() from public,anon;
grant execute on function public.erp_x_work_health() to authenticated;

notify pgrst,'reload schema';
commit;
