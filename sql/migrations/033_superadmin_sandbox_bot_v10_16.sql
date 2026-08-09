-- ERP EI V10.16
-- Sandbox manual exclusivo para Superadministración.
-- Pedidos TEST aislados de Siesa, inventario, reservas, Drive, SLA y métricas productivas.

begin;

insert into erp_supply.modules(code,name,description,icon,sort_order)
values('sandbox','Bot de pruebas','Pedidos manuales de prueba completamente aislados','bot',175)
on conflict(code) do update set name=excluded.name,description=excluded.description,icon=excluded.icon,sort_order=excluded.sort_order,active=true;

insert into erp_supply.role_module_permissions(role_code,module_code,can_read,can_create,can_update,can_approve,can_admin)
values('super_admin','sandbox',true,true,true,true,true)
on conflict(role_code,module_code) do update set can_read=true,can_create=true,can_update=true,can_approve=true,can_admin=true;

delete from erp_supply.role_module_permissions where module_code='sandbox' and role_code<>'super_admin';

-- Los pedidos TEST son invisibles para cualquier rol diferente de Superadministración.
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
      (o.is_test and 'super_admin'=any(ctx.roles))
      or (
        not o.is_test and (
          ctx.roles && array['super_admin','gerencia','jefe_logistica','auditoria']::text[]
          or o.seller_profile_id=ctx.profile_id
          or o.current_assignee_id=ctx.profile_id
          or o.current_role_code=any(ctx.roles)
          or exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.assigned_profile_id=ctx.profile_id)
          or exists(select 1 from erp_supply.step_roles sr where sr.step_code=o.current_step_code and sr.role_code=any(ctx.roles) and sr.can_view)
        )
      )
    )
  )
$$;

create or replace function erp_supply.can_view_order_or_reception_shadow(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path=erp_supply,public,auth
as $$
  select erp_supply.can_view_order(p_order_id) or exists(
    select 1 from erp_supply.orders o
    where o.id=p_order_id and o.organization_id=erp_supply.current_org_id() and not o.is_test
      and o.order_type_code='PVE' and o.current_step_code in('COMPRAS','RECEPCION_MERCANCIA')
      and erp_supply.has_role('coordinador_logistico')
  )
$$;

create or replace function erp_supply.require_sandbox_admin()
returns uuid
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_actor uuid:=erp_supply.require_profile();
begin
  if not erp_supply.has_role('super_admin') then
    raise exception 'El Modo Sandbox es exclusivo de Superadministración' using errcode='42501';
  end if;
  return v_actor;
end;
$$;

-- Corte oficial: los pedidos TEST no generan requerimientos físicos Siesa.
create or replace function erp_supply.sync_parallel_cut_requirements(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_cut_profile uuid;
  v_count integer:=0;
begin
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then return 0; end if;
  if v_order.is_test then
    delete from erp_supply.cut_requirements where order_id=p_order_id;
    update erp_supply.orders set metadata=metadata||jsonb_build_object('sandboxCutFlow',true,'sandboxCutSyncedAt',now()),updated_at=now() where id=p_order_id;
    return 0;
  end if;
  v_cut_profile:=erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,cutProfileId}');
  delete from erp_supply.cut_requirements r
  where r.order_id=p_order_id and r.process_status='PENDING'
    and not exists(select 1 from erp_supply.order_items i where i.id=r.order_item_id and i.requires_cut and coalesce(i.metadata->>'receptionActive','true')<>'false');
  insert into erp_supply.cut_requirements(
    organization_id,order_id,order_item_id,task_id,group_key,sku,reference,description,
    unit,units_required,length_each,total_length,assigned_profile_id,material_master_id,material_variant_id,metadata
  )
  select v_order.organization_id,v_order.id,i.id,null,
    md5(i.material_master_id::text||'|'||coalesce(i.material_variant_id::text,'SIN_VARIANTE')),
    i.sku,i.reference,i.description,'M',i.quantity,i.requested_cut_length,
    round((i.quantity*i.requested_cut_length)::numeric,4),v_cut_profile,i.material_master_id,i.material_variant_id,
    jsonb_build_object('lineNumber',i.line_number,'source','SIESA_PARALLEL_CUT_V10_14','materialMasterId',i.material_master_id,'materialVariantId',i.material_variant_id)
  from erp_supply.order_items i
  where i.order_id=v_order.id and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.requires_cut and i.requested_cut_length is not null and i.requested_cut_length>0 and i.material_master_id is not null
  on conflict(order_item_id) do update set
    group_key=excluded.group_key,sku=excluded.sku,reference=excluded.reference,description=excluded.description,
    units_required=excluded.units_required,length_each=excluded.length_each,total_length=excluded.total_length,
    material_master_id=excluded.material_master_id,material_variant_id=excluded.material_variant_id,
    assigned_profile_id=coalesce(excluded.assigned_profile_id,erp_supply.cut_requirements.assigned_profile_id),
    metadata=erp_supply.cut_requirements.metadata||excluded.metadata,updated_at=now();
  get diagnostics v_count=row_count;
  if exists(select 1 from erp_supply.order_items i where i.order_id=v_order.id and i.requires_cut and coalesce(i.metadata->>'receptionActive','true')<>'false' and i.material_master_id is null) then
    raise exception 'Hay líneas de corte sin material oficial Siesa. Corrige la referencia en Recepción.';
  end if;
  update erp_supply.orders set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.14','parallel',true,'materialIdentity','SIESA_MASTER','syncedAt',now(),
    'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY')
  )),updated_at=now() where id=p_order_id;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- BOT MANUAL DE PEDIDOS TEST
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_sandbox_create(p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_count integer:=least(greatest(coalesce(erp_supply.safe_integer(p_payload->>'count'),1),1),10);
  v_scenario text:=upper(coalesce(nullif(trim(p_payload->>'scenario'),''),'FLOW'));
  v_step text:=upper(coalesce(nullif(trim(p_payload->>'stepCode'),''),'RECEPCION_PEDIDO'));
  v_type text:=upper(coalesce(nullif(trim(p_payload->>'orderType'),''),'PVC'));
  v_priority text:=upper(coalesce(nullif(trim(p_payload->>'priority'),''),'MEDIUM'));
  v_route text:=upper(coalesce(nullif(trim(p_payload->>'route'),''),'LOCAL_DISPATCH'));
  v_payment text;
  v_requires_cut boolean:=coalesce(erp_supply.safe_boolean(p_payload->>'requiresCut'),false);
  v_requires_purchase boolean;
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_num text;
  v_ids jsonb:='[]'::jsonb;
  i integer;
begin
  if not exists(select 1 from erp_supply.workflow_steps where code=v_step and active) or v_step='CLOSED' then raise exception 'Etapa Sandbox inválida'; end if;
  if not exists(select 1 from erp_supply.order_types where code=v_type and active) then v_type:='PVC'; end if;
  if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then v_priority:='MEDIUM'; end if;
  if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then v_route:='LOCAL_DISPATCH'; end if;
  v_payment:=case when v_type='PVN' then 'CASH' else 'CREDIT' end;
  v_requires_purchase:=v_type='PVE';
  for i in 1..v_count loop
    v_num:='TEST-'||to_char(clock_timestamp(),'YYMMDD-HH24MISSMS')||'-'||lpad(i::text,2,'0');
    insert into erp_supply.orders(
      organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
      client_name,client_document,client_city,client_address,client_phone,seller_profile_id,current_step_code,status,priority,
      requires_cut,requires_purchase,current_assignee_id,current_role_code,source,is_history,is_test,metadata
    ) values(
      v_org,v_num,'SANDBOX-'||v_scenario,v_type,v_payment,v_route,
      'CLIENTE DE PRUEBA · NO PRODUCTIVO','TEST','TULUÁ','DIRECCIÓN FICTICIA · SANDBOX','0000000000',v_actor,v_step,'ASSIGNED',v_priority,
      v_requires_cut,v_requires_purchase,v_actor,'super_admin','QA_BOT',false,true,
      jsonb_build_object('manualSandbox',true,'sandboxVersion','10.16','scenario',v_scenario,'createdBy',v_actor,'excludedFromProduction',true)
    ) returning * into v_order;

    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,item_status,metadata)
    values(v_order.id,1,'TEST-MAT-001','TEST-REF-001','Material sintético de prueba · no Siesa',case when v_requires_cut then 2 else 5 end,case when v_requires_cut then 'M' else 'UND' end,v_requires_cut,case when v_requires_cut then 25 else null end,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'receptionActive',true));
    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,item_status,metadata)
    values(v_order.id,2,'TEST-MAT-002','TEST-REF-002','Segundo material sintético de prueba',3,'UND',false,null,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'receptionActive',true));

    select * into v_task from erp_supply.create_task(v_order,v_step,1);
    update erp_supply.order_tasks set status='ASSIGNED',assigned_profile_id=v_actor,assigned_role_code='super_admin',assigned_at=now(),metadata=metadata||jsonb_build_object('sandbox',true) where id=v_task.id;
    update erp_supply.orders set status='ASSIGNED',current_assignee_id=v_actor,current_role_code='super_admin',metadata=metadata||jsonb_build_object('sandboxTaskId',v_task.id),updated_at=now() where id=v_order.id;
    insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
    values(v_org,v_order.id,v_task.id,'SANDBOX','SANDBOX_CREATED',null,v_step,v_actor,'super_admin',jsonb_build_object('scenario',v_scenario,'excludedFromProduction',true));
    v_ids:=v_ids||jsonb_build_array(v_order.id);
  end loop;
  return jsonb_build_object('success',true,'created',v_count,'orderIds',v_ids,'sandbox',true);
end;
$$;

create or replace function public.erp_x_sandbox_list_orders(
  p_search text default null,p_step text default null,p_status text default null,p_page integer default 1,p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  select count(*) into v_total from erp_supply.orders o
  where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false)
    and (p_step is null or p_step='' or o.current_step_code=p_step)
    and (p_status is null or p_status='' or o.status=p_status)
    and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%');
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select o.id,o.order_number "orderNumber",o.client_name "clientName",o.order_type_code "orderType",o.payment_condition_code "paymentCondition",
      o.delivery_route_code route,o.current_step_code "currentStep",ws.name "stepName",o.status,o.priority,o.requires_cut "requiresCut",o.requires_purchase "requiresPurchase",
      o.current_assignee_id "assigneeId",p.display_name "assigneeName",o.current_role_code "roleCode",0::bigint "ageBusinessSeconds",false "slaExceeded",
      o.version,false "isHistory",true "isTest",o.created_at "createdAt",o.updated_at "updatedAt",o.metadata->>'scenario' scenario
    from erp_supply.orders o join erp_supply.workflow_steps ws on ws.code=o.current_step_code left join erp_supply.profiles p on p.id=o.current_assignee_id
    where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false)
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
    order by o.updated_at desc offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),'sandbox',true,'generatedAt',now());
end;
$$;

create or replace function public.erp_x_sandbox_move(p_order_id uuid,p_step_code text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_order erp_supply.orders%rowtype;v_task erp_supply.order_tasks%rowtype;v_step text:=upper(trim(coalesce(p_step_code,'')));v_seq integer;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and is_test and source='QA_BOT' and coalesce((metadata->>'manualSandbox')::boolean,false) for update;
  if not found then raise exception 'Pedido Sandbox no disponible' using errcode='42501'; end if;
  if not exists(select 1 from erp_supply.workflow_steps where code=v_step and active and not terminal) then raise exception 'Etapa inválida'; end if;
  update erp_supply.task_sessions set ended_at=coalesce(ended_at,now()),note=coalesce(note,'')||' · cierre por movimiento Sandbox' where task_id in(select id from erp_supply.order_tasks where order_id=p_order_id) and ended_at is null;
  update erp_supply.order_tasks set status='CANCELLED',completed_at=coalesce(completed_at,now()),result_detail='Reubicado manualmente por Bot Sandbox' where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
  select coalesce(max(sequence_no),0)+1 into v_seq from erp_supply.order_tasks where order_id=p_order_id;
  insert into erp_supply.order_tasks(order_id,step_code,sequence_no,queue_code,status,assigned_profile_id,assigned_role_code,assigned_at,metadata)
  select p_order_id,v_step,v_seq,s.queue_code,'ASSIGNED',v_actor,'super_admin',now(),jsonb_build_object('sandbox',true,'manualMove',true) from erp_supply.workflow_steps s where s.code=v_step returning * into v_task;
  update erp_supply.orders set current_step_code=v_step,status='ASSIGNED',current_assignee_id=v_actor,current_role_code='super_admin',version=version+1,updated_at=now(),metadata=metadata||jsonb_build_object('sandboxTaskId',v_task.id,'sandboxMovedAt',now()) where id=p_order_id;
  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,v_task.id,'SANDBOX','SANDBOX_MOVE',v_order.current_step_code,v_step,v_actor,'super_admin',jsonb_build_object('excludedFromProduction',true));
  return jsonb_build_object('success',true,'orderId',p_order_id,'step',v_step,'taskId',v_task.id,'sandbox',true);
end;
$$;

create or replace function public.erp_x_sandbox_delete(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_deleted integer;
begin
  delete from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and is_test and source='QA_BOT' and coalesce((metadata->>'manualSandbox')::boolean,false);
  get diagnostics v_deleted=row_count;
  if v_deleted=0 then raise exception 'Pedido Sandbox no encontrado'; end if;
  return jsonb_build_object('success',true,'deleted',v_deleted);
end;
$$;

create or replace function public.erp_x_sandbox_clear()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_deleted integer;
begin
  delete from erp_supply.orders where organization_id=erp_supply.current_org_id() and is_test and source='QA_BOT' and coalesce((metadata->>'manualSandbox')::boolean,false);
  get diagnostics v_deleted=row_count;
  return jsonb_build_object('success',true,'deleted',v_deleted);
end;
$$;

-- ---------------------------------------------------------------------------
-- ALISTAMIENTO SANDBOX: orígenes ficticios y cero consumo físico.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_picking_origin_plan(p_order_item_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();v_item erp_supply.order_items%rowtype;v_order erp_supply.orders%rowtype;
  v_required numeric;v_total numeric:=0;v_remaining numeric;v_single uuid;v_row record;v_candidates jsonb:='[]'::jsonb;v_plan jsonb:='[]'::jsonb;v_take numeric;
begin
  perform erp_supply.require_profile();
  select i.* into v_item from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=p_order_item_id and o.organization_id=v_org and erp_supply.can_view_order(o.id);
  if not found then raise exception 'Línea no disponible' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=v_item.order_id;
  if v_order.is_test then
    if not erp_supply.has_role('super_admin') then raise exception 'Sandbox exclusivo de Superadministración' using errcode='42501'; end if;
    if v_item.requires_cut then return jsonb_build_object('orderItemId',v_item.id,'managedByCutting',true,'required',coalesce(v_item.quantity*v_item.requested_cut_length,v_item.quantity),'unit',v_item.unit,'candidates','[]'::jsonb,'suggestedPlan','[]'::jsonb,'sandbox',true); end if;
    return jsonb_build_object('orderItemId',v_item.id,'managedByCutting',false,'required',v_item.quantity,'unit',v_item.unit,'totalAvailable',999999,'shortage',0,
      'candidates',jsonb_build_array(jsonb_build_object('lotId',v_item.id,'inventoryItemId',v_item.id,'lotNumber','TEST-LOTE','serialNumber','SANDBOX','location','TEST-A01','locationName','Ubicación ficticia Sandbox','warehouseCode','TEST','available',999999,'sourceSystem','SANDBOX','recommended',true)),
      'suggestedPlan',jsonb_build_array(jsonb_build_object('lotId',v_item.id,'quantity',v_item.quantity)),'sandbox',true);
  end if;
  if v_item.requires_cut then return jsonb_build_object('orderItemId',v_item.id,'managedByCutting',true,'required',erp_supply.order_item_required_quantity(v_item),'unit',v_item.unit,'candidates','[]'::jsonb,'suggestedPlan','[]'::jsonb); end if;
  if v_item.material_master_id is null then raise exception 'La línea no está vinculada al maestro oficial Siesa'; end if;
  v_required:=v_item.quantity;
  select l.id into v_single from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id and l.quantity_available>=v_required
  order by l.quantity_available asc,l.received_at asc nulls last,l.id limit 1;
  for v_row in select l.id,l.inventory_item_id,l.lot_number,l.serial_number,l.location,l.quantity_available,l.warehouse_code,l.source_location_name,l.source_system,mv.variant_label
    from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id left join erp_supply.material_variants mv on mv.id=l.material_variant_id
    where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id and l.quantity_available>0
    order by case when v_single is not null and l.id=v_single then 0 else 1 end,case when v_single is null then l.quantity_available end desc,l.quantity_available asc,l.location,l.id
  loop
    v_total:=v_total+v_row.quantity_available;
    v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object('lotId',v_row.id,'inventoryItemId',v_row.inventory_item_id,'lotNumber',v_row.lot_number,'serialNumber',v_row.serial_number,'location',v_row.location,'locationName',v_row.source_location_name,'warehouseCode',v_row.warehouse_code,'available',v_row.quantity_available,'sourceSystem',v_row.source_system,'variantLabel',v_row.variant_label,'recommended',v_row.id=v_single));
  end loop;
  v_remaining:=v_required;
  if v_single is not null then v_plan:=jsonb_build_array(jsonb_build_object('lotId',v_single,'quantity',v_required)); else
    for v_row in select l.id,l.quantity_available from erp_supply.inventory_lots l join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where ii.organization_id=v_org and ii.active and ii.material_master_id=v_item.material_master_id and l.source_active and l.material_variant_id is not distinct from v_item.material_variant_id and l.quantity_available>0 order by l.quantity_available desc,l.location,l.id
    loop exit when v_remaining<=0;v_take:=least(v_remaining,v_row.quantity_available);v_plan:=v_plan||jsonb_build_array(jsonb_build_object('lotId',v_row.id,'quantity',v_take));v_remaining:=v_remaining-v_take;end loop;
  end if;
  return jsonb_build_object('orderItemId',v_item.id,'managedByCutting',false,'required',v_required,'unit',v_item.unit,'materialMasterId',v_item.material_master_id,'materialVariantId',v_item.material_variant_id,'totalAvailable',v_total,'shortage',greatest(v_required-v_total,0),'candidates',v_candidates,'suggestedPlan',v_plan);
end;
$$;

-- V10.15 guardado de precheck con bypass físico solo para pedidos TEST.
create or replace function public.erp_x_save_picking_precheck(p_order_id uuid,p_items jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth as $$
declare v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_task erp_supply.order_tasks%rowtype;v_order erp_supply.orders%rowtype;v_row jsonb;v_item erp_supply.order_items%rowtype;v_id uuid;v_result text;v_novelty text;v_origins jsonb;v_count int:=0;begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.is_test and not erp_supply.has_role('super_admin') then raise exception 'Sandbox exclusivo de Superadministración' using errcode='42501'; end if;
  if not v_order.is_test and not (erp_supply.can_access_module('picking','update') or erp_supply.has_role('aux_logistica') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado para guardar Alistamiento' using errcode='42501'; end if;
  select * into v_task from erp_supply.order_tasks where order_id=p_order_id and step_code='ALISTAMIENTO' and status='IN_PROGRESS' order by sequence_no desc limit 1;
  if not found then raise exception 'Primero debes tomar el pedido en Alistamiento'; end if;
  if v_task.assigned_profile_id is distinct from v_actor and not (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then raise exception 'Pedido asignado a otro auxiliar' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Resultados inválidos'; end if;
  for v_row in select value from jsonb_array_elements(p_items) loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_novelty:=nullif(trim(v_row->>'novelty'),'');v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');if not found then raise exception 'Línea no disponible'; end if;
    if not v_order.is_test and v_item.requires_cut and not exists(select 1 from erp_supply.cut_requirements r where r.order_item_id=v_item.id and r.process_status='READY' and r.collection_status='COLLECTED') then raise exception 'La línea % todavía está en Corte',v_item.line_number; end if;
    if v_result not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado'; end if;if v_result='MISSING' and v_novelty is null then raise exception 'Explica el faltante de la línea %',v_item.line_number; end if;
    if not v_order.is_test and v_result='FOUND' and not v_item.requires_cut then perform erp_supply.validate_picking_origins(v_item,v_origins,false); end if;
    insert into erp_supply.picking_prechecks(order_item_id,organization_id,order_id,task_id,result,novelty,checked_by,metadata)
    values(v_item.id,v_org,p_order_id,v_task.id,v_result,v_novelty,v_actor,jsonb_build_object('lineNumber',v_item.line_number,'source',case when v_order.is_test then 'SANDBOX_V10_16' else 'PARALLEL_PICKING_V10_15' end,'origins',v_origins,'sandbox',v_order.is_test))
    on conflict(order_item_id) do update set result=excluded.result,novelty=excluded.novelty,checked_by=excluded.checked_by,checked_at=now(),task_id=excluded.task_id,metadata=erp_supply.picking_prechecks.metadata||excluded.metadata;
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('success',true,'saved',v_count,'sandbox',v_order.is_test);
end;$$;

create or replace function public.erp_x_confirm_picking_round(p_order_id uuid,p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();v_org uuid:=erp_supply.current_org_id();v_order erp_supply.orders%rowtype;v_row jsonb;v_item erp_supply.order_items%rowtype;v_id uuid;v_result text;v_origins jsonb;v_allocations jsonb:='[]'::jsonb;v_alloc jsonb;v_result_payload jsonb;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if jsonb_typeof(coalesce(p_payload->'items','[]'::jsonb))<>'array' then raise exception 'Resultados de Alistamiento inválidos'; end if;
  if v_order.is_test then
    if not erp_supply.has_role('super_admin') then raise exception 'Sandbox exclusivo de Superadministración' using errcode='42501'; end if;
    v_result_payload:=public.erp_x_confirm_picking_round_v10_8(p_order_id,p_payload);
    return v_result_payload||jsonb_build_object('inventoryAllocations','[]'::jsonb,'inventoryTraceVersion','SANDBOX_V10_16','sandbox',true);
  end if;
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select i.* into v_item from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=v_id and i.order_id=p_order_id and o.organization_id=v_org and erp_supply.can_view_order(o.id) and i.item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea de Alistamiento no disponible'; end if;if v_result='FOUND' and not v_item.requires_cut then perform erp_supply.validate_picking_origins(v_item,v_origins,false); end if;
  end loop;
  for v_row in select value from jsonb_array_elements(p_payload->'items') loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');v_result:=upper(coalesce(v_row->>'result',''));v_origins:=coalesce(v_row->'origins','[]'::jsonb);
    select * into v_item from erp_supply.order_items where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if v_result='FOUND' and not v_item.requires_cut then v_alloc:=erp_supply.consume_picking_origins(v_item,v_origins,v_actor);v_allocations:=v_allocations||jsonb_build_array(jsonb_build_object('orderItemId',v_item.id,'origins',v_alloc));end if;
  end loop;
  v_result_payload:=public.erp_x_confirm_picking_round_v10_8(p_order_id,p_payload);
  return v_result_payload||jsonb_build_object('inventoryAllocations',v_allocations,'inventoryTraceVersion','10.15');
end;
$$;

-- ---------------------------------------------------------------------------
-- CORTE SANDBOX: datos sintéticos; jamás usa inventory_items/inventory_lots.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_sandbox_cutting_groups(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_page integer:=greatest(coalesce(p_page,1),1);v_size integer:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;begin
  with q as(select i.id from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false) and i.requires_cut and coalesce(i.metadata->>'sandboxCutStatus','PENDING')<>'READY' and (p_search is null or p_search='' or lower(coalesce(i.reference,'')||' '||coalesce(i.sku,'')||' '||i.description) like '%'||lower(p_search)||'%')) select count(*) into v_total from q;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from(select 'SBX:'||i.id::text "groupKey",i.reference,i.sku,i.description,null::uuid "materialMasterId",null::uuid "materialVariantId",null::text "variantLabel",1 "itemCount",1 "orderCount",i.quantity "cutCount",round((i.quantity*coalesce(i.requested_cut_length,1))::numeric,4) "totalLength",i.created_at "oldestAt",false "inProgress" from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where o.organization_id=v_org and o.is_test and o.source='QA_BOT' and coalesce((o.metadata->>'manualSandbox')::boolean,false) and i.requires_cut and coalesce(i.metadata->>'sandboxCutStatus','PENDING')<>'READY' and (p_search is null or p_search='' or lower(coalesce(i.reference,'')||' '||coalesce(i.sku,'')||' '||i.description) like '%'||lower(p_search)||'%') order by i.created_at offset(v_page-1)*v_size limit v_size)x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),'sandbox',true);
end;$$;

create or replace function public.erp_x_sandbox_cutting_group(p_group_key text)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_id uuid:=erp_supply.safe_uuid(replace(coalesce(p_group_key,''),'SBX:',''));v_item erp_supply.order_items%rowtype;v_order erp_supply.orders%rowtype;v_total numeric;begin
  select i,o into v_item,v_order from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=v_id and o.organization_id=v_org and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false) and i.requires_cut;
  if not found then raise exception 'Grupo Sandbox no encontrado'; end if;v_total:=round((v_item.quantity*coalesce(v_item.requested_cut_length,1))::numeric,4);
  return jsonb_build_object('group',jsonb_build_object('groupKey',p_group_key,'reference',v_item.reference,'sku',v_item.sku,'description',v_item.description,'itemCount',1,'orderCount',1,'cutCount',v_item.quantity,'totalLength',v_total),
    'items',jsonb_build_array(jsonb_build_object('requirementId',v_item.id,'orderId',v_order.id,'orderNumber',v_order.order_number,'clientName',v_order.client_name,'priority',v_order.priority,'orderItemId',v_item.id,'lineNumber',v_item.line_number,'sku',v_item.sku,'reference',v_item.reference,'description',v_item.description,'unit','M','unitsRequired',v_item.quantity,'lengthEach',v_item.requested_cut_length,'totalLength',v_total,'processStatus','PENDING','taskStatus','PENDING','assigneeId',v_actor,'assigneeName','Super Admin · Sandbox')),
    'reels',jsonb_build_array(jsonb_build_object('lotId','11111111-1111-4111-8111-111111111111','inventoryItemId','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa','lotNumber','TEST-C500','serialNumber','SANDBOX-500','location','ZONA TEST','locationName','Carreto ficticio 500 m','warehouseCode','TEST','quantityAvailable',500,'unit','M','sourceSystem','SANDBOX'),jsonb_build_object('lotId','22222222-2222-4222-8222-222222222222','inventoryItemId','bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb','lotNumber','TEST-C180','serialNumber','SANDBOX-180','location','ZONA TEST','locationName','Remanente ficticio 180 m','warehouseCode','TEST','quantityAvailable',180,'unit','M','sourceSystem','SANDBOX')),
    'recentBatches','[]'::jsonb,'sandbox',true);
end;$$;

create or replace function public.erp_x_sandbox_cutting_optimizer(p_group_key text)
returns jsonb language plpgsql stable security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_id uuid:=erp_supply.safe_uuid(replace(coalesce(p_group_key,''),'SBX:',''));v_item erp_supply.order_items%rowtype;v_order erp_supply.orders%rowtype;v_needed numeric;v_a jsonb;v_b jsonb;begin
  select i,o into v_item,v_order from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=v_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false);
  if not found then raise exception 'Grupo Sandbox no encontrado'; end if;v_needed:=round((v_item.quantity*coalesce(v_item.requested_cut_length,1))::numeric,4);
  v_a:=jsonb_build_object('lotId','22222222-2222-4222-8222-222222222222','lotNumber','TEST-C180','serialNumber','SANDBOX-180','location','ZONA TEST','locationName','Remanente ficticio 180 m','warehouseCode','TEST','sourceSystem','SANDBOX','usableLength',180,'projectedRemaining',180-v_needed,'sufficient',180>=v_needed,'approvalRequired',(180-v_needed>0 and 180-v_needed<50),'utilizationPct',round(v_needed/180*100,2),'operationalRank',1,'materialRank',1);
  v_b:=jsonb_build_object('lotId','11111111-1111-4111-8111-111111111111','lotNumber','TEST-C500','serialNumber','SANDBOX-500','location','ZONA TEST','locationName','Carreto ficticio 500 m','warehouseCode','TEST','sourceSystem','SANDBOX','usableLength',500,'projectedRemaining',500-v_needed,'sufficient',500>=v_needed,'approvalRequired',(500-v_needed>0 and 500-v_needed<50),'utilizationPct',round(v_needed/500*100,2),'operationalRank',2,'materialRank',2);
  return jsonb_build_object('groupKey',p_group_key,'reference',v_item.reference,'sku',v_item.sku,'description',v_item.description,'requiredLength',v_needed,'recommended',case when 180>=v_needed then v_a else v_b end,'bestMaterialUse',case when 180>=v_needed then v_a else v_b end,'candidates',jsonb_build_array(v_a,v_b),'generatedAt',now(),'sandbox',true,'rule',jsonb_build_object('criticalRemainderMeters',50,'strategy','Simulación sin inventario'));
end;$$;

create or replace function public.erp_x_sandbox_execute_cut_group(p_group_key text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_id uuid:=erp_supply.safe_uuid(replace(coalesce(p_group_key,''),'SBX:',''));v_item erp_supply.order_items%rowtype;v_order erp_supply.orders%rowtype;v_needed numeric;v_reel numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'reelLength'),500);v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);v_remaining numeric;begin
  select i,o into v_item,v_order from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=v_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false) for update;
  if not found then raise exception 'Grupo Sandbox no encontrado'; end if;v_needed:=round((v_item.quantity*coalesce(v_item.requested_cut_length,1))::numeric,4);v_remaining:=v_reel-v_needed-v_scrap;if v_remaining<0 then raise exception 'El carreto ficticio no alcanza para los cortes'; end if;
  update erp_supply.order_items set metadata=metadata||jsonb_build_object('sandboxCutStatus','READY','sandboxCutAt',now(),'sandboxReelLength',v_reel,'sandboxRemaining',v_remaining),updated_at=now() where id=v_id;
  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload) values(v_order.organization_id,v_order.id,'SANDBOX','SANDBOX_CUT','ALISTAMIENTO','ALISTAMIENTO',v_actor,'super_admin',jsonb_build_object('orderItemId',v_id,'usedLength',v_needed,'remainingLength',v_remaining,'inventoryTouched',false));
  return jsonb_build_object('success',true,'usedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_remaining,'sandbox',true,'inventoryTouched',false);
end;$$;

create or replace function public.erp_x_sandbox_resolve_cut_requirement(p_requirement_id uuid,p_resolution text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_item erp_supply.order_items%rowtype;v_order erp_supply.orders%rowtype;v_res text:=upper(trim(coalesce(p_resolution,'')));begin
  select i,o into v_item,v_order from erp_supply.order_items i join erp_supply.orders o on o.id=i.order_id where i.id=p_requirement_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false) for update;
  if not found then raise exception 'Requerimiento Sandbox no encontrado'; end if;if v_res not in('FULL_REEL','NO_CUT') then raise exception 'Resolución Sandbox inválida'; end if;
  update erp_supply.order_items set metadata=metadata||jsonb_build_object('sandboxCutStatus','READY','sandboxCutResolution',v_res,'sandboxCutAt',now(),'sandboxReason',p_payload->>'reason'),updated_at=now() where id=p_requirement_id;
  return jsonb_build_object('success',true,'resolution',v_res,'sandbox',true,'inventoryTouched',false);
end;$$;

-- Permisos públicos únicamente vía RPC autenticado.
revoke all on function public.erp_x_sandbox_create(jsonb) from public,anon;
revoke all on function public.erp_x_sandbox_list_orders(text,text,text,integer,integer) from public,anon;
revoke all on function public.erp_x_sandbox_move(uuid,text) from public,anon;
revoke all on function public.erp_x_sandbox_delete(uuid) from public,anon;
revoke all on function public.erp_x_sandbox_clear() from public,anon;
revoke all on function public.erp_x_sandbox_cutting_groups(text,integer,integer) from public,anon;
revoke all on function public.erp_x_sandbox_cutting_group(text) from public,anon;
revoke all on function public.erp_x_sandbox_cutting_optimizer(text) from public,anon;
revoke all on function public.erp_x_sandbox_execute_cut_group(text,jsonb) from public,anon;
revoke all on function public.erp_x_sandbox_resolve_cut_requirement(uuid,text,jsonb) from public,anon;
grant execute on function public.erp_x_sandbox_create(jsonb) to authenticated;
grant execute on function public.erp_x_sandbox_list_orders(text,text,text,integer,integer) to authenticated;
grant execute on function public.erp_x_sandbox_move(uuid,text) to authenticated;
grant execute on function public.erp_x_sandbox_delete(uuid) to authenticated;
grant execute on function public.erp_x_sandbox_clear() to authenticated;
grant execute on function public.erp_x_sandbox_cutting_groups(text,integer,integer) to authenticated;
grant execute on function public.erp_x_sandbox_cutting_group(text) to authenticated;
grant execute on function public.erp_x_sandbox_cutting_optimizer(text) to authenticated;
grant execute on function public.erp_x_sandbox_execute_cut_group(text,jsonb) to authenticated;
grant execute on function public.erp_x_sandbox_resolve_cut_requirement(uuid,text,jsonb) to authenticated;
grant execute on function public.erp_x_picking_origin_plan(uuid) to authenticated;
grant execute on function public.erp_x_save_picking_precheck(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_confirm_picking_round(uuid,jsonb) to authenticated;


-- ---------------------------------------------------------------------------
-- AISLAMIENTO DE MÉTRICAS: incidencias/aprobaciones Sandbox funcionan dentro
-- del pedido TEST, pero nunca entran al SLA, Centro de Excepciones o Pareto.
-- ---------------------------------------------------------------------------
create or replace function erp_supply.refresh_exception_sla(p_organization_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid;
  v_issue record;
  v_approval record;
  v_rule erp_supply.exception_sla_rules%rowtype;
  v_age bigint;
  v_level integer;
  v_severity text;
  v_target text;
  v_inserted integer:=0;
  v_updated integer:=0;
begin
  for v_org in
    select id from erp_supply.organizations
    where p_organization_id is null or id=p_organization_id
  loop
    for v_issue in
      select i.*,o.order_number,o.priority,o.current_role_code
      from erp_supply.order_issues i
      join erp_supply.orders o on o.id=i.order_id
      where i.organization_id=v_org and not o.is_test and i.status='OPEN' and i.issue_type in('NOVELTY','REPORT')
    loop
      select * into v_rule
      from erp_supply.exception_sla_rules r
      where r.organization_id=v_org and r.active and r.object_type='ISSUE'
        and r.subtype in(v_issue.issue_type,'*')
      order by case when r.subtype=v_issue.issue_type then 0 else 1 end
      limit 1;
      if not found then continue; end if;

      v_age:=erp_supply.business_seconds_between(v_org,v_issue.created_at,now());
      v_level:=case
        when v_age>=v_rule.escalation_2_seconds then 3
        when v_age>=v_rule.escalation_1_seconds then 2
        when v_age>=v_rule.warning_seconds then 1
        else 0
      end;
      if v_level>0 then
        v_severity:=case v_level when 1 then 'WARNING' when 2 then 'HIGH' else 'CRITICAL' end;
        v_target:=case v_level
          when 1 then coalesce(v_issue.target_role_code,v_issue.current_role_code,'jefe_logistica')
          when 2 then coalesce(v_rule.escalation_role_1,'jefe_logistica')
          else coalesce(v_rule.escalation_role_2,'gerencia')
        end;
        insert into erp_supply.operational_alerts(
          organization_id,order_id,source_type,source_id,alert_level,severity,target_role_code,message,metadata
        ) values(
          v_org,v_issue.order_id,'ISSUE',v_issue.id,v_level,v_severity,v_target,
          format('%s %s del pedido %s supera su SLA operativo',case when v_issue.issue_type='NOVELTY' then 'La novedad' else 'El reporte' end,v_issue.title,v_issue.order_number),
          jsonb_build_object('ageBusinessSeconds',v_age,'priority',v_issue.priority,'slaVersion','10.13')
        ) on conflict(organization_id,source_type,source_id,alert_level) do nothing;
        if found then v_inserted:=v_inserted+1; end if;
      end if;
      update erp_supply.order_issues
      set metadata=metadata||jsonb_build_object('sla',jsonb_build_object(
        'ageBusinessSeconds',v_age,
        'warningSeconds',v_rule.warning_seconds,
        'escalation1Seconds',v_rule.escalation_1_seconds,
        'escalation2Seconds',v_rule.escalation_2_seconds,
        'level',v_level,
        'refreshedAt',now()
      ))
      where id=v_issue.id;
      v_updated:=v_updated+1;
    end loop;

    for v_approval in
      select a.*,o.order_number,o.priority
      from erp_supply.approval_requests a
      join erp_supply.orders o on o.id=a.order_id
      where a.organization_id=v_org and not o.is_test and a.status='PENDING'
    loop
      select * into v_rule
      from erp_supply.exception_sla_rules r
      where r.organization_id=v_org and r.active and r.object_type='APPROVAL'
        and r.subtype in(v_approval.request_type,'*')
      order by case when r.subtype=v_approval.request_type then 0 else 1 end
      limit 1;
      if not found then continue; end if;

      v_age:=erp_supply.business_seconds_between(v_org,v_approval.created_at,now());
      v_level:=case
        when v_age>=v_rule.escalation_2_seconds then 3
        when v_age>=v_rule.escalation_1_seconds then 2
        when v_age>=v_rule.warning_seconds then 1
        else 0
      end;
      if v_level>0 then
        v_severity:=case v_level when 1 then 'WARNING' when 2 then 'HIGH' else 'CRITICAL' end;
        v_target:=case v_level
          when 1 then coalesce(v_approval.assigned_role_code,'jefe_logistica')
          when 2 then coalesce(v_rule.escalation_role_1,'gerencia')
          else coalesce(v_rule.escalation_role_2,'auditoria')
        end;
        insert into erp_supply.operational_alerts(
          organization_id,order_id,source_type,source_id,alert_level,severity,target_role_code,message,metadata
        ) values(
          v_org,v_approval.order_id,'APPROVAL',v_approval.id,v_level,v_severity,v_target,
          format('La aprobación %s del pedido %s supera su SLA operativo',v_approval.request_type,v_approval.order_number),
          jsonb_build_object('ageBusinessSeconds',v_age,'priority',v_approval.priority,'slaVersion','10.13')
        ) on conflict(organization_id,source_type,source_id,alert_level) do nothing;
        if found then v_inserted:=v_inserted+1; end if;
      end if;
      update erp_supply.approval_requests
      set request_payload=request_payload||jsonb_build_object('sla',jsonb_build_object(
        'ageBusinessSeconds',v_age,
        'warningSeconds',v_rule.warning_seconds,
        'escalation1Seconds',v_rule.escalation_1_seconds,
        'escalation2Seconds',v_rule.escalation_2_seconds,
        'level',v_level,
        'refreshedAt',now()
      ))
      where id=v_approval.id;
      v_updated:=v_updated+1;
    end loop;

    update erp_supply.operational_alerts a
    set status='CLOSED',closed_at=coalesce(closed_at,now())
    where a.organization_id=v_org and a.status<>'CLOSED' and (
      (a.source_type='ISSUE' and not exists(
        select 1 from erp_supply.order_issues i where i.id=a.source_id and i.status='OPEN'
      )) or
      (a.source_type='APPROVAL' and not exists(
        select 1 from erp_supply.approval_requests r where r.id=a.source_id and r.status='PENDING'
      ))
    );
  end loop;
  return jsonb_build_object('processed',v_updated,'alertsCreated',v_inserted,'refreshedAt',now());
end;
$$;

create or replace function public.erp_x_exception_summary()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_roles text[]:=erp_supply.current_roles();
  v_control boolean;
begin
  perform erp_supply.refresh_exception_sla(v_org);
  v_control:=erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica') or erp_supply.can_access_module('approvals','read');
  return jsonb_build_object(
    'openNovelties',(select count(*) from erp_supply.order_issues i join erp_supply.orders o on o.id=i.order_id where i.organization_id=v_org and not o.is_test and i.status='OPEN' and i.issue_type='NOVELTY' and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)),
    'openReports',(select count(*) from erp_supply.order_issues i join erp_supply.orders o on o.id=i.order_id where i.organization_id=v_org and not o.is_test and i.status='OPEN' and i.issue_type='REPORT' and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)),
    'pendingApprovals',(select count(*) from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id where a.organization_id=v_org and not o.is_test and a.status='PENDING' and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))),
    'slaWarnings',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and not exists(select 1 from erp_supply.orders o where o.id=a.order_id and o.is_test) and a.alert_level=1 and (v_control or a.target_role_code=any(v_roles))),
    'escalated',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and not exists(select 1 from erp_supply.orders o where o.id=a.order_id and o.is_test) and a.alert_level>=2 and (v_control or a.target_role_code=any(v_roles))),
    'critical',(select count(*) from erp_supply.operational_alerts a where a.organization_id=v_org and a.status='OPEN' and not exists(select 1 from erp_supply.orders o where o.id=a.order_id and o.is_test) and a.alert_level=3 and (v_control or a.target_role_code=any(v_roles))),
    'generatedAt',now()
  );
end;
$$;

create or replace function public.erp_x_exception_center(
  p_kind text default null,
  p_state text default 'OPEN',
  p_page integer default 1,
  p_page_size integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_roles text[]:=erp_supply.current_roles();
  v_control boolean;
  v_kind text:=upper(nullif(trim(coalesce(p_kind,'')),''));
  v_state text:=upper(nullif(trim(coalesce(p_state,'')),''));
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,100),1),250);
  v_total bigint;
  v_items jsonb;
begin
  perform erp_supply.refresh_exception_sla(v_org);
  v_control:=erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica') or erp_supply.can_access_module('approvals','read');

  with unified as (
    select
      i.id,'ISSUE'::text item_type,i.issue_type subtype,i.order_id,o.order_number,o.client_name,o.priority,
      coalesce(t.step_code,o.current_step_code) process_code,i.title,i.detail,i.status,
      i.target_role_code target_role,i.created_by actor_id,p.display_name actor_name,i.created_at,
      i.resolved_at closed_at,
      coalesce((i.metadata#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,i.created_at,coalesce(i.resolved_at,now()))) age_business_seconds,
      coalesce((i.metadata#>>'{sla,level}')::integer,0) sla_level,
      i.blocking,
      i.source_code source_code,
      null::text decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor or (i.source_code='NO_DELIVERY' and erp_supply.can_access_module('shipping','update'))) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='ISSUE' and oa.source_id=i.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    join erp_supply.profiles p on p.id=i.created_by
    left join erp_supply.order_tasks t on t.id=i.task_id
    where i.organization_id=v_org and not o.is_test
      and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)

    union all

    select
      a.id,'APPROVAL'::text item_type,a.request_type subtype,a.order_id,o.order_number,o.client_name,o.priority,
      o.current_step_code process_code,coalesce(a.request_payload->>'exceptionCode',a.request_type) title,a.reason detail,a.status,
      a.assigned_role_code target_role,a.requested_by actor_id,p.display_name actor_name,a.created_at,
      a.decided_at closed_at,
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) age_business_seconds,
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) sla_level,
      true blocking,
      coalesce(a.request_payload->>'exceptionCode',a.request_type) source_code,
      a.decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia')) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='APPROVAL' and oa.source_id=a.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles p on p.id=a.requested_by
    where a.organization_id=v_org and not o.is_test
      and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))
  ), filtered as (
    select * from unified u
    where (v_kind is null or u.item_type=v_kind or u.subtype=v_kind)
      and (
        v_state is null
        or (v_state='OPEN' and ((u.item_type='ISSUE' and u.status='OPEN') or (u.item_type='APPROVAL' and u.status='PENDING')))
        or (v_state='CLOSED' and ((u.item_type='ISSUE' and u.status<>'OPEN') or (u.item_type='APPROVAL' and u.status<>'PENDING')))
        or u.status=v_state
      )
  )
  select count(*) into v_total from filtered;

  with unified as (
    select
      i.id,'ISSUE'::text item_type,i.issue_type subtype,i.order_id,o.order_number,o.client_name,o.priority,
      coalesce(t.step_code,o.current_step_code) process_code,i.title,i.detail,i.status,
      i.target_role_code target_role,p.display_name actor_name,i.created_at,i.resolved_at closed_at,
      coalesce((i.metadata#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,i.created_at,coalesce(i.resolved_at,now()))) age_business_seconds,
      coalesce((i.metadata#>>'{sla,level}')::integer,0) sla_level,i.blocking,i.source_code source_code,null::text decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor or (i.source_code='NO_DELIVERY' and erp_supply.can_access_module('shipping','update'))) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='ISSUE' and oa.source_id=i.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    join erp_supply.profiles p on p.id=i.created_by
    left join erp_supply.order_tasks t on t.id=i.task_id
    where i.organization_id=v_org and not o.is_test and (v_control or i.created_by=v_actor or i.target_role_code=any(v_roles) or o.current_assignee_id=v_actor)
    union all
    select
      a.id,'APPROVAL'::text item_type,a.request_type subtype,a.order_id,o.order_number,o.client_name,o.priority,
      o.current_step_code process_code,coalesce(a.request_payload->>'exceptionCode',a.request_type) title,a.reason detail,a.status,
      a.assigned_role_code target_role,p.display_name actor_name,a.created_at,a.decided_at closed_at,
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) age_business_seconds,
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) sla_level,true blocking,
      coalesce(a.request_payload->>'exceptionCode',a.request_type) source_code,a.decision_reason,
      (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia')) can_resolve,
      (select oa.target_role_code from erp_supply.operational_alerts oa where oa.organization_id=v_org and oa.source_type='APPROVAL' and oa.source_id=a.id and oa.status='OPEN' order by oa.alert_level desc limit 1) escalated_role
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles p on p.id=a.requested_by
    where a.organization_id=v_org and not o.is_test and (v_control or a.requested_by=v_actor or a.assigned_profile_id=v_actor or a.assigned_role_code=any(v_roles))
  ), filtered as (
    select * from unified u
    where (v_kind is null or u.item_type=v_kind or u.subtype=v_kind)
      and (
        v_state is null
        or (v_state='OPEN' and ((u.item_type='ISSUE' and u.status='OPEN') or (u.item_type='APPROVAL' and u.status='PENDING')))
        or (v_state='CLOSED' and ((u.item_type='ISSUE' and u.status<>'OPEN') or (u.item_type='APPROVAL' and u.status<>'PENDING')))
        or u.status=v_state
      )
  ), page_rows as (
    select * from filtered
    order by
      case when (item_type='ISSUE' and status='OPEN') or (item_type='APPROVAL' and status='PENDING') then 0 else 1 end,
      sla_level desc,
      case priority when 'CRITICAL' then 5 when 'URGENT' then 4 when 'HIGH' then 3 when 'MEDIUM' then 2 else 1 end desc,
      age_business_seconds desc,created_at asc
    offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'itemType',item_type,'subtype',subtype,'orderId',order_id,'orderNumber',order_number,'clientName',client_name,
    'priority',priority,'processCode',process_code,'title',title,'detail',detail,'status',status,'targetRole',target_role,
    'actorName',actor_name,'createdAt',created_at,'closedAt',closed_at,'ageBusinessSeconds',age_business_seconds,
    'slaLevel',sla_level,'blocking',blocking,'sourceCode',source_code,'decisionReason',decision_reason,'canResolve',can_resolve,'escalatedRole',escalated_role
  ) order by
    case when (item_type='ISSUE' and status='OPEN') or (item_type='APPROVAL' and status='PENDING') then 0 else 1 end,
    sla_level desc,age_business_seconds desc),'[]'::jsonb)
  into v_items from page_rows;

  return jsonb_build_object(
    'items',v_items,
    'summary',public.erp_x_exception_summary(),
    'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer),
    'generatedAt',now()
  );
end;
$$;

create or replace function public.erp_x_list_approvals(p_status text default 'PENDING',p_page integer default 1,p_page_size integer default 50)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_total bigint;
  v_items jsonb;
  v_page int:=greatest(p_page,1);
  v_size int:=least(greatest(p_page_size,1),200);
begin
  perform erp_supply.refresh_exception_sla(v_org);
  select count(*) into v_total
  from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id
  where a.organization_id=v_org and not o.is_test and (p_status is null or a.status=p_status)
    and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica'));

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items from (
    select a.id,a.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",o.priority,
      o.current_step_code "processCode",a.request_type "requestType",a.status,a.reason,a.request_payload "requestPayload",
      rq.display_name "requestedBy",a.assigned_role_code "assignedRole",a.decision_reason "decisionReason",
      a.created_at "createdAt",a.decided_at "decidedAt",
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) "ageBusinessSeconds",
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) "slaLevel"
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles rq on rq.id=a.requested_by
    where a.organization_id=v_org and not o.is_test and (p_status is null or a.status=p_status)
      and (a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles) or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica'))
    order by coalesce((a.request_payload#>>'{sla,level}')::integer,0) desc,a.created_at asc
    offset (v_page-1)*v_size limit v_size
  ) x;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int));
end;
$$;

create or replace function public.erp_x_cause_analytics(p_date_from date default null,p_date_to date default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_from date:=coalesce(p_date_from,current_date-30);
  v_to date:=coalesce(p_date_to,current_date);
  v_result jsonb;
begin
  perform erp_supply.require_profile();
  if not (erp_supply.can_access_module('reports','read') or erp_supply.has_role('auditoria') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para consultar analítica causal' using errcode='42501';
  end if;
  if v_to<v_from then raise exception 'Rango de fechas inválido'; end if;

  with events as (
    select
      i.created_at event_at,
      coalesce(nullif(i.source_code,''),nullif(i.title,''),'INCIDENCIA') cause_code,
      null::text reference,
      coalesce(t.step_code,o.current_step_code) process_code,
      seller.display_name seller_name,
      po.supplier_name supplier_name
    from erp_supply.order_issues i
    join erp_supply.orders o on o.id=i.order_id
    left join erp_supply.order_tasks t on t.id=i.task_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where i.organization_id=v_org and not o.is_test and i.issue_type in('NOVELTY','REPORT')
      and i.created_at>=v_from::timestamptz and i.created_at<(v_to+1)::timestamptz

    union all

    select
      pc.checked_at,'MERCANCIA_NO_ENCONTRADA',coalesce(oi.reference,oi.sku,oi.description),'ALISTAMIENTO',
      seller.display_name,po.supplier_name
    from erp_supply.picking_prechecks pc
    join erp_supply.orders o on o.id=pc.order_id
    join erp_supply.order_items oi on oi.id=pc.order_item_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where pc.organization_id=v_org and not o.is_test and pc.result='MISSING'
      and pc.checked_at>=v_from::timestamptz and pc.checked_at<(v_to+1)::timestamptz

    union all

    select
      coalesce(cr.ready_at,cr.updated_at),'CORTE_ASIGNADO_INCORRECTAMENTE',coalesce(cr.reference,cr.sku,cr.description),'CORTE',
      seller.display_name,po.supplier_name
    from erp_supply.cut_requirements cr
    join erp_supply.orders o on o.id=cr.order_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    left join lateral (
      select p.supplier_name from erp_supply.purchase_orders p where p.order_id=o.id order by p.created_at desc limit 1
    ) po on true
    where cr.organization_id=v_org and not o.is_test and cr.resolution_code='NO_CUT'
      and coalesce(cr.ready_at,cr.updated_at)>=v_from::timestamptz and coalesce(cr.ready_at,cr.updated_at)<(v_to+1)::timestamptz

    union all

    select
      r.received_at,'RECEPCION_CON_RECHAZO',coalesce(oi.reference,oi.sku,oi.description),'RECEPCION_MERCANCIA',
      seller.display_name,r.supplier_name
    from erp_supply.receipt_lines rl
    join erp_supply.receipts r on r.id=rl.receipt_id
    join erp_supply.orders o on o.id=r.order_id
    left join erp_supply.order_items oi on oi.id=rl.order_item_id
    left join erp_supply.profiles seller on seller.id=o.seller_profile_id
    where o.organization_id=v_org and not o.is_test and coalesce(rl.rejected_quantity,0)>0 and r.received_at is not null
      and r.received_at>=v_from::timestamptz and r.received_at<(v_to+1)::timestamptz
  )
  select jsonb_build_object(
    'from',v_from,'to',v_to,'totalEvents',(select count(*) from events),
    'causes',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(cause_code,''),'Sin clasificar') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'references',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(reference,''),'Sin referencia') label,count(*) n from events where reference is not null group by 1 order by n desc limit 12) x),
    'sellers',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(seller_name,''),'Sin asesor') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'suppliers',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(supplier_name,''),'Sin proveedor') label,count(*) n from events where supplier_name is not null group by 1 order by n desc limit 12) x),
    'processes',(select coalesce(jsonb_agg(jsonb_build_object('label',label,'count',n) order by n desc),'[]'::jsonb) from (select coalesce(nullif(process_code,''),'SIN_ETAPA') label,count(*) n from events group by 1 order by n desc limit 12) x),
    'generatedAt',now()
  ) into v_result;
  return v_result;
end;
$$;

update erp_supply.operational_alerts a set status='CLOSED',closed_at=coalesce(closed_at,now()),metadata=metadata||jsonb_build_object('sandboxExcluded',true)
where exists(select 1 from erp_supply.orders o where o.id=a.order_id and o.is_test) and a.status<>'CLOSED';


-- Dashboard productivo tampoco cuenta aprobaciones Sandbox.
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
      'pendingApprovals',(select count(*) from erp_supply.approval_requests a join erp_supply.orders o on o.id=a.order_id where a.organization_id=v_org and not o.is_test and a.status='PENDING' and (a.assigned_profile_id=v_profile or a.assigned_role_code=any(erp_supply.current_roles())))
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

notify pgrst,'reload schema';
commit;
