-- ERP Electroingeniería · Instalador consolidado
-- Generado desde las migraciones versionadas. Para una base existente, ejecute únicamente la migración nueva correspondiente.


-- ============================================================================
-- 001_core_schema.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 001: isolated enterprise schema, security model and operational data model.

begin;

create extension if not exists pgcrypto;
create schema if not exists erp_supply;
revoke all on schema erp_supply from public, anon, authenticated;

create or replace function erp_supply.touch_updated_at()
returns trigger
language plpgsql
set search_path = erp_supply, public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create table if not exists erp_supply.organizations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  timezone text not null default 'America/Bogota',
  active boolean not null default true,
  settings jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists erp_supply.roles (
  code text primary key,
  name text not null,
  description text,
  system_role boolean not null default true,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists erp_supply.profiles (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  email text not null,
  display_name text not null,
  employee_code text,
  active boolean not null default true,
  is_system boolean not null default false,
  preferences jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, email)
);

create table if not exists erp_supply.profile_roles (
  profile_id uuid not null references erp_supply.profiles(id) on delete cascade,
  role_code text not null references erp_supply.roles(code),
  is_primary boolean not null default false,
  granted_at timestamptz not null default now(),
  granted_by uuid references erp_supply.profiles(id),
  primary key (profile_id, role_code)
);

create table if not exists erp_supply.modules (
  code text primary key,
  name text not null,
  description text,
  icon text,
  sort_order integer not null default 100,
  active boolean not null default true
);

create table if not exists erp_supply.role_module_permissions (
  role_code text not null references erp_supply.roles(code) on delete cascade,
  module_code text not null references erp_supply.modules(code) on delete cascade,
  can_read boolean not null default true,
  can_create boolean not null default false,
  can_update boolean not null default false,
  can_approve boolean not null default false,
  can_admin boolean not null default false,
  primary key (role_code, module_code)
);

create table if not exists erp_supply.work_calendars (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  code text not null,
  name text not null,
  timezone text not null default 'America/Bogota',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table if not exists erp_supply.work_calendar_segments (
  id uuid primary key default gen_random_uuid(),
  calendar_id uuid not null references erp_supply.work_calendars(id) on delete cascade,
  iso_weekday smallint not null check (iso_weekday between 1 and 7),
  start_time time not null,
  end_time time not null,
  check (end_time > start_time),
  unique (calendar_id, iso_weekday, start_time, end_time)
);

create table if not exists erp_supply.holidays (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  holiday_date date not null,
  name text not null,
  source text,
  unique (organization_id, holiday_date)
);

create table if not exists erp_supply.order_types (
  code text primary key,
  name text not null,
  description text,
  requires_purchase_default boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 100
);

create table if not exists erp_supply.payment_conditions (
  code text primary key,
  name text not null,
  requires_cartera boolean not null default false,
  requires_caja boolean not null default false,
  active boolean not null default true,
  sort_order integer not null default 100
);

create table if not exists erp_supply.delivery_routes (
  code text primary key,
  name text not null,
  route_group text not null check (route_group in ('LOCAL','NATIONAL','PICKUP','POINT')),
  active boolean not null default true,
  sort_order integer not null default 100
);

create table if not exists erp_supply.workflow_steps (
  code text primary key,
  name text not null,
  module_code text not null references erp_supply.modules(code),
  queue_code text not null,
  sla_hours numeric(10,2),
  sort_order integer not null,
  terminal boolean not null default false,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.step_roles (
  step_code text not null references erp_supply.workflow_steps(code) on delete cascade,
  role_code text not null references erp_supply.roles(code) on delete cascade,
  can_view boolean not null default true,
  can_claim boolean not null default false,
  can_assign boolean not null default false,
  can_start boolean not null default false,
  can_complete boolean not null default false,
  can_block boolean not null default false,
  can_override boolean not null default false,
  primary key (step_code, role_code)
);

create table if not exists erp_supply.routing_rules (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  step_code text not null references erp_supply.workflow_steps(code),
  route_code text references erp_supply.delivery_routes(code),
  order_type_code text references erp_supply.order_types(code),
  assigned_role_code text references erp_supply.roles(code),
  assigned_profile_id uuid references erp_supply.profiles(id),
  priority integer not null default 100,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_number text not null,
  external_reference text,
  order_type_code text not null references erp_supply.order_types(code),
  payment_condition_code text not null references erp_supply.payment_conditions(code),
  delivery_route_code text not null references erp_supply.delivery_routes(code),
  client_name text not null,
  client_document text,
  client_city text,
  client_address text,
  client_phone text,
  seller_profile_id uuid references erp_supply.profiles(id),
  current_step_code text not null references erp_supply.workflow_steps(code),
  status text not null check (status in ('DRAFT','QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED','PENDING_APPROVAL','CLOSED','CANCELLED')),
  priority text not null default 'MEDIUM' check (priority in ('LOW','MEDIUM','HIGH','URGENT','CRITICAL')),
  requires_cut boolean not null default false,
  requires_purchase boolean not null default false,
  current_assignee_id uuid references erp_supply.profiles(id),
  current_role_code text references erp_supply.roles(code),
  promised_at timestamptz,
  requested_delivery_date date,
  source text not null default 'ERP' check (source in ('ERP','CSV_HISTORY','API','QA_BOT')),
  is_history boolean not null default false,
  is_test boolean not null default false,
  qa_run_id uuid,
  version integer not null default 1,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  cancelled_at timestamptz,
  unique (organization_id, order_number)
);

create index if not exists idx_orders_queue on erp_supply.orders (organization_id, current_step_code, status, priority, updated_at desc);
create index if not exists idx_orders_search on erp_supply.orders (organization_id, lower(order_number), lower(client_name));
create index if not exists idx_orders_assignee on erp_supply.orders (organization_id, current_assignee_id, status);
create index if not exists idx_orders_created on erp_supply.orders (organization_id, created_at desc);

create table if not exists erp_supply.order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  line_number integer not null,
  sku text,
  reference text,
  description text not null,
  quantity numeric(18,4) not null check (quantity > 0),
  unit text not null default 'UND',
  warehouse_location text,
  requires_cut boolean not null default false,
  requested_cut_length numeric(18,4),
  dimensions jsonb not null default '{}'::jsonb,
  item_status text not null default 'PENDING',
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (order_id, line_number)
);

create table if not exists erp_supply.order_tasks (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  step_code text not null references erp_supply.workflow_steps(code),
  sequence_no integer not null,
  queue_code text not null,
  status text not null check (status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED','COMPLETED','CANCELLED')),
  assigned_profile_id uuid references erp_supply.profiles(id),
  assigned_role_code text references erp_supply.roles(code),
  created_at timestamptz not null default now(),
  assigned_at timestamptz,
  started_at timestamptz,
  completed_at timestamptz,
  blocked_at timestamptz,
  raw_seconds bigint not null default 0,
  business_seconds bigint not null default 0,
  result_code text,
  result_detail text,
  metadata jsonb not null default '{}'::jsonb,
  unique (order_id, sequence_no)
);

create unique index if not exists uq_active_task_per_order on erp_supply.order_tasks(order_id)
where status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
create index if not exists idx_tasks_queue on erp_supply.order_tasks(queue_code, status, assigned_profile_id, created_at);

create table if not exists erp_supply.task_sessions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references erp_supply.order_tasks(id) on delete cascade,
  profile_id uuid not null references erp_supply.profiles(id),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  raw_seconds bigint not null default 0,
  business_seconds bigint not null default 0,
  note text,
  created_at timestamptz not null default now()
);

create unique index if not exists uq_open_session_per_task on erp_supply.task_sessions(task_id)
where ended_at is null;
create unique index if not exists uq_open_session_per_user on erp_supply.task_sessions(profile_id)
where ended_at is null;

create table if not exists erp_supply.order_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  event_type text not null,
  action_code text,
  from_step_code text,
  to_step_code text,
  from_status text,
  to_status text,
  actor_profile_id uuid references erp_supply.profiles(id),
  actor_role_code text,
  idempotency_key text,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create unique index if not exists uq_event_idempotency on erp_supply.order_events(organization_id, idempotency_key)
where idempotency_key is not null;
create index if not exists idx_events_order_time on erp_supply.order_events(order_id, created_at);

create table if not exists erp_supply.order_comments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  author_profile_id uuid not null references erp_supply.profiles(id),
  comment_type text not null default 'GENERAL',
  visibility text not null default 'ORDER' check (visibility in ('ORDER','INTERNAL','MANAGEMENT')),
  body text not null check (length(body) between 1 and 5000),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);

create table if not exists erp_supply.approval_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  request_type text not null,
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','CANCELLED','EXECUTED')),
  requested_by uuid not null references erp_supply.profiles(id),
  assigned_role_code text references erp_supply.roles(code),
  assigned_profile_id uuid references erp_supply.profiles(id),
  reason text not null,
  request_payload jsonb not null default '{}'::jsonb,
  decision_reason text,
  decided_by uuid references erp_supply.profiles(id),
  decided_at timestamptz,
  executed_at timestamptz,
  created_at timestamptz not null default now()
);

create unique index if not exists uq_pending_approval_type on erp_supply.approval_requests(order_id, request_type)
where status = 'PENDING';

create table if not exists erp_supply.drive_files (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid references erp_supply.orders(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  file_category text not null,
  drive_file_id text not null,
  file_name text not null,
  mime_type text,
  web_view_link text,
  web_content_link text,
  size_bytes bigint,
  uploaded_by uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (organization_id, drive_file_id)
);

create table if not exists erp_supply.receipts (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  receipt_number text not null,
  purchase_order text,
  supplier_name text,
  status text not null default 'OPEN' check (status in ('OPEN','PARTIAL','CONFORMING','NONCONFORMING','CLOSED')),
  received_by uuid references erp_supply.profiles(id),
  received_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(order_id, receipt_number)
);

create table if not exists erp_supply.receipt_lines (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references erp_supply.receipts(id) on delete cascade,
  order_item_id uuid references erp_supply.order_items(id),
  sku text,
  description text not null,
  expected_quantity numeric(18,4),
  received_quantity numeric(18,4) not null default 0,
  accepted_quantity numeric(18,4) not null default 0,
  rejected_quantity numeric(18,4) not null default 0,
  unit text not null default 'UND',
  location text,
  quality_status text not null default 'PENDING',
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.inventory_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  sku text not null,
  reference text,
  description text not null,
  unit text not null default 'UND',
  item_type text not null default 'STANDARD',
  barcode text,
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku)
);

create table if not exists erp_supply.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  inventory_item_id uuid not null references erp_supply.inventory_items(id) on delete cascade,
  lot_number text,
  serial_number text,
  location text not null,
  quantity_available numeric(18,4) not null default 0,
  quantity_reserved numeric(18,4) not null default 0,
  quantity_blocked numeric(18,4) not null default 0,
  received_at timestamptz,
  expires_at date,
  metadata jsonb not null default '{}'::jsonb,
  check (quantity_available >= 0 and quantity_reserved >= 0 and quantity_blocked >= 0)
);

create table if not exists erp_supply.inventory_movements (
  id bigint generated always as identity primary key,
  organization_id uuid not null references erp_supply.organizations(id),
  inventory_item_id uuid not null references erp_supply.inventory_items(id),
  lot_id uuid references erp_supply.inventory_lots(id),
  order_id uuid references erp_supply.orders(id),
  movement_type text not null,
  quantity numeric(18,4) not null,
  unit text not null,
  from_location text,
  to_location text,
  actor_profile_id uuid references erp_supply.profiles(id),
  reference text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists erp_supply.cut_jobs (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid references erp_supply.order_items(id),
  inventory_lot_id uuid references erp_supply.inventory_lots(id),
  requested_length numeric(18,4) not null,
  actual_length numeric(18,4),
  scrap_length numeric(18,4) not null default 0,
  status text not null default 'PENDING' check (status in ('PENDING','ASSIGNED','IN_PROGRESS','COMPLETED','REJECTED')),
  assigned_profile_id uuid references erp_supply.profiles(id),
  started_at timestamptz,
  completed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists erp_supply.invoices (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  invoice_number text not null,
  invoice_date date not null default current_date,
  amount numeric(18,2),
  currency text not null default 'COP',
  status text not null default 'REGISTERED',
  drive_file_id uuid references erp_supply.drive_files(id),
  registered_by uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(order_id, invoice_number)
);

create table if not exists erp_supply.deliveries (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  route_code text not null references erp_supply.delivery_routes(code),
  status text not null default 'PLANNED' check (status in ('PLANNED','DISPATCHED','IN_TRANSIT','DELIVERED','NOT_DELIVERED','REPROGRAMMED','CANCELLED')),
  scheduled_at timestamptz,
  dispatched_at timestamptz,
  delivered_at timestamptz,
  received_by text,
  no_delivery_reason text,
  carrier text,
  tracking_number text,
  assigned_profile_id uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists erp_supply.credit_requests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  request_number text not null,
  client_name text not null,
  client_document text,
  requested_amount numeric(18,2) not null,
  requested_term_days integer,
  status text not null default 'DRAFT' check (status in ('DRAFT','SUBMITTED','UNDER_REVIEW','APPROVED','REJECTED','CANCELLED')),
  requested_by uuid not null references erp_supply.profiles(id),
  assigned_to uuid references erp_supply.profiles(id),
  decision_reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(organization_id, request_number)
);

create table if not exists erp_supply.import_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  import_type text not null,
  file_name text,
  status text not null default 'PROCESSING' check (status in ('PROCESSING','COMPLETED','PARTIAL','FAILED')),
  total_rows integer not null default 0,
  inserted_rows integer not null default 0,
  rejected_rows integer not null default 0,
  imported_by uuid not null references erp_supply.profiles(id),
  summary jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table if not exists erp_supply.import_errors (
  id bigint generated always as identity primary key,
  batch_id uuid not null references erp_supply.import_batches(id) on delete cascade,
  row_number integer,
  error_code text,
  error_message text not null,
  raw_row jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists erp_supply.qa_runs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  run_type text not null default 'MATRIX',
  status text not null default 'RUNNING' check (status in ('RUNNING','PASSED','FAILED','CANCELLED')),
  requested_by uuid references erp_supply.profiles(id),
  total_scenarios integer not null default 0,
  passed_scenarios integer not null default 0,
  failed_scenarios integer not null default 0,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  summary jsonb not null default '{}'::jsonb
);

do $$
begin
  if not exists (select 1 from pg_constraint where conname='fk_orders_qa_run' and conrelid='erp_supply.orders'::regclass) then
    alter table erp_supply.orders add constraint fk_orders_qa_run foreign key (qa_run_id) references erp_supply.qa_runs(id) on delete set null;
  end if;
end $$;

create table if not exists erp_supply.qa_scenarios (
  id uuid primary key default gen_random_uuid(),
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  scenario_key text not null,
  order_id uuid references erp_supply.orders(id) on delete set null,
  input jsonb not null,
  expected_path jsonb not null default '[]'::jsonb,
  actual_path jsonb not null default '[]'::jsonb,
  status text not null default 'RUNNING' check (status in ('RUNNING','PASSED','FAILED')),
  error_message text,
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  unique(qa_run_id, scenario_key)
);

create table if not exists erp_supply.outbox_events (
  id bigint generated always as identity primary key,
  organization_id uuid not null references erp_supply.organizations(id),
  event_type text not null,
  aggregate_type text not null,
  aggregate_id uuid,
  payload jsonb not null,
  status text not null default 'PENDING' check (status in ('PENDING','PROCESSING','SENT','FAILED','CANCELLED')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  processed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create table if not exists erp_supply.system_audit (
  id bigint generated always as identity primary key,
  organization_id uuid references erp_supply.organizations(id),
  actor_profile_id uuid references erp_supply.profiles(id),
  action text not null,
  entity_type text not null,
  entity_id text,
  before_data jsonb,
  after_data jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

drop trigger if exists trg_organizations_touch on erp_supply.organizations;
drop trigger if exists trg_profiles_touch on erp_supply.profiles;
drop trigger if exists trg_orders_touch on erp_supply.orders;
drop trigger if exists trg_items_touch on erp_supply.order_items;
drop trigger if exists trg_inventory_touch on erp_supply.inventory_items;
drop trigger if exists trg_deliveries_touch on erp_supply.deliveries;
drop trigger if exists trg_credit_touch on erp_supply.credit_requests;
create trigger trg_organizations_touch before update on erp_supply.organizations for each row execute function erp_supply.touch_updated_at();
create trigger trg_profiles_touch before update on erp_supply.profiles for each row execute function erp_supply.touch_updated_at();
create trigger trg_orders_touch before update on erp_supply.orders for each row execute function erp_supply.touch_updated_at();
create trigger trg_items_touch before update on erp_supply.order_items for each row execute function erp_supply.touch_updated_at();
create trigger trg_inventory_touch before update on erp_supply.inventory_items for each row execute function erp_supply.touch_updated_at();
create trigger trg_deliveries_touch before update on erp_supply.deliveries for each row execute function erp_supply.touch_updated_at();
create trigger trg_credit_touch before update on erp_supply.credit_requests for each row execute function erp_supply.touch_updated_at();

commit;


-- ============================================================================
-- 002_seed_configuration.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 002: roles, modules, workflow, schedules and default organization.

begin;

insert into erp_supply.organizations(code, name, timezone, settings)
values ('EI', 'Electroingeniería S.A.S.', 'America/Bogota', jsonb_build_object('currency','COP','locale','es-CO'))
on conflict (code) do update set name = excluded.name, timezone = excluded.timezone;

insert into erp_supply.roles(code, name, description) values
  ('super_admin','Superadministración','Control total, configuración y pruebas'),
  ('gerencia','Gerencia','Lectura integral, aprobaciones y control ejecutivo'),
  ('jefe_logistica','Jefatura logística','Supervisión de la operación y excepciones'),
  ('ventas','Ventas','Registro y seguimiento de pedidos propios'),
  ('cartera','Cartera','Validación de crédito y liberación financiera'),
  ('caja','Caja','Validación de pagos y soportes'),
  ('compras','Compras','Gestión de PVE, proveedores y órdenes de compra'),
  ('recepcion_mercancia','Recepción de mercancía','Recepción física, calidad y stickers'),
  ('coordinador_logistico','Coordinación logística','Recepción documental, facturación y rutas locales'),
  ('aux_logistica','Auxiliar de logística','Alistamiento y preparación de pedidos'),
  ('auxiliar_corte','Auxiliar de corte','Prealistamiento y corte de materiales'),
  ('despacho_nacional','Despacho nacional','Facturación y despachos nacionales'),
  ('auditoria','Auditoría','Lectura integral sin operación')
on conflict (code) do update set name = excluded.name, description = excluded.description, active = true;

insert into erp_supply.modules(code,name,description,icon,sort_order) values
  ('dashboard','Centro de operación','KPIs, alertas y cuellos de botella','layout-dashboard',10),
  ('orders','Control de pedidos','Registro, consulta y trazabilidad total','clipboard-list',20),
  ('sales','Registro de ventas','Creación y control comercial','badge-dollar-sign',30),
  ('credit','Crédito','Solicitudes y decisiones de crédito','landmark',40),
  ('cartera','Cartera','Liberaciones de cartera y riesgo','wallet-cards',50),
  ('caja','Caja','Validación de pagos','banknote',60),
  ('purchasing','Compras','Órdenes PVE, proveedores y abastecimiento','shopping-cart',70),
  ('receiving','Recepción','Recepción documental y física','package-check',80),
  ('picking','Alistamiento','Picking, checklist y novedades','list-checks',90),
  ('cutting','Corte','Colas de corte, chipas y desperdicio','scissors',100),
  ('billing','Facturación','Facturas, soportes y liberación','receipt-text',110),
  ('shipping','Despachos','Rutas locales, nacionales y recogidas','truck',120),
  ('inventory','Inventario','Existencias, lotes, ubicaciones y movimientos','boxes',130),
  ('approvals','Aprobaciones','Excepciones, cancelaciones y reaperturas','shield-check',140),
  ('vsm','VSM y tiempos','Lead time, tiempos productivos y esperas','activity',150),
  ('reports','Reportes','Indicadores y exportaciones','chart-no-axes-combined',160),
  ('imports','Importaciones','Carga histórica por CSV','file-up',170),
  ('qa','Bot QA','Pruebas matriciales y trazas E2E','bot',180),
  ('audit','Auditoría','Eventos, cambios y evidencias','scan-search',190),
  ('admin','Administración','Usuarios, roles, calendarios y reglas','settings',200)
on conflict (code) do update set name=excluded.name, description=excluded.description, icon=excluded.icon, sort_order=excluded.sort_order, active=true;

insert into erp_supply.order_types(code,name,description,requires_purchase_default,sort_order) values
  ('PVC','Pedido de venta crédito','Pedido comercial con validación de crédito',false,10),
  ('PVN','Pedido de venta nacional','Pedido con despacho de cobertura nacional',false,20),
  ('PVE','Pedido de venta especial','Pedido sujeto a abastecimiento o compra',true,30),
  ('PVP','Pedido de venta proyecto','Pedido asociado a proyecto o suministro especial',false,40)
on conflict (code) do update set name=excluded.name, description=excluded.description, requires_purchase_default=excluded.requires_purchase_default;

insert into erp_supply.payment_conditions(code,name,requires_cartera,requires_caja,sort_order) values
  ('CREDIT','Crédito',true,false,10),
  ('CASH','Contado',false,true,20),
  ('MIXED','Mixto',true,true,30)
on conflict (code) do update set name=excluded.name, requires_cartera=excluded.requires_cartera, requires_caja=excluded.requires_caja;

insert into erp_supply.delivery_routes(code,name,route_group,sort_order) values
  ('CLIENT_POINT','Entrega en punto','POINT',10),
  ('CLIENT_PICKUP','Cliente recoge','PICKUP',20),
  ('LOCAL_DISPATCH','Despacho local','LOCAL',30),
  ('NATIONAL_DISPATCH','Despacho nacional','NATIONAL',40)
on conflict (code) do update set name=excluded.name, route_group=excluded.route_group;

insert into erp_supply.workflow_steps(code,name,module_code,queue_code,sla_hours,sort_order,terminal,metadata) values
  ('CARTERA','Validación de cartera','cartera','CARTERA',4,10,false,'{"phase":"financial"}'),
  ('CAJA','Validación de caja','caja','CAJA',2,20,false,'{"phase":"financial"}'),
  ('COMPRAS','Gestión de compras','purchasing','COMPRAS',24,30,false,'{"phase":"supply"}'),
  ('RECEPCION_MERCANCIA','Recepción de mercancía','receiving','RECEPCION_MERCANCIA',8,40,false,'{"phase":"inbound"}'),
  ('RECEPCION_PEDIDO','Recepción documental y asignación','receiving','RECEPCION_PEDIDO',2,50,false,'{"phase":"inbound"}'),
  ('ALISTAMIENTO','Alistamiento','picking','ALISTAMIENTO',8,60,false,'{"phase":"warehouse"}'),
  ('CORTE','Corte y prealistamiento','cutting','CORTE',8,70,false,'{"phase":"warehouse"}'),
  ('FACTURACION','Facturación','billing','FACTURACION',4,80,false,'{"phase":"outbound"}'),
  ('CLIENT_POINT','Entrega en punto','shipping','CLIENT_POINT',4,90,false,'{"phase":"delivery"}'),
  ('CLIENT_PICKUP','Cliente recoge','shipping','CLIENT_PICKUP',8,100,false,'{"phase":"delivery"}'),
  ('LOCAL_DISPATCH','Despacho local','shipping','LOCAL_DISPATCH',8,110,false,'{"phase":"delivery"}'),
  ('NATIONAL_DISPATCH','Despacho nacional','shipping','NATIONAL_DISPATCH',24,120,false,'{"phase":"delivery"}'),
  ('CLOSURE','Cierre y verificación','shipping','CLOSURE',2,130,false,'{"phase":"closure"}'),
  ('CLOSED','Pedido cerrado','orders','CLOSED',null,140,true,'{"phase":"terminal"}')
on conflict (code) do update set name=excluded.name,module_code=excluded.module_code,queue_code=excluded.queue_code,sla_hours=excluded.sla_hours,sort_order=excluded.sort_order,metadata=excluded.metadata;

-- Step permissions. Super Admin has full control; supervisory roles receive override rights.
insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'super_admin', true,true,true,true,true,true,true from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true,can_claim=true,can_assign=true,can_start=true,can_complete=true,can_block=true,can_override=true;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'gerencia', true,false,false,false,false,false,true from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true,can_override=true;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code, 'auditoria', true,false,false,false,false,false,false from erp_supply.workflow_steps s
on conflict (step_code,role_code) do update set can_view=true;

insert into erp_supply.step_roles values
  ('CARTERA','cartera',true,true,false,true,true,true,false),
  ('CAJA','caja',true,true,false,true,true,true,false),
  ('COMPRAS','compras',true,true,true,true,true,true,false),
  ('RECEPCION_MERCANCIA','recepcion_mercancia',true,true,true,true,true,true,false),
  ('RECEPCION_PEDIDO','coordinador_logistico',true,true,true,true,true,true,false),
  ('ALISTAMIENTO','aux_logistica',true,true,false,true,true,true,false),
  ('CORTE','auxiliar_corte',true,true,false,true,true,true,false),
  ('FACTURACION','coordinador_logistico',true,true,false,true,true,true,false),
  ('FACTURACION','despacho_nacional',true,true,false,true,true,true,false),
  ('CLIENT_POINT','coordinador_logistico',true,true,false,true,true,true,false),
  ('CLIENT_PICKUP','coordinador_logistico',true,true,false,true,true,true,false),
  ('LOCAL_DISPATCH','coordinador_logistico',true,true,false,true,true,true,false),
  ('NATIONAL_DISPATCH','despacho_nacional',true,true,false,true,true,true,false),
  ('CLOSURE','jefe_logistica',true,true,true,true,true,true,true)
on conflict (step_code,role_code) do update set
  can_view=excluded.can_view,can_claim=excluded.can_claim,can_assign=excluded.can_assign,
  can_start=excluded.can_start,can_complete=excluded.can_complete,can_block=excluded.can_block,can_override=excluded.can_override;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select s.code,'jefe_logistica',true,false,true,false,false,true,true from erp_supply.workflow_steps s
where not s.terminal
on conflict (step_code,role_code) do update set can_view=true,can_assign=true,can_block=true,can_override=true;

-- Module permissions: precise role menu and action rights.
insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
select 'super_admin',m.code,true,true,true,true,true from erp_supply.modules m
on conflict (role_code,module_code) do update set can_read=true,can_create=true,can_update=true,can_approve=true,can_admin=true;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
select r.code,m.code,true,false,false,(r.code='gerencia'),false
from erp_supply.roles r cross join erp_supply.modules m
where r.code in ('gerencia','auditoria')
on conflict (role_code,module_code) do update set can_read=excluded.can_read,can_approve=excluded.can_approve;

insert into erp_supply.role_module_permissions values
  ('ventas','dashboard',true,false,false,false,false),('ventas','orders',true,true,true,false,false),('ventas','sales',true,true,true,false,false),('ventas','credit',true,true,true,false,false),('ventas','approvals',true,true,false,false,false),
  ('cartera','dashboard',true,false,false,false,false),('cartera','orders',true,false,false,false,false),('cartera','cartera',true,false,true,true,false),('cartera','credit',true,false,true,true,false),('cartera','approvals',true,true,true,true,false),
  ('caja','dashboard',true,false,false,false,false),('caja','orders',true,false,false,false,false),('caja','caja',true,false,true,false,false),('caja','approvals',true,true,true,false,false),
  ('compras','dashboard',true,false,false,false,false),('compras','orders',true,false,false,false,false),('compras','purchasing',true,true,true,false,false),('compras','receiving',true,false,false,false,false),('compras','approvals',true,true,true,false,false),
  ('recepcion_mercancia','dashboard',true,false,false,false,false),('recepcion_mercancia','orders',true,false,false,false,false),('recepcion_mercancia','receiving',true,true,true,false,false),('recepcion_mercancia','inventory',true,true,true,false,false),('recepcion_mercancia','approvals',true,true,true,false,false),
  ('coordinador_logistico','dashboard',true,false,false,false,false),('coordinador_logistico','orders',true,false,true,false,false),('coordinador_logistico','receiving',true,true,true,false,false),('coordinador_logistico','picking',true,false,true,false,false),('coordinador_logistico','billing',true,true,true,false,false),('coordinador_logistico','shipping',true,true,true,false,false),('coordinador_logistico','approvals',true,true,true,false,false),
  ('aux_logistica','dashboard',true,false,false,false,false),('aux_logistica','orders',true,false,false,false,false),('aux_logistica','picking',true,false,true,false,false),('aux_logistica','approvals',true,true,false,false,false),
  ('auxiliar_corte','dashboard',true,false,false,false,false),('auxiliar_corte','orders',true,false,false,false,false),('auxiliar_corte','cutting',true,true,true,false,false),('auxiliar_corte','inventory',true,false,true,false,false),('auxiliar_corte','approvals',true,true,false,false,false),
  ('despacho_nacional','dashboard',true,false,false,false,false),('despacho_nacional','orders',true,false,true,false,false),('despacho_nacional','billing',true,true,true,false,false),('despacho_nacional','shipping',true,true,true,false,false),('despacho_nacional','approvals',true,true,true,false,false),
  ('jefe_logistica','dashboard',true,false,false,false,false),('jefe_logistica','orders',true,false,true,true,false),('jefe_logistica','purchasing',true,false,true,true,false),('jefe_logistica','receiving',true,false,true,true,false),('jefe_logistica','picking',true,false,true,true,false),('jefe_logistica','cutting',true,false,true,true,false),('jefe_logistica','billing',true,false,true,true,false),('jefe_logistica','shipping',true,false,true,true,false),('jefe_logistica','inventory',true,false,true,true,false),('jefe_logistica','approvals',true,true,true,true,false),('jefe_logistica','vsm',true,false,false,false,false),('jefe_logistica','reports',true,false,false,false,false),('jefe_logistica','qa',true,false,false,false,false),('jefe_logistica','audit',true,false,false,false,false)
on conflict (role_code,module_code) do update set can_read=excluded.can_read,can_create=excluded.can_create,can_update=excluded.can_update,can_approve=excluded.can_approve,can_admin=excluded.can_admin;

-- Default calendar: 07:00–12:00 and 13:40–17:30, Monday through Friday (8 h 50 min/day).
insert into erp_supply.work_calendars(organization_id,code,name,timezone)
select id,'OPERATIONS_CO','Operación Colombia','America/Bogota' from erp_supply.organizations where code='EI'
on conflict (organization_id,code) do update set name=excluded.name,timezone=excluded.timezone,active=true;

insert into erp_supply.work_calendar_segments(calendar_id,iso_weekday,start_time,end_time)
select c.id,d,'07:00','12:00' from erp_supply.work_calendars c cross join generate_series(1,5) d where c.code='OPERATIONS_CO'
on conflict do nothing;
insert into erp_supply.work_calendar_segments(calendar_id,iso_weekday,start_time,end_time)
select c.id,d,'13:40','17:30' from erp_supply.work_calendars c cross join generate_series(1,5) d where c.code='OPERATIONS_CO'
on conflict do nothing;

-- Colombian public holidays for 2026. Administrators can maintain future years in the calendar module.
insert into erp_supply.holidays(organization_id,holiday_date,name,source)
select o.id,h.d,h.n,case when h.d='2026-07-13'::date then 'Ley 2578 de 2026' else 'Colombia 2026' end from erp_supply.organizations o cross join (values
  ('2026-01-01'::date,'Año Nuevo'),('2026-01-12','Día de los Reyes Magos'),('2026-03-23','Día de San José'),
  ('2026-04-02','Jueves Santo'),('2026-04-03','Viernes Santo'),('2026-05-01','Día del Trabajo'),
  ('2026-05-18','Ascensión del Señor'),('2026-06-08','Corpus Christi'),('2026-06-15','Sagrado Corazón'),
  ('2026-06-29','San Pedro y San Pablo'),('2026-07-13','Nuestra Señora del Rosario de Chiquinquirá'),
  ('2026-07-20','Independencia de Colombia'),('2026-08-07','Batalla de Boyacá'),('2026-08-17','Asunción de la Virgen'),
  ('2026-10-12','Día de la Diversidad Étnica y Cultural'),('2026-11-02','Todos los Santos'),
  ('2026-11-16','Independencia de Cartagena'),('2026-12-08','Inmaculada Concepción'),('2026-12-25','Navidad')
) h(d,n) where o.code='EI'
on conflict (organization_id,holiday_date) do update set name=excluded.name,source=excluded.source;

commit;


-- ============================================================================
-- 003_workflow_engine.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 003: identity, calendar calculations, routing and transactional workflow engine.

begin;

create or replace function erp_supply.current_profile_id()
returns uuid
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select p.id
  from erp_supply.profiles p
  where p.auth_user_id = auth.uid() and p.active
  limit 1
$$;

create or replace function erp_supply.current_org_id()
returns uuid
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select p.organization_id
  from erp_supply.profiles p
  where p.auth_user_id = auth.uid() and p.active
  limit 1
$$;

create or replace function erp_supply.current_roles()
returns text[]
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select coalesce(array_agg(pr.role_code order by pr.is_primary desc, pr.role_code), '{}'::text[])
  from erp_supply.profiles p
  join erp_supply.profile_roles pr on pr.profile_id = p.id
  join erp_supply.roles r on r.code = pr.role_code and r.active
  where p.auth_user_id = auth.uid() and p.active
$$;

create or replace function erp_supply.has_role(p_role text)
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select coalesce(p_role = any(erp_supply.current_roles()), false)
$$;

create or replace function erp_supply.require_profile()
returns uuid
language plpgsql
stable
security definer
set search_path = erp_supply, public, auth
as $$
declare v_profile uuid;
begin
  v_profile := erp_supply.current_profile_id();
  if v_profile is null then
    raise exception 'Usuario sin perfil activo en ERP Supply Enterprise' using errcode='42501';
  end if;
  return v_profile;
end;
$$;

create or replace function erp_supply.can_access_module(p_module text, p_capability text default 'read')
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, auth
as $$
  select exists (
    select 1
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    join erp_supply.role_module_permissions mp on mp.role_code=pr.role_code and mp.module_code=p_module
    where p.auth_user_id=auth.uid() and p.active
      and case lower(coalesce(p_capability,'read'))
        when 'create' then mp.can_create
        when 'update' then mp.can_update
        when 'approve' then mp.can_approve
        when 'admin' then mp.can_admin
        else mp.can_read
      end
  )
$$;


create or replace function erp_supply.can_view_order(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth
as $$
  with ctx as (
    select erp_supply.current_profile_id() profile_id,erp_supply.current_roles() roles
  )
  select exists(
    select 1 from erp_supply.orders o cross join ctx
    where o.id=p_order_id and o.organization_id=erp_supply.current_org_id() and (
      ctx.roles && array['super_admin','gerencia','jefe_logistica','auditoria']::text[]
      or o.seller_profile_id=ctx.profile_id
      or o.current_assignee_id=ctx.profile_id
      or o.current_role_code=any(ctx.roles)
      or exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.assigned_profile_id=ctx.profile_id)
      or exists(select 1 from erp_supply.step_roles sr where sr.step_code=o.current_step_code and sr.role_code=any(ctx.roles) and sr.can_view)
    )
  )
$$;

create or replace function erp_supply.business_seconds_between(
  p_organization_id uuid,
  p_start timestamptz,
  p_end timestamptz
)
returns bigint
language sql
stable
security definer
set search_path = erp_supply, public
as $$
with org as (
  select o.id, o.timezone,
         (select c.id from erp_supply.work_calendars c where c.organization_id=o.id and c.active order by c.created_at limit 1) calendar_id
  from erp_supply.organizations o where o.id=p_organization_id
), days as (
  select g::date work_date, org.*
  from org,
  lateral generate_series(
    (p_start at time zone org.timezone)::date,
    (p_end at time zone org.timezone)::date,
    interval '1 day'
  ) g
), segments as (
  select d.work_date,d.timezone,
    ((d.work_date + s.start_time) at time zone d.timezone) seg_start,
    ((d.work_date + s.end_time) at time zone d.timezone) seg_end
  from days d
  join erp_supply.work_calendar_segments s
    on s.calendar_id=d.calendar_id and s.iso_weekday=extract(isodow from d.work_date)::int
  where not exists (
    select 1 from erp_supply.holidays h
    where h.organization_id=d.id and h.holiday_date=d.work_date
  )
), overlaps as (
  select greatest(seg_start,p_start) a, least(seg_end,p_end) b
  from segments where seg_end>p_start and seg_start<p_end
)
select coalesce(sum(greatest(0,extract(epoch from (b-a))))::bigint,0)
from overlaps
$$;

create or replace function erp_supply.initial_step(
  p_order_type text,
  p_payment_condition text,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case
    when p_payment_condition in ('CREDIT','MIXED') then 'CARTERA'
    when p_payment_condition='CASH' then 'CAJA'
    when p_requires_purchase or p_order_type='PVE' then 'COMPRAS'
    else 'RECEPCION_PEDIDO'
  end
$$;

create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case p_current_step
    when 'CARTERA' then case
      when p_payment_condition='MIXED' then 'CAJA'
      when p_requires_purchase or p_order_type='PVE' then 'COMPRAS'
      else 'RECEPCION_PEDIDO' end
    when 'CAJA' then case when p_requires_purchase or p_order_type='PVE' then 'COMPRAS' else 'RECEPCION_PEDIDO' end
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case when p_requires_cut then 'CORTE' else 'FACTURACION' end
    when 'CORTE' then 'FACTURACION'
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.default_role_for_step(p_step text, p_route text)
returns text
language sql
immutable
as $$
  select case p_step
    when 'CARTERA' then 'cartera'
    when 'CAJA' then 'caja'
    when 'COMPRAS' then 'compras'
    when 'RECEPCION_MERCANCIA' then 'recepcion_mercancia'
    when 'RECEPCION_PEDIDO' then 'coordinador_logistico'
    when 'ALISTAMIENTO' then 'aux_logistica'
    when 'CORTE' then 'auxiliar_corte'
    when 'FACTURACION' then case when p_route='NATIONAL_DISPATCH' then 'despacho_nacional' else 'coordinador_logistico' end
    when 'NATIONAL_DISPATCH' then 'despacho_nacional'
    when 'CLIENT_POINT' then 'coordinador_logistico'
    when 'CLIENT_PICKUP' then 'coordinador_logistico'
    when 'LOCAL_DISPATCH' then 'coordinador_logistico'
    when 'CLOSURE' then 'jefe_logistica'
    else null end
$$;

create or replace function erp_supply.resolve_assignment(
  p_org uuid,
  p_step text,
  p_route text,
  p_order_type text
)
returns table(profile_id uuid, role_code text)
language sql
stable
security definer
set search_path=erp_supply,public
as $$
  with matching as (
    select rr.assigned_profile_id,rr.assigned_role_code,rr.priority
    from erp_supply.routing_rules rr
    where rr.organization_id=p_org and rr.active and rr.step_code=p_step
      and (rr.route_code is null or rr.route_code=p_route)
      and (rr.order_type_code is null or rr.order_type_code=p_order_type)
    order by
      (rr.route_code is not null)::int desc,
      (rr.order_type_code is not null)::int desc,
      rr.priority asc
    limit 1
  )
  select m.assigned_profile_id,coalesce(m.assigned_role_code,erp_supply.default_role_for_step(p_step,p_route)) from matching m
  union all
  select null,erp_supply.default_role_for_step(p_step,p_route)
  where not exists(select 1 from matching)
  limit 1
$$;

create or replace function erp_supply.actor_can(
  p_actor uuid,
  p_step text,
  p_action text,
  p_assignee uuid default null
)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public
as $$
  select exists(
    select 1
    from erp_supply.profile_roles pr
    join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=p_step
    where pr.profile_id=p_actor and (
      sr.can_override or
      case upper(p_action)
        when 'CLAIM' then sr.can_claim
        when 'ASSIGN' then sr.can_assign
        when 'START' then sr.can_start and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'COMPLETE' then sr.can_complete and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'WAIT' then sr.can_block and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'BLOCK' then sr.can_block
        when 'RESUME' then sr.can_start
        else sr.can_view
      end
    )
  )
$$;

create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_assignment record; v_task erp_supply.order_tasks;
begin
  select * into v_assignment from erp_supply.resolve_assignment(p_order.organization_id,p_step,p_order.delivery_route_code,p_order.order_type_code);
  insert into erp_supply.order_tasks(order_id,step_code,sequence_no,queue_code,status,assigned_profile_id,assigned_role_code,assigned_at)
  select p_order.id,p_step,p_sequence,s.queue_code,
    case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_assignment.profile_id,v_assignment.role_code,
    case when v_assignment.profile_id is null then null else now() end
  from erp_supply.workflow_steps s where s.code=p_step
  returning * into v_task;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_assignment.profile_id,
      current_role_code=v_assignment.role_code,
      version=version+1
  where id=p_order.id;
  return v_task;
end;
$$;

create or replace function erp_supply.execute_action_internal(
  p_order_id uuid,
  p_action text,
  p_payload jsonb,
  p_actor uuid,
  p_bypass_permissions boolean default false,
  p_expected_version integer default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_action text := upper(trim(coalesce(p_action,'')));
  v_next text;
  v_new_task erp_supply.order_tasks%rowtype;
  v_target uuid;
  v_session erp_supply.task_sessions%rowtype;
  v_now timestamptz := now();
  v_business bigint := 0;
  v_event_id bigint;
  v_actor_role text;
begin
  if v_action='' then raise exception 'Acción requerida'; end if;
  if p_actor is null then raise exception 'Actor requerido' using errcode='42501'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if p_expected_version is not null and v_order.version<>p_expected_version then
    raise exception 'El pedido cambió mientras estaba abierto. Actualice la pantalla.' using errcode='40001';
  end if;
  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_order.organization_id and idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'version',v_order.version);
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  select pr.role_code into v_actor_role from erp_supply.profile_roles pr
  where pr.profile_id=p_actor order by pr.is_primary desc,pr.role_code limit 1;

  if v_action not in ('COMMENT','REQUEST_APPROVAL') and v_task.id is null and v_order.status not in ('CLOSED','CANCELLED') then
    raise exception 'El pedido no tiene una tarea operativa activa';
  end if;

  if not p_bypass_permissions and v_action in ('CLAIM','ASSIGN','START','COMPLETE','WAIT','BLOCK','RESUME')
     and not erp_supply.actor_can(p_actor,v_order.current_step_code,v_action,v_order.current_assignee_id) then
    raise exception 'El usuario no está autorizado para ejecutar % en %',v_action,v_order.current_step_code using errcode='42501';
  end if;

  if v_action='CLAIM' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede reclamarse en su estado actual'; end if;
    update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=coalesce(assigned_at,v_now),status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=p_actor,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='ASSIGN' then
    begin v_target := (p_payload->>'profileId')::uuid; exception when others then raise exception 'profileId inválido'; end;
    if not exists(select 1 from erp_supply.profiles where id=v_target and organization_id=v_order.organization_id and active) then raise exception 'Responsable no válido'; end if;
    update erp_supply.order_tasks set assigned_profile_id=v_target,assigned_at=v_now,status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=v_target,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='START' then
    if v_task.status not in ('QUEUED','ASSIGNED','WAITING') then raise exception 'La tarea no puede iniciarse en su estado actual'; end if;
    if v_task.assigned_profile_id is null then
      update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=v_now where id=v_task.id;
    end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then
      raise exception 'El usuario ya tiene otra sesión de trabajo activa';
    end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action in ('WAIT','BLOCK') then
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=extract(epoch from(v_now-s.started_at))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,
      blocked_at=case when v_action='BLOCK' then v_now else blocked_at end,
      result_detail=coalesce(p_payload->>'reason',p_payload->>'detail',result_detail)
    where id=v_task.id returning * into v_task;
    update erp_supply.orders set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='RESUME' then
    if v_task.status not in ('WAITING','BLOCKED') then raise exception 'La tarea no está en espera o bloqueo'; end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note) values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMPLETE' then
    if not p_bypass_permissions and v_task.status<>'IN_PROGRESS' then raise exception 'Debe iniciar la tarea antes de finalizarla'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=extract(epoch from(v_now-s.started_at))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    select coalesce(sum(business_seconds),0) into v_business from erp_supply.task_sessions where task_id=v_task.id;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-coalesce(started_at,created_at)))::bigint),
      business_seconds=v_business,result_code=coalesce(p_payload->>'resultCode','COMPLETED'),result_detail=p_payload->>'detail',metadata=metadata||coalesce(p_payload,'{}'::jsonb)
    where id=v_task.id returning * into v_task;

    v_next:=erp_supply.next_step(v_order.current_step_code,v_order.order_type_code,v_order.payment_condition_code,v_order.delivery_route_code,v_order.requires_cut,v_order.requires_purchase);
    if v_next='CLOSED' then
      update erp_supply.orders set current_step_code='CLOSED',status='CLOSED',closed_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
    else
      select * into v_new_task from erp_supply.create_task(v_order,v_next,v_task.sequence_no+1);
      select * into v_order from erp_supply.orders where id=v_order.id;
    end if;

  elsif v_action='NO_DELIVERY' then
    if v_order.current_step_code not in ('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'La no entrega solo aplica en despacho o entrega'; end if;
    insert into erp_supply.deliveries(order_id,route_code,status,no_delivery_reason,assigned_profile_id,metadata)
    values(v_order.id,v_order.delivery_route_code,'NOT_DELIVERED',coalesce(p_payload->>'reason','No entregado'),p_actor,p_payload);
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=p_payload->>'reason' where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='WAITING',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='REPROGRAM' then
    update erp_supply.deliveries set status='REPROGRAMMED',scheduled_at=(p_payload->>'scheduledAt')::timestamptz,metadata=metadata||p_payload
    where id=(select id from erp_supply.deliveries where order_id=v_order.id order by created_at desc limit 1);
    update erp_supply.order_tasks set status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMMENT' then
    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_order.id,p_actor,coalesce(p_payload->>'commentType','GENERAL'),coalesce(p_payload->>'visibility','ORDER'),p_payload->>'body',coalesce(p_payload->'metadata','{}'::jsonb));

  elsif v_action='REQUEST_APPROVAL' then
    insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
    values(v_order.organization_id,v_order.id,p_payload->>'requestType',p_actor,coalesce(p_payload->>'assignedRole','jefe_logistica'),p_payload->>'reason',p_payload);

  else
    raise exception 'Acción no reconocida: %',v_action;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_order.organization_id,v_order.id,coalesce(v_task.id,v_new_task.id),'WORKFLOW_ACTION',v_action,
    case when v_action='COMPLETE' then v_task.step_code else v_order.current_step_code end,
    v_order.current_step_code,null,v_order.status,p_actor,v_actor_role,p_idempotency_key,coalesce(p_payload,'{}'::jsonb))
  returning id into v_event_id;

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_order.organization_id,'ORDER_ACTION','ORDER',v_order.id,jsonb_build_object('eventId',v_event_id,'action',v_action,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'eventId',v_event_id);
end;
$$;

commit;


-- ============================================================================
-- 004_public_api.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 004: browser-facing native Supabase RPC API.

begin;

create or replace function public.erp_x_session()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_profile erp_supply.profiles%rowtype; v_roles text[]; v_modules jsonb; v_org erp_supply.organizations%rowtype;
begin
  select * into v_profile from erp_supply.profiles where auth_user_id=auth.uid() and active limit 1;
  if not found then raise exception 'Usuario sin perfil operativo activo' using errcode='42501'; end if;
  select * into v_org from erp_supply.organizations where id=v_profile.organization_id;
  v_roles:=erp_supply.current_roles();
  select coalesce(jsonb_agg(x.obj order by x.sort_order),'[]'::jsonb) into v_modules from (
    select m.sort_order,jsonb_build_object('code',m.code,'name',m.name,'description',m.description,'icon',m.icon,'sortOrder',m.sort_order,
      'canRead',bool_or(mp.can_read),'canCreate',bool_or(mp.can_create),'canUpdate',bool_or(mp.can_update),'canApprove',bool_or(mp.can_approve),'canAdmin',bool_or(mp.can_admin)) obj
    from erp_supply.modules m join erp_supply.role_module_permissions mp on mp.module_code=m.code and mp.role_code=any(v_roles)
    where m.active group by m.code,m.name,m.description,m.icon,m.sort_order
  ) x;
  return jsonb_build_object(
    'profile',jsonb_build_object('id',v_profile.id,'email',v_profile.email,'name',v_profile.display_name,'employeeCode',v_profile.employee_code,'roles',v_roles,'preferences',v_profile.preferences),
    'organization',jsonb_build_object('id',v_org.id,'code',v_org.code,'name',v_org.name,'timezone',v_org.timezone,'settings',v_org.settings),
    'modules',v_modules,
    'catalogs',jsonb_build_object(
      'orderTypes',(select jsonb_agg(to_jsonb(t) order by sort_order) from erp_supply.order_types t where active),
      'paymentConditions',(select jsonb_agg(to_jsonb(p) order by sort_order) from erp_supply.payment_conditions p where active),
      'deliveryRoutes',(select jsonb_agg(to_jsonb(r) order by sort_order) from erp_supply.delivery_routes r where active),
      'steps',(select jsonb_agg(to_jsonb(s) order by sort_order) from erp_supply.workflow_steps s where active),
      'priorities',jsonb_build_array('LOW','MEDIUM','HIGH','URGENT','CRITICAL')
    ),
    'serverTime',now()
  );
end;
$$;

create or replace function public.erp_x_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile();
begin
  return jsonb_build_object(
    'kpis',jsonb_build_object(
      'activeOrders',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and status not in('CLOSED','CANCELLED')),
      'closedToday',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and closed_at::date=current_date),
      'critical',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and priority in('URGENT','CRITICAL') and status not in('CLOSED','CANCELLED')),
      'blocked',(select count(*) from erp_supply.orders where organization_id=v_org and not is_test and erp_supply.can_view_order(id) and status='BLOCKED'),
      'myTasks',(select count(*) from erp_supply.order_tasks t join erp_supply.orders o on o.id=t.order_id where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) and t.assigned_profile_id=v_profile and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')),
      'pendingApprovals',(select count(*) from erp_supply.approval_requests a where a.organization_id=v_org and a.status='PENDING' and (a.assigned_profile_id=v_profile or a.assigned_role_code=any(erp_supply.current_roles())))
    ),
    'queues',(select coalesce(jsonb_agg(q order by (q->>'sortOrder')::int),'[]'::jsonb) from (
      select jsonb_build_object('stepCode',s.code,'name',s.name,'sortOrder',s.sort_order,'quantity',count(o.id),
        'overdue',count(o.id) filter(where s.sla_hours is not null and erp_supply.business_seconds_between(v_org,o.updated_at,now())>s.sla_hours*3600),
        'inProgress',count(o.id) filter(where o.status='IN_PROGRESS'),'waiting',count(o.id) filter(where o.status in('WAITING','BLOCKED'))
      ) q
      from erp_supply.workflow_steps s left join erp_supply.orders o on o.current_step_code=s.code and o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) and o.status not in('CLOSED','CANCELLED')
      where not s.terminal group by s.code,s.name,s.sort_order,s.sla_hours
    ) z),
    'recent',(select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from (
      select o.id,o.order_number "orderNumber",o.client_name "clientName",o.order_type_code "orderType",o.current_step_code "currentStep",o.status,o.priority,o.updated_at "updatedAt"
      from erp_supply.orders o where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id) order by o.updated_at desc limit 12
    ) x),
    'generatedAt',now()
  );
end;
$$;

create or replace function public.erp_x_list_orders(
  p_search text default null,
  p_step text default null,
  p_status text default null,
  p_order_type text default null,
  p_route text default null,
  p_assignment text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 50,
  p_include_history boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),250); v_total bigint; v_items jsonb;
begin
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o
    left join erp_supply.profiles p on p.id=o.current_assignee_id
    join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
  ) select count(*) into v_total from filtered;

  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.updated_at desc
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'externalReference',external_reference,'orderType',order_type_code,'clientName',client_name,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep',current_step_code,'stepName',step_name,
    'status',status,'priority',priority,'requiresCut',requires_cut,'requiresPurchase',requires_purchase,'assigneeId',current_assignee_id,
    'assigneeName',assignee_name,'roleCode',current_role_code,'ageBusinessSeconds',age_business_seconds,
    'slaExceeded',(sla_hours is not null and age_business_seconds>sla_hours*3600),'version',version,'isHistory',is_history,'createdAt',created_at,'updatedAt',updated_at
  )),'[]'::jsonb) into v_items from filtered;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_get_actions(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_actions jsonb:='[]'; v_can_override boolean;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1;
  v_can_override:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia');
  if v_order.status not in('CLOSED','CANCELLED') then
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'CLAIM',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLAIM','label','Tomar tarea','kind','primary')); end if;
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'START',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','START','label','Iniciar trabajo','kind','primary','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'COMPLETE',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE','label','Finalizar etapa','kind','success','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','WAIT','label','Poner en espera','kind','warning','requires',jsonb_build_array('reason'))); end if;
    if v_task.status in('WAITING','BLOCKED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','RESUME','label','Reanudar','kind','primary')); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and v_task.status in('ASSIGNED','IN_PROGRESS') then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','NO_DELIVERY','label','Registrar no entrega','kind','danger','requires',jsonb_build_array('reason'))); end if;
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMMENT','label','Agregar comentario','kind','secondary','requires',jsonb_build_array('body')));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REQUEST_APPROVAL','label','Solicitar aprobación','kind','secondary','requires',jsonb_build_array('requestType','reason')));
  end if;
  return jsonb_build_object('orderId',v_order.id,'version',v_order.version,'status',v_order.status,'currentStep',v_order.current_step_code,'taskStatus',v_task.status,'canOverride',v_can_override,'actions',v_actions);
end;
$$;

create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_order erp_supply.orders%rowtype;
begin
  erp_supply.require_profile();
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb) from erp_supply.order_items i where i.order_id=p_order_id),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

create or replace function public.erp_x_create_order(p_payload jsonb, p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_order erp_supply.orders%rowtype; v_initial text; v_task erp_supply.order_tasks%rowtype; v_item jsonb; v_line int:=0; v_requires_purchase boolean; v_number text;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then raise exception 'Rol no autorizado para crear pedidos' using errcode='42501'; end if;
  v_number:=nullif(trim(p_payload->>'orderNumber'),'');
  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if p_idempotency_key is not null and exists(select 1 from erp_supply.order_events where organization_id=v_org and idempotency_key=p_idempotency_key) then
    select o.* into v_order from erp_supply.orders o join erp_supply.order_events e on e.order_id=o.id where e.organization_id=v_org and e.idempotency_key=p_idempotency_key limit 1;
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number);
  end if;
  v_requires_purchase:=coalesce((p_payload->>'requiresPurchase')::boolean,(select requires_purchase_default from erp_supply.order_types where code=p_payload->>'orderType'),false);
  v_initial:=erp_supply.initial_step(p_payload->>'orderType',p_payload->>'paymentCondition',v_requires_purchase);
  insert into erp_supply.orders(organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata)
  values(v_org,v_number,p_payload->>'externalReference',p_payload->>'orderType',p_payload->>'paymentCondition',p_payload->>'deliveryRoute',p_payload->>'clientName',p_payload->>'clientDocument',p_payload->>'clientCity',p_payload->>'clientAddress',p_payload->>'clientPhone',v_actor,v_initial,'QUEUED',coalesce(p_payload->>'priority','MEDIUM'),coalesce((p_payload->>'requiresCut')::boolean,false),v_requires_purchase,(p_payload->>'promisedAt')::timestamptz,(p_payload->>'requestedDeliveryDate')::date,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_order;
  for v_item in select value from jsonb_array_elements(coalesce(p_payload->'items','[]'::jsonb)) loop
    v_line:=v_line+1;
    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,warehouse_location,requires_cut,requested_cut_length,dimensions,metadata)
    values(v_order.id,coalesce((v_item->>'lineNumber')::int,v_line),v_item->>'sku',v_item->>'reference',coalesce(v_item->>'description','Ítem sin descripción'),(v_item->>'quantity')::numeric,coalesce(v_item->>'unit','UND'),v_item->>'warehouseLocation',coalesce((v_item->>'requiresCut')::boolean,false),(v_item->>'requestedCutLength')::numeric,coalesce(v_item->'dimensions','{}'::jsonb),coalesce(v_item->'metadata','{}'::jsonb));
  end loop;
  if v_line=0 then raise exception 'El pedido debe contener al menos un ítem'; end if;
  select * into v_task from erp_supply.create_task(v_order,v_initial,1);
  select * into v_order from erp_supply.orders where id=v_order.id;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,to_step_code,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,p_payload);
  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_execute_action(p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,p_expected_version integer default null,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
begin
  return erp_supply.execute_action_internal(p_order_id,p_action_code,coalesce(p_payload,'{}'::jsonb),erp_supply.require_profile(),false,p_expected_version,p_idempotency_key);
end;
$$;

create or replace function public.erp_x_list_approvals(p_status text default 'PENDING',p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_roles text[]:=erp_supply.current_roles(); v_total bigint; v_items jsonb; v_page int:=greatest(p_page,1); v_size int:=least(greatest(p_page_size,1),200);
begin
  select count(*) into v_total from erp_supply.approval_requests a where a.organization_id=v_org and (p_status is null or a.status=p_status) and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria'));
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select a.id,a.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",a.request_type "requestType",a.status,a.reason,a.request_payload "requestPayload",rq.display_name "requestedBy",a.assigned_role_code "assignedRole",a.decision_reason "decisionReason",a.created_at "createdAt",a.decided_at "decidedAt"
    from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id join erp_supply.profiles rq on rq.id=a.requested_by
    where a.organization_id=v_org and (p_status is null or a.status=p_status) and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria'))
    order by a.created_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_roles text[]:=erp_supply.current_roles(); v_req erp_supply.approval_requests%rowtype; v_order erp_supply.orders%rowtype; v_dec text:=upper(p_decision);
begin
  select * into v_req from erp_supply.approval_requests where id=p_request_id for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if not (v_req.assigned_profile_id=v_actor or v_req.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then raise exception 'No autorizado para decidir' using errcode='42501'; end if;
  update erp_supply.approval_requests set status=v_dec,decision_reason=p_reason,decided_by=v_actor,decided_at=now() where id=p_request_id returning * into v_req;
  if v_dec='APPROVED' then
    select * into v_order from erp_supply.orders where id=v_req.order_id for update;
    case v_req.request_type
      when 'CANCELLATION' then
        update erp_supply.order_tasks set status='CANCELLED',completed_at=now() where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
        update erp_supply.orders set status='CANCELLED',cancelled_at=now(),current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id;
      when 'PRIORITY' then update erp_supply.orders set priority=coalesce(v_req.request_payload->>'priority','HIGH'),version=version+1 where id=v_order.id;
      when 'ROUTE_CHANGE' then update erp_supply.orders set delivery_route_code=v_req.request_payload->>'route',version=version+1 where id=v_order.id;
      when 'REOPEN' then
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code=coalesce(v_req.request_payload->>'targetStep','CLOSURE'),version=version+1 where id=v_order.id returning * into v_order;
        perform erp_supply.create_task(v_order,v_order.current_step_code,(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id));
      else null;
    end case;
    update erp_supply.approval_requests set status='EXECUTED',executed_at=now() where id=p_request_id;
  end if;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason));
  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec);
end;
$$;

create or replace function public.erp_x_register_drive_file(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_file erp_supply.drive_files%rowtype;
begin
  insert into erp_supply.drive_files(organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,web_view_link,web_content_link,size_bytes,uploaded_by,metadata)
  values(v_org,(p_payload->>'orderId')::uuid,(p_payload->>'taskId')::uuid,p_payload->>'category',p_payload->>'driveFileId',p_payload->>'fileName',p_payload->>'mimeType',p_payload->>'webViewLink',p_payload->>'webContentLink',(p_payload->>'sizeBytes')::bigint,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_file;
  return jsonb_build_object('success',true,'file',to_jsonb(v_file));
end;
$$;

create or replace function public.erp_x_inventory(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_total bigint; v_items jsonb; v_page int:=greatest(p_page,1);v_size int:=least(greatest(p_page_size,1),200);
begin
  erp_supply.require_profile();
  select count(*) into v_total from erp_supply.inventory_items i where i.organization_id=v_org and i.active and (p_search is null or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select i.id,i.sku,i.reference,i.description,i.unit,i.item_type "itemType",i.barcode,
      coalesce(sum(l.quantity_available),0) "available",coalesce(sum(l.quantity_reserved),0) "reserved",coalesce(sum(l.quantity_blocked),0) "blocked",count(l.id) "lots"
    from erp_supply.inventory_items i left join erp_supply.inventory_lots l on l.inventory_item_id=i.id
    where i.organization_id=v_org and i.active and (p_search is null or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')) like '%'||lower(p_search)||'%')
    group by i.id order by i.description offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_vsm(p_date_from date default current_date-30,p_date_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return jsonb_build_object(
    'steps',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order),'[]'::jsonb) from (
      select s.code,s.name,s.sort_order,count(o.id) tasks,
        round(avg(t.business_seconds) filter(where o.id is not null)/3600.0,2) "avgBusinessHours",round(avg(t.raw_seconds) filter(where o.id is not null)/3600.0,2) "avgElapsedHours",
        round(percentile_cont(.5) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0,2) "medianBusinessHours",
        round(percentile_cont(.9) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0,2) "p90BusinessHours"
      from erp_supply.workflow_steps s left join erp_supply.order_tasks t on t.step_code=s.code and t.completed_at::date between p_date_from and p_date_to
      left join erp_supply.orders o on o.id=t.order_id and o.organization_id=v_org and not o.is_test
      group by s.code,s.name,s.sort_order
    ) x),
    'throughput',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) from (
      select d::date day,count(o.id) filter(where o.created_at::date=d::date) created,count(o.id) filter(where o.closed_at::date=d::date) closed
      from generate_series(p_date_from,p_date_to,'1 day') d left join erp_supply.orders o on o.organization_id=v_org and not o.is_test and (o.created_at::date=d::date or o.closed_at::date=d::date)
      group by d
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Historical CSV import receives normalized JSON rows in batches.
create or replace function public.erp_x_import_history(p_file_name text,p_rows jsonb,p_batch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_batch erp_supply.import_batches%rowtype; v_row jsonb; v_n int:=0; v_ok int:=0; v_bad int:=0; v_order erp_supply.orders%rowtype; v_step text; v_status text;
begin
  if not erp_supply.can_access_module('imports','create') then raise exception 'No autorizado para importar históricos' using errcode='42501'; end if;
  if p_batch_id is null then
    insert into erp_supply.import_batches(organization_id,import_type,file_name,imported_by,total_rows) values(v_org,'ORDER_HISTORY',p_file_name,v_actor,jsonb_array_length(p_rows)) returning * into v_batch;
  else select * into v_batch from erp_supply.import_batches where id=p_batch_id and organization_id=v_org for update;
  end if;
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_n:=v_n+1;
    begin
      v_status:=upper(coalesce(v_row->>'status','CLOSED'));
      if v_status not in('CLOSED','CANCELLED') then v_status:='CLOSED'; end if;
      v_step:=case when v_status='CLOSED' then 'CLOSED' else coalesce(v_row->>'currentStep','CLOSED') end;
      insert into erp_supply.orders(organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,client_name,client_document,client_city,current_step_code,status,priority,requires_cut,requires_purchase,source,is_history,metadata,created_at,updated_at,closed_at,cancelled_at)
      values(v_org,v_row->>'orderNumber',v_row->>'externalReference',coalesce(v_row->>'orderType','PVC'),coalesce(v_row->>'paymentCondition','CREDIT'),coalesce(v_row->>'deliveryRoute','LOCAL_DISPATCH'),coalesce(v_row->>'clientName','Cliente histórico'),v_row->>'clientDocument',v_row->>'clientCity',v_step,v_status,coalesce(v_row->>'priority','MEDIUM'),coalesce((v_row->>'requiresCut')::boolean,false),coalesce((v_row->>'requiresPurchase')::boolean,false),'CSV_HISTORY',true,v_row,coalesce((v_row->>'createdAt')::timestamptz,now()),coalesce((v_row->>'updatedAt')::timestamptz,now()),case when v_status='CLOSED' then coalesce((v_row->>'closedAt')::timestamptz,(v_row->>'updatedAt')::timestamptz,now()) end,case when v_status='CANCELLED' then coalesce((v_row->>'cancelledAt')::timestamptz,now()) end)
      on conflict(organization_id,order_number) do update set metadata=erp_supply.orders.metadata||excluded.metadata,is_history=true;
      v_ok:=v_ok+1;
    exception when others then
      v_bad:=v_bad+1;
      insert into erp_supply.import_errors(batch_id,row_number,error_code,error_message,raw_row) values(v_batch.id,v_n,sqlstate,sqlerrm,v_row);
    end;
  end loop;
  update erp_supply.import_batches set inserted_rows=inserted_rows+v_ok,rejected_rows=rejected_rows+v_bad,status=case when v_bad=0 then 'COMPLETED' when v_ok=0 then 'FAILED' else 'PARTIAL' end,completed_at=now(),summary=summary||jsonb_build_object('lastBatchRows',v_n) where id=v_batch.id returning * into v_batch;
  return jsonb_build_object('success',v_bad=0,'batchId',v_batch.id,'processed',v_n,'inserted',v_ok,'rejected',v_bad,'status',v_batch.status);
end;
$$;

create or replace function public.erp_x_users()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  if not (erp_supply.can_access_module('admin','read') or erp_supply.has_role('jefe_logistica')) then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) from (
    select p.id,p.email,p.display_name name,p.employee_code "employeeCode",p.active,p.auth_user_id "authUserId",coalesce(array_agg(pr.role_code) filter(where pr.role_code is not null),'{}') roles
    from erp_supply.profiles p left join erp_supply.profile_roles pr on pr.profile_id=p.id where p.organization_id=v_org group by p.id
  ) x);
end;
$$;

-- Revoke everything by default, then expose only the native API.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public, anon, authenticated',r.sig); end loop;
end $$;

grant execute on function public.erp_x_session() to authenticated;
grant execute on function public.erp_x_dashboard() to authenticated;
grant execute on function public.erp_x_list_orders(text,text,text,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.erp_x_get_actions(uuid) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;
grant execute on function public.erp_x_create_order(jsonb,text) to authenticated;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;
grant execute on function public.erp_x_list_approvals(text,integer,integer) to authenticated;
grant execute on function public.erp_x_decide_approval(uuid,text,text) to authenticated;
grant execute on function public.erp_x_register_drive_file(jsonb) to authenticated;
grant execute on function public.erp_x_inventory(text,integer,integer) to authenticated;
grant execute on function public.erp_x_vsm(date,date) to authenticated;
grant execute on function public.erp_x_import_history(text,jsonb,uuid) to authenticated;
grant execute on function public.erp_x_users() to authenticated;

commit;


-- ============================================================================
-- 005_qa_and_admin.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 005: bootstrap, administration and deterministic 192-scenario QA bot.

begin;

-- Bootstrap the known administrator only when the Supabase Auth account already exists.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active)
select o.id,u.id,lower(u.email),coalesce(u.raw_user_meta_data->>'full_name','Juan Esteban Pérez'),true
from auth.users u cross join erp_supply.organizations o
where lower(u.email)='j.perez@ei.com.co' and o.code='EI'
on conflict (organization_id,email) do update set auth_user_id=excluded.auth_user_id,active=true;

insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
select p.id,'super_admin',true from erp_supply.profiles p where lower(p.email)='j.perez@ei.com.co'
on conflict (profile_id,role_code) do update set is_primary=true;

create or replace function public.erp_x_admin_save_profile(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile erp_supply.profiles%rowtype; v_role text;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede administrar usuarios' using errcode='42501'; end if;
  if p_payload->>'id' is null then
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active)
    values(v_org,(p_payload->>'authUserId')::uuid,lower(p_payload->>'email'),p_payload->>'name',p_payload->>'employeeCode',coalesce((p_payload->>'active')::boolean,true)) returning * into v_profile;
  else
    update erp_supply.profiles set auth_user_id=coalesce((p_payload->>'authUserId')::uuid,auth_user_id),email=lower(p_payload->>'email'),display_name=p_payload->>'name',employee_code=p_payload->>'employeeCode',active=coalesce((p_payload->>'active')::boolean,active)
    where id=(p_payload->>'id')::uuid and organization_id=v_org returning * into v_profile;
  end if;
  delete from erp_supply.profile_roles where profile_id=v_profile.id;
  for v_role in select value#>>'{}' from jsonb_array_elements(coalesce(p_payload->'roles','[]'::jsonb)) loop
    insert into erp_supply.profile_roles(profile_id,role_code,is_primary,granted_by) values(v_profile.id,v_role,not exists(select 1 from erp_supply.profile_roles where profile_id=v_profile.id),erp_supply.current_profile_id());
  end loop;
  return jsonb_build_object('success',true,'profile',to_jsonb(v_profile));
end;
$$;

create or replace function public.erp_x_admin_sync_auth()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_count integer;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede sincronizar Auth' using errcode='42501'; end if;
  with inserted as (
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active)
    select v_org,u.id,lower(u.email),coalesce(u.raw_user_meta_data->>'full_name',split_part(u.email,'@',1)),false
    from auth.users u
    where u.email is not null and not exists(select 1 from erp_supply.profiles p where p.organization_id=v_org and (p.auth_user_id=u.id or lower(p.email)=lower(u.email)))
    returning 1
  ) select count(*) into v_count from inserted;
  update erp_supply.profiles p set auth_user_id=u.id
  from auth.users u where p.organization_id=v_org and p.auth_user_id is null and lower(p.email)=lower(u.email);
  return jsonb_build_object('success',true,'createdProfiles',v_count);
end;
$$;

create or replace function public.erp_x_calendar()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return jsonb_build_object(
    'calendars',(select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from erp_supply.work_calendars c where c.organization_id=v_org),
    'segments',(select coalesce(jsonb_agg(to_jsonb(s) order by s.iso_weekday,s.start_time),'[]'::jsonb) from erp_supply.work_calendar_segments s join erp_supply.work_calendars c on c.id=s.calendar_id where c.organization_id=v_org),
    'holidays',(select coalesce(jsonb_agg(to_jsonb(h) order by h.holiday_date),'[]'::jsonb) from erp_supply.holidays h where h.organization_id=v_org)
  );
end;
$$;

create or replace function public.erp_x_run_qa_matrix(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_run erp_supply.qa_runs%rowtype;
  v_type text; v_payment text; v_route text; v_cut boolean; v_purchase boolean; v_key text; v_initial text;
  v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_scenario erp_supply.qa_scenarios%rowtype;
  v_expected jsonb; v_actual jsonb; v_step text; v_guard int; v_passed int:=0;v_failed int:=0;v_total int:=0;v_error text;
begin
  if not erp_supply.has_role('super_admin') then raise exception 'El bot QA solo puede ser ejecutado por Super Admin' using errcode='42501'; end if;
  insert into erp_supply.qa_runs(organization_id,requested_by,total_scenarios) values(v_org,v_actor,192) returning * into v_run;
  foreach v_type in array array['PVC','PVN','PVE','PVP'] loop
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_total:=v_total+1; v_error:=null;
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_type,v_payment,v_route,v_cut,v_purchase);
            v_initial:=erp_supply.initial_step(v_type,v_payment,v_purchase or v_type='PVE');
            v_expected:=jsonb_build_array(v_initial); v_step:=v_initial; v_guard:=0;
            while v_step<>'CLOSED' and v_guard<20 loop
              v_step:=erp_supply.next_step(v_step,v_type,v_payment,v_route,v_cut,v_purchase or v_type='PVE');
              v_expected:=v_expected||jsonb_build_array(v_step); v_guard:=v_guard+1;
            end loop;
            insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,input,expected_path)
            values(v_run.id,v_key,jsonb_build_object('orderType',v_type,'payment',v_payment,'route',v_route,'requiresCut',v_cut,'requiresPurchase',v_purchase),v_expected)
            returning * into v_scenario;
            begin
              insert into erp_supply.orders(organization_id,order_number,order_type_code,payment_condition_code,delivery_route_code,client_name,seller_profile_id,current_step_code,status,requires_cut,requires_purchase,source,is_test,qa_run_id,metadata)
              values(v_org,'QA-'||replace(v_run.id::text,'-','')||'-'||lpad(v_total::text,3,'0'),v_type,v_payment,v_route,'Cliente QA '||v_key,v_actor,v_initial,'QUEUED',v_cut,v_purchase or v_type='PVE','QA_BOT',true,v_run.id,jsonb_build_object('scenario',v_key)) returning * into v_order;
              insert into erp_supply.order_items(order_id,line_number,sku,description,quantity,unit,requires_cut,requested_cut_length)
              values(v_order.id,1,'QA-'||v_type,'Material de prueba automatizada',1,'UND',v_cut,case when v_cut then 10 else null end);
              select * into v_task from erp_supply.create_task(v_order,v_initial,1);
              v_actual:=jsonb_build_array(v_initial); v_guard:=0;
              loop
                select * into v_order from erp_supply.orders where id=v_order.id;
                exit when v_order.status='CLOSED' or v_guard>=20;
                perform erp_supply.execute_action_internal(v_order.id,'START',jsonb_build_object('detail','Inicio QA'),v_actor,true,null,v_key||'-START-'||v_guard);
                perform erp_supply.execute_action_internal(v_order.id,'COMPLETE',jsonb_build_object('detail','Finalización QA'),v_actor,true,null,v_key||'-COMPLETE-'||v_guard);
                select * into v_order from erp_supply.orders where id=v_order.id;
                v_actual:=v_actual||jsonb_build_array(v_order.current_step_code); v_guard:=v_guard+1;
              end loop;
              if v_order.status='CLOSED' and v_actual=v_expected then
                update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=v_actual,status='PASSED',completed_at=now() where id=v_scenario.id; v_passed:=v_passed+1;
              else
                v_error:=format('Estado final %s; paso %s; ruta esperada %s; ruta real %s',v_order.status,v_order.current_step_code,v_expected,v_actual);
                update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=v_actual,status='FAILED',error_message=v_error,completed_at=now() where id=v_scenario.id; v_failed:=v_failed+1;
              end if;
            exception when others then
              v_error:=sqlstate||' - '||sqlerrm;
              update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=coalesce(v_actual,'[]'::jsonb),status='FAILED',error_message=v_error,completed_at=now() where id=v_scenario.id; v_failed:=v_failed+1;
            end;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),summary=jsonb_build_object('matrix','4 order types × 3 payments × 4 routes × 2 cut × 2 purchase','cleanup',p_cleanup)
  where id=v_run.id returning * into v_run;
  if p_cleanup then delete from erp_supply.orders where qa_run_id=v_run.id; end if;
  return jsonb_build_object('runId',v_run.id,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
end;
$$;

create or replace function public.erp_x_qa_runs(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria')) then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]'::jsonb) from (
    select q.id,q.run_type "runType",q.status,q.total_scenarios "totalScenarios",q.passed_scenarios "passedScenarios",q.failed_scenarios "failedScenarios",q.started_at "startedAt",q.completed_at "completedAt",q.summary
    from erp_supply.qa_runs q where q.organization_id=v_org order by q.started_at desc limit least(greatest(p_limit,1),100)
  ) x);
end;
$$;

create or replace function public.erp_x_qa_run_detail(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_run erp_supply.qa_runs%rowtype;
begin
  erp_supply.require_profile();
  select * into v_run from erp_supply.qa_runs where id=p_run_id and organization_id=v_org;
  if not found then raise exception 'Ejecución QA no encontrada'; end if;
  return jsonb_build_object('run',to_jsonb(v_run),'scenarios',(select coalesce(jsonb_agg(to_jsonb(s) order by s.scenario_key),'[]'::jsonb) from erp_supply.qa_scenarios s where s.qa_run_id=p_run_id));
end;
$$;

revoke all on function public.erp_x_admin_save_profile(jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_admin_sync_auth() from public,anon,authenticated;
revoke all on function public.erp_x_calendar() from public,anon,authenticated;
revoke all on function public.erp_x_run_qa_matrix(boolean) from public,anon,authenticated;
revoke all on function public.erp_x_qa_runs(integer) from public,anon,authenticated;
revoke all on function public.erp_x_qa_run_detail(uuid) from public,anon,authenticated;
grant execute on function public.erp_x_admin_save_profile(jsonb) to authenticated;
grant execute on function public.erp_x_admin_sync_auth() to authenticated;
grant execute on function public.erp_x_calendar() to authenticated;
grant execute on function public.erp_x_run_qa_matrix(boolean) to authenticated;
grant execute on function public.erp_x_qa_runs(integer) to authenticated;
grant execute on function public.erp_x_qa_run_detail(uuid) to authenticated;

commit;


-- ============================================================================
-- 006_domain_services.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 006: credit, receiving, inventory, cutting, billing, delivery and audit services.

begin;

create or replace function public.erp_x_credit_list(p_status text default null,p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_total bigint;v_items jsonb;v_page int:=greatest(p_page,1);v_size int:=least(greatest(p_page_size,1),200);
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('credit','read') then raise exception 'No autorizado' using errcode='42501'; end if;
  select count(*) into v_total from erp_supply.credit_requests c where c.organization_id=v_org and (p_status is null or c.status=p_status) and (p_search is null or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select c.id,c.request_number "requestNumber",c.client_name "clientName",c.client_document "clientDocument",c.requested_amount "requestedAmount",c.requested_term_days "requestedTermDays",c.status,p.display_name "requestedBy",a.display_name "assignedTo",c.decision_reason "decisionReason",c.metadata,c.created_at "createdAt",c.updated_at "updatedAt"
    from erp_supply.credit_requests c join erp_supply.profiles p on p.id=c.requested_by left join erp_supply.profiles a on a.id=c.assigned_to
    where c.organization_id=v_org and (p_status is null or c.status=p_status) and (p_search is null or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%')
    order by c.created_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_credit_create(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_req erp_supply.credit_requests%rowtype;v_number text;
begin
  if not erp_supply.can_access_module('credit','create') then raise exception 'No autorizado para crear crédito' using errcode='42501'; end if;
  v_number:=coalesce(nullif(p_payload->>'requestNumber',''),'CR-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
  insert into erp_supply.credit_requests(organization_id,request_number,client_name,client_document,requested_amount,requested_term_days,status,requested_by,metadata)
  values(v_org,v_number,p_payload->>'clientName',p_payload->>'clientDocument',(p_payload->>'requestedAmount')::numeric,(p_payload->>'requestedTermDays')::int,'SUBMITTED',v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_req;
  return jsonb_build_object('success',true,'request',to_jsonb(v_req));
end;
$$;

create or replace function public.erp_x_credit_transition(p_request_id uuid,p_action text,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_req erp_supply.credit_requests%rowtype;v_action text:=upper(p_action);
begin
  select * into v_req from erp_supply.credit_requests where id=p_request_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Solicitud de crédito no encontrada'; end if;
  if v_action='TAKE' then
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests set status='UNDER_REVIEW',assigned_to=v_actor where id=v_req.id returning * into v_req;
  elsif v_action in('APPROVE','REJECT') then
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests set status=case when v_action='APPROVE' then 'APPROVED' else 'REJECTED' end,assigned_to=coalesce(assigned_to,v_actor),decision_reason=p_reason where id=v_req.id returning * into v_req;
  elsif v_action='CANCEL' then
    update erp_supply.credit_requests set status='CANCELLED',decision_reason=p_reason where id=v_req.id returning * into v_req;
  else raise exception 'Transición de crédito inválida';
  end if;
  return jsonb_build_object('success',true,'request',to_jsonb(v_req));
end;
$$;

create or replace function public.erp_x_save_receipt(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_receipt erp_supply.receipts%rowtype;v_line jsonb;v_inventory erp_supply.inventory_items%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_status text;
begin
  if not erp_supply.can_access_module('receiving','create') then raise exception 'No autorizado para recepción' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id();
  if not found then raise exception 'Pedido no encontrado'; end if;
  v_status:=coalesce(p_payload->>'status','CONFORMING');
  insert into erp_supply.receipts(order_id,receipt_number,purchase_order,supplier_name,status,received_by,received_at,metadata)
  values(p_order_id,coalesce(p_payload->>'receiptNumber','REC-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISS')),p_payload->>'purchaseOrder',p_payload->>'supplierName',v_status,v_actor,now(),coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_receipt;
  for v_line in select value from jsonb_array_elements(coalesce(p_payload->'lines','[]'::jsonb)) loop
    insert into erp_supply.receipt_lines(receipt_id,order_item_id,sku,description,expected_quantity,received_quantity,accepted_quantity,rejected_quantity,unit,location,quality_status,metadata)
    values(v_receipt.id,(v_line->>'orderItemId')::uuid,v_line->>'sku',coalesce(v_line->>'description','Material recibido'),(v_line->>'expectedQuantity')::numeric,(v_line->>'receivedQuantity')::numeric,coalesce((v_line->>'acceptedQuantity')::numeric,(v_line->>'receivedQuantity')::numeric),coalesce((v_line->>'rejectedQuantity')::numeric,0),coalesce(v_line->>'unit','UND'),coalesce(v_line->>'location','RECEPCION'),coalesce(v_line->>'qualityStatus','ACCEPTED'),coalesce(v_line->'metadata','{}'::jsonb));
    if coalesce((v_line->>'acceptedQuantity')::numeric,(v_line->>'receivedQuantity')::numeric)>0 then
      insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,barcode)
      values(v_order.organization_id,coalesce(v_line->>'sku','SKU-'||substr(gen_random_uuid()::text,1,8)),v_line->>'reference',coalesce(v_line->>'description','Material recibido'),coalesce(v_line->>'unit','UND'),coalesce(v_line->>'itemType','STANDARD'),v_line->>'barcode')
      on conflict(organization_id,sku) do update set description=excluded.description,reference=coalesce(excluded.reference,erp_supply.inventory_items.reference),unit=excluded.unit
      returning * into v_inventory;
      insert into erp_supply.inventory_lots(inventory_item_id,lot_number,serial_number,location,quantity_available,received_at,metadata)
      values(v_inventory.id,v_line->>'lotNumber',v_line->>'serialNumber',coalesce(v_line->>'location','RECEPCION'),coalesce((v_line->>'acceptedQuantity')::numeric,(v_line->>'receivedQuantity')::numeric),now(),jsonb_build_object('receiptId',v_receipt.id)) returning * into v_lot;
      insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,to_location,actor_profile_id,reference,metadata)
      values(v_order.organization_id,v_inventory.id,v_lot.id,p_order_id,'RECEIPT',v_lot.quantity_available,v_inventory.unit,v_lot.location,v_actor,v_receipt.receipt_number,'{}');
    end if;
  end loop;
  return jsonb_build_object('success',true,'receipt',to_jsonb(v_receipt));
end;
$$;

create or replace function public.erp_x_stickers(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
begin
  erp_supply.require_profile();
  return (select coalesce(jsonb_agg(jsonb_build_object(
    'receiptNumber',r.receipt_number,'purchaseOrder',r.purchase_order,'supplier',r.supplier_name,'receivedAt',r.received_at,
    'sku',l.sku,'description',l.description,'quantity',l.accepted_quantity,'unit',l.unit,'location',l.location,'lotNumber',l.metadata->>'lotNumber','qualityStatus',l.quality_status
  ) order by r.created_at,l.description),'[]'::jsonb)
  from erp_supply.receipts r join erp_supply.receipt_lines l on l.receipt_id=r.id where r.order_id=p_order_id);
end;
$$;

create or replace function public.erp_x_inventory_adjust(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_item erp_supply.inventory_items%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_qty numeric;v_type text;
begin
  if not erp_supply.can_access_module('inventory','update') then raise exception 'No autorizado para ajustar inventario' using errcode='42501'; end if;
  select * into v_item from erp_supply.inventory_items where id=(p_payload->>'itemId')::uuid and organization_id=v_org;
  if not found then raise exception 'Artículo no encontrado'; end if;
  select * into v_lot from erp_supply.inventory_lots where id=(p_payload->>'lotId')::uuid and inventory_item_id=v_item.id for update;
  if not found then raise exception 'Lote no encontrado'; end if;
  v_qty:=(p_payload->>'quantity')::numeric;v_type:=upper(p_payload->>'movementType');
  if v_type in('ISSUE','ADJUSTMENT_OUT','SCRAP') then
    if v_lot.quantity_available<v_qty then raise exception 'Existencia insuficiente'; end if;
    update erp_supply.inventory_lots set quantity_available=quantity_available-v_qty where id=v_lot.id returning * into v_lot;
  else
    update erp_supply.inventory_lots set quantity_available=quantity_available+v_qty where id=v_lot.id returning * into v_lot;
  end if;
  insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata)
  values(v_org,v_item.id,v_lot.id,(p_payload->>'orderId')::uuid,v_type,v_qty,v_item.unit,p_payload->>'fromLocation',p_payload->>'toLocation',v_actor,p_payload->>'reference',coalesce(p_payload->'metadata','{}'::jsonb));
  return jsonb_build_object('success',true,'lot',to_jsonb(v_lot));
end;
$$;

create or replace function public.erp_x_save_cut_job(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_job erp_supply.cut_jobs%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_item erp_supply.inventory_items%rowtype;v_actual numeric;v_scrap numeric;
begin
  if not erp_supply.can_access_module('cutting','update') then raise exception 'No autorizado para registrar corte' using errcode='42501'; end if;
  v_actual:=(p_payload->>'actualLength')::numeric;v_scrap:=coalesce((p_payload->>'scrapLength')::numeric,0);
  select * into v_lot from erp_supply.inventory_lots where id=(p_payload->>'inventoryLotId')::uuid for update;
  if not found then raise exception 'Chipa o lote no encontrado'; end if;
  select * into v_item from erp_supply.inventory_items where id=v_lot.inventory_item_id;
  if v_lot.quantity_available < v_actual+v_scrap then raise exception 'Longitud disponible insuficiente'; end if;
  insert into erp_supply.cut_jobs(order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,status,assigned_profile_id,started_at,completed_at,metadata)
  values(p_order_id,(p_payload->>'orderItemId')::uuid,v_lot.id,(p_payload->>'requestedLength')::numeric,v_actual,v_scrap,'COMPLETED',v_actor,coalesce((p_payload->>'startedAt')::timestamptz,now()),now(),coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_job;
  update erp_supply.inventory_lots set quantity_available=quantity_available-v_actual-v_scrap where id=v_lot.id;
  insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,actor_profile_id,reference,metadata)
  values(erp_supply.current_org_id(),v_item.id,v_lot.id,p_order_id,'CUT_CONSUMPTION',v_actual+v_scrap,v_item.unit,v_lot.location,v_actor,v_job.id::text,jsonb_build_object('actualLength',v_actual,'scrapLength',v_scrap));
  return jsonb_build_object('success',true,'cutJob',to_jsonb(v_job));
end;
$$;

create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_invoice erp_supply.invoices%rowtype;
begin
  if not erp_supply.can_access_module('billing','create') then raise exception 'No autorizado para facturar' using errcode='42501'; end if;
  insert into erp_supply.invoices(order_id,invoice_number,invoice_date,amount,currency,status,drive_file_id,registered_by,metadata)
  values(p_order_id,p_payload->>'invoiceNumber',coalesce((p_payload->>'invoiceDate')::date,current_date),(p_payload->>'amount')::numeric,coalesce(p_payload->>'currency','COP'),'REGISTERED',(p_payload->>'driveFileRecordId')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_invoice;
  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

create or replace function public.erp_x_save_delivery(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_delivery erp_supply.deliveries%rowtype;
begin
  if not erp_supply.can_access_module('shipping','update') then raise exception 'No autorizado para despacho' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id();
  if not found then raise exception 'Pedido no encontrado'; end if;
  insert into erp_supply.deliveries(order_id,route_code,status,scheduled_at,dispatched_at,delivered_at,received_by,no_delivery_reason,carrier,tracking_number,assigned_profile_id,metadata)
  values(p_order_id,v_order.delivery_route_code,coalesce(p_payload->>'status','PLANNED'),(p_payload->>'scheduledAt')::timestamptz,(p_payload->>'dispatchedAt')::timestamptz,(p_payload->>'deliveredAt')::timestamptz,p_payload->>'receivedBy',p_payload->>'noDeliveryReason',p_payload->>'carrier',p_payload->>'trackingNumber',v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_delivery;
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery));
end;
$$;

create or replace function public.erp_x_audit(p_entity_type text default null,p_search text default null,p_page integer default 1,p_page_size integer default 100)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_page int:=greatest(p_page,1);v_size int:=least(greatest(p_page_size,1),250);v_total bigint;v_items jsonb;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('audit','read') then raise exception 'No autorizado' using errcode='42501'; end if;
  select count(*) into v_total from erp_supply.order_events e join erp_supply.orders o on o.id=e.order_id where e.organization_id=v_org and not o.is_test and (p_entity_type is null or e.event_type=p_entity_type) and (p_search is null or lower(o.order_number||' '||coalesce(e.action_code,'')||' '||e.payload::text) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select e.id,e.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",e.event_type "eventType",e.action_code "actionCode",e.from_step_code "fromStep",e.to_step_code "toStep",e.from_status "fromStatus",e.to_status "toStatus",p.display_name actor,e.actor_role_code "actorRole",e.payload,e.created_at "createdAt"
    from erp_supply.order_events e join erp_supply.orders o on o.id=e.order_id left join erp_supply.profiles p on p.id=e.actor_profile_id
    where e.organization_id=v_org and not o.is_test and (p_entity_type is null or e.event_type=p_entity_type) and (p_search is null or lower(o.order_number||' '||coalesce(e.action_code,'')||' '||e.payload::text) like '%'||lower(p_search)||'%')
    order by e.created_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

-- Permissions.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('erp_x_credit_list','erp_x_credit_create','erp_x_credit_transition','erp_x_save_receipt','erp_x_stickers','erp_x_inventory_adjust','erp_x_save_cut_job','erp_x_save_invoice','erp_x_save_delivery','erp_x_audit')
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;


-- ============================================================================
-- 007_health_check.sql
-- ============================================================================
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


-- ============================================================================
-- 008_enterprise_controls.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 008: enterprise stage gates, mandatory checklists, assignment pools and domain controls.

begin;

create table if not exists erp_supply.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  po_number text not null,
  supplier_name text not null,
  status text not null default 'ISSUED' check (status in ('DRAFT','ISSUED','CONFIRMED','PARTIAL','RECEIVED','CANCELLED')),
  total_amount numeric(18,2),
  currency text not null default 'COP',
  expected_at timestamptz,
  drive_file_id uuid references erp_supply.drive_files(id),
  created_by uuid not null references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_id,po_number)
);

create table if not exists erp_supply.financial_validations (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  validation_type text not null check (validation_type in ('CARTERA','CAJA')),
  decision text not null check (decision in ('APPROVED','REJECTED','PENDING')),
  amount numeric(18,2),
  reference text,
  notes text not null,
  evidence_file_id uuid references erp_supply.drive_files(id),
  created_by uuid not null references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists idx_financial_order_type on erp_supply.financial_validations(order_id,validation_type,created_at desc);

create table if not exists erp_supply.checklist_templates (
  step_code text not null references erp_supply.workflow_steps(code) on delete cascade,
  item_code text not null,
  label text not null,
  required boolean not null default true,
  sort_order integer not null default 100,
  active boolean not null default true,
  primary key(step_code,item_code)
);

create table if not exists erp_supply.task_checklist (
  task_id uuid not null references erp_supply.order_tasks(id) on delete cascade,
  item_code text not null,
  label text not null,
  required boolean not null default true,
  sort_order integer not null default 100,
  completed boolean not null default false,
  completed_by uuid references erp_supply.profiles(id),
  completed_at timestamptz,
  note text,
  metadata jsonb not null default '{}'::jsonb,
  primary key(task_id,item_code)
);

insert into erp_supply.checklist_templates(step_code,item_code,label,required,sort_order) values
  ('CARTERA','CLIENT_DATA','Datos del cliente y condición comercial verificados',true,10),
  ('CARTERA','CREDIT_STATUS','Cupo, mora y condición de crédito validados',true,20),
  ('CAJA','PAYMENT_REFERENCE','Referencia y valor del pago verificados',true,10),
  ('CAJA','PAYMENT_SUPPORT','Soporte de pago registrado',true,20),
  ('COMPRAS','SUPPLIER','Proveedor y disponibilidad confirmados',true,10),
  ('COMPRAS','PURCHASE_ORDER','Orden de compra registrada',true,20),
  ('RECEPCION_MERCANCIA','COUNT','Cantidades recibidas verificadas',true,10),
  ('RECEPCION_MERCANCIA','QUALITY','Inspección de calidad registrada',true,20),
  ('RECEPCION_MERCANCIA','LOCATION','Ubicación y lote asignados',true,30),
  ('RECEPCION_PEDIDO','DOCUMENTS','Documentación comercial revisada',true,10),
  ('RECEPCION_PEDIDO','ASSIGNMENT','Pedido asignado a la cola operativa',true,20),
  ('ALISTAMIENTO','ITEMS','Todos los ítems fueron encontrados y verificados',true,10),
  ('ALISTAMIENTO','QUANTITIES','Cantidades y referencias coinciden con el pedido',true,20),
  ('ALISTAMIENTO','PACKAGING','Empaque, identificación y protección completados',true,30),
  ('CORTE','MEASUREMENTS','Medidas solicitadas verificadas',true,10),
  ('CORTE','CUT_RECORD','Consumo, longitud real y desperdicio registrados',true,20),
  ('CORTE','IDENTIFICATION','Material cortado identificado y ubicado',true,30),
  ('FACTURACION','INVOICE','Factura registrada y asociada al pedido',true,10),
  ('FACTURACION','COMMERCIAL_MATCH','Valores, cliente e ítems coinciden con la orden',true,20),
  ('CLIENT_POINT','DELIVERY_EVIDENCE','Evidencia y receptor registrados',true,10),
  ('CLIENT_PICKUP','DELIVERY_EVIDENCE','Evidencia y receptor registrados',true,10),
  ('LOCAL_DISPATCH','DELIVERY_EVIDENCE','Evidencia, transportador y receptor registrados',true,10),
  ('NATIONAL_DISPATCH','DELIVERY_EVIDENCE','Guía, transportadora y evidencia registradas',true,10),
  ('CLOSURE','DOCUMENTS_COMPLETE','Expediente documental completo',true,10),
  ('CLOSURE','DELIVERY_CONFIRMED','Entrega confirmada y sin pendientes',true,20)
on conflict(step_code,item_code) do update set label=excluded.label,required=excluded.required,sort_order=excluded.sort_order,active=true;

-- Replace task creation so every task is born with its controlled checklist.
create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_assignment record; v_task erp_supply.order_tasks;
begin
  select * into v_assignment from erp_supply.resolve_assignment(p_order.organization_id,p_step,p_order.delivery_route_code,p_order.order_type_code);
  insert into erp_supply.order_tasks(order_id,step_code,sequence_no,queue_code,status,assigned_profile_id,assigned_role_code,assigned_at)
  select p_order.id,p_step,p_sequence,s.queue_code,
    case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_assignment.profile_id,v_assignment.role_code,
    case when v_assignment.profile_id is null then null else now() end
  from erp_supply.workflow_steps s where s.code=p_step
  returning * into v_task;

  insert into erp_supply.task_checklist(task_id,item_code,label,required,sort_order)
  select v_task.id,t.item_code,t.label,t.required,t.sort_order
  from erp_supply.checklist_templates t
  where t.step_code=p_step and t.active
  on conflict(task_id,item_code) do nothing;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_assignment.profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_assignment.profile_id,
      current_role_code=v_assignment.role_code,
      version=version+1
  where id=p_order.id;
  return v_task;
end;
$$;

create or replace function erp_supply.validate_task_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_order erp_supply.orders%rowtype; v_missing integer;
begin
  if new.status<>'COMPLETED' or old.status='COMPLETED' then return new; end if;
  select * into v_order from erp_supply.orders where id=new.order_id;
  if v_order.is_test then return new; end if;

  select count(*) into v_missing from erp_supply.task_checklist
  where task_id=new.id and required and not completed;
  if v_missing>0 then raise exception 'No puede finalizar: quedan % controles obligatorios sin completar',v_missing; end if;

  case new.step_code
    when 'CARTERA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CARTERA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Cartera';
      end if;
    when 'CAJA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CAJA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Caja';
      end if;
    when 'COMPRAS' then
      if not exists(select 1 from erp_supply.purchase_orders where order_id=v_order.id and status in('ISSUED','CONFIRMED','PARTIAL','RECEIVED')) then
        raise exception 'Debe registrar una orden de compra válida';
      end if;
    when 'RECEPCION_MERCANCIA' then
      if not exists(select 1 from erp_supply.receipts where order_id=v_order.id and status in('PARTIAL','CONFORMING','CLOSED')) then
        raise exception 'Debe registrar la recepción física y su resultado de calidad';
      end if;
    when 'CORTE' then
      if v_order.requires_cut and not exists(select 1 from erp_supply.cut_jobs where order_id=v_order.id and status='COMPLETED') then
        raise exception 'Debe registrar al menos un corte completado';
      end if;
    when 'FACTURACION' then
      if not exists(select 1 from erp_supply.invoices where order_id=v_order.id and status='REGISTERED') then
        raise exception 'Debe registrar la factura antes de liberar el pedido';
      end if;
    when 'CLIENT_POINT' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'CLIENT_PICKUP' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'LOCAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'NATIONAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega nacional'; end if;
    when 'CLOSURE' then
      if not exists(select 1 from erp_supply.invoices where order_id=v_order.id) then raise exception 'El pedido no tiene factura registrada'; end if;
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'El pedido no tiene entrega confirmada'; end if;
    else null;
  end case;
  return new;
end;
$$;

drop trigger if exists trg_validate_task_completion on erp_supply.order_tasks;
create trigger trg_validate_task_completion before update of status on erp_supply.order_tasks
for each row execute function erp_supply.validate_task_completion();

create or replace function public.erp_x_assignment_pool(p_step_code text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) from (
    select distinct p.id,p.display_name name,p.email,array_agg(distinct pr.role_code) roles
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=p_step_code and sr.can_view
    where p.organization_id=v_org and p.active
    group by p.id
  ) x);
end;
$$;

create or replace function public.erp_x_update_checklist(p_task_id uuid,p_item_code text,p_completed boolean,p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_task erp_supply.order_tasks%rowtype;v_item erp_supply.task_checklist%rowtype;
begin
  select * into v_task from erp_supply.order_tasks where id=p_task_id;
  if not found or not erp_supply.can_view_order(v_task.order_id) then raise exception 'Tarea no disponible' using errcode='42501'; end if;
  if not (erp_supply.actor_can(v_actor,v_task.step_code,'START',v_task.assigned_profile_id) or erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'No autorizado para actualizar esta lista' using errcode='42501';
  end if;
  update erp_supply.task_checklist set completed=p_completed,completed_by=case when p_completed then v_actor else null end,
    completed_at=case when p_completed then now() else null end,note=nullif(trim(p_note),'')
  where task_id=p_task_id and item_code=p_item_code returning * into v_item;
  if not found then raise exception 'Control de lista no encontrado'; end if;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  select o.organization_id,o.id,v_task.id,'CHECKLIST_UPDATED','CHECKLIST',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('itemCode',p_item_code,'completed',p_completed,'note',p_note)
  from erp_supply.orders o where o.id=v_task.order_id;
  return jsonb_build_object('success',true,'item',to_jsonb(v_item));
end;
$$;

create or replace function public.erp_x_save_financial_validation(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_row erp_supply.financial_validations%rowtype;v_type text:=upper(p_payload->>'validationType');
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_type not in('CARTERA','CAJA') or v_order.current_step_code<>v_type then raise exception 'La validación no corresponde a la etapa actual'; end if;
  if not (erp_supply.can_access_module(lower(v_type),'update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
  insert into erp_supply.financial_validations(order_id,validation_type,decision,amount,reference,notes,evidence_file_id,created_by,metadata)
  values(p_order_id,v_type,upper(coalesce(p_payload->>'decision','APPROVED')),nullif(p_payload->>'amount','')::numeric,p_payload->>'reference',coalesce(nullif(trim(p_payload->>'notes'),''),'Validación registrada'),nullif(p_payload->>'evidenceFileId','')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_row;
  return jsonb_build_object('success',true,'validation',to_jsonb(v_row));
end;
$$;

create or replace function public.erp_x_save_purchase_order(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_po erp_supply.purchase_orders%rowtype;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'COMPRAS' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Compras'; end if;
  if not (erp_supply.can_access_module('purchasing','create') or erp_supply.can_access_module('purchasing','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
  insert into erp_supply.purchase_orders(order_id,po_number,supplier_name,status,total_amount,currency,expected_at,drive_file_id,created_by,metadata)
  values(p_order_id,p_payload->>'poNumber',p_payload->>'supplierName',upper(coalesce(p_payload->>'status','ISSUED')),nullif(p_payload->>'totalAmount','')::numeric,coalesce(p_payload->>'currency','COP'),nullif(p_payload->>'expectedAt','')::timestamptz,nullif(p_payload->>'driveFileRecordId','')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  on conflict(order_id,po_number) do update set supplier_name=excluded.supplier_name,status=excluded.status,total_amount=excluded.total_amount,currency=excluded.currency,expected_at=excluded.expected_at,drive_file_id=coalesce(excluded.drive_file_id,erp_supply.purchase_orders.drive_file_id),metadata=erp_supply.purchase_orders.metadata||excluded.metadata,updated_at=now()
  returning * into v_po;
  return jsonb_build_object('success',true,'purchaseOrder',to_jsonb(v_po));
end;
$$;

create or replace function public.erp_x_inventory_lots(p_item_id uuid default null,p_search text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('inventory','read') and not erp_supply.can_access_module('cutting','read') and not erp_supply.has_role('super_admin') then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.description,x.location,x.lot_number),'[]'::jsonb) from (
    select l.id,l.inventory_item_id "itemId",i.sku,i.reference,i.description,i.unit,l.lot_number "lotNumber",l.serial_number "serialNumber",l.location,l.quantity_available "available",l.quantity_reserved "reserved",l.quantity_blocked "blocked",l.expires_at "expiresAt"
    from erp_supply.inventory_lots l join erp_supply.inventory_items i on i.id=l.inventory_item_id
    where i.organization_id=v_org and i.active and l.quantity_available>0
      and (p_item_id is null or i.id=p_item_id)
      and (p_search is null or p_search='' or lower(i.sku||' '||i.description||' '||coalesce(i.reference,'')||' '||coalesce(l.lot_number,'')||' '||l.location) like '%'||lower(p_search)||'%')
  ) x);
end;
$$;

-- Harden the public action gateway: every mutation requires visible order and explicit action permission.
create or replace function public.erp_x_execute_action(p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,p_expected_version integer default null,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_action text:=upper(trim(coalesce(p_action_code,'')));v_type text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;
  if v_action='NO_DELIVERY' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then raise exception 'No autorizado para registrar no entrega' using errcode='42501'; end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then raise exception 'No autorizado para reprogramar' using errcode='42501'; end if;
  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(p_payload->>'requestType','')));
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then raise exception 'Tipo de solicitud inválido'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if v_type='PRIORITY' and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
    if v_type='ROUTE_CHANGE' and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then raise exception 'Ruta inválida'; end if;
  end if;
  return erp_supply.execute_action_internal(p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

-- Rich action catalog, including assignment and domain prerequisites.
create or replace function public.erp_x_get_actions(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_actions jsonb:='[]';v_domains jsonb:='[]';v_can_override boolean;v_latest_delivery text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1;
  select status into v_latest_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1;
  v_can_override:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('gerencia');
  if v_order.status not in('CLOSED','CANCELLED') then
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'CLAIM',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLAIM','label','Tomar tarea','kind','primary')); end if;
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'START',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','START','label','Iniciar trabajo','kind','primary','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'COMPLETE',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE','label','Finalizar etapa','kind','success','requires',jsonb_build_array('detail'))); end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','WAIT','label','Poner en espera','kind','warning','requires',jsonb_build_array('reason'))); end if;
    if v_task.status in('WAITING','BLOCKED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','RESUME','label','Reanudar','kind','primary')); end if;
    if erp_supply.actor_can(v_actor,v_order.current_step_code,'ASSIGN',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','ASSIGN','label','Asignar responsable','kind','secondary','requires',jsonb_build_array('profileId'))); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and v_task.status in('ASSIGNED','IN_PROGRESS') and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','NO_DELIVERY','label','Registrar no entrega','kind','danger','requires',jsonb_build_array('reason'))); end if;
    if v_task.status='WAITING' and v_latest_delivery='NOT_DELIVERED' and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REPROGRAM','label','Reprogramar entrega','kind','warning','requires',jsonb_build_array('scheduledAt'))); end if;
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMMENT','label','Agregar comentario','kind','secondary','requires',jsonb_build_array('body')));
    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REQUEST_APPROVAL','label','Solicitar aprobación','kind','secondary','requires',jsonb_build_array('requestType','reason')));

    if v_order.current_step_code in('CARTERA','CAJA') and (erp_supply.can_access_module(lower(v_order.current_step_code),'update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FINANCIAL','label','Registrar validación financiera')); end if;
    if v_order.current_step_code='COMPRAS' and (erp_supply.can_access_module('purchasing','create') or erp_supply.can_access_module('purchasing','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','PURCHASE','label','Registrar orden de compra')); end if;
    if v_order.current_step_code='RECEPCION_MERCANCIA' and (erp_supply.can_access_module('receiving','create') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','RECEIPT','label','Registrar recepción'),jsonb_build_object('code','STICKERS','label','Imprimir stickers')); end if;
    if v_order.current_step_code='CORTE' and (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CUT','label','Registrar corte')); end if;
    if v_order.current_step_code='FACTURACION' and (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','INVOICE','label','Registrar factura')); end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','DELIVERY','label','Registrar despacho o entrega')); end if;
    if exists(select 1 from erp_supply.task_checklist where task_id=v_task.id) then v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CHECKLIST','label','Lista de verificación')); end if;
    v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FILE','label','Subir evidencia'));
  end if;
  return jsonb_build_object('orderId',v_order.id,'version',v_order.version,'status',v_order.status,'currentStep',v_order.current_step_code,'taskId',v_task.id,'taskStatus',v_task.status,'canOverride',v_can_override,'actions',v_actions,'domainActions',v_domains);
end;
$$;

-- Rich detail, now including enterprise controls.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_order erp_supply.orders%rowtype;
begin
  erp_supply.require_profile();
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;
  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb) from erp_supply.order_items i where i.order_id=p_order_id),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

-- Secure optional UUID handling and order visibility for Drive metadata.
create or replace function public.erp_x_register_drive_file(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_file erp_supply.drive_files%rowtype;v_order_id uuid:=nullif(p_payload->>'orderId','')::uuid;v_task_id uuid:=nullif(p_payload->>'taskId','')::uuid;
begin
  if v_order_id is not null and not erp_supply.can_view_order(v_order_id) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if nullif(trim(p_payload->>'driveFileId'),'') is null or nullif(trim(p_payload->>'fileName'),'') is null then raise exception 'Identificador y nombre de archivo requeridos'; end if;
  insert into erp_supply.drive_files(organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,web_view_link,web_content_link,size_bytes,uploaded_by,metadata)
  values(v_org,v_order_id,v_task_id,coalesce(p_payload->>'category','EVIDENCE'),p_payload->>'driveFileId',p_payload->>'fileName',p_payload->>'mimeType',p_payload->>'webViewLink',p_payload->>'webContentLink',nullif(p_payload->>'sizeBytes','')::bigint,v_actor,coalesce(p_payload->'metadata','{}'::jsonb))
  returning * into v_file;
  return jsonb_build_object('success',true,'file',to_jsonb(v_file));
end;
$$;

-- Final RPC security surface.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig); end loop;
end $$;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('grant execute on function %s to authenticated',r.sig); end loop;
end $$;

commit;


-- ============================================================================
-- 009_domain_hardening.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 009: harden domain services and cross-organization access.

begin;

create or replace function public.erp_x_credit_list(p_status text default null,p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_profile uuid:=erp_supply.require_profile();v_roles text[]:=erp_supply.current_roles();v_total bigint;v_items jsonb;v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),200);v_all boolean;
begin
  if not erp_supply.can_access_module('credit','read') then raise exception 'No autorizado' using errcode='42501'; end if;
  v_all:=v_roles && array['super_admin','gerencia','cartera','auditoria']::text[];
  select count(*) into v_total from erp_supply.credit_requests c
  where c.organization_id=v_org and (v_all or c.requested_by=v_profile)
    and (p_status is null or p_status='' or c.status=upper(p_status))
    and (p_search is null or p_search='' or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select c.id,c.request_number "requestNumber",c.client_name "clientName",c.client_document "clientDocument",c.requested_amount "requestedAmount",c.requested_term_days "requestedTermDays",c.status,p.display_name "requestedBy",a.display_name "assignedTo",c.decision_reason "decisionReason",c.metadata,c.created_at "createdAt",c.updated_at "updatedAt"
    from erp_supply.credit_requests c join erp_supply.profiles p on p.id=c.requested_by left join erp_supply.profiles a on a.id=c.assigned_to
    where c.organization_id=v_org and (v_all or c.requested_by=v_profile)
      and (p_status is null or p_status='' or c.status=upper(p_status))
      and (p_search is null or p_search='' or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%')
    order by c.created_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end));
end;
$$;

create or replace function public.erp_x_credit_transition(p_request_id uuid,p_action text,p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_req erp_supply.credit_requests%rowtype;v_action text:=upper(trim(coalesce(p_action,'')));
begin
  select * into v_req from erp_supply.credit_requests where id=p_request_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Solicitud de crédito no encontrada'; end if;
  if v_action='TAKE' then
    if v_req.status not in('SUBMITTED','UNDER_REVIEW') then raise exception 'La solicitud no puede tomarse en su estado actual'; end if;
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests set status='UNDER_REVIEW',assigned_to=v_actor where id=v_req.id returning * into v_req;
  elsif v_action in('APPROVE','REJECT') then
    if v_req.status not in('SUBMITTED','UNDER_REVIEW') then raise exception 'La solicitud ya no admite decisión'; end if;
    if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests set status=case when v_action='APPROVE' then 'APPROVED' else 'REJECTED' end,assigned_to=coalesce(assigned_to,v_actor),decision_reason=trim(p_reason) where id=v_req.id returning * into v_req;
  elsif v_action='CANCEL' then
    if v_req.status in('APPROVED','REJECTED','CANCELLED') then raise exception 'La solicitud ya no puede cancelarse'; end if;
    if not (v_req.requested_by=v_actor or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests set status='CANCELLED',decision_reason=coalesce(nullif(trim(p_reason),''),'Cancelada por el solicitante') where id=v_req.id returning * into v_req;
  else raise exception 'Transición de crédito inválida';
  end if;
  return jsonb_build_object('success',true,'request',to_jsonb(v_req));
end;
$$;

create or replace function public.erp_x_save_receipt(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_receipt erp_supply.receipts%rowtype;v_line jsonb;v_inventory erp_supply.inventory_items%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_status text:=upper(coalesce(p_payload->>'status','CONFORMING'));v_received numeric;v_accepted numeric;v_rejected numeric;v_count integer:=0;
begin
  if not (erp_supply.can_access_module('receiving','create') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para recepción' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'RECEPCION_MERCANCIA' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Recepción de mercancía'; end if;
  if v_status not in('OPEN','PARTIAL','CONFORMING','NONCONFORMING','CLOSED') then raise exception 'Estado de recepción inválido'; end if;
  if jsonb_typeof(coalesce(p_payload->'lines','[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_payload->'lines','[]'::jsonb))=0 then raise exception 'Debe registrar al menos una línea recibida'; end if;
  insert into erp_supply.receipts(order_id,receipt_number,purchase_order,supplier_name,status,received_by,received_at,metadata)
  values(p_order_id,coalesce(nullif(trim(p_payload->>'receiptNumber'),''),'REC-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')),p_payload->>'purchaseOrder',p_payload->>'supplierName',v_status,v_actor,now(),coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_receipt;
  for v_line in select value from jsonb_array_elements(p_payload->'lines') loop
    v_count:=v_count+1;
    v_received:=nullif(v_line->>'receivedQuantity','')::numeric;
    v_accepted:=coalesce(nullif(v_line->>'acceptedQuantity','')::numeric,v_received);
    v_rejected:=coalesce(nullif(v_line->>'rejectedQuantity','')::numeric,0);
    if v_received is null or v_received<=0 then raise exception 'Cantidad recibida inválida en la línea %',v_count; end if;
    if v_accepted<0 or v_rejected<0 or v_accepted+v_rejected>v_received then raise exception 'Distribución aceptada/rechazada inválida en la línea %',v_count; end if;
    insert into erp_supply.receipt_lines(receipt_id,order_item_id,sku,description,expected_quantity,received_quantity,accepted_quantity,rejected_quantity,unit,location,quality_status,metadata)
    values(v_receipt.id,nullif(v_line->>'orderItemId','')::uuid,v_line->>'sku',coalesce(nullif(trim(v_line->>'description'),''),'Material recibido'),nullif(v_line->>'expectedQuantity','')::numeric,v_received,v_accepted,v_rejected,coalesce(nullif(v_line->>'unit',''),'UND'),coalesce(nullif(v_line->>'location',''),'RECEPCION'),upper(coalesce(v_line->>'qualityStatus','ACCEPTED')),coalesce(v_line->'metadata','{}'::jsonb)||jsonb_build_object('lotNumber',nullif(v_line->>'lotNumber','')));
    if v_accepted>0 then
      insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,barcode)
      values(v_order.organization_id,coalesce(nullif(v_line->>'sku',''),'SKU-'||substr(gen_random_uuid()::text,1,8)),v_line->>'reference',coalesce(nullif(trim(v_line->>'description'),''),'Material recibido'),coalesce(nullif(v_line->>'unit',''),'UND'),coalesce(nullif(v_line->>'itemType',''),'STANDARD'),nullif(v_line->>'barcode',''))
      on conflict(organization_id,sku) do update set description=excluded.description,reference=coalesce(excluded.reference,erp_supply.inventory_items.reference),unit=excluded.unit,updated_at=now()
      returning * into v_inventory;
      insert into erp_supply.inventory_lots(inventory_item_id,lot_number,serial_number,location,quantity_available,received_at,metadata)
      values(v_inventory.id,nullif(v_line->>'lotNumber',''),nullif(v_line->>'serialNumber',''),coalesce(nullif(v_line->>'location',''),'RECEPCION'),v_accepted,now(),jsonb_build_object('receiptId',v_receipt.id,'qualityStatus',upper(coalesce(v_line->>'qualityStatus','ACCEPTED')))) returning * into v_lot;
      insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,to_location,actor_profile_id,reference,metadata)
      values(v_order.organization_id,v_inventory.id,v_lot.id,p_order_id,'RECEIPT',v_accepted,v_inventory.unit,v_lot.location,v_actor,v_receipt.receipt_number,jsonb_build_object('receiptLine',v_count));
    end if;
  end loop;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','RECEIPT',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('receiptId',v_receipt.id,'status',v_status,'lines',v_count));
  return jsonb_build_object('success',true,'receipt',to_jsonb(v_receipt),'lines',v_count);
end;
$$;

create or replace function public.erp_x_stickers(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
begin
  erp_supply.require_profile();
  if not erp_supply.can_view_order(p_order_id) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
    'receiptNumber',r.receipt_number,'purchaseOrder',r.purchase_order,'supplier',r.supplier_name,'receivedAt',r.received_at,
    'sku',l.sku,'description',l.description,'quantity',l.accepted_quantity,'unit',l.unit,'location',l.location,'lotNumber',l.metadata->>'lotNumber','qualityStatus',l.quality_status
  ) order by r.created_at,l.description),'[]'::jsonb)
  from erp_supply.receipts r join erp_supply.receipt_lines l on l.receipt_id=r.id where r.order_id=p_order_id);
end;
$$;

create or replace function public.erp_x_inventory_adjust(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_item erp_supply.inventory_items%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_qty numeric;v_type text;v_order_id uuid:=nullif(p_payload->>'orderId','')::uuid;
begin
  if not erp_supply.can_access_module('inventory','update') then raise exception 'No autorizado para ajustar inventario' using errcode='42501'; end if;
  select * into v_item from erp_supply.inventory_items where id=nullif(p_payload->>'itemId','')::uuid and organization_id=v_org;
  if not found then raise exception 'Artículo no encontrado'; end if;
  select * into v_lot from erp_supply.inventory_lots where id=nullif(p_payload->>'lotId','')::uuid and inventory_item_id=v_item.id for update;
  if not found then raise exception 'Lote no encontrado'; end if;
  if v_order_id is not null and not erp_supply.can_view_order(v_order_id) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  v_qty:=nullif(p_payload->>'quantity','')::numeric;v_type:=upper(trim(coalesce(p_payload->>'movementType','')));
  if v_qty is null or v_qty<=0 then raise exception 'Cantidad inválida'; end if;
  if v_type not in('RECEIPT','RETURN','TRANSFER_IN','TRANSFER_OUT','ISSUE','ADJUSTMENT_IN','ADJUSTMENT_OUT','SCRAP') then raise exception 'Tipo de movimiento inválido'; end if;
  if v_type in('ISSUE','ADJUSTMENT_OUT','SCRAP','TRANSFER_OUT') then
    if v_lot.quantity_available<v_qty then raise exception 'Existencia insuficiente'; end if;
    update erp_supply.inventory_lots set quantity_available=quantity_available-v_qty where id=v_lot.id returning * into v_lot;
  else
    update erp_supply.inventory_lots set quantity_available=quantity_available+v_qty where id=v_lot.id returning * into v_lot;
  end if;
  insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata)
  values(v_org,v_item.id,v_lot.id,v_order_id,v_type,v_qty,v_item.unit,p_payload->>'fromLocation',p_payload->>'toLocation',v_actor,p_payload->>'reference',coalesce(p_payload->'metadata','{}'::jsonb));
  return jsonb_build_object('success',true,'lot',to_jsonb(v_lot));
end;
$$;

create or replace function public.erp_x_save_cut_job(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_job erp_supply.cut_jobs%rowtype;v_lot erp_supply.inventory_lots%rowtype;v_item erp_supply.inventory_items%rowtype;v_actual numeric;v_requested numeric;v_scrap numeric;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para registrar corte' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'CORTE' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Corte'; end if;
  v_requested:=nullif(p_payload->>'requestedLength','')::numeric;v_actual:=nullif(p_payload->>'actualLength','')::numeric;v_scrap:=coalesce(nullif(p_payload->>'scrapLength','')::numeric,0);
  if v_requested is null or v_requested<=0 or v_actual is null or v_actual<=0 or v_scrap<0 then raise exception 'Medidas de corte inválidas'; end if;
  select l.* into v_lot from erp_supply.inventory_lots l join erp_supply.inventory_items i on i.id=l.inventory_item_id where l.id=nullif(p_payload->>'inventoryLotId','')::uuid and i.organization_id=v_order.organization_id for update of l;
  if not found then raise exception 'Chipa o lote no encontrado'; end if;
  select * into v_item from erp_supply.inventory_items where id=v_lot.inventory_item_id;
  if v_lot.quantity_available < v_actual+v_scrap then raise exception 'Longitud disponible insuficiente'; end if;
  if nullif(p_payload->>'orderItemId','') is not null and not exists(select 1 from erp_supply.order_items where id=(p_payload->>'orderItemId')::uuid and order_id=p_order_id) then raise exception 'Ítem de pedido inválido'; end if;
  insert into erp_supply.cut_jobs(order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,status,assigned_profile_id,started_at,completed_at,metadata)
  values(p_order_id,nullif(p_payload->>'orderItemId','')::uuid,v_lot.id,v_requested,v_actual,v_scrap,'COMPLETED',v_actor,coalesce(nullif(p_payload->>'startedAt','')::timestamptz,now()),now(),coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_job;
  update erp_supply.inventory_lots set quantity_available=quantity_available-v_actual-v_scrap where id=v_lot.id;
  insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,actor_profile_id,reference,metadata)
  values(v_order.organization_id,v_item.id,v_lot.id,p_order_id,'CUT_CONSUMPTION',v_actual+v_scrap,v_item.unit,v_lot.location,v_actor,v_job.id::text,jsonb_build_object('requestedLength',v_requested,'actualLength',v_actual,'scrapLength',v_scrap));
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','CUT',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('cutJobId',v_job.id,'actualLength',v_actual,'scrapLength',v_scrap));
  return jsonb_build_object('success',true,'cutJob',to_jsonb(v_job));
end;
$$;

create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_invoice erp_supply.invoices%rowtype;
begin
  if not (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para facturar' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'FACTURACION' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Facturación'; end if;
  if nullif(trim(p_payload->>'invoiceNumber'),'') is null then raise exception 'Número de factura requerido'; end if;
  insert into erp_supply.invoices(order_id,invoice_number,invoice_date,amount,currency,status,drive_file_id,registered_by,metadata)
  values(p_order_id,trim(p_payload->>'invoiceNumber'),coalesce(nullif(p_payload->>'invoiceDate','')::date,current_date),nullif(p_payload->>'amount','')::numeric,coalesce(nullif(p_payload->>'currency',''),'COP'),'REGISTERED',nullif(p_payload->>'driveFileRecordId','')::uuid,v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_invoice;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','INVOICE',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('invoiceId',v_invoice.id,'invoiceNumber',v_invoice.invoice_number));
  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

create or replace function public.erp_x_save_delivery(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();v_order erp_supply.orders%rowtype;v_delivery erp_supply.deliveries%rowtype;v_status text:=upper(coalesce(p_payload->>'status','PLANNED'));
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para despacho' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en una etapa de entrega'; end if;
  if v_status not in('PLANNED','DISPATCHED','IN_TRANSIT','DELIVERED','NOT_DELIVERED','REPROGRAMMED','CANCELLED') then raise exception 'Estado de entrega inválido'; end if;
  if v_status='DELIVERED' and nullif(trim(p_payload->>'receivedBy'),'') is null then raise exception 'Debe registrar quién recibió'; end if;
  if v_status='NOT_DELIVERED' and nullif(trim(p_payload->>'noDeliveryReason'),'') is null then raise exception 'Debe registrar el motivo de no entrega'; end if;
  insert into erp_supply.deliveries(order_id,route_code,status,scheduled_at,dispatched_at,delivered_at,received_by,no_delivery_reason,carrier,tracking_number,assigned_profile_id,metadata)
  values(p_order_id,v_order.delivery_route_code,v_status,nullif(p_payload->>'scheduledAt','')::timestamptz,nullif(p_payload->>'dispatchedAt','')::timestamptz,case when v_status='DELIVERED' then coalesce(nullif(p_payload->>'deliveredAt','')::timestamptz,now()) else nullif(p_payload->>'deliveredAt','')::timestamptz end,p_payload->>'receivedBy',p_payload->>'noDeliveryReason',p_payload->>'carrier',p_payload->>'trackingNumber',v_actor,coalesce(p_payload->'metadata','{}'::jsonb)) returning * into v_delivery;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','DELIVERY',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('deliveryId',v_delivery.id,'status',v_status,'trackingNumber',v_delivery.tracking_number));
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery));
end;
$$;

-- Final security reconciliation for every native API function.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;


-- ============================================================================
-- 010_identity_and_routing_bootstrap.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 010: reuse Supabase Auth identities and established logistics routing without importing legacy orders.

begin;

-- Import only identity and role configuration from the previous public.profiles table when it exists.
do $$
begin
  if to_regclass('public.profiles') is not null
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='auth_user_id')
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='role_code')
  then
    execute $q$
      insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active,preferences)
      select o.id,lp.auth_user_id,lower(lp.email),coalesce(nullif(lp.display_name,''),split_part(lp.email,'@',1)),null,
             coalesce(lp.active,true),jsonb_build_object('legacyProfileImported',true)
      from public.profiles lp cross join erp_supply.organizations o
      where o.code='EI' and lp.email is not null
      on conflict(organization_id,email) do update set
        auth_user_id=coalesce(excluded.auth_user_id,erp_supply.profiles.auth_user_id),
        display_name=excluded.display_name,
        active=excluded.active,
        preferences=erp_supply.profiles.preferences||excluded.preferences
    $q$;

    execute $q$
      insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
      select ep.id,lp.role_code,true
      from public.profiles lp
      join erp_supply.profiles ep on lower(ep.email)=lower(lp.email)
      join erp_supply.roles r on r.code=lp.role_code
      where lp.role_code is not null
      on conflict(profile_id,role_code) do update set is_primary=true
    $q$;
  end if;
end $$;

-- Every Supabase Auth account is visible to the administrator even if it had no legacy profile.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active,preferences)
select o.id,u.id,lower(u.email),coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(u.email,'@',1)),false,jsonb_build_object('createdFromAuth',true)
from auth.users u cross join erp_supply.organizations o
where o.code='EI' and u.email is not null
on conflict(organization_id,email) do update set auth_user_id=coalesce(erp_supply.profiles.auth_user_id,excluded.auth_user_id);

-- Explicit bootstrap for the designated Super Admin. This is idempotent and only
-- activates the exact corporate account already present in Supabase Auth.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active,preferences)
select o.id,u.id,lower(u.email),coalesce(nullif(u.raw_user_meta_data->>'full_name',''),'Juan Esteban Pérez'),true,
       jsonb_build_object('bootstrapSuperAdmin',true)
from auth.users u cross join erp_supply.organizations o
where o.code='EI' and lower(u.email)='j.perez@ei.com.co'
on conflict(organization_id,email) do update set
  auth_user_id=excluded.auth_user_id,
  display_name=coalesce(nullif(erp_supply.profiles.display_name,''),excluded.display_name),
  active=true,
  preferences=erp_supply.profiles.preferences||excluded.preferences;

insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
select p.id,'super_admin',true
from erp_supply.profiles p
where lower(p.email)='j.perez@ei.com.co'
on conflict(profile_id,role_code) do update set is_primary=true;

-- Established local/national route ownership.
insert into erp_supply.routing_rules(organization_id,step_code,route_code,assigned_role_code,assigned_profile_id,priority,metadata)
select o.id,x.step_code,x.route_code,x.role_code,p.id,x.priority,jsonb_build_object('source','established-routing')
from erp_supply.organizations o
join (values
  ('FACTURACION','CLIENT_POINT','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','CLIENT_PICKUP','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','LOCAL_DISPATCH','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','NATIONAL_DISPATCH','despacho_nacional','j.laverde@ei.com.co',10),
  ('CLIENT_POINT','CLIENT_POINT','coordinador_logistico','d.diaz@ei.com.co',10),
  ('CLIENT_PICKUP','CLIENT_PICKUP','coordinador_logistico','d.diaz@ei.com.co',10),
  ('LOCAL_DISPATCH','LOCAL_DISPATCH','coordinador_logistico','d.diaz@ei.com.co',10),
  ('NATIONAL_DISPATCH','NATIONAL_DISPATCH','despacho_nacional','j.laverde@ei.com.co',10)
) x(step_code,route_code,role_code,email,priority) on true
left join erp_supply.profiles p on p.organization_id=o.id and lower(p.email)=x.email
where o.code='EI'
  and not exists(
    select 1 from erp_supply.routing_rules rr
    where rr.organization_id=o.id and rr.step_code=x.step_code and rr.route_code=x.route_code
      and rr.order_type_code is null and rr.assigned_role_code=x.role_code
  );

commit;


-- ============================================================================
-- 011_engine_hardening.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 011: transactional engine hardening and precise workflow audit.

begin;

create or replace function erp_supply.execute_action_internal(
  p_order_id uuid,
  p_action text,
  p_payload jsonb,
  p_actor uuid,
  p_bypass_permissions boolean default false,
  p_expected_version integer default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_action text := upper(trim(coalesce(p_action,'')));
  v_next text;
  v_new_task erp_supply.order_tasks%rowtype;
  v_target uuid;
  v_session erp_supply.task_sessions%rowtype;
  v_now timestamptz := now();
  v_business bigint := 0;
  v_event_id bigint;
  v_actor_role text;
  v_from_step text;
  v_from_status text;
  v_scheduled_at timestamptz;
begin
  if v_action='' then raise exception 'Acción requerida'; end if;
  if p_actor is null then raise exception 'Actor requerido' using errcode='42501'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  v_from_step:=v_order.current_step_code;
  v_from_status:=v_order.status;

  if p_expected_version is not null and v_order.version<>p_expected_version then
    raise exception 'El pedido cambió mientras estaba abierto. Actualice la pantalla.' using errcode='40001';
  end if;
  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_order.organization_id and idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  select pr.role_code into v_actor_role from erp_supply.profile_roles pr
  where pr.profile_id=p_actor order by pr.is_primary desc,pr.role_code limit 1;

  if v_action not in ('COMMENT','REQUEST_APPROVAL') and v_task.id is null and v_order.status not in ('CLOSED','CANCELLED') then
    raise exception 'El pedido no tiene una tarea operativa activa';
  end if;

  if not p_bypass_permissions then
    if v_action in ('CLAIM','ASSIGN','START','COMPLETE','WAIT','BLOCK','RESUME')
       and not erp_supply.actor_can(p_actor,v_order.current_step_code,v_action,v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para ejecutar % en %',v_action,v_order.current_step_code using errcode='42501';
    end if;
    if v_action='NO_DELIVERY' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para registrar no entrega' using errcode='42501';
    end if;
    if v_action='REPROGRAM' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para reprogramar la entrega' using errcode='42501';
    end if;
  end if;

  if v_action='CLAIM' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede reclamarse en su estado actual'; end if;
    if v_task.assigned_profile_id is not null and v_task.assigned_profile_id<>p_actor and not p_bypass_permissions
       and not exists(select 1 from erp_supply.profile_roles pr join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_task.step_code where pr.profile_id=p_actor and sr.can_override) then
      raise exception 'La tarea ya está asignada a otro responsable';
    end if;
    update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=coalesce(assigned_at,v_now),status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=p_actor,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='ASSIGN' then
    begin v_target := nullif(p_payload->>'profileId','')::uuid; exception when others then raise exception 'profileId inválido'; end;
    if v_target is null then raise exception 'Debe seleccionar un responsable'; end if;
    if not exists(
      select 1 from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_order.current_step_code and sr.can_view
      where p.id=v_target and p.organization_id=v_order.organization_id and p.active
    ) then raise exception 'El responsable no está habilitado para la etapa %',v_order.current_step_code; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'No puede reasignar una tarea con sesión de trabajo activa'; end if;
    update erp_supply.order_tasks set assigned_profile_id=v_target,assigned_at=v_now,status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=v_target,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='START' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede iniciarse en su estado actual'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión de trabajo activa'; end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then
      raise exception 'El usuario ya tiene otra sesión de trabajo activa';
    end if;
    if v_task.assigned_profile_id is null then
      update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=v_now where id=v_task.id;
    end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action in ('WAIT','BLOCK') then
    if v_task.status<>'IN_PROGRESS' then raise exception 'Solo una tarea en proceso puede ponerse en espera o bloqueo'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,
      blocked_at=case when v_action='BLOCK' then v_now else blocked_at end,
      result_detail=coalesce(nullif(p_payload->>'reason',''),nullif(p_payload->>'detail',''),result_detail)
    where id=v_task.id returning * into v_task;
    update erp_supply.orders set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='RESUME' then
    if v_task.status not in ('WAITING','BLOCKED') then raise exception 'La tarea no está en espera o bloqueo'; end if;
    if exists(select 1 from erp_supply.task_sessions where profile_id=p_actor and ended_at is null and task_id<>v_task.id) then raise exception 'El usuario ya tiene otra sesión de trabajo activa'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión activa'; end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note) values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMPLETE' then
    if not p_bypass_permissions and v_task.status<>'IN_PROGRESS' then raise exception 'Debe iniciar la tarea antes de finalizarla'; end if;
    if not p_bypass_permissions and not exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea no tiene una sesión activa para finalizar'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    select coalesce(sum(business_seconds),0) into v_business from erp_supply.task_sessions where task_id=v_task.id;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-coalesce(started_at,created_at)))::bigint),
      business_seconds=v_business,result_code=coalesce(nullif(p_payload->>'resultCode',''),'COMPLETED'),result_detail=p_payload->>'detail',metadata=metadata||coalesce(p_payload,'{}'::jsonb)
    where id=v_task.id returning * into v_task;

    v_next:=erp_supply.next_step(v_order.current_step_code,v_order.order_type_code,v_order.payment_condition_code,v_order.delivery_route_code,v_order.requires_cut,v_order.requires_purchase);
    if v_next='CLOSED' then
      update erp_supply.orders set current_step_code='CLOSED',status='CLOSED',closed_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
    else
      select * into v_new_task from erp_supply.create_task(v_order,v_next,v_task.sequence_no+1);
      select * into v_order from erp_supply.orders where id=v_order.id;
    end if;

  elsif v_action='NO_DELIVERY' then
    if v_order.current_step_code not in ('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'La no entrega solo aplica en despacho o entrega'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo de no entrega'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    insert into erp_supply.deliveries(order_id,route_code,status,no_delivery_reason,assigned_profile_id,metadata)
    values(v_order.id,v_order.delivery_route_code,'NOT_DELIVERED',trim(p_payload->>'reason'),p_actor,p_payload);
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=trim(p_payload->>'reason') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='WAITING',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='REPROGRAM' then
    begin v_scheduled_at:=nullif(p_payload->>'scheduledAt','')::timestamptz; exception when others then raise exception 'Fecha de reprogramación inválida'; end;
    if v_scheduled_at is null or v_scheduled_at<=v_now then raise exception 'La nueva fecha debe ser futura'; end if;
    if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED') then raise exception 'No existe una no entrega pendiente de reprogramación'; end if;
    update erp_supply.deliveries set status='REPROGRAMMED',scheduled_at=v_scheduled_at,metadata=metadata||p_payload,updated_at=v_now
    where id=(select id from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED' order by created_at desc limit 1);
    update erp_supply.order_tasks set status='ASSIGNED',result_detail=coalesce(nullif(p_payload->>'detail',''),'Entrega reprogramada') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMMENT' then
    if nullif(trim(p_payload->>'body'),'') is null then raise exception 'Debe escribir el comentario'; end if;
    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_order.id,p_actor,upper(coalesce(nullif(p_payload->>'commentType',''),'GENERAL')),upper(coalesce(nullif(p_payload->>'visibility',''),'ORDER')),trim(p_payload->>'body'),coalesce(p_payload->'metadata','{}'::jsonb));

  elsif v_action='REQUEST_APPROVAL' then
    insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
    values(v_order.organization_id,v_order.id,upper(p_payload->>'requestType'),p_actor,coalesce(nullif(p_payload->>'assignedRole',''),'jefe_logistica'),trim(p_payload->>'reason'),p_payload);

  else
    raise exception 'Acción no reconocida: %',v_action;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_order.organization_id,v_order.id,coalesce(v_task.id,v_new_task.id),'WORKFLOW_ACTION',v_action,
    v_from_step,v_order.current_step_code,v_from_status,v_order.status,p_actor,v_actor_role,p_idempotency_key,coalesce(p_payload,'{}'::jsonb))
  returning id into v_event_id;

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_order.organization_id,p_actor,v_action,'ORDER',v_order.id::text,
    jsonb_build_object('step',v_from_step,'status',v_from_status,'version',coalesce(p_expected_version,v_order.version-1)),
    jsonb_build_object('step',v_order.current_step_code,'status',v_order.status,'version',v_order.version),
    jsonb_build_object('eventId',v_event_id,'idempotencyKey',p_idempotency_key));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_order.organization_id,'ORDER_ACTION','ORDER',v_order.id,jsonb_build_object('eventId',v_event_id,'action',v_action,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'eventId',v_event_id);
end;
$$;

-- Correct VSM numeric handling and distinguish productive time from elapsed time.
create or replace function public.erp_x_vsm(p_date_from date default current_date-30,p_date_to date default current_date)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Rango de fechas inválido'; end if;
  return jsonb_build_object(
    'steps',(select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order),'[]'::jsonb) from (
      select s.code,s.name,s.sort_order,count(o.id) tasks,
        round((avg(t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "avgBusinessHours",
        round((avg(t.raw_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "avgElapsedHours",
        round((percentile_cont(.5) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "medianBusinessHours",
        round((percentile_cont(.9) within group(order by t.business_seconds) filter(where o.id is not null)/3600.0)::numeric,2) "p90BusinessHours",
        round((avg(greatest(0,t.raw_seconds-t.business_seconds)) filter(where o.id is not null)/3600.0)::numeric,2) "avgWaitHours"
      from erp_supply.workflow_steps s
      left join erp_supply.order_tasks t on t.step_code=s.code and t.completed_at::date between p_date_from and p_date_to
      left join erp_supply.orders o on o.id=t.order_id and o.organization_id=v_org and not o.is_test
      group by s.code,s.name,s.sort_order
    ) x),
    'throughput',(select coalesce(jsonb_agg(to_jsonb(x) order by x.day),'[]'::jsonb) from (
      select d::date day,count(o.id) filter(where o.created_at::date=d::date) created,count(o.id) filter(where o.closed_at::date=d::date) closed
      from generate_series(p_date_from,p_date_to,'1 day') d
      left join erp_supply.orders o on o.organization_id=v_org and not o.is_test and (o.created_at::date=d::date or o.closed_at::date=d::date)
      group by d
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Keep only authenticated access to native APIs.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;


-- ============================================================================
-- 012_enterprise_health_and_release_gate.sql
-- ============================================================================
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


-- ============================================================================
-- 013_history_import_hardening.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 013: robust, resumable and auditable historical CSV import.

begin;

create or replace function erp_supply.try_boolean(p_value text,p_default boolean default false)
returns boolean
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value)='' then return p_default; end if;
  case lower(btrim(p_value))
    when '1' then return true; when 'true' then return true; when 't' then return true;
    when 'yes' then return true; when 'si' then return true; when 'sí' then return true; when 'x' then return true;
    when '0' then return false; when 'false' then return false; when 'f' then return false;
    when 'no' then return false;
    else return p_default;
  end case;
end;
$$;

create or replace function erp_supply.try_timestamptz(p_value text,p_default timestamptz default null)
returns timestamptz
language plpgsql
stable
as $$
begin
  if p_value is null or btrim(p_value)='' then return p_default; end if;
  return p_value::timestamptz;
exception when others then
  return p_default;
end;
$$;

create or replace function public.erp_x_import_history(p_file_name text,p_rows jsonb,p_batch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_batch erp_supply.import_batches%rowtype;
  v_row jsonb;
  v_n integer:=0;
  v_ok integer:=0;
  v_bad integer:=0;
  v_status text;
  v_step text;
  v_type text;
  v_payment text;
  v_route text;
  v_priority text;
  v_created timestamptz;
  v_updated timestamptz;
  v_closed timestamptz;
  v_cancelled timestamptz;
begin
  if not erp_supply.can_access_module('imports','create') then
    raise exception 'No autorizado para importar históricos' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_rows,'null'::jsonb))<>'array' then raise exception 'p_rows debe ser un arreglo JSON'; end if;
  if jsonb_array_length(p_rows)=0 then raise exception 'El lote no contiene filas'; end if;
  if jsonb_array_length(p_rows)>500 then raise exception 'Máximo 500 filas por lote'; end if;
  if nullif(btrim(p_file_name),'') is null then raise exception 'Nombre de archivo requerido'; end if;

  if p_batch_id is null then
    insert into erp_supply.import_batches(organization_id,import_type,file_name,imported_by,total_rows,status)
    values(v_org,'ORDER_HISTORY',btrim(p_file_name),v_actor,jsonb_array_length(p_rows),'PROCESSING')
    returning * into v_batch;
  else
    select * into v_batch from erp_supply.import_batches
    where id=p_batch_id and organization_id=v_org and import_type='ORDER_HISTORY'
    for update;
    if not found then raise exception 'Lote de importación no encontrado'; end if;
    update erp_supply.import_batches
    set total_rows=total_rows+jsonb_array_length(p_rows),status='PROCESSING',completed_at=null
    where id=v_batch.id returning * into v_batch;
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_n:=v_n+1;
    begin
      if nullif(btrim(v_row->>'orderNumber'),'') is null then raise exception 'Número de pedido requerido'; end if;
      if nullif(btrim(v_row->>'clientName'),'') is null then raise exception 'Cliente requerido'; end if;

      v_type:=upper(coalesce(nullif(btrim(v_row->>'orderType'),''),'PVC'));
      v_payment:=upper(coalesce(nullif(btrim(v_row->>'paymentCondition'),''),'CREDIT'));
      v_route:=upper(coalesce(nullif(btrim(v_row->>'deliveryRoute'),''),'LOCAL_DISPATCH'));
      v_priority:=upper(coalesce(nullif(btrim(v_row->>'priority'),''),'MEDIUM'));
      v_status:=upper(coalesce(nullif(btrim(v_row->>'status'),''),'CLOSED'));

      if not exists(select 1 from erp_supply.order_types where code=v_type and active) then raise exception 'Tipo de pedido inválido: %',v_type; end if;
      if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago inválida: %',v_payment; end if;
      if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta inválida: %',v_route; end if;
      if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida: %',v_priority; end if;
      if v_status not in('CLOSED','CANCELLED') then v_status:='CLOSED'; end if;
      v_step:=case when v_status='CLOSED' then 'CLOSED' else coalesce(nullif(upper(v_row->>'currentStep'),''),'CLOSED') end;
      if not exists(select 1 from erp_supply.workflow_steps where code=v_step) then v_step:='CLOSED'; end if;

      v_created:=erp_supply.try_timestamptz(v_row->>'createdAt',now());
      v_updated:=erp_supply.try_timestamptz(v_row->>'updatedAt',v_created);
      v_closed:=case when v_status='CLOSED' then erp_supply.try_timestamptz(v_row->>'closedAt',v_updated) end;
      v_cancelled:=case when v_status='CANCELLED' then erp_supply.try_timestamptz(v_row->>'cancelledAt',v_updated) end;

      insert into erp_supply.orders(
        organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
        client_name,client_document,client_city,current_step_code,status,priority,requires_cut,requires_purchase,
        source,is_history,metadata,created_at,updated_at,closed_at,cancelled_at
      ) values(
        v_org,btrim(v_row->>'orderNumber'),nullif(btrim(v_row->>'externalReference'),''),v_type,v_payment,v_route,
        btrim(v_row->>'clientName'),nullif(btrim(v_row->>'clientDocument'),''),nullif(btrim(v_row->>'clientCity'),''),
        v_step,v_status,v_priority,erp_supply.try_boolean(v_row->>'requiresCut',false),
        erp_supply.try_boolean(v_row->>'requiresPurchase',v_type='PVE'),'CSV_HISTORY',true,v_row,
        v_created,v_updated,v_closed,v_cancelled
      )
      on conflict(organization_id,order_number) do update set
        external_reference=coalesce(excluded.external_reference,erp_supply.orders.external_reference),
        order_type_code=excluded.order_type_code,payment_condition_code=excluded.payment_condition_code,
        delivery_route_code=excluded.delivery_route_code,client_name=excluded.client_name,
        client_document=coalesce(excluded.client_document,erp_supply.orders.client_document),
        client_city=coalesce(excluded.client_city,erp_supply.orders.client_city),current_step_code=excluded.current_step_code,
        status=excluded.status,priority=excluded.priority,requires_cut=excluded.requires_cut,
        requires_purchase=excluded.requires_purchase,source='CSV_HISTORY',is_history=true,
        metadata=erp_supply.orders.metadata||excluded.metadata,updated_at=greatest(erp_supply.orders.updated_at,excluded.updated_at),
        closed_at=coalesce(excluded.closed_at,erp_supply.orders.closed_at),
        cancelled_at=coalesce(excluded.cancelled_at,erp_supply.orders.cancelled_at);
      v_ok:=v_ok+1;
    exception when others then
      v_bad:=v_bad+1;
      insert into erp_supply.import_errors(batch_id,row_number,error_code,error_message,raw_row)
      values(v_batch.id,v_batch.inserted_rows+v_batch.rejected_rows+v_n,sqlstate,sqlerrm,v_row);
    end;
  end loop;

  update erp_supply.import_batches
  set inserted_rows=inserted_rows+v_ok,rejected_rows=rejected_rows+v_bad,
      status=case when rejected_rows+v_bad=0 then 'COMPLETED' when inserted_rows+v_ok=0 then 'FAILED' else 'PARTIAL' end,
      completed_at=now(),summary=summary||jsonb_build_object('lastChunkRows',v_n,'lastChunkInserted',v_ok,'lastChunkRejected',v_bad,'updatedAt',now())
  where id=v_batch.id returning * into v_batch;

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,after_data,metadata)
  values(v_org,v_actor,'IMPORT_HISTORY_CHUNK','IMPORT_BATCH',v_batch.id::text,
    jsonb_build_object('processed',v_n,'inserted',v_ok,'rejected',v_bad,'status',v_batch.status),jsonb_build_object('fileName',p_file_name));

  return jsonb_build_object('success',v_bad=0,'batchId',v_batch.id,'processed',v_n,'inserted',v_ok,'rejected',v_bad,
    'status',v_batch.status,'totals',jsonb_build_object('rows',v_batch.total_rows,'inserted',v_batch.inserted_rows,'rejected',v_batch.rejected_rows));
end;
$$;

revoke all on function public.erp_x_import_history(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.erp_x_import_history(text,jsonb,uuid) to authenticated;

commit;


-- ============================================================================
-- 014_qa_control_suite.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 014: cross-cutting QA suite for concurrency, gates, approvals, history and inventory.

begin;

create or replace function erp_supply.qa_make_order(
  p_run_id uuid,p_actor uuid,p_key text,p_step text,p_is_test boolean default true,
  p_route text default 'LOCAL_DISPATCH',p_requires_cut boolean default false
)
returns uuid
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare v_org uuid;v_order erp_supply.orders%rowtype;
begin
  select organization_id into v_org from erp_supply.profiles where id=p_actor;
  insert into erp_supply.orders(
    organization_id,order_number,order_type_code,payment_condition_code,delivery_route_code,client_name,
    seller_profile_id,current_step_code,status,requires_cut,requires_purchase,source,is_test,qa_run_id,metadata
  ) values(
    v_org,'QAC-'||substr(replace(p_run_id::text,'-',''),1,10)||'-'||p_key,'PVC','CREDIT',p_route,'Cliente control '||p_key,
    p_actor,p_step,'QUEUED',p_requires_cut,false,'QA_BOT',p_is_test,p_run_id,jsonb_build_object('controlScenario',p_key)
  ) returning * into v_order;
  insert into erp_supply.order_items(order_id,line_number,sku,description,quantity,unit,requires_cut,requested_cut_length)
  values(v_order.id,1,'QAC-'||p_key,'Material control automatizado',10,'UND',p_requires_cut,case when p_requires_cut then 5 else null end);
  perform erp_supply.create_task(v_order,p_step,1);
  return v_order.id;
end;
$$;

create or replace function erp_supply.qa_record(
  p_run_id uuid,p_key text,p_input jsonb,p_expected jsonb,p_actual jsonb,p_ok boolean,p_error text default null,p_order_id uuid default null
)
returns void
language sql
security definer
set search_path=erp_supply,public
as $$
  insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,order_id,input,expected_path,actual_path,status,error_message,completed_at)
  values(p_run_id,p_key,p_order_id,coalesce(p_input,'{}'::jsonb),coalesce(p_expected,'[]'::jsonb),coalesce(p_actual,'[]'::jsonb),
    case when p_ok then 'PASSED' else 'FAILED' end,p_error,now())
$$;

create or replace function public.erp_x_run_qa_control_suite(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
  v_order_id uuid;v_order2_id uuid;v_task uuid;v_version integer;v_result jsonb;v_result2 jsonb;
  v_ok boolean;v_error text;v_passed integer:=0;v_failed integer:=0;v_total integer:=0;
  v_req uuid;v_hist_number text;v_item uuid;v_lot uuid;v_available numeric;
  v_key text;
begin
  if not erp_supply.has_role('super_admin') then raise exception 'La suite integral solo puede ser ejecutada por Super Admin' using errcode='42501'; end if;
  insert into erp_supply.qa_runs(organization_id,run_type,requested_by,total_scenarios,summary)
  values(v_org,'CONTROL_SUITE',v_actor,10,jsonb_build_object('suite','enterprise-controls')) returning * into v_run;

  -- 1. Idempotencia por doble envío.
  v_total:=v_total+1;v_key:='CTRL-01-IDEMPOTENCY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'IDEMPOTENCY','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    v_result:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"inicio"}',v_actor,true,v_version,v_key);
    v_result2:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"reintento"}',v_actor,true,null,v_key);
    v_ok:=coalesce((v_result2->>'idempotent')::boolean,false) and (select count(*)=1 from erp_supply.order_events where idempotency_key=v_key);
    if not v_ok then v_error:='La acción duplicada creó más de un evento o no fue reconocida como idempotente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('ONE_EVENT','IDEMPOTENT_RESPONSE'),jsonb_build_array(v_result,v_result2),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 2. Conflicto de versión optimista.
  v_total:=v_total+1;v_key:='CTRL-02-OPTIMISTIC-VERSION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'VERSION','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,v_version,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"stale"}',v_actor,true,v_version,v_key||'-WAIT');
      v_error:='No se bloqueó la versión desactualizada';
    exception when sqlstate '40001' then v_ok:=true;
    end;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('SQLSTATE_40001'),jsonb_build_array(case when v_ok then 'BLOCKED' else 'NOT_BLOCKED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 3. Una sola sesión activa por operario.
  v_total:=v_total+1;v_key:='CTRL-03-SINGLE-OPERATOR-SESSION';v_ok:=false;v_error:=null;v_order_id:=null;v_order2_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-A','RECEPCION_PEDIDO',true);
    v_order2_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-B','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-A');
    begin
      perform erp_supply.execute_action_internal(v_order2_id,'START','{}',v_actor,true,null,v_key||'-B');
      v_error:='Se permitieron dos sesiones simultáneas';
    exception when others then
      v_ok:=position('otra sesión' in lower(sqlerrm))>0 or position('uq_open_session_per_user' in lower(sqlerrm))>0;
      if not v_ok then v_error:=sqlstate||' - '||sqlerrm; end if;
    end;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('SECOND_SESSION_REJECTED'),jsonb_build_array(case when v_ok then 'REJECTED' else 'ACCEPTED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then delete from erp_supply.orders where id in(v_order_id,v_order2_id); end if;

  -- 4. Espera, reanudación y sesiones de tiempo.
  v_total:=v_total+1;v_key:='CTRL-04-WAIT-RESUME-TIME';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'TIMING','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"espera control"}',v_actor,true,null,v_key||'-WAIT');
    perform erp_supply.execute_action_internal(v_order_id,'RESUME','{}',v_actor,true,null,v_key||'-RESUME');
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"fin"}',v_actor,true,null,v_key||'-COMPLETE');
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='RECEPCION_PEDIDO' order by sequence_no limit 1;
    v_ok=(select count(*)=2 and bool_and(ended_at is not null) from erp_supply.task_sessions where task_id=v_task)
      and exists(select 1 from erp_supply.order_tasks where id=v_task and status='COMPLETED');
    if not v_ok then v_error:='Las sesiones de espera/reanudación no cerraron correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('TWO_CLOSED_SESSIONS','TASK_COMPLETED'),jsonb_build_array(case when v_ok then 'OK' else 'INVALID' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 5. Puerta real: checklist y validación financiera obligatorios.
  v_total:=v_total+1;v_key:='CTRL-05-STAGE-GATE';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'GATE','CARTERA',false);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{}',v_actor,true,null,v_key||'-BLOCKED');
      v_error:='La etapa se completó sin checklist ni validación';
    exception when others then
      v_ok:=position('controles obligatorios' in lower(sqlerrm))>0 or position('validación aprobada' in lower(sqlerrm))>0;
    end;
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='CARTERA' and status='IN_PROGRESS';
    update erp_supply.task_checklist set completed=true,completed_by=v_actor,completed_at=now() where task_id=v_task;
    insert into erp_supply.financial_validations(order_id,validation_type,decision,notes,created_by)
    values(v_order_id,'CARTERA','APPROVED','QA control',v_actor);
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"gate satisfied"}',v_actor,true,null,v_key||'-PASS');
    v_ok:=v_ok and exists(select 1 from erp_supply.orders where id=v_order_id and current_step_code='RECEPCION_PEDIDO');
    if not v_ok and v_error is null then v_error:='La puerta no bloqueó o no liberó correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('BLOCK_WITHOUT_CONTROLS','ADVANCE_WITH_CONTROLS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 6. No entrega y reprogramación futura.
  v_total:=v_total+1;v_key:='CTRL-06-NO-DELIVERY-REPROGRAM';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'NODELIVERY','LOCAL_DISPATCH',true,'LOCAL_DISPATCH');
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'NO_DELIVERY','{"reason":"cliente ausente"}',v_actor,true,null,v_key||'-NO');
    perform erp_supply.execute_action_internal(v_order_id,'REPROGRAM',jsonb_build_object('scheduledAt',now()+interval '1 day'),v_actor,true,null,v_key||'-REPROGRAM');
    v_ok:=exists(select 1 from erp_supply.deliveries where order_id=v_order_id and status='REPROGRAMMED')
      and exists(select 1 from erp_supply.orders where id=v_order_id and status='ASSIGNED');
    if not v_ok then v_error:='La no entrega no quedó reprogramada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('NOT_DELIVERED','REPROGRAMMED'),jsonb_build_array(case when v_ok then 'REPROGRAMMED' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 7. Solicitud y ejecución de prioridad.
  v_total:=v_total+1;v_key:='CTRL-07-APPROVAL-PRIORITY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'APPROVAL','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'REQUEST_APPROVAL','{"requestType":"PRIORITY","priority":"HIGH","reason":"QA"}',v_actor,true,null,v_key||'-REQUEST');
    select id into v_req from erp_supply.approval_requests where order_id=v_order_id and request_type='PRIORITY' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','Aprobación QA');
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and priority='HIGH')
      and exists(select 1 from erp_supply.approval_requests where id=v_req and status='EXECUTED');
    if not v_ok then v_error:='La aprobación no actualizó prioridad o no quedó ejecutada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('REQUESTED','EXECUTED','PRIORITY_HIGH'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 8. Importación histórica sin tareas operativas.
  v_total:=v_total+1;v_key:='CTRL-08-HISTORY-ISOLATION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_hist_number:='QAH-'||substr(replace(v_run.id::text,'-',''),1,12);
    perform public.erp_x_import_history('qa-history.csv',jsonb_build_array(jsonb_build_object(
      'orderNumber',v_hist_number,'orderType','PVC','paymentCondition','CREDIT','deliveryRoute','LOCAL_DISPATCH',
      'clientName','Histórico QA','status','CLOSED','createdAt',now()-interval '30 days','closedAt',now()-interval '29 days'
    )),null);
    select id into v_order_id from erp_supply.orders where organization_id=v_org and order_number=v_hist_number;
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and is_history and status='CLOSED')
      and not exists(select 1 from erp_supply.order_tasks where order_id=v_order_id);
    if not v_ok then v_error:='El histórico creó tareas o no quedó aislado'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('HISTORY','NO_TASKS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 9. Recepción publica inventario y movimiento.
  v_total:=v_total+1;v_key:='CTRL-09-RECEIPT-INVENTORY';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'RECEIPT','RECEPCION_MERCANCIA',true);
    perform public.erp_x_save_receipt(v_order_id,jsonb_build_object('receiptNumber','QAR-'||substr(v_run.id::text,1,8),'status','CONFORMING','lines',jsonb_build_array(jsonb_build_object(
      'sku','QA-RECEIPT-'||substr(v_run.id::text,1,8),'description','Material recepción QA','receivedQuantity',10,'acceptedQuantity',10,'rejectedQuantity',0,'unit','UND','location','QA','lotNumber','LOT-QA'
    ))));
    select inventory_item_id into v_item from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' order by id desc limit 1;
    v_ok:=v_item is not null and exists(select 1 from erp_supply.inventory_lots where inventory_item_id=v_item and quantity_available=10)
      and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' and quantity=10);
    if not v_ok then v_error:='La recepción no publicó inventario correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('RECEIPT','LOT','MOVEMENT'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then
    delete from erp_supply.inventory_movements where order_id=v_order_id;
    if v_item is not null then delete from erp_supply.inventory_lots where inventory_item_id=v_item;delete from erp_supply.inventory_items where id=v_item;end if;
    delete from erp_supply.orders where id=v_order_id;
  end if;

  -- 10. Corte consume lote y registra desperdicio.
  v_total:=v_total+1;v_key:='CTRL-10-CUT-CONSUMPTION';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;v_lot:=null;
  begin
    insert into erp_supply.inventory_items(organization_id,sku,description,unit,item_type)
    values(v_org,'QA-CUT-'||substr(v_run.id::text,1,8),'Chipa QA','M','CABLE') returning id into v_item;
    insert into erp_supply.inventory_lots(inventory_item_id,lot_number,location,quantity_available)
    values(v_item,'LOT-CUT-QA','QA-CORTE',100) returning id into v_lot;
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'CUT','CORTE',true,'LOCAL_DISPATCH',true);
    perform public.erp_x_save_cut_job(v_order_id,jsonb_build_object('inventoryLotId',v_lot,'requestedLength',10,'actualLength',10,'scrapLength',1));
    select quantity_available into v_available from erp_supply.inventory_lots where id=v_lot;
    v_ok:=v_available=89 and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='CUT_CONSUMPTION' and quantity=11);
    if not v_ok then v_error:='El corte no descontó longitud y desperdicio correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('AVAILABLE_89','MOVEMENT_11'),jsonb_build_array(coalesce(v_available,-1)),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then
    if v_order_id is not null then delete from erp_supply.inventory_movements where order_id=v_order_id;delete from erp_supply.orders where id=v_order_id;end if;
    if v_lot is not null then delete from erp_supply.inventory_lots where id=v_lot;end if;
    if v_item is not null then delete from erp_supply.inventory_items where id=v_item;end if;
  end if;

  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,
    total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),
    summary=summary||jsonb_build_object('cleanup',p_cleanup,'controls','idempotency,version,sessions,timing,gates,delivery,approval,history,receipt,cut')
  where id=v_run.id returning * into v_run;

  return jsonb_build_object('runId',v_run.id,'runType',v_run.run_type,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
end;
$$;

revoke all on function public.erp_x_run_qa_control_suite(boolean) from public,anon,authenticated;
grant execute on function public.erp_x_run_qa_control_suite(boolean) to authenticated;

-- Reconcile every public native RPC.
do $$ declare r record; begin
  for r in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_x_%'
  loop execute format('revoke all on function %s from public,anon,authenticated',r.sig);execute format('grant execute on function %s to authenticated',r.sig);end loop;
end $$;

commit;


-- ============================================================================
-- 015_approval_lifecycle_hardening.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 015: strict approval lifecycle, canonical approvers and safe execution.

begin;

create or replace function public.erp_x_execute_action(
  p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_action text:=upper(trim(coalesce(p_action_code,'')));
  v_type text;
  v_payload jsonb:=coalesce(p_payload,'{}'::jsonb);
  v_route text;
  v_assigned_role text;
begin
  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;

  if v_action='NO_DELIVERY' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
    raise exception 'No autorizado para registrar no entrega' using errcode='42501';
  end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
    raise exception 'No autorizado para reprogramar' using errcode='42501';
  end if;

  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(v_payload->>'requestType','')));
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then
      raise exception 'Tipo de solicitud inválido';
    end if;
    if nullif(trim(v_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if exists(select 1 from erp_supply.approval_requests where order_id=p_order_id and request_type=v_type and status='PENDING') then
      raise exception 'Ya existe una solicitud pendiente del mismo tipo';
    end if;

    if v_type in('CANCELLATION','PRIORITY','ROUTE_CHANGE','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION')
       and v_order.status in('CLOSED','CANCELLED') then
      raise exception 'La solicitud % solo aplica a pedidos activos',v_type;
    end if;
    if v_type='REOPEN' and v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
    if v_type='PRIORITY' and upper(coalesce(v_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then
      raise exception 'Prioridad inválida';
    end if;
    if v_type='ROUTE_CHANGE' then
      v_route:=upper(coalesce(v_payload->>'route',''));
      if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta inválida'; end if;
      if v_route=v_order.delivery_route_code then raise exception 'La nueva ruta debe ser diferente de la actual'; end if;
      if v_order.current_step_code in('CLOSURE','CLOSED') then raise exception 'No se puede cambiar la ruta después de la entrega'; end if;
      v_payload:=v_payload||jsonb_build_object('route',v_route);
    end if;

    v_assigned_role:=case
      when v_type='PAYMENT_EXCEPTION' then 'gerencia'
      else 'jefe_logistica'
    end;
    v_payload:=v_payload||jsonb_build_object('requestType',v_type,'assignedRole',v_assigned_role);
  end if;

  return erp_supply.execute_action_internal(p_order_id,v_action,v_payload,v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_req erp_supply.approval_requests%rowtype;
  v_order erp_supply.orders%rowtype;
  v_dec text:=upper(trim(coalesce(p_decision,'')));
  v_route text;
  v_old_task erp_supply.order_tasks%rowtype;
  v_next_sequence integer;
  v_final_status text;
  v_before_step text;
  v_before_status text;
  v_now timestamptz:=now();
begin
  select * into v_req from erp_supply.approval_requests
  where id=p_request_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
  if not (v_req.assigned_profile_id=v_actor or v_req.assigned_role_code=any(v_roles)
      or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then
    raise exception 'No autorizado para decidir' using errcode='42501';
  end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id for update;
  if not found then raise exception 'Pedido asociado no encontrado'; end if;
  v_before_step:=v_order.current_step_code;
  v_before_status:=v_order.status;

  update erp_supply.approval_requests
  set status=v_dec,decision_reason=trim(p_reason),decided_by=v_actor,decided_at=v_now
  where id=p_request_id returning * into v_req;

  if v_dec='APPROVED' then
    case v_req.request_type
      when 'CANCELLATION' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.task_sessions s
        set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
            business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
            note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cancelación aprobada'
        from erp_supply.order_tasks t
        where s.task_id=t.id and t.order_id=v_order.id and s.ended_at is null;
        update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='CANCELLED_BY_APPROVAL'
        where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
        update erp_supply.orders set status='CANCELLED',cancelled_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1
        where id=v_order.id returning * into v_order;

      when 'PRIORITY' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.orders set priority=upper(v_req.request_payload->>'priority'),version=version+1
        where id=v_order.id returning * into v_order;

      when 'ROUTE_CHANGE' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        v_route:=upper(v_req.request_payload->>'route');
        if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta aprobada inválida'; end if;
        if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
          select * into v_old_task from erp_supply.order_tasks
          where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
          order by sequence_no desc limit 1 for update;
          update erp_supply.task_sessions s set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
            business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
            note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cambio de ruta'
          where s.task_id=v_old_task.id and s.ended_at is null;
          update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='ROUTE_CHANGED'
          where id=v_old_task.id;
          v_next_sequence:=coalesce(v_old_task.sequence_no,0)+1;
          update erp_supply.orders set delivery_route_code=v_route,current_step_code=v_route,status='QUEUED',
            current_assignee_id=null,current_role_code=null,version=version+1
          where id=v_order.id returning * into v_order;
          perform erp_supply.create_task(v_order,v_route,v_next_sequence);
          select * into v_order from erp_supply.orders where id=v_order.id;
        else
          update erp_supply.orders set delivery_route_code=v_route,version=version+1
          where id=v_order.id returning * into v_order;
        end if;

      when 'REOPEN' then
        if v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
        v_next_sequence:=(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id);
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code='CLOSURE',
          current_assignee_id=null,current_role_code=null,version=version+1
        where id=v_order.id returning * into v_order;
        perform erp_supply.create_task(v_order,'CLOSURE',v_next_sequence);
        select * into v_order from erp_supply.orders where id=v_order.id;

      when 'STOCK_EXCEPTION' then null;
      when 'FLOW_EXCEPTION' then null;
      when 'PAYMENT_EXCEPTION' then null;
      when 'DATA_CORRECTION' then null;
      else raise exception 'Tipo de solicitud no implementado: %',v_req.request_type;
    end case;

    update erp_supply.approval_requests set status='EXECUTED',executed_at=v_now where id=p_request_id returning status into v_final_status;
  else
    v_final_status:='REJECTED';
  end if;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_before_step,v_order.current_step_code,
    v_before_status,v_order.status,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason,'finalRequestStatus',v_final_status));

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_req.organization_id,v_actor,'APPROVAL_'||v_dec,'APPROVAL_REQUEST',v_req.id::text,
    jsonb_build_object('status','PENDING'),jsonb_build_object('status',v_final_status,'orderStatus',v_order.status,'orderVersion',v_order.version),
    jsonb_build_object('requestType',v_req.request_type,'reason',p_reason));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_req.organization_id,'APPROVAL_DECIDED','ORDER',v_order.id,
    jsonb_build_object('requestId',v_req.id,'decision',v_dec,'requestType',v_req.request_type,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec,'requestStatus',v_final_status,
    'orderId',v_order.id,'orderStatus',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
end;
$$;

revoke all on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) from public,anon,authenticated;
revoke all on function public.erp_x_decide_approval(uuid,text,text) from public,anon,authenticated;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;
grant execute on function public.erp_x_decide_approval(uuid,text,text) to authenticated;

commit;


-- ============================================================================
-- 016_domain_audit_triggers.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 016: append-only audit coverage for every sensitive domain record.

begin;

create or replace function erp_supply.audit_domain_row()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_row jsonb;
  v_old jsonb;
  v_new jsonb;
  v_org uuid;
  v_actor uuid;
  v_order uuid;
  v_task uuid;
  v_receipt uuid;
  v_entity_id text;
  v_is_test boolean:=false;
  v_mode text:=coalesce(TG_ARGV[0],'DIRECT');
begin
  v_old:=case when TG_OP in('UPDATE','DELETE') then to_jsonb(old) end;
  v_new:=case when TG_OP in('INSERT','UPDATE') then to_jsonb(new) end;
  v_row:=coalesce(v_new,v_old,'{}'::jsonb);

  if v_mode='ORDER' then
    begin v_order:=nullif(v_row->>'order_id','')::uuid; exception when others then v_order:=null; end;
  elsif v_mode='TASK' then
    begin v_task:=nullif(v_row->>'task_id','')::uuid; exception when others then v_task:=null; end;
    select t.order_id into v_order from erp_supply.order_tasks t where t.id=v_task;
  elsif v_mode='RECEIPT' then
    begin v_receipt:=nullif(v_row->>'receipt_id','')::uuid; exception when others then v_receipt:=null; end;
    select r.order_id into v_order from erp_supply.receipts r where r.id=v_receipt;
  elsif v_mode='INVENTORY_ITEM' then
    select organization_id into v_org from erp_supply.inventory_items where id=nullif(v_row->>'inventory_item_id','')::uuid;
  elsif v_mode='PROFILE' then
    select organization_id into v_org from erp_supply.profiles where id=nullif(v_row->>'profile_id','')::uuid;
  elsif v_mode='MOVEMENT' then
    begin v_order:=nullif(v_row->>'order_id','')::uuid; exception when others then v_order:=null; end;
    begin v_org:=nullif(v_row->>'organization_id','')::uuid; exception when others then v_org:=null; end;
  else
    begin v_org:=nullif(v_row->>'organization_id','')::uuid; exception when others then v_org:=null; end;
  end if;

  if v_order is not null then
    select organization_id,is_test into v_org,v_is_test from erp_supply.orders where id=v_order;
  end if;
  if v_is_test then
    if TG_OP='DELETE' then return old; else return new; end if;
  end if;

  v_actor:=erp_supply.current_profile_id();
  v_entity_id:=coalesce(v_row->>'id',v_row->>'task_id',v_row->>'profile_id',v_row->>'order_id','UNKNOWN');
  if v_row ? 'item_code' then v_entity_id:=v_entity_id||':'||coalesce(v_row->>'item_code',''); end if;
  if v_row ? 'role_code' then v_entity_id:=v_entity_id||':'||coalesce(v_row->>'role_code',''); end if;

  insert into erp_supply.system_audit(
    organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata
  ) values(
    v_org,v_actor,TG_OP,TG_TABLE_NAME,v_entity_id,v_old,v_new,
    jsonb_build_object('schema',TG_TABLE_SCHEMA,'trigger','domain-audit','orderId',v_order)
  );

  if TG_OP='DELETE' then return old; else return new; end if;
end;
$$;

-- Helper block creates idempotent triggers.
do $$
declare r record;
begin
  for r in select * from (values
    ('order_items','ORDER'),('financial_validations','ORDER'),('purchase_orders','ORDER'),('receipts','ORDER'),('receipt_lines','RECEIPT'),
    ('task_checklist','TASK'),('inventory_items','DIRECT'),('inventory_lots','INVENTORY_ITEM'),('inventory_movements','MOVEMENT'),('cut_jobs','ORDER'),('invoices','ORDER'),
    ('deliveries','ORDER'),('credit_requests','DIRECT'),('drive_files','ORDER'),('approval_requests','ORDER'),
    ('profiles','DIRECT'),('profile_roles','PROFILE')
  ) x(table_name,mode)
  loop
    execute format('drop trigger if exists %I on erp_supply.%I','trg_audit_'||r.table_name,r.table_name);
    execute format('create trigger %I after insert or update or delete on erp_supply.%I for each row execute function erp_supply.audit_domain_row(%L)',
      'trg_audit_'||r.table_name,r.table_name,r.mode);
  end loop;
end $$;

commit;


-- ============================================================================
-- 017_input_contract_hardening.sql
-- ============================================================================
-- ERP Supply Enterprise V10
-- Migration 017: strict and friendly input contracts for creation, administration and credit.

begin;

create or replace function erp_supply.safe_boolean(p_value text,p_default boolean default null)
returns boolean
language sql
immutable
as $$
  select case lower(trim(coalesce(p_value,'')))
    when 'true' then true when 't' then true when '1' then true when 'yes' then true when 'si' then true when 'sí' then true
    when 'false' then false when 'f' then false when '0' then false when 'no' then false
    else p_default end
$$;

create or replace function erp_supply.safe_numeric(p_value text)
returns numeric
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::numeric;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;

create or replace function erp_supply.safe_integer(p_value text)
returns integer
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::integer;
exception when invalid_text_representation or numeric_value_out_of_range then return null;
end;
$$;

create or replace function erp_supply.safe_date(p_value text)
returns date
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::date;
exception when invalid_datetime_format or datetime_field_overflow then return null;
end;
$$;

create or replace function erp_supply.safe_timestamptz(p_value text)
returns timestamptz
language plpgsql
stable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::timestamptz;
exception when invalid_datetime_format or datetime_field_overflow then return null;
end;
$$;

create or replace function erp_supply.safe_uuid(p_value text)
returns uuid
language plpgsql
immutable
as $$
begin
  if nullif(trim(p_value),'') is null then return null; end if;
  return trim(p_value)::uuid;
exception when invalid_text_representation then return null;
end;
$$;

create or replace function public.erp_x_create_order(p_payload jsonb,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_item jsonb;
  v_items jsonb;
  v_initial text;
  v_number text;
  v_order_type text;
  v_payment text;
  v_route text;
  v_client text;
  v_priority text;
  v_requires_purchase boolean;
  v_requires_cut boolean;
  v_item_cut boolean;
  v_quantity numeric;
  v_cut_length numeric;
  v_requested_date date;
  v_promised_at timestamptz;
  v_line integer:=0;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then
    raise exception 'Rol no autorizado para crear pedidos' using errcode='42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'El pedido debe enviarse como un objeto válido'; end if;

  v_number:=nullif(trim(p_payload->>'orderNumber'),'');
  v_order_type:=upper(nullif(trim(p_payload->>'orderType'),''));
  v_payment:=upper(nullif(trim(p_payload->>'paymentCondition'),''));
  v_route:=upper(nullif(trim(p_payload->>'deliveryRoute'),''));
  v_client:=nullif(trim(p_payload->>'clientName'),'');
  v_priority:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_requested_date:=erp_supply.safe_date(p_payload->>'requestedDeliveryDate');
  v_promised_at:=erp_supply.safe_timestamptz(p_payload->>'promisedAt');
  v_items:=coalesce(p_payload->'items','[]'::jsonb);

  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_order_type and active) then raise exception 'Tipo de pedido inválido: %',coalesce(v_order_type,'vacío'); end if;
  if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago inválida: %',coalesce(v_payment,'vacía'); end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Modalidad de entrega inválida: %',coalesce(v_route,'vacía'); end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
  if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)=0 then raise exception 'El pedido debe contener al menos un ítem'; end if;
  if (p_payload ? 'requestedDeliveryDate') and nullif(trim(p_payload->>'requestedDeliveryDate'),'') is not null and v_requested_date is null then raise exception 'Fecha solicitada inválida'; end if;
  if (p_payload ? 'promisedAt') and nullif(trim(p_payload->>'promisedAt'),'') is not null and v_promised_at is null then raise exception 'Fecha prometida inválida'; end if;

  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_org and idempotency_key=p_idempotency_key
  ) then
    select o.* into v_order
    from erp_supply.orders o
    join erp_supply.order_events e on e.order_id=o.id
    where e.organization_id=v_org and e.idempotency_key=p_idempotency_key
    limit 1;
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
  end if;

  v_requires_purchase:=coalesce(
    erp_supply.safe_boolean(p_payload->>'requiresPurchase',null),
    (select requires_purchase_default from erp_supply.order_types where code=v_order_type),
    false
  );
  v_requires_cut:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresCut',false),false);

  for v_item in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_item)<>'object' then raise exception 'Cada línea del pedido debe ser un objeto'; end if;
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    if v_item_cut then v_requires_cut:=true; end if;
  end loop;

  v_initial:=erp_supply.initial_step(v_order_type,v_payment,v_requires_purchase);

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),nullif(trim(p_payload->>'clientCity'),''),
    nullif(trim(p_payload->>'clientAddress'),''),nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
    v_priority,v_requires_cut,v_requires_purchase,v_promised_at,v_requested_date,
    case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end
  ) returning * into v_order;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_line:=v_line+1;
    v_quantity:=erp_supply.safe_numeric(v_item->>'quantity');
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    v_cut_length:=erp_supply.safe_numeric(v_item->>'requestedCutLength');
    if nullif(trim(v_item->>'description'),'') is null then raise exception 'La línea % no tiene descripción',v_line; end if;
    if v_quantity is null or v_quantity<=0 then raise exception 'Cantidad inválida en la línea %',v_line; end if;
    if v_item_cut and (v_cut_length is null or v_cut_length<=0) then raise exception 'La línea % requiere una longitud de corte válida',v_line; end if;
    insert into erp_supply.order_items(
      order_id,line_number,sku,reference,description,quantity,unit,warehouse_location,requires_cut,
      requested_cut_length,dimensions,metadata
    ) values(
      v_order.id,coalesce(erp_supply.safe_integer(v_item->>'lineNumber'),v_line),nullif(trim(v_item->>'sku'),''),
      nullif(trim(v_item->>'reference'),''),trim(v_item->>'description'),v_quantity,
      coalesce(nullif(trim(v_item->>'unit'),''),'UND'),nullif(trim(v_item->>'warehouseLocation'),''),v_item_cut,
      v_cut_length,case when jsonb_typeof(coalesce(v_item->'dimensions','{}'::jsonb))='object' then coalesce(v_item->'dimensions','{}'::jsonb) else '{}'::jsonb end,
      case when jsonb_typeof(coalesce(v_item->'metadata','{}'::jsonb))='object' then coalesce(v_item->'metadata','{}'::jsonb) else '{}'::jsonb end
    );
  end loop;

  select * into v_task from erp_supply.create_task(v_order,v_initial,1);
  select * into v_order from erp_supply.orders where id=v_order.id;
  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,to_step_code,to_status,actor_profile_id,actor_role_code,idempotency_key,payload
  ) values(
    v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,p_payload
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_admin_save_profile(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile erp_supply.profiles%rowtype;
  v_profile_id uuid:=erp_supply.safe_uuid(p_payload->>'id');
  v_auth_id uuid:=erp_supply.safe_uuid(p_payload->>'authUserId');
  v_email text:=lower(nullif(trim(p_payload->>'email'),''));
  v_name text:=nullif(trim(p_payload->>'name'),'');
  v_active boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'active',true),true);
  v_roles jsonb:=coalesce(p_payload->'roles','[]'::jsonb);
  v_role text;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede administrar usuarios' using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Perfil inválido'; end if;
  if v_email is null or position('@' in v_email)<=1 then raise exception 'Correo inválido'; end if;
  if v_name is null then raise exception 'Nombre requerido'; end if;
  if (p_payload ? 'id') and nullif(trim(p_payload->>'id'),'') is not null and v_profile_id is null then raise exception 'ID de perfil inválido'; end if;
  if (p_payload ? 'authUserId') and nullif(trim(p_payload->>'authUserId'),'') is not null and v_auth_id is null then raise exception 'Auth User UUID inválido'; end if;
  if v_auth_id is not null and not exists(select 1 from auth.users where id=v_auth_id) then raise exception 'El UUID no corresponde a un usuario de Supabase Auth'; end if;
  if jsonb_typeof(v_roles)<>'array' then raise exception 'La lista de roles es inválida'; end if;
  if v_active and jsonb_array_length(v_roles)=0 then raise exception 'Un usuario activo debe tener al menos un rol'; end if;

  if v_profile_id is null then
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active)
    values(v_org,v_auth_id,v_email,v_name,nullif(trim(p_payload->>'employeeCode'),''),v_active)
    returning * into v_profile;
  else
    update erp_supply.profiles
    set auth_user_id=coalesce(v_auth_id,auth_user_id),email=v_email,display_name=v_name,
        employee_code=nullif(trim(p_payload->>'employeeCode'),''),active=v_active
    where id=v_profile_id and organization_id=v_org
    returning * into v_profile;
    if not found then raise exception 'Perfil no encontrado'; end if;
  end if;

  for v_role in select value#>>'{}' from jsonb_array_elements(v_roles) loop
    if not exists(select 1 from erp_supply.roles where code=v_role and active) then raise exception 'Rol inválido: %',v_role; end if;
  end loop;

  delete from erp_supply.profile_roles where profile_id=v_profile.id;
  for v_role in select value#>>'{}' from jsonb_array_elements(v_roles) loop
    insert into erp_supply.profile_roles(profile_id,role_code,is_primary,granted_by)
    values(v_profile.id,v_role,not exists(select 1 from erp_supply.profile_roles where profile_id=v_profile.id),erp_supply.current_profile_id());
  end loop;
  return jsonb_build_object('success',true,'profile',to_jsonb(v_profile));
exception
  when unique_violation then raise exception 'Ya existe un perfil con ese correo o usuario Auth';
end;
$$;

create or replace function public.erp_x_credit_create(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_req erp_supply.credit_requests%rowtype;
  v_number text;
  v_client text:=nullif(trim(p_payload->>'clientName'),'');
  v_amount numeric:=erp_supply.safe_numeric(p_payload->>'requestedAmount');
  v_term integer:=erp_supply.safe_integer(p_payload->>'requestedTermDays');
begin
  if not erp_supply.can_access_module('credit','create') then raise exception 'No autorizado para crear crédito' using errcode='42501'; end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'Solicitud de crédito inválida'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if v_amount is null or v_amount<=0 then raise exception 'Valor solicitado inválido'; end if;
  if v_term is null or v_term<=0 then raise exception 'Plazo solicitado inválido'; end if;
  v_number:=coalesce(nullif(trim(p_payload->>'requestNumber'),''),'CR-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS'));
  insert into erp_supply.credit_requests(
    organization_id,request_number,client_name,client_document,requested_amount,requested_term_days,status,requested_by,metadata
  ) values(
    v_org,v_number,v_client,nullif(trim(p_payload->>'clientDocument'),''),v_amount,v_term,'SUBMITTED',v_actor,
    case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end
  ) returning * into v_req;
  return jsonb_build_object('success',true,'request',to_jsonb(v_req));
exception
  when unique_violation then raise exception 'Ya existe una solicitud con el número %',v_number;
end;
$$;

-- Final permission reconciliation after the hardening migration.
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


-- ============================================================================
-- 018_reception_order_v10_6.sql
-- ============================================================================
-- ERP Electroingeniería V10.6
-- Recepción de pedidos: líneas definitivas + asignación controlada de Alistamiento y Corte.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

-- Respeta la asignación realizada en Recepción cuando se crean las tareas futuras.
create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_resolved record;
  v_profile_id uuid;
  v_role_code text;
  v_preferred_text text;
  v_task erp_supply.order_tasks;
begin
  if p_step='ALISTAMIENTO' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,pickingProfileId}','');
    v_role_code:='aux_logistica';
  elsif p_step='CORTE' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,cutProfileId}','');
    v_role_code:='auxiliar_corte';
  end if;

  if v_preferred_text is not null then
    begin
      v_profile_id:=v_preferred_text::uuid;
    exception when others then
      v_profile_id:=null;
    end;

    if v_profile_id is not null and not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr
        on sr.role_code=pr.role_code
       and sr.step_code=p_step
       and sr.can_view
      where p.id=v_profile_id
        and p.organization_id=p_order.organization_id
        and p.active
        and pr.role_code=v_role_code
    ) then
      v_profile_id:=null;
    end if;
  end if;

  if v_profile_id is null then
    select * into v_resolved
    from erp_supply.resolve_assignment(
      p_order.organization_id,
      p_step,
      p_order.delivery_route_code,
      p_order.order_type_code
    );
    v_profile_id:=v_resolved.profile_id;
    v_role_code:=v_resolved.role_code;
  end if;

  insert into erp_supply.order_tasks(
    order_id,step_code,sequence_no,queue_code,status,
    assigned_profile_id,assigned_role_code,assigned_at,metadata
  )
  select
    p_order.id,p_step,p_sequence,s.queue_code,
    case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_profile_id,v_role_code,
    case when v_profile_id is null then null else now() end,
    case
      when v_preferred_text is not null and v_profile_id is not null
        then jsonb_build_object('assignedFrom','RECEPCION_PEDIDO')
      else '{}'::jsonb
    end
  from erp_supply.workflow_steps s
  where s.code=p_step
  returning * into v_task;

  if v_task.id is null then
    raise exception 'No existe la etapa %',p_step;
  end if;

  insert into erp_supply.task_checklist(task_id,item_code,label,required,sort_order)
  select v_task.id,t.item_code,t.label,t.required,t.sort_order
  from erp_supply.checklist_templates t
  where t.step_code=p_step and t.active
  on conflict(task_id,item_code) do nothing;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_profile_id,
      current_role_code=v_role_code,
      version=version+1,
      updated_at=now()
  where id=p_order.id;

  return v_task;
end;
$$;

-- Confirma toda la recepción en una transacción: líneas, cortes, responsables y avance.
create or replace function public.erp_x_confirm_order_reception(
  p_order_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_line jsonb;
  v_lines jsonb:=coalesce(p_payload->'lines','[]'::jsonb);
  v_line_count integer:=0;
  v_cut_count integer:=0;
  v_picking uuid;
  v_cut uuid;
  v_item_id uuid;
  v_candidate uuid;
  v_used_ids uuid[]:='{}'::uuid[];
  v_quantity numeric;
  v_cut_length numeric;
  v_requires_cut boolean;
  v_description text;
  v_unit text;
  v_source_mode text:=upper(coalesce(nullif(trim(p_payload->>'sourceMode'),''),'CORRECT'));
  v_new_version integer;
  v_result jsonb;
begin
  if not (
    erp_supply.can_access_module('receiving','update')
    or erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
  ) then
    raise exception 'No autorizado para confirmar Recepción de pedidos' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;

  if not found or not erp_supply.can_view_order(v_order.id) then
    raise exception 'Pedido no disponible' using errcode='42501';
  end if;
  if v_order.current_step_code<>'RECEPCION_PEDIDO' then
    raise exception 'El pedido ya no está en Recepción de pedidos';
  end if;
  if jsonb_typeof(v_lines)<>'array' or jsonb_array_length(v_lines)=0 then
    raise exception 'Debe confirmar al menos una línea del pedido';
  end if;
  if v_source_mode not in('CORRECT','PDF','MANUAL') then
    raise exception 'Origen de información inválido';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=v_order.id
    and step_code='RECEPCION_PEDIDO'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found then
    raise exception 'El pedido no tiene una tarea activa de Recepción';
  end if;
  if v_task.status<>'IN_PROGRESS' then
    raise exception 'Primero debes tomar e iniciar el pedido';
  end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not erp_supply.has_role('super_admin')
     and not erp_supply.has_role('jefe_logistica') then
    raise exception 'El pedido está siendo gestionado por otro usuario' using errcode='42501';
  end if;

  begin
    v_picking:=nullif(p_payload->>'pickingProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de alistamiento inválido';
  end;
  if v_picking is null or not exists(
    select 1
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    where p.id=v_picking
      and p.organization_id=v_org
      and p.active
      and pr.role_code='aux_logistica'
  ) then
    raise exception 'Selecciona un auxiliar de logística activo';
  end if;

  begin
    v_cut:=nullif(p_payload->>'cutProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de corte inválido';
  end;

  -- Mueve temporalmente los números para permitir reordenar sin colisiones únicas.
  update erp_supply.order_items
  set line_number=line_number+100000,
      metadata=metadata||jsonb_build_object('receptionActive',false),
      updated_at=now()
  where order_id=v_order.id;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_line_count:=v_line_count+1;
    if jsonb_typeof(v_line)<>'object' then
      raise exception 'La línea % no es válida',v_line_count;
    end if;

    v_description:=nullif(trim(v_line->>'description'),'');
    begin
      v_quantity:=nullif(v_line->>'quantity','')::numeric;
    exception when others then
      raise exception 'Cantidad inválida en la línea %',v_line_count;
    end;
    v_unit:=upper(coalesce(nullif(trim(v_line->>'unit'),''),'UND'));
    v_requires_cut:=coalesce((v_line->>'requiresCut')::boolean,false);
    begin
      v_cut_length:=nullif(v_line->>'requestedCutLength','')::numeric;
    exception when others then
      raise exception 'Longitud de corte inválida en la línea %',v_line_count;
    end;

    if v_description is null then
      raise exception 'La línea % necesita una descripción',v_line_count;
    end if;
    if v_quantity is null or v_quantity<=0 then
      raise exception 'La línea % necesita una cantidad válida',v_line_count;
    end if;
    if v_requires_cut and (v_cut_length is null or v_cut_length<=0) then
      raise exception 'La línea % necesita una longitud de corte válida',v_line_count;
    end if;
    if v_requires_cut then v_cut_count:=v_cut_count+1; end if;

    v_item_id:=null;
    begin
      v_candidate:=nullif(v_line->>'orderItemId','')::uuid;
    exception when others then
      v_candidate:=null;
    end;

    if v_candidate is not null and exists(
      select 1 from erp_supply.order_items
      where id=v_candidate and order_id=v_order.id
    ) and not (v_candidate=any(v_used_ids)) then
      v_item_id:=v_candidate;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'reference'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and reference=trim(v_line->>'reference')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'sku'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and sku=trim(v_line->>'sku')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null then
      insert into erp_supply.order_items(
        order_id,line_number,sku,reference,description,quantity,unit,
        warehouse_location,requires_cut,requested_cut_length,dimensions,metadata
      ) values(
        v_order.id,v_line_count,nullif(trim(v_line->>'sku'),''),
        nullif(trim(v_line->>'reference'),''),v_description,v_quantity,v_unit,
        nullif(trim(v_line->>'warehouseLocation'),''),v_requires_cut,
        case when v_requires_cut then v_cut_length else null end,
        case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
          then coalesce(v_line->'dimensions','{}'::jsonb) else '{}'::jsonb end,
        case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
          then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
        || jsonb_build_object(
          'receptionActive',true,
          'receptionSource',v_source_mode,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ) returning id into v_item_id;
    else
      update erp_supply.order_items
      set line_number=v_line_count,
          sku=nullif(trim(v_line->>'sku'),''),
          reference=nullif(trim(v_line->>'reference'),''),
          description=v_description,
          quantity=v_quantity,
          unit=v_unit,
          warehouse_location=nullif(trim(v_line->>'warehouseLocation'),''),
          requires_cut=v_requires_cut,
          requested_cut_length=case when v_requires_cut then v_cut_length else null end,
          dimensions=case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
            then coalesce(v_line->'dimensions','{}'::jsonb) else dimensions end,
          metadata=metadata
            || case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
                 then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
            || jsonb_build_object(
              'receptionActive',true,
              'receptionSource',v_source_mode,
              'confirmedAt',now(),
              'confirmedBy',v_actor
            ),
          updated_at=now()
      where id=v_item_id;
    end if;

    v_used_ids:=array_append(v_used_ids,v_item_id);
  end loop;

  if v_cut_count>0 then
    if v_cut is null or not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      where p.id=v_cut
        and p.organization_id=v_org
        and p.active
        and pr.role_code='auxiliar_corte'
    ) then
      raise exception 'Selecciona un auxiliar de corte activo';
    end if;
  else
    v_cut:=null;
  end if;

  -- Los registros antiguos con relaciones de recepción se conservan, pero dejan de formar parte del pedido operativo.
  delete from erp_supply.order_items i
  where i.order_id=v_order.id
    and not (i.id=any(v_used_ids))
    and not exists(select 1 from erp_supply.receipt_lines rl where rl.order_item_id=i.id)
    and not exists(select 1 from erp_supply.cut_jobs cj where cj.order_item_id=i.id);

  update erp_supply.task_checklist
  set completed=true,
      completed_by=v_actor,
      completed_at=now(),
      note=case item_code
        when 'DOCUMENTS' then 'Información comercial validada en Recepción de pedidos'
        when 'ASSIGNMENT' then 'Auxiliares asignados desde Recepción de pedidos'
        else note end,
      metadata=metadata||jsonb_build_object('source','RECEPCION_PEDIDO_V10_6')
  where task_id=v_task.id and item_code in('DOCUMENTS','ASSIGNMENT');

  update erp_supply.orders
  set requires_cut=(v_cut_count>0),
      metadata=metadata||jsonb_build_object(
        'receptionAssignment',jsonb_build_object(
          'pickingProfileId',v_picking,
          'cutProfileId',v_cut,
          'sourceMode',v_source_mode,
          'sourceFileId',nullif(p_payload->>'sourceFileId',''),
          'sourceFileName',nullif(p_payload->>'sourceFileName',''),
          'readerVersion',nullif(p_payload->>'readerVersion',''),
          'lineCount',v_line_count,
          'cutLineCount',v_cut_count,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ),
      version=version+1,
      updated_at=now()
  where id=v_order.id
  returning version into v_new_version;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'DOMAIN_RECORD','RECEPTION_ASSIGNMENT',
    'RECEPCION_PEDIDO','RECEPCION_PEDIDO',v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'sourceMode',v_source_mode,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count,
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'sourceFileId',nullif(p_payload->>'sourceFileId',''),
      'readerVersion',nullif(p_payload->>'readerVersion','')
    )
  );

  v_result:=erp_supply.execute_action_internal(
    v_order.id,
    'COMPLETE',
    jsonb_build_object(
      'resultCode','RECEPTION_CONFIRMED',
      'detail','Información validada y auxiliares asignados',
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count
    ),
    v_actor,
    false,
    v_new_version,
    'RECEPTION-CONFIRM-'||v_order.id::text||'-'||v_new_version::text
  );

  return v_result||jsonb_build_object(
    'receptionConfirmed',true,
    'lines',v_line_count,
    'cutLines',v_cut_count,
    'pickingProfileId',v_picking,
    'cutProfileId',v_cut
  );
end;
$$;

-- El detalle operativo muestra solo las líneas vigentes; las antiguas relacionadas quedan auditables en la base.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
begin
  perform erp_supply.require_profile();
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;

  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb)
      from erp_supply.order_items i
      where i.order_id=p_order_id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'metadata',c.metadata,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

revoke all on function public.erp_x_confirm_order_reception(uuid,jsonb) from public;
grant execute on function public.erp_x_confirm_order_reception(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;

commit;


-- ============================================================================
-- 019_financial_routing_and_cash_invoice_v10_7.sql
-- ============================================================================
-- ERP Supply Enterprise V10.7
-- Enrutamiento condicional de Cartera/Caja y facturación PVN desde Caja.

begin;

insert into erp_supply.workflow_steps(code,name,module_code,queue_code,sla_hours,sort_order,terminal,metadata)
values('CAJA_FACTURACION','Facturación en Caja','caja','CAJA',4,75,false,'{"phase":"outbound","orderType":"PVN"}'::jsonb)
on conflict(code) do update set
  name=excluded.name,module_code=excluded.module_code,queue_code=excluded.queue_code,
  sla_hours=excluded.sla_hours,sort_order=excluded.sort_order,terminal=false,active=true,metadata=excluded.metadata;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
values('CAJA_FACTURACION','caja',true,true,false,true,true,true,false)
on conflict(step_code,role_code) do update set
  can_view=true,can_claim=true,can_assign=false,can_start=true,can_complete=true,can_block=true,can_override=false;

insert into erp_supply.step_roles(step_code,role_code,can_view,can_claim,can_assign,can_start,can_complete,can_block,can_override)
select 'CAJA_FACTURACION',r.role_code,r.can_view,r.can_claim,r.can_assign,r.can_start,r.can_complete,r.can_block,r.can_override
from erp_supply.step_roles r
where r.step_code='CAJA' and r.role_code in('super_admin','gerencia','auditoria','jefe_logistica')
on conflict(step_code,role_code) do update set
  can_view=excluded.can_view,can_claim=excluded.can_claim,can_assign=excluded.can_assign,
  can_start=excluded.can_start,can_complete=excluded.can_complete,can_block=excluded.can_block,can_override=excluded.can_override;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('caja','billing',true,true,true,false,false)
on conflict(role_code,module_code) do update set
  can_read=true,can_create=true,can_update=true;

insert into erp_supply.checklist_templates(step_code,item_code,label,required,sort_order,active)
values('CAJA_FACTURACION','INVOICE_UPLOAD','Factura cargada y verificada por Caja',true,10,true)
on conflict(step_code,item_code) do update set label=excluded.label,required=true,sort_order=10,active=true;

create or replace function erp_supply.initial_step(
  p_order_type text,
  p_payment_condition text,
  p_requires_purchase boolean,
  p_has_credit_arrears boolean,
  p_held_by_cashier boolean
)
returns text
language sql
immutable
as $$
  select case
    when p_order_type in('PVC','PVP') and coalesce(p_has_credit_arrears,false) then 'CARTERA'
    when p_order_type='PVN' and coalesce(p_held_by_cashier,false) then 'CAJA'
    when p_order_type='PVE' then 'COMPRAS'
    when p_order_type not in('PVC','PVP','PVN','PVE') and coalesce(p_requires_purchase,false) then 'COMPRAS'
    else 'RECEPCION_PEDIDO'
  end
$$;

create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case p_current_step
    when 'CARTERA' then 'RECEPCION_PEDIDO'
    when 'CAJA' then 'RECEPCION_PEDIDO'
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case
      when p_requires_cut then 'CORTE'
      when p_order_type='PVN' then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CORTE' then case when p_order_type='PVN' then 'CAJA_FACTURACION' else 'FACTURACION' end
    when 'CAJA_FACTURACION' then p_delivery_route
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.default_role_for_step(p_step text,p_route text)
returns text
language sql
immutable
as $$
  select case p_step
    when 'CARTERA' then 'cartera'
    when 'CAJA' then 'caja'
    when 'CAJA_FACTURACION' then 'caja'
    when 'COMPRAS' then 'compras'
    when 'RECEPCION_MERCANCIA' then 'recepcion_mercancia'
    when 'RECEPCION_PEDIDO' then 'coordinador_logistico'
    when 'ALISTAMIENTO' then 'aux_logistica'
    when 'CORTE' then 'auxiliar_corte'
    when 'FACTURACION' then case when p_route='NATIONAL_DISPATCH' then 'despacho_nacional' else 'coordinador_logistico' end
    when 'NATIONAL_DISPATCH' then 'despacho_nacional'
    when 'CLIENT_POINT' then 'coordinador_logistico'
    when 'CLIENT_PICKUP' then 'coordinador_logistico'
    when 'LOCAL_DISPATCH' then 'coordinador_logistico'
    when 'CLOSURE' then 'jefe_logistica'
    else null end
$$;

create or replace function public.erp_x_create_order(p_payload jsonb,p_idempotency_key text default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_item jsonb;
  v_items jsonb;
  v_initial text;
  v_number text;
  v_order_type text;
  v_payment text;
  v_route text;
  v_client text;
  v_priority text;
  v_requires_purchase boolean;
  v_requires_cut boolean;
  v_item_cut boolean;
  v_has_credit_arrears boolean;
  v_held_by_cashier boolean;
  v_quantity numeric;
  v_cut_length numeric;
  v_requested_date date;
  v_promised_at timestamptz;
  v_line integer:=0;
  v_metadata jsonb;
begin
  if not (erp_supply.can_access_module('orders','create') or erp_supply.can_access_module('sales','create')) then
    raise exception 'Rol no autorizado para crear pedidos' using errcode='42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload)<>'object' then raise exception 'El pedido debe enviarse como un objeto válido'; end if;

  v_number:=nullif(trim(p_payload->>'orderNumber'),'');
  v_order_type:=upper(nullif(trim(p_payload->>'orderType'),''));
  v_payment:=upper(nullif(trim(p_payload->>'paymentCondition'),''));
  v_route:=upper(nullif(trim(p_payload->>'deliveryRoute'),''));
  v_client:=nullif(trim(p_payload->>'clientName'),'');
  v_priority:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_requested_date:=erp_supply.safe_date(p_payload->>'requestedDeliveryDate');
  v_promised_at:=erp_supply.safe_timestamptz(p_payload->>'promisedAt');
  v_items:=coalesce(p_payload->'items','[]'::jsonb);

  if v_number is null then raise exception 'Número de pedido requerido'; end if;
  if v_client is null then raise exception 'Cliente requerido'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_order_type and active) then raise exception 'Tipo de pedido inválido: %',coalesce(v_order_type,'vacío'); end if;
  if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago inválida: %',coalesce(v_payment,'vacía'); end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Modalidad de entrega inválida: %',coalesce(v_route,'vacía'); end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
  if jsonb_typeof(v_items)<>'array' or jsonb_array_length(v_items)=0 then raise exception 'El pedido debe contener al menos un ítem'; end if;
  if (p_payload ? 'requestedDeliveryDate') and nullif(trim(p_payload->>'requestedDeliveryDate'),'') is not null and v_requested_date is null then raise exception 'Fecha solicitada inválida'; end if;
  if (p_payload ? 'promisedAt') and nullif(trim(p_payload->>'promisedAt'),'') is not null and v_promised_at is null then raise exception 'Fecha prometida inválida'; end if;

  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_org and idempotency_key=p_idempotency_key
  ) then
    select o.* into v_order
    from erp_supply.orders o
    join erp_supply.order_events e on e.order_id=o.id
    where e.organization_id=v_org and e.idempotency_key=p_idempotency_key
    limit 1;
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
  end if;

  v_requires_purchase:=coalesce(
    erp_supply.safe_boolean(p_payload->>'requiresPurchase',null),
    (select requires_purchase_default from erp_supply.order_types where code=v_order_type),
    false
  );
  v_requires_cut:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresCut',false),false);
  v_has_credit_arrears:=v_order_type in('PVC','PVP') and coalesce(erp_supply.safe_boolean(p_payload->>'hasCreditArrears',false),false);
  v_held_by_cashier:=v_order_type='PVN' and coalesce(erp_supply.safe_boolean(p_payload->>'heldByCashier',false),false);

  for v_item in select value from jsonb_array_elements(v_items) loop
    if jsonb_typeof(v_item)<>'object' then raise exception 'Cada línea del pedido debe ser un objeto'; end if;
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    if v_item_cut then v_requires_cut:=true; end if;
  end loop;

  v_initial:=erp_supply.initial_step(v_order_type,v_payment,v_requires_purchase,v_has_credit_arrears,v_held_by_cashier);
  v_metadata:=(case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
    ||jsonb_build_object(
      'hasCreditArrears',v_has_credit_arrears,
      'heldByCashier',v_held_by_cashier,
      'initialRouting',v_initial,
      'routingVersion','10.7'
    );

  insert into erp_supply.orders(
    organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
    client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,
    priority,requires_cut,requires_purchase,promised_at,requested_delivery_date,metadata
  ) values(
    v_org,v_number,nullif(trim(p_payload->>'externalReference'),''),v_order_type,v_payment,v_route,
    v_client,nullif(trim(p_payload->>'clientDocument'),''),nullif(trim(p_payload->>'clientCity'),''),
    nullif(trim(p_payload->>'clientAddress'),''),nullif(trim(p_payload->>'clientPhone'),''),v_actor,v_initial,'QUEUED',
    v_priority,v_requires_cut,v_requires_purchase,v_promised_at,v_requested_date,v_metadata
  ) returning * into v_order;

  for v_item in select value from jsonb_array_elements(v_items) loop
    v_line:=v_line+1;
    v_quantity:=erp_supply.safe_numeric(v_item->>'quantity');
    v_item_cut:=coalesce(erp_supply.safe_boolean(v_item->>'requiresCut',false),false);
    v_cut_length:=erp_supply.safe_numeric(v_item->>'requestedCutLength');
    if nullif(trim(v_item->>'description'),'') is null then raise exception 'La línea % no tiene descripción',v_line; end if;
    if v_quantity is null or v_quantity<=0 then raise exception 'Cantidad inválida en la línea %',v_line; end if;
    if v_item_cut and (v_cut_length is null or v_cut_length<=0) then raise exception 'La línea % requiere una longitud de corte válida',v_line; end if;
    insert into erp_supply.order_items(
      order_id,line_number,sku,reference,description,quantity,unit,warehouse_location,requires_cut,
      requested_cut_length,dimensions,metadata
    ) values(
      v_order.id,coalesce(erp_supply.safe_integer(v_item->>'lineNumber'),v_line),nullif(trim(v_item->>'sku'),''),
      nullif(trim(v_item->>'reference'),''),trim(v_item->>'description'),v_quantity,
      coalesce(nullif(trim(v_item->>'unit'),''),'UND'),nullif(trim(v_item->>'warehouseLocation'),''),v_item_cut,
      v_cut_length,case when jsonb_typeof(coalesce(v_item->'dimensions','{}'::jsonb))='object' then coalesce(v_item->'dimensions','{}'::jsonb) else '{}'::jsonb end,
      case when jsonb_typeof(coalesce(v_item->'metadata','{}'::jsonb))='object' then coalesce(v_item->'metadata','{}'::jsonb) else '{}'::jsonb end
    );
  end loop;

  select * into v_task from erp_supply.create_task(v_order,v_initial,1);
  select * into v_order from erp_supply.orders where id=v_order.id;
  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,to_step_code,to_status,actor_profile_id,actor_role_code,idempotency_key,payload
  ) values(
    v_org,v_order.id,v_task.id,'ORDER_CREATED','CREATE',v_initial,v_order.status,v_actor,(erp_supply.current_roles())[1],p_idempotency_key,
    p_payload||jsonb_build_object('resolvedInitialStep',v_initial,'hasCreditArrears',v_has_credit_arrears,'heldByCashier',v_held_by_cashier)
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'currentStep',v_order.current_step_code,'status',v_order.status,'version',v_order.version);
exception
  when unique_violation then raise exception 'Ya existe un pedido con el número %',v_number;
end;
$$;

create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_invoice erp_supply.invoices%rowtype;
  v_file_id uuid:=erp_supply.safe_uuid(p_payload->>'driveFileRecordId');
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  if v_order.current_step_code='CAJA_FACTURACION' then
    if not (erp_supply.has_role('caja') or erp_supply.has_role('super_admin')) then
      raise exception 'Solo Caja puede registrar esta factura' using errcode='42501';
    end if;
    if v_order.order_type_code<>'PVN' then raise exception 'La facturación en Caja solo aplica a pedidos PVN'; end if;
    if v_file_id is null or not exists(
      select 1 from erp_supply.drive_files f
      where f.id=v_file_id and f.order_id=p_order_id and upper(f.file_category)='INVOICE'
    ) then raise exception 'Debe subir la factura PDF antes de guardarla'; end if;
  else
    if v_order.current_step_code<>'FACTURACION' and not erp_supply.has_role('super_admin') then raise exception 'El pedido no está en Facturación'; end if;
    if not (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para facturar' using errcode='42501'; end if;
  end if;

  if nullif(trim(p_payload->>'invoiceNumber'),'') is null then raise exception 'Número de factura requerido'; end if;
  insert into erp_supply.invoices(order_id,invoice_number,invoice_date,amount,currency,status,drive_file_id,registered_by,metadata)
  values(
    p_order_id,trim(p_payload->>'invoiceNumber'),coalesce(erp_supply.safe_date(p_payload->>'invoiceDate'),current_date),
    erp_supply.safe_numeric(p_payload->>'amount'),coalesce(nullif(trim(p_payload->>'currency'),''),'COP'),'REGISTERED',
    v_file_id,v_actor,
    (case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object' then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
      ||jsonb_build_object('registeredStep',v_order.current_step_code)
  ) returning * into v_invoice;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,'DOMAIN_RECORD','INVOICE',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('invoiceId',v_invoice.id,'invoiceNumber',v_invoice.invoice_number,'step',v_order.current_step_code));
  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

create or replace function erp_supply.validate_cash_invoice_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if new.step_code='CAJA_FACTURACION' and new.status='COMPLETED' and old.status<>'COMPLETED' then
    if not exists(select 1 from erp_supply.invoices i where i.order_id=new.order_id and i.status='REGISTERED') then
      raise exception 'Debe subir la factura antes de enviar el pedido a logística';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_cash_invoice_completion on erp_supply.order_tasks;
create trigger trg_validate_cash_invoice_completion
before update of status on erp_supply.order_tasks
for each row execute function erp_supply.validate_cash_invoice_completion();

commit;


-- ============================================================================
-- 020_picking_partial_rounds_v10_8.sql
-- ============================================================================
-- ERP Electroingeniería V10.8.1
-- Corrección: llamadas require_profile() ejecutadas mediante PERFORM en PL/pgSQL.
-- Alistamiento guiado, verificación línea a línea y rondas parciales del mismo pedido.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

create table if not exists erp_supply.picking_rounds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid not null references erp_supply.order_tasks(id) on delete cascade,
  round_no integer not null check (round_no > 0),
  status text not null check (status in ('COMPLETE','PARTIAL')),
  picked_profile_id uuid not null references erp_supply.profiles(id),
  total_lines integer not null default 0,
  found_lines integer not null default 0,
  missing_lines integer not null default 0,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  raw_seconds bigint not null default 0,
  business_seconds bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(order_id,round_no),
  unique(task_id)
);

create table if not exists erp_supply.picking_round_items (
  id uuid primary key default gen_random_uuid(),
  picking_round_id uuid not null references erp_supply.picking_rounds(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  result text not null check (result in ('FOUND','MISSING')),
  novelty text,
  quantity numeric(18,4) not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(picking_round_id,order_item_id),
  check (result='FOUND' or nullif(trim(novelty),'') is not null)
);

create index if not exists idx_picking_rounds_order on erp_supply.picking_rounds(order_id,round_no);
create index if not exists idx_picking_rounds_status on erp_supply.picking_rounds(organization_id,status,completed_at desc);
create index if not exists idx_picking_round_items_item on erp_supply.picking_round_items(order_item_id,created_at desc);

create or replace function public.erp_x_confirm_picking_round(
  p_order_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_round erp_supply.picking_rounds%rowtype;
  v_result jsonb;
  v_row jsonb;
  v_rows jsonb:=coalesce(p_payload->'items','[]'::jsonb);
  v_item erp_supply.order_items%rowtype;
  v_item_id uuid;
  v_seen uuid[]:='{}'::uuid[];
  v_round_no integer;
  v_pending integer;
  v_processed integer:=0;
  v_found integer:=0;
  v_missing integer:=0;
  v_found_cut_count integer:=0;
  v_status text;
  v_novelty text;
  v_started timestamptz;
  v_version integer;
  v_fulfillment jsonb;
  v_found_ids jsonb:='[]'::jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','update')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para confirmar Alistamiento' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)
  for update;

  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'ALISTAMIENTO' then raise exception 'El pedido no está en Alistamiento'; end if;
  if jsonb_typeof(v_rows)<>'array' or jsonb_array_length(v_rows)=0 then
    raise exception 'Debes verificar las líneas pendientes del pedido';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=v_order.id and step_code='ALISTAMIENTO'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  if not found then raise exception 'El pedido no tiene una tarea activa de Alistamiento'; end if;
  if v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not erp_supply.has_role('jefe_logistica')
     and not erp_supply.has_role('super_admin') then
    raise exception 'El pedido está siendo gestionado por otro usuario' using errcode='42501';
  end if;

  select count(*) into v_pending
  from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.item_status not in('FULFILLED','CANCELLED');

  if v_pending=0 then raise exception 'El pedido no tiene mercancía pendiente de verificar'; end if;
  if jsonb_array_length(v_rows)<>v_pending then
    raise exception 'Debes marcar todas las líneas pendientes antes de enviar a facturación';
  end if;

  select coalesce(max(round_no),0)+1 into v_round_no
  from erp_supply.picking_rounds where order_id=v_order.id;

  v_started:=coalesce(
    (select min(s.started_at) from erp_supply.task_sessions s where s.task_id=v_task.id and s.ended_at is null),
    v_task.started_at,
    now()
  );

  insert into erp_supply.picking_rounds(
    organization_id,order_id,task_id,round_no,status,picked_profile_id,
    total_lines,found_lines,missing_lines,started_at,completed_at,metadata
  ) values(
    v_org,v_order.id,v_task.id,v_round_no,'COMPLETE',v_actor,
    v_pending,0,0,v_started,now(),jsonb_build_object('source','ALISTAMIENTO_V10_8')
  ) returning * into v_round;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    if jsonb_typeof(v_row)<>'object' then raise exception 'Resultado de línea inválido'; end if;
    v_item_id:=erp_supply.safe_uuid(v_row->>'orderItemId');
    if v_item_id is null or v_item_id=any(v_seen) then raise exception 'Hay una línea inválida o repetida'; end if;

    select * into v_item
    from erp_supply.order_items
    where id=v_item_id and order_id=v_order.id
      and coalesce(metadata->>'receptionActive','true')<>'false'
      and item_status not in('FULFILLED','CANCELLED')
    for update;
    if not found then raise exception 'Una línea ya no está pendiente en este pedido'; end if;

    v_status:=upper(coalesce(nullif(trim(v_row->>'result'),''),''));
    if v_status not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado en todas las líneas'; end if;
    v_novelty:=nullif(trim(v_row->>'novelty'),'');
    if v_status='MISSING' and v_novelty is null then
      raise exception 'Explica por qué no se encontró la línea %',v_item.line_number;
    end if;

    insert into erp_supply.picking_round_items(
      picking_round_id,order_item_id,result,novelty,quantity,metadata
    ) values(
      v_round.id,v_item.id,v_status,v_novelty,v_item.quantity,
      jsonb_build_object('lineNumber',v_item.line_number,'sku',v_item.sku,'reference',v_item.reference)
    );

    if v_status='FOUND' then
      v_found:=v_found+1;
      if v_item.requires_cut then v_found_cut_count:=v_found_cut_count+1; end if;
      v_found_ids:=v_found_ids||jsonb_build_array(v_item.id);
      update erp_supply.order_items
      set item_status='FULFILLED',
          metadata=metadata||jsonb_build_object(
            'fulfillmentStatus','FULFILLED','fulfilledRound',v_round_no,
            'fulfilledAt',now(),'fulfilledBy',v_actor,'lastNovelty',null
          ),
          updated_at=now()
      where id=v_item.id;
    else
      v_missing:=v_missing+1;
      update erp_supply.order_items
      set item_status='PENDING',
          metadata=metadata||jsonb_build_object(
            'fulfillmentStatus','PENDING','lastCheckedRound',v_round_no,
            'lastCheckedAt',now(),'lastCheckedBy',v_actor,'lastNovelty',v_novelty
          ),
          updated_at=now()
      where id=v_item.id;

      insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
      values(
        v_order.id,v_actor,'NOVELTY','INTERNAL',
        format('Línea %s no encontrada: %s',v_item.line_number,v_novelty),
        jsonb_build_object('source','ALISTAMIENTO','roundNo',v_round_no,'orderItemId',v_item.id)
      );
    end if;

    v_processed:=v_processed+1;
    v_seen:=array_append(v_seen,v_item.id);
  end loop;

  if v_processed<>v_pending then raise exception 'No se verificaron todas las líneas pendientes'; end if;
  v_status:=case when v_missing>0 then 'PARTIAL' else 'COMPLETE' end;

  update erp_supply.picking_rounds
  set status=v_status,found_lines=v_found,missing_lines=v_missing,
      metadata=metadata||jsonb_build_object('foundItemIds',v_found_ids)
  where id=v_round.id returning * into v_round;

  update erp_supply.task_checklist
  set completed=true,completed_by=v_actor,completed_at=now(),
      note=case when v_status='PARTIAL'
        then format('Ronda %s enviada con %s línea(s) pendiente(s)',v_round_no,v_missing)
        else format('Ronda %s verificada completamente',v_round_no) end,
      metadata=metadata||jsonb_build_object('source','ALISTAMIENTO_V10_8','roundNo',v_round_no,'result',v_status)
  where task_id=v_task.id and required;

  v_fulfillment:=
    (case when jsonb_typeof(coalesce(v_order.metadata->'fulfillment','{}'::jsonb))='object'
      then coalesce(v_order.metadata->'fulfillment','{}'::jsonb) else '{}'::jsonb end)
    ||jsonb_build_object(
      'status',v_status,
      'partialLabel',(v_status='PARTIAL'),
      'roundCount',v_round_no,
      'activeRound',v_round_no,
      'pendingItemCount',v_missing,
      'foundItemCount',v_found,
      'lastPickingAt',now(),
      'lastPickingBy',v_actor,
      'currentShipmentItemIds',v_found_ids,
      'currentShipmentRequiresCut',(v_found_cut_count>0),
      'firstPartialAt',case
        when v_status='PARTIAL' then coalesce(v_order.metadata#>'{fulfillment,firstPartialAt}',to_jsonb(now()))
        else v_order.metadata#>'{fulfillment,firstPartialAt}' end,
      'completedAt',case when v_status='COMPLETE' then to_jsonb(now()) else 'null'::jsonb end
    );

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('fulfillment',v_fulfillment),
      requires_cut=(v_found_cut_count>0),
      version=version+1,updated_at=now()
  where id=v_order.id returning version into v_version;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'DOMAIN_RECORD','PICKING_ROUND',
    'ALISTAMIENTO','ALISTAMIENTO',v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('roundId',v_round.id,'roundNo',v_round_no,'result',v_status,
      'foundLines',v_found,'missingLines',v_missing,'foundItemIds',v_found_ids,
      'currentShipmentRequiresCut',(v_found_cut_count>0))
  );

  v_result:=erp_supply.execute_action_internal(
    v_order.id,'COMPLETE',
    jsonb_build_object(
      'resultCode',case when v_status='PARTIAL' then 'PICKING_PARTIAL' else 'PICKING_COMPLETE' end,
      'detail',case when v_status='PARTIAL'
        then format('Alistamiento parcial: %s encontrada(s), %s pendiente(s)',v_found,v_missing)
        else format('Alistamiento completo: %s línea(s) encontrada(s)',v_found) end,
      'pickingRoundId',v_round.id,'roundNo',v_round_no,
      'foundLines',v_found,'missingLines',v_missing,'partial',(v_status='PARTIAL'),
      'currentShipmentRequiresCut',(v_found_cut_count>0)
    ),
    v_actor,false,v_version,
    'PICKING-ROUND-'||v_order.id::text||'-'||v_round_no::text
  );

  update erp_supply.picking_rounds r
  set raw_seconds=t.raw_seconds,business_seconds=t.business_seconds,
      completed_at=coalesce(t.completed_at,r.completed_at)
  from erp_supply.order_tasks t where r.id=v_round.id and t.id=r.task_id;

  return v_result||jsonb_build_object(
    'pickingConfirmed',true,'roundId',v_round.id,'roundNo',v_round_no,
    'result',v_status,'foundLines',v_found,'missingLines',v_missing,
    'partial',(v_status='PARTIAL')
  );
end;
$$;

create or replace function public.erp_x_resume_partial_picking(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_sequence integer;
  v_pending integer;
  v_fulfillment jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','update')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then raise exception 'No autorizado para retomar Alistamiento' using errcode='42501'; end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)
  for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  select count(*) into v_pending from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.item_status not in('FULFILLED','CANCELLED');

  if coalesce(v_order.metadata#>>'{fulfillment,status}','')<>'PARTIAL' or v_pending=0 then
    raise exception 'El pedido no tiene mercancía parcial pendiente';
  end if;
  if exists(select 1 from erp_supply.order_tasks t where t.order_id=v_order.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')) then
    raise exception 'La salida parcial actual debe finalizar antes de retomar lo pendiente';
  end if;
  if v_order.status<>'CLOSED' then
    raise exception 'El pedido parcial todavía no ha terminado su salida anterior';
  end if;

  select coalesce(max(sequence_no),0)+1 into v_sequence from erp_supply.order_tasks where order_id=v_order.id;
  v_fulfillment:=coalesce(v_order.metadata->'fulfillment','{}'::jsonb)||jsonb_build_object(
    'status','PARTIAL','partialLabel',true,'pendingItemCount',v_pending,
    'resumeRequestedAt',now(),'resumeRequestedBy',v_actor
  );
  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('fulfillment',v_fulfillment),
      closed_at=null,version=version+1,updated_at=now()
  where id=v_order.id returning * into v_order;

  select * into v_task from erp_supply.create_task(v_order,'ALISTAMIENTO',v_sequence);

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'WORKFLOW_ACTION','PICKING_RESUME',
    'CLOSED','ALISTAMIENTO','CLOSED',v_task.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('pendingItems',v_pending,'sequenceNo',v_sequence)
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'currentStep','ALISTAMIENTO',
    'status',v_task.status,'pendingItems',v_pending,'version',(select version from erp_supply.orders where id=v_order.id));
end;
$$;

create or replace function public.erp_x_picking_pending(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),250);
  v_total bigint;
  v_items jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','read')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
    or erp_supply.has_role('auditoria')
  ) then raise exception 'No autorizado para consultar parciales' using errcode='42501'; end if;

  with rows as (
    select o.id
    from erp_supply.orders o
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'
      and exists(select 1 from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED'))
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
  ) select count(*) into v_total from rows;

  with rows as (
    select o.*,
      (select count(*) from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED')) pending_count,
      (select count(*) from erp_supply.picking_rounds r where r.order_id=o.id) round_count,
      not exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED'))
        and o.status='CLOSED' can_resume,
      coalesce((select p.display_name from erp_supply.profiles p where p.id=erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')),'Auxiliar asignado') picking_name,
      erp_supply.business_seconds_between(v_org,
        coalesce(erp_supply.safe_timestamptz(o.metadata#>>'{fulfillment,firstPartialAt}'),o.updated_at),now()) age_seconds
    from erp_supply.orders o
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'
      and exists(select 1 from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED'))
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
    order by coalesce(erp_supply.safe_timestamptz(o.metadata#>>'{fulfillment,firstPartialAt}'),o.updated_at)
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'clientName',client_name,'orderType',order_type_code,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep','ALISTAMIENTO',
    'stepName','Alistamiento pendiente','status',case when can_resume then 'WAITING' else status end,
    'priority',priority,'assigneeName',picking_name,'ageBusinessSeconds',age_seconds,
    'pendingItemCount',pending_count,'pickingRoundCount',round_count,'fulfillmentStatus','PARTIAL',
    'canResume',can_resume,'actualStep',current_step_code,'actualStatus',status,'version',version
  )),'[]'::jsonb) into v_items from rows;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object(
    'page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer
  ),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_partial_fulfillment_metrics(
  p_date_from date default current_date-30,
  p_date_to date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  perform erp_supply.require_profile();
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Rango de fechas inválido'; end if;
  return jsonb_build_object(
    'summary',jsonb_build_object(
      'partialPending',(select count(*) from erp_supply.orders o where o.organization_id=v_org and not o.is_test
        and erp_supply.can_view_order(o.id) and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'),
      'completedAfterPartial',(select count(*) from erp_supply.orders o where o.organization_id=v_org and not o.is_test
        and erp_supply.can_view_order(o.id) and coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE'
        and o.metadata#>>'{fulfillment,firstPartialAt}' is not null)
    ),
    'orders',(select coalesce(jsonb_agg(to_jsonb(x) order by x."firstPartialAt" desc),'[]'::jsonb) from (
      select o.id,o.order_number "orderNumber",o.client_name "clientName",
        coalesce(o.metadata#>>'{fulfillment,status}','PARTIAL') status,
        count(r.id)::integer "roundCount",
        coalesce((select count(*) from erp_supply.order_items i where i.order_id=o.id and i.item_status not in('FULFILLED','CANCELLED')),0)::integer "pendingItemCount",
        min(r.started_at) "firstStartedAt",
        min(r.completed_at) filter(where r.status='PARTIAL') "firstPartialAt",
        max(r.completed_at) filter(where coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE') "completedAt",
        round((coalesce((array_agg(r.business_seconds order by r.round_no))[1],0)/3600.0)::numeric,2) "partialHours",
        round((erp_supply.business_seconds_between(v_org,min(r.started_at),
          case when coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE' then max(r.completed_at) else now() end)/3600.0)::numeric,2) "realHours"
      from erp_supply.orders o
      join erp_supply.picking_rounds r on r.order_id=o.id
      where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
        and exists(select 1 from erp_supply.picking_rounds rp where rp.order_id=o.id and rp.status='PARTIAL')
        and r.completed_at::date between p_date_from and p_date_to
      group by o.id,o.order_number,o.client_name,o.metadata
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Mantiene la etiqueta parcial en todas las colas sin crear un segundo pedido.
create or replace function public.erp_x_list_orders(
  p_search text default null,
  p_step text default null,
  p_status text default null,
  p_order_type text default null,
  p_route text default null,
  p_assignment text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 50,
  p_include_history boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),250); v_total bigint; v_items jsonb;
begin
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o
    left join erp_supply.profiles p on p.id=o.current_assignee_id
    join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
  ) select count(*) into v_total from filtered;

  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.updated_at desc
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'externalReference',external_reference,'orderType',order_type_code,'clientName',client_name,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep',current_step_code,'stepName',step_name,
    'status',status,'priority',priority,'requiresCut',requires_cut,'requiresPurchase',requires_purchase,'assigneeId',current_assignee_id,
    'assigneeName',assignee_name,'roleCode',current_role_code,'ageBusinessSeconds',age_business_seconds,
    'slaExceeded',(sla_hours is not null and age_business_seconds>sla_hours*3600),'version',version,'isHistory',is_history,'createdAt',created_at,'updatedAt',updated_at,
    'fulfillmentStatus',metadata#>>'{fulfillment,status}',
    'partialLabel',coalesce((metadata#>>'{fulfillment,partialLabel}')::boolean,false),
    'pendingItemCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,pendingItemCount}'),0),
    'pickingRoundCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,roundCount}'),0)
  )),'[]'::jsonb) into v_items from filtered;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int),'generatedAt',now());
end;
$$;

-- El expediente incluye rondas e historial de verificación.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
begin
  perform erp_supply.require_profile();
  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;

  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb)
      from erp_supply.order_items i where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'metadata',c.metadata,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'pickingRounds',(select coalesce(jsonb_agg(to_jsonb(r) order by r.round_no),'[]'::jsonb) from erp_supply.picking_rounds r where r.order_id=p_order_id),
    'pickingRoundItems',(select coalesce(jsonb_agg(to_jsonb(ri) order by r.round_no,i.line_number),'[]'::jsonb)
      from erp_supply.picking_round_items ri join erp_supply.picking_rounds r on r.id=ri.picking_round_id
      join erp_supply.order_items i on i.id=ri.order_item_id where r.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

revoke all on function public.erp_x_confirm_picking_round(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_resume_partial_picking(uuid) from public,anon,authenticated;
revoke all on function public.erp_x_picking_pending(text,integer,integer) from public,anon,authenticated;
revoke all on function public.erp_x_partial_fulfillment_metrics(date,date) from public,anon,authenticated;
grant execute on function public.erp_x_confirm_picking_round(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_resume_partial_picking(uuid) to authenticated;
grant execute on function public.erp_x_picking_pending(text,integer,integer) to authenticated;
grant execute on function public.erp_x_partial_fulfillment_metrics(date,date) to authenticated;
grant execute on function public.erp_x_list_orders(text,text,text,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;

commit;


-- ============================================================================
-- 021_billing_microprocess_v10_9.sql
-- ============================================================================
-- ERP Supply Enterprise V10.9
-- Microproceso de Facturación: PVN/PNV a Caja, factura normal para PVC/PVE y Anexo PVP.

begin;

-- La lista de Facturación usa una denominación neutra porque PVP no carga factura.
update erp_supply.checklist_templates
set label='Factura o Anexo PVP cargado',required=true,active=true
where step_code='FACTURACION' and item_code='INVOICE';

update erp_supply.checklist_templates
set label='Documento validado para envío a despacho',required=true,active=true
where step_code='FACTURACION' and item_code='COMMERCIAL_MATCH';

update erp_supply.task_checklist c
set label=case c.item_code
  when 'INVOICE' then 'Anexo PVP cargado'
  when 'COMMERCIAL_MATCH' then 'Anexo PVP validado para despacho'
  else c.label end
from erp_supply.order_tasks t
join erp_supply.orders o on o.id=t.order_id
where c.task_id=t.id
  and t.step_code='FACTURACION'
  and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  and upper(o.order_type_code)='PVP'
  and c.item_code in('INVOICE','COMMERCIAL_MATCH');

-- El tipo operativo real es PVN. Se acepta PNV como alias defensivo para datos históricos.
create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case p_current_step
    when 'CARTERA' then 'RECEPCION_PEDIDO'
    when 'CAJA' then 'RECEPCION_PEDIDO'
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case
      when p_requires_cut then 'CORTE'
      when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CORTE' then case
      when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CAJA_FACTURACION' then p_delivery_route
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

-- Toda factura nueva debe estar vinculada al archivo cargado en Google Drive
-- y a la tarea activa de facturación de la ronda actual.
create or replace function public.erp_x_save_invoice(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_invoice erp_supply.invoices%rowtype;
  v_file_id uuid:=erp_supply.safe_uuid(p_payload->>'driveFileRecordId');
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=erp_supply.current_org_id()
    and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code=v_order.current_step_code
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1;
  if not found then raise exception 'El pedido no tiene una tarea activa de facturación'; end if;

  if upper(v_order.order_type_code)='PVP' then
    raise exception 'Los pedidos PVP deben cargar Anexo PVP, no factura';
  end if;

  if v_order.current_step_code='CAJA_FACTURACION' then
    if not (erp_supply.has_role('caja') or erp_supply.has_role('super_admin')) then
      raise exception 'Solo Caja puede registrar esta factura' using errcode='42501';
    end if;
    if upper(v_order.order_type_code) not in('PVN','PNV') then
      raise exception 'La facturación en Caja solo aplica a pedidos pagados de contado';
    end if;
  else
    if v_order.current_step_code<>'FACTURACION' and not erp_supply.has_role('super_admin') then
      raise exception 'El pedido no está en Facturación';
    end if;
    if not (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then
      raise exception 'No autorizado para facturar' using errcode='42501';
    end if;
  end if;

  if v_file_id is null or not exists(
    select 1
    from erp_supply.drive_files f
    where f.id=v_file_id
      and f.order_id=p_order_id
      and f.task_id=v_task.id
      and upper(f.file_category)='INVOICE'
  ) then
    raise exception 'Debe subir la factura mediante Google Drive antes de guardarla';
  end if;

  if nullif(trim(p_payload->>'invoiceNumber'),'') is null then
    raise exception 'Número de factura requerido';
  end if;

  insert into erp_supply.invoices(
    order_id,invoice_number,invoice_date,amount,currency,status,
    drive_file_id,registered_by,metadata
  ) values(
    p_order_id,
    trim(p_payload->>'invoiceNumber'),
    coalesce(erp_supply.safe_date(p_payload->>'invoiceDate'),current_date),
    erp_supply.safe_numeric(p_payload->>'amount'),
    coalesce(nullif(trim(p_payload->>'currency'),''),'COP'),
    'REGISTERED',v_file_id,v_actor,
    (case when jsonb_typeof(coalesce(p_payload->'metadata','{}'::jsonb))='object'
      then coalesce(p_payload->'metadata','{}'::jsonb) else '{}'::jsonb end)
      ||jsonb_build_object('registeredStep',v_order.current_step_code,'taskId',v_task.id)
  ) returning * into v_invoice;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_order.organization_id,p_order_id,v_task.id,'DOMAIN_RECORD','INVOICE',
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'invoiceId',v_invoice.id,
      'invoiceNumber',v_invoice.invoice_number,
      'step',v_order.current_step_code,
      'taskId',v_task.id
    )
  );

  return jsonb_build_object('success',true,'invoice',to_jsonb(v_invoice));
end;
$$;

-- Corrige manualmente un PVN que haya llegado a Facturación de Logística.
create or replace function public.erp_x_route_billing_to_cash(
  p_order_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_new_task erp_supply.order_tasks%rowtype;
  v_sequence integer;
  v_now timestamptz:=now();
  v_raw bigint:=0;
  v_business bigint:=0;
begin
  if not (
    erp_supply.can_access_module('billing','update')
    or erp_supply.has_role('coordinador_logistico')
    or erp_supply.has_role('despacho_nacional')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para enviar el pedido a Caja' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=v_org
    and erp_supply.can_view_order(id)
  for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'FACTURACION' then
    raise exception 'El pedido no está en Facturación de Logística';
  end if;
  if upper(v_order.order_type_code) not in('PVN','PNV') then
    raise exception 'Solo los pedidos pagados de contado pueden enviarse a Caja';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code='FACTURACION'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;
  if not found then raise exception 'No existe una tarea activa de Facturación'; end if;

  update erp_supply.task_sessions s
  set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from (v_now-s.started_at)))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_org,s.started_at,v_now),
      note=coalesce(nullif(trim(p_reason),''),'Reenrutado manualmente a Caja')
  where s.task_id=v_task.id and s.ended_at is null;

  select coalesce(sum(raw_seconds),0),coalesce(sum(business_seconds),0)
  into v_raw,v_business
  from erp_supply.task_sessions
  where task_id=v_task.id;

  update erp_supply.order_tasks
  set status='CANCELLED',completed_at=v_now,
      raw_seconds=v_raw,business_seconds=v_business,
      result_code='ROUTED_TO_CASH',
      result_detail=coalesce(nullif(trim(p_reason),''),'Pedido pagado de contado enviado a Caja'),
      metadata=metadata||jsonb_build_object(
        'routedToCashAt',v_now,
        'routedToCashBy',v_actor,
        'routingVersion','10.9'
      )
  where id=v_task.id;

  select coalesce(max(sequence_no),0)+1 into v_sequence
  from erp_supply.order_tasks where order_id=p_order_id;

  select * into v_new_task
  from erp_supply.create_task(v_order,'CAJA_FACTURACION',v_sequence);

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object(
        'billingRouting','CAJA_FACTURACION',
        'billingRoutedManually',true,
        'billingRoutedAt',v_now,
        'billingRoutedBy',v_actor,
        'routingVersion','10.9'
      ),
      updated_at=v_now
  where id=p_order_id;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,p_order_id,v_task.id,'ROUTE_CORRECTION','SEND_TO_CASH',
    'FACTURACION','CAJA_FACTURACION',v_order.status,v_new_task.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'reason',coalesce(nullif(trim(p_reason),''),'Pedido pagado de contado'),
      'cancelledTaskId',v_task.id,
      'newTaskId',v_new_task.id,
      'routingVersion','10.9'
    )
  );

  return jsonb_build_object(
    'success',true,
    'orderId',p_order_id,
    'currentStep','CAJA_FACTURACION',
    'taskId',v_new_task.id
  );
end;
$$;

-- Control transaccional por documento y por tarea/ronda.
create or replace function erp_supply.validate_task_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_missing integer;
begin
  if new.status<>'COMPLETED' or old.status='COMPLETED' then return new; end if;
  select * into v_order from erp_supply.orders where id=new.order_id;
  if v_order.is_test then return new; end if;

  select count(*) into v_missing
  from erp_supply.task_checklist
  where task_id=new.id and required and not completed;
  if v_missing>0 then
    raise exception 'No puede finalizar: quedan % controles obligatorios sin completar',v_missing;
  end if;

  case new.step_code
    when 'CARTERA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CARTERA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Cartera';
      end if;
    when 'CAJA' then
      if not exists(select 1 from erp_supply.financial_validations where order_id=v_order.id and validation_type='CAJA' and decision='APPROVED') then
        raise exception 'Debe registrar una validación aprobada de Caja';
      end if;
    when 'COMPRAS' then
      if not exists(select 1 from erp_supply.purchase_orders where order_id=v_order.id and status in('ISSUED','CONFIRMED','PARTIAL','RECEIVED')) then
        raise exception 'Debe registrar una orden de compra válida';
      end if;
    when 'RECEPCION_MERCANCIA' then
      if not exists(select 1 from erp_supply.receipts where order_id=v_order.id and status in('PARTIAL','CONFORMING','CLOSED')) then
        raise exception 'Debe registrar la recepción física y su resultado de calidad';
      end if;
    when 'CORTE' then
      if v_order.requires_cut and not exists(select 1 from erp_supply.cut_jobs where order_id=v_order.id and status='COMPLETED') then
        raise exception 'Debe registrar al menos un corte completado';
      end if;
    when 'FACTURACION' then
      if upper(v_order.order_type_code)='PVP' then
        if not exists(
          select 1 from erp_supply.drive_files f
          where f.order_id=v_order.id and f.task_id=new.id and upper(f.file_category)='PVP_ANNEX'
        ) then raise exception 'Debe cargar el Anexo PVP antes de enviar el pedido a despacho'; end if;
      else
        if not exists(
          select 1
          from erp_supply.invoices i
          join erp_supply.drive_files f on f.id=i.drive_file_id
          where i.order_id=v_order.id and i.status='REGISTERED' and f.task_id=new.id
        ) then raise exception 'Debe cargar la factura antes de enviar el pedido a despacho'; end if;
      end if;
    when 'CLIENT_POINT' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'CLIENT_PICKUP' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'LOCAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega'; end if;
    when 'NATIONAL_DISPATCH' then
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then raise exception 'Debe confirmar la entrega nacional'; end if;
    when 'CLOSURE' then
      if upper(v_order.order_type_code)='PVP' then
        if not exists(select 1 from erp_supply.drive_files where order_id=v_order.id and upper(file_category)='PVP_ANNEX') then
          raise exception 'El pedido no tiene Anexo PVP';
        end if;
      elsif not exists(select 1 from erp_supply.invoices where order_id=v_order.id and status='REGISTERED') then
        raise exception 'El pedido no tiene factura registrada';
      end if;
      if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='DELIVERED') then
        raise exception 'El pedido no tiene entrega confirmada';
      end if;
    else null;
  end case;
  return new;
end;
$$;

create or replace function erp_supply.validate_cash_invoice_completion()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if new.step_code='CAJA_FACTURACION' and new.status='COMPLETED' and old.status<>'COMPLETED' then
    if not exists(
      select 1
      from erp_supply.invoices i
      join erp_supply.drive_files f on f.id=i.drive_file_id
      where i.order_id=new.order_id and i.status='REGISTERED' and f.task_id=new.id
    ) then
      raise exception 'Debe subir la factura de esta gestión antes de enviar el pedido a despacho';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function public.erp_x_save_invoice(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_route_billing_to_cash(uuid,text) from public,anon,authenticated;
grant execute on function public.erp_x_save_invoice(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_route_billing_to_cash(uuid,text) to authenticated;

commit;


-- ============================================================================
-- 022_multi_active_sessions_v10_9_3.sql
-- ============================================================================
-- ERP EI V10.9.3
-- Permite que un mismo usuario mantenga varias sesiones de trabajo activas,
-- conservando una sola sesión abierta por tarea/pedido.

begin;

-- Elimina únicamente la restricción global por usuario.
drop index if exists erp_supply.uq_open_session_per_user;

-- Conserva y reafirma el bloqueo por tarea.
create unique index if not exists uq_open_session_per_task
  on erp_supply.task_sessions(task_id)
  where ended_at is null;

create or replace function erp_supply.execute_action_internal(
  p_order_id uuid,
  p_action text,
  p_payload jsonb,
  p_actor uuid,
  p_bypass_permissions boolean default false,
  p_expected_version integer default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_action text := upper(trim(coalesce(p_action,'')));
  v_next text;
  v_new_task erp_supply.order_tasks%rowtype;
  v_target uuid;
  v_session erp_supply.task_sessions%rowtype;
  v_now timestamptz := now();
  v_business bigint := 0;
  v_event_id bigint;
  v_actor_role text;
  v_from_step text;
  v_from_status text;
  v_scheduled_at timestamptz;
begin
  if v_action='' then raise exception 'Acción requerida'; end if;
  if p_actor is null then raise exception 'Actor requerido' using errcode='42501'; end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then raise exception 'Pedido no encontrado'; end if;
  v_from_step:=v_order.current_step_code;
  v_from_status:=v_order.status;

  if p_expected_version is not null and v_order.version<>p_expected_version then
    raise exception 'El pedido cambió mientras estaba abierto. Actualice la pantalla.' using errcode='40001';
  end if;
  if p_idempotency_key is not null and exists(
    select 1 from erp_supply.order_events where organization_id=v_order.organization_id and idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object('success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=v_order.id and status in ('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  select pr.role_code into v_actor_role from erp_supply.profile_roles pr
  where pr.profile_id=p_actor order by pr.is_primary desc,pr.role_code limit 1;

  if v_action not in ('COMMENT','REQUEST_APPROVAL') and v_task.id is null and v_order.status not in ('CLOSED','CANCELLED') then
    raise exception 'El pedido no tiene una tarea operativa activa';
  end if;

  if not p_bypass_permissions then
    if v_action in ('CLAIM','ASSIGN','START','COMPLETE','WAIT','BLOCK','RESUME')
       and not erp_supply.actor_can(p_actor,v_order.current_step_code,v_action,v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para ejecutar % en %',v_action,v_order.current_step_code using errcode='42501';
    end if;
    if v_action='NO_DELIVERY' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para registrar no entrega' using errcode='42501';
    end if;
    if v_action='REPROGRAM' and not erp_supply.actor_can(p_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
      raise exception 'El usuario no está autorizado para reprogramar la entrega' using errcode='42501';
    end if;
  end if;

  if v_action='CLAIM' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede reclamarse en su estado actual'; end if;
    if v_task.assigned_profile_id is not null and v_task.assigned_profile_id<>p_actor and not p_bypass_permissions
       and not exists(select 1 from erp_supply.profile_roles pr join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_task.step_code where pr.profile_id=p_actor and sr.can_override) then
      raise exception 'La tarea ya está asignada a otro responsable';
    end if;
    update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=coalesce(assigned_at,v_now),status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=p_actor,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='ASSIGN' then
    begin v_target := nullif(p_payload->>'profileId','')::uuid; exception when others then raise exception 'profileId inválido'; end;
    if v_target is null then raise exception 'Debe seleccionar un responsable'; end if;
    if not exists(
      select 1 from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr on sr.role_code=pr.role_code and sr.step_code=v_order.current_step_code and sr.can_view
      where p.id=v_target and p.organization_id=v_order.organization_id and p.active
    ) then raise exception 'El responsable no está habilitado para la etapa %',v_order.current_step_code; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'No puede reasignar una tarea con sesión de trabajo activa'; end if;
    update erp_supply.order_tasks set assigned_profile_id=v_target,assigned_at=v_now,status='ASSIGNED' where id=v_task.id returning * into v_task;
    update erp_supply.orders set current_assignee_id=v_target,status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='START' then
    if v_task.status not in ('QUEUED','ASSIGNED') then raise exception 'La tarea no puede iniciarse en su estado actual'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión de trabajo activa'; end if;
    if v_task.assigned_profile_id is null then
      update erp_supply.order_tasks set assigned_profile_id=p_actor,assigned_at=v_now where id=v_task.id;
    end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action in ('WAIT','BLOCK') then
    if v_task.status<>'IN_PROGRESS' then raise exception 'Solo una tarea en proceso puede ponerse en espera o bloqueo'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    update erp_supply.order_tasks set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,
      blocked_at=case when v_action='BLOCK' then v_now else blocked_at end,
      result_detail=coalesce(nullif(p_payload->>'reason',''),nullif(p_payload->>'detail',''),result_detail)
    where id=v_task.id returning * into v_task;
    update erp_supply.orders set status=case when v_action='WAIT' then 'WAITING' else 'BLOCKED' end,version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='RESUME' then
    if v_task.status not in ('WAITING','BLOCKED') then raise exception 'La tarea no está en espera o bloqueo'; end if;
    if exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea ya tiene una sesión activa'; end if;
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note) values(v_task.id,p_actor,v_now,p_payload->>'detail') returning * into v_session;
    update erp_supply.order_tasks set status='IN_PROGRESS',assigned_profile_id=coalesce(assigned_profile_id,p_actor) where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='IN_PROGRESS',current_assignee_id=coalesce(current_assignee_id,p_actor),version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMPLETE' then
    if not p_bypass_permissions and v_task.status<>'IN_PROGRESS' then raise exception 'Debe iniciar la tarea antes de finalizarla'; end if;
    if not p_bypass_permissions and not exists(select 1 from erp_supply.task_sessions where task_id=v_task.id and ended_at is null) then raise exception 'La tarea no tiene una sesión activa para finalizar'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    select coalesce(sum(business_seconds),0) into v_business from erp_supply.task_sessions where task_id=v_task.id;
    update erp_supply.order_tasks set status='COMPLETED',completed_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-coalesce(started_at,created_at)))::bigint),
      business_seconds=v_business,result_code=coalesce(nullif(p_payload->>'resultCode',''),'COMPLETED'),result_detail=p_payload->>'detail',metadata=metadata||coalesce(p_payload,'{}'::jsonb)
    where id=v_task.id returning * into v_task;

    v_next:=erp_supply.next_step(v_order.current_step_code,v_order.order_type_code,v_order.payment_condition_code,v_order.delivery_route_code,v_order.requires_cut,v_order.requires_purchase);
    if v_next='CLOSED' then
      update erp_supply.orders set current_step_code='CLOSED',status='CLOSED',closed_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
    else
      select * into v_new_task from erp_supply.create_task(v_order,v_next,v_task.sequence_no+1);
      select * into v_order from erp_supply.orders where id=v_order.id;
    end if;

  elsif v_action='NO_DELIVERY' then
    if v_order.current_step_code not in ('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then raise exception 'La no entrega solo aplica en despacho o entrega'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo de no entrega'; end if;
    update erp_supply.task_sessions s set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now)
    where s.task_id=v_task.id and s.ended_at is null;
    insert into erp_supply.deliveries(order_id,route_code,status,no_delivery_reason,assigned_profile_id,metadata)
    values(v_order.id,v_order.delivery_route_code,'NOT_DELIVERED',trim(p_payload->>'reason'),p_actor,p_payload);
    update erp_supply.order_tasks set status='WAITING',result_code='NO_DELIVERY',result_detail=trim(p_payload->>'reason') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='WAITING',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='REPROGRAM' then
    begin v_scheduled_at:=nullif(p_payload->>'scheduledAt','')::timestamptz; exception when others then raise exception 'Fecha de reprogramación inválida'; end;
    if v_scheduled_at is null or v_scheduled_at<=v_now then raise exception 'La nueva fecha debe ser futura'; end if;
    if not exists(select 1 from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED') then raise exception 'No existe una no entrega pendiente de reprogramación'; end if;
    update erp_supply.deliveries set status='REPROGRAMMED',scheduled_at=v_scheduled_at,metadata=metadata||p_payload,updated_at=v_now
    where id=(select id from erp_supply.deliveries where order_id=v_order.id and status='NOT_DELIVERED' order by created_at desc limit 1);
    update erp_supply.order_tasks set status='ASSIGNED',result_detail=coalesce(nullif(p_payload->>'detail',''),'Entrega reprogramada') where id=v_task.id returning * into v_task;
    update erp_supply.orders set status='ASSIGNED',version=version+1 where id=v_order.id returning * into v_order;

  elsif v_action='COMMENT' then
    if nullif(trim(p_payload->>'body'),'') is null then raise exception 'Debe escribir el comentario'; end if;
    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_order.id,p_actor,upper(coalesce(nullif(p_payload->>'commentType',''),'GENERAL')),upper(coalesce(nullif(p_payload->>'visibility',''),'ORDER')),trim(p_payload->>'body'),coalesce(p_payload->'metadata','{}'::jsonb));

  elsif v_action='REQUEST_APPROVAL' then
    insert into erp_supply.approval_requests(organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload)
    values(v_order.organization_id,v_order.id,upper(p_payload->>'requestType'),p_actor,coalesce(nullif(p_payload->>'assignedRole',''),'jefe_logistica'),trim(p_payload->>'reason'),p_payload);

  else
    raise exception 'Acción no reconocida: %',v_action;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,idempotency_key,payload)
  values(v_order.organization_id,v_order.id,coalesce(v_task.id,v_new_task.id),'WORKFLOW_ACTION',v_action,
    v_from_step,v_order.current_step_code,v_from_status,v_order.status,p_actor,v_actor_role,p_idempotency_key,coalesce(p_payload,'{}'::jsonb))
  returning id into v_event_id;

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_order.organization_id,p_actor,v_action,'ORDER',v_order.id::text,
    jsonb_build_object('step',v_from_step,'status',v_from_status,'version',coalesce(p_expected_version,v_order.version-1)),
    jsonb_build_object('step',v_order.current_step_code,'status',v_order.status,'version',v_order.version),
    jsonb_build_object('eventId',v_event_id,'idempotencyKey',p_idempotency_key));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_order.organization_id,'ORDER_ACTION','ORDER',v_order.id,jsonb_build_object('eventId',v_event_id,'action',v_action,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'orderId',v_order.id,'orderNumber',v_order.order_number,'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'eventId',v_event_id);
end;
$$;

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

  union all select '05_CONCURRENCIA','Múltiples pedidos activos por operario',
    to_regclass('erp_supply.uq_open_session_per_user') is null,
    'Sesiones simultáneas permitidas por usuario; el bloqueo se conserva por tarea'

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

create or replace function public.erp_x_run_qa_control_suite(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
  v_order_id uuid;v_order2_id uuid;v_task uuid;v_version integer;v_result jsonb;v_result2 jsonb;
  v_ok boolean;v_error text;v_passed integer:=0;v_failed integer:=0;v_total integer:=0;
  v_req uuid;v_hist_number text;v_item uuid;v_lot uuid;v_available numeric;
  v_key text;
begin
  if not erp_supply.has_role('super_admin') then raise exception 'La suite integral solo puede ser ejecutada por Super Admin' using errcode='42501'; end if;
  insert into erp_supply.qa_runs(organization_id,run_type,requested_by,total_scenarios,summary)
  values(v_org,'CONTROL_SUITE',v_actor,10,jsonb_build_object('suite','enterprise-controls')) returning * into v_run;

  -- 1. Idempotencia por doble envío.
  v_total:=v_total+1;v_key:='CTRL-01-IDEMPOTENCY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'IDEMPOTENCY','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    v_result:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"inicio"}',v_actor,true,v_version,v_key);
    v_result2:=erp_supply.execute_action_internal(v_order_id,'START','{"detail":"reintento"}',v_actor,true,null,v_key);
    v_ok:=coalesce((v_result2->>'idempotent')::boolean,false) and (select count(*)=1 from erp_supply.order_events where idempotency_key=v_key);
    if not v_ok then v_error:='La acción duplicada creó más de un evento o no fue reconocida como idempotente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('ONE_EVENT','IDEMPOTENT_RESPONSE'),jsonb_build_array(v_result,v_result2),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 2. Conflicto de versión optimista.
  v_total:=v_total+1;v_key:='CTRL-02-OPTIMISTIC-VERSION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'VERSION','RECEPCION_PEDIDO',true);
    select version into v_version from erp_supply.orders where id=v_order_id;
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,v_version,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"stale"}',v_actor,true,v_version,v_key||'-WAIT');
      v_error:='No se bloqueó la versión desactualizada';
    exception when sqlstate '40001' then v_ok:=true;
    end;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('SQLSTATE_40001'),jsonb_build_array(case when v_ok then 'BLOCKED' else 'NOT_BLOCKED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 3. Múltiples sesiones activas por operario, una por tarea.
  v_total:=v_total+1;v_key:='CTRL-03-MULTI-ORDER-SESSIONS';v_ok:=false;v_error:=null;v_order_id:=null;v_order2_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-A','RECEPCION_PEDIDO',true);
    v_order2_id:=erp_supply.qa_make_order(v_run.id,v_actor,'SESSION-B','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-A');
    perform erp_supply.execute_action_internal(v_order2_id,'START','{}',v_actor,true,null,v_key||'-B');
    v_ok=(select count(*)=2 from erp_supply.task_sessions s
      join erp_supply.order_tasks t on t.id=s.task_id
      where s.profile_id=v_actor and s.ended_at is null and t.order_id in(v_order_id,v_order2_id));
    if not v_ok then v_error:='No se conservaron las dos sesiones simultáneas'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('TWO_ACTIVE_SESSIONS'),jsonb_build_array(case when v_ok then 'ACCEPTED' else 'REJECTED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then delete from erp_supply.orders where id in(v_order_id,v_order2_id); end if;

  -- 4. Espera, reanudación y sesiones de tiempo.
  v_total:=v_total+1;v_key:='CTRL-04-WAIT-RESUME-TIME';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'TIMING','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'WAIT','{"reason":"espera control"}',v_actor,true,null,v_key||'-WAIT');
    perform erp_supply.execute_action_internal(v_order_id,'RESUME','{}',v_actor,true,null,v_key||'-RESUME');
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"fin"}',v_actor,true,null,v_key||'-COMPLETE');
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='RECEPCION_PEDIDO' order by sequence_no limit 1;
    v_ok=(select count(*)=2 and bool_and(ended_at is not null) from erp_supply.task_sessions where task_id=v_task)
      and exists(select 1 from erp_supply.order_tasks where id=v_task and status='COMPLETED');
    if not v_ok then v_error:='Las sesiones de espera/reanudación no cerraron correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('TWO_CLOSED_SESSIONS','TASK_COMPLETED'),jsonb_build_array(case when v_ok then 'OK' else 'INVALID' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 5. Puerta real: checklist y validación financiera obligatorios.
  v_total:=v_total+1;v_key:='CTRL-05-STAGE-GATE';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'GATE','CARTERA',false);
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    begin
      perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{}',v_actor,true,null,v_key||'-BLOCKED');
      v_error:='La etapa se completó sin checklist ni validación';
    exception when others then
      v_ok:=position('controles obligatorios' in lower(sqlerrm))>0 or position('validación aprobada' in lower(sqlerrm))>0;
    end;
    select id into v_task from erp_supply.order_tasks where order_id=v_order_id and step_code='CARTERA' and status='IN_PROGRESS';
    update erp_supply.task_checklist set completed=true,completed_by=v_actor,completed_at=now() where task_id=v_task;
    insert into erp_supply.financial_validations(order_id,validation_type,decision,notes,created_by)
    values(v_order_id,'CARTERA','APPROVED','QA control',v_actor);
    perform erp_supply.execute_action_internal(v_order_id,'COMPLETE','{"detail":"gate satisfied"}',v_actor,true,null,v_key||'-PASS');
    v_ok:=v_ok and exists(select 1 from erp_supply.orders where id=v_order_id and current_step_code='RECEPCION_PEDIDO');
    if not v_ok and v_error is null then v_error:='La puerta no bloqueó o no liberó correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('BLOCK_WITHOUT_CONTROLS','ADVANCE_WITH_CONTROLS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 6. No entrega y reprogramación futura.
  v_total:=v_total+1;v_key:='CTRL-06-NO-DELIVERY-REPROGRAM';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'NODELIVERY','LOCAL_DISPATCH',true,'LOCAL_DISPATCH');
    perform erp_supply.execute_action_internal(v_order_id,'START','{}',v_actor,true,null,v_key||'-START');
    perform erp_supply.execute_action_internal(v_order_id,'NO_DELIVERY','{"reason":"cliente ausente"}',v_actor,true,null,v_key||'-NO');
    perform erp_supply.execute_action_internal(v_order_id,'REPROGRAM',jsonb_build_object('scheduledAt',now()+interval '1 day'),v_actor,true,null,v_key||'-REPROGRAM');
    v_ok:=exists(select 1 from erp_supply.deliveries where order_id=v_order_id and status='REPROGRAMMED')
      and exists(select 1 from erp_supply.orders where id=v_order_id and status='ASSIGNED');
    if not v_ok then v_error:='La no entrega no quedó reprogramada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('NOT_DELIVERED','REPROGRAMMED'),jsonb_build_array(case when v_ok then 'REPROGRAMMED' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 7. Solicitud y ejecución de prioridad.
  v_total:=v_total+1;v_key:='CTRL-07-APPROVAL-PRIORITY';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'APPROVAL','RECEPCION_PEDIDO',true);
    perform erp_supply.execute_action_internal(v_order_id,'REQUEST_APPROVAL','{"requestType":"PRIORITY","priority":"HIGH","reason":"QA"}',v_actor,true,null,v_key||'-REQUEST');
    select id into v_req from erp_supply.approval_requests where order_id=v_order_id and request_type='PRIORITY' order by created_at desc limit 1;
    perform public.erp_x_decide_approval(v_req,'APPROVED','Aprobación QA');
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and priority='HIGH')
      and exists(select 1 from erp_supply.approval_requests where id=v_req and status='EXECUTED');
    if not v_ok then v_error:='La aprobación no actualizó prioridad o no quedó ejecutada'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('REQUESTED','EXECUTED','PRIORITY_HIGH'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 8. Importación histórica sin tareas operativas.
  v_total:=v_total+1;v_key:='CTRL-08-HISTORY-ISOLATION';v_ok:=false;v_error:=null;v_order_id:=null;
  begin
    v_hist_number:='QAH-'||substr(replace(v_run.id::text,'-',''),1,12);
    perform public.erp_x_import_history('qa-history.csv',jsonb_build_array(jsonb_build_object(
      'orderNumber',v_hist_number,'orderType','PVC','paymentCondition','CREDIT','deliveryRoute','LOCAL_DISPATCH',
      'clientName','Histórico QA','status','CLOSED','createdAt',now()-interval '30 days','closedAt',now()-interval '29 days'
    )),null);
    select id into v_order_id from erp_supply.orders where organization_id=v_org and order_number=v_hist_number;
    v_ok:=exists(select 1 from erp_supply.orders where id=v_order_id and is_history and status='CLOSED')
      and not exists(select 1 from erp_supply.order_tasks where order_id=v_order_id);
    if not v_ok then v_error:='El histórico creó tareas o no quedó aislado'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('HISTORY','NO_TASKS'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then delete from erp_supply.orders where id=v_order_id; end if;

  -- 9. Recepción publica inventario y movimiento.
  v_total:=v_total+1;v_key:='CTRL-09-RECEIPT-INVENTORY';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;
  begin
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'RECEIPT','RECEPCION_MERCANCIA',true);
    perform public.erp_x_save_receipt(v_order_id,jsonb_build_object('receiptNumber','QAR-'||substr(v_run.id::text,1,8),'status','CONFORMING','lines',jsonb_build_array(jsonb_build_object(
      'sku','QA-RECEIPT-'||substr(v_run.id::text,1,8),'description','Material recepción QA','receivedQuantity',10,'acceptedQuantity',10,'rejectedQuantity',0,'unit','UND','location','QA','lotNumber','LOT-QA'
    ))));
    select inventory_item_id into v_item from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' order by id desc limit 1;
    v_ok:=v_item is not null and exists(select 1 from erp_supply.inventory_lots where inventory_item_id=v_item and quantity_available=10)
      and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='RECEIPT' and quantity=10);
    if not v_ok then v_error:='La recepción no publicó inventario correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('RECEIPT','LOT','MOVEMENT'),jsonb_build_array(case when v_ok then 'OK' else 'FAILED' end),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup and v_order_id is not null then
    delete from erp_supply.inventory_movements where order_id=v_order_id;
    if v_item is not null then delete from erp_supply.inventory_lots where inventory_item_id=v_item;delete from erp_supply.inventory_items where id=v_item;end if;
    delete from erp_supply.orders where id=v_order_id;
  end if;

  -- 10. Corte consume lote y registra desperdicio.
  v_total:=v_total+1;v_key:='CTRL-10-CUT-CONSUMPTION';v_ok:=false;v_error:=null;v_order_id:=null;v_item:=null;v_lot:=null;
  begin
    insert into erp_supply.inventory_items(organization_id,sku,description,unit,item_type)
    values(v_org,'QA-CUT-'||substr(v_run.id::text,1,8),'Chipa QA','M','CABLE') returning id into v_item;
    insert into erp_supply.inventory_lots(inventory_item_id,lot_number,location,quantity_available)
    values(v_item,'LOT-CUT-QA','QA-CORTE',100) returning id into v_lot;
    v_order_id:=erp_supply.qa_make_order(v_run.id,v_actor,'CUT','CORTE',true,'LOCAL_DISPATCH',true);
    perform public.erp_x_save_cut_job(v_order_id,jsonb_build_object('inventoryLotId',v_lot,'requestedLength',10,'actualLength',10,'scrapLength',1));
    select quantity_available into v_available from erp_supply.inventory_lots where id=v_lot;
    v_ok:=v_available=89 and exists(select 1 from erp_supply.inventory_movements where order_id=v_order_id and movement_type='CUT_CONSUMPTION' and quantity=11);
    if not v_ok then v_error:='El corte no descontó longitud y desperdicio correctamente'; end if;
  exception when others then v_error:=sqlstate||' - '||sqlerrm;v_ok:=false;end;
  perform erp_supply.qa_record(v_run.id,v_key,'{}',jsonb_build_array('AVAILABLE_89','MOVEMENT_11'),jsonb_build_array(coalesce(v_available,-1)),v_ok,v_error,v_order_id);
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;
  if p_cleanup then
    if v_order_id is not null then delete from erp_supply.inventory_movements where order_id=v_order_id;delete from erp_supply.orders where id=v_order_id;end if;
    if v_lot is not null then delete from erp_supply.inventory_lots where id=v_lot;end if;
    if v_item is not null then delete from erp_supply.inventory_items where id=v_item;end if;
  end if;

  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,
    total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),
    summary=summary||jsonb_build_object('cleanup',p_cleanup,'controls','idempotency,version,sessions,timing,gates,delivery,approval,history,receipt,cut')
  where id=v_run.id returning * into v_run;

  return jsonb_build_object('runId',v_run.id,'runType',v_run.run_type,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
end;
$$;

-- Mantener acceso únicamente para usuarios autenticados.
revoke all on function public.erp_x_health_check() from public,anon,authenticated;
grant execute on function public.erp_x_health_check() to authenticated;
revoke all on function public.erp_x_run_qa_control_suite(boolean) from public,anon,authenticated;
grant execute on function public.erp_x_run_qa_control_suite(boolean) to authenticated;

commit;


-- ============================================================================
-- 023_repair_reception_rpc_v10_9_4.sql
-- ============================================================================
-- ERP EI V10.9.4
-- Reparación de Recepción: restaura el RPC transaccional para enviar a Alistamiento y Corte.
-- Esta migración NO reemplaza erp_x_get_order, para conservar la versión posterior de pedidos parciales.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_resolved record;
  v_profile_id uuid;
  v_role_code text;
  v_preferred_text text;
  v_task erp_supply.order_tasks;
begin
  if p_step='ALISTAMIENTO' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,pickingProfileId}','');
    v_role_code:='aux_logistica';
  elsif p_step='CORTE' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,cutProfileId}','');
    v_role_code:='auxiliar_corte';
  end if;

  if v_preferred_text is not null then
    begin
      v_profile_id:=v_preferred_text::uuid;
    exception when others then
      v_profile_id:=null;
    end;

    if v_profile_id is not null and not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr
        on sr.role_code=pr.role_code
       and sr.step_code=p_step
       and sr.can_view
      where p.id=v_profile_id
        and p.organization_id=p_order.organization_id
        and p.active
        and pr.role_code=v_role_code
    ) then
      v_profile_id:=null;
    end if;
  end if;

  if v_profile_id is null then
    select * into v_resolved
    from erp_supply.resolve_assignment(
      p_order.organization_id,
      p_step,
      p_order.delivery_route_code,
      p_order.order_type_code
    );
    v_profile_id:=v_resolved.profile_id;
    v_role_code:=v_resolved.role_code;
  end if;

  insert into erp_supply.order_tasks(
    order_id,step_code,sequence_no,queue_code,status,
    assigned_profile_id,assigned_role_code,assigned_at,metadata
  )
  select
    p_order.id,p_step,p_sequence,s.queue_code,
    case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_profile_id,v_role_code,
    case when v_profile_id is null then null else now() end,
    case
      when v_preferred_text is not null and v_profile_id is not null
        then jsonb_build_object('assignedFrom','RECEPCION_PEDIDO')
      else '{}'::jsonb
    end
  from erp_supply.workflow_steps s
  where s.code=p_step
  returning * into v_task;

  if v_task.id is null then
    raise exception 'No existe la etapa %',p_step;
  end if;

  insert into erp_supply.task_checklist(task_id,item_code,label,required,sort_order)
  select v_task.id,t.item_code,t.label,t.required,t.sort_order
  from erp_supply.checklist_templates t
  where t.step_code=p_step and t.active
  on conflict(task_id,item_code) do nothing;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_profile_id,
      current_role_code=v_role_code,
      version=version+1,
      updated_at=now()
  where id=p_order.id;

  return v_task;
end;
$$;

-- Confirma toda la recepción en una transacción: líneas, cortes, responsables y avance.
create or replace function public.erp_x_confirm_order_reception(
  p_order_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_line jsonb;
  v_lines jsonb:=coalesce(p_payload->'lines','[]'::jsonb);
  v_line_count integer:=0;
  v_cut_count integer:=0;
  v_picking uuid;
  v_cut uuid;
  v_item_id uuid;
  v_candidate uuid;
  v_used_ids uuid[]:='{}'::uuid[];
  v_quantity numeric;
  v_cut_length numeric;
  v_requires_cut boolean;
  v_description text;
  v_unit text;
  v_source_mode text:=upper(coalesce(nullif(trim(p_payload->>'sourceMode'),''),'CORRECT'));
  v_new_version integer;
  v_result jsonb;
begin
  if not (
    erp_supply.can_access_module('receiving','update')
    or erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
  ) then
    raise exception 'No autorizado para confirmar Recepción de pedidos' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;

  if not found or not erp_supply.can_view_order(v_order.id) then
    raise exception 'Pedido no disponible' using errcode='42501';
  end if;
  if v_order.current_step_code<>'RECEPCION_PEDIDO' then
    raise exception 'El pedido ya no está en Recepción de pedidos';
  end if;
  if jsonb_typeof(v_lines)<>'array' or jsonb_array_length(v_lines)=0 then
    raise exception 'Debe confirmar al menos una línea del pedido';
  end if;
  if v_source_mode not in('CORRECT','PDF','MANUAL') then
    raise exception 'Origen de información inválido';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=v_order.id
    and step_code='RECEPCION_PEDIDO'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found then
    raise exception 'El pedido no tiene una tarea activa de Recepción';
  end if;
  if v_task.status<>'IN_PROGRESS' then
    raise exception 'Primero debes tomar e iniciar el pedido';
  end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not erp_supply.has_role('super_admin')
     and not erp_supply.has_role('jefe_logistica') then
    raise exception 'El pedido está siendo gestionado por otro usuario' using errcode='42501';
  end if;

  begin
    v_picking:=nullif(p_payload->>'pickingProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de alistamiento inválido';
  end;
  if v_picking is null or not exists(
    select 1
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    where p.id=v_picking
      and p.organization_id=v_org
      and p.active
      and pr.role_code='aux_logistica'
  ) then
    raise exception 'Selecciona un auxiliar de logística activo';
  end if;

  begin
    v_cut:=nullif(p_payload->>'cutProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de corte inválido';
  end;

  -- Mueve temporalmente los números para permitir reordenar sin colisiones únicas.
  update erp_supply.order_items
  set line_number=line_number+100000,
      metadata=metadata||jsonb_build_object('receptionActive',false),
      updated_at=now()
  where order_id=v_order.id;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_line_count:=v_line_count+1;
    if jsonb_typeof(v_line)<>'object' then
      raise exception 'La línea % no es válida',v_line_count;
    end if;

    v_description:=nullif(trim(v_line->>'description'),'');
    begin
      v_quantity:=nullif(v_line->>'quantity','')::numeric;
    exception when others then
      raise exception 'Cantidad inválida en la línea %',v_line_count;
    end;
    v_unit:=upper(coalesce(nullif(trim(v_line->>'unit'),''),'UND'));
    v_requires_cut:=coalesce((v_line->>'requiresCut')::boolean,false);
    begin
      v_cut_length:=nullif(v_line->>'requestedCutLength','')::numeric;
    exception when others then
      raise exception 'Longitud de corte inválida en la línea %',v_line_count;
    end;

    if v_description is null then
      raise exception 'La línea % necesita una descripción',v_line_count;
    end if;
    if v_quantity is null or v_quantity<=0 then
      raise exception 'La línea % necesita una cantidad válida',v_line_count;
    end if;
    if v_requires_cut and (v_cut_length is null or v_cut_length<=0) then
      raise exception 'La línea % necesita una longitud de corte válida',v_line_count;
    end if;
    if v_requires_cut then v_cut_count:=v_cut_count+1; end if;

    v_item_id:=null;
    begin
      v_candidate:=nullif(v_line->>'orderItemId','')::uuid;
    exception when others then
      v_candidate:=null;
    end;

    if v_candidate is not null and exists(
      select 1 from erp_supply.order_items
      where id=v_candidate and order_id=v_order.id
    ) and not (v_candidate=any(v_used_ids)) then
      v_item_id:=v_candidate;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'reference'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and reference=trim(v_line->>'reference')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'sku'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and sku=trim(v_line->>'sku')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null then
      insert into erp_supply.order_items(
        order_id,line_number,sku,reference,description,quantity,unit,
        warehouse_location,requires_cut,requested_cut_length,dimensions,metadata
      ) values(
        v_order.id,v_line_count,nullif(trim(v_line->>'sku'),''),
        nullif(trim(v_line->>'reference'),''),v_description,v_quantity,v_unit,
        nullif(trim(v_line->>'warehouseLocation'),''),v_requires_cut,
        case when v_requires_cut then v_cut_length else null end,
        case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
          then coalesce(v_line->'dimensions','{}'::jsonb) else '{}'::jsonb end,
        case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
          then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
        || jsonb_build_object(
          'receptionActive',true,
          'receptionSource',v_source_mode,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ) returning id into v_item_id;
    else
      update erp_supply.order_items
      set line_number=v_line_count,
          sku=nullif(trim(v_line->>'sku'),''),
          reference=nullif(trim(v_line->>'reference'),''),
          description=v_description,
          quantity=v_quantity,
          unit=v_unit,
          warehouse_location=nullif(trim(v_line->>'warehouseLocation'),''),
          requires_cut=v_requires_cut,
          requested_cut_length=case when v_requires_cut then v_cut_length else null end,
          dimensions=case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
            then coalesce(v_line->'dimensions','{}'::jsonb) else dimensions end,
          metadata=metadata
            || case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
                 then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
            || jsonb_build_object(
              'receptionActive',true,
              'receptionSource',v_source_mode,
              'confirmedAt',now(),
              'confirmedBy',v_actor
            ),
          updated_at=now()
      where id=v_item_id;
    end if;

    v_used_ids:=array_append(v_used_ids,v_item_id);
  end loop;

  if v_cut_count>0 then
    if v_cut is null or not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      where p.id=v_cut
        and p.organization_id=v_org
        and p.active
        and pr.role_code='auxiliar_corte'
    ) then
      raise exception 'Selecciona un auxiliar de corte activo';
    end if;
  else
    v_cut:=null;
  end if;

  -- Los registros antiguos con relaciones de recepción se conservan, pero dejan de formar parte del pedido operativo.
  delete from erp_supply.order_items i
  where i.order_id=v_order.id
    and not (i.id=any(v_used_ids))
    and not exists(select 1 from erp_supply.receipt_lines rl where rl.order_item_id=i.id)
    and not exists(select 1 from erp_supply.cut_jobs cj where cj.order_item_id=i.id);

  update erp_supply.task_checklist
  set completed=true,
      completed_by=v_actor,
      completed_at=now(),
      note=case item_code
        when 'DOCUMENTS' then 'Información comercial validada en Recepción de pedidos'
        when 'ASSIGNMENT' then 'Auxiliares asignados desde Recepción de pedidos'
        else note end,
      metadata=metadata||jsonb_build_object('source','RECEPCION_PEDIDO_V10_6')
  where task_id=v_task.id and item_code in('DOCUMENTS','ASSIGNMENT');

  update erp_supply.orders
  set requires_cut=(v_cut_count>0),
      metadata=metadata||jsonb_build_object(
        'receptionAssignment',jsonb_build_object(
          'pickingProfileId',v_picking,
          'cutProfileId',v_cut,
          'sourceMode',v_source_mode,
          'sourceFileId',nullif(p_payload->>'sourceFileId',''),
          'sourceFileName',nullif(p_payload->>'sourceFileName',''),
          'readerVersion',nullif(p_payload->>'readerVersion',''),
          'lineCount',v_line_count,
          'cutLineCount',v_cut_count,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ),
      version=version+1,
      updated_at=now()
  where id=v_order.id
  returning version into v_new_version;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'DOMAIN_RECORD','RECEPTION_ASSIGNMENT',
    'RECEPCION_PEDIDO','RECEPCION_PEDIDO',v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'sourceMode',v_source_mode,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count,
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'sourceFileId',nullif(p_payload->>'sourceFileId',''),
      'readerVersion',nullif(p_payload->>'readerVersion','')
    )
  );

  v_result:=erp_supply.execute_action_internal(
    v_order.id,
    'COMPLETE',
    jsonb_build_object(
      'resultCode','RECEPTION_CONFIRMED',
      'detail','Información validada y auxiliares asignados',
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count
    ),
    v_actor,
    false,
    v_new_version,
    'RECEPTION-CONFIRM-'||v_order.id::text||'-'||v_new_version::text
  );

  return v_result||jsonb_build_object(
    'receptionConfirmed',true,
    'lines',v_line_count,
    'cutLines',v_cut_count,
    'pickingProfileId',v_picking,
    'cutProfileId',v_cut
  );
end;
$$;

revoke all on function public.erp_x_confirm_order_reception(uuid,jsonb) from public;
grant execute on function public.erp_x_confirm_order_reception(uuid,jsonb) to authenticated;

do $$
begin
  if to_regprocedure('public.erp_x_confirm_order_reception(uuid,jsonb)') is null then
    raise exception 'No fue posible instalar public.erp_x_confirm_order_reception(uuid,jsonb)';
  end if;
end;
$$;

commit;

-- Fuerza a PostgREST/Supabase a reconocer inmediatamente la firma nueva.
notify pgrst, 'reload schema';

-- Debe devolver: public.erp_x_confirm_order_reception(uuid,jsonb)
select to_regprocedure('public.erp_x_confirm_order_reception(uuid,jsonb)') as rpc_instalado;


-- ============================================================================
-- 024_cutting_first_and_collection_v10_10.sql
-- ============================================================================
-- ERP Electroingeniería V10.10
-- Corte primero, agrupación por referencia, control de carreto e integración con Alistamiento.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

create table if not exists erp_supply.cut_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  group_key text not null,
  reference text,
  description text not null,
  inventory_item_id uuid references erp_supply.inventory_items(id),
  inventory_lot_id uuid references erp_supply.inventory_lots(id),
  resolution_code text not null check (resolution_code in ('CUT','FULL_REEL')),
  reel_initial_length numeric(18,4) not null check (reel_initial_length > 0),
  requested_length numeric(18,4) not null check (requested_length > 0),
  scrap_length numeric(18,4) not null default 0 check (scrap_length >= 0),
  remaining_length numeric(18,4) not null check (remaining_length >= 0),
  executed_by uuid not null references erp_supply.profiles(id),
  executed_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

create table if not exists erp_supply.cut_requirements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  task_id uuid references erp_supply.order_tasks(id) on delete set null,
  group_key text not null,
  sku text,
  reference text,
  description text not null,
  unit text not null default 'M',
  units_required numeric(18,4) not null check (units_required > 0),
  length_each numeric(18,4) not null check (length_each > 0),
  total_length numeric(18,4) not null check (total_length > 0),
  process_status text not null default 'PENDING' check (process_status in ('PENDING','IN_PROGRESS','READY')),
  resolution_code text check (resolution_code in ('CUT','FULL_REEL','NO_CUT')),
  collection_status text not null default 'PENDING' check (collection_status in ('PENDING','COLLECTED')),
  assigned_profile_id uuid references erp_supply.profiles(id),
  cut_batch_id uuid references erp_supply.cut_batches(id) on delete set null,
  cut_job_id uuid references erp_supply.cut_jobs(id) on delete set null,
  inventory_lot_id uuid references erp_supply.inventory_lots(id) on delete set null,
  ready_at timestamptz,
  ready_by uuid references erp_supply.profiles(id),
  collected_at timestamptz,
  collected_by uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_item_id)
);

create index if not exists idx_cut_requirements_group
  on erp_supply.cut_requirements(organization_id,group_key,process_status,created_at);
create index if not exists idx_cut_requirements_order
  on erp_supply.cut_requirements(order_id,collection_status,process_status);
create index if not exists idx_cut_batches_group
  on erp_supply.cut_batches(organization_id,group_key,executed_at desc);


-- Ninguna ronda de Alistamiento puede cerrarse mientras haya cortes sin terminar o sin recoger.
create or replace function erp_supply.enforce_cut_collection_before_picking()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if exists(
    select 1 from erp_supply.cut_requirements r
    where r.order_id=new.order_id and (r.process_status<>'READY' or r.collection_status<>'COLLECTED')
  ) then
    raise exception 'Debes terminar y recoger todos los cortes antes de verificar Alistamiento';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_enforce_cut_collection_before_picking on erp_supply.picking_rounds;
create trigger trg_enforce_cut_collection_before_picking
before insert on erp_supply.picking_rounds
for each row execute function erp_supply.enforce_cut_collection_before_picking();

create or replace function erp_supply.cut_group_key(
  p_reference text,
  p_sku text,
  p_description text
)
returns text
language sql
immutable
as $$
  select md5(
    lower(trim(coalesce(nullif(p_reference,''),nullif(p_sku,''),p_description,'')))
    ||'|'||lower(trim(coalesce(p_description,'')))
  )
$$;

-- Flujo definitivo: si hay corte, Recepción envía primero a Corte; Corte entrega a Alistamiento.
create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case p_current_step
    when 'CARTERA' then 'RECEPCION_PEDIDO'
    when 'CAJA' then 'RECEPCION_PEDIDO'
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then case when p_requires_cut then 'CORTE' else 'ALISTAMIENTO' end
    when 'CORTE' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case
      when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION'
      else 'FACTURACION' end
    when 'CAJA_FACTURACION' then p_delivery_route
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.sync_cut_requirements(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_count integer:=0;
  v_cut_first boolean;
begin
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then return 0; end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id and step_code='CORTE'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1;
  if not found then return 0; end if;

  v_cut_first:=not exists(
    select 1 from erp_supply.order_tasks t
    where t.order_id=p_order_id and t.step_code='ALISTAMIENTO'
      and t.status='COMPLETED' and t.sequence_no<v_task.sequence_no
  );

  insert into erp_supply.cut_requirements(
    organization_id,order_id,order_item_id,task_id,group_key,sku,reference,description,
    unit,units_required,length_each,total_length,assigned_profile_id,metadata
  )
  select
    v_order.organization_id,v_order.id,i.id,v_task.id,
    erp_supply.cut_group_key(i.reference,i.sku,i.description),
    i.sku,i.reference,i.description,'M',i.quantity,i.requested_cut_length,
    round((i.quantity*i.requested_cut_length)::numeric,4),v_task.assigned_profile_id,
    jsonb_build_object('lineNumber',i.line_number,'source','CUT_FIRST_V10_10')
  from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.requires_cut
    and i.requested_cut_length is not null
    and i.requested_cut_length>0
  on conflict(order_item_id) do update set
    task_id=excluded.task_id,
    group_key=excluded.group_key,
    sku=excluded.sku,
    reference=excluded.reference,
    description=excluded.description,
    units_required=excluded.units_required,
    length_each=excluded.length_each,
    total_length=excluded.total_length,
    assigned_profile_id=coalesce(erp_supply.cut_requirements.assigned_profile_id,excluded.assigned_profile_id),
    metadata=erp_supply.cut_requirements.metadata||excluded.metadata,
    updated_at=now();

  get diagnostics v_count=row_count;

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object(
        'cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
          'version','10.10','cutFirst',v_cut_first,'syncedAt',now(),
          'pendingRequirements',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status<>'READY')
        )
      ),updated_at=now()
  where id=p_order_id;

  return v_count;
end;
$$;

create or replace function erp_supply.trg_sync_cut_requirements()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public
as $$
begin
  if new.step_code='CORTE' then
    perform erp_supply.sync_cut_requirements(new.order_id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_cut_requirements on erp_supply.order_tasks;
create trigger trg_sync_cut_requirements
after insert on erp_supply.order_tasks
for each row execute function erp_supply.trg_sync_cut_requirements();

create or replace function erp_supply.start_cut_task(p_order_id uuid,p_actor uuid)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_task erp_supply.order_tasks%rowtype;
  v_org uuid;
  v_now timestamptz:=now();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
begin
  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id and step_code='CORTE'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found then raise exception 'El pedido no tiene una tarea activa de Corte'; end if;

  select organization_id into v_org from erp_supply.orders where id=p_order_id;
  if v_task.assigned_profile_id is not null and v_task.assigned_profile_id<>p_actor and not v_override then
    raise exception 'Este corte está asignado a otro auxiliar' using errcode='42501';
  end if;

  if v_task.status='QUEUED' then
    update erp_supply.order_tasks
    set status='ASSIGNED',assigned_profile_id=p_actor,assigned_role_code='auxiliar_corte',assigned_at=v_now
    where id=v_task.id returning * into v_task;
  end if;

  if v_task.status in('ASSIGNED','WAITING','BLOCKED') then
    update erp_supply.order_tasks
    set status='IN_PROGRESS',started_at=coalesce(started_at,v_now),blocked_at=null
    where id=v_task.id returning * into v_task;
  end if;

  if v_task.status='IN_PROGRESS' then
    insert into erp_supply.task_sessions(task_id,profile_id,started_at,note)
    select v_task.id,p_actor,v_now,'Gestión de corte por referencia'
    where not exists(select 1 from erp_supply.task_sessions s where s.task_id=v_task.id and s.ended_at is null);
  end if;

  update erp_supply.orders
  set status='IN_PROGRESS',current_assignee_id=p_actor,current_role_code='auxiliar_corte',
      version=version+1,updated_at=v_now
  where id=p_order_id;

  update erp_supply.cut_requirements
  set task_id=v_task.id,assigned_profile_id=p_actor,
      process_status=case when process_status='PENDING' then 'IN_PROGRESS' else process_status end,
      updated_at=v_now
  where order_id=p_order_id and process_status<>'READY';

  return v_task;
end;
$$;

create or replace function erp_supply.advance_cut_order_if_ready(p_order_id uuid,p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_new_task erp_supply.order_tasks%rowtype;
  v_now timestamptz:=now();
  v_raw bigint:=0;
  v_business bigint:=0;
  v_sequence integer;
  v_next text;
  v_cut_first boolean;
begin
  if exists(select 1 from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status<>'READY') then
    return false;
  end if;

  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found or v_order.current_step_code<>'CORTE' then return false; end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=p_order_id and step_code='CORTE'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found then return false; end if;

  update erp_supply.task_checklist
  set completed=true,completed_by=p_actor,completed_at=v_now,
      note='Todos los cortes quedaron listos para recoger',
      metadata=metadata||jsonb_build_object('source','CUT_FIRST_V10_10')
  where task_id=v_task.id and required;

  update erp_supply.task_sessions s
  set ended_at=v_now,
      raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at)))::bigint,
      business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
      note='Grupo de corte finalizado'
  where s.task_id=v_task.id and s.ended_at is null;

  select coalesce(sum(raw_seconds),0),coalesce(sum(business_seconds),0)
  into v_raw,v_business from erp_supply.task_sessions where task_id=v_task.id;

  update erp_supply.orders
  set requires_cut=exists(
        select 1 from erp_supply.cut_requirements r
        where r.order_id=p_order_id and r.resolution_code in('CUT','FULL_REEL')
      ),
      metadata=metadata||jsonb_build_object(
        'cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
          'completedAt',v_now,'completedBy',p_actor,
          'pendingCollection',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.collection_status='PENDING')
        )
      ),version=version+1,updated_at=v_now
  where id=p_order_id returning * into v_order;

  update erp_supply.order_tasks
  set status='COMPLETED',completed_at=v_now,raw_seconds=v_raw,business_seconds=v_business,
      result_code='CUT_READY_FOR_PICKING',result_detail='Cortes listos para recoger en Alistamiento',
      metadata=metadata||jsonb_build_object('cutFlowVersion','10.10','readyForPickupAt',v_now)
  where id=v_task.id;

  v_cut_first=coalesce((v_order.metadata#>>'{cutFlow,cutFirst}')::boolean,true);
  if v_cut_first then
    v_next:='ALISTAMIENTO';
  else
    v_next:=case when upper(v_order.order_type_code) in('PVN','PNV') then 'CAJA_FACTURACION' else 'FACTURACION' end;
  end if;

  select coalesce(max(sequence_no),0)+1 into v_sequence from erp_supply.order_tasks where order_id=p_order_id;
  select * into v_new_task from erp_supply.create_task(v_order,v_next,v_sequence);

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_order.organization_id,p_order_id,v_task.id,'WORKFLOW_ACTION','CUT_READY_FOR_PICKING',
    'CORTE',v_next,'IN_PROGRESS',v_new_task.status,p_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'nextTaskId',v_new_task.id,'cutFirst',v_cut_first,
      'requirements',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id),
      'collectionPending',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.collection_status='PENDING')
    )
  );

  return true;
end;
$$;

create or replace function public.erp_x_cutting_groups(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_total bigint;
  v_items jsonb;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar Corte' using errcode='42501';
  end if;

  with eligible as (
    select r.*
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
    join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    where r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id)
      and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
  ), grouped as (
    select group_key from eligible group by group_key
  ) select count(*) into v_total from grouped;

  with eligible as (
    select r.*,o.order_number,o.client_name,o.priority,t.status task_status,t.assigned_profile_id
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
    join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    where r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id)
      and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
  ), grouped as (
    select group_key,max(reference) reference,max(sku) sku,max(description) description,
      count(*)::integer item_count,count(distinct order_id)::integer order_count,
      sum(units_required) cut_count,sum(total_length) total_length,
      min(created_at) oldest_at,
      bool_or(task_status='IN_PROGRESS') in_progress
    from eligible group by group_key
    order by in_progress desc,oldest_at
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
      'groupKey',group_key,'reference',reference,'sku',sku,'description',description,
      'itemCount',item_count,'orderCount',order_count,'cutCount',cut_count,
      'totalLength',total_length,'oldestAt',oldest_at,'inProgress',in_progress
    )),'[]'::jsonb) into v_items from grouped;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object(
    'page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer
  ),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_cutting_group(p_group_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reference text;
  v_sku text;
  v_description text;
begin
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar Corte' using errcode='42501';
  end if;

  select max(r.reference),max(r.sku),max(r.description)
  into v_reference,v_sku,v_description
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
  join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and erp_supply.can_view_order(o.id)
    and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor);
  if v_description is null then raise exception 'El grupo ya no tiene cortes pendientes'; end if;

  return jsonb_build_object(
    'group',jsonb_build_object(
      'groupKey',p_group_key,'reference',v_reference,'sku',v_sku,'description',v_description,
      'itemCount',(select count(*) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE' join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id) and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)),
      'orderCount',(select count(distinct r.order_id) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE' join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id) and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)),
      'cutCount',(select coalesce(sum(r.units_required),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE' join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id) and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)),
      'totalLength',(select coalesce(sum(r.total_length),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE' join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and erp_supply.can_view_order(o.id) and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor))
    ),
    'items',(select coalesce(jsonb_agg(jsonb_build_object(
      'requirementId',r.id,'orderId',r.order_id,'orderNumber',o.order_number,'clientName',o.client_name,
      'priority',o.priority,'orderItemId',r.order_item_id,'lineNumber',i.line_number,
      'sku',r.sku,'reference',r.reference,'description',r.description,'unit',r.unit,
      'unitsRequired',r.units_required,'lengthEach',r.length_each,'totalLength',r.total_length,
      'processStatus',r.process_status,'taskStatus',t.status,'assigneeId',t.assigned_profile_id,'assigneeName',p.display_name
    ) order by o.priority desc,o.order_number,i.line_number),'[]'::jsonb)
      from erp_supply.cut_requirements r
      join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
      join erp_supply.order_items i on i.id=r.order_item_id
      join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      left join erp_supply.profiles p on p.id=t.assigned_profile_id
      where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
        and erp_supply.can_view_order(o.id)
        and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)),
    'reels',(select coalesce(jsonb_agg(jsonb_build_object(
      'lotId',l.id,'inventoryItemId',ii.id,'lotNumber',l.lot_number,'location',l.location,
      'quantityAvailable',l.quantity_available,'unit',ii.unit,'updatedAt',ii.updated_at
    ) order by l.quantity_available desc),'[]'::jsonb)
      from erp_supply.inventory_items ii join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
      where ii.organization_id=v_org and ii.active and l.quantity_available>0
        and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference)
          or ii.metadata->>'cutGroupKey'=p_group_key)),
    'recentBatches',(select coalesce(jsonb_agg(to_jsonb(b) order by b.executed_at desc),'[]'::jsonb)
      from (select * from erp_supply.cut_batches where organization_id=v_org and group_key=p_group_key order by executed_at desc limit 5) b)
  );
end;
$$;

create or replace function public.erp_x_execute_cut_group(p_group_key text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);
  v_needed numeric;
  v_reference text;
  v_sku text;
  v_description text;
  v_inventory_item erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_batch erp_supply.cut_batches%rowtype;
  v_req erp_supply.cut_requirements%rowtype;
  v_job erp_supply.cut_jobs%rowtype;
  v_orders uuid[]:='{}'::uuid[];
  v_order_id uuid;
  v_difference numeric;
  v_count integer:=0;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para ejecutar cortes' using errcode='42501';
  end if;
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if v_reel is null or v_reel<=0 then raise exception 'Indica cuánto tiene el carreto'; end if;
  if v_scrap<0 then raise exception 'La merma no puede ser negativa'; end if;

  select coalesce(sum(r.total_length),0),max(r.reference),max(r.sku),max(r.description)
  into v_needed,v_reference,v_sku,v_description
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
  join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and erp_supply.can_view_order(o.id)
    and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor);
  if v_needed<=0 then raise exception 'El grupo ya no tiene cortes pendientes'; end if;
  if v_reel<v_needed+v_scrap then
    raise exception 'El carreto tiene % y se necesitan % incluyendo la merma',v_reel,v_needed+v_scrap;
  end if;

  select * into v_inventory_item
  from erp_supply.inventory_items ii
  where ii.organization_id=v_org
    and ((v_sku is not null and ii.sku=v_sku) or (v_reference is not null and ii.reference=v_reference)
      or ii.metadata->>'cutGroupKey'=p_group_key)
  order by (ii.metadata->>'cutGroupKey'=p_group_key) desc limit 1 for update;

  if not found then
    insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,metadata)
    values(v_org,coalesce(v_sku,v_reference,'CUT-'||substr(p_group_key,1,12)),v_reference,v_description,'M','CUT_REEL',jsonb_build_object('cutGroupKey',p_group_key,'source','CUT_FIRST_V10_10'))
    returning * into v_inventory_item;
  else
    update erp_supply.inventory_items set metadata=metadata||jsonb_build_object('cutGroupKey',p_group_key),updated_at=now()
    where id=v_inventory_item.id returning * into v_inventory_item;
  end if;

  if v_lot_id is not null then
    select * into v_lot from erp_supply.inventory_lots
    where id=v_lot_id and inventory_item_id=v_inventory_item.id for update;
    if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia'; end if;
    v_difference:=v_reel-v_lot.quantity_available;
    if abs(v_difference)>0.0001 then
      update erp_supply.inventory_lots set quantity_available=v_reel where id=v_lot.id returning * into v_lot;
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,
        actor_profile_id,reference,metadata
      ) values(
        v_org,v_inventory_item.id,v_lot.id,case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,
        abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',
        jsonb_build_object('previousLength',v_reel-v_difference,'confirmedLength',v_reel,'source','CUT_FIRST_V10_10')
      );
    end if;
  else
    insert into erp_supply.inventory_lots(
      inventory_item_id,lot_number,location,quantity_available,received_at,metadata
    ) values(
      v_inventory_item.id,
      coalesce(nullif(trim(p_payload->>'lotNumber'),''),'CARRETO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS')),
      coalesce(nullif(trim(p_payload->>'location'),''),'CORTE'),v_reel,now(),
      jsonb_build_object('cutGroupKey',p_group_key,'source','CUT_FIRST_V10_10')
    ) returning * into v_lot;
    insert into erp_supply.inventory_movements(
      organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,to_location,
      actor_profile_id,reference,metadata
    ) values(v_org,v_inventory_item.id,v_lot.id,'CUT_REEL_ENTRY',v_reel,'M',v_lot.location,v_actor,v_lot.lot_number,jsonb_build_object('source','CUT_FIRST_V10_10'));
  end if;

  insert into erp_supply.cut_batches(
    organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,
    resolution_code,reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata
  ) values(
    v_org,p_group_key,v_reference,v_description,v_inventory_item.id,v_lot.id,'CUT',
    v_reel,v_needed,v_scrap,v_reel-v_needed-v_scrap,v_actor,
    jsonb_build_object('lotNumber',v_lot.lot_number,'location',v_lot.location,'version','10.10')
  ) returning * into v_batch;

  for v_req in
    select r.*
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.current_step_code='CORTE'
    join erp_supply.order_tasks t on t.id=r.task_id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
      and erp_supply.can_view_order(o.id)
      and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)
    order by r.created_at for update of r
  loop
    perform erp_supply.start_cut_task(v_req.order_id,v_actor);
    insert into erp_supply.cut_jobs(
      order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,
      status,assigned_profile_id,started_at,completed_at,metadata
    ) values(
      v_req.order_id,v_req.order_item_id,v_lot.id,v_req.total_length,v_req.total_length,0,
      'COMPLETED',v_actor,now(),now(),jsonb_build_object(
        'mode','CUT','batchId',v_batch.id,'units',v_req.units_required,'lengthEach',v_req.length_each,'cutFlowVersion','10.10'
      )
    ) returning * into v_job;

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='CUT',collection_status='PENDING',
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set metadata=metadata||jsonb_build_object(
      'cutStatus','READY','cutResolution','CUT','cutRequirementId',v_req.id,
      'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor
    ),updated_at=now() where id=v_req.order_item_id;

    if not (v_req.order_id=any(v_orders)) then v_orders:=array_append(v_orders,v_req.order_id); end if;
    v_count:=v_count+1;
  end loop;

  update erp_supply.inventory_lots
  set quantity_available=v_reel-v_needed-v_scrap,
      metadata=metadata||jsonb_build_object('lastCutBatchId',v_batch.id,'lastCutAt',now())
  where id=v_lot.id;

  insert into erp_supply.inventory_movements(
    organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,
    actor_profile_id,reference,metadata
  ) values(
    v_org,v_inventory_item.id,v_lot.id,'CUT_CONSUMPTION',v_needed+v_scrap,'M',v_lot.location,
    v_actor,v_batch.id::text,jsonb_build_object('requestedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_reel-v_needed-v_scrap,'groupKey',p_group_key)
  );

  foreach v_order_id in array v_orders loop
    perform erp_supply.advance_cut_order_if_ready(v_order_id,v_actor);
  end loop;

  return jsonb_build_object('success',true,'batchId',v_batch.id,'processedItems',v_count,
    'requestedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_reel-v_needed-v_scrap,
    'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number);
end;
$$;

create or replace function public.erp_x_resolve_cut_requirement(
  p_requirement_id uuid,
  p_resolution text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_resolution text:=upper(trim(coalesce(p_resolution,'')));
  v_req erp_supply.cut_requirements%rowtype;
  v_order erp_supply.orders%rowtype;
  v_reason text:=nullif(trim(p_payload->>'reason'),'');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_inventory_item erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_batch erp_supply.cut_batches%rowtype;
  v_job erp_supply.cut_jobs%rowtype;
  v_difference numeric;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para resolver cortes' using errcode='42501';
  end if;
  if v_resolution not in('FULL_REEL','NO_CUT') then raise exception 'Resolución de corte inválida'; end if;

  select r.* into v_req
  from erp_supply.cut_requirements r
  join erp_supply.order_tasks t on t.id=r.task_id
  where r.id=p_requirement_id and r.organization_id=v_org and r.process_status<>'READY'
    and (v_override or t.assigned_profile_id is null or t.assigned_profile_id=v_actor)
  for update of r;
  if not found then raise exception 'El corte ya fue resuelto o no está disponible'; end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id and current_step_code='CORTE' for update;
  if not found then raise exception 'El pedido ya no está en Corte'; end if;
  perform erp_supply.start_cut_task(v_req.order_id,v_actor);

  if v_resolution='NO_CUT' then
    if v_reason is null then raise exception 'Explica por qué la referencia no necesita corte'; end if;

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='NO_CUT',collection_status='PENDING',
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
        metadata=metadata||jsonb_build_object('reason',v_reason),updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set requires_cut=false,requested_cut_length=null,
        metadata=metadata||jsonb_build_object(
          'cutStatus','READY','cutResolution','NO_CUT','cutRequirementId',v_req.id,
          'cutReadyAt',now(),'cutReadyBy',v_actor,'cutNoNeedReason',v_reason,
          'originalRequestedCutLength',v_req.length_each
        ),updated_at=now()
    where id=v_req.order_item_id;

    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_req.order_id,v_actor,'NOVELTY','INTERNAL',
      format('Corte corregido: la referencia %s no necesita corte. %s',coalesce(v_req.reference,v_req.sku,v_req.description),v_reason),
      jsonb_build_object('source','CORTE','resolution','NO_CUT','requirementId',v_req.id));
  else
    if v_reel is null or v_reel<=0 then raise exception 'Indica la medida del carreto completo'; end if;
    if abs(v_reel-v_req.total_length)>0.0001 then
      raise exception 'Carreto completo solo aplica cuando la medida del carreto (%) coincide con lo solicitado (%)',v_reel,v_req.total_length;
    end if;

    select * into v_inventory_item from erp_supply.inventory_items ii
    where ii.organization_id=v_org and ((v_req.sku is not null and ii.sku=v_req.sku)
      or (v_req.reference is not null and ii.reference=v_req.reference)
      or ii.metadata->>'cutGroupKey'=v_req.group_key)
    order by (ii.metadata->>'cutGroupKey'=v_req.group_key) desc limit 1 for update;

    if not found then
      insert into erp_supply.inventory_items(organization_id,sku,reference,description,unit,item_type,metadata)
      values(v_org,coalesce(v_req.sku,v_req.reference,'CUT-'||substr(v_req.group_key,1,12)),v_req.reference,v_req.description,'M','CUT_REEL',jsonb_build_object('cutGroupKey',v_req.group_key,'source','CUT_FIRST_V10_10'))
      returning * into v_inventory_item;
    end if;

    if v_lot_id is not null then
      select * into v_lot from erp_supply.inventory_lots where id=v_lot_id and inventory_item_id=v_inventory_item.id for update;
      if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia'; end if;
      v_difference:=v_reel-v_lot.quantity_available;
      if abs(v_difference)>0.0001 then
        update erp_supply.inventory_lots set quantity_available=v_reel where id=v_lot.id returning * into v_lot;
        insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata)
        values(v_org,v_inventory_item.id,v_lot.id,case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',jsonb_build_object('confirmedLength',v_reel));
      end if;
    else
      insert into erp_supply.inventory_lots(inventory_item_id,lot_number,location,quantity_available,received_at,metadata)
      values(v_inventory_item.id,coalesce(nullif(trim(p_payload->>'lotNumber'),''),'CARRETO-'||to_char(clock_timestamp(),'YYYYMMDD-HH24MISS-MS')),coalesce(nullif(trim(p_payload->>'location'),''),'CORTE'),v_reel,now(),jsonb_build_object('cutGroupKey',v_req.group_key,'source','CUT_FIRST_V10_10'))
      returning * into v_lot;
      insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,to_location,actor_profile_id,reference,metadata)
      values(v_org,v_inventory_item.id,v_lot.id,'CUT_REEL_ENTRY',v_reel,'M',v_lot.location,v_actor,v_lot.lot_number,jsonb_build_object('source','CUT_FIRST_V10_10'));
    end if;

    insert into erp_supply.cut_batches(organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,resolution_code,reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata)
    values(v_org,v_req.group_key,v_req.reference,v_req.description,v_inventory_item.id,v_lot.id,'FULL_REEL',v_reel,v_req.total_length,0,0,v_actor,jsonb_build_object('requirementId',v_req.id,'version','10.10'))
    returning * into v_batch;

    insert into erp_supply.cut_jobs(order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,status,assigned_profile_id,started_at,completed_at,metadata)
    values(v_req.order_id,v_req.order_item_id,v_lot.id,v_req.total_length,v_req.total_length,0,'COMPLETED',v_actor,now(),now(),jsonb_build_object('mode','FULL_REEL','batchId',v_batch.id,'cutFlowVersion','10.10'))
    returning * into v_job;

    update erp_supply.inventory_lots set quantity_available=0,metadata=metadata||jsonb_build_object('issuedCompleteAt',now(),'cutBatchId',v_batch.id) where id=v_lot.id;
    insert into erp_supply.inventory_movements(organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,actor_profile_id,reference,metadata)
    values(v_org,v_inventory_item.id,v_lot.id,v_req.order_id,'FULL_REEL_ISSUE',v_req.total_length,'M',v_lot.location,v_actor,v_batch.id::text,jsonb_build_object('requirementId',v_req.id));

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='FULL_REEL',collection_status='PENDING',
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set metadata=metadata||jsonb_build_object(
      'cutStatus','READY','cutResolution','FULL_REEL','cutRequirementId',v_req.id,
      'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor
    ),updated_at=now() where id=v_req.order_item_id;
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,v_req.order_id,v_req.task_id,'DOMAIN_RECORD',v_resolution,'CORTE','CORTE',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('requirementId',v_req.id,'reason',v_reason));

  perform erp_supply.advance_cut_order_if_ready(v_req.order_id,v_actor);
  return jsonb_build_object('success',true,'requirementId',v_req.id,'resolution',v_resolution,'orderId',v_req.order_id);
end;
$$;

create or replace function public.erp_x_cut_pickups_pending(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_is_picker boolean:=erp_supply.has_role('aux_logistica');
  v_total bigint;
  v_items jsonb;
begin
  if not (erp_supply.can_access_module('picking','read') or v_is_picker or v_override) then
    raise exception 'No autorizado para consultar cortes por recoger' using errcode='42501';
  end if;

  with eligible as (
    select o.id
    from erp_supply.orders o
    left join lateral (
      select t.* from erp_supply.order_tasks t
      where t.order_id=o.id and t.step_code='ALISTAMIENTO'
        and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      order by t.sequence_no desc limit 1
    ) pt on true
    where o.organization_id=v_org and o.current_step_code in('CORTE','ALISTAMIENTO')
      and exists(select 1 from erp_supply.cut_requirements r where r.order_id=o.id and r.process_status='READY' and r.collection_status='PENDING')
      and (
        v_override
        or (o.current_step_code='ALISTAMIENTO' and pt.id is not null and (pt.assigned_profile_id is null or pt.assigned_profile_id=v_actor) and erp_supply.can_view_order(o.id))
        or (o.current_step_code='CORTE' and v_is_picker and (
          erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}') is null
          or erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')=v_actor
        ))
      )
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name) like '%'||lower(p_search)||'%')
  ) select count(*) into v_total from eligible;

  with eligible as (
    select o.*,
      coalesce(pt.assigned_profile_id,erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')) pickup_assignee_id,
      coalesce(tp.display_name,rp.display_name) assignee_name,
      (select count(*) from erp_supply.cut_requirements r where r.order_id=o.id and r.process_status='READY' and r.collection_status='PENDING') pickup_count,
      (select coalesce(sum(r.total_length),0) from erp_supply.cut_requirements r where r.order_id=o.id and r.process_status='READY' and r.collection_status='PENDING') pickup_length,
      (select count(*) from erp_supply.cut_requirements r where r.order_id=o.id and r.process_status<>'READY') cuts_still_pending,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_seconds
    from erp_supply.orders o
    left join lateral (
      select t.* from erp_supply.order_tasks t
      where t.order_id=o.id and t.step_code='ALISTAMIENTO'
        and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      order by t.sequence_no desc limit 1
    ) pt on true
    left join erp_supply.profiles tp on tp.id=pt.assigned_profile_id
    left join erp_supply.profiles rp on rp.id=erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')
    where o.organization_id=v_org and o.current_step_code in('CORTE','ALISTAMIENTO')
      and exists(select 1 from erp_supply.cut_requirements r where r.order_id=o.id and r.process_status='READY' and r.collection_status='PENDING')
      and (
        v_override
        or (o.current_step_code='ALISTAMIENTO' and pt.id is not null and (pt.assigned_profile_id is null or pt.assigned_profile_id=v_actor) and erp_supply.can_view_order(o.id))
        or (o.current_step_code='CORTE' and v_is_picker and (
          erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}') is null
          or erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')=v_actor
        ))
      )
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name) like '%'||lower(p_search)||'%')
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 else 4 end,o.updated_at
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'clientName',client_name,'orderType',order_type_code,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep',current_step_code,
    'stepName',case when current_step_code='CORTE' then 'Recogida anticipada desde Corte' else 'Cortes por recoger' end,
    'status',status,'priority',priority,'assigneeName',assignee_name,'pickupAssigneeId',pickup_assignee_id,
    'ageBusinessSeconds',age_seconds,'cutPickupPendingCount',pickup_count,'cutPickupTotalLength',pickup_length,
    'cutsStillPending',cuts_still_pending,'cutPickupLabel',true,'pickupWhileCutting',(current_step_code='CORTE'),'version',version
  )),'[]'::jsonb) into v_items from eligible;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object(
    'page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer
  ),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_cut_pickup_detail(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_is_picker boolean:=erp_supply.has_role('aux_logistica');
  v_picking_profile uuid;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org;
  if not found or v_order.current_step_code not in('CORTE','ALISTAMIENTO') then raise exception 'El pedido no tiene cortes disponibles para recoger'; end if;
  v_picking_profile:=erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,pickingProfileId}');

  if v_order.current_step_code='ALISTAMIENTO' then
    select * into v_task from erp_supply.order_tasks
    where order_id=p_order_id and step_code='ALISTAMIENTO' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    order by sequence_no desc limit 1;
    if not found then raise exception 'No existe tarea activa de Alistamiento'; end if;
    if v_task.assigned_profile_id is not null and v_task.assigned_profile_id<>v_actor and not v_override then raise exception 'El pedido está asignado a otro auxiliar' using errcode='42501'; end if;
    if not erp_supply.can_view_order(v_order.id) and not v_override then raise exception 'No autorizado para consultar el pedido' using errcode='42501'; end if;
  elsif not v_override then
    if not v_is_picker then raise exception 'No autorizado para recoger cortes' using errcode='42501'; end if;
    if v_picking_profile is not null and v_picking_profile<>v_actor then raise exception 'La recogida está asignada a otro auxiliar' using errcode='42501'; end if;
  end if;

  if not exists(select 1 from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING') then
    raise exception 'No quedan cortes pendientes de recoger';
  end if;

  return jsonb_build_object(
    'order',jsonb_build_object('id',v_order.id,'orderNumber',v_order.order_number,'clientName',v_order.client_name,'priority',v_order.priority,'route',v_order.delivery_route_code,'currentStep',v_order.current_step_code),
    'task',case when v_task.id is null then null else to_jsonb(v_task) end,
    'pickupWhileCutting',(v_order.current_step_code='CORTE'),
    'cutsStillPending',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status<>'READY'),
    'items',(select coalesce(jsonb_agg(jsonb_build_object(
      'requirementId',r.id,'orderItemId',r.order_item_id,'lineNumber',i.line_number,
      'sku',r.sku,'reference',r.reference,'description',r.description,
      'unitsRequired',r.units_required,'lengthEach',r.length_each,'totalLength',r.total_length,
      'resolution',r.resolution_code,'readyAt',r.ready_at,'lotNumber',l.lot_number,'location',l.location
    ) order by i.line_number),'[]'::jsonb)
      from erp_supply.cut_requirements r
      join erp_supply.order_items i on i.id=r.order_item_id
      left join erp_supply.inventory_lots l on l.id=r.inventory_lot_id
      where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING'),
    'remaining',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING')
  );
end;
$$;

create or replace function public.erp_x_confirm_cut_pickup(p_order_id uuid,p_requirement_ids jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_id uuid;
  v_value jsonb;
  v_count integer:=0;
  v_remaining integer;
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_is_picker boolean:=erp_supply.has_role('aux_logistica');
  v_picking_profile uuid;
begin
  if jsonb_typeof(coalesce(p_requirement_ids,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_requirement_ids,'[]'::jsonb))=0 then
    raise exception 'Marca al menos un corte como recogido';
  end if;

  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=v_org and current_step_code in('CORTE','ALISTAMIENTO') for update;
  if not found then raise exception 'El pedido ya no tiene cortes disponibles para recoger'; end if;
  v_picking_profile:=erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,pickingProfileId}');

  if v_order.current_step_code='ALISTAMIENTO' then
    select * into v_task from erp_supply.order_tasks
    where order_id=p_order_id and step_code='ALISTAMIENTO' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    order by sequence_no desc limit 1 for update;
    if not found then raise exception 'No existe tarea activa de Alistamiento'; end if;
    if v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
    if v_task.assigned_profile_id is distinct from v_actor and not v_override then raise exception 'El pedido está siendo gestionado por otro auxiliar' using errcode='42501'; end if;
  elsif not v_override then
    if not v_is_picker then raise exception 'No autorizado para recoger cortes' using errcode='42501'; end if;
    if v_picking_profile is not null and v_picking_profile<>v_actor then raise exception 'La recogida está asignada a otro auxiliar' using errcode='42501'; end if;
  end if;

  for v_value in select value from jsonb_array_elements(p_requirement_ids) loop
    v_id:=erp_supply.safe_uuid(trim(both '"' from v_value::text));
    if v_id is null then raise exception 'Identificador de corte inválido'; end if;
    update erp_supply.cut_requirements
    set collection_status='COLLECTED',collected_at=now(),collected_by=v_actor,updated_at=now(),
        metadata=metadata||jsonb_build_object('collectionSource',case when v_order.current_step_code='CORTE' then 'EARLY_PICKUP_V10_10' else 'ALISTAMIENTO_V10_10' end)
    where id=v_id and order_id=p_order_id and process_status='READY' and collection_status='PENDING';
    if found then v_count:=v_count+1; end if;
  end loop;

  if v_count=0 then raise exception 'Los cortes seleccionados ya habían sido recogidos'; end if;
  select count(*) into v_remaining from erp_supply.cut_requirements where order_id=p_order_id and process_status='READY' and collection_status='PENDING';

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
      'pendingCollection',v_remaining,'lastPickupAt',now(),'lastPickupBy',v_actor,
      'earlyPickup',(v_order.current_step_code='CORTE'),
      'allCollectedAt',case when v_remaining=0 then to_jsonb(now()) else metadata#>'{cutFlow,allCollectedAt}' end
    )),version=version+1,updated_at=now()
  where id=p_order_id;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','CUT_PICKUP',v_order.current_step_code,v_order.current_step_code,v_actor,(erp_supply.current_roles())[1],jsonb_build_object('collected',v_count,'remaining',v_remaining,'earlyPickup',(v_order.current_step_code='CORTE')));

  return jsonb_build_object('success',true,'collected',v_count,'remaining',v_remaining,'allCollected',(v_remaining=0),'stage',v_order.current_step_code);
end;
$$;

-- Expediente extendido con cortes agrupados y estado de recogida.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
begin
  perform erp_supply.require_profile();
  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;

  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb) from erp_supply.order_items i where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'metadata',c.metadata,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'cutRequirements',(select coalesce(jsonb_agg(to_jsonb(r) order by i.line_number),'[]'::jsonb) from erp_supply.cut_requirements r join erp_supply.order_items i on i.id=r.order_item_id where r.order_id=p_order_id),
    'cutBatches',(select coalesce(jsonb_agg(to_jsonb(b) order by b.executed_at),'[]'::jsonb) from erp_supply.cut_batches b where exists(select 1 from erp_supply.cut_requirements r where r.cut_batch_id=b.id and r.order_id=p_order_id)),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'pickingRounds',(select coalesce(jsonb_agg(to_jsonb(r) order by r.round_no),'[]'::jsonb) from erp_supply.picking_rounds r where r.order_id=p_order_id),
    'pickingRoundItems',(select coalesce(jsonb_agg(to_jsonb(ri) order by r.round_no,i.line_number),'[]'::jsonb) from erp_supply.picking_round_items ri join erp_supply.picking_rounds r on r.id=ri.picking_round_id join erp_supply.order_items i on i.id=ri.order_item_id where r.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

-- Sincroniza pedidos que ya están en Corte.
do $$
declare r record;
begin
  for r in select id from erp_supply.orders where current_step_code='CORTE' and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') loop
    perform erp_supply.sync_cut_requirements(r.id);
  end loop;
end $$;

-- Corrige de forma segura pedidos con corte que aún no habían iniciado Alistamiento.
do $$
declare
  r record;
  v_order erp_supply.orders%rowtype;
  v_sequence integer;
  v_new_task erp_supply.order_tasks%rowtype;
begin
  for r in
    select o.id,t.id task_id
    from erp_supply.orders o
    join erp_supply.order_tasks t on t.order_id=o.id and t.step_code='ALISTAMIENTO' and t.status in('QUEUED','ASSIGNED')
    where o.current_step_code='ALISTAMIENTO' and o.requires_cut
      and not exists(select 1 from erp_supply.picking_rounds pr where pr.order_id=o.id)
  loop
    update erp_supply.order_tasks set status='CANCELLED',completed_at=now(),result_code='REROUTED_TO_CUT',result_detail='Flujo corregido: Corte antes de Alistamiento' where id=r.task_id;
    select * into v_order from erp_supply.orders where id=r.id for update;
    select coalesce(max(sequence_no),0)+1 into v_sequence from erp_supply.order_tasks where order_id=r.id;
    update erp_supply.orders set metadata=metadata||jsonb_build_object('cutFlow',jsonb_build_object('version','10.10','cutFirst',true,'reroutedAt',now())),version=version+1 where id=r.id returning * into v_order;
    select * into v_new_task from erp_supply.create_task(v_order,'CORTE',v_sequence);
    insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,payload)
    values(v_order.organization_id,r.id,r.task_id,'ROUTE_CORRECTION','CUT_BEFORE_PICKING','ALISTAMIENTO','CORTE',v_order.status,v_new_task.status,jsonb_build_object('version','10.10','newTaskId',v_new_task.id));
  end loop;
end $$;

revoke all on function public.erp_x_cutting_groups(text,integer,integer) from public,anon,authenticated;
revoke all on function public.erp_x_cutting_group(text) from public,anon,authenticated;
revoke all on function public.erp_x_execute_cut_group(text,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_resolve_cut_requirement(uuid,text,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_cut_pickups_pending(text,integer,integer) from public,anon,authenticated;
revoke all on function public.erp_x_cut_pickup_detail(uuid) from public,anon,authenticated;
revoke all on function public.erp_x_confirm_cut_pickup(uuid,jsonb) from public,anon,authenticated;

grant execute on function public.erp_x_cutting_groups(text,integer,integer) to authenticated;
grant execute on function public.erp_x_cutting_group(text) to authenticated;
grant execute on function public.erp_x_execute_cut_group(text,jsonb) to authenticated;
grant execute on function public.erp_x_resolve_cut_requirement(uuid,text,jsonb) to authenticated;
grant execute on function public.erp_x_cut_pickups_pending(text,integer,integer) to authenticated;
grant execute on function public.erp_x_cut_pickup_detail(uuid) to authenticated;
grant execute on function public.erp_x_confirm_cut_pickup(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;

notify pgrst,'reload schema';

commit;
