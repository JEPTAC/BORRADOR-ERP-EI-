-- ERP Supply Enterprise V10
-- Migration 015: strict approval lifecycle, canonical approvers and safe execution.

begin;

create or replace function public.erp_x_execute_action(
  p_order_id uuid,p_action_code text,p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_action text:=upper(trim(coalesce(p_action_code,'')));
  v_type text;
  v_payload jsonb:=coalesce(p_payload,'{}'::jsonb);
  v_route text;
  v_assigned_role text;
begin
  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;

  if v_action='NO_DELIVERY' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
    raise exception 'No autorizado para registrar no entrega' using errcode='42501';
  end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
    raise exception 'No autorizado para reprogramar' using errcode='42501';
  end if;

  if v_action='REQUEST_APPROVAL' then
    v_type:=upper(trim(coalesce(v_payload->>'requestType','')));
    if v_type not in('CANCELLATION','PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then
      raise exception 'Tipo de solicitud inválido';
    end if;
    if nullif(trim(v_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if exists(select 1 from erp_supply.approval_requests where order_id=p_order_id and request_type=v_type and status='PENDING') then
      raise exception 'Ya existe una solicitud pendiente del mismo tipo';
    end if;

    if v_type in('CANCELLATION','PRIORITY','ROUTE_CHANGE','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION')
       and v_order.status in('CLOSED','CANCELLED') then
      raise exception 'La solicitud % solo aplica a pedidos activos',v_type;
    end if;
    if v_type='REOPEN' and v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
    if v_type='PRIORITY' and upper(coalesce(v_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then
      raise exception 'Prioridad inválida';
    end if;
    if v_type='ROUTE_CHANGE' then
      v_route:=upper(coalesce(v_payload->>'route',''));
      if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta inválida'; end if;
      if v_route=v_order.delivery_route_code then raise exception 'La nueva ruta debe ser diferente de la actual'; end if;
      if v_order.current_step_code in('CLOSURE','CLOSED') then raise exception 'No se puede cambiar la ruta después de la entrega'; end if;
      v_payload:=v_payload||jsonb_build_object('route',v_route);
    end if;

    v_assigned_role:=case
      when v_type='PAYMENT_EXCEPTION' then 'gerencia'
      else 'jefe_logistica'
    end;
    v_payload:=v_payload||jsonb_build_object('requestType',v_type,'assignedRole',v_assigned_role);
  end if;

  return erp_supply.execute_action_internal(p_order_id,v_action,v_payload,v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

create or replace function public.erp_x_decide_approval(p_request_id uuid,p_decision text,p_reason text)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
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
  select * into v_req from erp_supply.approval_requests
  where id=p_request_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Solicitud no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud ya fue decidida'; end if;
  if v_dec not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
  if not (v_req.assigned_profile_id=v_actor or v_req.assigned_role_code=any(v_roles)
      or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')) then
    raise exception 'No autorizado para decidir' using errcode='42501';
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
        set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
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
        update erp_supply.orders set priority=upper(v_req.request_payload->>'priority'),version=version+1
        where id=v_order.id returning * into v_order;

      when 'ROUTE_CHANGE' then
        if v_order.status in('CLOSED','CANCELLED') then raise exception 'El pedido ya está finalizado'; end if;
        v_route:=upper(v_req.request_payload->>'route');
        if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta aprobada inválida'; end if;
        if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
          select * into v_old_task from erp_supply.order_tasks
          where order_id=v_order.id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
          order by sequence_no desc limit 1 for update;
          update erp_supply.task_sessions s set ended_at=v_now,
            raw_seconds=greatest(0,extract(epoch from(v_now-s.started_at))::bigint),
            business_seconds=erp_supply.business_seconds_between(v_order.organization_id,s.started_at,v_now),
            note=coalesce(s.note,'')||case when s.note is null then '' else ' · ' end||'Cerrada por cambio de ruta'
          where s.task_id=v_old_task.id and s.ended_at is null;
          update erp_supply.order_tasks set status='CANCELLED',completed_at=v_now,result_code='ROUTE_CHANGED'
          where id=v_old_task.id;
          v_next_sequence:=coalesce(v_old_task.sequence_no,0)+1;
          update erp_supply.orders set delivery_route_code=v_route,current_step_code=v_route,status='QUEUED',
            current_assignee_id=null,current_role_code=null,version=version+1
          where id=v_order.id returning * into v_order;
          perform erp_supply.create_task(v_order,v_route,v_next_sequence);
          select * into v_order from erp_supply.orders where id=v_order.id;
        else
          update erp_supply.orders set delivery_route_code=v_route,version=version+1
          where id=v_order.id returning * into v_order;
        end if;

      when 'REOPEN' then
        if v_order.status<>'CLOSED' then raise exception 'Solo se pueden reabrir pedidos cerrados'; end if;
        v_next_sequence:=(select coalesce(max(sequence_no),0)+1 from erp_supply.order_tasks where order_id=v_order.id);
        update erp_supply.orders set status='QUEUED',closed_at=null,current_step_code='CLOSURE',
          current_assignee_id=null,current_role_code=null,version=version+1
        where id=v_order.id returning * into v_order;
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

  insert into erp_supply.order_events(organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload)
  values(v_req.organization_id,v_req.order_id,'APPROVAL_DECISION',v_dec,v_before_step,v_order.current_step_code,
    v_before_status,v_order.status,v_actor,(v_roles)[1],jsonb_build_object('requestId',v_req.id,'requestType',v_req.request_type,'reason',p_reason,'finalRequestStatus',v_final_status));

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata)
  values(v_req.organization_id,v_actor,'APPROVAL_'||v_dec,'APPROVAL_REQUEST',v_req.id::text,
    jsonb_build_object('status','PENDING'),jsonb_build_object('status',v_final_status,'orderStatus',v_order.status,'orderVersion',v_order.version),
    jsonb_build_object('requestType',v_req.request_type,'reason',p_reason));

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_req.organization_id,'APPROVAL_DECIDED','ORDER',v_order.id,
    jsonb_build_object('requestId',v_req.id,'decision',v_dec,'requestType',v_req.request_type,'orderNumber',v_order.order_number));

  return jsonb_build_object('success',true,'requestId',v_req.id,'decision',v_dec,'requestStatus',v_final_status,
    'orderId',v_order.id,'orderStatus',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version);
end;
$$;

revoke all on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) from public,anon,authenticated;
revoke all on function public.erp_x_decide_approval(uuid,text,text) from public,anon,authenticated;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;
grant execute on function public.erp_x_decide_approval(uuid,text,text) to authenticated;

commit;
