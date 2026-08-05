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
