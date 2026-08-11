-- ERP EI V10.22.0
-- Endurecimiento transversal detectado durante la auditoría de combinaciones.
-- 1) Alistamiento no puede confirmar una línea de Corte sin recogida real.
-- 2) Mercancía OK de PVE publica inventario oficial de forma idempotente.
-- 3) Diagnóstico de integridad de datos entre flujos.

begin;

-- ============================================================================
-- 1. GATE DE SERVIDOR: CORTE RECOGIDO ANTES DE ALISTAR
-- ============================================================================
create or replace function erp_supply.trg_require_collected_cut_for_picking()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_item erp_supply.order_items%rowtype;
begin
  select * into v_item
  from erp_supply.order_items
  where id=new.order_item_id;

  if found and v_item.requires_cut then
    if not exists(
      select 1
      from erp_supply.cut_requirements r
      where r.order_item_id=v_item.id
        and r.process_status='READY'
        and r.collection_status='COLLECTED'
    ) then
      raise exception 'La línea % todavía está en Corte o no ha sido recogida en Alistamiento',v_item.line_number;
    end if;
  end if;

  return new;
end;
$$;

revoke all on function erp_supply.trg_require_collected_cut_for_picking() from public;

drop trigger if exists trg_require_collected_cut_for_picking on erp_supply.picking_round_items;
create trigger trg_require_collected_cut_for_picking
before insert or update of order_item_id,result on erp_supply.picking_round_items
for each row execute function erp_supply.trg_require_collected_cut_for_picking();

-- ============================================================================
-- 2. PVE: MERCANCÍA OK TAMBIÉN PUBLICA INVENTARIO
--    Conserva la operación simple, pero ya no permite avanzar con una recepción
--    física que no haya dejado lote + movimiento trazable.
-- ============================================================================
create or replace function erp_supply.finalize_arrived_purchase(p_order_id uuid,p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_receipt uuid;
  v_receipt_number text;
  v_version integer;
  v_item erp_supply.order_items%rowtype;
  v_inventory erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_source_key text;
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id
  for update;

  if not found or v_order.current_step_code<>'RECEPCION_MERCANCIA' then
    return false;
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code='RECEPCION_MERCANCIA'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found then return false; end if;

  v_receipt_number:='ARR-'||replace(p_order_id::text,'-','');

  insert into erp_supply.receipts(
    order_id,receipt_number,purchase_order,supplier_name,status,
    received_by,received_at,metadata
  )
  values(
    p_order_id,
    v_receipt_number,
    (select po_number from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),
    (select supplier_name from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),
    'CONFORMING',p_actor,now(),
    jsonb_build_object('source','MERCANCIA_OK_V10_22','automaticArrival',true)
  )
  on conflict(order_id,receipt_number) do update set
    status='CONFORMING',
    received_by=excluded.received_by,
    received_at=coalesce(erp_supply.receipts.received_at,excluded.received_at),
    metadata=erp_supply.receipts.metadata||excluded.metadata
  returning id into v_receipt;

  for v_item in
    select i.*
    from erp_supply.order_items i
    where i.order_id=p_order_id
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
    order by i.line_number
  loop
    if not exists(
      select 1 from erp_supply.receipt_lines rl
      where rl.receipt_id=v_receipt and rl.order_item_id=v_item.id
    ) then
      insert into erp_supply.receipt_lines(
        receipt_id,order_item_id,sku,description,expected_quantity,
        received_quantity,accepted_quantity,rejected_quantity,unit,location,
        quality_status,metadata
      ) values(
        v_receipt,v_item.id,v_item.sku,v_item.description,v_item.quantity,
        v_item.quantity,v_item.quantity,0,v_item.unit,'RECEPCION','ACCEPTED',
        jsonb_build_object(
          'source','MERCANCIA_OK_V10_22',
          'materialMasterId',v_item.material_master_id,
          'materialVariantId',v_item.material_variant_id
        )
      );
    end if;

    -- Sandbox no toca inventario real. El flujo Sandbox conserva sus RPC aislados.
    if v_order.is_test then
      continue;
    end if;

    if v_item.material_master_id is null then
      raise exception 'La línea % no está vinculada al maestro oficial Siesa y no puede publicarse en inventario',v_item.line_number;
    end if;

    select * into v_inventory
    from erp_supply.inventory_items ii
    where ii.organization_id=v_order.organization_id
      and ii.material_master_id=v_item.material_master_id
      and ii.active
    limit 1;

    if not found then
      raise exception 'El material de la línea % no tiene artículo de inventario oficial activo. Sincroniza Siesa antes de confirmar Mercancía OK',v_item.line_number;
    end if;

    v_source_key:='ERP-ARRIVAL:'||v_receipt::text||':'||v_item.id::text;

    insert into erp_supply.inventory_lots(
      inventory_item_id,lot_number,location,quantity_available,received_at,
      material_variant_id,source_system,source_key,source_active,metadata
    ) values(
      v_inventory.id,
      'ARR-'||substr(replace(v_receipt::text,'-',''),1,12)||'-'||v_item.line_number,
      'RECEPCION',v_item.quantity,now(),
      v_item.material_variant_id,'ERP_RECEIPT',v_source_key,true,
      jsonb_build_object(
        'receiptId',v_receipt,
        'orderItemId',v_item.id,
        'automaticArrival',true,
        'flowVersion','10.22.0'
      )
    )
    on conflict(inventory_item_id,source_system,source_key) where source_key is not null
    do update set
      quantity_available=excluded.quantity_available,
      material_variant_id=excluded.material_variant_id,
      source_active=true,
      received_at=coalesce(erp_supply.inventory_lots.received_at,excluded.received_at),
      metadata=erp_supply.inventory_lots.metadata||excluded.metadata
    returning * into v_lot;

    if not exists(
      select 1
      from erp_supply.inventory_movements m
      where m.order_id=p_order_id
        and m.movement_type='RECEIPT'
        and m.reference=v_receipt_number
        and m.metadata->>'orderItemId'=v_item.id::text
    ) then
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,order_id,movement_type,
        quantity,unit,to_location,actor_profile_id,reference,metadata
      ) values(
        v_order.organization_id,v_inventory.id,v_lot.id,p_order_id,'RECEIPT',
        v_item.quantity,v_inventory.unit,v_lot.location,p_actor,v_receipt_number,
        jsonb_build_object(
          'receiptId',v_receipt,
          'orderItemId',v_item.id,
          'automaticArrival',true,
          'flowVersion','10.22.0'
        )
      );
    end if;
  end loop;

  update erp_supply.task_checklist
  set completed=true,
      completed_by=p_actor,
      completed_at=coalesce(completed_at,now()),
      note='Mercancía OK confirmada desde Recepción',
      metadata=metadata||jsonb_build_object('source','MERCANCIA_OK_V10_22')
  where task_id=v_task.id and required;

  select version into v_version from erp_supply.orders where id=p_order_id;

  perform erp_supply.execute_action_internal(
    p_order_id,'COMPLETE',
    jsonb_build_object(
      'resultCode','MERCHANDISE_OK',
      'detail','Mercancía recibida en sede e inventario publicado',
      'receiptId',v_receipt,
      'inventoryPublished',not v_order.is_test,
      'flowVersion','10.22.0'
    ),
    p_actor,true,v_version,'ARRIVAL-'||p_order_id::text
  );

  return true;
end;
$$;

-- ============================================================================
-- 3. RECEPCIÓN MANUAL PVE: IDENTIDAD SIESA + ACUMULACIÓN + IDEMPOTENCIA
-- ============================================================================
create or replace function public.erp_x_receipt_progress(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_items jsonb;
  v_complete boolean;
begin
  if not erp_supply.can_view_order(p_order_id) then
    raise exception 'Pedido no disponible' using errcode='42501';
  end if;

  with progress as(
    select
      i.id order_item_id,
      i.line_number,
      i.sku,
      i.reference,
      i.description,
      i.unit,
      i.quantity expected_quantity,
      coalesce(sum(rl.received_quantity),0) received_quantity,
      coalesce(sum(rl.accepted_quantity),0) accepted_quantity,
      coalesce(sum(rl.rejected_quantity),0) rejected_quantity,
      greatest(i.quantity-coalesce(sum(rl.accepted_quantity),0),0) remaining_quantity
    from erp_supply.order_items i
    join erp_supply.orders o on o.id=i.order_id and o.organization_id=v_org
    left join erp_supply.receipt_lines rl on rl.order_item_id=i.id
    left join erp_supply.receipts r on r.id=rl.receipt_id and r.order_id=p_order_id
    where i.order_id=p_order_id
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
    group by i.id,i.line_number,i.sku,i.reference,i.description,i.unit,i.quantity
  )
  select
    coalesce(jsonb_agg(jsonb_build_object(
      'orderItemId',order_item_id,
      'lineNumber',line_number,
      'sku',sku,
      'reference',reference,
      'description',description,
      'unit',unit,
      'expectedQuantity',expected_quantity,
      'receivedQuantity',received_quantity,
      'acceptedQuantity',accepted_quantity,
      'rejectedQuantity',rejected_quantity,
      'remainingQuantity',remaining_quantity,
      'complete',remaining_quantity<=0.0001
    ) order by line_number),'[]'::jsonb),
    coalesce(bool_and(remaining_quantity<=0.0001),false)
  into v_items,v_complete
  from progress;

  return jsonb_build_object(
    'orderId',p_order_id,
    'items',v_items,
    'complete',v_complete,
    'version','10.22.0'
  );
end;
$$;

create or replace function public.erp_x_save_receipt(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_receipt erp_supply.receipts%rowtype;
  v_line jsonb;
  v_order_item erp_supply.order_items%rowtype;
  v_inventory erp_supply.inventory_items%rowtype;
  v_lot erp_supply.inventory_lots%rowtype;
  v_status text:=upper(coalesce(p_payload->>'status','CONFORMING'));
  v_received numeric;
  v_accepted numeric;
  v_rejected numeric;
  v_prior_accepted numeric;
  v_count integer:=0;
  v_request_id text:=nullif(trim(p_payload->>'requestId'),'');
  v_receipt_number text;
  v_source_key text;
  v_pending integer:=0;
begin
  if not (erp_supply.can_access_module('receiving','create') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para recepción' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=erp_supply.current_org_id()
    and erp_supply.can_view_order(id)
  for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'RECEPCION_MERCANCIA' and not erp_supply.has_role('super_admin') then
    raise exception 'El pedido no está en Recepción de mercancía';
  end if;
  if v_status not in('OPEN','PARTIAL','CONFORMING','NONCONFORMING','CLOSED') then
    raise exception 'Estado de recepción inválido';
  end if;
  if jsonb_typeof(coalesce(p_payload->'lines','[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_payload->'lines','[]'::jsonb))=0 then
    raise exception 'Debe registrar al menos una línea recibida';
  end if;

  if v_request_id is not null then
    select r.* into v_receipt
    from erp_supply.receipts r
    where r.order_id=p_order_id and r.metadata->>'requestId'=v_request_id
    order by r.created_at desc limit 1;
    if found then
      return jsonb_build_object(
        'success',true,'idempotent',true,'receipt',to_jsonb(v_receipt),
        'lines',(select count(*) from erp_supply.receipt_lines rl where rl.receipt_id=v_receipt.id),
        'version','10.22.0'
      );
    end if;
  end if;

  v_receipt_number:=coalesce(
    nullif(trim(p_payload->>'receiptNumber'),''),
    'REC-'||to_char(clock_timestamp(),'YYYYMMDDHH24MISSMS')||'-'||substr(replace(gen_random_uuid()::text,'-',''),1,6)
  );

  insert into erp_supply.receipts(
    order_id,receipt_number,purchase_order,supplier_name,status,received_by,received_at,metadata
  ) values(
    p_order_id,v_receipt_number,p_payload->>'purchaseOrder',p_payload->>'supplierName',v_status,v_actor,now(),
    coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object(
      'source','RECEPCION_PVE_V10_22','flowVersion','10.22.0','requestId',v_request_id
    )
  ) returning * into v_receipt;

  for v_line in select value from jsonb_array_elements(p_payload->'lines')
  loop
    v_count:=v_count+1;

    select * into v_order_item
    from erp_supply.order_items i
    where i.id=nullif(v_line->>'orderItemId','')::uuid
      and i.order_id=p_order_id
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
    for update;
    if not found then raise exception 'Ítem de pedido inválido en la línea %',v_count; end if;

    v_received:=nullif(v_line->>'receivedQuantity','')::numeric;
    v_accepted:=coalesce(nullif(v_line->>'acceptedQuantity','')::numeric,v_received);
    v_rejected:=coalesce(nullif(v_line->>'rejectedQuantity','')::numeric,0);
    if v_received is null or v_received<=0 then raise exception 'Cantidad recibida inválida en la línea %',v_count; end if;
    if v_accepted<0 or v_rejected<0 or v_accepted+v_rejected>v_received+0.0001 then
      raise exception 'Distribución aceptada/rechazada inválida en la línea %',v_count;
    end if;

    select coalesce(sum(rl.accepted_quantity),0) into v_prior_accepted
    from erp_supply.receipt_lines rl
    join erp_supply.receipts r on r.id=rl.receipt_id
    where r.order_id=p_order_id and rl.order_item_id=v_order_item.id;

    if v_prior_accepted+v_accepted>v_order_item.quantity+0.0001 then
      raise exception 'La línea % supera la cantidad pendiente. Esperado %, ya aceptado %, nuevo aceptado %',
        v_order_item.line_number,v_order_item.quantity,v_prior_accepted,v_accepted;
    end if;

    insert into erp_supply.receipt_lines(
      receipt_id,order_item_id,sku,description,expected_quantity,received_quantity,
      accepted_quantity,rejected_quantity,unit,location,quality_status,metadata
    ) values(
      v_receipt.id,v_order_item.id,v_order_item.sku,v_order_item.description,v_order_item.quantity,
      v_received,v_accepted,v_rejected,v_order_item.unit,
      coalesce(nullif(v_line->>'location',''),'RECEPCION'),
      upper(coalesce(v_line->>'qualityStatus','ACCEPTED')),
      coalesce(v_line->'metadata','{}'::jsonb)||jsonb_build_object(
        'lotNumber',nullif(v_line->>'lotNumber',''),
        'materialMasterId',v_order_item.material_master_id,
        'materialVariantId',v_order_item.material_variant_id,
        'flowVersion','10.22.0'
      )
    );

    if v_accepted<=0 or v_order.is_test then continue; end if;

    if v_order_item.material_master_id is null then
      raise exception 'La línea % no está vinculada al maestro oficial Siesa',v_order_item.line_number;
    end if;

    select * into v_inventory
    from erp_supply.inventory_items ii
    where ii.organization_id=v_order.organization_id
      and ii.material_master_id=v_order_item.material_master_id
      and ii.active
    limit 1;
    if not found then
      raise exception 'La línea % no tiene artículo de inventario oficial activo. Sincroniza Siesa antes de recibir.',v_order_item.line_number;
    end if;

    v_source_key:='ERP-RECEIPT:'||v_receipt.id::text||':'||v_order_item.id::text;
    insert into erp_supply.inventory_lots(
      inventory_item_id,lot_number,serial_number,location,quantity_available,received_at,
      material_variant_id,source_system,source_key,source_active,metadata
    ) values(
      v_inventory.id,
      coalesce(nullif(v_line->>'lotNumber',''),'REC-'||substr(replace(v_receipt.id::text,'-',''),1,12)||'-'||v_order_item.line_number),
      nullif(v_line->>'serialNumber',''),
      coalesce(nullif(v_line->>'location',''),'RECEPCION'),
      v_accepted,now(),v_order_item.material_variant_id,'ERP_RECEIPT',v_source_key,true,
      jsonb_build_object(
        'receiptId',v_receipt.id,'orderItemId',v_order_item.id,
        'qualityStatus',upper(coalesce(v_line->>'qualityStatus','ACCEPTED')),
        'flowVersion','10.22.0'
      )
    )
    on conflict(inventory_item_id,source_system,source_key) where source_key is not null
    do update set
      quantity_available=excluded.quantity_available,
      material_variant_id=excluded.material_variant_id,
      source_active=true,
      metadata=erp_supply.inventory_lots.metadata||excluded.metadata
    returning * into v_lot;

    if not exists(
      select 1 from erp_supply.inventory_movements m
      where m.order_id=p_order_id
        and m.movement_type='RECEIPT'
        and m.reference=v_receipt.receipt_number
        and m.metadata->>'orderItemId'=v_order_item.id::text
    ) then
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,order_id,movement_type,quantity,unit,
        to_location,actor_profile_id,reference,metadata
      ) values(
        v_order.organization_id,v_inventory.id,v_lot.id,p_order_id,'RECEIPT',v_accepted,
        v_inventory.unit,v_lot.location,v_actor,v_receipt.receipt_number,
        jsonb_build_object('receiptId',v_receipt.id,'orderItemId',v_order_item.id,'flowVersion','10.22.0')
      );
    end if;
  end loop;

  select count(*) into v_pending
  from erp_supply.order_items i
  where i.order_id=p_order_id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and coalesce((
      select sum(rl.accepted_quantity)
      from erp_supply.receipt_lines rl
      join erp_supply.receipts r on r.id=rl.receipt_id
      where r.order_id=p_order_id and rl.order_item_id=i.id
    ),0)<i.quantity-0.0001;

  if v_status='CONFORMING' and v_pending>0 then
    raise exception 'La recepción no puede quedar Conforme: todavía hay % línea(s) con cantidad pendiente',v_pending;
  end if;
  if v_status='PARTIAL' and v_pending=0 then
    raise exception 'Todas las cantidades ya están completas. Usa Conforme para cerrar la recepción';
  end if;

  insert into erp_supply.order_events(
    organization_id,order_id,event_type,action_code,actor_profile_id,actor_role_code,payload
  ) values(
    v_order.organization_id,p_order_id,'DOMAIN_RECORD','RECEIPT',v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'receiptId',v_receipt.id,'status',v_status,'lines',v_count,
      'pendingLines',v_pending,'flowVersion','10.22.0'
    )
  );

  return jsonb_build_object(
    'success',true,'receipt',to_jsonb(v_receipt),'lines',v_count,
    'pendingLines',v_pending,'complete',v_pending=0,'version','10.22.0'
  );
end;
$$;

-- Ninguna llamada directa a COMPLETE puede saltarse la recepción física pendiente.
create or replace function erp_supply.trg_require_complete_receipt_before_task_complete()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_pending integer;
begin
  if new.step_code<>'RECEPCION_MERCANCIA'
     or new.status<>'COMPLETED'
     or old.status='COMPLETED' then
    return new;
  end if;

  select * into v_order from erp_supply.orders where id=new.order_id;
  if not found or v_order.is_test then return new; end if;

  select count(*) into v_pending
  from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and coalesce((
      select sum(rl.accepted_quantity)
      from erp_supply.receipt_lines rl
      join erp_supply.receipts r on r.id=rl.receipt_id
      where r.order_id=v_order.id and rl.order_item_id=i.id
    ),0)<i.quantity-0.0001;

  if v_pending>0 then
    raise exception 'Recepción de mercancía incompleta: % línea(s) aún tienen cantidad pendiente',v_pending;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_require_complete_receipt_before_task_complete on erp_supply.order_tasks;
create trigger trg_require_complete_receipt_before_task_complete
before update of status on erp_supply.order_tasks
for each row execute function erp_supply.trg_require_complete_receipt_before_task_complete();

revoke all on function public.erp_x_receipt_progress(uuid) from public,anon;
grant execute on function public.erp_x_receipt_progress(uuid) to authenticated;
revoke all on function public.erp_x_save_receipt(uuid,jsonb) from public,anon;
grant execute on function public.erp_x_save_receipt(uuid,jsonb) to authenticated;

-- ============================================================================
-- 4. DIAGNÓSTICO DE INTEGRIDAD ENTRE SUBFLUJOS
-- ============================================================================
create or replace function public.erp_x_flow_integrity()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_cut_fulfilled_without_collection bigint:=0;
  v_cut_completed_without_evidence bigint:=0;
  v_auto_receipt_without_movement bigint:=0;
  v_invalid_receipt_distribution bigint:=0;
  v_active_without_task bigint:=0;
  v_duplicate_task_sessions bigint:=0;
  v_receipt_lot_without_master bigint:=0;
  v_ok boolean;
begin
  if not (
    erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('auditoria')
  ) then
    raise exception 'No autorizado para ejecutar el diagnóstico de integridad' using errcode='42501';
  end if;

  select count(*) into v_cut_fulfilled_without_collection
  from erp_supply.order_items i
  join erp_supply.orders o on o.id=i.order_id
  where o.organization_id=v_org
    and not o.is_history
    and not o.is_test
    and i.requires_cut
    and i.item_status='FULFILLED'
    and not exists(
      select 1 from erp_supply.cut_requirements r
      where r.order_item_id=i.id
        and r.process_status='READY'
        and r.collection_status='COLLECTED'
    );

  select count(*) into v_cut_completed_without_evidence
  from erp_supply.cut_executions e
  where e.organization_id=v_org
    and e.status='COMPLETED'
    and e.evidence_file_id is null;

  select count(*) into v_auto_receipt_without_movement
  from erp_supply.receipts r
  join erp_supply.orders o on o.id=r.order_id
  join erp_supply.receipt_lines rl on rl.receipt_id=r.id
  where o.organization_id=v_org
    and not o.is_test
    and coalesce(rl.accepted_quantity,0)>0
    and (
      coalesce(r.metadata->>'automaticArrival','false')='true'
      or coalesce(rl.metadata->>'source','') in('MERCANCIA_OK_V10_12','MERCANCIA_OK_V10_22')
    )
    and not exists(
      select 1 from erp_supply.inventory_movements m
      where m.order_id=o.id
        and m.movement_type='RECEIPT'
        and (
          m.metadata->>'orderItemId'=rl.order_item_id::text
          or m.reference=r.receipt_number
        )
    );

  select count(*) into v_invalid_receipt_distribution
  from erp_supply.receipt_lines rl
  join erp_supply.receipts r on r.id=rl.receipt_id
  join erp_supply.orders o on o.id=r.order_id
  where o.organization_id=v_org
    and (
      coalesce(rl.received_quantity,0)<0
      or coalesce(rl.accepted_quantity,0)<0
      or coalesce(rl.rejected_quantity,0)<0
      or coalesce(rl.accepted_quantity,0)+coalesce(rl.rejected_quantity,0)>coalesce(rl.received_quantity,0)+0.0001
    );

  select count(*) into v_active_without_task
  from erp_supply.orders o
  where o.organization_id=v_org
    and not o.is_history
    and not o.is_test
    and o.status not in('DRAFT','CLOSED','CANCELLED')
    and not exists(
      select 1 from erp_supply.order_tasks t
      where t.order_id=o.id
        and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    );

  select count(*) into v_duplicate_task_sessions
  from (
    select s.task_id
    from erp_supply.task_sessions s
    join erp_supply.order_tasks t on t.id=s.task_id
    join erp_supply.orders o on o.id=t.order_id
    where o.organization_id=v_org and s.ended_at is null
    group by s.task_id
    having count(*)>1
  ) x;

  select count(*) into v_receipt_lot_without_master
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where ii.organization_id=v_org
    and l.source_system='ERP_RECEIPT'
    and ii.material_master_id is null;

  v_ok:=v_cut_fulfilled_without_collection=0
    and v_cut_completed_without_evidence=0
    and v_auto_receipt_without_movement=0
    and v_invalid_receipt_distribution=0
    and v_active_without_task=0
    and v_duplicate_task_sessions=0
    and v_receipt_lot_without_master=0;

  return jsonb_build_object(
    'success',v_ok,
    'version','10.22.0',
    'checkedAt',now(),
    'checkedBy',v_actor,
    'counts',jsonb_build_object(
      'fulfilledCutWithoutCollection',v_cut_fulfilled_without_collection,
      'completedCutWithoutEvidence',v_cut_completed_without_evidence,
      'automaticReceiptWithoutMovement',v_auto_receipt_without_movement,
      'invalidReceiptDistribution',v_invalid_receipt_distribution,
      'activeOrderWithoutTask',v_active_without_task,
      'duplicateOpenSessionPerTask',v_duplicate_task_sessions,
      'receiptLotWithoutOfficialMaterial',v_receipt_lot_without_master
    )
  );
end;
$$;

-- Reexpone la QA unificada incluyendo ahora integridad de datos entre flujos.
create or replace function public.erp_x_run_qa_v10_22(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_matrix jsonb;
  v_controls jsonb;
  v_self jsonb;
  v_flow jsonb;
  v_ok boolean;
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'La QA integral V10.22 solo puede ser ejecutada por Super Admin' using errcode='42501';
  end if;

  v_matrix:=public.erp_x_run_qa_matrix(p_cleanup);
  v_controls:=public.erp_x_run_qa_control_suite(p_cleanup);
  v_self:=public.erp_x_v10_22_self_check();
  v_flow:=public.erp_x_flow_integrity();

  v_ok:=coalesce(v_matrix->>'status','FAILED')='PASSED'
    and coalesce(v_controls->>'status','FAILED')='PASSED'
    and coalesce((v_self->>'success')::boolean,false)
    and coalesce((v_flow->>'success')::boolean,false);

  return jsonb_build_object(
    'success',v_ok,
    'version','10.22.0',
    'matrix',v_matrix,
    'controls',v_controls,
    'selfCheck',v_self,
    'flowIntegrity',v_flow
  );
end;
$$;

revoke all on function public.erp_x_flow_integrity() from public,anon;
grant execute on function public.erp_x_flow_integrity() to authenticated;
revoke all on function public.erp_x_run_qa_v10_22(boolean) from public,anon;
grant execute on function public.erp_x_run_qa_v10_22(boolean) to authenticated;

notify pgrst,'reload schema';
commit;
