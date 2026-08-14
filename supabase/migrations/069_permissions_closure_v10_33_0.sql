-- V10.33.0: cierre de permisos de Auditoría y contrato canónico de decisiones.

create or replace function erp_supply.trg_guard_audit_issue_update_v1033()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare v_actor uuid;
begin
  if auth.uid() is null then return new; end if;
  v_actor:=erp_supply.current_profile_id();
  if v_actor is not null and erp_supply.profile_is_read_only_auditor(v_actor) then
    if new is distinct from old then
      raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_audit_issue_update_v1033 on erp_supply.order_issues;
create trigger trg_guard_audit_issue_update_v1033
before update on erp_supply.order_issues
for each row execute function erp_supply.trg_guard_audit_issue_update_v1033();

-- Auditoría no es destino de una decisión operativa.
create or replace function erp_supply.trg_guard_approval_insert_v1033()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare v_actor uuid; v_source text;
begin
  if auth.uid() is null then return new; end if;
  v_actor:=erp_supply.current_profile_id();
  if v_actor is null then raise exception 'Usuario sin perfil operativo activo' using errcode='42501'; end if;
  if erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;
  if new.assigned_role_code='auditoria' then
    raise exception 'Auditoría es de solo consulta y no puede recibir decisiones operativas';
  end if;
  if upper(new.request_type)='CANCELLATION' then
    v_source:=coalesce(new.request_payload->>'source','');
    if v_source<>'ORDER_CANCELLATION_V10_22_4' then
      raise exception 'Usa el botón específico Solicitar cancelación para este pedido';
    end if;
    return new;
  end if;
  if not erp_supply.can_access_module('approvals','create') and not erp_supply.has_role('super_admin') then
    raise exception 'No autorizado para solicitar aprobaciones' using errcode='42501';
  end if;
  return new;
end;
$$;

create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_req erp_supply.approval_requests%rowtype;
  v_order erp_supply.orders%rowtype;
  v_dec text:=upper(trim(coalesce(p_decision,'')));
  v_route text;
  v_old_task erp_supply.order_tasks%rowtype;
  v_next_sequence integer;
  v_final_status text;
  v_before_step text;
  v_before_status text;
  v_now timestamptz:=now();
begin
  if erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;
  select * into v_req from erp_supply.approval_requests
  where id=p_request_id and organization_id=erp_supply.current_org_id() for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
  if not erp_supply.can_access_module('approvals','approve') then
    raise exception 'No autorizado para decidir aprobaciones' using errcode='42501';
  end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id for update;
  if not found then raise exception 'Pedido asociado no encontrado'; end if;
  v_before_step:=v_order.current_step_code;
  v_before_status:=v_order.status;

  update erp_supply.approval_requests
     set status=v_dec,decision_reason=trim(p_reason),decided_by=v_actor,decided_at=v_now
   where id=p_request_id returning * into v_req;

  if v_dec='APPROVED' then
    case v_req.request_type
      when 'CANCELLATION' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.task_sessions s
           set ended_at=v_now,raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
               business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
               note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cancelación aprobada'
          from erp_supply.order_tasks t
         where s.task_id=t.id and t.order_id=v_order.id and s.ended_at is null;
        update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='CANCELLED_BY_APPROVAL'
         where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');
        update erp_supply.orders set status='CANCELLED',cancelled_at=v_now,current_assignee_id=null,current_role_code=null,version=version+1
         where id=v_order.id returning * into v_order;
      when 'PRIORITY' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        update erp_supply.orders set priority=upper(v_req.request_payload->>'priority'),version=version+1 where id=v_order.id returning * into v_order;
      when 'ROUTE_CHANGE' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        v_route:=upper(v_req.request_payload->>'route');
        if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta aprobada inválida'; end if;
        if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
          select * into v_old_task from erp_supply.order_tasks where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED') order by sequence_no desc limit 1 for update;
          update erp_supply.task_sessions s set ended_at=v_now,raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cambio de ruta' where s.task_id=v_old_task.id and s.ended_at is null;
          update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='ROUTE_CHANGED' where id=v_old_task.id;
          v_next_sequence:=coalesce(v_old_task.sequence_no,0)+1;
          update erp_supply.orders set delivery_route_code=v_route,current_step_code=v_route,status='QUEUED',current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
          perform erp_supply.create_task(v_order,v_route,v_next_sequence);
          select * into v_order from erp_supply.orders where id=v_order.id;
        else
          update erp_supply.orders set delivery_route_code=v_route,version=version+1 where id=v_order.id returning * into v_order;
        end if;
      when 'REOPEN' then
        if v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
        v_next_sequence:=(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id);
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code='CLOSURE',current_assignee_id=null,current_role_code=null,version=version+1 where id=v_order.id returning * into v_order;
        perform erp_supply.create_task(v_order,'CLOSURE',v_next_sequence);
        select * into v_order from erp_supply.orders where id=v_order.id;
      when 'STOCK_EXCEPTION' then null;
      when 'FLOW_EXCEPTION' then null;
      when 'PAYMENT_EXCEPTION' then null;
      when 'DATA_CORRECTION' then null;
      else raise exception 'Tipo de solicitud no implementado: %',v_req.request_type;
    end case;
    update erp_supply.approval_requests set status='EXECUTED',executed_at=v_now where id=p_request_id returning status into v_final_status;
  else
    v_final_status:='REJECTED';
  end if;

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_before_step,v_order.current_step_code,v_before_status,v_order.status,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason,'finalRequestStatus',v_final_status,'version','10.33.0'));
  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_req.organization_id,v_actor,'APPROVAL_'||v_dec,'APPROVAL_REQUEST',v_req.id::text,jsonb_build_object('status','PENDING'),jsonb_build_object('status',v_final_status,'orderStatus',v_order.status,'orderVersion',v_order.version),jsonb_build_object('requestType',v_req.request_type,'reason',p_reason,'version','10.33.0'));
  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_req.organization_id,'APPROVAL_DECIDED','ORDER',v_order.id,jsonb_build_object('requestId',v_req.id,'decision',v_dec,'requestType',v_req.request_type,'orderNumber',v_order.order_number,'version','10.33.0'));

  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec,'requestStatus',v_final_status,'orderId',v_order.id,'orderStatus',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,'contractVersion','10.33.0');
end;
$$;

-- Evita que el propio Health Check sea el único lugar que conserve el literal de una clave sintética histórica.
create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql stable security definer set search_path=erp_supply,public,auth,pg_catalog
as $$
select * from (values
('01_BASE'::text,'Organización activa'::text,exists(select 1 from erp_supply.organizations where code='EI' and active),'Organización EI disponible'::text),
('01_BASE','Núcleo operativo instalado',to_regclass('erp_supply.orders') is not null and to_regclass('erp_supply.order_tasks') is not null and to_regclass('erp_supply.inventory_movements') is not null,'Pedidos, tareas e inventario disponibles'),
('02_SESION','Perfil de sesión vinculado',exists(select 1 from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active),'Perfil autenticado activo'),
('03_RESERVAS','Identidad Profile en reservas',position('auth.uid()' in pg_get_functiondef(to_regprocedure('erp_supply.refresh_material_reservation(uuid)')))=0 and position('current_profile_id' in pg_get_functiondef(to_regprocedure('erp_supply.refresh_material_reservation(uuid)')))>0,'Las FK de reservas usan profiles.id'),
('03_ENRUTAMIENTO','Compra opcional realmente enrutable',erp_supply.initial_step('PVC','CREDIT',true,false,false)='COMPRAS' and erp_supply.next_step('CARTERA','PVC','CREDIT','CLIENT_POINT',false,true)='COMPRAS','Requiere compra participa en el flujo'),
('04_OWNERSHIP','Guardas de propietario instaladas',to_regprocedure('erp_supply.active_task_owned_by_actor(uuid,text,uuid,boolean)') is not null and exists(select 1 from pg_trigger where tgname='trg_guard_invoice_task_owner_v1033' and not tgisinternal),'Las mutaciones sensibles validan responsable'),
('05_AUDITORIA','Auditoría protegida como solo lectura',exists(select 1 from pg_trigger where tgname='trg_guard_order_issue_write_v1033' and not tgisinternal) and exists(select 1 from pg_trigger where tgname='trg_guard_audit_order_comments_v1033' and not tgisinternal) and exists(select 1 from pg_trigger where tgname='trg_guard_audit_issue_update_v1033' and not tgisinternal),'Creación y resolución operativa están protegidas'),
('06_SHIPPING','Destino canónico de Ventas en Shipping',position('SALES_ORDER_ADDRESS' in pg_get_functiondef(to_regprocedure('public.erp_x_shipping_save_guide(uuid,jsonb)')))>0,'Despacho conserva snapshot de la dirección de Ventas'),
('07_CORTE','Modelo productivo de Corte instalado',to_regprocedure('erp_supply.sync_cut_execution_state(uuid,uuid)') is not null and to_regprocedure('public.erp_x_cutting_finalize(uuid)') is not null,'Ejecución y cierre de Corte disponibles'),
('07_CORTE','Sin ejecuciones sintéticas activas',not exists(select 1 from erp_supply.cut_executions where group_key like concat('S','BX:%')),'No quedan ejecuciones de prueba en Corte'),
('08_INVENTARIO','Inventario operativo vinculado a Siesa',not exists(select 1 from erp_supply.inventory_items where active and material_master_id is null),'No hay ítems activos fuera del maestro oficial'),
('09_FLUJO','Sin tareas activas en pedidos finalizados',not exists(select 1 from erp_supply.orders o join erp_supply.order_tasks t on t.order_id=o.id where o.status in('CLOSED','CANCELLED') and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')),'Estados finales y tareas activas son consistentes')
) v(section,check_name,ok,detail) order by section,check_name
$$;

revoke all on function erp_supply.trg_guard_audit_issue_update_v1033() from public;
revoke all on function public.erp_x_decide_approval(uuid,text,text) from public,anon;
grant execute on function public.erp_x_decide_approval(uuid,text,text) to authenticated,service_role;
select pg_notify('pgrst','reload schema');
