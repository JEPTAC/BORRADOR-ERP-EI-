-- ERP Electroingeniería V10.15
-- Materiales comerciales simples en Ventas + reserva lógica + origen físico en Alistamiento.
-- Base requerida: V10.14.3 con maestro Siesa activo.

begin;

create table if not exists erp_supply.material_reservations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  material_master_id uuid not null references erp_supply.material_master(id),
  material_variant_id uuid references erp_supply.material_variants(id),
  quantity numeric(18,4) not null check(quantity>0),
  unit text not null,
  status text not null default 'ACTIVE' check(status in('ACTIVE','CONSUMED','RELEASED')),
  shortage_quantity numeric(18,4) not null default 0 check(shortage_quantity>=0),
  created_by uuid references erp_supply.profiles(id),
  consumed_at timestamptz,
  released_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(order_item_id)
);
create index if not exists idx_material_reservations_active
  on erp_supply.material_reservations(organization_id,material_master_id,material_variant_id,status);
create index if not exists idx_material_reservations_order
  on erp_supply.material_reservations(order_id,status);

create table if not exists erp_supply.order_item_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  inventory_item_id uuid not null references erp_supply.inventory_items(id),
  inventory_lot_id uuid not null references erp_supply.inventory_lots(id),
  quantity numeric(18,4) not null check(quantity>0),
  unit text not null,
  allocation_type text not null default 'PICKING' check(allocation_type in('PICKING','CUTTING')),
  status text not null default 'CONSUMED' check(status in('CONSUMED','RELEASED')),
  actor_profile_id uuid references erp_supply.profiles(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists idx_order_item_allocations_item on erp_supply.order_item_allocations(order_item_id,created_at);
create index if not exists idx_order_item_allocations_lot on erp_supply.order_item_allocations(inventory_lot_id,created_at);

create or replace function erp_supply.order_item_required_quantity(p_item erp_supply.order_items)
returns numeric
language sql
immutable
as $$
  select case
    when coalesce(p_item.requires_cut,false) then round((p_item.quantity*coalesce(p_item.requested_cut_length,0))::numeric,4)
    when p_item.unit='M' and coalesce(p_item.metadata->>'cutResolution','')='NO_CUT'
      and erp_supply.safe_numeric(p_item.metadata->>'originalRequestedCutLength') is not null
      then round((p_item.quantity*erp_supply.safe_numeric(p_item.metadata->>'originalRequestedCutLength'))::numeric,4)
    else round(p_item.quantity::numeric,4)
  end
$$;

create or replace function erp_supply.material_physical_available(
  p_org uuid,p_material uuid,p_variant uuid default null
)
returns numeric
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select coalesce(sum(l.quantity_available),0)
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items i on i.id=l.inventory_item_id
  where i.organization_id=p_org and i.active and i.material_master_id=p_material
    and l.source_active
    and l.material_variant_id is not distinct from p_variant
$$;

create or replace function erp_supply.material_erp_reserved(
  p_org uuid,p_material uuid,p_variant uuid default null,p_exclude_item uuid default null
)
returns numeric
language sql
stable
security definer
set search_path=erp_supply,public,pg_catalog
as $$
  select coalesce(sum(r.quantity),0)
  from erp_supply.material_reservations r
  where r.organization_id=p_org and r.material_master_id=p_material
    and r.material_variant_id is not distinct from p_variant
    and r.status='ACTIVE'
    and (p_exclude_item is null or r.order_item_id<>p_exclude_item)
$$;

create or replace function erp_supply.refresh_material_reservation(p_order_item_id uuid)
returns void
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_required numeric;
  v_physical numeric;
  v_reserved numeric;
  v_shortage numeric;
  v_actor uuid;
begin
  select * into v_item from erp_supply.order_items where id=p_order_item_id;
  if not found then return; end if;
  select * into v_order from erp_supply.orders where id=v_item.order_id;
  if not found then return; end if;

  if coalesce(v_order.is_test,false) or v_item.material_master_id is null then
    delete from erp_supply.material_reservations where order_item_id=v_item.id;
    return;
  end if;

  if v_item.item_status='FULFILLED' then
    update erp_supply.material_reservations
      set status='CONSUMED',consumed_at=coalesce(consumed_at,now()),updated_at=now()
      where order_item_id=v_item.id and status<>'CONSUMED';
    return;
  elsif exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=v_item.id and r.process_status='READY' and coalesce(r.resolution_code,'') in('CUT','FULL_REEL')) then
    update erp_supply.material_reservations
      set status='CONSUMED',consumed_at=coalesce(consumed_at,now()),updated_at=now(),
          metadata=metadata||jsonb_build_object('consumedBy','CORTE')
      where order_item_id=v_item.id and status<>'CONSUMED';
    return;
  elsif v_item.item_status='CANCELLED' or coalesce(v_item.metadata->>'receptionActive','true')='false' or v_order.status='CANCELLED' then
    update erp_supply.material_reservations
      set status='RELEASED',released_at=coalesce(released_at,now()),updated_at=now()
      where order_item_id=v_item.id and status='ACTIVE';
    return;
  end if;

  v_required:=erp_supply.order_item_required_quantity(v_item);
  if v_required is null or v_required<=0 then return; end if;
  v_physical:=erp_supply.material_physical_available(v_order.organization_id,v_item.material_master_id,v_item.material_variant_id);
  v_reserved:=erp_supply.material_erp_reserved(v_order.organization_id,v_item.material_master_id,v_item.material_variant_id,v_item.id);
  v_shortage:=greatest(v_required-greatest(v_physical-v_reserved,0),0);
  begin v_actor:=auth.uid(); exception when others then v_actor:=null; end;

  insert into erp_supply.material_reservations(
    organization_id,order_id,order_item_id,material_master_id,material_variant_id,quantity,unit,status,shortage_quantity,created_by,metadata
  ) values(
    v_order.organization_id,v_order.id,v_item.id,v_item.material_master_id,v_item.material_variant_id,v_required,v_item.unit,'ACTIVE',v_shortage,v_actor,
    jsonb_build_object('source','SALES_V10_15','reference',v_item.reference,'lineNumber',v_item.line_number,'requiresCut',v_item.requires_cut)
  )
  on conflict(order_item_id) do update set
    material_master_id=excluded.material_master_id,material_variant_id=excluded.material_variant_id,
    quantity=excluded.quantity,unit=excluded.unit,status='ACTIVE',shortage_quantity=excluded.shortage_quantity,
    consumed_at=null,released_at=null,metadata=erp_supply.material_reservations.metadata||excluded.metadata,updated_at=now();
end;
$$;

create or replace function erp_supply.trg_refresh_material_reservation()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
begin
  perform erp_supply.refresh_material_reservation(new.id);
  return new;
end;
$$;
drop trigger if exists trg_refresh_material_reservation on erp_supply.order_items;
create trigger trg_refresh_material_reservation
after insert or update of quantity,requires_cut,requested_cut_length,item_status,metadata,material_master_id,material_variant_id
on erp_supply.order_items
for each row execute function erp_supply.trg_refresh_material_reservation();

create or replace function erp_supply.trg_release_order_reservations()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
begin
  if new.status='CANCELLED' and old.status is distinct from new.status then
    update erp_supply.material_reservations
      set status='RELEASED',released_at=coalesce(released_at,now()),updated_at=now()
      where order_id=new.id and status='ACTIVE';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_release_order_reservations on erp_supply.orders;
create trigger trg_release_order_reservations
after update of status on erp_supply.orders
for each row execute function erp_supply.trg_release_order_reservations();


-- Cuando Corte ya consumió físicamente el material, la reserva lógica deja de descontarse del ATP.
create or replace function erp_supply.trg_consume_cut_reservation()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
begin
  if new.process_status='READY' and old.process_status is distinct from new.process_status
     and coalesce(new.resolution_code,'') in('CUT','FULL_REEL') then
    update erp_supply.material_reservations
      set status='CONSUMED',consumed_at=coalesce(consumed_at,now()),updated_at=now(),
          metadata=metadata||jsonb_build_object('consumedBy','CORTE','cutRequirementId',new.id,'cutResolution',new.resolution_code)
      where order_item_id=new.order_item_id and status='ACTIVE';
  end if;
  return new;
end;
$$;
drop trigger if exists trg_consume_cut_reservation on erp_supply.cut_requirements;
create trigger trg_consume_cut_reservation
after update of process_status,resolution_code on erp_supply.cut_requirements
for each row execute function erp_supply.trg_consume_cut_reservation();

-- Backfill solo de líneas operativas actuales. No toca historial ni pruebas.
do $$
declare r record;
begin
  for r in
    select i.id
    from erp_supply.order_items i
    join erp_supply.orders o on o.id=i.order_id
    where not o.is_test and o.status<>'CANCELLED'
      and i.item_status not in('FULFILLED','CANCELLED')
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
      and i.material_master_id is not null
  loop
    perform erp_supply.refresh_material_reservation(r.id);
  end loop;
end $$;

-- Búsqueda comercial: existencia Siesa disponible, reserva ERP y disponible para prometer.
create or replace function public.erp_x_material_search(p_query text default null,p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_q text:=erp_supply.material_norm(p_query);
  v_limit integer:=least(greatest(coalesce(p_limit,20),1),50);
begin
  perform erp_supply.require_profile();
  return (
    select coalesce(jsonb_agg(to_jsonb(x) order by x.rank_score,x.reference),'[]'::jsonb)
    from (
      select m.id,m.reference,m.exact_name "name",m.unit,m.weight,m.attributes,
        ii.id "inventoryItemId",
        coalesce((select sum(coalesce(erp_supply.safe_numeric(l.metadata->>'physicalExistence'),l.quantity_available+l.quantity_reserved+l.quantity_blocked)) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.source_active),0) "physicalAvailable",
        coalesce((select sum(l.quantity_available) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.source_active),0) "siesaAvailable",
        coalesce((select sum(l.quantity_reserved) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.source_active),0) "siesaCommitted",
        coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.status='ACTIVE'),0) "erpReserved",
        greatest(
          coalesce((select sum(l.quantity_available) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.source_active),0)
          -coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.status='ACTIVE'),0),0
        ) "availableToPromise",
        greatest(
          coalesce((select sum(l.quantity_available) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.source_active),0)
          -coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.status='ACTIVE'),0),0
        ) "available",
        coalesce((select jsonb_agg(jsonb_build_object(
          'id',v.id,'label',v.variant_label,
          'physicalAvailable',coalesce((select sum(coalesce(erp_supply.safe_numeric(l.metadata->>'physicalExistence'),l.quantity_available+l.quantity_reserved+l.quantity_blocked)) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.material_variant_id=v.id and l.source_active),0),
          'siesaAvailable',coalesce((select sum(l.quantity_available) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.material_variant_id=v.id and l.source_active),0),
          'erpReserved',coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.material_variant_id=v.id and r.status='ACTIVE'),0),
          'availableToPromise',greatest(
            coalesce((select sum(l.quantity_available) from erp_supply.inventory_lots l where l.inventory_item_id=ii.id and l.material_variant_id=v.id and l.source_active),0)
            -coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.material_variant_id=v.id and r.status='ACTIVE'),0),0
          )
        ) order by v.variant_label) from erp_supply.material_variants v where v.material_master_id=m.id and v.active),'[]'::jsonb) variants,
        case
          when v_q='' then 10
          when erp_supply.material_norm(m.reference)=v_q then 0
          when m.normalized_name=v_q then 1
          when erp_supply.material_norm(m.reference) like v_q||'%' then 2
          when m.normalized_name like v_q||'%' then 3
          else 5
        end rank_score
      from erp_supply.material_master m
      left join erp_supply.inventory_items ii on ii.organization_id=m.organization_id and ii.material_master_id=m.id and ii.active
      where m.organization_id=v_org and m.active
        and (v_q='' or erp_supply.material_norm(m.reference) like '%'||v_q||'%'
          or m.normalized_name like '%'||v_q||'%'
          or erp_supply.material_norm(m.attributes::text) like '%'||v_q||'%')
      order by rank_score,m.reference
      limit v_limit
    ) x
  );
end;
$$;

-- Inventario: diferencia claramente físico Siesa, reservado ERP y disponible para prometer.
create or replace function public.erp_x_inventory(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_org uuid:=erp_supply.current_org_id();v_total bigint;v_items jsonb;v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),250);v_q text:=erp_supply.material_norm(p_search);
begin
  perform erp_supply.require_profile();
  if not erp_supply.can_access_module('inventory','read') and not erp_supply.can_access_module('cutting','read') and not erp_supply.has_role('super_admin') then raise exception 'No autorizado' using errcode='42501'; end if;
  select count(*) into v_total
  from erp_supply.inventory_items i join erp_supply.material_master m on m.id=i.material_master_id
  where i.organization_id=v_org and i.active and m.active
    and (v_q='' or erp_supply.material_norm(m.reference||' '||m.exact_name||' '||m.attributes::text) like '%'||v_q||'%');

  select coalesce(jsonb_agg(to_jsonb(x) order by x.description),'[]'::jsonb) into v_items from (
    select i.id,i.sku,m.reference,m.exact_name description,m.unit,i.item_type "itemType",i.barcode,m.id "materialMasterId",
      coalesce(sum(coalesce(erp_supply.safe_numeric(l.metadata->>'physicalExistence'),l.quantity_available+l.quantity_reserved+l.quantity_blocked)) filter(where l.source_active),0) "physicalExistence",
      coalesce(sum(l.quantity_available) filter(where l.source_active),0) available,
      coalesce(sum(l.quantity_reserved) filter(where l.source_active),0) "siesaCommitted",
      coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.status='ACTIVE'),0) "erpReserved",
      greatest(coalesce(sum(l.quantity_available) filter(where l.source_active),0)
        -coalesce((select sum(r.quantity) from erp_supply.material_reservations r where r.organization_id=v_org and r.material_master_id=m.id and r.status='ACTIVE'),0),0) "availableToPromise",
      coalesce(sum(l.quantity_blocked) filter(where l.source_active),0) blocked,
      count(l.id) filter(where l.source_active) lots,
      count(distinct l.material_variant_id) filter(where l.source_active and l.material_variant_id is not null) "variantCount",
      m.attributes
    from erp_supply.inventory_items i
    join erp_supply.material_master m on m.id=i.material_master_id and m.active
    left join erp_supply.inventory_lots l on l.inventory_item_id=i.id and l.source_active
    where i.organization_id=v_org and i.active
      and (v_q='' or erp_supply.material_norm(m.reference||' '||m.exact_name||' '||m.attributes::text) like '%'||v_q||'%')
    group by i.id,m.id
    order by m.exact_name
    offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

-- Opciones reales de origen para Alistamiento. No se asigna nada todavía.
create or replace function public.erp_x_picking_origin_plan(p_order_item_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_required numeric;
  v_total numeric:=0;
  v_remaining numeric;
  v_single uuid;
  v_row record;
  v_candidates jsonb:='[]'::jsonb;
  v_plan jsonb:='[]'::jsonb;
  v_take numeric;
begin
  perform erp_supply.require_profile();
  select i.* into v_item from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id
    where i.id=p_order_item_id and o.organization_id=v_org and erp_supply.can_view_order(o.id);
  if not found then raise exception 'Línea no disponible' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=v_item.order_id;
  if v_item.requires_cut then
    return jsonb_build_object('orderItemId',v_item.id,'managedByCutting',true,'required',erp_supply.order_item_required_quantity(v_item),'unit',v_item.unit,'candidates','[]'::jsonb,'suggestedPlan','[]'::jsonb);
  end if;
  if v_item.material_master_id is null then raise exception 'La línea no está vinculada al maestro oficial Siesa'; end if;
  v_required:=v_item.quantity;

  select l.id into v_single
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id
    and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id
    and l.quantity_available>=v_required
  order by l.quantity_available asc,l.received_at asc nulls last,l.id
  limit 1;

  for v_row in
    select l.id,l.inventory_item_id,l.lot_number,l.serial_number,l.location,l.quantity_available,l.warehouse_code,l.source_location_name,l.source_system,
      mv.variant_label
    from erp_supply.inventory_lots l
    join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
    left join erp_supply.material_variants mv on mv.id=l.material_variant_id
    where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id
      and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id and l.quantity_available>0
    order by case when v_single is not null and l.id=v_single then 0 else 1 end,
      case when v_single is null then l.quantity_available end desc,
      l.quantity_available asc,l.location,l.id
  loop
    v_total:=v_total+v_row.quantity_available;
    v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object(
      'lotId',v_row.id,'inventoryItemId',v_row.inventory_item_id,'lotNumber',v_row.lot_number,'serialNumber',v_row.serial_number,
      'location',v_row.location,'locationName',v_row.source_location_name,'warehouseCode',v_row.warehouse_code,
      'available',v_row.quantity_available,'sourceSystem',v_row.source_system,'variantLabel',v_row.variant_label,
      'recommended',v_row.id=v_single
    ));
  end loop;

  v_remaining:=v_required;
  if v_single is not null then
    v_plan:=jsonb_build_array(jsonb_build_object('lotId',v_single,'quantity',v_required));
  else
    for v_row in
      select l.id,l.quantity_available
      from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id
        and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id and l.quantity_available>0
      order by l.quantity_available desc,l.location,l.id
    loop
      exit when v_remaining<=0;
      v_take:=least(v_remaining,v_row.quantity_available);
      v_plan:=v_plan||jsonb_build_array(jsonb_build_object('lotId',v_row.id,'quantity',v_take));
      v_remaining:=v_remaining-v_take;
    end loop;
  end if;

  return jsonb_build_object(
    'orderItemId',v_item.id,'managedByCutting',false,'required',v_required,'unit',v_item.unit,
    'materialMasterId',v_item.material_master_id,'materialVariantId',v_item.material_variant_id,
    'totalAvailable',v_total,'shortage',greatest(v_required-v_total,0),
    'candidates',v_candidates,'suggestedPlan',v_plan
  );
end;
$$;

create or replace function erp_supply.validate_picking_origins(p_item erp_supply.order_items,p_origins jsonb,p_lock boolean default false)
returns numeric
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_org uuid;
  v_row jsonb;
  v_lot uuid;
  v_qty numeric;
  v_sum numeric:=0;
  v_seen uuid[]:='{}'::uuid[];
  v_inventory_item uuid;
  v_material uuid;
  v_variant uuid;
  v_available numeric;
  v_active boolean;
begin
  select organization_id into v_org from erp_supply.orders where id=p_item.order_id;
  if p_item.requires_cut then return 0; end if;
  if jsonb_typeof(coalesce(p_origins,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_origins,'[]'::jsonb))=0 then
    raise exception 'Selecciona de qué lote o ubicación se tomó la línea %',p_item.line_number;
  end if;
  for v_row in select value from jsonb_array_elements(p_origins) loop
    v_lot:=erp_supply.safe_uuid(v_row->>'lotId');
    v_qty:=erp_supply.safe_numeric(v_row->>'quantity');
    if v_lot is null or v_qty is null or v_qty<=0 or v_lot=any(v_seen) then raise exception 'Origen físico inválido en la línea %',p_item.line_number; end if;
    if p_lock then
      select l.inventory_item_id,ii.material_master_id,l.material_variant_id,l.quantity_available,l.source_active
        into v_inventory_item,v_material,v_variant,v_available,v_active
      from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where l.id=v_lot and ii.organization_id=v_org for update of l;
    else
      select l.inventory_item_id,ii.material_master_id,l.material_variant_id,l.quantity_available,l.source_active
        into v_inventory_item,v_material,v_variant,v_available,v_active
      from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where l.id=v_lot and ii.organization_id=v_org;
    end if;
    if v_inventory_item is null or not coalesce(v_active,false) then raise exception 'El lote seleccionado ya no está disponible'; end if;
    if v_material is distinct from p_item.material_master_id or v_variant is distinct from p_item.material_variant_id then raise exception 'El lote seleccionado no corresponde al material o variante de la línea %',p_item.line_number; end if;
    if v_available<v_qty then raise exception 'Existencia insuficiente en uno de los lotes seleccionados para la línea %',p_item.line_number; end if;
    v_sum:=v_sum+v_qty;v_seen:=array_append(v_seen,v_lot);
  end loop;
  if abs(v_sum-p_item.quantity)>0.0001 then
    raise exception 'La suma de los orígenes de la línea % debe ser exactamente % %',p_item.line_number,p_item.quantity,p_item.unit;
  end if;
  return v_sum;
end;
$$;

create or replace function erp_supply.consume_picking_origins(
  p_item erp_supply.order_items,p_origins jsonb,p_actor uuid
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_org uuid;v_row jsonb;v_lot uuid;v_qty numeric;v_inventory_item uuid;v_location text;v_order_number text;v_out jsonb:='[]'::jsonb;
begin
  if p_item.requires_cut then return '[]'::jsonb; end if;
  perform erp_supply.validate_picking_origins(p_item,p_origins,true);
  select organization_id,order_number into v_org,v_order_number from erp_supply.orders where id=p_item.order_id;
  for v_row in select value from jsonb_array_elements(p_origins) loop
    v_lot:=erp_supply.safe_uuid(v_row->>'lotId');v_qty:=erp_supply.safe_numeric(v_row->>'quantity');
    select inventory_item_id,location into v_inventory_item,v_location from erp_supply.inventory_lots where id=v_lot;
    update erp_supply.inventory_lots set quantity_available=quantity_available-v_qty,
      metadata=metadata||jsonb_build_object('lastPickingAt',now(),'lastPickingBy',p_actor,'lastOrderId',p_item.order_id)
      where id=v_lot;
    insert into erp_supply.order_item_allocations(
      organization_id,order_id,order_item_id,inventory_item_id,inventory_lot_id,quantity,unit,allocation_type,status,actor_profile_id,metadata
    ) values(v_org,p_item.order_id,p_item.id,v_inventory_item,v_lot,v_qty,p_item.unit,'PICKING','CONSUMED',p_actor,
      jsonb_build_object('source','ALISTAMIENTO_V10_15','reference',p_item.reference,'lineNumber',p_item.line_number));
    insert into erp_supply.inventory_movements(
      organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,from_location,to_location,actor_profile_id,reference,metadata
    ) values(v_org,v_inventory_item,v_lot,p_item.order_id,'ISSUE',v_qty,p_item.unit,v_location,'ALISTAMIENTO',p_actor,v_order_number,
      jsonb_build_object('source','ALISTAMIENTO_V10_15','orderItemId',p_item.id,'materialMasterId',p_item.material_master_id,'materialVariantId',p_item.material_variant_id));
    v_out:=v_out||jsonb_build_array(jsonb_build_object('lotId',v_lot,'quantity',v_qty,'location',v_location));
  end loop;
  return v_out;
end;
$$;

-- Guardamos el origen elegido también durante el alistamiento paralelo.
create or replace function public.erp_x_picking_precheck(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth as $$
declare v_org uuid:=erp_supply.current_org_id();begin
  perform erp_supply.require_profile();
  if not exists(select 1 from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)) then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  return jsonb_build_object('items',(select coalesce(jsonb_agg(jsonb_build_object(
    'orderItemId',p.order_item_id,'result',p.result,'novelty',p.novelty,'origins',coalesce(p.metadata->'origins','[]'::jsonb),'checkedAt',p.checked_at,'checkedBy',pr.display_name
  ) order by p.checked_at),'[]'::jsonb) from erp_supply.picking_prechecks p left join erp_supply.profiles pr on pr.id=p.checked_by where p.order_id=p_order_id));
end;$$;

create or replace function public.erp_x_save_picking_precheck(p_order_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_task erp_supply.order_tasks%rowtype;v_row jsonb;v_item erp_supply.order_items%rowtype;v_id uuid;v_result text;v_novelty text;v_origins jsonb;v_count int:=0;begin
  if not (erp_supply.can_access_module('picking','update') or erp_supply.has_role('aux_logistica') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para guardar Alistamiento' using errcode='42501'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='ALISTAMIENTO' and status='IN_PROGRESS' order by sequence_no desc limit 1;
  if not found then raise exception 'Primero debes tomar el pedido en Alistamiento'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'Pedido asignado a otro auxiliar' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Resultados inválidos'; end if;
  for v_row in select value from jsonb_array_elements(p_items) loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_novelty:=nullif(trim(v_row->>'novelty'),'');v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea no disponible'; end if;
    if v_item.requires_cut and not exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=v_item.id and r.process_status='READY' and r.collection_status='COLLECTED') then raise exception 'La línea % todavía está en Corte',v_item.line_number; end if;
    if v_result not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado'; end if;
    if v_result='MISSING' and v_novelty is null then raise exception 'Explica el faltante de la línea %',v_item.line_number; end if;
    if v_result='FOUND' and not v_item.requires_cut then perform erp_supply.validate_picking_origins(v_item,v_origins,false); end if;
    insert into erp_supply.picking_prechecks(order_item_id,organization_id,order_id,task_id,result,novelty,checked_by,metadata)
    values(v_item.id,v_org,p_order_id,v_task.id,v_result,v_novelty,v_actor,jsonb_build_object('lineNumber',v_item.line_number,'source','PARALLEL_PICKING_V10_15','origins',v_origins))
    on conflict(order_item_id) do update set result=excluded.result,novelty=excluded.novelty,checked_by=excluded.checked_by,checked_at=now(),task_id=excluded.task_id,metadata=erp_supply.picking_prechecks.metadata||excluded.metadata;
    v_count:=v_count+1;
  end loop;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_org,p_order_id,v_task.id,'DOMAIN_RECORD','PICKING_PRECHECK','ALISTAMIENTO','ALISTAMIENTO',v_actor,(erp_supply.current_roles())[1],jsonb_build_object('items',v_count,'inventoryOrigins',true));
  return jsonb_build_object('success',true,'saved',v_count);
end;$$;

-- Conservamos el motor de rondas probado y lo envolvemos con la asignación física.
do $$
begin
  if to_regprocedure('public.erp_x_confirm_picking_round_v10_8(uuid,jsonb)') is null then
    if to_regprocedure('public.erp_x_confirm_picking_round(uuid,jsonb)') is null then
      raise exception 'No existe el RPC base erp_x_confirm_picking_round(uuid,jsonb)';
    end if;
    alter function public.erp_x_confirm_picking_round(uuid,jsonb) rename to erp_x_confirm_picking_round_v10_8;
  end if;
end $$;

create or replace function public.erp_x_confirm_picking_round(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_row jsonb;
  v_item erp_supply.order_items%rowtype;
  v_id uuid;
  v_result text;
  v_origins jsonb;
  v_allocations jsonb:='[]'::jsonb;
  v_alloc jsonb;
  v_result_payload jsonb;
begin
  if jsonb_typeof(coalesce(p_payload->'items','[]'::jsonb))<>'array' then raise exception 'Resultados de Alistamiento inválidos'; end if;
  -- Validación completa antes de descontar la primera unidad.
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select i.* into v_item from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id
      where i.id=v_id and i.order_id=p_order_id and o.organization_id=v_org and erp_supply.can_view_order(o.id)
        and i.item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea de Alistamiento no disponible'; end if;
    if v_result='FOUND' and not v_item.requires_cut then perform erp_supply.validate_picking_origins(v_item,v_origins,false); end if;
  end loop;

  -- Consumo físico dentro de la misma transacción. Cualquier fallo posterior revierte todo.
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if v_result='FOUND' and not v_item.requires_cut then
      v_alloc:=erp_supply.consume_picking_origins(v_item,v_origins,v_actor);
      v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('orderItemId',v_item.id,'origins',v_alloc));
    end if;
  end loop;

  v_result_payload:=public.erp_x_confirm_picking_round_v10_8(p_order_id,p_payload);
  return v_result_payload||jsonb_build_object('inventoryAllocations',v_allocations,'inventoryTraceVersion','10.15');
end;
$$;

revoke all on function public.erp_x_picking_origin_plan(uuid) from public,anon;
grant execute on function public.erp_x_picking_origin_plan(uuid) to authenticated;
revoke all on function public.erp_x_confirm_picking_round(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_confirm_picking_round(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_picking_precheck(uuid) to authenticated;
grant execute on function public.erp_x_save_picking_precheck(uuid,jsonb) to authenticated;

-- Diagnóstico breve para soporte.
create or replace function public.erp_x_material_reservation_health()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_org uuid:=erp_supply.current_org_id();begin
  perform erp_supply.require_profile();
  return jsonb_build_object(
    'activeReservations',(select count(*) from erp_supply.material_reservations where organization_id=v_org and status='ACTIVE'),
    'reservedQuantity',(select coalesce(sum(quantity),0) from erp_supply.material_reservations where organization_id=v_org and status='ACTIVE'),
    'shortageReservations',(select count(*) from erp_supply.material_reservations where organization_id=v_org and status='ACTIVE' and shortage_quantity>0),
    'physicalAllocations',(select count(*) from erp_supply.order_item_allocations where organization_id=v_org and status='CONSUMED')
  );
end;$$;
grant execute on function public.erp_x_material_reservation_health() to authenticated;

notify pgrst,'reload schema';
commit;
