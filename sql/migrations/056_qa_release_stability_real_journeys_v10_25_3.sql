-- ERP EI V10.25.3 · QA release estable, por etapas y con prerrequisitos reales
-- Requiere: 053, 054, 055.
-- Corrige:
-- 1) limpieza QA con receipt_lines -> order_items;
-- 2) recorridos ROUTE/JOURNEY monolíticos que superaban statement_timeout;
-- 3) PVN/Facturación sin factura sintética de QA;
-- 4) ejecución ordenada: 336 rutas -> 336 recorridos -> campaña profunda;
-- 5) health de liberación sin contaminarse con QA histórica/test.

begin;

-- ---------------------------------------------------------------------------
-- 1. Integridad de borrado: una receipt_line no puede sobrevivir a su order_item.
-- ---------------------------------------------------------------------------
alter table erp_supply.receipt_lines
  drop constraint if exists receipt_lines_order_item_id_fkey;

alter table erp_supply.receipt_lines
  add constraint receipt_lines_order_item_id_fkey
  foreign key(order_item_id)
  references erp_supply.order_items(id)
  on delete cascade;

-- Índice para selección incremental/priorizada de casos.
create index if not exists idx_qa_deep_cases_pending_priority_v10253
  on erp_supply.qa_deep_cases(qa_run_id,status,family,case_key);

-- Estado persistente de los recorridos largos. Una invocación procesa UNA etapa.
create table if not exists erp_supply.qa_release_journey_state(
  case_id uuid primary key references erp_supply.qa_deep_cases(id) on delete cascade,
  qa_run_id uuid not null references erp_supply.qa_runs(id) on delete cascade,
  order_id uuid references erp_supply.orders(id) on delete set null,
  order_number text,
  expected_path jsonb not null default '[]'::jsonb,
  actual_path jsonb not null default '[]'::jsonb,
  action_sequence jsonb not null default '[]'::jsonb,
  steps_executed integer not null default 0,
  first_step_done boolean not null default false,
  status text not null default 'RUNNING' check(status in('RUNNING','PASSED','FAILED')),
  started_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  last_error text
);
create index if not exists idx_qa_release_journey_run
  on erp_supply.qa_release_journey_state(qa_run_id,status,updated_at);
revoke all on erp_supply.qa_release_journey_state from public,anon,authenticated;

-- ---------------------------------------------------------------------------
-- 2. Borrado Sandbox robusto. Solo permite QA_BOT + TEST + manualSandbox.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_sandbox_delete(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_deleted integer:=0;
begin
  if not exists(
    select 1 from erp_supply.orders o
    where o.id=p_order_id and o.organization_id=v_org
      and o.is_test and o.source='QA_BOT'
      and coalesce((o.metadata->>'manualSandbox')::boolean,false)
  ) then
    raise exception 'Pedido Sandbox no encontrado' using errcode='42501';
  end if;

  -- Compatibilidad con bases donde existían receipt_lines anteriores al FK CASCADE.
  delete from erp_supply.receipt_lines rl
  where exists(select 1 from erp_supply.receipts r where r.id=rl.receipt_id and r.order_id=p_order_id)
     or exists(select 1 from erp_supply.order_items i where i.id=rl.order_item_id and i.order_id=p_order_id);

  delete from erp_supply.orders
  where id=p_order_id and organization_id=v_org and is_test and source='QA_BOT';
  get diagnostics v_deleted=row_count;

  if v_deleted<>1 then raise exception 'No fue posible eliminar el pedido Sandbox'; end if;
  return jsonb_build_object('success',true,'deleted',v_deleted,'version','10.25.3');
end;
$$;

create or replace function public.erp_x_sandbox_clear()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_id uuid;v_deleted integer:=0;v_failed integer:=0;
begin
  for v_id in
    select id from erp_supply.orders
    where organization_id=v_org and is_test and source='QA_BOT'
      and coalesce((metadata->>'manualSandbox')::boolean,false)
    order by created_at
  loop
    begin
      perform public.erp_x_sandbox_delete(v_id);
      v_deleted:=v_deleted+1;
    exception when others then
      v_failed:=v_failed+1;
    end;
  end loop;
  return jsonb_build_object('success',v_failed=0,'deleted',v_deleted,'failed',v_failed,'version','10.25.3');
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Archivo sintético: solo para pedidos TEST. No toca Google Drive real.
-- ---------------------------------------------------------------------------
create or replace function erp_supply.qa_synthetic_file(
  p_order_id uuid,
  p_task_id uuid,
  p_category text,
  p_actor uuid,
  p_label text default null
)
returns uuid
language plpgsql
security definer
set search_path=erp_supply,public,pg_catalog
as $$
declare
  v_org uuid;v_id uuid;v_category text:=upper(trim(coalesce(p_category,'')));
begin
  select organization_id into v_org
  from erp_supply.orders
  where id=p_order_id and is_test and source='QA_BOT';
  if v_org is null then raise exception 'qa_synthetic_file solo admite pedidos QA_BOT TEST'; end if;
  if v_category='' then raise exception 'Categoría de evidencia QA requerida'; end if;

  insert into erp_supply.drive_files(
    organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,
    size_bytes,uploaded_by,metadata
  ) values(
    v_org,p_order_id,p_task_id,v_category,
    'QA-SYNTH-'||gen_random_uuid()::text,
    coalesce(nullif(trim(p_label),''),lower(v_category)||'-qa.pdf'),
    case when v_category='DELIVERY_EVIDENCE' then 'image/jpeg' else 'application/pdf' end,
    128,p_actor,
    jsonb_build_object('qaSynthetic',true,'bytesUploaded',false,'excludedFromProduction',true,'version','10.25.3')
  ) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function erp_supply.qa_synthetic_file(uuid,uuid,text,uuid,text) from public;

-- ---------------------------------------------------------------------------
-- 4. Prepara y EJECUTA la operación real de cada etapa QA.
--    Devuelve advanced=true cuando el RPC específico ya avanzó el workflow.
-- ---------------------------------------------------------------------------
create or replace function erp_supply.qa_execute_step_domain(
  p_order_id uuid,
  p_step text,
  p_actor uuid,
  p_case_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_step text:=upper(trim(coalesce(p_step,'')));
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_item_code text;v_lines jsonb;v_items jsonb;v_pickups jsonb;
  v_pick uuid;v_cut_profile uuid;v_file uuid;v_result jsonb:='{}'::jsonb;
  v_group text;v_exec uuid;v_group_count int:=0;
begin
  select * into v_order from erp_supply.orders
  where id=p_order_id and is_test and source='QA_BOT' for update;
  if not found then raise exception 'Pedido QA de recorrido no disponible'; end if;
  if v_order.current_step_code<>v_step then
    raise exception 'Desalineación QA: esperado %, actual %',v_step,v_order.current_step_code;
  end if;

  select * into v_task from erp_supply.order_tasks
  where order_id=p_order_id and step_code=v_step
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1;
  if not found then raise exception 'La etapa % no tiene tarea activa',v_step; end if;

  -- Simula conscientemente los checklist que un usuario completaría en la UI.
  for v_item_code in
    select item_code from erp_supply.task_checklist
    where task_id=v_task.id and required and not completed
    order by sort_order,item_code
  loop
    perform public.erp_x_update_checklist(v_task.id,v_item_code,true,'QA release 10.25.3');
  end loop;

  if v_step in('CARTERA','CAJA') then
    v_result:=public.erp_x_save_financial_validation(p_order_id,jsonb_build_object(
      'validationType',v_step,'decision','APPROVED','amount',100000,
      'reference','QA-'||substr(p_case_id::text,1,8),'notes','Validación sintética QA release 10.25.3',
      'metadata',jsonb_build_object('qaSynthetic',true,'caseId',p_case_id)
    ));
    return jsonb_build_object('advanced',false,'operation','FINANCIAL_VALIDATION','result',v_result);

  elsif v_step='COMPRAS' then
    v_result:=public.erp_x_save_purchase_order(p_order_id,jsonb_build_object(
      'poNumber','PO-QA-'||substr(replace(p_case_id::text,'-',''),1,12),
      'supplierName','PROVEEDOR SINTÉTICO QA','status','CONFIRMED','totalAmount',100000,'currency','COP',
      'expectedAt',(now()+interval '1 day')::text,
      'metadata',jsonb_build_object('qaSynthetic',true,'caseId',p_case_id)
    ));
    return jsonb_build_object('advanced',false,'operation','PURCHASE_ORDER','result',v_result);

  elsif v_step='RECEPCION_MERCANCIA' then
    select coalesce(jsonb_agg(jsonb_build_object(
      'orderItemId',i.id,'receivedQuantity',i.quantity,'acceptedQuantity',i.quantity,
      'rejectedQuantity',0,'qualityStatus','ACCEPTED','location','QA-RECEPCION',
      'lotNumber','QA-'||i.line_number::text
    ) order by i.line_number),'[]'::jsonb)
    into v_lines
    from erp_supply.order_items i
    where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false';
    if jsonb_array_length(v_lines)=0 then raise exception 'Recepción QA sin líneas'; end if;
    v_result:=public.erp_x_save_receipt(p_order_id,jsonb_build_object(
      'receiptNumber','REC-QA-'||substr(replace(p_case_id::text,'-',''),1,12),
      'requestId','REL-REC-'||p_case_id::text,'status','CONFORMING',
      'supplierName','PROVEEDOR SINTÉTICO QA','lines',v_lines,
      'metadata',jsonb_build_object('qaSynthetic',true,'caseId',p_case_id)
    ));
    if coalesce((v_result->>'complete')::boolean,false)=false then raise exception 'La recepción QA no quedó completa'; end if;
    return jsonb_build_object('advanced',false,'operation','RECEIPT','result',v_result);

  elsif v_step='RECEPCION_PEDIDO' then
    select p.id into v_pick
    from erp_supply.profiles p join erp_supply.profile_roles pr on pr.profile_id=p.id
    where p.organization_id=v_order.organization_id and p.active and pr.role_code='aux_logistica'
    order by p.created_at,p.id limit 1;
    if v_pick is null then raise exception 'CONFIG_QA: no existe un auxiliar de logística activo para probar asignación'; end if;
    if v_order.requires_cut then
      select p.id into v_cut_profile
      from erp_supply.profiles p join erp_supply.profile_roles pr on pr.profile_id=p.id
      where p.organization_id=v_order.organization_id and p.active and pr.role_code='auxiliar_corte'
      order by p.created_at,p.id limit 1;
      if v_cut_profile is null then raise exception 'CONFIG_QA: no existe un auxiliar de corte activo para probar asignación'; end if;
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'orderItemId',i.id,'sku',i.sku,'reference',i.reference,'description',i.description,
      'quantity',i.quantity,'unit',i.unit,'requiresCut',i.requires_cut,
      'requestedCutLength',i.requested_cut_length,
      'metadata',jsonb_build_object('qaSynthetic',true)
    ) order by i.line_number),'[]'::jsonb)
    into v_lines from erp_supply.order_items i
    where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false';
    v_result:=public.erp_x_confirm_order_reception(p_order_id,jsonb_build_object(
      'sourceMode','CORRECT','pickingProfileId',v_pick,'cutProfileId',v_cut_profile,'lines',v_lines,
      'readerVersion','QA-10.25.3'
    ));
    return jsonb_build_object('advanced',true,'operation','RECEPTION_CONFIRM_ASSIGN','result',v_result);

  elsif v_step='ALISTAMIENTO' then
    -- Corte es paralelo a Alistamiento: si el pedido lo exige, el Robot ejecuta
    -- Corte real completo (inicio/pausa/reanudación/evidencia/cierre) y luego
    -- la recogida real antes de confirmar Alistamiento.
    if v_order.requires_cut then
      for v_group in
        select distinct r.group_key
        from erp_supply.cut_requirements r
        where r.order_id=p_order_id and r.process_status<>'READY'
          and greatest(r.total_length-coalesce(r.length_completed,0),0)>0.0001
        order by r.group_key
      loop
        v_group_count:=v_group_count+1;
        perform public.erp_x_cutting_start(v_group);
        select e.id into v_exec from erp_supply.cut_executions e
        where e.organization_id=v_order.organization_id and e.group_key=v_group
          and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
        order by e.started_at desc,e.id desc limit 1;
        if v_exec is null then raise exception 'Corte QA no creó ejecución para %',v_group; end if;
        if exists(select 1 from erp_supply.cut_executions where id=v_exec and status='IN_PROGRESS') then
          perform public.erp_x_cutting_pause(v_exec,'QA: prueba pausa de Corte');
          perform public.erp_x_cutting_resume(v_exec);
        end if;
        perform public.erp_x_sandbox_execute_cut_group(v_group,jsonb_build_object('reelLength',500,'scrapLength',1));
        perform public.erp_x_sandbox_cutting_evidence(v_exec,jsonb_build_object('fileName','qa-corte.jpg','mimeType','image/jpeg','sizeBytes',128));
        perform public.erp_x_cutting_finalize(v_exec);
      end loop;
      if v_group_count=0 and exists(select 1 from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY') then
        raise exception 'El pedido exige Corte pero no fue posible ejecutar sus requerimientos';
      end if;
      select coalesce(jsonb_agg(r.id order by r.created_at),'[]'::jsonb) into v_pickups
      from erp_supply.cut_requirements r
      where r.order_id=p_order_id and r.process_status='READY' and r.collection_status='PENDING';
      if jsonb_array_length(v_pickups)>0 then
        perform public.erp_x_confirm_cut_pickup(p_order_id,v_pickups);
      end if;
      if exists(select 1 from erp_supply.cut_requirements r where r.order_id=p_order_id and (r.process_status<>'READY' or r.collection_status<>'COLLECTED')) then
        raise exception 'Corte QA no quedó READY + COLLECTED antes de Alistamiento';
      end if;
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'orderItemId',i.id,'result','FOUND','novelty',null,'origins','[]'::jsonb
    ) order by i.line_number),'[]'::jsonb)
    into v_items from erp_supply.order_items i
    where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'
      and i.item_status not in('FULFILLED','CANCELLED');
    if jsonb_array_length(v_items)=0 then raise exception 'Alistamiento QA sin líneas pendientes'; end if;
    -- En Sandbox el wrapper de confirmación evita consumir inventario real.
    v_result:=public.erp_x_confirm_picking_round(p_order_id,jsonb_build_object('items',v_items,'qaSynthetic',true));
    return jsonb_build_object('advanced',true,'operation',case when v_order.requires_cut then 'CUTTING_PICKUP_AND_PICKING_FULL' else 'PICKING_FULL' end,'cutGroups',v_group_count,'result',v_result);

  elsif v_step='CORTE' then
    for v_group in
      select distinct r.group_key
      from erp_supply.cut_requirements r
      where r.order_id=p_order_id and r.process_status<>'READY'
        and greatest(r.total_length-coalesce(r.length_completed,0),0)>0.0001
      order by r.group_key
    loop
      v_group_count:=v_group_count+1;
      perform public.erp_x_cutting_start(v_group);
      select e.id into v_exec from erp_supply.cut_executions e
      where e.organization_id=v_order.organization_id and e.group_key=v_group
        and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
      order by e.started_at desc,e.id desc limit 1;
      if v_exec is null then raise exception 'Corte QA no creó ejecución para %',v_group; end if;
      if exists(select 1 from erp_supply.cut_executions where id=v_exec and status='IN_PROGRESS') then
        perform public.erp_x_cutting_pause(v_exec,'QA: prueba pausa de Corte');
        perform public.erp_x_cutting_resume(v_exec);
      end if;
      perform public.erp_x_sandbox_execute_cut_group(v_group,jsonb_build_object('reelLength',500,'scrapLength',1));
      perform public.erp_x_sandbox_cutting_evidence(v_exec,jsonb_build_object('fileName','qa-corte.jpg','mimeType','image/jpeg','sizeBytes',128));
      perform public.erp_x_cutting_finalize(v_exec);
    end loop;
    if v_group_count=0 and v_order.requires_cut then raise exception 'El pedido exige Corte pero no tiene requerimientos pendientes'; end if;
    return jsonb_build_object('advanced',false,'operation','CUTTING_FULL','groups',v_group_count);

  elsif v_step in('FACTURACION','CAJA_FACTURACION') then
    if upper(v_order.order_type_code)='PVP' then
      if v_step<>'FACTURACION' then raise exception 'PVP llegó indebidamente a CAJA_FACTURACION'; end if;
      v_file:=erp_supply.qa_synthetic_file(p_order_id,v_task.id,'PVP_ANNEX',p_actor,'anexo-pvp-qa.pdf');
      return jsonb_build_object('advanced',false,'operation','PVP_ANNEX','fileId',v_file);
    else
      v_file:=erp_supply.qa_synthetic_file(p_order_id,v_task.id,'INVOICE',p_actor,'factura-qa.pdf');
      v_result:=public.erp_x_save_invoice(p_order_id,jsonb_build_object(
        'driveFileRecordId',v_file,'invoiceNumber','FAC-QA-'||substr(replace(p_case_id::text,'-',''),1,12),
        'invoiceDate',current_date::text,'amount',100000,'currency','COP',
        'metadata',jsonb_build_object('qaSynthetic',true,'caseId',p_case_id)
      ));
      return jsonb_build_object('advanced',false,'operation','INVOICE','fileId',v_file,'result',v_result);
    end if;

  elsif v_step in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
    v_result:=public.erp_x_shipping_save_guide(p_order_id,jsonb_build_object(
      'trackingNumber','GUIA-QA-'||substr(replace(p_case_id::text,'-',''),1,10),
      'carrier','TRANSPORTADORA QA'
    ));
    -- El flujo real exige destino confirmado antes de pasar a Cierre.
    v_result:=public.erp_x_shipping_save_location(p_order_id,jsonb_build_object(
      'placeLabel','Punto sintético QA','municipality','Tuluá','department','Valle del Cauca',
      'address','Zona QA · sin despacho físico','latitude',4.08466,'longitude',-76.19536,
      'accuracy',1,'source','QA_SYNTHETIC'
    ));
    v_result:=public.erp_x_shipping_send_to_closure(p_order_id,jsonb_build_object('detail','Despacho QA enviado a cierre'));
    return jsonb_build_object('advanced',true,'operation','SHIPPING_GUIDE_TO_CLOSURE','result',v_result);

  elsif v_step='CLOSURE' then
    v_file:=erp_supply.qa_synthetic_file(p_order_id,v_task.id,'DELIVERY_EVIDENCE',p_actor,'foto-entrega-qa.jpg');
    perform public.erp_x_shipping_register_evidence(p_order_id,jsonb_build_object('fileId',v_file));
    v_result:=public.erp_x_shipping_finalize(p_order_id,jsonb_build_object('receivedBy','CLIENTE QA'));
    return jsonb_build_object('advanced',true,'operation','DELIVERY_EVIDENCE_FINALIZE','fileId',v_file,'result',v_result);
  end if;

  return jsonb_build_object('advanced',false,'operation','GENERIC');
end;
$$;
revoke all on function erp_supply.qa_execute_step_domain(uuid,text,uuid,uuid) from public;

-- ---------------------------------------------------------------------------
-- 5. Una invocación = una etapa para ROUTE_CANONICAL/JOURNEY_FULL.
--    Los demás casos continúan usando el motor profundo existente.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_execute_release_slice(p_case_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_case erp_supply.qa_deep_cases%rowtype;v_state erp_supply.qa_release_journey_state%rowtype;
  v_spec jsonb;v_seed jsonb;v_order uuid;v_order_number text;v_step text;v_next text;
  v_expected jsonb:='[]'::jsonb;v_actual jsonb:='[]'::jsonb;v_sequence jsonb:='[]'::jsonb;
  v_guard int:=0;v_domain jsonb;v_advanced boolean:=false;v_req uuid;v_issue jsonb;v_issue_id uuid;
  v_cleanup_ok boolean:=true;v_cleanup_error text;v_ok boolean:=false;v_started timestamptz:=clock_timestamp();v_error_state text;v_error_message text;
begin
  select c.* into v_case
  from erp_supply.qa_deep_cases c join erp_supply.qa_runs r on r.id=c.qa_run_id
  where c.id=p_case_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT'
  for update of c;
  if not found then raise exception 'Caso QA release no disponible'; end if;
  if v_case.family not in('ROUTE_CANONICAL','JOURNEY_FULL') then
    return public.erp_x_qa_robot_execute_deep_case(p_case_id);
  end if;
  if v_case.status in('PASSED','FAILED','SKIPPED') then
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,'status',v_case.status,'result',v_case.result,'errorMessage',v_case.error_message);
  end if;

  update erp_supply.qa_deep_cases
  set last_attempt_at=now(),attempt_count=coalesce(attempt_count,0)+1,
      started_at=coalesce(started_at,now()),error_message=null,error_sqlstate=null
  where id=v_case.id;

  select * into v_state from erp_supply.qa_release_journey_state where case_id=v_case.id for update;
  if not found then
    v_spec:=v_case.specification;
    v_seed:=public.erp_x_qa_robot_seed_order(v_case.qa_run_id,v_spec||jsonb_build_object('scenarioKey',v_case.case_key));
    v_order:=erp_supply.safe_uuid(v_seed->>'orderId');v_order_number:=v_seed->>'orderNumber';
    if v_order is null then raise exception 'No fue posible crear el pedido del recorrido'; end if;
    select current_step_code into v_step from erp_supply.orders where id=v_order;
    v_expected:=jsonb_build_array(v_step);v_actual:=jsonb_build_array(v_step);v_guard:=0;v_next:=v_step;
    while v_next<>'CLOSED' and v_guard<20 loop
      v_next:=erp_supply.next_step(v_next,upper(v_spec->>'orderType'),upper(v_spec->>'paymentCondition'),upper(v_spec->>'deliveryRoute'),
        coalesce(erp_supply.safe_boolean(v_spec->>'requiresCut'),false),coalesce(erp_supply.safe_boolean(v_spec->>'requiresPurchase'),false));
      v_expected:=v_expected||jsonb_build_array(v_next);v_guard:=v_guard+1;
    end loop;
    if v_guard>=20 and v_next<>'CLOSED' then raise exception 'La ruta esperada excedió 20 etapas'; end if;
    insert into erp_supply.qa_release_journey_state(case_id,qa_run_id,order_id,order_number,expected_path,actual_path,action_sequence)
    values(v_case.id,v_case.qa_run_id,v_order,v_order_number,v_expected,v_actual,'[]'::jsonb)
    returning * into v_state;
  end if;

  v_order:=v_state.order_id;v_spec:=v_case.specification;
  if v_order is null or not exists(select 1 from erp_supply.orders where id=v_order) then
    raise exception 'El pedido persistente del recorrido QA ya no existe';
  end if;

  begin
    select current_step_code into v_step from erp_supply.orders where id=v_order for update;
    if v_step='CLOSED' then
      v_ok:=v_state.actual_path=v_state.expected_path;
    else
      perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA release 10.25.3 START'),v_actor,true,null,
        'REL253-START-'||v_case.id::text||'-'||v_state.steps_executed::text);
      v_sequence:=v_state.action_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','START'));

      if v_case.family='JOURNEY_FULL' then
        v_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','NOTE','title','Nota QA release','detail','Validación secuencial completa 10.25.3','sourceCode','QA_RELEASE'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','NOTE'));

        v_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','NOVELTY','title','Novedad QA release','detail','Novedad creada y resuelta','sourceCode','QA_RELEASE'));
        v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}');
        if v_issue_id is null then raise exception 'No fue posible crear NOVELTY en %',v_step; end if;
        perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Resuelta por QA release','resolutionCode','RESOLVED'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','NOVELTY_RESOLVED'));

        v_issue:=public.erp_x_create_order_issue(v_order,jsonb_build_object('type','REPORT','title','Reporte QA release','detail','Reporte creado y resuelto','targetRole','jefe_logistica','sourceCode','QA_RELEASE'));
        v_issue_id:=erp_supply.safe_uuid(v_issue#>>'{issue,id}');
        if v_issue_id is null then raise exception 'No fue posible crear REPORT en %',v_step; end if;
        perform public.erp_x_resolve_order_issue(v_issue_id,jsonb_build_object('resolution','Reporte resuelto por QA release','resolutionCode','RESOLVED'));
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','REPORT_RESOLVED'));

        begin perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA reactivar'),v_actor,true,null,'REL253-RESTART-'||v_case.id::text||'-'||v_state.steps_executed::text); exception when others then null; end;
        perform erp_supply.execute_action_internal(v_order,'WAIT',jsonb_build_object('reason','QA journey espera'),v_actor,true,null,'REL253-WAIT-'||v_case.id::text||'-'||v_state.steps_executed::text);
        perform erp_supply.execute_action_internal(v_order,'RESUME',jsonb_build_object('detail','QA journey reanudar'),v_actor,true,null,'REL253-RESUME-'||v_case.id::text||'-'||v_state.steps_executed::text);
        v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','WAIT_RESUME'));

        if not v_state.first_step_done then
          perform public.erp_x_execute_action(v_order,'REQUEST_APPROVAL',jsonb_build_object('requestType','PRIORITY','priority','URGENT','reason','QA journey prioridad','assignedRole','gerencia'),null,'REL253-PRIORITY-'||v_case.id::text);
          select id into v_req from erp_supply.approval_requests where order_id=v_order and request_type='PRIORITY' and status='PENDING' order by created_at desc limit 1;
          if v_req is null then raise exception 'No se creó la aprobación PRIORITY del recorrido'; end if;
          perform public.erp_x_decide_approval(v_req,'APPROVED','QA release aprueba prioridad');
          v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action','PRIORITY_APPROVED'));
        end if;
      end if;

      -- El RPC específico realiza la operación real de negocio de la etapa.
      begin perform erp_supply.execute_action_internal(v_order,'START',jsonb_build_object('detail','QA preparar operación'),v_actor,true,null,'REL253-START2-'||v_case.id::text||'-'||v_state.steps_executed::text); exception when others then null; end;
      v_domain:=erp_supply.qa_execute_step_domain(v_order,v_step,v_actor,v_case.id);
      v_advanced:=coalesce((v_domain->>'advanced')::boolean,false);
      v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_step,'action',coalesce(v_domain->>'operation','DOMAIN')));

      if not v_advanced then
        perform erp_supply.execute_action_internal(v_order,'COMPLETE',jsonb_build_object('detail','QA release completar etapa','qaDomain',v_domain),v_actor,true,null,
          'REL253-COMPLETE-'||v_case.id::text||'-'||v_state.steps_executed::text);
      end if;

      select current_step_code into v_next from erp_supply.orders where id=v_order;
      if v_next=v_step then raise exception 'La etapa % no avanzó después de su operación real',v_step; end if;
      v_actual:=v_state.actual_path||jsonb_build_array(v_next);
      v_sequence:=v_sequence||jsonb_build_array(jsonb_build_object('step',v_next,'action','ADVANCED'));

      update erp_supply.qa_release_journey_state
      set actual_path=v_actual,action_sequence=v_sequence,steps_executed=steps_executed+1,
          first_step_done=true,updated_at=now()
      where case_id=v_case.id returning * into v_state;

      if v_next='CLOSED' then v_ok:=v_actual=v_state.expected_path; end if;
    end if;

    if v_ok or (select current_step_code='CLOSED' from erp_supply.orders where id=v_order) then
      if not v_ok then v_ok:=v_state.actual_path=v_state.expected_path; end if;
      begin
        perform public.erp_x_sandbox_delete(v_order);
      exception when others then
        v_cleanup_ok:=false;v_cleanup_error:=sqlstate||' · '||sqlerrm;
      end;
      update erp_supply.qa_release_journey_state
      set status=case when v_ok and v_cleanup_ok then 'PASSED' else 'FAILED' end,completed_at=now(),updated_at=now(),
          last_error=case when not v_ok then 'La ruta real no coincide con la esperada' when not v_cleanup_ok then v_cleanup_error else null end
      where case_id=v_case.id returning * into v_state;
      update erp_supply.qa_deep_cases
      set status=case when v_ok and v_cleanup_ok then 'PASSED' else 'FAILED' end,
          result=jsonb_build_object('family',v_case.family,'orderNumber',v_state.order_number,'expectedPath',v_state.expected_path,'actualPath',v_state.actual_path,
            'stepsExecuted',v_state.steps_executed,'actionCount',jsonb_array_length(v_state.action_sequence),'sequence',v_state.action_sequence,'cleanupVerified',v_cleanup_ok),
          error_sqlstate=case when v_ok and v_cleanup_ok then null else 'QA_ASSERT' end,
          error_message=case when not v_ok then 'La ruta real no coincide con la esperada' when not v_cleanup_ok then 'Limpieza QA: '||v_cleanup_error else null end,
          duration_ms=greatest(0,round(extract(epoch from(clock_timestamp()-started_at))*1000)::int),
          completed_at=now(),cleanup_verified=v_cleanup_ok
      where id=v_case.id;
      return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,
        'status',case when v_ok and v_cleanup_ok then 'PASSED' else 'FAILED' end,'completed',true,'cleanupVerified',v_cleanup_ok,'version','10.25.3');
    end if;

    -- No se marca RUNNING: queda PENDING de forma intencional para la siguiente etapa.
    update erp_supply.qa_deep_cases set status='PENDING',completed_at=null where id=v_case.id;
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,'status','PENDING',
      'completed',false,'currentStep',v_next,'stepsExecuted',v_state.steps_executed,'version','10.25.3');

  exception when others then
    -- Captura el error PRIMARIO antes de intentar limpiar; una falla de limpieza
    -- nunca debe sobrescribir el diagnóstico funcional original.
    v_error_state:=sqlstate;v_error_message:=sqlerrm;
    begin
      if v_order is not null and exists(select 1 from erp_supply.orders where id=v_order) then perform public.erp_x_sandbox_delete(v_order); end if;
    exception when others then v_cleanup_ok:=false;v_cleanup_error:=sqlstate||' · '||sqlerrm; end;
    update erp_supply.qa_release_journey_state
      set status='FAILED',completed_at=now(),updated_at=now(),last_error=v_error_state||' · '||v_error_message
      where case_id=v_case.id;
    update erp_supply.qa_deep_cases
      set status='FAILED',error_sqlstate=v_error_state,error_message=v_error_message,
          result=jsonb_build_object('family',v_case.family,'failedStep',v_step,'cleanupVerified',v_cleanup_ok,'cleanupError',v_cleanup_error),
          duration_ms=greatest(0,round(extract(epoch from(clock_timestamp()-started_at))*1000)::int),completed_at=now(),cleanup_verified=v_cleanup_ok
      where id=v_case.id;
    return jsonb_build_object('caseId',v_case.id,'caseKey',v_case.case_key,'family',v_case.family,'status','FAILED',
      'errorSqlstate',v_error_state,'errorMessage',v_error_message,'failedStep',v_step,'cleanupVerified',v_cleanup_ok,'version','10.25.3');
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Progreso optimizado y PRIORIZADO: rutas -> journeys -> casos profundos.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_deep_progress(p_run_id uuid,p_limit integer default 24)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_limit int:=least(greatest(coalesce(p_limit,24),1),60);
  v_total int;v_pending int;v_running int;v_passed int;v_failed int;v_transport_attempts int;v_timeout_attempts int;v_transport_cases int;v_timeout_cases int;
  v_routes_total int;v_routes_pass int;v_routes_fail int;v_routes_pending int;
  v_journeys_total int;v_journeys_pass int;v_journeys_fail int;v_journeys_pending int;v_attempts bigint;
begin
  if not exists(select 1 from erp_supply.qa_runs r where r.id=p_run_id and r.organization_id=v_org and r.run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;

  select
    count(*)::int,
    count(*) filter(where status='PENDING')::int,
    count(*) filter(where status='RUNNING')::int,
    count(*) filter(where status='PASSED')::int,
    count(*) filter(where status='FAILED')::int,
    coalesce(sum(transport_failures),0)::int,
    coalesce(sum(timeout_failures),0)::int,
    count(*) filter(where transport_failures>0)::int,
    count(*) filter(where timeout_failures>0)::int,
    count(*) filter(where family='ROUTE_CANONICAL')::int,
    count(*) filter(where family='ROUTE_CANONICAL' and status='PASSED')::int,
    count(*) filter(where family='ROUTE_CANONICAL' and status='FAILED')::int,
    count(*) filter(where family='ROUTE_CANONICAL' and status in('PENDING','RUNNING'))::int,
    count(*) filter(where family='JOURNEY_FULL')::int,
    count(*) filter(where family='JOURNEY_FULL' and status='PASSED')::int,
    count(*) filter(where family='JOURNEY_FULL' and status='FAILED')::int,
    count(*) filter(where family='JOURNEY_FULL' and status in('PENDING','RUNNING'))::int,
    coalesce(sum(attempt_count),0)::bigint
  into v_total,v_pending,v_running,v_passed,v_failed,v_transport_attempts,v_timeout_attempts,v_transport_cases,v_timeout_cases,
       v_routes_total,v_routes_pass,v_routes_fail,v_routes_pending,v_journeys_total,v_journeys_pass,v_journeys_fail,v_journeys_pending,v_attempts
  from erp_supply.qa_deep_cases where qa_run_id=p_run_id;

  return jsonb_build_object(
    'runId',p_run_id,'total',v_total,'planned',v_total,'executed',v_passed+v_failed,'pending',v_pending,'running',v_running,'passed',v_passed,'failed',v_failed,
    'transportFailures',v_transport_attempts,'timeoutFailures',v_timeout_attempts,
    'transportCases',v_transport_cases,'timeoutCases',v_timeout_cases,'stageSlices',v_attempts,
    'done',v_pending=0 and v_running=0,
    'coveragePercent',case when v_total=0 then 0 else round(((v_passed+v_failed)::numeric/v_total::numeric)*100,2) end,
    'routes',jsonb_build_object('planned',v_routes_total,'executed',v_routes_pass+v_routes_fail,'passed',v_routes_pass,'failed',v_routes_fail,'pending',v_routes_pending),
    'journeys',jsonb_build_object('planned',v_journeys_total,'executed',v_journeys_pass+v_journeys_fail,'passed',v_journeys_pass,'failed',v_journeys_fail,'pending',v_journeys_pending),
    'byFamily',(select coalesce(jsonb_object_agg(x.family,jsonb_build_object('planned',x.total,'executed',x.executed,'passed',x.passed,'failed',x.failed,'pending',x.pending,'transportCases',x.transport_cases,'timeoutCases',x.timeout_cases)),'{}'::jsonb)
      from(select family,count(*)::int total,count(*) filter(where status in('PASSED','FAILED'))::int executed,count(*) filter(where status='PASSED')::int passed,
        count(*) filter(where status='FAILED')::int failed,count(*) filter(where status in('PENDING','RUNNING'))::int pending,
        count(*) filter(where transport_failures>0)::int transport_cases,count(*) filter(where timeout_failures>0)::int timeout_cases
        from erp_supply.qa_deep_cases where qa_run_id=p_run_id group by family order by family)x),
    'pendingItems',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'family',family,'caseKey',case_key) order by priority,case_key),'[]'::jsonb)
      from(select id,family,case_key,case family when 'ROUTE_CANONICAL' then 1 when 'JOURNEY_FULL' then 2 else 3 end priority
        from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='PENDING'
        order by priority,case_key limit v_limit)x),
    'pendingIds',(select coalesce(jsonb_agg(id order by priority,case_key),'[]'::jsonb)
      from(select id,family,case_key,case family when 'ROUTE_CANONICAL' then 1 when 'JOURNEY_FULL' then 2 else 3 end priority
        from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='PENDING'
        order by priority,case_key limit v_limit)x),
    'failures',(select coalesce(jsonb_agg(jsonb_build_object('caseId',id,'caseKey',case_key,'family',family,'sqlstate',error_sqlstate,'error',error_message,'transportFailures',transport_failures,'timeoutFailures',timeout_failures,'result',result) order by completed_at desc),'[]'::jsonb)
      from(select * from erp_supply.qa_deep_cases where qa_run_id=p_run_id and status='FAILED' order by completed_at desc nulls last limit 50)f),
    'version','10.25.3'
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 7. Integridad de liberación: corrige contaminación de ejecuciones TEST.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_release_flow_integrity()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_base jsonb:=public.erp_x_flow_integrity();v_real_cut bigint:=0;v_counts jsonb;v_ok boolean;
begin
  perform erp_supply.require_sandbox_admin();
  select count(*) into v_real_cut
  from erp_supply.cut_executions e
  where e.organization_id=erp_supply.current_org_id() and e.status='COMPLETED' and e.evidence_file_id is null
    and not coalesce((e.metadata->>'isTest')::boolean,false);
  v_counts:=jsonb_set(coalesce(v_base->'counts','{}'::jsonb),'{completedCutWithoutEvidence}',to_jsonb(v_real_cut),true);
  v_ok:=coalesce((v_counts->>'fulfilledCutWithoutCollection')::bigint,0)=0
    and v_real_cut=0
    and coalesce((v_counts->>'automaticReceiptWithoutMovement')::bigint,0)=0
    and coalesce((v_counts->>'invalidReceiptDistribution')::bigint,0)=0
    and coalesce((v_counts->>'activeOrderWithoutTask')::bigint,0)=0
    and coalesce((v_counts->>'duplicateOpenSessionPerTask')::bigint,0)=0
    and coalesce((v_counts->>'receiptLotWithoutOfficialMaterial')::bigint,0)=0;
  return jsonb_build_object('success',v_ok,'counts',v_counts,'baseVersion',v_base->>'version','version','10.25.3','checkedAt',now());
end;
$$;

create or replace function public.erp_x_qa_release_health(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();v_row record;v_checks jsonb:='[]'::jsonb;v_ok boolean:=true;
  v_route_ok boolean;v_controls_ok boolean;v_branch_ok boolean;v_real_cut bigint;
begin
  perform erp_supply.require_sandbox_admin();
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;

  select count(*)=336 and count(*) filter(where status='PASSED')=336 and count(*) filter(where status='FAILED')=0
    into v_route_ok from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL';
  select exists(select 1 from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-CONTROLS-10' and status='PASSED') into v_controls_ok;
  select exists(select 1 from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-BRANCH-SUITE' and status='PASSED') into v_branch_ok;
  select count(*) into v_real_cut from erp_supply.cut_executions e where e.organization_id=v_org and e.status='COMPLETED' and e.evidence_file_id is null and not coalesce((e.metadata->>'isTest')::boolean,false);

  for v_row in select * from public.erp_x_health_check() loop
    -- Los dos gates QA históricos son reemplazados por la corrida de release actual.
    if v_row.check_name='Última matriz de 336 rutas aprobada' then
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('section',v_row.section,'checkName','336 rutas de release actual aprobadas','ok',v_route_ok,'detail',case when v_route_ok then '336/336 rutas release aprobadas' else 'La corrida release actual todavía no tiene 336/336 rutas' end));
      v_ok:=v_ok and v_route_ok;
    elsif v_row.check_name='Últimos 10 controles empresariales aprobados' then
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('section',v_row.section,'checkName','10 controles empresariales de release actual','ok',v_controls_ok,'detail',case when v_controls_ok then '10/10 controles de la corrida actual' else 'Los controles empresariales de la corrida actual no están aprobados' end));
      v_ok:=v_ok and v_controls_ok;
    elsif v_row.check_name='Cortes cerrados conservan evidencia' then
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('section',v_row.section,'checkName',v_row.check_name,'ok',v_real_cut=0,'detail',v_real_cut||' ejecución(es) PRODUCTIVAS COMPLETED sin evidencia'));
      v_ok:=v_ok and v_real_cut=0;
    else
      v_checks:=v_checks||jsonb_build_array(jsonb_build_object('section',v_row.section,'checkName',v_row.check_name,'ok',v_row.ok,'detail',v_row.detail));
      v_ok:=v_ok and coalesce(v_row.ok,false);
    end if;
  end loop;
  v_checks:=v_checks||jsonb_build_array(jsonb_build_object('section','09_QA','checkName','Ramas críticas release actual','ok',v_branch_ok,'detail',case when v_branch_ok then '10/10 ramas críticas' else 'Ramas críticas pendientes/fallidas' end));
  v_ok:=v_ok and v_branch_ok;
  return jsonb_build_object('success',v_ok,'checks',v_checks,'version','10.25.3','checkedAt',now());
end;
$$;


-- ---------------------------------------------------------------------------
-- 8. Versionado/reanudación: V10.25.3 nunca reanuda una corrida vieja que ya
--    acumuló transport/timeouts del orquestador anterior.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_create_run(p_options jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();
  v_org uuid:=erp_supply.current_org_id();
  v_run erp_supply.qa_runs%rowtype;
begin
  insert into erp_supply.qa_runs(organization_id,run_type,status,requested_by,total_scenarios,summary)
  values(v_org,'TOTAL_ROBOT','RUNNING',v_actor,0,jsonb_build_object(
    'qaRobotVersion','10.25.3','options',coalesce(p_options,'{}'::jsonb),'productionIsolation',true,
    'startedFrom','SUPER_ADMIN_PORTAL','executionModel','STAGE_SLICED_LOW_CONCURRENCY'
  )) returning * into v_run;
  return jsonb_build_object('runId',v_run.id,'status',v_run.status,'startedAt',v_run.started_at,'version','10.25.3');
end;
$$;

create or replace function public.erp_x_qa_robot_latest_resumable()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_run uuid;v_progress jsonb;
begin
  select r.id into v_run
  from erp_supply.qa_runs r
  where r.organization_id=v_org and r.run_type='TOTAL_ROBOT'
    and coalesce(r.summary->>'qaRobotVersion','')='10.25.3'
    and exists(select 1 from erp_supply.qa_deep_cases c where c.qa_run_id=r.id and c.status in('PENDING','RUNNING'))
  order by r.started_at desc limit 1;
  if v_run is null then return jsonb_build_object('available',false,'version','10.25.3'); end if;
  v_progress:=public.erp_x_qa_robot_deep_progress(v_run,1);
  return jsonb_build_object('available',true,'runId',v_run,'progress',v_progress,'version','10.25.3');
end;
$$;

create or replace function public.erp_x_qa_robot_plan()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid:=erp_supply.require_sandbox_admin();v_steps int;begin
  select count(*) into v_steps from erp_supply.workflow_steps where active and not terminal;
  return jsonb_build_object(
    'version','10.25.3','strategy','RELEASE_CERTIFICATION_STAGE_SLICED_ZERO_SKIPS','productionIsolation',true,
    'domain',jsonb_build_object('routingCombinations',336,'fullSequentialJourneys',336,'enterpriseControls',10,'integrityGates',2,'branchChecks',10,
      'activeSteps',v_steps,'releaseRule','planned = executed; pending = 0; timeout = 0; transport = 0; all gates green',
      'journeyExecution','ONE_REAL_OPERATIONAL_STAGE_PER_RPC'),
    'orchestration',jsonb_build_object('routeConcurrency',2,'journeyConcurrency',2,'deepConcurrency',3,'transportRetries',3,'resume',true),
    'ui',jsonb_build_object('modules','ALL_SUPER_ADMIN_MODULES','mustOpenSandboxOrders',true,'mustExecutePrimaryAction',true,'consoleAndRpcErrors',true),
    'responsive',jsonb_build_object('widths',jsonb_build_array(360,390,424,768,960,1440),'expectedChecks',54),
    'certificate',jsonb_build_object('required',true,'passState','CERTIFIED'),
    'capacity',jsonb_build_object('engine','k6','separateReleaseGate',true,'profiles',jsonb_build_array('SMOKE','NORMAL','BUSY','PEAK','SPIKE','SOAK','BREAKPOINT')),
    'requestedBy',v_actor
  );
end;
$$;


-- ---------------------------------------------------------------------------
-- 9. Certificado/cierre V10.25.3: conserva gates estrictos con versionado actual.
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_qa_robot_release_certificate(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();
  v_routes_total int;v_routes_pass int;v_routes_fail int;v_routes_pending int;
  v_journeys_total int;v_journeys_pass int;v_journeys_fail int;v_journeys_pending int;
  v_deep_total int;v_deep_pass int;v_deep_fail int;v_deep_pending int;v_transport int;v_timeout int;
  v_ui_expected int;v_ui_pass int;v_ui_fail int;v_resp_pass int;v_resp_fail int;v_sandbox_pass int;v_sandbox_fail int;
  v_health_pass int;v_health_fail int;v_contract_fail int;v_domain_fail int;v_controls_pass int;v_branch_pass int;v_cleanup_remaining int;v_certified boolean;v_gates jsonb;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;

  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING'))
  into v_routes_total,v_routes_pass,v_routes_fail,v_routes_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='ROUTE_CANONICAL';
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING'))
  into v_journeys_total,v_journeys_pass,v_journeys_fail,v_journeys_pending from erp_supply.qa_deep_cases where qa_run_id=p_run_id and family='JOURNEY_FULL';
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING')),coalesce(sum(transport_failures),0)::int,coalesce(sum(timeout_failures),0)::int
  into v_deep_total,v_deep_pass,v_deep_fail,v_deep_pending,v_transport,v_timeout from erp_supply.qa_deep_cases where qa_run_id=p_run_id;

  select count(*) into v_ui_expected from erp_supply.modules m join erp_supply.role_module_permissions p on p.module_code=m.code and p.role_code='super_admin' where m.active and p.can_read;
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_ui_pass,v_ui_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key like 'UI-MODULE-%';
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_resp_pass,v_resp_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key like 'RESP-%';
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_sandbox_pass,v_sandbox_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and (check_key like 'SANDBOX-STEP-%' or check_key='SANDBOX-CUTTING-PARALLEL');
  select count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED') into v_health_pass,v_health_fail
    from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key in('HEALTH-GLOBAL','HEALTH-WORKFORCE','HEALTH-QUEUES','HEALTH-RESERVATIONS','HEALTH-RUNTIME','INTEGRITY-STRUCTURAL','INTEGRITY-FLOW');
  select count(*) into v_contract_fail from erp_supply.qa_robot_checks where qa_run_id=p_run_id and layer='CONTRACT' and status='FAILED';
  select count(*) into v_domain_fail from erp_supply.qa_robot_checks where qa_run_id=p_run_id and layer='DOMAIN' and status='FAILED';
  select count(*) into v_controls_pass from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-CONTROLS-10' and status='PASSED';
  select count(*) into v_branch_pass from erp_supply.qa_robot_checks where qa_run_id=p_run_id and check_key='DOMAIN-BRANCH-SUITE' and status='PASSED';
  select count(*) into v_cleanup_remaining from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT';

  v_gates:=jsonb_build_object(
    'routing',jsonb_build_object('expected',336,'planned',v_routes_total,'executed',v_routes_pass+v_routes_fail,'passed',v_routes_pass,'failed',v_routes_fail,'pending',v_routes_pending,'ok',v_routes_total=336 and v_routes_pass=336 and v_routes_fail=0 and v_routes_pending=0),
    'journeys',jsonb_build_object('expected',336,'planned',v_journeys_total,'executed',v_journeys_pass+v_journeys_fail,'passed',v_journeys_pass,'failed',v_journeys_fail,'pending',v_journeys_pending,'ok',v_journeys_total=336 and v_journeys_pass=336 and v_journeys_fail=0 and v_journeys_pending=0),
    'extreme',jsonb_build_object('planned',v_deep_total,'executed',v_deep_pass+v_deep_fail,'passed',v_deep_pass,'failed',v_deep_fail,'pending',v_deep_pending,'transport',v_transport,'timeouts',v_timeout,'ok',v_deep_total>672 and v_deep_fail=0 and v_deep_pending=0 and v_transport=0 and v_timeout=0),
    'interface',jsonb_build_object('expectedModules',v_ui_expected,'passedModules',v_ui_pass,'failedModules',v_ui_fail,'ok',v_ui_pass=v_ui_expected and v_ui_fail=0),
    'responsive',jsonb_build_object('expected',54,'passed',v_resp_pass,'failed',v_resp_fail,'ok',v_resp_pass=54 and v_resp_fail=0),
    'sandboxUi',jsonb_build_object('expected',14,'passed',v_sandbox_pass,'failed',v_sandbox_fail,'ok',v_sandbox_pass=14 and v_sandbox_fail=0),
    'integrity',jsonb_build_object('expected',7,'passed',v_health_pass,'failed',v_health_fail,'ok',v_health_pass=7 and v_health_fail=0),
    'domainChecks',jsonb_build_object('controlsPassed',v_controls_pass=1,'branchSuitePassed',v_branch_pass=1,'failed',v_domain_fail,'ok',v_controls_pass=1 and v_branch_pass=1 and v_domain_fail=0),
    'contracts',jsonb_build_object('failed',v_contract_fail,'ok',v_contract_fail=0),
    'cleanup',jsonb_build_object('remainingTestOrders',v_cleanup_remaining,'ok',v_cleanup_remaining=0)
  );

  v_certified:=
    v_routes_total=336 and v_routes_pass=336 and v_routes_fail=0 and v_routes_pending=0
    and v_journeys_total=336 and v_journeys_pass=336 and v_journeys_fail=0 and v_journeys_pending=0
    and v_deep_total>672 and v_deep_fail=0 and v_deep_pending=0 and v_transport=0 and v_timeout=0
    and v_ui_pass=v_ui_expected and v_ui_fail=0
    and v_resp_pass=54 and v_resp_fail=0
    and v_sandbox_pass=14 and v_sandbox_fail=0
    and v_health_pass=7 and v_health_fail=0 and v_controls_pass=1 and v_branch_pass=1 and v_domain_fail=0 and v_contract_fail=0 and v_cleanup_remaining=0;

  return jsonb_build_object('certified',v_certified,'releaseState',case when v_certified then 'CERTIFIED' when v_deep_pending>0 then 'INCOMPLETE' else 'FAILED' end,
    'runId',p_run_id,'gates',v_gates,'version','10.25.3','checkedAt',now());
end;
$$;

-- Cierre de una prueba dirigida (solo rutas o solo campaña profunda). No emite
-- certificado de liberación; solo asegura que su inventario particular terminó.
create or replace function public.erp_x_qa_robot_finish_directed_run(p_run_id uuid,p_suite text default 'DIRECTED')
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_order uuid;v_deleted int:=0;v_cleanup_remaining int:=0;
  v_total int:=0;v_passed int:=0;v_failed int:=0;v_pending int:=0;v_transport int:=0;v_timeout int:=0;v_ok boolean:=false;v_suite text:=upper(coalesce(nullif(trim(p_suite),''),'DIRECTED'));
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  for v_order in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
    begin perform public.erp_x_sandbox_delete(v_order);v_deleted:=v_deleted+1; exception when others then null; end;
  end loop;
  select count(*),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status in('PENDING','RUNNING')),coalesce(sum(transport_failures),0)::int,coalesce(sum(timeout_failures),0)::int
    into v_total,v_passed,v_failed,v_pending,v_transport,v_timeout from erp_supply.qa_deep_cases where qa_run_id=p_run_id;
  select count(*) into v_cleanup_remaining from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT';
  v_ok:=v_total>0 and v_passed=v_total and v_failed=0 and v_pending=0 and v_transport=0 and v_timeout=0 and v_cleanup_remaining=0;
  update erp_supply.qa_runs set status=case when v_ok then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,
    completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object('directedSuite',v_suite,'planned',v_total,'executed',v_passed+v_failed,'passed',v_passed,
      'failed',v_failed,'pending',v_pending,'transport',v_transport,'timeouts',v_timeout,'sandboxOrdersDeleted',v_deleted,'cleanupRemaining',v_cleanup_remaining,'qaRobotVersion','10.25.3')
  where id=p_run_id;
  return jsonb_build_object('runId',p_run_id,'suite',v_suite,'status',case when v_ok then 'PASSED' else 'FAILED' end,'passed',v_passed,'failed',v_failed,
    'planned',v_total,'executed',v_passed+v_failed,'pending',v_pending,'transportFailures',v_transport,'timeoutFailures',v_timeout,'cleanupRemaining',v_cleanup_remaining,'version','10.25.3');
end;
$$;

-- El cierre del Robot se subordina al certificado, no solo al número de checks.
create or replace function public.erp_x_qa_robot_finish_run(p_run_id uuid,p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_sandbox_admin();v_org uuid:=erp_supply.current_org_id();v_order uuid;v_deleted int:=0;
  v_total int:=0;v_passed int:=0;v_failed int:=0;v_warnings int:=0;v_running int:=0;v_certificate jsonb;v_certified boolean;v_release_state text;
begin
  if not exists(select 1 from erp_supply.qa_runs where id=p_run_id and organization_id=v_org and run_type='TOTAL_ROBOT') then raise exception 'Ejecución QA total no disponible'; end if;
  if p_cleanup then
    for v_order in select id from erp_supply.orders where qa_run_id=p_run_id and organization_id=v_org and is_test and source='QA_BOT' loop
      begin perform public.erp_x_sandbox_delete(v_order);v_deleted:=v_deleted+1;
      exception when others then
        perform public.erp_x_qa_robot_record_check(p_run_id,jsonb_build_object('checkKey','CLEANUP-'||v_order::text,'layer','INTEGRITY','suite','SANDBOX_CLEANUP','status','FAILED','severity','CRITICAL','orderId',v_order,'errorMessage',sqlstate||' · '||sqlerrm));
      end;
    end loop;
  end if;

  select count(*) filter(where status<>'SKIPPED'),count(*) filter(where status='PASSED'),count(*) filter(where status='FAILED'),count(*) filter(where status='WARNING'),count(*) filter(where status='RUNNING')
  into v_total,v_passed,v_failed,v_warnings,v_running from erp_supply.qa_robot_checks where qa_run_id=p_run_id;
  v_certificate:=public.erp_x_qa_robot_release_certificate(p_run_id);
  v_certified:=coalesce((v_certificate->>'certified')::boolean,false);v_release_state:=coalesce(v_certificate->>'releaseState','FAILED');

  update erp_supply.qa_runs set status=case when v_certified then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,
    failed_scenarios=v_failed+case when v_certified then 0 else 1 end,completed_at=now(),summary=coalesce(summary,'{}'::jsonb)||jsonb_build_object(
      'warnings',v_warnings,'runningChecksAtFinish',v_running,'sandboxOrdersDeleted',v_deleted,'qaRobotVersion','10.25.3','releaseState',v_release_state,'releaseCertificate',v_certificate,'finishedAt',now())
  where id=p_run_id;
  return jsonb_build_object('runId',p_run_id,'status',case when v_certified then 'PASSED' else 'FAILED' end,'releaseState',v_release_state,'certified',v_certified,
    'total',v_total,'passed',v_passed,'failed',v_failed+case when v_certified then 0 else 1 end,'warnings',v_warnings,'sandboxOrdersDeleted',v_deleted,'certificate',v_certificate);
end;
$$;


revoke all on function public.erp_x_qa_robot_create_run(jsonb) from public,anon;
revoke all on function public.erp_x_qa_robot_latest_resumable() from public,anon;
revoke all on function public.erp_x_qa_robot_plan() from public,anon;
grant execute on function public.erp_x_qa_robot_create_run(jsonb) to authenticated;
grant execute on function public.erp_x_qa_robot_latest_resumable() to authenticated;
grant execute on function public.erp_x_qa_robot_plan() to authenticated;

revoke all on function public.erp_x_qa_robot_execute_release_slice(uuid) from public,anon;
revoke all on function public.erp_x_qa_release_flow_integrity() from public,anon;
revoke all on function public.erp_x_qa_release_health(uuid) from public,anon;
grant execute on function public.erp_x_qa_robot_execute_release_slice(uuid) to authenticated;
grant execute on function public.erp_x_qa_release_flow_integrity() to authenticated;
grant execute on function public.erp_x_qa_release_health(uuid) to authenticated;

notify pgrst,'reload schema';
commit;
