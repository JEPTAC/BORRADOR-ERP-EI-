-- ERP Supply Enterprise V10
-- Migration 012: release-grade health audit for configuration, security, concurrency and operational integrity.

begin;

create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
with
required_api(name) as (
  values
    ('erp_x_session'),('erp_x_health_check'),('erp_x_dashboard'),('erp_x_list_orders'),
    ('erp_x_get_order'),('erp_x_get_actions'),('erp_x_create_order'),('erp_x_execute_action'),
    ('erp_x_list_approvals'),('erp_x_decide_approval'),('erp_x_register_drive_file'),
    ('erp_x_inventory'),('erp_x_inventory_adjust'),('erp_x_inventory_lots'),('erp_x_vsm'),
    ('erp_x_import_history'),('erp_x_users'),('erp_x_assignment_pool'),('erp_x_update_checklist'),
    ('erp_x_save_financial_validation'),('erp_x_save_purchase_order'),('erp_x_admin_save_profile'),
    ('erp_x_admin_sync_auth'),('erp_x_calendar'),('erp_x_run_qa_matrix'),('erp_x_qa_runs'),
    ('erp_x_qa_run_detail'),('erp_x_run_qa_control_suite'),('erp_x_credit_list'),('erp_x_credit_create'),
    ('erp_x_credit_transition'),('erp_x_save_receipt'),('erp_x_stickers'),('erp_x_save_cut_job'),
    ('erp_x_save_invoice'),('erp_x_save_delivery'),('erp_x_audit')
),
public_api as (
  select p.oid,p.proname,p.prosecdef,
         has_function_privilege('authenticated',p.oid,'EXECUTE') auth_execute,
         has_function_privilege('anon',p.oid,'EXECUTE') anon_execute
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname like 'erp_x_%'
),
calendar_stats as (
  select c.id,c.timezone,count(s.id) segments,
         coalesce(sum(extract(epoch from(s.end_time-s.start_time))),0)::bigint weekly_seconds
  from erp_supply.work_calendars c
  left join erp_supply.work_calendar_segments s on s.calendar_id=c.id
  where c.code='OPERATIONS_CO' and c.active
  group by c.id,c.timezone
),
active_task_issues as (
  select o.id,o.order_number,count(t.id) task_count
  from erp_supply.orders o
  left join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.status not in('DRAFT','CLOSED','CANCELLED')
  group by o.id,o.order_number
  having count(t.id)<>1
),
step_mismatches as (
  select o.id
  from erp_supply.orders o
  join erp_supply.order_tasks t on t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where not o.is_history and not o.is_test and o.current_step_code<>t.step_code
),
open_session_issues as (
  select s.id
  from erp_supply.task_sessions s
  join erp_supply.order_tasks t on t.id=s.task_id
  where s.ended_at is null and t.status<>'IN_PROGRESS'
),
latest_matrix as (
  select q.* from erp_supply.qa_runs q where q.run_type='MATRIX' order by q.started_at desc limit 1
),
latest_controls as (
  select q.* from erp_supply.qa_runs q where q.run_type='CONTROL_SUITE' order by q.started_at desc limit 1
),
checks as (
  select '01_INSTALACION'::text section,'Organización activa'::text check_name,
    exists(select 1 from erp_supply.organizations where code='EI' and active) ok,
    (select count(*)||' organización(es) activas' from erp_supply.organizations where active) detail

  union all select '01_INSTALACION','Tablas del núcleo instaladas',
    to_regclass('erp_supply.orders') is not null and to_regclass('erp_supply.order_tasks') is not null
      and to_regclass('erp_supply.inventory_movements') is not null and to_regclass('erp_supply.system_audit') is not null,
    'Pedidos, tareas, inventario y auditoría'

  union all select '01_INSTALACION','Roles empresariales configurados',
    (select count(*)>=13 from erp_supply.roles where active),
    (select count(*)||' roles activos' from erp_supply.roles where active)

  union all select '01_INSTALACION','Módulos empresariales configurados',
    (select count(*)>=20 from erp_supply.modules where active),
    (select count(*)||' módulos activos' from erp_supply.modules where active)

  union all select '01_INSTALACION','Catálogos comerciales completos',
    (select count(*)=4 from erp_supply.order_types where active)
      and (select count(*)=3 from erp_supply.payment_conditions where active)
      and (select count(*)=4 from erp_supply.delivery_routes where active),
    format('%s tipos · %s pagos · %s rutas',
      (select count(*) from erp_supply.order_types where active),
      (select count(*) from erp_supply.payment_conditions where active),
      (select count(*) from erp_supply.delivery_routes where active))

  union all select '01_INSTALACION','Flujo operativo completo',
    (select count(*)>=14 from erp_supply.workflow_steps where active),
    (select count(*)||' etapas activas' from erp_supply.workflow_steps where active)

  union all select '02_IDENTIDAD','Perfil de la sesión vinculado',
    exists(select 1 from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active limit 1),'Sesión sin perfil activo')

  union all select '02_IDENTIDAD','Super Admin principal configurado',
    exists(select 1 from erp_supply.profiles p join erp_supply.profile_roles pr on pr.profile_id=p.id
      where lower(p.email)='j.perez@ei.com.co' and p.active and pr.role_code='super_admin'),
    coalesce((select p.display_name||' · activo='||p.active from erp_supply.profiles p where lower(p.email)='j.perez@ei.com.co' limit 1),'Cuenta no encontrada')

  union all select '02_IDENTIDAD','Usuarios activos vinculados a Supabase Auth',
    not exists(select 1 from erp_supply.profiles where active and auth_user_id is null and not is_system),
    (select count(*)||' activo(s) sin vínculo Auth' from erp_supply.profiles where active and auth_user_id is null and not is_system)

  union all select '03_CALENDARIO','Zona horaria operativa',
    exists(select 1 from calendar_stats where timezone='America/Bogota'),
    coalesce((select timezone from calendar_stats),'Calendario no encontrado')

  union all select '03_CALENDARIO','Horario exacto lunes a viernes',
    exists(select 1 from calendar_stats where segments=10 and weekly_seconds=159000),
    coalesce((select segments||' segmentos · '||round(weekly_seconds/3600.0,2)||' horas/semana' from calendar_stats),'Calendario no encontrado')

  union all select '03_CALENDARIO','Festivos colombianos 2026',
    (select count(*)>=19 from erp_supply.holidays where holiday_date between date '2026-01-01' and date '2026-12-31'),
    (select count(*)||' festivos configurados, incluido el nuevo festivo de Chiquinquirá' from erp_supply.holidays where holiday_date between date '2026-01-01' and date '2026-12-31')

  union all select '04_SEGURIDAD','Esquema interno oculto',
    not has_schema_privilege('authenticated','erp_supply','USAGE') and not has_schema_privilege('anon','erp_supply','USAGE'),
    'authenticated='||has_schema_privilege('authenticated','erp_supply','USAGE')||' · anon='||has_schema_privilege('anon','erp_supply','USAGE')

  union all select '04_SEGURIDAD','API pública completa',
    not exists(select 1 from required_api r where not exists(select 1 from public_api a where a.proname=r.name)),
    coalesce((select string_agg(r.name,', ' order by r.name) from required_api r where not exists(select 1 from public_api a where a.proname=r.name)),'37 RPC requeridos disponibles')

  union all select '04_SEGURIDAD','RPC protegidos con SECURITY DEFINER',
    not exists(select 1 from public_api where not prosecdef),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not prosecdef),'Todos los RPC erp_x_* protegidos')

  union all select '04_SEGURIDAD','RPC disponibles para usuarios autenticados',
    not exists(select 1 from public_api where not auth_execute),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where not auth_execute),'Todos los RPC erp_x_* habilitados para authenticated')

  union all select '04_SEGURIDAD','Rol anónimo completamente bloqueado',
    not exists(select 1 from public_api where anon_execute),
    coalesce((select string_agg(proname,', ' order by proname) from public_api where anon_execute),'Ningún RPC erp_x_* expuesto a anon')

  union all select '05_CONCURRENCIA','Una sola tarea activa por pedido',
    to_regclass('erp_supply.uq_active_task_per_order') is not null and not exists(select 1 from active_task_issues),
    (select count(*)||' pedido(s) con cantidad inválida de tareas activas' from active_task_issues)

  union all select '05_CONCURRENCIA','Una sola sesión abierta por tarea',
    to_regclass('erp_supply.uq_open_session_per_task') is not null,
    'Índice parcial uq_open_session_per_task'

  union all select '05_CONCURRENCIA','Una sola sesión abierta por operario',
    to_regclass('erp_supply.uq_open_session_per_user') is not null,
    'Índice parcial uq_open_session_per_user'

  union all select '05_CONCURRENCIA','Sesiones abiertas coherentes',
    not exists(select 1 from open_session_issues),
    (select count(*)||' sesión(es) abiertas fuera de una tarea IN_PROGRESS' from open_session_issues)

  union all select '05_CONCURRENCIA','Etapa del pedido coincide con tarea activa',
    not exists(select 1 from step_mismatches),
    (select count(*)||' pedido(s) desalineados' from step_mismatches)

  union all select '05_CONCURRENCIA','Idempotencia de eventos configurada',
    to_regclass('erp_supply.uq_event_idempotency') is not null,
    'Índice único por organización e idempotency_key'

  union all select '06_CONTROLES','Puertas de cierre activas',
    exists(select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and c.relname='order_tasks' and t.tgname='trg_validate_task_completion' and t.tgenabled<>'D'),
    'Checklist y documentos obligatorios antes de completar cada etapa'

  union all select '06_CONTROLES','Listas de verificación configuradas',
    (select count(*)>=8 from erp_supply.checklist_templates where active and required),
    (select count(*)||' controles obligatorios activos' from erp_supply.checklist_templates where active and required)

  union all select '06_CONTROLES','Dominios operativos instalados',
    to_regclass('erp_supply.financial_validations') is not null and to_regclass('erp_supply.purchase_orders') is not null
      and to_regclass('erp_supply.receipts') is not null and to_regclass('erp_supply.cut_jobs') is not null
      and to_regclass('erp_supply.invoices') is not null and to_regclass('erp_supply.deliveries') is not null,
    'Finanzas, compras, recepción, corte, facturación y entrega'

  union all select '06_CONTROLES','Auditoría automática de dominios sensibles',
    (select count(*)>=16 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and t.tgname like 'trg_audit_%' and not t.tgisinternal and t.tgenabled<>'D'),
    (select count(*)||' disparadores de auditoría activos' from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='erp_supply' and t.tgname like 'trg_audit_%' and not t.tgisinternal and t.tgenabled<>'D')

  union all select '07_ENRUTAMIENTO','Reglas locales y nacionales configuradas',
    (select count(*)>=8 from erp_supply.routing_rules where active and metadata->>'source'='established-routing'),
    (select count(*)||' reglas establecidas' from erp_supply.routing_rules where active and metadata->>'source'='established-routing')

  union all select '07_ENRUTAMIENTO','Responsable local Duvan Díaz vinculado',
    exists(select 1 from erp_supply.routing_rules rr join erp_supply.profiles p on p.id=rr.assigned_profile_id
      where rr.active and lower(p.email)='d.diaz@ei.com.co' and rr.route_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH')),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where lower(p.email)='d.diaz@ei.com.co' limit 1),'Perfil pendiente de vincular')

  union all select '07_ENRUTAMIENTO','Responsable nacional Javier Laverde vinculado',
    exists(select 1 from erp_supply.routing_rules rr join erp_supply.profiles p on p.id=rr.assigned_profile_id
      where rr.active and lower(p.email)='j.laverde@ei.com.co' and rr.route_code='NATIONAL_DISPATCH'),
    coalesce((select p.display_name||' · '||p.email from erp_supply.profiles p where lower(p.email)='j.laverde@ei.com.co' limit 1),'Perfil pendiente de vincular')

  union all select '08_QA','Bot matricial de 192 escenarios instalado',
    to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null,
    '4 tipos × 3 pagos × 4 rutas × 2 corte × 2 compra'

  union all select '08_QA','Última matriz QA aprobada',
    exists(select 1 from latest_matrix where status='PASSED' and total_scenarios=192 and passed_scenarios=192 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_matrix),'Aún no se ha ejecutado la matriz QA')

  union all select '08_QA','Última suite de controles empresariales aprobada',
    exists(select 1 from latest_controls where status='PASSED' and total_scenarios=10 and passed_scenarios=10 and failed_scenarios=0),
    coalesce((select status||' · '||passed_scenarios||'/'||total_scenarios||' aprobados · '||failed_scenarios||' fallidos' from latest_controls),'Aún no se ha ejecutado la suite de controles')

  union all select '09_HISTORICO','Importador histórico aislado',
    to_regprocedure('public.erp_x_import_history(text,jsonb,uuid)') is not null,
    'Los pedidos CSV quedan como is_history=true y no generan tareas activas'

  union all select '09_AUDITORIA','Auditoría y outbox instalados',
    to_regclass('erp_supply.system_audit') is not null and to_regclass('erp_supply.outbox_events') is not null,
    format('%s registros de auditoría · %s eventos outbox pendientes',
      (select count(*) from erp_supply.system_audit),
      (select count(*) from erp_supply.outbox_events where processed_at is null))
)
select section,check_name,ok,detail from checks order by section,check_name
$$;

revoke all on function public.erp_x_health_check() from public,anon,authenticated;
grant execute on function public.erp_x_health_check() to authenticated;

-- Final permission reconciliation after every migration.
do $$
declare r record;
begin
  revoke all on schema erp_supply from public,anon,authenticated;
  for r in
    select p.oid::regprocedure sig
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname like 'erp_x_%'
  loop
    execute format('revoke all on function %s from public,anon,authenticated',r.sig);
    execute format('grant execute on function %s to authenticated',r.sig);
  end loop;
end $$;

commit;
