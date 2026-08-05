-- ============================================================
-- EI ERP NOVA V9 · API NATIVA SUPABASE
-- Ejecutar una sola vez en Supabase SQL Editor.
-- No modifica ni elimina pedidos existentes.
-- Requiere las tablas normalizadas y funciones operativas V8 ya instaladas.
-- ============================================================

begin;

create extension if not exists pgcrypto;

-- ------------------------------------------------------------
-- SESIÓN
-- ------------------------------------------------------------
create or replace function public.erp_v9_session()
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare p public.profiles%rowtype; r text; k text;
begin
  select * into p from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  r:=public.erp_current_exact_role();
  k:=public.erp_current_user_key();
  return jsonb_build_object(
    'viewer',jsonb_build_object('uid',k,'authUid',auth.uid(),'email',lower(p.email),'name',p.display_name,'role',r,'active',p.active),
    'version','9.0.0','backend','SUPABASE_NATIVE','generatedAt',now()
  );
end $$;

-- ------------------------------------------------------------
-- CATÁLOGO Y POOLS DE ASIGNACIÓN
-- ------------------------------------------------------------
create or replace function public.erp_v9_catalog()
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare p public.profiles%rowtype; r text; a jsonb; c jsonb; rec jsonb;
begin
  select * into p from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  r:=public.erp_current_exact_role();
  select coalesce(jsonb_agg(jsonb_build_object('uid',coalesce(nullif(firebase_uid,''),auth_user_id::text),'email',lower(email),'name',display_name,'role',public.erp_exact_role(role_code)) order by display_name),'[]'::jsonb)
    into a from public.profiles where active=true and auth_user_id is not null and public.erp_exact_role(role_code)='aux_logistica';
  select coalesce(jsonb_agg(jsonb_build_object('uid',coalesce(nullif(firebase_uid,''),auth_user_id::text),'email',lower(email),'name',display_name,'role',public.erp_exact_role(role_code)) order by display_name),'[]'::jsonb)
    into c from public.profiles where active=true and auth_user_id is not null and public.erp_exact_role(role_code)='auxiliar_corte';
  select coalesce(jsonb_agg(jsonb_build_object('uid',coalesce(nullif(firebase_uid,''),auth_user_id::text),'email',lower(email),'name',display_name,'role',public.erp_exact_role(role_code)) order by display_name),'[]'::jsonb)
    into rec from public.profiles where active=true and auth_user_id is not null and public.erp_exact_role(role_code)='recepcion_mercancia';
  return jsonb_build_object(
    'viewerRole',r,
    'routes',jsonb_build_array(
      jsonb_build_object('code','cliente_punto','label','Entrega en punto'),
      jsonb_build_object('code','cliente_recoge','label','Cliente recoge'),
      jsonb_build_object('code','despacho_local','label','Despacho local'),
      jsonb_build_object('code','despacho_nacional','label','Despacho nacional')
    ),
    'orderKinds',jsonb_build_array('PVC','PVN','PVE','PVP'),
    'paymentConditions',jsonb_build_array('CREDITO','CONTADO','MIXTO'),
    'priorityLevels',jsonb_build_array('MEDIA','ALTA','URGENTE','CRITICA'),
    'assignmentPools',jsonb_build_object('alistamiento',a,'corte',c,'recepcionMercancia',rec),
    'generatedAt',now()
  );
end $$;

-- ------------------------------------------------------------
-- PANEL
-- ------------------------------------------------------------
create or replace function public.erp_v9_dashboard()
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare v_uid text:=public.erp_current_user_key(); v_email text; result jsonb;
begin
  if v_uid is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  select lower(email) into v_email from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  with visible as (
    select c.* from public.cases c where public.erp_case_id_visible(c.case_id)
  ), proc as (
    select coalesce(nullif(public.erp_normalize_key(current_process),''),'sin_proceso') code,count(*) quantity from visible group by 1
  ), recent as (
    select case_id,reference,client,status,current_process,updated_at from visible order by updated_at desc nulls last limit 12
  )
  select jsonb_build_object(
    'summary',jsonb_build_object(
      'visible',(select count(*) from visible),
      'active',(select count(*) from visible where not public.erp_is_terminal_status(status)),
      'closed',(select count(*) from visible where public.erp_is_terminal_status(status)),
      'assignedToMe',(select count(*) from visible where coalesce(assigned_uid,'')=v_uid or lower(coalesce(assigned_email,''))=v_email),
      'availableApprovals',(select count(*) from public.workflow_requests wr where wr.status='PENDING' and public.erp_case_id_visible(wr.case_id) and (public.erp_current_exact_role()=any(coalesce(wr.assigned_roles,'{}'::text[])) or v_uid=any(coalesce(wr.assigned_user_uids,'{}'::text[])) or public.erp_current_exact_role() in ('super_admin','gerencia')))
    ),
    'byProcess',coalesce((select jsonb_agg(jsonb_build_object('code',code,'label',replace(code,'_',' '),'quantity',quantity) order by quantity desc) from proc),'[]'::jsonb),
    'recentCases',coalesce((select jsonb_agg(jsonb_build_object('caseId',case_id,'reference',reference,'client',client,'status',status,'currentProcess',current_process,'updatedAt',updated_at) order by updated_at desc) from recent),'[]'::jsonb),
    'generatedAt',now()
  ) into result;
  return result;
end $$;

-- ------------------------------------------------------------
-- LISTADO PAGINADO DE PEDIDOS
-- ------------------------------------------------------------
create or replace function public.erp_v9_cases(
  p_search text default null,
  p_processes text[] default null,
  p_status text default null,
  p_route text default null,
  p_order_kind text default null,
  p_assignment text default 'all',
  p_lifecycle text default 'active',
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare v_uid text:=public.erp_current_user_key(); v_email text; v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),100); v_total bigint; v_items jsonb; v_norm_processes text[];
begin
  if v_uid is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  select lower(email) into v_email from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  select array_agg(public.erp_normalize_key(x)) into v_norm_processes from unnest(coalesce(p_processes,'{}'::text[])) x;
  with filtered as (
    select c.*,public.erp_case_route(to_jsonb(c)||coalesce(c.raw_data,'{}'::jsonb)) route_code
    from public.cases c
    where public.erp_case_id_visible(c.case_id)
      and (p_search is null or btrim(p_search)='' or lower(coalesce(c.reference,'')||' '||coalesce(c.client,'')||' '||coalesce(c.case_id,'')||' '||coalesce(c.description,'')) like '%'||lower(btrim(p_search))||'%')
      and (coalesce(array_length(v_norm_processes,1),0)=0 or public.erp_normalize_key(c.current_process)=any(v_norm_processes))
      and (p_status is null or btrim(p_status)='' or public.erp_normalize_key(c.status)=public.erp_normalize_key(p_status))
      and (p_route is null or btrim(p_route)='' or public.erp_case_route(to_jsonb(c)||coalesce(c.raw_data,'{}'::jsonb))=public.erp_normalize_key(p_route))
      and (p_order_kind is null or btrim(p_order_kind)='' or upper(coalesce(c.order_kind,''))=upper(btrim(p_order_kind)))
      and (coalesce(p_assignment,'all')='all' or (p_assignment='mine' and (coalesce(c.assigned_uid,'')=v_uid or lower(coalesce(c.assigned_email,''))=v_email)) or (p_assignment='unassigned' and coalesce(c.assigned_uid,c.assigned_email,c.assigned_to,'')=''))
      and (coalesce(p_lifecycle,'active')='all' or (p_lifecycle='active' and not public.erp_is_terminal_status(c.status)) or (p_lifecycle='terminal' and public.erp_is_terminal_status(c.status)))
  )
  select count(*) into v_total from filtered;
  with filtered as (
    select c.*,public.erp_case_route(to_jsonb(c)||coalesce(c.raw_data,'{}'::jsonb)) route_code
    from public.cases c
    where public.erp_case_id_visible(c.case_id)
      and (p_search is null or btrim(p_search)='' or lower(coalesce(c.reference,'')||' '||coalesce(c.client,'')||' '||coalesce(c.case_id,'')||' '||coalesce(c.description,'')) like '%'||lower(btrim(p_search))||'%')
      and (coalesce(array_length(v_norm_processes,1),0)=0 or public.erp_normalize_key(c.current_process)=any(v_norm_processes))
      and (p_status is null or btrim(p_status)='' or public.erp_normalize_key(c.status)=public.erp_normalize_key(p_status))
      and (p_route is null or btrim(p_route)='' or public.erp_case_route(to_jsonb(c)||coalesce(c.raw_data,'{}'::jsonb))=public.erp_normalize_key(p_route))
      and (p_order_kind is null or btrim(p_order_kind)='' or upper(coalesce(c.order_kind,''))=upper(btrim(p_order_kind)))
      and (coalesce(p_assignment,'all')='all' or (p_assignment='mine' and (coalesce(c.assigned_uid,'')=v_uid or lower(coalesce(c.assigned_email,''))=v_email)) or (p_assignment='unassigned' and coalesce(c.assigned_uid,c.assigned_email,c.assigned_to,'')=''))
      and (coalesce(p_lifecycle,'active')='all' or (p_lifecycle='active' and not public.erp_is_terminal_status(c.status)) or (p_lifecycle='terminal' and public.erp_is_terminal_status(c.status)))
    order by c.updated_at desc nulls last,c.created_at desc
    offset (v_page-1)*v_size limit v_size
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'caseId',case_id,'reference',reference,'client',client,'orderKind',order_kind,'status',status,'currentProcess',current_process,'route',route_code,'assignedName',assigned_name,'assignedUid',assigned_uid,'assignedEmail',assigned_email,'priority',priority,'updatedAt',updated_at,'createdAt',created_at,'rawData',raw_data
  ) order by updated_at desc nulls last),'[]'::jsonb) into v_items from filtered;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end,'hasNextPage',v_page<ceil(greatest(v_total,1)::numeric/v_size)::int),'generatedAt',now());
end $$;

-- ------------------------------------------------------------
-- DETALLE DE PEDIDO
-- ------------------------------------------------------------
create or replace function public.erp_v9_case_detail(p_case_id text)
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare c jsonb;
begin
  if not public.erp_case_id_visible(p_case_id) then raise exception 'El pedido no está disponible para este usuario' using errcode='42501'; end if;
  select to_jsonb(x) into c from public.cases x where x.case_id=p_case_id;
  if c is null then raise exception 'Pedido no encontrado'; end if;
  return jsonb_build_object(
    'case',c,
    'items',coalesce((select jsonb_agg(to_jsonb(x) order by x.item_index) from public.case_items x where x.case_id=p_case_id),'[]'::jsonb),
    'history',coalesce((select jsonb_agg(to_jsonb(x) order by coalesce(x.timestamp,x.started_at,x.ended_at)) from public.case_state_history x where x.case_id=p_case_id),'[]'::jsonb),
    'processStats',coalesce((select jsonb_agg(to_jsonb(x) order by x.process_code) from public.case_process_stats x where x.case_id=p_case_id),'[]'::jsonb),
    'cuts',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.case_cuts x where x.case_id=p_case_id),'[]'::jsonb),
    'components',coalesce((select jsonb_agg(to_jsonb(x) order by x.component_type,x.component_index) from public.case_components x where x.case_id=p_case_id),'[]'::jsonb),
    'events',coalesce((select jsonb_agg(to_jsonb(x) order by x.timestamp) from public.case_events x where x.case_id=p_case_id),'[]'::jsonb),
    'evidences',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.evidences x where x.case_id=p_case_id),'[]'::jsonb),
    'comments',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.case_comments x where x.case_id=p_case_id),'[]'::jsonb),
    'requests',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at) from public.workflow_requests x where x.case_id=p_case_id),'[]'::jsonb),
    'generatedAt',now()
  );
end $$;

-- ------------------------------------------------------------
-- ACCIONES NATIVAS V9
-- ------------------------------------------------------------
create or replace function public.erp_v9_case_actions(p_case_id text)
returns jsonb
language plpgsql stable security definer set search_path=public
as $$
declare
  p public.profiles%rowtype;c public.cases%rowtype;v_uid text;v_role text;v_process text;v_status text;v_route text;v_terminal boolean;v_assigned boolean;v_can boolean:=false;ops jsonb:='[]'::jsonb;req jsonb:='[]'::jsonb;approvals jsonb:='[]'::jsonb;t text;
begin
  select * into p from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  select * into c from public.cases where case_id=p_case_id;
  if not found then raise exception 'Pedido no encontrado'; end if;
  if not public.erp_case_id_visible(p_case_id) then raise exception 'El pedido no está disponible para este usuario' using errcode='42501'; end if;
  v_uid:=public.erp_current_user_key();v_role:=public.erp_current_exact_role();v_process:=public.erp_normalize_key(c.current_process);v_status:=public.erp_normalize_key(c.status);v_route:=public.erp_case_route(to_jsonb(c)||coalesce(c.raw_data,'{}'::jsonb));v_terminal:=public.erp_is_terminal_status(c.status);
  v_assigned:=coalesce(c.assigned_uid,'')=v_uid or lower(coalesce(c.assigned_email,''))=lower(coalesce(p.email,''));
  if not v_terminal then
    if v_role='super_admin' then v_can:=true;
    elsif v_role in ('gerencia','auditoria') then v_can:=false;
    elsif v_process='cartera' then v_can:=v_role='cartera' or v_assigned;
    elsif v_process='caja' then v_can:=v_role='caja' or v_assigned;
    elsif v_process='compras' then v_can:=v_role='compras' or v_assigned;
    elsif v_process in ('recepcion_pedidos','recepcion_mercancia','reception_goods') then v_can:=v_role in ('recepcion_mercancia','coordinador_logistico','jefe_logistica') or v_assigned;
    elsif v_process='alistamiento' then v_can:=v_role='aux_logistica' and v_assigned;
    elsif v_process in ('prealistamiento','corte','corte_cable') then v_can:=v_role='auxiliar_corte' and v_assigned;
    elsif v_process='facturacion' then v_can:=v_role='jefe_logistica' or (v_route='despacho_nacional' and v_role='despacho_nacional') or (v_route<>'despacho_nacional' and v_role='coordinador_logistico');
    elsif v_process in ('cliente_punto','cliente_recoge','despacho_local') then v_can:=v_role in ('coordinador_logistico','jefe_logistica');
    elsif v_process='despacho_nacional' then v_can:=v_role in ('despacho_nacional','jefe_logistica');
    elsif v_process in ('cierre_caso','cierre_despacho_nacional') then v_can:=v_role in ('jefe_logistica','coordinador_logistico','despacho_nacional');
    end if;
  end if;

  -- Los comentarios siempre están disponibles para usuarios con visibilidad.
  ops:=ops||jsonb_build_array(jsonb_build_object('code','add_comment','label','Agregar comentario','category','COMMENT','enabled',true));
  if v_can then
    if v_process='cartera' then ops:=ops||jsonb_build_array(jsonb_build_object('code','release_cartera','label','Liberar desde Cartera','category','PROCESS','enabled',true));
    elsif v_process='caja' then
      if upper(coalesce(c.order_kind,''))='PVN' and upper(coalesce(c.payment_condition,'')) in ('CONTADO','MIXTO') and coalesce(public.erp_try_boolean(c.raw_data->>'invoiceRegistered',false),false) then
        ops:=ops||jsonb_build_array(jsonb_build_object('code','release_caja_factura_pvn','label','Validar pago posterior a factura','category','PROCESS','enabled',true));
      else ops:=ops||jsonb_build_array(jsonb_build_object('code','release_caja_prelogistica','label','Liberar pago hacia Logística','category','PROCESS','enabled',true)); end if;
    elsif v_process='compras' then ops:=ops||jsonb_build_array(jsonb_build_object('code','release_compras','label','Liberar orden de compra','category','PROCESS','enabled',true));
    elsif v_process in ('recepcion_pedidos','recepcion_mercancia','reception_goods') then ops:=ops||jsonb_build_array(jsonb_build_object('code','receive_and_assign_order','label','Recibir y asignar pedido','category','PROCESS','enabled',true));
    elsif v_process='alistamiento' then
      if v_status in ('asignado','assigned') then ops:=ops||jsonb_build_array(jsonb_build_object('code','start_alistamiento','label','Iniciar Alistamiento','category','PROCESS','enabled',true));
      else ops:=ops||jsonb_build_array(jsonb_build_object('code','complete_alistamiento','label','Finalizar Alistamiento','category','PROCESS','enabled',true)); end if;
    elsif v_process in ('prealistamiento','corte','corte_cable') then
      if v_status in ('asignado','assigned') then ops:=ops||jsonb_build_array(jsonb_build_object('code','start_corte','label','Iniciar Corte','category','PROCESS','enabled',true));
      else ops:=ops||jsonb_build_array(jsonb_build_object('code','complete_corte','label','Finalizar Corte','category','PROCESS','enabled',true)); end if;
    elsif v_process='facturacion' then ops:=ops||jsonb_build_array(jsonb_build_object('code','release_facturacion','label','Registrar factura y liberar','category','PROCESS','enabled',true));
    elsif v_process in ('cliente_punto','cliente_recoge','despacho_local','despacho_nacional') then
      if public.erp_normalize_key(coalesce(c.raw_data->>'deliveryStatus','')) in ('no_delivery','not_delivered','failed','reprogramming') then ops:=ops||jsonb_build_array(jsonb_build_object('code','reprogram_no_delivery','label','Reprogramar entrega','category','DELIVERY','enabled',true));
      elsif v_status in ('asignado','assigned') then ops:=ops||jsonb_build_array(jsonb_build_object('code','start_delivery','label','Iniciar entrega o despacho','category','DELIVERY','enabled',true));
      else ops:=ops||jsonb_build_array(jsonb_build_object('code','complete_delivery','label','Completar entrega o despacho','category','DELIVERY','enabled',true)); end if;
    elsif v_process in ('cierre_caso','cierre_despacho_nacional') then ops:=ops||jsonb_build_array(jsonb_build_object('code','close_case','label','Cerrar formalmente el pedido','category','CLOSURE','enabled',true));
    end if;
  end if;

  foreach t in array array['priority','cancellation','route_change','no_delivery','reopen','stock_exception','flow_exception','payment_exception','data_correction'] loop
    if public.erp_can_request_type(t) and not exists(select 1 from public.workflow_requests w where w.case_id=p_case_id and public.erp_normalize_key(w.request_type)=t and w.status='PENDING') then
      if (t='reopen' and v_terminal) or (t='data_correction') or (t<>'reopen' and not v_terminal) then req:=req||jsonb_build_array(jsonb_build_object('code',t,'label',case t when 'priority' then 'Solicitar prioridad' when 'cancellation' then 'Solicitar cancelación' when 'route_change' then 'Solicitar cambio de ruta' when 'no_delivery' then 'Reportar no entrega' when 'reopen' then 'Solicitar reapertura' when 'stock_exception' then 'Excepción de inventario' when 'flow_exception' then 'Excepción de flujo' when 'payment_exception' then 'Excepción financiera' else 'Corrección de datos' end,'category','REQUEST','enabled',true)); end if;
    end if;
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object('requestId',w.request_id,'requestType',w.request_type,'reason',w.reason,'requestedByName',w.requested_by_name,'createdAt',w.created_at) order by w.created_at),'[]'::jsonb) into approvals
  from public.workflow_requests w where w.case_id=p_case_id and w.status='PENDING' and (v_role in ('super_admin','gerencia') or v_role=any(coalesce(w.assigned_roles,'{}'::text[])) or v_uid=any(coalesce(w.assigned_user_uids,'{}'::text[])));
  return jsonb_build_object('caseId',p_case_id,'context',jsonb_build_object('status',c.status,'currentProcess',c.current_process,'route',v_route,'terminal',v_terminal,'assignedToMe',v_assigned,'canOperate',v_can),'operationalActions',ops,'requestActions',req,'pendingApprovals',approvals,'generatedAt',now());
end $$;

create or replace function public.erp_v9_execute(p_case_id text,p_action_code text,p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql security definer set search_path=public
as $$
declare p public.profiles%rowtype;v_uid text;v_role text;v_action text:=public.erp_normalize_key(p_action_code);v_allowed boolean:=false;v_result jsonb;v_request_id uuid;v_case_for_request text;v_data jsonb;v_detail text;v_reason text;
begin
  select * into p from public.profiles where auth_user_id=auth.uid() and active=true limit 1;
  if not found then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  v_uid:=public.erp_current_user_key();v_role:=public.erp_current_exact_role();v_detail:=nullif(btrim(coalesce(p_payload->>'detail',p_payload->>'note',p_payload->>'reason','')),'');v_reason:=nullif(btrim(coalesce(p_payload->>'reason',p_payload->>'detail',p_payload->>'note','')),'');

  if v_action='create_case' then
    if v_role not in ('super_admin','ventas') then raise exception 'Su rol no puede crear pedidos' using errcode='42501'; end if;
    if coalesce(btrim(p_case_id),'')='' then raise exception 'Debe indicar el identificador del pedido'; end if;
    if exists(select 1 from public.cases where case_id=p_case_id) then raise exception 'El identificador ya existe'; end if;
    v_data:=coalesce(p_payload,'{}'::jsonb)||jsonb_build_object('id',p_case_id,'createdBy',v_uid,'createdByUid',v_uid,'createdByEmail',lower(p.email),'createdByName',p.display_name,'salesAdvisor',coalesce(p_payload->>'salesAdvisor',lower(p.email)),'createdAt',coalesce(p_payload->'createdAt',to_jsonb(now())),'updatedAt',to_jsonb(now()));
    v_result:=public.erp_upsert_case(p_case_id,v_data,true);
    return jsonb_build_object('success',true,'actionCode',v_action,'caseId',p_case_id,'result',v_result,'executedAt',now());
  end if;

  if v_action='decide_approval' then
    begin v_request_id:=(p_payload->>'requestId')::uuid; exception when others then raise exception 'Solicitud inválida'; end;
    select case_id into v_case_for_request from public.workflow_requests where request_id=v_request_id;
    if v_case_for_request is null then raise exception 'Solicitud no encontrada'; end if;
    v_result:=public.erp_decide_approval(v_request_id,upper(p_payload->>'decision'),coalesce(v_reason,'Sin observación'));
    return jsonb_build_object('success',true,'actionCode',v_action,'caseId',v_case_for_request,'requestId',v_request_id,'result',v_result,'executedAt',now());
  end if;

  if not public.erp_case_id_visible(p_case_id) then raise exception 'El pedido no está disponible para este usuario' using errcode='42501'; end if;

  if v_action='add_comment' then
    if coalesce(btrim(p_payload->>'body'),'')='' then raise exception 'Debe escribir el comentario'; end if;
    insert into public.case_comments(case_id,comment_type,body,visibility,created_by_uid,created_by_name,created_by_role,metadata)
    values(p_case_id,upper(coalesce(p_payload->>'commentType','COMMENT')),btrim(p_payload->>'body'),upper(coalesce(p_payload->>'visibility','CASE')),v_uid,p.display_name,v_role,coalesce(p_payload->'metadata','{}'::jsonb)) returning jsonb_build_object('commentId',comment_id,'caseId',case_id,'commentType',comment_type,'body',body,'visibility',visibility,'createdByName',created_by_name,'createdByRole',created_by_role,'createdAt',created_at,'metadata',metadata) into v_result;
    return jsonb_build_object('success',true,'actionCode',v_action,'caseId',p_case_id,'result',v_result,'executedAt',now());
  end if;

  if v_action=any(array['priority','cancellation','route_change','no_delivery','reopen','stock_exception','flow_exception','payment_exception','data_correction']) then
    if v_reason is null then raise exception 'Debe indicar el motivo'; end if;
    v_result:=public.erp_request_approval(p_case_id,v_action,v_reason,coalesce(p_payload-'reason'-'detail'-'note','{}'::jsonb));
    return jsonb_build_object('success',true,'actionCode',v_action,'caseId',p_case_id,'result',v_result,'executedAt',now());
  end if;

  select exists(select 1 from jsonb_array_elements((public.erp_v9_case_actions(p_case_id))->'operationalActions') x where public.erp_normalize_key(x->>'code')=v_action and coalesce(public.erp_try_boolean(x->>'enabled',false),false)) into v_allowed;
  if not v_allowed then raise exception 'La acción % no está disponible para este pedido o usuario',v_action using errcode='42501'; end if;

  case v_action
    when 'release_cartera' then v_result:=public.erp_release_cartera(p_case_id,coalesce(v_detail,'Liberado por Cartera'));
    when 'release_caja_prelogistica' then v_result:=public.erp_release_caja_prelogistica(p_case_id,coalesce(v_detail,'Liberado por Caja'),coalesce(p_payload->'paymentEvidence','{}'::jsonb));
    when 'release_caja_factura_pvn' then v_result:=public.erp_release_caja_factura_pvn(p_case_id,coalesce(v_detail,'Pago validado por Caja'),coalesce(p_payload->'invoiceData',p_payload-'detail'-'note'-'reason'));
    when 'release_compras' then v_result:=public.erp_release_compras(p_case_id,coalesce(v_detail,'Orden liberada por Compras'),coalesce(p_payload->'purchaseData',p_payload-'detail'-'note'-'reason'));
    when 'receive_and_assign_order' then v_result:=public.erp_receive_and_assign_order(p_case_id,coalesce(p_payload->>'assignedUserUid',p_payload->>'assigneeIdentifier'),coalesce(v_detail,'Pedido recibido y asignado'),coalesce(public.erp_try_boolean(p_payload->>'requiresCut',false),false),coalesce(p_payload->'metadata','{}'::jsonb));
    when 'start_alistamiento' then v_result:=public.erp_start_alistamiento(p_case_id,v_detail);
    when 'complete_alistamiento' then v_result:=public.erp_complete_alistamiento(p_case_id,coalesce(v_detail,'Alistamiento finalizado'),p_payload->>'cutAssigneeIdentifier',coalesce(p_payload->'metadata',p_payload-'detail'-'note'-'reason'-'cutAssigneeIdentifier'));
    when 'start_corte' then v_result:=public.erp_start_corte(p_case_id,v_detail);
    when 'complete_corte' then v_result:=public.erp_complete_corte(p_case_id,coalesce(v_detail,'Corte finalizado'),coalesce(p_payload->'cutData',p_payload-'detail'-'note'-'reason'));
    when 'release_facturacion' then v_result:=public.erp_release_facturacion(p_case_id,coalesce(v_detail,'Factura registrada'),coalesce(p_payload->'billingData',p_payload-'detail'-'note'-'reason'));
    when 'start_delivery' then v_result:=public.erp_start_delivery(p_case_id,v_detail);
    when 'complete_delivery' then v_result:=public.erp_complete_delivery(p_case_id,coalesce(v_detail,'Entrega completada'),coalesce(p_payload->'deliveryData',p_payload-'detail'-'note'-'reason'));
    when 'reprogram_no_delivery' then v_result:=public.erp_reprogram_no_delivery(p_case_id,(p_payload->>'newDeliveryAt')::timestamptz,coalesce(v_reason,'Reprogramación'),coalesce(p_payload->'metadata','{}'::jsonb));
    when 'close_case' then v_result:=public.erp_close_case(p_case_id,coalesce(p_payload->>'closureNote',v_detail,'Cierre formal'),coalesce(p_payload->'closeData',p_payload-'closureNote'-'detail'-'note'-'reason'));
    else raise exception 'Acción V9 no implementada: %',v_action;
  end case;
  return jsonb_build_object('success',true,'actionCode',v_action,'caseId',p_case_id,'result',v_result,'executedAt',now(),'executedBy',jsonb_build_object('uid',v_uid,'name',p.display_name,'role',v_role));
end $$;

create or replace function public.erp_v9_workflows(p_view text default 'available',p_request_type text default null,p_status text default null,p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin return public.erp_list_workflow_requests(p_view,p_request_type,p_status,p_search,p_page,p_page_size); end $$;

-- ------------------------------------------------------------
-- CRÉDITO
-- ------------------------------------------------------------
create or replace function public.erp_v9_credit_list(p_status text default null,p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_uid text:=public.erp_current_user_key(); v_role text:=public.erp_current_exact_role(); v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if v_uid is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  with f as (select * from public.credit_requests r where (v_role in ('super_admin','gerencia','cartera','auditoria') or r.created_by_uid=v_uid) and (p_status is null or btrim(p_status)='' or upper(r.status)=upper(p_status)) and (p_search is null or btrim(p_search)='' or lower(coalesce(r.request_code,'')||' '||coalesce(r.company_name,'')||' '||coalesce(r.contact_name,'')) like '%'||lower(btrim(p_search))||'%')) select count(*) into v_total from f;
  with f as (select * from public.credit_requests r where (v_role in ('super_admin','gerencia','cartera','auditoria') or r.created_by_uid=v_uid) and (p_status is null or btrim(p_status)='' or upper(r.status)=upper(p_status)) and (p_search is null or btrim(p_search)='' or lower(coalesce(r.request_code,'')||' '||coalesce(r.company_name,'')||' '||coalesce(r.contact_name,'')) like '%'||lower(btrim(p_search))||'%') order by r.updated_at desc offset (v_page-1)*v_size limit v_size)
  select coalesce(jsonb_agg(jsonb_build_object('requestId',request_id,'requestCode',request_code,'status',status,'companyName',company_name,'contactName',contact_name,'contactPhone',contact_phone,'companyAddress',company_address,'requestedAmount',requested_amount,'requestedTerm',requested_term,'documentCount',document_count,'documents',documents,'updatedAt',updated_at,'createdAt',created_at,'createdByName',created_by_name) order by updated_at desc),'[]'::jsonb) into v_items from f;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end));
end $$;

create or replace function public.erp_v9_credit_save(p_request_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid text:=public.erp_current_user_key();v_role text:=public.erp_current_exact_role();v_existing public.credit_requests%rowtype;v_docs jsonb;v_count int;
begin
  if v_uid is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  if v_role not in ('super_admin','ventas') then raise exception 'Su rol no puede crear solicitudes de crédito' using errcode='42501'; end if;
  select * into v_existing from public.credit_requests where request_id=p_request_id for update;
  if found and v_role<>'super_admin' and v_existing.created_by_uid<>v_uid then raise exception 'La solicitud pertenece a otro usuario' using errcode='42501'; end if;
  if found and v_existing.status not in ('DRAFT','RETURNED') and v_role<>'super_admin' then raise exception 'La solicitud ya no está editable'; end if;
  v_docs:=coalesce(p_payload->'documents',case when found then v_existing.documents else '{}'::jsonb end,'{}'::jsonb);v_count:=jsonb_object_length(v_docs);
  insert into public.credit_requests(request_id,request_code,status,created_by_uid,created_by_auth_uid,created_by_name,created_by_email,company_name,contact_name,contact_phone,company_address,landline,requested_amount,requested_term,document_count,completeness,documents,created_at,updated_at,raw_data)
  values(p_request_id,coalesce(p_payload->>'requestCode','SCR-'||to_char(now(),'YYYYMMDD-HH24MISS')),coalesce(p_payload->>'status','DRAFT'),v_uid,auth.uid(),coalesce(p_payload->>'createdByName',(public.erp_current_profile()).display_name),coalesce(p_payload->>'createdByEmail',(public.erp_current_profile()).email),p_payload->>'companyName',p_payload->>'contactName',p_payload->>'contactPhone',p_payload->>'companyAddress',p_payload->>'landline',public.erp_try_numeric(p_payload->>'requestedAmount'),p_payload->>'requestedTerm',v_count,least(100,round(v_count*100.0/15)::int),v_docs,now(),now(),p_payload||jsonb_build_object('requestId',p_request_id,'documentCount',v_count))
  on conflict(request_id) do update set company_name=excluded.company_name,contact_name=excluded.contact_name,contact_phone=excluded.contact_phone,company_address=excluded.company_address,landline=excluded.landline,requested_amount=excluded.requested_amount,requested_term=excluded.requested_term,document_count=excluded.document_count,completeness=excluded.completeness,documents=excluded.documents,updated_at=now(),raw_data=public.credit_requests.raw_data||excluded.raw_data;
  return (select to_jsonb(x) from public.credit_requests x where x.request_id=p_request_id);
end $$;

create or replace function public.erp_v9_credit_transition(p_request_id text,p_action text,p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
begin return public.credit_transition(p_request_id,p_action,coalesce(p_payload,'{}'::jsonb)); end $$;

-- ------------------------------------------------------------
-- USUARIOS
-- ------------------------------------------------------------
create or replace function public.erp_v9_profiles()
returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if public.erp_current_exact_role()<>'super_admin' then raise exception 'Solo Super Admin puede administrar perfiles' using errcode='42501'; end if;
  return jsonb_build_object('items',coalesce((select jsonb_agg(jsonb_build_object('uid',coalesce(nullif(firebase_uid,''),auth_user_id::text),'firebaseUid',firebase_uid,'authUid',auth_user_id,'email',lower(email),'name',display_name,'role',public.erp_exact_role(role_code),'active',active) order by display_name,email) from public.profiles),'[]'::jsonb));
end $$;

create or replace function public.erp_v9_update_profile(p_user_key text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare p public.profiles%rowtype;v_role text;
begin
  if public.erp_current_exact_role()<>'super_admin' then raise exception 'Solo Super Admin puede modificar perfiles' using errcode='42501'; end if;
  v_role:=public.erp_exact_role(coalesce(p_payload->>'role',''));
  if v_role='' then raise exception 'Rol inválido'; end if;
  update public.profiles set display_name=coalesce(nullif(btrim(p_payload->>'name'),''),display_name),role_code=v_role,active=coalesce(public.erp_try_boolean(p_payload->>'active',active),active),profile_updated_at=now(),raw_profile=coalesce(raw_profile,'{}'::jsonb)||p_payload
  where firebase_uid=p_user_key or auth_user_id::text=p_user_key returning * into p;
  if not found then raise exception 'Perfil no encontrado'; end if;
  insert into public.roles(role_code,role_name,active) values(v_role,v_role,true) on conflict(role_code) do nothing;
  delete from public.user_roles where firebase_uid=p.firebase_uid and is_primary=true;
  insert into public.user_roles(firebase_uid,role_code,is_primary,source) values(p.firebase_uid,v_role,true,'ERP_V9') on conflict(firebase_uid,role_code) do update set is_primary=true,source='ERP_V9';
  return jsonb_build_object('uid',coalesce(nullif(p.firebase_uid,''),p.auth_user_id::text),'email',lower(p.email),'name',p.display_name,'role',v_role,'active',p.active);
end $$;

-- ------------------------------------------------------------
-- DOMINIOS NORMALIZADOS
-- ------------------------------------------------------------
create or replace function public.erp_v9_domain_list(p_domain text,p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_items jsonb;v_total bigint;v_domain text:=public.erp_normalize_key(p_domain);
begin
  if public.erp_current_user_key() is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  if v_domain='novelties' then
    with f as (select * from public.issue_reports x where p_search is null or btrim(p_search)='' or lower(coalesce(x.title,'')||' '||coalesce(x.detail,'')||' '||coalesce(x.case_client,'')) like '%'||lower(btrim(p_search))||'%') select count(*) into v_total from f;
    with f as (select * from public.issue_reports x where p_search is null or btrim(p_search)='' or lower(coalesce(x.title,'')||' '||coalesce(x.detail,'')||' '||coalesce(x.case_client,'')) like '%'||lower(btrim(p_search))||'%' order by x.updated_at desc offset (v_page-1)*v_size limit v_size)
    select coalesce(jsonb_agg(jsonb_build_object('reportId',report_id,'title',title,'category',category,'severity',severity,'status',status,'processCode',process_code,'caseClient',case_client,'detail',detail,'createdAt',created_at,'updatedAt',updated_at) order by updated_at desc),'[]'::jsonb) into v_items from f;
  elsif v_domain='inventory' then
    with f as (select * from public.inventory_chipas x where p_search is null or btrim(p_search)='' or lower(coalesce(x.reference,'')||' '||coalesce(x.description,'')||' '||coalesce(x.client,'')) like '%'||lower(btrim(p_search))||'%') select count(*) into v_total from f;
    with f as (select * from public.inventory_chipas x where p_search is null or btrim(p_search)='' or lower(coalesce(x.reference,'')||' '||coalesce(x.description,'')||' '||coalesce(x.client,'')) like '%'||lower(btrim(p_search))||'%' order by x.updated_at desc offset (v_page-1)*v_size limit v_size)
    select coalesce(jsonb_agg(jsonb_build_object('chipId',chip_id,'reference',reference,'description',description,'warehouse',warehouse,'remaining',remaining,'unit',unit,'status',status,'client',client,'updatedAt',updated_at,'createdAt',created_at) order by updated_at desc),'[]'::jsonb) into v_items from f;
  else raise exception 'Dominio V9 no reconocido: %',p_domain;
  end if;
  return jsonb_build_object('items',coalesce(v_items,'[]'::jsonb),'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',coalesce(v_total,0),'totalPages',case when coalesce(v_total,0)=0 then 0 else ceil(v_total::numeric/v_size)::int end));
end $$;

create or replace function public.erp_v9_novelty_save(p_report_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_uid text:=public.erp_current_user_key();v_role text:=public.erp_current_exact_role();
begin
  if v_uid is null then raise exception 'Usuario ERP no autorizado' using errcode='42501'; end if;
  insert into public.issue_reports(report_id,source_path,source_id,source_type,source_reference,source_module,case_client,title,description,detail,category,severity,status,process_code,process_name,created_by_uid,created_by_name,created_by_role,assigned_role,sales_advisor,managed_by_uid,managed_by_name,created_at,updated_at,visible_roles,raw_data)
  values(p_report_id,'reportes_novedad/'||p_report_id,p_payload->>'sourceId',p_payload->>'sourceType',p_payload->>'sourceReference',coalesce(p_payload->>'sourceModule','ERP_V9'),p_payload->>'caseClient',p_payload->>'title',p_payload->>'description',p_payload->>'detail',p_payload->>'category',p_payload->>'severity',coalesce(p_payload->>'status','OPEN'),p_payload->>'processCode',p_payload->>'processName',v_uid,coalesce(p_payload->>'createdByName',(public.erp_current_profile()).display_name),v_role,p_payload->>'assignedRole',p_payload->>'salesAdvisor',p_payload->>'managedBy',p_payload->>'managedByName',now(),now(),coalesce(p_payload->'visibleRoles','[]'::jsonb),p_payload)
  on conflict(report_id) do update set title=excluded.title,description=excluded.description,detail=excluded.detail,category=excluded.category,severity=excluded.severity,status=excluded.status,process_code=excluded.process_code,updated_at=now(),raw_data=public.issue_reports.raw_data||excluded.raw_data;
  return (select to_jsonb(x) from public.issue_reports x where x.report_id=p_report_id);
end $$;

create or replace function public.erp_v9_inventory_save(p_chip_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_role text:=public.erp_current_exact_role();
begin
  if v_role not in ('super_admin','jefe_logistica','auxiliar_corte','recepcion_mercancia') then raise exception 'Su rol no puede modificar inventario' using errcode='42501'; end if;
  insert into public.inventory_chipas(chip_id,case_id,case_reference,cut_id,cut_code,reference,description,unit,warehouse,available_before,meters_cut,remaining,status,client,purchase_order,source,registered_by_name,created_by_name,created_at,updated_at,raw_data)
  values(p_chip_id,p_payload->>'caseId',p_payload->>'caseReference',p_payload->>'cutId',p_payload->>'cutCode',p_payload->>'reference',p_payload->>'description',coalesce(p_payload->>'unit','M'),p_payload->>'warehouse',public.erp_try_numeric(p_payload->>'availableBefore'),public.erp_try_numeric(p_payload->>'metersCut'),public.erp_try_numeric(p_payload->>'remaining'),coalesce(p_payload->>'status','AVAILABLE'),p_payload->>'client',p_payload->>'purchaseOrder',coalesce(p_payload->>'source','ERP_V9'),coalesce(p_payload->>'registeredByName',(public.erp_current_profile()).display_name),coalesce(p_payload->>'createdByName',(public.erp_current_profile()).display_name),now(),now(),p_payload)
  on conflict(chip_id) do update set reference=excluded.reference,description=excluded.description,unit=excluded.unit,warehouse=excluded.warehouse,remaining=excluded.remaining,status=excluded.status,client=excluded.client,updated_at=now(),raw_data=public.inventory_chipas.raw_data||excluded.raw_data;
  return (select to_jsonb(x) from public.inventory_chipas x where x.chip_id=p_chip_id);
end $$;

-- ------------------------------------------------------------
-- RECEPCIÓN DE MERCANCÍA Y STICKERS
-- ------------------------------------------------------------
create or replace function public.erp_v9_goods_list(p_kind text default 'receipts',p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_role text:=public.erp_current_exact_role();v_collection text;v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_total bigint;v_items jsonb;
begin
  if v_role not in ('super_admin','gerencia','compras','recepcion_mercancia','jefe_logistica','auditoria') then raise exception 'Su rol no puede consultar recepción de mercancía' using errcode='42501'; end if;
  v_collection:=case public.erp_normalize_key(p_kind) when 'receipts' then 'recepciones_mercancia' when 'stickers' then 'recepcion_stickers' else null end;
  if v_collection is null then raise exception 'Tipo de registro inválido'; end if;
  with f as (select * from public.erp_documents d where d.collection_name=v_collection and (p_search is null or btrim(p_search)='' or lower(d.document_id||' '||coalesce(d.raw_data::text,'')) like '%'||lower(btrim(p_search))||'%')) select count(*) into v_total from f;
  with f as (select * from public.erp_documents d where d.collection_name=v_collection and (p_search is null or btrim(p_search)='' or lower(d.document_id||' '||coalesce(d.raw_data::text,'')) like '%'||lower(btrim(p_search))||'%') order by d.updated_at desc offset (v_page-1)*v_size limit v_size)
  select coalesce(jsonb_agg(jsonb_build_object('documentId',document_id,'createdAt',created_at,'updatedAt',updated_at)||coalesce(raw_data,'{}'::jsonb) order by updated_at desc),'[]'::jsonb) into v_items from f;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end));
end $$;

create or replace function public.erp_v9_goods_save(p_kind text,p_document_id text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_role text:=public.erp_current_exact_role();v_uid text:=public.erp_current_user_key();v_collection text;v_data jsonb;
begin
  if v_role not in ('super_admin','compras','recepcion_mercancia','jefe_logistica') then raise exception 'Su rol no puede registrar recepción o stickers' using errcode='42501'; end if;
  v_collection:=case public.erp_normalize_key(p_kind) when 'receipts' then 'recepciones_mercancia' when 'stickers' then 'recepcion_stickers' else null end;
  if v_collection is null then raise exception 'Tipo de registro inválido'; end if;
  if coalesce(btrim(p_document_id),'')='' then raise exception 'Identificador inválido'; end if;
  v_data:=coalesce(p_payload,'{}'::jsonb)||jsonb_build_object('id',p_document_id,'documentId',p_document_id,'updatedAt',now(),'updatedByUid',v_uid,'updatedByName',(public.erp_current_profile()).display_name);
  if not exists(select 1 from public.erp_documents where collection_name=v_collection and document_id=p_document_id) then v_data:=v_data||jsonb_build_object('createdAt',coalesce(v_data->'createdAt',to_jsonb(now())),'createdByUid',v_uid,'createdByName',(public.erp_current_profile()).display_name); end if;
  insert into public.erp_documents(collection_name,document_id,raw_data,created_by_uid,updated_by_uid)
  values(v_collection,p_document_id,v_data,v_uid,v_uid)
  on conflict(collection_name,document_id) do update set raw_data=public.erp_documents.raw_data||excluded.raw_data,updated_at=now(),updated_by_uid=v_uid
  returning raw_data into v_data;
  return v_data;
end $$;

-- ------------------------------------------------------------
-- VSM Y AUDITORÍA
-- ------------------------------------------------------------
create or replace function public.erp_v9_vsm(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_items jsonb;v_total bigint;
begin
  if public.erp_current_exact_role() not in ('super_admin','gerencia','jefe_logistica','auditoria') then raise exception 'Su rol no puede consultar VSM' using errcode='42501'; end if;
  with f as (select s.*,c.reference,c.client from public.case_process_stats s join public.cases c on c.case_id=s.case_id where public.erp_case_id_visible(s.case_id) and (p_search is null or btrim(p_search)='' or lower(coalesce(c.reference,'')||' '||coalesce(c.client,'')) like '%'||lower(btrim(p_search))||'%')) select count(*) into v_total from f;
  with f as (select s.*,c.reference,c.client from public.case_process_stats s join public.cases c on c.case_id=s.case_id where public.erp_case_id_visible(s.case_id) and (p_search is null or btrim(p_search)='' or lower(coalesce(c.reference,'')||' '||coalesce(c.client,'')) like '%'||lower(btrim(p_search))||'%') order by coalesce(s.completed_at,s.started_at) desc offset (v_page-1)*v_size limit v_size)
  select coalesce(jsonb_agg(jsonb_build_object('caseId',case_id,'reference',reference,'client',client,'process',process_code,'startedAt',started_at,'endedAt',completed_at,'activeHours',round(coalesce(active_ms,0)::numeric/3600000,2),'waitHours',round(coalesce(wait_ms,0)::numeric/3600000,2),'deadHours',round(coalesce(dead_ms,0)::numeric/3600000,2)) order by coalesce(completed_at,started_at) desc),'[]'::jsonb) into v_items from f;
  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total));
end $$;

create or replace function public.erp_v9_audit(p_search text default null,p_page integer default 1,p_page_size integer default 50)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_page int:=greatest(coalesce(p_page,1),1);v_size int:=least(greatest(coalesce(p_page_size,50),1),100);v_items jsonb;
begin
  if public.erp_current_exact_role() not in ('super_admin','gerencia','auditoria') then raise exception 'Su rol no puede consultar auditoría' using errcode='42501'; end if;
  with f as (select * from public.case_events x where p_search is null or btrim(p_search)='' or lower(coalesce(x.case_reference,'')||' '||coalesce(x.detail,'')||' '||coalesce(x.event_type,'')) like '%'||lower(btrim(p_search))||'%' order by x.timestamp desc offset (v_page-1)*v_size limit v_size)
  select coalesce(jsonb_agg(jsonb_build_object('eventId',event_id,'caseId',case_id,'caseReference',case_reference,'eventType',event_type,'detail',detail,'createdByName',created_by_name,'createdByRole',created_by_role,'timestamp',timestamp) order by timestamp desc),'[]'::jsonb) into v_items from f;
  return jsonb_build_object('items',v_items);
end $$;

-- ------------------------------------------------------------
-- DIAGNÓSTICO V9
-- ------------------------------------------------------------
create or replace function public.erp_v9_health()
returns jsonb language plpgsql volatile security definer set search_path=public as $$
declare checks jsonb:='[]'::jsonb;v_count bigint;
begin
  if public.erp_current_exact_role() not in ('super_admin','gerencia','auditoria') then raise exception 'Su rol no puede ejecutar diagnóstico' using errcode='42501'; end if;
  select count(*) into v_count from public.cases;checks:=checks||jsonb_build_array(jsonb_build_object('name','Pedidos existentes','ok',v_count>0,'detail',v_count||' pedidos'));
  select count(*) into v_count from public.profiles where active=true and auth_user_id is not null;checks:=checks||jsonb_build_array(jsonb_build_object('name','Usuarios activos vinculados','ok',v_count>0,'detail',v_count||' usuarios'));
  checks:=checks||jsonb_build_array(jsonb_build_object('name','API V9 de sesión','ok',to_regprocedure('public.erp_v9_session()') is not null));
  checks:=checks||jsonb_build_array(jsonb_build_object('name','API V9 de pedidos','ok',to_regprocedure('public.erp_v9_cases(text,text[],text,text,text,text,text,integer,integer)') is not null));
  checks:=checks||jsonb_build_array(jsonb_build_object('name','Ejecutor operativo V9','ok',to_regprocedure('public.erp_v9_execute(text,text,jsonb)') is not null));
  checks:=checks||jsonb_build_array(jsonb_build_object('name','API V9 de mercancía','ok',to_regprocedure('public.erp_v9_goods_list(text,text,integer,integer)') is not null));
  checks:=checks||jsonb_build_array(jsonb_build_object('name','Google Drive','ok',true,'detail','La conexión se valida desde el navegador con OAuth.'));
  return jsonb_build_object('checks',checks,'generatedAt',now(),'version','9.0.0');
end $$;

-- ------------------------------------------------------------
-- PERMISOS: solo la API V9 se expone al navegador nuevo.
-- No se revocan permisos de V8 en este script.
-- ------------------------------------------------------------
do $$
declare f record;
begin
  for f in select p.oid::regprocedure sig from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname like 'erp_v9_%'
  loop execute format('revoke all on function %s from public, anon, authenticated',f.sig); end loop;
end $$;

grant execute on function public.erp_v9_session() to authenticated;
grant execute on function public.erp_v9_catalog() to authenticated;
grant execute on function public.erp_v9_dashboard() to authenticated;
grant execute on function public.erp_v9_cases(text,text[],text,text,text,text,text,integer,integer) to authenticated;
grant execute on function public.erp_v9_case_detail(text) to authenticated;
grant execute on function public.erp_v9_case_actions(text) to authenticated;
grant execute on function public.erp_v9_execute(text,text,jsonb) to authenticated;
grant execute on function public.erp_v9_workflows(text,text,text,text,integer,integer) to authenticated;
grant execute on function public.erp_v9_credit_list(text,text,integer,integer) to authenticated;
grant execute on function public.erp_v9_credit_save(text,jsonb) to authenticated;
grant execute on function public.erp_v9_credit_transition(text,text,jsonb) to authenticated;
grant execute on function public.erp_v9_profiles() to authenticated;
grant execute on function public.erp_v9_update_profile(text,jsonb) to authenticated;
grant execute on function public.erp_v9_domain_list(text,text,integer,integer) to authenticated;
grant execute on function public.erp_v9_novelty_save(text,jsonb) to authenticated;
grant execute on function public.erp_v9_inventory_save(text,jsonb) to authenticated;
grant execute on function public.erp_v9_goods_list(text,text,integer,integer) to authenticated;
grant execute on function public.erp_v9_goods_save(text,text,jsonb) to authenticated;
grant execute on function public.erp_v9_vsm(text,integer,integer) to authenticated;
grant execute on function public.erp_v9_audit(text,integer,integer) to authenticated;
grant execute on function public.erp_v9_health() to authenticated;

commit;

-- Verificación rápida
select
  to_regprocedure('public.erp_v9_session()') as api_sesion,
  to_regprocedure('public.erp_v9_cases(text,text[],text,text,text,text,text,integer,integer)') as api_pedidos,
  to_regprocedure('public.erp_v9_execute(text,text,jsonb)') as api_escritura,
  has_function_privilege('authenticated','public.erp_v9_session()','EXECUTE') as auth_sesion,
  has_function_privilege('authenticated','public.erp_v9_execute(text,text,jsonb)','EXECUTE') as auth_escritura,
  has_function_privilege('anon','public.erp_v9_execute(text,text,jsonb)','EXECUTE') as anon_escritura;
