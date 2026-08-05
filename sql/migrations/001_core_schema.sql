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
