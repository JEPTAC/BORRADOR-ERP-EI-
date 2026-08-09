-- V10.16.2 · Hotfix visual + Sandbox paralelo Corte/Alistamiento
-- Ejecutar sobre bases que ya estén en V10.16.1.

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

  v_cut_profile:=coalesce(erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,cutProfileId}'),v_order.current_assignee_id);

  delete from erp_supply.cut_requirements r
  where r.order_id=p_order_id and r.process_status='PENDING'
    and not exists(
      select 1
      from erp_supply.order_items i
      where i.id=r.order_item_id
        and i.requires_cut
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
    );

  if v_order.is_test then
    insert into erp_supply.cut_requirements(
      organization_id,order_id,order_item_id,task_id,group_key,sku,reference,description,
      unit,units_required,length_each,total_length,assigned_profile_id,metadata
    )
    select
      v_order.organization_id,
      v_order.id,
      i.id,
      null,
      'SBX:'||i.id::text,
      i.sku,
      i.reference,
      i.description,
      'M',
      i.quantity,
      coalesce(i.requested_cut_length,1),
      round((i.quantity*coalesce(i.requested_cut_length,1))::numeric,4),
      v_cut_profile,
      jsonb_build_object(
        'lineNumber',i.line_number,
        'source','SANDBOX_PARALLEL_CUT_V10_16_2',
        'sandbox',true,
        'synthetic',true
      )
    from erp_supply.order_items i
    where i.order_id=v_order.id
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
      and i.requires_cut
      and coalesce(i.requested_cut_length,0)>0
    on conflict(order_item_id) do update set
      group_key=excluded.group_key,
      sku=excluded.sku,
      reference=excluded.reference,
      description=excluded.description,
      units_required=excluded.units_required,
      length_each=excluded.length_each,
      total_length=excluded.total_length,
      assigned_profile_id=coalesce(excluded.assigned_profile_id,erp_supply.cut_requirements.assigned_profile_id),
      metadata=erp_supply.cut_requirements.metadata||excluded.metadata,
      updated_at=now();

    get diagnostics v_count=row_count;

    update erp_supply.orders
    set metadata=metadata||jsonb_build_object(
      'sandboxCutFlow',
      coalesce(metadata->'sandboxCutFlow','{}'::jsonb)||jsonb_build_object(
        'parallel',true,
        'version','10.16.2',
        'syncedAt',now(),
        'pendingRequirements',(
          select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY'
        ),
        'pendingCollection',(
          select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status='READY' and collection_status='PENDING'
        )
      )
    ),updated_at=now()
    where id=p_order_id;

    return v_count;
  end if;

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

  if exists(
    select 1 from erp_supply.order_items i
    where i.order_id=v_order.id
      and i.requires_cut
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
      and i.material_master_id is null
  ) then
    raise exception 'Hay líneas de corte sin material oficial Siesa. Corrige la referencia en Recepción.';
  end if;

  update erp_supply.orders set metadata=metadata||jsonb_build_object('cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.14','parallel',true,'materialIdentity','SIESA_MASTER','syncedAt',now(),
    'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY')
  )),updated_at=now() where id=p_order_id;
  return v_count;
end;
$$;

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
      jsonb_build_object('manualSandbox',true,'sandboxVersion','10.16.2','scenario',v_scenario,'createdBy',v_actor,'excludedFromProduction',true)
    ) returning * into v_order;

    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,item_status,metadata)
    values(v_order.id,1,'TEST-MAT-001','TEST-REF-001','Material sintético de prueba · no Siesa',case when v_requires_cut then 2 else 5 end,case when v_requires_cut then 'M' else 'UND' end,v_requires_cut,case when v_requires_cut then 25 else null end,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'receptionActive',true));
    insert into erp_supply.order_items(order_id,line_number,sku,reference,description,quantity,unit,requires_cut,requested_cut_length,item_status,metadata)
    values(v_order.id,2,'TEST-MAT-002','TEST-REF-002','Segundo material sintético de prueba',3,'UND',false,null,'PENDING',jsonb_build_object('sandbox',true,'synthetic',true,'receptionActive',true));

    if v_requires_cut then
      perform erp_supply.sync_parallel_cut_requirements(v_order.id);
    end if;

    select * into v_task from erp_supply.create_task(v_order,v_step,1);
    update erp_supply.order_tasks
    set status='ASSIGNED',assigned_profile_id=v_actor,assigned_role_code='super_admin',assigned_at=now(),metadata=metadata||jsonb_build_object('sandbox',true)
    where id=v_task.id;
    update erp_supply.orders
    set status='ASSIGNED',current_assignee_id=v_actor,current_role_code='super_admin',metadata=metadata||jsonb_build_object('sandboxTaskId',v_task.id),updated_at=now()
    where id=v_order.id;
    insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
    values(v_org,v_order.id,v_task.id,'SANDBOX','SANDBOX_CREATED',null,v_step,v_actor,'super_admin',jsonb_build_object('scenario',v_scenario,'excludedFromProduction',true));
    v_ids:=v_ids||jsonb_build_array(v_order.id);
  end loop;

  return jsonb_build_object('success',true,'created',v_count,'orderIds',v_ids,'sandbox',true);
end;
$$;

create or replace function public.erp_x_sandbox_move(p_order_id uuid,p_step_code text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_step text:=upper(trim(coalesce(p_step_code,'')));
  v_seq integer;
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and is_test and source='QA_BOT' and coalesce((metadata->>'manualSandbox')::boolean,false)
  for update;
  if not found then raise exception 'Pedido Sandbox no disponible' using errcode='42501'; end if;
  if not exists(select 1 from erp_supply.workflow_steps where code=v_step and active and not terminal) then raise exception 'Etapa inválida'; end if;

  update erp_supply.task_sessions
  set ended_at=coalesce(ended_at,now()),note=coalesce(note,'')||' · cierre por movimiento Sandbox'
  where task_id in(select id from erp_supply.order_tasks where order_id=p_order_id) and ended_at is null;

  update erp_supply.order_tasks
  set status='CANCELLED',completed_at=coalesce(completed_at,now()),result_detail='Reubicado manualmente por Bot Sandbox'
  where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');

  select coalesce(max(sequence_no),0)+1 into v_seq from erp_supply.order_tasks where order_id=p_order_id;
  insert into erp_supply.order_tasks(order_id,step_code,sequence_no,queue_code,status,assigned_profile_id,assigned_role_code,assigned_at,metadata)
  select p_order_id,v_step,v_seq,s.queue_code,'ASSIGNED',v_actor,'super_admin',now(),jsonb_build_object('sandbox',true,'manualMove',true)
  from erp_supply.workflow_steps s
  where s.code=v_step
  returning * into v_task;

  update erp_supply.orders
  set current_step_code=v_step,status='ASSIGNED',current_assignee_id=v_actor,current_role_code='super_admin',version=version+1,updated_at=now(),metadata=metadata||jsonb_build_object('sandboxTaskId',v_task.id,'sandboxMovedAt',now())
  where id=p_order_id;

  if exists(select 1 from erp_supply.order_items where order_id=p_order_id and requires_cut) then
    perform erp_supply.sync_parallel_cut_requirements(p_order_id);
  end if;

  insert into erp_supply.order_events(organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,p_order_id,v_task.id,'SANDBOX','SANDBOX_MOVE',v_order.current_step_code,v_step,v_actor,'super_admin',jsonb_build_object('excludedFromProduction',true));

  return jsonb_build_object('success',true,'orderId',p_order_id,'step',v_step,'taskId',v_task.id,'sandbox',true);
end;
$$;

create or replace function public.erp_x_sandbox_execute_cut_group(p_group_key text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_id uuid:=erp_supply.safe_uuid(replace(coalesce(p_group_key,''),'SBX:',''));
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_needed numeric;
  v_reel numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'reelLength'),500);
  v_scrap numeric:=coalesce(erp_supply.safe_numeric(p_payload->>'scrapLength'),0);
  v_remaining numeric;
begin
  select i.* into v_item
  from erp_supply.order_items i
  join erp_supply.orders o on o.id=i.order_id
  where i.id=v_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  for update of i;
  if not found then raise exception 'Grupo Sandbox no encontrado'; end if;

  select o.* into v_order
  from erp_supply.orders o
  where o.id=v_item.order_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  for update;
  if not found then raise exception 'Grupo Sandbox no encontrado'; end if;

  v_needed:=round((v_item.quantity*coalesce(v_item.requested_cut_length,1))::numeric,4);
  v_remaining:=v_reel-v_needed-v_scrap;
  if v_remaining<0 then raise exception 'El carreto ficticio no alcanza para los cortes'; end if;

  update erp_supply.order_items
  set metadata=metadata||jsonb_build_object('sandboxCutStatus','READY','sandboxCutAt',now(),'sandboxReelLength',v_reel,'sandboxRemaining',v_remaining),updated_at=now()
  where id=v_id;

  update erp_supply.cut_requirements
  set process_status='READY',resolution_code='CUT',ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
      metadata=metadata||jsonb_build_object('sandbox',true,'sandboxReelLength',v_reel,'sandboxRemaining',v_remaining),updated_at=now()
  where order_item_id=v_id and order_id=v_order.id;

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('sandboxCutFlow',coalesce(metadata->'sandboxCutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.16.2','parallel',true,'lastCutAt',now(),
    'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=v_order.id and process_status<>'READY'),
    'pendingCollection',(select count(*) from erp_supply.cut_requirements where order_id=v_order.id and process_status='READY' and collection_status='PENDING')
  )),updated_at=now()
  where id=v_order.id;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,actor_profile_id,actor_role_code,payload)
  values(v_order.organization_id,v_order.id,'SANDBOX','SANDBOX_CUT','ALISTAMIENTO','ALISTAMIENTO',v_actor,'super_admin',jsonb_build_object('orderItemId',v_id,'usedLength',v_needed,'remainingLength',v_remaining,'inventoryTouched',false));

  return jsonb_build_object('success',true,'usedLength',v_needed,'scrapLength',v_scrap,'remainingLength',v_remaining,'sandbox',true,'inventoryTouched',false);
end;
$$;

create or replace function public.erp_x_sandbox_resolve_cut_requirement(p_requirement_id uuid,p_resolution text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=erp_supply,public,auth,pg_catalog as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_res text:=upper(trim(coalesce(p_resolution,'')));
begin
  select i.* into v_item
  from erp_supply.order_items i
  join erp_supply.orders o on o.id=i.order_id
  where i.id=p_requirement_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  for update of i;
  if not found then raise exception 'Requerimiento Sandbox no encontrado'; end if;

  select o.* into v_order
  from erp_supply.orders o
  where o.id=v_item.order_id and o.organization_id=erp_supply.current_org_id() and o.is_test and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  for update;
  if not found then raise exception 'Requerimiento Sandbox no encontrado'; end if;

  if v_res not in('FULL_REEL','NO_CUT') then raise exception 'Resolución Sandbox inválida'; end if;

  update erp_supply.order_items
  set metadata=metadata||jsonb_build_object('sandboxCutStatus','READY','sandboxCutResolution',v_res,'sandboxCutAt',now(),'sandboxReason',p_payload->>'reason'),updated_at=now()
  where id=p_requirement_id;

  update erp_supply.cut_requirements
  set process_status='READY',resolution_code=v_res,ready_at=now(),ready_by=v_actor,assigned_profile_id=v_actor,
      metadata=metadata||jsonb_build_object('sandbox',true,'sandboxReason',p_payload->>'reason'),updated_at=now()
  where order_item_id=p_requirement_id and order_id=v_order.id;

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('sandboxCutFlow',coalesce(metadata->'sandboxCutFlow','{}'::jsonb)||jsonb_build_object(
    'version','10.16.2','parallel',true,'lastCutAt',now(),
    'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=v_order.id and process_status<>'READY'),
    'pendingCollection',(select count(*) from erp_supply.cut_requirements where order_id=v_order.id and process_status='READY' and collection_status='PENDING')
  )),updated_at=now()
  where id=v_order.id;

  return jsonb_build_object('success',true,'resolution',v_res,'sandbox',true,'inventoryTouched',false);
end;
$$;
