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
