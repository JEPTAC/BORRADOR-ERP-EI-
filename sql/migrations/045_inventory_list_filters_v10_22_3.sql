-- ERP EI V10.22.3
-- Inventario operacional en lista: filtros reales, facetas y ordenamiento en servidor.
-- No sustituye erp_x_inventory(text,integer,integer) para conservar compatibilidad con reportes.

begin;

create or replace function public.erp_x_inventory_filtered(p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_search text:=erp_supply.material_norm(p_payload->>'search');
  v_unit text:=upper(trim(coalesce(p_payload->>'unit','')));
  v_warehouse text:=upper(trim(coalesce(p_payload->>'warehouse','')));
  v_item_type text:=upper(trim(coalesce(p_payload->>'itemType','')));
  v_stock text:=upper(trim(coalesce(p_payload->>'stock','')));
  v_variants text:=upper(trim(coalesce(p_payload->>'variants','ALL')));
  v_sort text:=lower(trim(coalesce(p_payload->>'sort','reference_asc')));
  v_page integer:=greatest(coalesce(erp_supply.safe_integer(p_payload->>'page'),1),1);
  v_size integer:=least(greatest(coalesce(erp_supply.safe_integer(p_payload->>'pageSize'),50),10),250);
begin
  perform erp_supply.require_profile();
  if not erp_supply.can_access_module('inventory','read')
     and not erp_supply.can_access_module('cutting','read')
     and not erp_supply.has_role('super_admin') then
    raise exception 'No autorizado' using errcode='42501';
  end if;

  if v_item_type not in ('','STANDARD','CUTTABLE') then v_item_type:=''; end if;
  if v_stock not in ('','AVAILABLE','OUT','PHYSICAL','RESERVED','BLOCKED') then v_stock:=''; end if;
  if v_variants not in ('ALL','YES','NO') then v_variants:='ALL'; end if;
  if v_sort not in ('reference_asc','name_asc','atp_desc','atp_asc','physical_desc','reserved_desc','lots_desc') then
    v_sort:='reference_asc';
  end if;

  return (
    with reservation_agg as(
      select r.material_master_id,coalesce(sum(r.quantity),0)::numeric erp_reserved
      from erp_supply.material_reservations r
      where r.organization_id=v_org and r.status='ACTIVE'
      group by r.material_master_id
    ),
    lot_agg as(
      select
        l.inventory_item_id,
        coalesce(sum(coalesce(erp_supply.safe_numeric(l.metadata->>'physicalExistence'),l.quantity_available+l.quantity_reserved+l.quantity_blocked)),0)::numeric physical_existence,
        coalesce(sum(l.quantity_available),0)::numeric siesa_available,
        coalesce(sum(l.quantity_reserved),0)::numeric siesa_committed,
        coalesce(sum(l.quantity_blocked),0)::numeric blocked,
        count(*)::integer lots,
        count(distinct l.material_variant_id) filter(where l.material_variant_id is not null)::integer variant_count,
        coalesce(array_remove(array_agg(distinct nullif(upper(trim(l.warehouse_code)),'')),null),'{}'::text[]) warehouses
      from erp_supply.inventory_lots l
      join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where ii.organization_id=v_org and l.source_active
      group by l.inventory_item_id
    ),
    base as(
      select
        i.id,i.sku,m.reference,m.exact_name description,m.unit,i.item_type "itemType",i.barcode,m.id "materialMasterId",
        coalesce(la.physical_existence,0) "physicalExistence",
        coalesce(la.siesa_available,0) available,
        coalesce(la.siesa_committed,0) "siesaCommitted",
        coalesce(ra.erp_reserved,0) "erpReserved",
        greatest(coalesce(la.siesa_available,0)-coalesce(ra.erp_reserved,0),0)::numeric "availableToPromise",
        coalesce(la.blocked,0) blocked,
        coalesce(la.lots,0)::integer lots,
        coalesce(la.variant_count,0)::integer "variantCount",
        coalesce(la.warehouses,'{}'::text[]) warehouses,
        m.attributes,
        erp_supply.material_norm(
          coalesce(m.reference,'')||' '||coalesce(m.exact_name,'')||' '||coalesce(m.attributes::text,'')||' '||coalesce(i.barcode,'')
        ) search_text
      from erp_supply.inventory_items i
      join erp_supply.material_master m on m.id=i.material_master_id and m.active
      left join lot_agg la on la.inventory_item_id=i.id
      left join reservation_agg ra on ra.material_master_id=m.id
      where i.organization_id=v_org and i.active
    ),
    searched as(
      select * from base b
      where v_search='' or b.search_text like '%'||v_search||'%'
    ),
    filtered as(
      select * from searched b
      where (v_unit='' or upper(b.unit)=v_unit)
        and (v_warehouse='' or v_warehouse=any(b.warehouses))
        and (v_item_type='' or upper(coalesce(b."itemType",''))=v_item_type)
        and (
          v_variants='ALL'
          or (v_variants='YES' and b."variantCount">0)
          or (v_variants='NO' and b."variantCount"=0)
        )
        and (
          v_stock=''
          or (v_stock='AVAILABLE' and b."availableToPromise">0)
          or (v_stock='OUT' and b."availableToPromise"<=0)
          or (v_stock='PHYSICAL' and b."physicalExistence">0)
          or (v_stock='RESERVED' and b."erpReserved">0)
          or (v_stock='BLOCKED' and b.blocked>0)
        )
    ),
    ordered as(
      select * from filtered b
      order by
        case when v_sort='reference_asc' then b.reference end asc nulls last,
        case when v_sort='name_asc' then b.description end asc nulls last,
        case when v_sort='atp_desc' then b."availableToPromise" end desc nulls last,
        case when v_sort='atp_asc' then b."availableToPromise" end asc nulls last,
        case when v_sort='physical_desc' then b."physicalExistence" end desc nulls last,
        case when v_sort='reserved_desc' then b."erpReserved" end desc nulls last,
        case when v_sort='lots_desc' then b.lots end desc nulls last,
        b.reference asc,b.id asc
    ),
    paged as(
      select * from ordered
      offset (v_page-1)*v_size
      limit v_size
    ),
    summary as(
      select
        count(*)::bigint total,
        count(*) filter(where "availableToPromise">0)::bigint available_count,
        count(*) filter(where "availableToPromise"<=0)::bigint out_count,
        count(*) filter(where "erpReserved">0)::bigint reserved_count,
        count(*) filter(where blocked>0)::bigint blocked_count
      from filtered
    ),
    units as(
      select unit value,count(*)::bigint count
      from searched
      where nullif(trim(unit),'') is not null
      group by unit
      order by unit
    ),
    warehouses as(
      select w value,count(distinct b.id)::bigint count
      from searched b
      cross join lateral unnest(b.warehouses) w
      group by w
      order by w
    )
    select jsonb_build_object(
      'items',coalesce((select jsonb_agg(
        jsonb_build_object(
          'id',p.id,'sku',p.sku,'reference',p.reference,'description',p.description,'unit',p.unit,
          'itemType',p."itemType",'barcode',p.barcode,'materialMasterId',p."materialMasterId",
          'physicalExistence',p."physicalExistence",'available',p.available,'siesaCommitted',p."siesaCommitted",
          'erpReserved',p."erpReserved",'availableToPromise',p."availableToPromise",'blocked',p.blocked,
          'lots',p.lots,'variantCount',p."variantCount",'warehouses',to_jsonb(p.warehouses),'attributes',p.attributes
        )
      ) from paged p),'[]'::jsonb),
      'pagination',jsonb_build_object(
        'page',v_page,'pageSize',v_size,
        'totalItems',(select total from summary),
        'totalPages',case when (select total from summary)=0 then 0 else ceil((select total from summary)::numeric/v_size)::integer end
      ),
      'summary',jsonb_build_object(
        'materials',(select total from summary),
        'availableMaterials',(select available_count from summary),
        'outMaterials',(select out_count from summary),
        'reservedMaterials',(select reserved_count from summary),
        'blockedMaterials',(select blocked_count from summary)
      ),
      'facets',jsonb_build_object(
        'units',coalesce((select jsonb_agg(jsonb_build_object('value',u.value,'count',u.count)) from units u),'[]'::jsonb),
        'warehouses',coalesce((select jsonb_agg(jsonb_build_object('value',w.value,'count',w.count)) from warehouses w),'[]'::jsonb)
      ),
      'filters',jsonb_build_object(
        'search',coalesce(p_payload->>'search',''),'unit',v_unit,'warehouse',v_warehouse,'itemType',v_item_type,
        'stock',v_stock,'variants',v_variants,'sort',v_sort,'page',v_page,'pageSize',v_size
      ),
      'version','10.22.3'
    )
  );
end;
$$;

revoke all on function public.erp_x_inventory_filtered(jsonb) from public,anon;
grant execute on function public.erp_x_inventory_filtered(jsonb) to authenticated;

notify pgrst,'reload schema';
commit;
