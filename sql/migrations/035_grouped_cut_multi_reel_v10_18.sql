-- ERP EI V10.18
-- Corte por referencia con trazabilidad física multi-carreto.
-- Base requerida: V10.17 + migraciones anteriores aplicadas.

begin;

-- ---------------------------------------------------------------------------
-- 1. PROGRESO PARCIAL POR REQUERIMIENTO Y TRAZABILIDAD DE CADA CARRETO
-- ---------------------------------------------------------------------------

alter table erp_supply.cut_requirements
  add column if not exists units_completed numeric(18,4) not null default 0;
alter table erp_supply.cut_requirements
  add column if not exists length_completed numeric(18,4) not null default 0;

update erp_supply.cut_requirements
set units_completed=units_required,
    length_completed=total_length
where process_status='READY'
  and (units_completed<units_required or length_completed<total_length);

update erp_supply.cut_requirements
set units_completed=least(greatest(units_completed,0),units_required),
    length_completed=least(greatest(length_completed,0),total_length);

create table if not exists erp_supply.cut_batch_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id) on delete cascade,
  cut_batch_id uuid not null references erp_supply.cut_batches(id) on delete cascade,
  cut_requirement_id uuid not null references erp_supply.cut_requirements(id) on delete cascade,
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  units_cut numeric(18,4) not null check(units_cut>0),
  length_each numeric(18,4) not null check(length_each>0),
  total_length numeric(18,4) not null check(total_length>0),
  inventory_lot_id uuid references erp_supply.inventory_lots(id) on delete set null,
  created_at timestamptz not null default now(),
  unique(cut_batch_id,cut_requirement_id)
);
create index if not exists idx_cut_batch_allocations_requirement
  on erp_supply.cut_batch_allocations(cut_requirement_id,created_at);
create index if not exists idx_cut_batch_allocations_order
  on erp_supply.cut_batch_allocations(order_id,created_at);

-- ---------------------------------------------------------------------------
-- 2. PLANIFICADOR INTERNO: SOLO ASIGNA CORTES COMPLETOS QUE CABEN EN EL CARRETO
-- ---------------------------------------------------------------------------

create or replace function erp_supply.cut_plan_rows(
  p_org uuid,
  p_group_key text,
  p_capacity numeric,
  p_actor uuid,
  p_override boolean
)
returns table(
  requirement_id uuid,
  order_id uuid,
  order_item_id uuid,
  units_to_cut numeric,
  length_each numeric,
  length_to_cut numeric,
  units_remaining_before numeric,
  units_remaining_after numeric
)
language plpgsql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_req record;
  v_available numeric:=greatest(coalesce(p_capacity,0),0);
  v_units_left numeric;
  v_units_fit numeric;
  v_units_take numeric;
begin
  if v_available<=0 then return; end if;

  for v_req in
    select r.*,o.priority,o.order_number
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=p_org
      and r.group_key=p_group_key
      and r.process_status<>'READY'
      and not exists(
        select 1 from erp_supply.order_issues oi
        where oi.order_id=o.id and oi.blocking and oi.status='OPEN'
      )
      and (p_override or r.assigned_profile_id is null or r.assigned_profile_id=p_actor)
    order by
      case upper(coalesce(o.priority,'MEDIUM'))
        when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3
        when 'MEDIUM' then 4 when 'LOW' then 5 else 6 end,
      r.created_at,
      o.order_number,
      r.id
  loop
    v_units_left:=greatest(v_req.units_required-coalesce(v_req.units_completed,0),0);
    if v_units_left<=0 or v_req.length_each<=0 then continue; end if;
    if v_req.length_each>v_available then continue; end if;

    v_units_fit:=floor(v_available/v_req.length_each);
    v_units_take:=least(v_units_left,v_units_fit);
    if v_units_take<=0 then continue; end if;

    requirement_id:=v_req.id;
    order_id:=v_req.order_id;
    order_item_id:=v_req.order_item_id;
    units_to_cut:=v_units_take;
    length_each:=v_req.length_each;
    length_to_cut:=round((v_units_take*v_req.length_each)::numeric,4);
    units_remaining_before:=v_units_left;
    units_remaining_after:=greatest(v_units_left-v_units_take,0);
    return next;

    v_available:=v_available-length_to_cut;
    exit when v_available<=0;
  end loop;
end;
$$;

revoke all on function erp_supply.cut_plan_rows(uuid,text,numeric,uuid,boolean) from public;

-- ---------------------------------------------------------------------------
-- 3. LISTA DE CORTE: LOS TOTALES SON LO QUE REALMENTE FALTA POR EJECUTAR
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_groups(
  p_search text default null,p_page integer default 1,p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
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
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    where r.organization_id=v_org and r.process_status<>'READY'
      and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description) like '%'||lower(p_search)||'%')
  ), grouped as(select group_key from eligible group by group_key)
  select count(*) into v_total from grouped;

  with eligible as (
    select r.*,o.order_number,o.client_name,o.priority,mv.variant_label
    from erp_supply.cut_requirements r
    join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
    left join erp_supply.material_variants mv on mv.id=r.material_variant_id
    where r.organization_id=v_org and r.process_status<>'READY'
      and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
      and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
      and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
      and (p_search is null or p_search='' or lower(coalesce(r.reference,'')||' '||coalesce(r.sku,'')||' '||r.description||' '||coalesce(mv.variant_label,'')) like '%'||lower(p_search)||'%')
  ), grouped as (
    select group_key,max(reference) reference,max(sku) sku,max(description) description,
      min(material_master_id::text)::uuid material_master_id,
      min(material_variant_id::text)::uuid material_variant_id,
      max(variant_label) variant_label,
      count(*)::integer item_count,
      count(distinct order_id)::integer order_count,
      sum(greatest(units_required-coalesce(units_completed,0),0)) cut_count,
      sum(greatest(total_length-coalesce(length_completed,0),0)) total_length,
      sum(coalesce(length_completed,0)) completed_length,
      min(created_at) oldest_at,
      bool_or(process_status='IN_PROGRESS' or coalesce(length_completed,0)>0) in_progress
    from eligible
    group by group_key
    order by in_progress desc,oldest_at
    offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'groupKey',group_key,'reference',reference,'sku',sku,'description',description,
    'materialMasterId',material_master_id,'materialVariantId',material_variant_id,'variantLabel',variant_label,
    'itemCount',item_count,'orderCount',order_count,'cutCount',cut_count,'totalLength',total_length,
    'completedLength',completed_length,'oldestAt',oldest_at,'inProgress',in_progress
  )),'[]'::jsonb) into v_items from grouped;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),
    'generatedAt',now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. DETALLE DEL GRUPO: UNA REFERENCIA, MUCHOS PEDIDOS, VARIOS CARRETOS POSIBLES
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_group(p_group_key text)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_actor uuid:=erp_supply.require_profile();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reference text;v_sku text;v_description text;v_material uuid;v_variant uuid;v_variant_label text;
begin
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar Corte' using errcode='42501';
  end if;

  select max(r.reference),max(r.sku),max(r.description),min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid
  into v_reference,v_sku,v_description,v_material,v_variant
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);

  if v_description is null then raise exception 'El grupo ya no tiene cortes pendientes'; end if;
  if v_material is null then raise exception 'El grupo no está vinculado al maestro Siesa. Corrige la referencia en Recepción.'; end if;
  select variant_label into v_variant_label from erp_supply.material_variants where id=v_variant;

  return jsonb_build_object(
    'group',jsonb_build_object(
      'groupKey',p_group_key,'reference',v_reference,'sku',v_sku,'description',v_description,
      'materialMasterId',v_material,'materialVariantId',v_variant,'variantLabel',v_variant_label,
      'itemCount',(select count(*) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and greatest(r.total_length-coalesce(r.length_completed,0),0)>0 and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'orderCount',(select count(distinct r.order_id) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and greatest(r.total_length-coalesce(r.length_completed,0),0)>0 and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'cutCount',(select coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'totalLength',(select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0) from erp_supply.cut_requirements r join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED') where r.group_key=p_group_key and r.organization_id=v_org and r.process_status<>'READY' and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN') and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
      'completedLength',(select coalesce(sum(r.length_completed),0) from erp_supply.cut_requirements r where r.group_key=p_group_key and r.organization_id=v_org)
    ),
    'items',(select coalesce(jsonb_agg(jsonb_build_object(
      'requirementId',r.id,'orderId',r.order_id,'orderNumber',o.order_number,'clientName',o.client_name,
      'priority',o.priority,'orderItemId',r.order_item_id,'lineNumber',i.line_number,'sku',r.sku,'reference',r.reference,'description',r.description,'unit',r.unit,
      'materialMasterId',r.material_master_id,'materialVariantId',r.material_variant_id,'variantLabel',mv.variant_label,
      'unitsRequired',r.units_required,'unitsCompleted',coalesce(r.units_completed,0),
      'unitsRemaining',greatest(r.units_required-coalesce(r.units_completed,0),0),
      'lengthEach',r.length_each,'totalLength',r.total_length,'lengthCompleted',coalesce(r.length_completed,0),
      'remainingLength',greatest(r.total_length-coalesce(r.length_completed,0),0),
      'processStatus',r.process_status,'taskStatus',case when r.process_status='IN_PROGRESS' then 'IN_PROGRESS' else 'PENDING' end,
      'assigneeId',r.assigned_profile_id,'assigneeName',p.display_name
    ) order by case upper(o.priority) when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.order_number,i.line_number),'[]'::jsonb)
      from erp_supply.cut_requirements r
      join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
      join erp_supply.order_items i on i.id=r.order_item_id
      left join erp_supply.profiles p on p.id=r.assigned_profile_id
      left join erp_supply.material_variants mv on mv.id=r.material_variant_id
      where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
        and greatest(r.total_length-coalesce(r.length_completed,0),0)>0
        and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
        and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)),
    'reels',(select coalesce(jsonb_agg(jsonb_build_object(
      'lotId',l.id,'inventoryItemId',ii.id,'lotNumber',l.lot_number,'serialNumber',l.serial_number,
      'variantLabel',mv.variant_label,'location',l.location,'locationName',l.source_location_name,
      'warehouseCode',l.warehouse_code,'quantityAvailable',l.quantity_available,'unit',ii.unit,
      'sourceSystem',l.source_system,'updatedAt',ii.updated_at
    ) order by l.quantity_available asc),'[]'::jsonb)
      from erp_supply.inventory_items ii
      join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
      left join erp_supply.material_variants mv on mv.id=l.material_variant_id
      where ii.organization_id=v_org and ii.active and ii.material_master_id=v_material
        and l.source_active and l.quantity_available>0 and l.material_variant_id is not distinct from v_variant),
    'recentBatches',(select coalesce(jsonb_agg(jsonb_build_object(
      'id',b.id,'lotId',b.inventory_lot_id,'lotNumber',l.lot_number,'location',l.location,
      'reelInitialLength',b.reel_initial_length,'cutLength',b.requested_length,'scrapLength',b.scrap_length,
      'remainingLength',b.remaining_length,'executedAt',b.executed_at,
      'allocations',(select coalesce(jsonb_agg(jsonb_build_object('orderId',a.order_id,'orderNumber',o.order_number,'unitsCut',a.units_cut,'lengthEach',a.length_each,'totalLength',a.total_length) order by o.order_number),'[]'::jsonb) from erp_supply.cut_batch_allocations a join erp_supply.orders o on o.id=a.order_id where a.cut_batch_id=b.id)
    ) order by b.executed_at desc),'[]'::jsonb)
      from (select * from erp_supply.cut_batches where organization_id=v_org and group_key=p_group_key order by executed_at desc limit 10) b
      left join erp_supply.inventory_lots l on l.id=b.inventory_lot_id)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 5. BÚSQUEDA DE ORIGEN FÍSICO, BLOQUEADA A LA MISMA REFERENCIA/VARIANTE
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_origin_search(
  p_group_key text,p_search text default null,p_limit integer default 50
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
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_material uuid;v_variant uuid;v_reference text;v_name text;v_variant_label text;
  v_q text:=lower(trim(coalesce(p_search,'')));
  v_limit integer:=least(greatest(coalesce(p_limit,50),1),100);
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar carretos de Corte' using errcode='42501';
  end if;

  select min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid,max(r.reference),max(r.description)
  into v_material,v_variant,v_reference,v_name
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_material is null then raise exception 'El grupo no tiene material oficial disponible'; end if;
  select variant_label into v_variant_label from erp_supply.material_variants where id=v_variant;

  return jsonb_build_object(
    'material',jsonb_build_object('materialMasterId',v_material,'materialVariantId',v_variant,'reference',v_reference,'name',v_name,'variantLabel',v_variant_label),
    'items',(select coalesce(jsonb_agg(to_jsonb(x) order by x."available" desc,x."warehouseCode",x."location"),'[]'::jsonb) from (
      select l.id "lotId",ii.id "inventoryItemId",l.lot_number "lotNumber",l.serial_number "serialNumber",
        l.warehouse_code "warehouseCode",l.location,l.source_location_name "locationName",
        l.quantity_available "available",l.source_system "sourceSystem",ii.updated_at "updatedAt"
      from erp_supply.inventory_items ii
      join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
      where ii.organization_id=v_org and ii.active and ii.material_master_id=v_material
        and l.source_active and l.quantity_available>0
        and l.material_variant_id is not distinct from v_variant
        and (v_q='' or lower(concat_ws(' ',l.lot_number,l.serial_number,l.warehouse_code,l.location,l.source_location_name,l.source_system)) like '%'||v_q||'%')
      order by l.quantity_available desc,l.warehouse_code,l.location
      limit v_limit
    ) x),
    'generatedAt',now()
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. PREVISUALIZACIÓN EXACTA DEL CARRETO SELECCIONADO
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_batch_plan(
  p_group_key text,p_inventory_lot_id uuid,p_reel_length numeric,p_scrap_length numeric default 0
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
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_material uuid;v_variant uuid;v_inventory_item uuid;v_lot_variant uuid;v_system_length numeric;
  v_capacity numeric;v_used numeric;v_cuts numeric;v_group_before numeric;v_group_after numeric;v_reel_remaining numeric;
  v_plan jsonb;v_approval_required boolean;v_approval_ready boolean;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para planear Corte' using errcode='42501';
  end if;
  if p_inventory_lot_id is null then raise exception 'Selecciona el carreto o lote físico'; end if;
  if p_reel_length is null or p_reel_length<=0 then raise exception 'Indica la cantidad real disponible en el carreto'; end if;
  if coalesce(p_scrap_length,0)<0 then raise exception 'La merma no puede ser negativa'; end if;

  select min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid,
    coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0)
  into v_material,v_variant,v_group_before
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_group_before<=0 or v_material is null then raise exception 'El grupo ya no tiene cortes pendientes'; end if;

  select l.inventory_item_id,l.material_variant_id,l.quantity_available
  into v_inventory_item,v_lot_variant,v_system_length
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where l.id=p_inventory_lot_id and ii.organization_id=v_org and ii.active and ii.material_master_id=v_material
    and l.source_active and l.material_variant_id is not distinct from v_variant;
  if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia y variante'; end if;

  v_capacity:=p_reel_length-coalesce(p_scrap_length,0);
  if v_capacity<=0 then raise exception 'La merma no puede consumir todo el carreto'; end if;

  select coalesce(sum(x.length_to_cut),0),coalesce(sum(x.units_to_cut),0),
    coalesce(jsonb_agg(jsonb_build_object(
      'requirementId',x.requirement_id,'orderId',x.order_id,'orderNumber',o.order_number,'clientName',o.client_name,
      'orderItemId',x.order_item_id,'unitsToCut',x.units_to_cut,'lengthEach',x.length_each,'lengthToCut',x.length_to_cut,
      'unitsRemainingBefore',x.units_remaining_before,'unitsRemainingAfter',x.units_remaining_after,
      'completesRequirement',(x.units_remaining_after<=0)
    ) order by case upper(o.priority) when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.order_number),'[]'::jsonb)
  into v_used,v_cuts,v_plan
  from erp_supply.cut_plan_rows(v_org,p_group_key,v_capacity,v_actor,v_override) x
  join erp_supply.orders o on o.id=x.order_id;

  if v_used<=0 then
    return jsonb_build_object(
      'canExecute',false,'reason','Ningún corte completo cabe en la cantidad indicada para este carreto.',
      'systemLength',v_system_length,'confirmedLength',p_reel_length,'discrepancy',p_reel_length-v_system_length,
      'groupRemainingBefore',v_group_before,'groupRemainingAfter',v_group_before,'plannedLength',0,'plannedCuts',0,
      'plan','[]'::jsonb
    );
  end if;

  v_reel_remaining:=p_reel_length-v_used-coalesce(p_scrap_length,0);
  v_group_after:=greatest(v_group_before-v_used,0);
  v_approval_required:=v_reel_remaining>0 and v_reel_remaining<50;

  select exists(
    select 1 from erp_supply.approval_requests a
    where a.organization_id=v_org
      and a.request_type='STOCK_EXCEPTION'
      and upper(coalesce(a.request_payload->>'exceptionCode',''))='LOW_REEL_REMAINDER'
      and a.request_payload->>'groupKey'=p_group_key
      and a.request_payload->>'inventoryLotId'=p_inventory_lot_id::text
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'reelLength'),0)-p_reel_length)<0.0001
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'plannedLength'),0)-v_used)<0.0001
      and a.status in('APPROVED','EXECUTED')
  ) into v_approval_ready;

  return jsonb_build_object(
    'canExecute',true,
    'inventoryLotId',p_inventory_lot_id,
    'systemLength',v_system_length,
    'confirmedLength',p_reel_length,
    'discrepancy',round((p_reel_length-v_system_length)::numeric,4),
    'plannedLength',v_used,
    'plannedCuts',v_cuts,
    'scrapLength',coalesce(p_scrap_length,0),
    'reelRemaining',v_reel_remaining,
    'groupRemainingBefore',v_group_before,
    'groupRemainingAfter',v_group_after,
    'groupCompleted',(v_group_after<=0),
    'partialBatch',(v_group_after>0),
    'approvalRequired',v_approval_required,
    'approvalReady',v_approval_ready,
    'plan',v_plan
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. APROBACIÓN DE REMANENTE: LIGADA AL CARRETO Y AL PLAN ESPECÍFICO
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_request_cut_remainder_approval(p_group_key text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order_id uuid;
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);
  v_plan jsonb;
  v_planned numeric;
  v_remaining numeric;
  v_assigned text:=coalesce(nullif(trim(p_payload->>'assignedRole'),''),'jefe_logistica');
  v_req erp_supply.approval_requests%rowtype;
begin
  select min(r.order_id) into v_order_id
  from erp_supply.cut_requirements r
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY';
  if v_order_id is null then raise exception 'Grupo sin cortes pendientes'; end if;
  if v_lot_id is null then raise exception 'Selecciona el carreto antes de solicitar aprobación'; end if;

  v_plan:=public.erp_x_cutting_batch_plan(p_group_key,v_lot_id,v_reel,v_scrap);
  if not coalesce((v_plan->>'canExecute')::boolean,false) then raise exception '%',coalesce(v_plan->>'reason','El carreto no permite ejecutar cortes'); end if;
  v_planned:=erp_supply.safe_numeric(v_plan->>'plannedLength');
  v_remaining:=erp_supply.safe_numeric(v_plan->>'reelRemaining');
  if v_remaining>=50 or v_remaining<=0 then raise exception 'La aprobación solo aplica cuando el remanente queda entre 0 y 50 m'; end if;
  if v_assigned not in('auditoria','gerencia','jefe_logistica') then raise exception 'La aprobación debe dirigirse a Auditoría, Gerencia o Jefatura Logística'; end if;

  if exists(
    select 1 from erp_supply.approval_requests a
    where a.organization_id=v_org and a.request_type='STOCK_EXCEPTION' and a.status='PENDING'
      and a.request_payload->>'groupKey'=p_group_key
      and a.request_payload->>'inventoryLotId'=v_lot_id::text
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'reelLength'),0)-v_reel)<0.0001
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'plannedLength'),0)-v_planned)<0.0001
  ) then raise exception 'Ya existe una aprobación pendiente para este carreto y plan de corte'; end if;

  insert into erp_supply.approval_requests(
    organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload
  ) values(
    v_org,v_order_id,'STOCK_EXCEPTION',v_actor,v_assigned,
    coalesce(nullif(trim(p_payload->>'reason'),''),format('Autorizar remanente de %s m en Corte',round(v_remaining,3))),
    jsonb_build_object(
      'exceptionCode','LOW_REEL_REMAINDER','groupKey',p_group_key,'inventoryLotId',v_lot_id,
      'reelLength',v_reel,'plannedLength',v_planned,'scrapLength',v_scrap,'remainingLength',v_remaining,'version','10.18'
    )
  ) returning * into v_req;

  return jsonb_build_object('success',true,'requestId',v_req.id,'remainingLength',v_remaining,'plannedLength',v_planned);
end;
$$;

-- ---------------------------------------------------------------------------
-- 8. EJECUCIÓN TRANSACCIONAL DE UN CARRETO DENTRO DEL GRUPO DE REFERENCIA
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_execute_cut_group(p_group_key text,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);
  v_lot_id uuid:=erp_supply.safe_uuid(p_payload->>'inventoryLotId');
  v_expected_planned numeric:=erp_supply.safe_numeric(p_payload->>'expectedPlannedLength');
  v_material uuid;v_variant uuid;v_reference text;v_description text;
  v_group_before numeric;v_group_after numeric;v_used numeric;v_cuts numeric;v_reel_remaining numeric;
  v_inventory_item erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_system_length numeric;v_difference numeric;
  v_batch erp_supply.cut_batches%rowtype;
  v_plan record;
  v_req erp_supply.cut_requirements%rowtype;
  v_job erp_supply.cut_jobs%rowtype;
  v_new_units numeric;v_new_length numeric;
  v_orders uuid[]:='{}'::uuid[];
  v_order_id uuid;
  v_count integer:=0;
  v_remaining_cuts numeric;
begin
  if not (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para ejecutar cortes' using errcode='42501';
  end if;
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;
  if v_lot_id is null then raise exception 'Selecciona el carreto o lote físico del que vas a cortar'; end if;
  if v_reel is null or v_reel<=0 then raise exception 'Indica la cantidad real disponible en el carreto'; end if;
  if v_scrap<0 then raise exception 'La merma no puede ser negativa'; end if;

  -- Bloquea todos los requerimientos del grupo antes de calcular el plan definitivo.
  perform 1
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
  for update of r;

  select min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid,max(r.reference),max(r.description),
    coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0)
  into v_material,v_variant,v_reference,v_description,v_group_before
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_group_before<=0 or v_material is null then raise exception 'El grupo ya no tiene cortes pendientes'; end if;

  select ii.* into v_inventory_item
  from erp_supply.inventory_items ii
  where ii.organization_id=v_org and ii.active and ii.material_master_id=v_material
  for update;
  if not found then raise exception 'No existe inventario oficial para esta referencia'; end if;

  select l.* into v_lot
  from erp_supply.inventory_lots l
  where l.id=v_lot_id and l.inventory_item_id=v_inventory_item.id and l.source_active
    and l.material_variant_id is not distinct from v_variant
  for update;
  if not found then raise exception 'El carreto seleccionado no corresponde a la misma referencia y variante'; end if;

  v_system_length:=v_lot.quantity_available;

  select coalesce(sum(x.length_to_cut),0),coalesce(sum(x.units_to_cut),0)
  into v_used,v_cuts
  from erp_supply.cut_plan_rows(v_org,p_group_key,v_reel-v_scrap,v_actor,v_override) x;

  if v_used<=0 then raise exception 'Ningún corte completo cabe en la cantidad real indicada para este carreto'; end if;
  if v_expected_planned is not null and abs(v_expected_planned-v_used)>0.0001 then
    raise exception 'El plan de corte cambió desde la vista previa. Vuelve a revisar antes de confirmar.';
  end if;

  v_reel_remaining:=v_reel-v_used-v_scrap;
  if v_reel_remaining<0 then raise exception 'La cantidad del carreto no alcanza para el plan calculado'; end if;

  if v_reel_remaining>0 and v_reel_remaining<50 and not exists(
    select 1 from erp_supply.approval_requests a
    where a.organization_id=v_org and a.request_type='STOCK_EXCEPTION'
      and upper(coalesce(a.request_payload->>'exceptionCode',''))='LOW_REEL_REMAINDER'
      and a.request_payload->>'groupKey'=p_group_key
      and a.request_payload->>'inventoryLotId'=v_lot_id::text
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'reelLength'),0)-v_reel)<0.0001
      and abs(coalesce(erp_supply.safe_numeric(a.request_payload->>'plannedLength'),0)-v_used)<0.0001
      and a.status in('APPROVED','EXECUTED')
  ) then
    raise exception 'APROBACION_REQUERIDA: este carreto quedará con % m. Solicita aprobación para este carreto antes de ejecutar.',round(v_reel_remaining,3);
  end if;

  -- Recuento físico: el auxiliar confirma cuánto hay realmente antes de cortar.
  v_difference:=v_reel-v_system_length;
  if abs(v_difference)>0.0001 then
    update erp_supply.inventory_lots
    set quantity_available=v_reel,
        metadata=metadata||jsonb_build_object('lastPhysicalCountAt',now(),'lastPhysicalCountBy',v_actor,'previousSystemLength',v_system_length,'confirmedPhysicalLength',v_reel)
    where id=v_lot.id
    returning * into v_lot;

    insert into erp_supply.inventory_movements(
      organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,
      actor_profile_id,reference,metadata
    ) values(
      v_org,v_inventory_item.id,v_lot.id,
      case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,
      abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',
      jsonb_build_object('previousLength',v_system_length,'confirmedLength',v_reel,'difference',v_difference,'groupKey',p_group_key,'source','CUT_MULTI_REEL_V10_18')
    );

    insert into erp_supply.order_events(
      organization_id,order_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload
    )
    select distinct v_org,r.order_id,'DOMAIN_RECORD','CUT_REEL_RECOUNT','ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],
      jsonb_build_object('groupKey',p_group_key,'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number,'previousLength',v_system_length,'confirmedLength',v_reel,'difference',v_difference,'nonBlocking',true)
    from erp_supply.cut_requirements r
    where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY';
  end if;

  v_group_after:=greatest(v_group_before-v_used,0);

  insert into erp_supply.cut_batches(
    organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,
    resolution_code,reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata
  ) values(
    v_org,p_group_key,v_reference,v_description,v_inventory_item.id,v_lot.id,'CUT',
    v_reel,v_used,v_scrap,v_reel_remaining,v_actor,
    jsonb_build_object(
      'lotNumber',v_lot.lot_number,'serialNumber',v_lot.serial_number,'warehouseCode',v_lot.warehouse_code,
      'location',v_lot.location,'locationName',v_lot.source_location_name,'version','10.18',
      'groupRemainingBefore',v_group_before,'groupRemainingAfter',v_group_after,'partialBatch',(v_group_after>0),
      'systemLengthBefore',v_system_length,'confirmedPhysicalLength',v_reel,'inventoryDifference',v_difference
    )
  ) returning * into v_batch;

  for v_plan in
    select * from erp_supply.cut_plan_rows(v_org,p_group_key,v_reel-v_scrap,v_actor,v_override)
  loop
    select * into v_req from erp_supply.cut_requirements where id=v_plan.requirement_id for update;
    if not found or v_req.process_status='READY' then continue; end if;

    insert into erp_supply.cut_batch_allocations(
      organization_id,cut_batch_id,cut_requirement_id,order_id,order_item_id,
      units_cut,length_each,total_length,inventory_lot_id
    ) values(
      v_org,v_batch.id,v_req.id,v_req.order_id,v_req.order_item_id,
      v_plan.units_to_cut,v_plan.length_each,v_plan.length_to_cut,v_lot.id
    );

    insert into erp_supply.order_item_allocations(
      organization_id,order_id,order_item_id,inventory_item_id,inventory_lot_id,quantity,unit,
      allocation_type,status,actor_profile_id,metadata
    ) values(
      v_org,v_req.order_id,v_req.order_item_id,v_inventory_item.id,v_lot.id,v_plan.length_to_cut,'M',
      'CUTTING','CONSUMED',v_actor,jsonb_build_object(
        'cutBatchId',v_batch.id,'cutRequirementId',v_req.id,'groupKey',p_group_key,
        'unitsCut',v_plan.units_to_cut,'lengthEach',v_plan.length_each,'version','10.18'
      )
    );

    insert into erp_supply.cut_jobs(
      order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,
      status,assigned_profile_id,started_at,completed_at,metadata
    ) values(
      v_req.order_id,v_req.order_item_id,v_lot.id,v_plan.length_to_cut,v_plan.length_to_cut,0,
      'COMPLETED',v_actor,now(),now(),jsonb_build_object(
        'mode','CUT','batchId',v_batch.id,'units',v_plan.units_to_cut,'lengthEach',v_plan.length_each,
        'partialRequirement',(v_plan.units_remaining_after>0),'cutFlowVersion','10.18'
      )
    ) returning * into v_job;

    v_new_units:=least(v_req.units_required,coalesce(v_req.units_completed,0)+v_plan.units_to_cut);
    v_new_length:=least(v_req.total_length,coalesce(v_req.length_completed,0)+v_plan.length_to_cut);

    update erp_supply.cut_requirements
    set units_completed=v_new_units,
        length_completed=v_new_length,
        process_status=case when v_new_length>=total_length-0.0001 then 'READY' else 'IN_PROGRESS' end,
        resolution_code=case when v_new_length>=total_length-0.0001 then 'CUT' else resolution_code end,
        collection_status=case when v_new_length>=total_length-0.0001 then 'PENDING' else collection_status end,
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=case when v_new_length>=total_length-0.0001 then now() else ready_at end,
        ready_by=case when v_new_length>=total_length-0.0001 then v_actor else ready_by end,
        assigned_profile_id=v_actor,
        metadata=metadata||jsonb_build_object(
          'lastCutBatchId',v_batch.id,'lastInventoryLotId',v_lot.id,'lastCutAt',now(),
          'unitsCompleted',v_new_units,'lengthCompleted',v_new_length,
          'remainingUnits',greatest(units_required-v_new_units,0),'remainingLength',greatest(total_length-v_new_length,0),
          'cutOrigins',coalesce(metadata->'cutOrigins','[]'::jsonb)||jsonb_build_array(jsonb_build_object(
            'batchId',v_batch.id,'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number,'location',v_lot.location,
            'unitsCut',v_plan.units_to_cut,'length',v_plan.length_to_cut
          )),
          'multiReel',true,'cutFlowVersion','10.18'
        ),
        updated_at=now()
    where id=v_req.id
    returning * into v_req;

    if v_req.process_status='READY' then
      update erp_supply.order_items
      set metadata=metadata||jsonb_build_object(
        'cutStatus','READY','cutResolution','CUT','cutRequirementId',v_req.id,
        'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor,
        'cutLengthCompleted',v_req.length_completed,'cutUnitsCompleted',v_req.units_completed,'multiReel',true
      ),updated_at=now()
      where id=v_req.order_item_id;
    else
      update erp_supply.order_items
      set metadata=metadata||jsonb_build_object(
        'cutStatus','IN_PROGRESS','cutRequirementId',v_req.id,'lastCutBatchId',v_batch.id,
        'cutLengthCompleted',v_req.length_completed,'cutUnitsCompleted',v_req.units_completed,
        'cutLengthRemaining',greatest(v_req.total_length-v_req.length_completed,0),'multiReel',true
      ),updated_at=now()
      where id=v_req.order_item_id;

      -- La reserva lógica conserva únicamente lo que todavía falta consumir físicamente.
      update erp_supply.material_reservations
      set quantity=greatest(v_req.total_length-v_req.length_completed,0),
          shortage_quantity=least(shortage_quantity,greatest(v_req.total_length-v_req.length_completed,0)),
          metadata=metadata||jsonb_build_object(
            'originalQuantity',coalesce(metadata->'originalQuantity',to_jsonb(quantity)),
            'partialConsumedBy','CORTE','lastCutBatchId',v_batch.id,'remainingQuantity',greatest(v_req.total_length-v_req.length_completed,0)
          ),
          updated_at=now()
      where order_item_id=v_req.order_item_id and status='ACTIVE';
    end if;

    if not (v_req.order_id=any(v_orders)) then v_orders:=array_append(v_orders,v_req.order_id); end if;
    v_count:=v_count+1;
  end loop;

  update erp_supply.inventory_lots
  set quantity_available=v_reel_remaining,
      metadata=metadata||jsonb_build_object('lastCutBatchId',v_batch.id,'lastCutAt',now(),'lastCutGroupKey',p_group_key)
  where id=v_lot.id;

  insert into erp_supply.inventory_movements(
    organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,
    actor_profile_id,reference,metadata
  ) values(
    v_org,v_inventory_item.id,v_lot.id,'CUT_CONSUMPTION',v_used+v_scrap,'M',v_lot.location,
    v_actor,v_batch.id::text,jsonb_build_object(
      'cutLength',v_used,'scrapLength',v_scrap,'remainingLength',v_reel_remaining,
      'groupKey',p_group_key,'batchId',v_batch.id,'version','10.18'
    )
  );

  foreach v_order_id in array v_orders loop
    perform erp_supply.advance_cut_order_if_ready(v_order_id,v_actor);
  end loop;

  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0),
         coalesce(sum(greatest(r.units_required-coalesce(r.units_completed,0),0)),0)
  into v_group_after,v_remaining_cuts
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY';

  update erp_supply.orders o
  set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.18','parallel',true,'multiReel',true,'lastBatchId',v_batch.id,'lastBatchAt',now()
  )),updated_at=now()
  where o.id=any(v_orders);

  return jsonb_build_object(
    'success',true,'batchId',v_batch.id,'processedRequirements',v_count,'processedCuts',v_cuts,
    'cutLength',v_used,'scrapLength',v_scrap,'reelRemaining',v_reel_remaining,
    'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number,'inventoryDifference',v_difference,
    'groupRemainingLength',v_group_after,'remainingCuts',v_remaining_cuts,'groupCompleted',(v_group_after<=0)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 9. CASOS ESPECIALES COMPATIBLES CON EL NUEVO PROGRESO MULTI-CARRETO
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_resolve_cut_requirement(
  p_requirement_id uuid,
  p_resolution text,
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
  v_override boolean:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  v_resolution text:=upper(trim(coalesce(p_resolution,'')));
  v_req erp_supply.cut_requirements%rowtype;
  v_order erp_supply.orders%rowtype;
  v_reason text:=nullif(trim(p_payload->>'reason'),'');
  v_reel numeric:=erp_supply.safe_numeric(p_payload->>'reelLength');
  v_remaining_length numeric;
  v_remaining_units numeric;
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
  where r.id=p_requirement_id and r.organization_id=v_org and r.process_status<>'READY'
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor)
  for update;
  if not found then raise exception 'El corte ya fue resuelto o no está disponible'; end if;

  select * into v_order from erp_supply.orders
  where id=v_req.order_id and status not in('CLOSED','CANCELLED') for update;
  if not found then raise exception 'El pedido ya no está activo'; end if;
  if exists(select 1 from erp_supply.order_issues oi where oi.order_id=v_order.id and oi.blocking and oi.status='OPEN') then
    raise exception 'El pedido está detenido por una novedad o reporte pendiente. Resuélvelo antes de continuar Corte.';
  end if;

  v_remaining_length:=greatest(v_req.total_length-coalesce(v_req.length_completed,0),0);
  v_remaining_units:=greatest(v_req.units_required-coalesce(v_req.units_completed,0),0);
  if v_remaining_length<=0 then raise exception 'Este requerimiento ya no tiene longitud pendiente'; end if;

  if v_resolution='NO_CUT' then
    if coalesce(v_req.length_completed,0)>0 then raise exception 'No puedes marcar No necesita corte después de haber ejecutado parte de esta línea'; end if;
    if v_reason is null then raise exception 'Explica por qué la referencia no necesita corte'; end if;

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='NO_CUT',collection_status='PENDING',
        units_completed=units_required,length_completed=total_length,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
        metadata=metadata||jsonb_build_object('reason',v_reason,'cutFlowVersion','10.18'),updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set requires_cut=false,requested_cut_length=null,
        metadata=metadata||jsonb_build_object(
          'cutStatus','READY','cutResolution','NO_CUT','cutRequirementId',v_req.id,
          'cutReadyAt',now(),'cutReadyBy',v_actor,'cutNoNeedReason',v_reason,
          'originalRequestedCutLength',v_req.length_each,'cutFlowVersion','10.18'
        ),updated_at=now()
    where id=v_req.order_item_id;

    insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
    values(v_req.order_id,v_actor,'NOVELTY','INTERNAL',
      format('Corte corregido: la referencia %s no necesita corte. %s',coalesce(v_req.reference,v_req.sku,v_req.description),v_reason),
      jsonb_build_object('source','CORTE','resolution','NO_CUT','requirementId',v_req.id,'version','10.18'));
  else
    if v_lot_id is null then raise exception 'Selecciona el carreto físico que se entregará completo'; end if;
    if v_reel is null or v_reel<=0 then raise exception 'Indica la medida del carreto completo'; end if;
    if abs(v_reel-v_remaining_length)>0.0001 then
      raise exception 'Carreto completo solo aplica cuando la medida física (%) coincide con lo pendiente de esta línea (%)',v_reel,v_remaining_length;
    end if;
    if v_req.material_master_id is null then raise exception 'La línea no tiene material oficial Siesa'; end if;

    select * into v_inventory_item
    from erp_supply.inventory_items ii
    where ii.organization_id=v_org and ii.active and ii.material_master_id=v_req.material_master_id
    for update;
    if not found then raise exception 'No existe inventario oficial para esta referencia'; end if;

    select * into v_lot
    from erp_supply.inventory_lots l
    where l.id=v_lot_id and l.inventory_item_id=v_inventory_item.id and l.source_active
      and l.material_variant_id is not distinct from v_req.material_variant_id
    for update;
    if not found then raise exception 'El carreto seleccionado no corresponde a esta referencia y variante'; end if;

    v_difference:=v_reel-v_lot.quantity_available;
    if abs(v_difference)>0.0001 then
      update erp_supply.inventory_lots
      set quantity_available=v_reel,
          metadata=metadata||jsonb_build_object('lastPhysicalCountAt',now(),'lastPhysicalCountBy',v_actor,'previousSystemLength',v_lot.quantity_available,'confirmedPhysicalLength',v_reel)
      where id=v_lot.id returning * into v_lot;
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata
      ) values(
        v_org,v_inventory_item.id,v_lot.id,case when v_difference>0 then 'ADJUSTMENT_IN' else 'ADJUSTMENT_OUT' end,
        abs(v_difference),'M',v_lot.location,v_lot.location,v_actor,'RECUENTO-CARRETO',
        jsonb_build_object('confirmedLength',v_reel,'difference',v_difference,'requirementId',v_req.id,'source','FULL_REEL_V10_18')
      );
    end if;

    insert into erp_supply.cut_batches(
      organization_id,group_key,reference,description,inventory_item_id,inventory_lot_id,resolution_code,
      reel_initial_length,requested_length,scrap_length,remaining_length,executed_by,metadata
    ) values(
      v_org,v_req.group_key,v_req.reference,v_req.description,v_inventory_item.id,v_lot.id,'FULL_REEL',
      v_reel,v_remaining_length,0,0,v_actor,
      jsonb_build_object('requirementId',v_req.id,'version','10.18','partialBefore',(coalesce(v_req.length_completed,0)>0))
    ) returning * into v_batch;

    insert into erp_supply.cut_batch_allocations(
      organization_id,cut_batch_id,cut_requirement_id,order_id,order_item_id,units_cut,length_each,total_length,inventory_lot_id
    ) values(
      v_org,v_batch.id,v_req.id,v_req.order_id,v_req.order_item_id,v_remaining_units,v_req.length_each,v_remaining_length,v_lot.id
    );

    insert into erp_supply.order_item_allocations(
      organization_id,order_id,order_item_id,inventory_item_id,inventory_lot_id,quantity,unit,
      allocation_type,status,actor_profile_id,metadata
    ) values(
      v_org,v_req.order_id,v_req.order_item_id,v_inventory_item.id,v_lot.id,v_remaining_length,'M',
      'CUTTING','CONSUMED',v_actor,jsonb_build_object('cutBatchId',v_batch.id,'cutRequirementId',v_req.id,'resolution','FULL_REEL','version','10.18')
    );

    insert into erp_supply.cut_jobs(
      order_id,order_item_id,inventory_lot_id,requested_length,actual_length,scrap_length,status,
      assigned_profile_id,started_at,completed_at,metadata
    ) values(
      v_req.order_id,v_req.order_item_id,v_lot.id,v_remaining_length,v_remaining_length,0,'COMPLETED',
      v_actor,now(),now(),jsonb_build_object('mode','FULL_REEL','batchId',v_batch.id,'units',v_remaining_units,'cutFlowVersion','10.18')
    ) returning * into v_job;

    update erp_supply.inventory_lots
    set quantity_available=0,
        metadata=metadata||jsonb_build_object('issuedCompleteAt',now(),'cutBatchId',v_batch.id,'cutFlowVersion','10.18')
    where id=v_lot.id;

    insert into erp_supply.inventory_movements(
      organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,actor_profile_id,reference,metadata
    ) values(
      v_org,v_inventory_item.id,v_lot.id,v_req.order_id,'FULL_REEL_ISSUE',v_remaining_length,'M',v_lot.location,
      v_actor,v_batch.id::text,jsonb_build_object('requirementId',v_req.id,'version','10.18')
    );

    update erp_supply.cut_requirements
    set process_status='READY',resolution_code='FULL_REEL',collection_status='PENDING',
        units_completed=units_required,length_completed=total_length,
        cut_batch_id=v_batch.id,cut_job_id=v_job.id,inventory_lot_id=v_lot.id,
        ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
        metadata=metadata||jsonb_build_object(
          'lastCutBatchId',v_batch.id,
          'cutOrigins',coalesce(metadata->'cutOrigins','[]'::jsonb)||jsonb_build_array(jsonb_build_object(
            'batchId',v_batch.id,'inventoryLotId',v_lot.id,'lotNumber',v_lot.lot_number,'location',v_lot.location,
            'unitsCut',v_remaining_units,'length',v_remaining_length
          )),
          'multiReel',true,'cutFlowVersion','10.18'
        ),
        updated_at=now()
    where id=v_req.id;

    update erp_supply.order_items
    set metadata=metadata||jsonb_build_object(
      'cutStatus','READY','cutResolution','FULL_REEL','cutRequirementId',v_req.id,
      'cutBatchId',v_batch.id,'cutReadyAt',now(),'cutReadyBy',v_actor,'multiReel',true,'cutFlowVersion','10.18'
    ),updated_at=now()
    where id=v_req.order_item_id;
  end if;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_req.order_id,v_req.task_id,'DOMAIN_RECORD',v_resolution,'ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('requirementId',v_req.id,'reason',v_reason,'version','10.18')
  );

  perform erp_supply.advance_cut_order_if_ready(v_req.order_id,v_actor);
  return jsonb_build_object('success',true,'requirementId',v_req.id,'resolution',v_resolution,'orderId',v_req.order_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- 10. RECOGIDA: MUESTRA TODOS LOS CARRETOS QUE ALIMENTARON CADA LÍNEA
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cut_pickup_detail(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
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
      'resolution',r.resolution_code,'readyAt',r.ready_at,
      'lotNumber',coalesce((select case when count(distinct a.inventory_lot_id)>1 then count(distinct a.inventory_lot_id)::text||' carretos' else max(l.lot_number) end from erp_supply.cut_batch_allocations a left join erp_supply.inventory_lots l on l.id=a.inventory_lot_id where a.cut_requirement_id=r.id),l_last.lot_number),
      'location',coalesce((select case when count(distinct a.inventory_lot_id)>1 then 'Varios orígenes' else max(l.location) end from erp_supply.cut_batch_allocations a left join erp_supply.inventory_lots l on l.id=a.inventory_lot_id where a.cut_requirement_id=r.id),l_last.location),
      'origins',(select coalesce(jsonb_agg(jsonb_build_object(
        'inventoryLotId',z.inventory_lot_id,'lotNumber',z.lot_number,'location',z.location,'warehouseCode',z.warehouse_code,
        'totalLength',z.total_length,'batches',z.batch_count
      ) order by z.lot_number),'[]'::jsonb) from (
        select a.inventory_lot_id,max(l.lot_number) lot_number,max(l.location) location,max(l.warehouse_code) warehouse_code,
          sum(a.total_length) total_length,count(distinct a.cut_batch_id) batch_count
        from erp_supply.cut_batch_allocations a
        left join erp_supply.inventory_lots l on l.id=a.inventory_lot_id
        where a.cut_requirement_id=r.id
        group by a.inventory_lot_id
      ) z)
    ) order by i.line_number),'[]'::jsonb)
      from erp_supply.cut_requirements r
      join erp_supply.order_items i on i.id=r.order_item_id
      left join erp_supply.inventory_lots l_last on l_last.id=r.inventory_lot_id
      where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING'),
    'remaining',(select count(*) from erp_supply.cut_requirements r where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 11. OPTIMIZADOR ACTUALIZADO: SI UN CARRETO NO CUBRE TODO, SUGIERE EL MEJOR
--    PARA AVANZAR EL MAYOR NÚMERO DE CORTES COMPLETOS.
-- ---------------------------------------------------------------------------

create or replace function public.erp_x_cutting_optimizer(p_group_key text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();
  v_override boolean:=erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia');
  v_needed numeric;v_reference text;v_sku text;v_description text;v_material uuid;v_variant uuid;v_variant_label text;
  v_candidates jsonb;v_recommended jsonb;
begin
  if not (erp_supply.can_access_module('cutting','read') or erp_supply.has_role('auxiliar_corte') or v_override) then
    raise exception 'No autorizado para consultar el optimizador de Corte' using errcode='42501';
  end if;
  if nullif(trim(p_group_key),'') is null then raise exception 'Grupo de corte requerido'; end if;

  select coalesce(sum(greatest(r.total_length-coalesce(r.length_completed,0),0)),0),max(r.reference),max(r.sku),max(r.description),
    min(r.material_master_id::text)::uuid,min(r.material_variant_id::text)::uuid
  into v_needed,v_reference,v_sku,v_description,v_material,v_variant
  from erp_supply.cut_requirements r
  join erp_supply.orders o on o.id=r.order_id and o.status not in('CLOSED','CANCELLED')
  where r.organization_id=v_org and r.group_key=p_group_key and r.process_status<>'READY'
    and not exists(select 1 from erp_supply.order_issues oi where oi.order_id=o.id and oi.blocking and oi.status='OPEN')
    and (v_override or r.assigned_profile_id is null or r.assigned_profile_id=v_actor);
  if v_needed<=0 then raise exception 'El grupo ya no tiene cortes pendientes'; end if;
  if v_material is null then raise exception 'El grupo no tiene identidad oficial Siesa'; end if;
  select variant_label into v_variant_label from erp_supply.material_variants where id=v_variant;

  with candidates as (
    select l.id lot_id,l.lot_number,l.serial_number,l.location,l.source_location_name,l.warehouse_code,l.source_system,
      l.quantity_available usable_length,
      (select coalesce(sum(p.length_to_cut),0) from erp_supply.cut_plan_rows(v_org,p_group_key,l.quantity_available,v_actor,v_override) p) planned_length,
      (select coalesce(sum(p.units_to_cut),0) from erp_supply.cut_plan_rows(v_org,p_group_key,l.quantity_available,v_actor,v_override) p) planned_cuts
    from erp_supply.inventory_items ii
    join erp_supply.inventory_lots l on l.inventory_item_id=ii.id
    where ii.organization_id=v_org and ii.active and ii.material_master_id=v_material
      and l.source_active and l.quantity_available>0 and l.material_variant_id is not distinct from v_variant
  ), ranked as (
    select c.*,
      c.usable_length-c.planned_length projected_remaining,
      (c.planned_length>=v_needed-0.0001) sufficient,
      (c.usable_length-c.planned_length>0 and c.usable_length-c.planned_length<50) approval_required,
      row_number() over(order by
        case when c.planned_length>=v_needed-0.0001 and (c.usable_length-c.planned_length=0 or c.usable_length-c.planned_length>=50) then 0
             when c.planned_length>=v_needed-0.0001 then 1 else 2 end,
        case when c.planned_length>=v_needed-0.0001 then c.usable_length-c.planned_length else -c.planned_length end,
        c.usable_length desc
      ) operational_rank
    from candidates c
    where c.planned_length>0
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'lotId',lot_id,'lotNumber',lot_number,'serialNumber',serial_number,'location',location,'locationName',source_location_name,
    'warehouseCode',warehouse_code,'sourceSystem',source_system,'usableLength',usable_length,
    'plannedLength',planned_length,'plannedCuts',planned_cuts,'projectedRemaining',projected_remaining,
    'sufficient',sufficient,'approvalRequired',approval_required,'operationalRank',operational_rank
  ) order by operational_rank),'[]'::jsonb),
  (select jsonb_build_object(
    'lotId',r2.lot_id,'lotNumber',r2.lot_number,'serialNumber',r2.serial_number,'location',r2.location,'locationName',r2.source_location_name,
    'warehouseCode',r2.warehouse_code,'sourceSystem',r2.source_system,'usableLength',r2.usable_length,
    'plannedLength',r2.planned_length,'plannedCuts',r2.planned_cuts,'projectedRemaining',r2.projected_remaining,
    'sufficient',r2.sufficient,'approvalRequired',r2.approval_required
  ) from ranked r2 order by r2.operational_rank limit 1)
  into v_candidates,v_recommended
  from (select * from ranked order by operational_rank limit 10) r;

  return jsonb_build_object(
    'groupKey',p_group_key,'reference',v_reference,'sku',v_sku,'description',v_description,
    'materialMasterId',v_material,'materialVariantId',v_variant,'variantLabel',v_variant_label,
    'requiredLength',v_needed,'recommended',v_recommended,'bestMaterialUse',v_recommended,
    'candidates',v_candidates,'generatedAt',now(),
    'rule',jsonb_build_object('criticalRemainderMeters',50,'strategy','Completar la referencia con uno o varios carretos; nunca mezclar material o variante')
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 12. PERMISOS Y VALIDACIÓN
-- ---------------------------------------------------------------------------

revoke all on function public.erp_x_cutting_origin_search(text,text,integer) from public,anon;
revoke all on function public.erp_x_cutting_batch_plan(text,uuid,numeric,numeric) from public,anon;
grant execute on function public.erp_x_cutting_origin_search(text,text,integer) to authenticated;
grant execute on function public.erp_x_cutting_batch_plan(text,uuid,numeric,numeric) to authenticated;
grant execute on function public.erp_x_cutting_groups(text,integer,integer) to authenticated;
grant execute on function public.erp_x_cutting_group(text) to authenticated;
grant execute on function public.erp_x_cutting_optimizer(text) to authenticated;
grant execute on function public.erp_x_execute_cut_group(text,jsonb) to authenticated;
grant execute on function public.erp_x_request_cut_remainder_approval(text,jsonb) to authenticated;

do $$
begin
  if to_regprocedure('public.erp_x_cutting_origin_search(text,text,integer)') is null then raise exception 'Falta búsqueda de origen físico V10.18'; end if;
  if to_regprocedure('public.erp_x_cutting_batch_plan(text,uuid,numeric,numeric)') is null then raise exception 'Falta planificador multi-carreto V10.18'; end if;
  if to_regclass('erp_supply.cut_batch_allocations') is null then raise exception 'Falta trazabilidad de asignaciones por carreto V10.18'; end if;
end;
$$;

notify pgrst,'reload schema';
commit;
