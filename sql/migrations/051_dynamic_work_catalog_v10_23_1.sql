-- ERP EI V10.23.1
-- Catálogo dinámico de actividades: Jefatura Logística y Gerencia pueden crear
-- nuevos tipos de trabajo desde el planificador. La actividad creada queda en el
-- catálogo oficial de la organización y puede reutilizarse en futuras asignaciones.

begin;

alter table erp_supply.work_activity_catalog
  add column if not exists created_by uuid references erp_supply.profiles(id),
  add column if not exists catalog_origin text not null default 'SYSTEM',
  add column if not exists archived_at timestamptz;

alter table erp_supply.work_activity_catalog
  drop constraint if exists work_activity_catalog_catalog_origin_check;
alter table erp_supply.work_activity_catalog
  add constraint work_activity_catalog_catalog_origin_check
  check(catalog_origin in('SYSTEM','MANAGER_CREATED'));

create index if not exists idx_work_activity_catalog_custom
on erp_supply.work_activity_catalog(organization_id,catalog_origin,created_at desc)
where catalog_origin='MANAGER_CREATED';

-- Los registros históricos ya existentes pertenecen al catálogo base salvo que
-- una versión futura indique explícitamente lo contrario.
update erp_supply.work_activity_catalog
set catalog_origin=coalesce(nullif(catalog_origin,''),'SYSTEM')
where catalog_origin is null or catalog_origin='';

create or replace function erp_supply.work_manager_catalog_roles(p_kind text)
returns text[]
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
begin
  if erp_supply.has_role('super_admin') then
    if upper(coalesce(p_kind,'ACTIVITY'))='DELIVERABLE' then
      return array['ventas','jefe_logistica','compras','cartera','gerencia']::text[];
    end if;
    return array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[];
  end if;

  if upper(coalesce(p_kind,'ACTIVITY'))='ACTIVITY' and erp_supply.has_role('jefe_logistica') then
    return array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[];
  end if;

  if upper(coalesce(p_kind,'DELIVERABLE'))='DELIVERABLE' and erp_supply.has_role('gerencia') then
    return array['ventas','jefe_logistica','compras','cartera']::text[];
  end if;

  return '{}'::text[];
end;
$$;
revoke all on function erp_supply.work_manager_catalog_roles(text) from public;

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
  v_name text:=regexp_replace(trim(coalesce(p_payload->>'name','')),'\s+',' ','g');
  v_description text:=nullif(trim(p_payload->>'description'),'');
  v_group text:=upper(coalesce(nullif(trim(p_payload->>'activityGroup'),''),case when v_kind='DELIVERABLE' then 'MANAGEMENT' else 'LOGISTICS' end));
  v_minutes integer:=greatest(1,least(coalesce(erp_supply.safe_numeric(p_payload->>'standardMinutes')::integer,60),1440));
  v_evidence text:=upper(coalesce(nullif(trim(p_payload->>'evidencePolicy'),''),case when v_kind='DELIVERABLE' then 'FILE' else 'FINAL_PHOTO' end));
  v_acceptance boolean:=coalesce((p_payload->>'acceptanceRequired')::boolean,v_kind='DELIVERABLE');
  v_team boolean:=coalesce((p_payload->>'teamAllowed')::boolean,v_kind='ACTIVITY');
  v_roles text[]:=erp_supply.work_manager_catalog_roles(v_kind);
  v_existing erp_supply.work_activity_catalog%rowtype;
  v_created erp_supply.work_activity_catalog%rowtype;
  v_code text;
begin
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia')) then
    raise exception 'No tienes permisos para crear actividades del catálogo' using errcode='42501';
  end if;

  if v_kind not in('ACTIVITY','DELIVERABLE') then
    raise exception 'Tipo de actividad inválido';
  end if;

  if v_kind='ACTIVITY' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'Solo Jefatura Logística puede crear actividades operativas' using errcode='42501';
  end if;

  if v_kind='DELIVERABLE' and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then
    raise exception 'Solo Gerencia puede crear tipos de entregable' using errcode='42501';
  end if;

  if char_length(v_name)<3 or char_length(v_name)>120 then
    raise exception 'El nombre de la actividad debe tener entre 3 y 120 caracteres';
  end if;

  if v_evidence not in('NONE','FINAL_PHOTO','BEFORE_AFTER','FILE','LINK','ERP_REFERENCE') then
    raise exception 'Política de evidencia inválida';
  end if;

  if v_kind='ACTIVITY' and v_group not in('LOGISTICS','GENERAL','IMPROVEMENT') then
    raise exception 'Categoría no habilitada para actividades logísticas';
  end if;

  if v_kind='DELIVERABLE' and v_group not in('COMMERCIAL','FINANCE','PURCHASING','MANAGEMENT','GENERAL','IMPROVEMENT') then
    raise exception 'Categoría no habilitada para entregables de Gerencia';
  end if;

  if coalesce(array_length(v_roles,1),0)=0 then
    raise exception 'No fue posible resolver el alcance de roles para esta actividad';
  end if;

  -- Evita que el catálogo se llene con duplicados por mayúsculas o espacios.
  select * into v_existing
  from erp_supply.work_activity_catalog c
  where c.organization_id=v_org
    and c.activity_kind=v_kind
    and c.active
    and lower(regexp_replace(trim(c.name),'\s+',' ','g'))=lower(v_name)
  order by c.created_at
  limit 1;

  if found then
    return jsonb_build_object(
      'success',true,
      'alreadyExists',true,
      'item',jsonb_build_object(
        'id',v_existing.id,'code',v_existing.code,'name',v_existing.name,
        'description',v_existing.description,'activityGroup',v_existing.activity_group,
        'activityKind',v_existing.activity_kind,'standardMinutes',v_existing.standard_minutes,
        'evidencePolicy',v_existing.evidence_policy,'acceptanceRequired',v_existing.acceptance_required,
        'teamAllowed',v_existing.team_allowed,'catalogOrigin',v_existing.catalog_origin
      ),
      'version','10.23.1'
    );
  end if;

  -- El código es técnico e inmutable; el nombre visible puede contener tildes y espacios.
  v_code:='CUSTOM_'||upper(substr(md5(v_org::text||':'||v_actor::text||':'||clock_timestamp()::text||':'||v_name),1,16));

  insert into erp_supply.work_activity_catalog(
    organization_id,code,name,description,activity_group,activity_kind,standard_minutes,
    evidence_policy,acceptance_required,team_allowed,allowed_roles,active,sort_order,
    metadata,created_by,catalog_origin
  ) values(
    v_org,v_code,v_name,v_description,v_group,v_kind,v_minutes,
    v_evidence,v_acceptance,v_team,v_roles,true,80,
    jsonb_build_object(
      'custom',true,
      'createdFromPlanner',true,
      'createdVersion','10.23.1',
      'createdAt',now()
    ),
    v_actor,'MANAGER_CREATED'
  ) returning * into v_created;

  insert into erp_supply.work_activity_events(
    organization_id,actor_profile_id,event_type,payload
  ) values(
    v_org,v_actor,'CATALOG_ACTIVITY_CREATED',
    jsonb_build_object(
      'catalogId',v_created.id,'code',v_created.code,'name',v_created.name,
      'kind',v_created.activity_kind,'group',v_created.activity_group,
      'standardMinutes',v_created.standard_minutes,'evidencePolicy',v_created.evidence_policy,
      'allowedRoles',to_jsonb(v_roles),'version','10.23.1'
    )
  );

  return jsonb_build_object(
    'success',true,
    'alreadyExists',false,
    'item',jsonb_build_object(
      'id',v_created.id,'code',v_created.code,'name',v_created.name,
      'description',v_created.description,'activityGroup',v_created.activity_group,
      'activityKind',v_created.activity_kind,'standardMinutes',v_created.standard_minutes,
      'evidencePolicy',v_created.evidence_policy,'acceptanceRequired',v_created.acceptance_required,
      'teamAllowed',v_created.team_allowed,'catalogOrigin',v_created.catalog_origin,
      'createdBy',v_created.created_by,'createdAt',v_created.created_at
    ),
    'version','10.23.1'
  );
end;
$$;

revoke all on function public.erp_x_work_create_catalog_item(jsonb) from public,anon;
grant execute on function public.erp_x_work_create_catalog_item(jsonb) to authenticated;

-- Devuelve el mismo catálogo de siempre, enriquecido con su origen. Esto mantiene
-- un único contrato para Mi Jornada y Planificación: catálogo base + actividades
-- creadas por Jefatura/Gerencia conviven en la misma fuente.
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
        c.catalog_origin "catalogOrigin",(c.catalog_origin='MANAGER_CREATED') "custom",
        c.created_by "createdBy",c.created_at "createdAt",
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

-- Extiende el diagnóstico V10.23 con la integridad del catálogo dinámico.
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

  return query
  select 'Catálogo dinámico trazable',
         not exists(
           select 1 from erp_supply.work_activity_catalog c
           where c.catalog_origin='MANAGER_CREATED' and c.created_by is null
         ),
         'Toda actividad creada por Jefatura o Gerencia conserva quién la creó';

  return query
  select 'Catálogo activo sin duplicados nominales',
         not exists(
           select 1
           from erp_supply.work_activity_catalog c
           where c.active
           group by c.organization_id,c.activity_kind,lower(regexp_replace(trim(c.name),'\s+',' ','g'))
           having count(*)>1
         ),
         'No deben existir dos actividades activas del mismo tipo con el mismo nombre normalizado';
end;
$$;

revoke all on function public.erp_x_work_health() from public,anon;
grant execute on function public.erp_x_work_health() to authenticated;

notify pgrst,'reload schema';
commit;
