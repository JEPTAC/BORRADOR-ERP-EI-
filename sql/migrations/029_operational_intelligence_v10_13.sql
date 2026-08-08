-- ERP EI V10.13
-- Inteligencia operacional estructural: SLA/escalamiento, Centro de Excepciones,
-- analítica causal y optimizador de carretos para Corte.
-- Base requerida: V10.12 + migración 028 aplicada.

begin;

-- ---------------------------------------------------------------------------
-- 1. REGLAS SLA Y ALERTAS OPERACIONALES
-- ---------------------------------------------------------------------------

create table if not exists erp_supply.exception_sla_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id) on delete cascade,
  object_type text not null check (object_type in ('ISSUE','APPROVAL')),
  subtype text not null default '*',
  warning_seconds integer not null check (warning_seconds > 0),
  escalation_1_seconds integer not null check (escalation_1_seconds >= warning_seconds),
  escalation_2_seconds integer not null check (escalation_2_seconds >= escalation_1_seconds),
  escalation_role_1 text references erp_supply.roles(code),
  escalation_role_2 text references erp_supply.roles(code),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, object_type, subtype)
);

create table if not exists erp_supply.operational_alerts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id) on delete cascade,
  order_id uuid references erp_supply.orders(id) on delete cascade,
  source_type text not null check (source_type in ('ISSUE','APPROVAL')),
  source_id uuid not null,
  alert_level integer not null check (alert_level between 1 and 3),
  severity text not null check (severity in ('WARNING','HIGH','CRITICAL')),
  target_role_code text references erp_supply.roles(code),
  message text not null,
  status text not null default 'OPEN' check (status in ('OPEN','ACKNOWLEDGED','CLOSED')),
  acknowledged_by uuid references erp_supply.profiles(id),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  closed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists uq_operational_alert_source_level
on erp_supply.operational_alerts(organization_id,source_type,source_id,alert_level);

create index if not exists idx_operational_alerts_open
on erp_supply.operational_alerts(organization_id,status,severity,created_at desc);

create index if not exists idx_approval_requests_sla
on erp_supply.approval_requests(organization_id,status,created_at);

-- SLA en segundos laborales. Los valores pueden administrarse posteriormente sin cambiar código.
insert into erp_supply.exception_sla_rules(
  organization_id,object_type,subtype,warning_seconds,escalation_1_seconds,escalation_2_seconds,
  escalation_role_1,escalation_role_2,metadata
)
select o.id,v.object_type,v.subtype,v.warning_seconds,v.escalation_1_seconds,v.escalation_2_seconds,
       v.role_1,v.role_2,jsonb_build_object('seed','V10.13')
from erp_supply.organizations o
cross join (values
  ('ISSUE','NOVELTY',7200,14400,28800,'jefe_logistica','gerencia'),
  ('ISSUE','REPORT',3600,7200,14400,'jefe_logistica','gerencia'),
  ('APPROVAL','*',3600,7200,14400,'gerencia','auditoria')
) as v(object_type,subtype,warning_seconds,escalation_1_seconds,escalation_2_seconds,role_1,role_2)
on conflict(organization_id,object_type,subtype) do update set
  warning_seconds=excluded.warning_seconds,
  escalation_1_seconds=excluded.escalation_1_seconds,
  escalation_2_seconds=excluded.escalation_2_seconds,
  escalation_role_1=excluded.escalation_role_1,
  escalation_role_2=excluded.escalation_role_2,
  metadata=erp_supply.exception_sla_rules.metadata||excluded.metadata,
  updated_at=now();

create or replace function erp_supply.refresh_exception_sla(p_organization_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid;
  v_issue record;
  v_approval record;
  v_rule erp_supply.exception_sla_rules%rowtype;
  v_age bigint;
  v_level integer;
  v_severity text;
  v_target text;
  v_inserted integer:=0;
  v_updated integer:=0;
begin
  for v_org in
    select id from erp_supply.organizations
    where p_organization_id is null or id=p_organization_id
  loop
    for v_issue in
      select i.*,o.order_number,o.priority,o.current_role_code
      from erp_supply.order_issues i
      join erp_supply.orders o on o.id=i.order_id
      where i.organization_id=v_org and i.status='OPEN' and i.issue_type in('NOVELTY','REPORT')
    loop
      select * into v_rule
      from erp_supply.exception_sla_rules r
      where r.organization_id=v_org and r.active and r.object_type='ISSUE'
        and r.subtype in(v_issue.issue_type,'*')
      order by case when r.subtype=v_issue.issue_type then 0 else 1 end
      limit 1;
      if not found then continue; end if;

      v_age:=erp_supply.business_seconds_between(v_org,v_issue.created_at,now());
      v_level:=case
        when v_age>=v_rule.escalation_2_seconds then 3
        when v_age>=v_rule.escalation_1_seconds then 2
        when v_age>=v_rule.warning_seconds then 1
        else 0
      end;
      if v_level>0 then
        v_severity:=case v_level when 1 then 'WARNING' when 2 then 'HIGH' else 'CRITICAL' end;
        v_target:=case v_level
          when 1 then coalesce(v_issue.target_role_code,v_issue.current_role_code,'jefe_logistica')
          when 2 then coalesce(v_rule.escalation_role_1,'jefe_logistica')
          else coalesce(v_rule.escalation_role_2,'gerencia')
        end;
        insert into erp_supply.operational_alerts(
          organization_id,order_id,source_type,source_id,alert_level,severity,target_role_code,message,metadata
        ) values(
          v_org,v_issue.order_id,'ISSUE',v_issue.id,v_level,v_severity,v_target,
          format('%s %s del pedido %s supera su SLA operativo',case when v_issue.issue_type='NOVELTY' then 'La novedad' else 'El reporte' end,v_issue.title,v_issue.order_number),
          jsonb_build_object('ageBusinessSeconds',v_age,'priority',v_issue.priority,'slaVersion','10.13')
        ) on conflict(organization_id,source_type,source_id,alert_level) do nothing;
        if found then v_inserted:=v_inserted+1; end if;
      end if;
      update erp_supply.order_issues
      set metadata=metadata||jsonb_build_object('sla',jsonb_build_object(
        'ageBusinessSeconds',v_age,
        'warningSeconds',v_rule.warning_seconds,
        'escalation1Seconds',v_rule.escalation_1_seconds,
        'escalation2Seconds',v_rule.escalation_2_seconds,
        'level',v_level,
        'refreshedAt',now()
      ))
      where id=v_issue.id;
      v_updated:=v_updated+1;
    end loop;

    for v_approval in
      select a.*,o.order_number,o.priority
      from erp_supply.approval_requests a
      join erp_supply.orders o on o.id=a.order_id
      where a.organization_id=v_org and a.status='PENDING'
    loop
      select * into v_rule
      from erp_supply.exception_sla_rules r
      where r.organization_id=v_org and r.active and r.object_type='APPROVAL'
        and r.subtype in(v_approval.request_type,'*')
      order by case when r.subtype=v_approval.request_type then 0 else 1 end
      limit 1;
      if not found then continue; end if;

      v_age:=erp_supply.business_seconds_between(v_org,v_approval.created_at,now());
      v_level:=case
        when v_age>=v_rule.escalation_2_seconds then 3
        when v_age>=v_rule.escalation_1_seconds then 2
        when v_age>=v_rule.warning_seconds then 1
        else 0
      end;
      if v_level>0 then
        v_severity:=case v_level when 1 then 'WARNING' when 2 then 'HIGH' else 'CRITICAL' end;
        v_target:=case v_level
          when 1 then coalesce(v_approval.assigned_role_code,'jefe_logistica')
          when 2 then coalesce(v_rule.escalation_role_1,'gerencia')
          else coalesce(v_rule.escalation_role_2,'auditoria')
        end;
        insert into erp_supply.operational_alerts(
          organization_id,order_id,source_type,source_id,alert_level,severity,target_role_code,message,metadata
        ) values(
          v_org,v_approval.order_id,'APPROVAL',v_approval.id,v_level,v_severity,v_target,
          format('La aprobación %s del pedido %s supera su SLA operativo',v_approval.request_type,v_approval.order_number),
          jsonb_build_object('ageBusinessSeconds',v_age,'priority',v_approval.priority,'slaVersion','10.13')
        ) on conflict(organization_id,source_type,source_id,alert_level) do nothing;
        if found then v_inserted:=v_inserted+1; end if;
      end if;
      update erp_supply.approval_requests
      set request_payload=request_payload||jsonb_build_object('sla',jsonb_build_object(
        'ageBusinessSeconds',v_age,
        'warningSeconds',v_rule.warning_seconds,
        'escalation1Seconds',v_rule.escalation_1_seconds,
        'escalation2Seconds',v_rule.escalation_2_seconds,
        'level',v_level,
        'refreshedAt',now()
      ))
      where id=v_approval.id;
      v_updated:=v_updated+1;
    end loop;

    update erp_supply.operational_alerts a
    set status='CLOSED',closed_at=coalesce(closed_at,now())
    where a.organization_id=v_org and a.status<>'CLOSED' and (
      (a.source_type='ISSUE' and not exists(
        select 1 from erp_supply.order_issues i where i.id=a.source_id and i.status='OPEN'
      )) or
      (a.source_type='APPROVAL' and not exists(
        select 1 from erp_supply.approval_requests r where r.id=a.source_id and r.status='PENDING'
      ))
    );
  end loop;
  return jsonb_build_object('processed',v_updated,'alertsCreated',v_inserted,'refreshedAt',now());
end;
$$;

-- Si pg_cron ya está habilitado en el proyecto, se programa una revisión cada 5 minutos.
-- Si no está disponible, no falla la migración: los RPC del Centro de Excepciones refrescan el SLA al consultar.
do $$
begin
  if to_regprocedure('cron.schedule(text,text,text)') is null and exists(select 1 from pg_available_extensions where name='pg_cron') then
    begin
      execute 'create extension if not exists pg_cron';
    exception when others then
      null;
    end;
  end if;
  if to_regprocedure('cron.schedule(text,text,text)') is not null then
    begin
      execute 'select cron.schedule($1,$2,$3)'
      using 'erp-ei-exception-sla-v10-13','*/5 * * * *','select erp_supply.refresh_exception_sla(null);';
    exception when others then
      null;
    end;
  end if;
end;
$$;

create or replace function public.erp_x_refresh_operational_sla()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();begin
  perform erp_supply.require_profile();
  return erp_supply.refresh_exception_sla(v_org);
end;
$$;
grant execute on function public.erp_x_refresh_operational_sla() to authenticated;

-- ---------------------------------------------------------------------------
-- 2. CENTRO DE EXCEPCIONES Y APROBACIONES
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_exception_summary()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_roles text[]:=erp_supply.current_roles();
  v_control boolean;
begin
  perform erp_supply.refresh_exception_sla(v_org);
  v_control:=erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica') or erp_supply.can_access_module('approvals','read');
  return jsonb_build_object(
    'openNovelties',(select count(*) from erp_supply.order_issues i join erp_supply.orders o on o.id=i.order_id where i.organization_id=v_org and i.status='OPEN' and i.issue_type='NOVELTY' and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)),
    'openReports',(select count(*) from erp_supply.order_issues i join erp_supply.orders o on o.id=i.order_id where i.organization_id=v_org and i.status='OPEN' and i.issue_type='REPORT' and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)),
    'pendingApprovals',(select count(*) from erp_supply.approval_requests a where a.organization_id=v_org and a.status='PENDING' and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))),
    'slaWarnings',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and a.alert_level=1 and (v_control or a.target_role_code=any(v_roles))),
    'escalated',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and a.alert_level>=2 and (v_control or a.target_role_code=any(v_roles))),
    'critical',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and a.alert_level=3 and (v_control or a.target_role_code=any(v_roles))),
    'generatedAt',now()
  );
end;
$$;
grant execute on function public.erp_x_exception_summary() to authenticated;

create or replace function public.erp_x_exception_center(
  p_kind text default null,
  p_state text default 'OPEN',
  p_page integer default 1,
  p_page_size integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_roles text[]:=erp_supply.current_roles();
  v_control boolean;
  v_kind text:=upper(nullif(trim(coalesce(p_kind,'')),''));
  v_state text:=upper(nullif(trim(coalesce(p_state,'')),''));
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,100),1),250);
  v_total bigint;
  v_items jsonb;
begin
  perform erp_supply.refresh_exception_sla(v_org);
  v_control:=erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica') or erp_supply.can_access_module('approvals','read');

  with unified as (
    select
      i.id,'ISSUE'::text item_type,i.issue_type subtype,i.order_id,o.order_number,o.client_name,o.priority,
      coalesce(t.step_code,o.current_step_code) process_code,i.title,i.detail,i.status,
      i.target_role_code target_role,i.created_by actor_id,p.display_name actor_name,i.created_at,
      i.resolved_at closed_at,
      coalesce((i.metadata#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,i.created_at,coalesce(i.resolved_at,now()))) age_business_seconds,
      coalesce((i.metadata#>>'{sla,level}')::integer,0) sla_level,
      i.blocking,
      i.source_code source_code,
      null::text decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor or (i.source_code='NO_DELIVERY' and erp_supply.can_access_module('shipping','update'))) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='ISSUE' and oa.source_id=i.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    join erp_supply.profiles p on p.id=i.created_by
    left join erp_supply.order_tasks t on t.id=i.task_id
    where i.organization_id=v_org
      and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)

    union all

    select
      a.id,'APPROVAL'::text item_type,a.request_type subtype,a.order_id,o.order_number,o.client_name,o.priority,
      o.current_step_code process_code,coalesce(a.request_payload->>'exceptionCode',a.request_type) title,a.reason detail,a.status,
      a.assigned_role_code target_role,a.requested_by actor_id,p.display_name actor_name,a.created_at,
      a.decided_at closed_at,
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) age_business_seconds,
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) sla_level,
      true blocking,
      coalesce(a.request_payload->>'exceptionCode',a.request_type) source_code,
      a.decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia')) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='APPROVAL' and oa.source_id=a.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles p on p.id=a.requested_by
    where a.organization_id=v_org
      and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))
  ), filtered as (
    select * from unified u
    where (v_kind is null or u.item_type=v_kind or u.subtype=v_kind)
      and (
        v_state is null
        or (v_state='OPEN' and ((u.item_type='ISSUE' and u.status='OPEN') or (u.item_type='APPROVAL' and u.status='PENDING')))
        or (v_state='CLOSED' and ((u.item_type='ISSUE' and u.status<>'OPEN') or (u.item_type='APPROVAL' and u.status<>'PENDING')))
        or u.status=v_state
      )
  )
  select count(*) into v_total from filtered;

  with unified as (
    select
      i.id,'ISSUE'::text item_type,i.issue_type subtype,i.order_id,o.order_number,o.client_name,o.priority,
      coalesce(t.step_code,o.current_step_code) process_code,i.title,i.detail,i.status,
      i.target_role_code target_role,p.display_name actor_name,i.created_at,i.resolved_at closed_at,
      coalesce((i.metadata#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,i.created_at,coalesce(i.resolved_at,now()))) age_business_seconds,
      coalesce((i.metadata#>>'{sla,level}')::integer,0) sla_level,i.blocking,i.source_code source_code,null::text decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor or (i.source_code='NO_DELIVERY' and erp_supply.can_access_module('shipping','update'))) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='ISSUE' and oa.source_id=i.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    join erp_supply.profiles p on p.id=i.created_by
    left join erp_supply.order_tasks t on t.id=i.task_id
    where i.organization_id=v_org and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)
    union all
    select
      a.id,'APPROVAL'::text item_type,a.request_type subtype,a.order_id,o.order_number,o.client_name,o.priority,
      o.current_step_code process_code,coalesce(a.request_payload->>'exceptionCode',a.request_type) title,a.reason detail,a.status,
      a.assigned_role_code target_role,p.display_name actor_name,a.created_at,a.decided_at closed_at,
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) age_business_seconds,
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) sla_level,true blocking,
      coalesce(a.request_payload->>'exceptionCode',a.request_type) source_code,a.decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia')) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='APPROVAL' and oa.source_id=a.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles p on p.id=a.requested_by
    where a.organization_id=v_org and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))
  ), filtered as (
    select * from unified u
    where (v_kind is null or u.item_type=v_kind or u.subtype=v_kind)
      and (
        v_state is null
        or (v_state='OPEN' and ((u.item_type='ISSUE' and u.status='OPEN') or (u.item_type='APPROVAL' and u.status='PENDING')))
        or (v_state='CLOSED' and ((u.item_type='ISSUE' and u.status<>'OPEN') or (u.item_type='APPROVAL' and u.status<>'PENDING')))
        or u.status=v_state
      )
  ), page_rows as (
    select * from filtered
    order by
      case when (item_type='ISSUE' and status='OPEN') or (item_type='APPROVAL' and status='PENDING') then 0 else 1 end,
      sla_level desc,
      case priority when 'CRITICAL' then 5 when 'URGENT' then 4 when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end desc,
      age_business_seconds desc,created_at asc
    offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'itemType',item_type,'subtype',subtype,'orderId',order_id,'orderNumber',order_number,'clientName',client_name,
    'priority',priority,'processCode',process_code,'title',title,'detail',detail,'status',status,'targetRole',target_role,
    'actorName',actor_name,'createdAt',created_at,'closedAt',closed_at,'ageBusinessSeconds',age_business_seconds,
    'slaLevel',sla_level,'blocking',blocking,'sourceCode',source_code,'decisionReason',decision_reason,'canResolve',can_resolve,'escalatedRole',escalated_role
  ) order by
    case when (item_type='ISSUE' and status='OPEN') or (item_type='APPROVAL' and status='PENDING') then 0 else 1 end,
    sla_level desc,age_business_seconds desc),'[]'::jsonb)
  into v_items from page_rows;

  return jsonb_build_object(
    'items',v_items,
    'summary',public.erp_x_exception_summary(),
    'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),
    'generatedAt',now()
  );
end;
$$;
grant execute on function public.erp_x_exception_center(text,text,integer,integer) to authenticated;

-- Listado de aprobaciones actualizado con SLA, manteniendo la firma usada por el frontend existente.
create or replace function public.erp_x_list_approvals(p_status text default 'PENDING',p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_total bigint;
  v_items jsonb;
  v_page int:=greatest(p_page,1);
  v_size int:=least(greatest(p_page_size,1),200);
begin
  perform erp_supply.refresh_exception_sla(v_org);
  select count(*) into v_total
  from erp_supply.approval_requests a
  where a.organization_id=v_org and (p_status is null or a.status=p_status)
    and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica'));

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select a.id,a.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",o.priority,
      o.current_step_code "processCode",a.request_type "requestType",a.status,a.reason,a.request_payload "requestPayload",
      rq.display_name "requestedBy",a.assigned_role_code "assignedRole",a.decision_reason "decisionReason",
      a.created_at "createdAt",a.decided_at "decidedAt",
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) "ageBusinessSeconds",
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) "slaLevel"
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles rq on rq.id=a.requested_by
    where a.organization_id=v_org and (p_status is null or a.status=p_status)
      and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica'))
    order by coalesce((a.request_payload#>>'{sla,level}')::integer,0) desc,a.created_at asc
    offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

-- Incidencias del pedido con SLA visible en cualquier popup.
create or replace function public.erp_x_order_issues(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();begin
  perform erp_supply.require_profile();
  if not erp_supply.can_view_order_or_reception_shadow(p_order_id) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  perform erp_supply.refresh_exception_sla(v_org);
  return jsonb_build_object('items',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',i.id,'type',i.issue_type,'title',i.title,'detail',i.detail,'status',i.status,'blocking',i.blocking,
      'sourceCode',i.source_code,'targetRole',i.target_role_code,'createdBy',p.display_name,'createdAt',i.created_at,
      'resolvedBy',rp.display_name,'resolvedAt',i.resolved_at,'resolution',i.resolution,'resolutionCode',i.resolution_code,
      'ageBusinessSeconds',coalesce((i.metadata#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,i.created_at,coalesce(i.resolved_at,now()))),
      'slaLevel',coalesce((i.metadata#>>'{sla,level}')::integer,0),'metadata',i.metadata
    ) order by i.created_at desc),'[]'::jsonb)
    from erp_supply.order_issues i
    join erp_supply.profiles p on p.id=i.created_by
    left join erp_supply.profiles rp on rp.id=i.resolved_by
    where i.order_id=p_order_id
  ));
end;
$$;
grant execute on function public.erp_x_order_issues(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. ANALÍTICA CAUSAL / PARETO
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cause_analytics(p_date_from date default null,p_date_to date default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_from date:=coalesce(p_date_from,current_date-30);
  v_to date:=coalesce(p_date_to,current_date);
  v_result jsonb;
begin
  perform erp_supply.require_profile();
  if not (erp_supply.can_access_module('reports','read') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para consultar analítica causal' using errcode='42501';
  end if;
  if v_to<v_from then raise exception 'Rango de fechas inválido'; end if;

  with events as (
    select
      i.created_at event_at,
      coalesce(nullif(i.source_code,''),nullif(i.title,''),'INCIDENCIA') cause_code,
      null::text reference,
      coalesce(t.step_code,o.current_step_code) process_code,
      seller.display_name seller_name,
      po.supplier_name supplier_name
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    left join erp_supply.order_tasks t on t.id=i.task_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where i.organization_id=v_org and i.issue_type in('NOVELTY','REPORT')
      and i.created_at>=v_from::timestamptz and i.created_at<(v_to+1)::timestamptz

    union all

    select
      pc.checked_at,'MERCANCIA_NO_ENCONTRADA',coalesce(oi.reference,oi.sku,oi.description),'ALISTAMIENTO',
      seller.display_name,po.supplier_name
    from erp_supply.picking_prechecks pc
    join erp_supply.orders o on o.id=pc.order_id
    join erp_supply.order_items oi on oi.id=pc.order_item_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where pc.organization_id=v_org and pc.result='MISSING'
      and pc.checked_at>=v_from::timestamptz and pc.checked_at<(v_to+1)::timestamptz

    union all

    select
      coalesce(cr.ready_at,cr.updated_at),'CORTE_ASIGNADO_INCORRECTAMENTE',coalesce(cr.reference,cr.sku,cr.description),'CORTE',
      seller.display_name,po.supplier_name
    from erp_supply.cut_requirements cr
    join erp_supply.orders o on o.id=cr.order_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where cr.organization_id=v_org and cr.resolution_code='NO_CUT'
      and coalesce(cr.ready_at,cr.updated_at)>=v_from::timestamptz and coalesce(cr.ready_at,cr.updated_at)<(v_to+1)::timestamptz

    union all

    select
      r.received_at,'RECEPCION_CON_RECHAZO',coalesce(oi.reference,oi.sku,oi.description),'RECEPCION_MERCANCIA',
      seller.display_name,r.supplier_name
    from erp_supply.receipt_lines rl
    join erp_supply.receipts r on r.id=rl.receipt_id
    join erp_supply.orders o on o.id=r.order_id
    left join erp_supply.order_items oi on oi.id=rl.order_item_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    where o.organization_id=v_org and coalesce(rl.rejected_quantity,0)>0 and r.received_at is not null
      and r.received_at>=v_from::timestamptz and r.received_at<(v_to+1)::timestamptz
  )
  select jsonb_build_object(
    'from',v_from,'to',v_to,'totalEvents',(select count(*) from events),
    'causes',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(cause_code,''),'Sin clasificar') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'references',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(reference,''),'Sin referencia') label,count(*) n from events where reference is not null group by 1 order by n desc limit 12) x),
    'sellers',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(seller_name,''),'Sin asesor') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'suppliers',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(supplier_name,''),'Sin proveedor') label,count(*) n from events where supplier_name is not null group by 1 order by n desc limit 12) x),
    'processes',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(process_code,''),'SIN_ETAPA') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'generatedAt',now()
  ) into v_result;
  return v_result;
end;
$$;
grant execute on function public.erp_x_cause_analytics(date,date) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. OPTIMIZADOR DE CARRETOS PARA CORTE
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_optimizer(p_group_key text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia');
  v_needed numeric;
  v_reference text;
  v_sku text;
  v_description text;
  v_candidates jsonb;
  v_recommended jsonb;
  v_best_use jsonb;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar el optimizador de Corte' using errcode='42501';
  end if;
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;

  select coalesce(sum(r.total_length),0),max(r.reference),max(r.sku),max(r.description)
  into v_needed,v_reference,v_sku,v_description
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_needed<=0 then raise exception 'El grupo ya no tiene cortes pendientes'; end if;

  with candidates as (
    select
      l.id lot_id,l.lot_number,l.location,
      l.quantity_available usable_length,
      l.quantity_available-v_needed projected_remaining,
      case when l.quantity_available>=v_needed then true else false end sufficient,
      case when l.quantity_available-v_needed>0
                 and l.quantity_available-v_needed<50 then true else false end approval_required,
      case when l.quantity_available>0 then round((v_needed/l.quantity_available*100)::numeric,2) else 0 end utilization_pct,
      ii.sku,ii.reference,ii.description
    from erp_supply.inventory_items ii
    join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
    where ii.organization_id=v_org and ii.active
      and l.quantity_available>0
      and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference) or ii.metadata->>'cutGroupKey'=p_group_key)
  ), ranked as (
    select c.*,
      row_number() over(order by
        case when c.sufficient and (c.projected_remaining=0 or c.projected_remaining>=50) then 0 when c.sufficient then 1 else 2 end,
        case when c.sufficient then c.projected_remaining else -c.usable_length end asc,
        c.lot_number nulls last
      ) operational_rank,
      row_number() over(order by
        case when c.sufficient then 0 else 1 end,
        case when c.sufficient then c.projected_remaining else -c.usable_length end asc
      ) material_rank
    from candidates c
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'lotId',lot_id,'lotNumber',lot_number,'location',location,'usableLength',usable_length,
    'projectedRemaining',projected_remaining,'sufficient',sufficient,'approvalRequired',approval_required,
    'utilizationPct',utilization_pct,'operationalRank',operational_rank,'materialRank',material_rank
  ) order by operational_rank),'[]'::jsonb) into v_candidates
  from (select * from ranked order by operational_rank limit 8) x;

  with candidates as (
    select l.id lot_id,l.lot_number,l.location,l.quantity_available usable_length,
      l.quantity_available-v_needed projected_remaining
    from erp_supply.inventory_items ii join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
    where ii.organization_id=v_org and ii.active and l.quantity_available>0
      and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference) or ii.metadata->>'cutGroupKey'=p_group_key)
  )
  select jsonb_build_object('lotId',lot_id,'lotNumber',lot_number,'location',location,'usableLength',usable_length,'projectedRemaining',projected_remaining,
    'approvalRequired',(projected_remaining>0 and projected_remaining<50))
  into v_recommended
  from candidates
  order by
    case when usable_length>=v_needed and (projected_remaining=0 or projected_remaining>=50) then 0 when usable_length>=v_needed then 1 else 2 end,
    case when usable_length>=v_needed then projected_remaining else -usable_length end asc
  limit 1;

  with candidates as (
    select l.id lot_id,l.lot_number,l.location,l.quantity_available usable_length,
      l.quantity_available-v_needed projected_remaining
    from erp_supply.inventory_items ii join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
    where ii.organization_id=v_org and ii.active and l.quantity_available>0
      and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference) or ii.metadata->>'cutGroupKey'=p_group_key)
  )
  select jsonb_build_object('lotId',lot_id,'lotNumber',lot_number,'location',location,'usableLength',usable_length,'projectedRemaining',projected_remaining,
    'approvalRequired',(projected_remaining>0 and projected_remaining<50))
  into v_best_use
  from candidates
  order by case when usable_length>=v_needed then 0 else 1 end,
           case when usable_length>=v_needed then projected_remaining else -usable_length end asc
  limit 1;

  return jsonb_build_object(
    'groupKey',p_group_key,'reference',v_reference,'sku',v_sku,'description',v_description,
    'requiredLength',v_needed,'recommended',v_recommended,'bestMaterialUse',v_best_use,
    'candidates',v_candidates,'generatedAt',now(),
    'rule',jsonb_build_object('criticalRemainderMeters',50,'strategy','Menor remanente sin forzar aprobación; si no existe, mejor aprovechamiento disponible')
  );
end;
$$;
grant execute on function public.erp_x_cutting_optimizer(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. CIERRE AUTOMÁTICO DE ALERTAS AL RESOLVER / DECIDIR
-- ---------------------------------------------------------------------------

create or replace function erp_supply.trg_close_operational_alerts()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if tg_table_name='order_issues' and new.status<>'OPEN' and old.status='OPEN' then
    update erp_supply.operational_alerts set status='CLOSED',closed_at=coalesce(closed_at,now())
    where source_type='ISSUE' and source_id=new.id and status<>'CLOSED';
  elsif tg_table_name='approval_requests' and new.status<>'PENDING' and old.status='PENDING' then
    update erp_supply.operational_alerts set status='CLOSED',closed_at=coalesce(closed_at,now())
    where source_type='APPROVAL' and source_id=new.id and status<>'CLOSED';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_close_issue_alerts on erp_supply.order_issues;
create trigger trg_close_issue_alerts after update of status on erp_supply.order_issues
for each row execute function erp_supply.trg_close_operational_alerts();

drop trigger if exists trg_close_approval_alerts on erp_supply.approval_requests;
create trigger trg_close_approval_alerts after update of status on erp_supply.approval_requests
for each row execute function erp_supply.trg_close_operational_alerts();

-- Validación de instalación.
do $$
begin
  if to_regprocedure('public.erp_x_exception_center(text,text,integer,integer)') is null then raise exception 'Falta Centro de Excepciones V10.13'; end if;
  if to_regprocedure('public.erp_x_cause_analytics(date,date)') is null then raise exception 'Falta Analítica Causal V10.13'; end if;
  if to_regprocedure('public.erp_x_cutting_optimizer(text)') is null then raise exception 'Falta Optimizador de Corte V10.13'; end if;
end;
$$;

notify pgrst,'reload schema';
commit;
