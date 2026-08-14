-- ERP ELECTROINGENIERIA V10.33.1
-- Un reintento con la misma idempotency_key se reconoce antes de comparar versión.
create or replace function public.erp_x_execute_action(
  p_order_id uuid,
  p_action_code text,
  p_payload jsonb default '{}'::jsonb,
  p_expected_version integer default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'erp_supply','public','auth','pg_catalog'
as $function$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_action text:=upper(trim(coalesce(p_action_code,'')));
  v_type text;
  v_assigned text;
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=erp_supply.current_org_id()
    and erp_supply.can_view_order_or_reception_shadow(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;

  if p_idempotency_key is not null and exists(
    select 1
    from erp_supply.order_events e
    where e.organization_id=v_order.organization_id
      and e.order_id=v_order.id
      and e.idempotency_key=p_idempotency_key
  ) then
    return jsonb_build_object(
      'success',true,'idempotent',true,'orderId',v_order.id,'orderNumber',v_order.order_number,
      'status',v_order.status,'currentStep',v_order.current_step_code,'version',v_order.version,
      'contractVersion','10.33.1'
    );
  end if;

  if v_action in('CLAIM','START','RESUME','COMPLETE') and exists(
    select 1 from erp_supply.order_issues i
    where i.order_id=p_order_id and i.blocking and i.status='OPEN'
  ) then
    raise exception 'El pedido está en espera por una novedad o reporte. Debes solucionar y cerrar la gestión antes de continuar.';
  end if;

  if v_action='NO_DELIVERY' and not (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then
    raise exception 'Solo Ventas o Superadministración pueden registrar una no entrega' using errcode='42501';
  end if;
  if v_action='REPROGRAM' and not erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
    raise exception 'No autorizado para reprogramar' using errcode='42501';
  end if;

  if v_action='REQUEST_APPROVAL' then
    if erp_supply.profile_is_read_only_auditor(v_actor) then
      raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
    end if;
    v_type:=upper(trim(coalesce(p_payload->>'requestType','')));
    if v_type='CANCELLATION' then
      raise exception 'La cancelación se solicita desde el botón Solicitar cancelación';
    end if;
    v_assigned:=coalesce(nullif(trim(p_payload->>'assignedRole'),''),'jefe_logistica');
    if v_type not in('PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then
      raise exception 'Tipo de solicitud inválido';
    end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if not exists(
      select 1 from erp_supply.role_module_permissions rmp
      where rmp.role_code=v_assigned and rmp.module_code='approvals' and rmp.can_approve
    ) then
      raise exception 'El rol seleccionado no puede decidir aprobaciones';
    end if;
    if v_type='PRIORITY'
       and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then
      raise exception 'Prioridad inválida';
    end if;
    if v_type='ROUTE_CHANGE'
       and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then
      raise exception 'Ruta inválida';
    end if;
  end if;

  return erp_supply.execute_action_internal(
    p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,
    p_expected_version,p_idempotency_key
  );
end;
$function$;
revoke all on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) from public,anon;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated,service_role;
