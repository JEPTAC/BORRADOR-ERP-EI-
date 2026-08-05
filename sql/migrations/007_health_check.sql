-- ERP Supply Enterprise V10
-- Migration 007: operational health check and security audit.

begin;

create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql
stable
security definer
set search_path=erp_supply,public,auth
as $$
with checks as (
  select 'SCHEMA'::text section,'Organization configured'::text check_name,
    exists(select 1 from erp_supply.organizations where active) ok,
    (select count(*)||' organization(s)' from erp_supply.organizations where active) detail
  union all select 'IDENTITY','Current profile linked',erp_supply.current_profile_id() is not null,coalesce(erp_supply.current_profile_id()::text,'No active profile')
  union all select 'CONFIG','Roles configured',(select count(*)>=13 from erp_supply.roles where active),(select count(*)||' roles' from erp_supply.roles where active)
  union all select 'CONFIG','Modules configured',(select count(*)>=20 from erp_supply.modules where active),(select count(*)||' modules' from erp_supply.modules where active)
  union all select 'CONFIG','Workflow steps configured',(select count(*)>=14 from erp_supply.workflow_steps where active),(select count(*)||' steps' from erp_supply.workflow_steps where active)
  union all select 'CALENDAR','Exact 8h50 workday configured',
    exists(select 1 from erp_supply.work_calendars c join erp_supply.work_calendar_segments s on s.calendar_id=c.id group by c.id having sum(extract(epoch from(s.end_time-s.start_time)))=159000),
    'Monday-Friday: 07:00-12:00 / 13:40-17:30'
  union all select 'SECURITY','Anonymous cannot execute session RPC',not has_function_privilege('anon','public.erp_x_session()','EXECUTE'),'anon execute='||has_function_privilege('anon','public.erp_x_session()','EXECUTE')
  union all select 'SECURITY','Authenticated can execute session RPC',has_function_privilege('authenticated','public.erp_x_session()','EXECUTE'),'authenticated execute='||has_function_privilege('authenticated','public.erp_x_session()','EXECUTE')
  union all select 'SECURITY','Internal schema hidden from authenticated',not has_schema_privilege('authenticated','erp_supply','USAGE'),'authenticated schema usage='||has_schema_privilege('authenticated','erp_supply','USAGE')
  union all select 'API','Native order list available',to_regprocedure('public.erp_x_list_orders(text,text,text,text,text,text,integer,integer,boolean)') is not null,'erp_x_list_orders'
  union all select 'API','Transactional action engine available',to_regprocedure('public.erp_x_execute_action(uuid,text,jsonb,integer,text)') is not null,'erp_x_execute_action'
  union all select 'QA','192-scenario bot available',to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null,'erp_x_run_qa_matrix'
  union all select 'IMPORT','Historical CSV import available',to_regprocedure('public.erp_x_import_history(text,jsonb,uuid)') is not null,'erp_x_import_history'
)
select * from checks order by section,check_name
$$;

revoke all on function public.erp_x_health_check() from public,anon,authenticated;
grant execute on function public.erp_x_health_check() to authenticated;

commit;
