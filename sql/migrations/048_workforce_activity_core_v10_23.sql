-- ERP EI V10.23.0
-- Gestión transversal de actividades, planificación, evidencias y entregables.
-- Toda persona del ERP recibe acceso a Mi Jornada; Jefatura Logística y Gerencia
-- obtienen capacidades de planificación según su ámbito de responsabilidad.

begin;

-- ---------------------------------------------------------------------------
-- 1. MÓDULO Y PERMISOS
-- ---------------------------------------------------------------------------
insert into erp_supply.modules(code,name,description,icon,sort_order)
values(
  'workforce',
  'Mi jornada y actividades',
  'Actividades varias, entregables, planificación, evidencias y analítica de capacidad',
  'timer',
  135
)
on conflict(code) do update set
  name=excluded.name,
  description=excluded.description,
  icon=excluded.icon,
  sort_order=excluded.sort_order,
  active=true;

-- El portal es transversal: absolutamente todos los roles activos pueden usar su jornada.
insert into erp_supply.role_module_permissions(
  role_code,module_code,can_read,can_create,can_update,can_approve,can_admin
)
select r.code,'workforce',true,true,true,
       (r.code in('super_admin','gerencia','jefe_logistica')),
       (r.code in('super_admin','gerencia','jefe_logistica'))
from erp_supply.roles r
where r.active
on conflict(role_code,module_code) do update set
  can_read=true,
  can_create=true,
  can_update=true,
  can_approve=excluded.can_approve,
  can_admin=excluded.can_admin;

-- ---------------------------------------------------------------------------
-- 2. CATÁLOGO CANÓNICO DE ACTIVIDADES
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.work_activity_catalog(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  code text not null,
  name text not null,
  description text,
  activity_group text not null default 'GENERAL'
    check(activity_group in('LOGISTICS','COMMERCIAL','FINANCE','PURCHASING','MANAGEMENT','GENERAL','IMPROVEMENT')),
  activity_kind text not null default 'ACTIVITY'
    check(activity_kind in('ACTIVITY','DELIVERABLE')),
  standard_minutes integer check(standard_minutes is null or standard_minutes>0),
  evidence_policy text not null default 'FINAL_PHOTO'
    check(evidence_policy in('NONE','FINAL_PHOTO','BEFORE_AFTER','FILE','LINK','ERP_REFERENCE')),
  acceptance_required boolean not null default false,
  team_allowed boolean not null default false,
  allowed_roles text[] not null default '{}'::text[],
  active boolean not null default true,
  sort_order integer not null default 100,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id,code)
);

create index if not exists idx_work_activity_catalog_org
on erp_supply.work_activity_catalog(organization_id,activity_group,active,sort_order);

-- ---------------------------------------------------------------------------
-- 3. PLANIFICACIÓN Y ASIGNACIONES
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.work_assignments(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  catalog_id uuid references erp_supply.work_activity_catalog(id),
  series_id uuid,
  title text not null,
  description text,
  assignment_kind text not null default 'ACTIVITY'
    check(assignment_kind in('ACTIVITY','DELIVERABLE')),
  status text not null default 'PUBLISHED'
    check(status in('DRAFT','PUBLISHED','CANCELLED')),
  priority text not null default 'MEDIUM'
    check(priority in('LOW','MEDIUM','HIGH','URGENT','CRITICAL')),
  planned_start timestamptz,
  planned_end timestamptz,
  due_at timestamptz,
  estimated_minutes integer check(estimated_minutes is null or estimated_minutes>0),
  evidence_policy text not null default 'FINAL_PHOTO'
    check(evidence_policy in('NONE','FINAL_PHOTO','BEFORE_AFTER','FILE','LINK','ERP_REFERENCE')),
  acceptance_required boolean not null default false,
  assigned_by uuid not null references erp_supply.profiles(id),
  related_entity_type text,
  related_entity_id text,
  recurrence jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check(planned_end is null or planned_start is not null),
  check(planned_end is null or planned_end>planned_start),
  check(assignment_kind<>'DELIVERABLE' or due_at is not null)
);

create index if not exists idx_work_assignments_window
on erp_supply.work_assignments(organization_id,planned_start,planned_end,status);
create index if not exists idx_work_assignments_due
on erp_supply.work_assignments(organization_id,due_at,status);
create index if not exists idx_work_assignments_series
on erp_supply.work_assignments(series_id) where series_id is not null;

create table if not exists erp_supply.work_assignment_members(
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references erp_supply.work_assignments(id) on delete cascade,
  profile_id uuid not null references erp_supply.profiles(id),
  status text not null default 'PLANNED'
    check(status in('PLANNED','READY','IN_PROGRESS','WAITING_EVIDENCE','SUBMITTED','COMPLETED','RETURNED','CANCELLED')),
  assigned_at timestamptz not null default now(),
  first_started_at timestamptz,
  submitted_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  unique(assignment_id,profile_id)
);

create index if not exists idx_work_assignment_members_profile
on erp_supply.work_assignment_members(profile_id,status,assigned_at desc);

-- ---------------------------------------------------------------------------
-- 4. EJECUCIÓN, PAUSAS, EVIDENCIAS Y REVISIÓN
-- ---------------------------------------------------------------------------
create table if not exists erp_supply.work_executions(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  assignment_id uuid references erp_supply.work_assignments(id) on delete set null,
  assignment_member_id uuid references erp_supply.work_assignment_members(id) on delete set null,
  catalog_id uuid not null references erp_supply.work_activity_catalog(id),
  profile_id uuid not null references erp_supply.profiles(id),
  source text not null default 'MANUAL' check(source in('MANUAL','PLANNED','ERP_LINKED')),
  status text not null default 'IN_PROGRESS'
    check(status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE','SUBMITTED','COMPLETED','RETURNED','CANCELLED')),
  title_snapshot text not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  elapsed_seconds bigint not null default 0,
  active_seconds bigint not null default 0,
  business_seconds bigint not null default 0,
  paused_seconds bigint not null default 0,
  start_delay_seconds bigint,
  deviation_ratio numeric(12,4),
  deviation_reason text,
  result_note text,
  related_entity_type text,
  related_entity_id text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists uq_work_open_execution_per_profile
on erp_supply.work_executions(profile_id)
where status in('IN_PROGRESS','PAUSED');
create index if not exists idx_work_executions_profile_time
on erp_supply.work_executions(profile_id,started_at desc);
create index if not exists idx_work_executions_assignment
on erp_supply.work_executions(assignment_id,profile_id,started_at desc);

create table if not exists erp_supply.work_execution_pauses(
  id uuid primary key default gen_random_uuid(),
  execution_id uuid not null references erp_supply.work_executions(id) on delete cascade,
  reason_code text not null default 'OTHER',
  note text,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  created_by uuid references erp_supply.profiles(id),
  ended_by uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb
);

create unique index if not exists uq_work_open_pause_per_execution
on erp_supply.work_execution_pauses(execution_id)
where ended_at is null;

create table if not exists erp_supply.work_evidence(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  execution_id uuid not null references erp_supply.work_executions(id) on delete cascade,
  profile_id uuid not null references erp_supply.profiles(id),
  evidence_type text not null
    check(evidence_type in('BEFORE_PHOTO','AFTER_PHOTO','FINAL_PHOTO','FILE','LINK','ERP_REFERENCE')),
  drive_file_id text,
  file_name text,
  mime_type text,
  size_bytes bigint,
  web_view_link text,
  external_value text,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_work_evidence_execution
on erp_supply.work_evidence(execution_id,created_at);

create table if not exists erp_supply.work_delivery_reviews(
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  execution_id uuid not null references erp_supply.work_executions(id),
  assignment_id uuid references erp_supply.work_assignments(id),
  decision text not null check(decision in('ACCEPTED','RETURNED')),
  note text,
  reviewed_by uuid not null references erp_supply.profiles(id),
  reviewed_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.work_activity_events(
  id bigint generated always as identity primary key,
  organization_id uuid not null references erp_supply.organizations(id),
  execution_id uuid references erp_supply.work_executions(id) on delete cascade,
  assignment_id uuid references erp_supply.work_assignments(id) on delete cascade,
  profile_id uuid references erp_supply.profiles(id),
  actor_profile_id uuid references erp_supply.profiles(id),
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_work_activity_events_timeline
on erp_supply.work_activity_events(organization_id,created_at desc);

-- ---------------------------------------------------------------------------
-- 5. TOUCH TRIGGERS
-- ---------------------------------------------------------------------------
drop trigger if exists trg_work_activity_catalog_touch on erp_supply.work_activity_catalog;
create trigger trg_work_activity_catalog_touch before update on erp_supply.work_activity_catalog
for each row execute function erp_supply.touch_updated_at();

drop trigger if exists trg_work_assignments_touch on erp_supply.work_assignments;
create trigger trg_work_assignments_touch before update on erp_supply.work_assignments
for each row execute function erp_supply.touch_updated_at();

drop trigger if exists trg_work_executions_touch on erp_supply.work_executions;
create trigger trg_work_executions_touch before update on erp_supply.work_executions
for each row execute function erp_supply.touch_updated_at();

-- ---------------------------------------------------------------------------
-- 6. CATÁLOGO INICIAL. Puede administrarse después sin cambiar código.
-- ---------------------------------------------------------------------------
insert into erp_supply.work_activity_catalog(
  organization_id,code,name,description,activity_group,activity_kind,standard_minutes,
  evidence_policy,acceptance_required,team_allowed,allowed_roles,sort_order,metadata
)
select o.id,x.code,x.name,x.description,x.activity_group,x.activity_kind,x.standard_minutes,
       x.evidence_policy,x.acceptance_required,x.team_allowed,x.allowed_roles,x.sort_order,
       jsonb_build_object('seedVersion','10.23.0','editable',true)
from erp_supply.organizations o
cross join (values
  ('LOG_ORGANIZE_WAREHOUSE','Organización de bodega','Orden, clasificación y disposición de materiales o zonas.','LOGISTICS','ACTIVITY',60,'BEFORE_AFTER',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[],10),
  ('LOG_CLEAN_WORKAREA','Limpieza de zona de trabajo','Limpieza y acondicionamiento de una zona operativa.','LOGISTICS','ACTIVITY',30,'BEFORE_AFTER',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[],20),
  ('LOG_LOADING','Cargue','Cargue de mercancía, vehículo o unidad logística.','LOGISTICS','ACTIVITY',45,'FINAL_PHOTO',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[],30),
  ('LOG_UNLOADING','Descargue','Descargue de mercancía y disposición inicial.','LOGISTICS','ACTIVITY',60,'FINAL_PHOTO',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[],40),
  ('LOG_CYCLE_COUNT','Conteo físico / inventario','Conteo físico, verificación o conciliación de existencias.','LOGISTICS','ACTIVITY',60,'FINAL_PHOTO',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia']::text[],50),
  ('LOG_RELOCATION','Reubicación de material','Movimiento y reubicación interna de materiales.','LOGISTICS','ACTIVITY',45,'FINAL_PHOTO',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia']::text[],60),
  ('LOG_SUPPORT_PICKING','Apoyo a alistamiento','Apoyo temporal a actividades de alistamiento.','LOGISTICS','ACTIVITY',30,'NONE',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte']::text[],70),
  ('LOG_SUPPORT_CUTTING','Apoyo a corte','Apoyo temporal a operación de corte.','LOGISTICS','ACTIVITY',30,'NONE',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte']::text[],80),
  ('LOG_MAINTENANCE','Mantenimiento básico / 5S','Mantenimiento autónomo, inspección o actividad 5S.','IMPROVEMENT','ACTIVITY',45,'BEFORE_AFTER',false,true,array['jefe_logistica','coordinador_logistico','aux_logistica','auxiliar_corte','recepcion_mercancia','despacho_nacional']::text[],90),
  ('GEN_MEETING','Reunión de trabajo','Reunión operativa o administrativa.','GENERAL','ACTIVITY',30,'NONE',false,true,'{}'::text[],110),
  ('GEN_TRAINING','Capacitación','Formación, inducción o transferencia de conocimiento.','IMPROVEMENT','ACTIVITY',60,'NONE',false,true,'{}'::text[],120),
  ('GEN_CONTINUOUS_IMPROVEMENT','Mejora continua','Análisis, estandarización o implementación de mejora.','IMPROVEMENT','ACTIVITY',60,'FILE',false,true,'{}'::text[],130),
  ('GEN_ADMIN','Gestión administrativa','Actividad administrativa no cubierta por un flujo ERP.','GENERAL','ACTIVITY',45,'NONE',false,false,'{}'::text[],140),
  ('MGT_DELIVERABLE','Entregable de gestión','Entregable con fecha límite, evidencia y aceptación del responsable.','MANAGEMENT','DELIVERABLE',120,'FILE',true,false,array['ventas','jefe_logistica','compras','cartera']::text[],200)
) as x(code,name,description,activity_group,activity_kind,standard_minutes,evidence_policy,acceptance_required,team_allowed,allowed_roles,sort_order)
where o.active
on conflict(organization_id,code) do update set
  name=excluded.name,
  description=excluded.description,
  activity_group=excluded.activity_group,
  activity_kind=excluded.activity_kind,
  standard_minutes=excluded.standard_minutes,
  evidence_policy=excluded.evidence_policy,
  acceptance_required=excluded.acceptance_required,
  team_allowed=excluded.team_allowed,
  allowed_roles=excluded.allowed_roles,
  sort_order=excluded.sort_order,
  active=true,
  metadata=erp_supply.work_activity_catalog.metadata||jsonb_build_object('seedVersion','10.23.0');

-- El esquema interno continúa inaccesible desde navegador.
revoke all on all tables in schema erp_supply from public,anon,authenticated;
revoke all on all sequences in schema erp_supply from public,anon,authenticated;

commit;
