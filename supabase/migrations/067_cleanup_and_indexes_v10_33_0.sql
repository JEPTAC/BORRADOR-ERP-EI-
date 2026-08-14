-- ERP ELECTROINGENIERIA V10.33.0
-- Limpieza definitiva de datos sintéticos históricos + índices de caminos críticos.

-- Las ejecuciones sintéticas no tienen requerimientos ni batches vinculados (auditado antes de esta migración).
delete from erp_supply.cut_execution_pauses p
where exists(
  select 1 from erp_supply.cut_executions e
  where e.id=p.execution_id and e.group_key like 'SBX:%'
);

delete from erp_supply.cut_executions e
where e.group_key like 'SBX:%';

-- Limpieza exclusiva de trazas creadas por campañas automatizadas antiguas.
delete from erp_supply.system_audit a
where coalesce(a.metadata::text,'') ~* '(SBX:|QA-REF-001|qa\.erp@ei\.com\.co|manualSandbox|sandboxCutStatus|SANDBOX_)'
   or coalesce(a.before_data::text,'') ~* '(SBX:|QA-REF-001|qa\.erp@ei\.com\.co|manualSandbox|sandboxCutStatus|SANDBOX_)'
   or coalesce(a.after_data::text,'') ~* '(SBX:|QA-REF-001|qa\.erp@ei\.com\.co|manualSandbox|sandboxCutStatus|SANDBOX_)';

delete from erp_supply.outbox_events e
where coalesce(e.payload::text,'') ~* '(SBX:|QA-REF-001|qa\.erp@ei\.com\.co|manualSandbox|sandboxCutStatus|SANDBOX_)';

-- Residuo CUT_FIRST_V10_10 sin material_master_id: se conserva historial, sale de operación.
update erp_supply.inventory_lots
set source_active=false,
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'retiredAt',now(),'retiredReason','LEGACY_NON_SIESA','retiredVersion','10.33.0'
    )
where inventory_item_id='7b368749-01ad-4ef3-9cd3-0d8ea6042fc4'::uuid;

update erp_supply.inventory_items
set active=false,
    metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
      'retiredAt',now(),'retiredReason','LEGACY_NON_SIESA','retiredVersion','10.33.0'
    ),
    updated_at=now()
where id='7b368749-01ad-4ef3-9cd3-0d8ea6042fc4'::uuid
  and material_master_id is null;

-- Índices priorizados por consultas actuales; no se crean los 136 FK-indexes de forma ciega.
create index if not exists idx_deliveries_order_created_v1033
  on erp_supply.deliveries(order_id,created_at desc);

create index if not exists idx_drive_files_order_task_category_v1033
  on erp_supply.drive_files(order_id,task_id,file_category,created_at desc);

create index if not exists idx_receipt_lines_order_item_v1033
  on erp_supply.receipt_lines(order_item_id,receipt_id);

create index if not exists idx_task_sessions_task_time_v1033
  on erp_supply.task_sessions(task_id,started_at,ended_at);

create index if not exists idx_financial_validations_order_type_v1033
  on erp_supply.financial_validations(order_id,validation_type,created_at desc);

create index if not exists idx_purchase_orders_order_created_v1033
  on erp_supply.purchase_orders(order_id,created_at desc);

-- Función PVE exclusivamente productiva.
create or replace function erp_supply.finalize_arrived_purchase(p_order_id uuid, p_actor uuid)
returns boolean
language plpgsql
security definer
set search_path = erp_supply, public, pg_catalog
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
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found or v_order.current_step_code<>'RECEPCION_MERCANCIA' then return false; end if;
  if coalesce(v_order.is_test,false) then
    raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code='RECEPCION_MERCANCIA'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found then return false; end if;

  v_receipt_number:='ARR-'||replace(p_order_id::text,'-','');
  insert into erp_supply.receipts(
    order_id,receipt_number,purchase_order,supplier_name,status,received_by,received_at,metadata
  ) values(
    p_order_id,v_receipt_number,
    (select po_number from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),
    (select supplier_name from erp_supply.purchase_orders where order_id=p_order_id order by created_at desc limit 1),
    'CONFORMING',p_actor,now(),
    jsonb_build_object('source','MERCANCIA_OK_V10_22','automaticArrival',true,'flowVersion','10.33.0')
  )
  on conflict(order_id,receipt_number) do update set
    status='CONFORMING',received_by=excluded.received_by,
    received_at=coalesce(erp_supply.receipts.received_at,excluded.received_at),
    metadata=erp_supply.receipts.metadata||excluded.metadata
  returning id into v_receipt;

  for v_item in
    select i.* from erp_supply.order_items i
    where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'
    order by i.line_number
  loop
    if not exists(select 1 from erp_supply.receipt_lines rl where rl.receipt_id=v_receipt and rl.order_item_id=v_item.id) then
      insert into erp_supply.receipt_lines(
        receipt_id,order_item_id,sku,description,expected_quantity,received_quantity,
        accepted_quantity,rejected_quantity,unit,location,quality_status,metadata
      ) values(
        v_receipt,v_item.id,v_item.sku,v_item.description,v_item.quantity,
        v_item.quantity,v_item.quantity,0,v_item.unit,'RECEPCION','ACCEPTED',
        jsonb_build_object('source','MERCANCIA_OK_V10_22','materialMasterId',v_item.material_master_id,'materialVariantId',v_item.material_variant_id,'flowVersion','10.33.0')
      );
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
      v_inventory.id,'ARR-'||substr(replace(v_receipt::text,'-',''),1,12)||'-'||v_item.line_number,
      'RECEPCION',v_item.quantity,now(),v_item.material_variant_id,'ERP_RECEIPT',v_source_key,true,
      jsonb_build_object('receiptId',v_receipt,'orderItemId',v_item.id,'automaticArrival',true,'flowVersion','10.33.0')
    )
    on conflict(inventory_item_id,source_system,source_key) where source_key is not null
    do update set quantity_available=excluded.quantity_available,
      material_variant_id=excluded.material_variant_id,source_active=true,
      received_at=coalesce(erp_supply.inventory_lots.received_at,excluded.received_at),
      metadata=erp_supply.inventory_lots.metadata||excluded.metadata
    returning * into v_lot;

    if not exists(
      select 1 from erp_supply.inventory_movements m
      where m.order_id=p_order_id and m.movement_type='RECEIPT'
        and m.reference=v_receipt_number and m.metadata->>'orderItemId'=v_item.id::text
    ) then
      insert into erp_supply.inventory_movements(
        organization_id,inventory_item_id,lot_id,order_id,movement_type,
        quantity,unit,to_location,actor_profile_id,reference,metadata
      ) values(
        v_order.organization_id,v_inventory.id,v_lot.id,p_order_id,'RECEIPT',
        v_item.quantity,v_inventory.unit,v_lot.location,p_actor,v_receipt_number,
        jsonb_build_object('receiptId',v_receipt,'orderItemId',v_item.id,'automaticArrival',true,'flowVersion','10.33.0')
      );
    end if;
  end loop;

  update erp_supply.task_checklist
  set completed=true,completed_by=p_actor,completed_at=coalesce(completed_at,now()),
      note='Mercancía OK confirmada desde Recepción',
      metadata=metadata||jsonb_build_object('source','MERCANCIA_OK_V10_33')
  where task_id=v_task.id and required;

  select version into v_version from erp_supply.orders where id=p_order_id;
  perform erp_supply.execute_action_internal(
    p_order_id,'COMPLETE',
    jsonb_build_object('resultCode','MERCHANDISE_OK','detail','Mercancía recibida en sede e inventario publicado','receiptId',v_receipt,'inventoryPublished',true,'flowVersion','10.33.0'),
    p_actor,true,v_version,'ARRIVAL-'||p_order_id::text
  );
  return true;
end;
$$;

analyze erp_supply.cut_executions;
analyze erp_supply.cut_execution_pauses;
analyze erp_supply.inventory_items;
analyze erp_supply.inventory_lots;
analyze erp_supply.material_reservations;
analyze erp_supply.deliveries;

select pg_notify('pgrst','reload schema');
