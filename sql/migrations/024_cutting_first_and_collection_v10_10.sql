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
