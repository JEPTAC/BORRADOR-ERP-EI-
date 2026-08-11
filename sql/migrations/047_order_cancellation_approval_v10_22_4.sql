-- ERP EI V10.22.4
-- Cancelación de pedidos por solicitud: cualquier usuario con visibilidad puede solicitarla
-- con nota obligatoria y únicamente Jefatura Logística puede decidirla.

begin;

-- ---------------------------------------------------------------------------
-- 1. INVARIANTE: TODA CANCELACIÓN LIMPIA LOS ARTEFACTOS OPERATIVOS DEL PEDIDO
-- ---------------------------------------------------------------------------
create or replace function erp_supply.trg_cleanup_cancelled_order()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.current_profile_id();
  v_exec_id uuid;
begin
  if new.status<>'CANCELLED' or old.status is not distinct from new.status then
    return new;
  end if;

  -- Cierra cualquier sesión y tarea que hubiera quedado activa.
  update erp_supply.task_sessions s
  set ended_at=coalesce(s.ended_at,now()),
      raw_seconds=case when s.ended_at is null then greatest(0,extract(epoch from(now()-s.started_at))::bigint) else s.raw_seconds end,
      business_seconds=case when s.ended_at is null then erp_supply.business_seconds_between(new.organization_id,s.started_at,now()) else s.business_seconds end,
      note=concat_ws(' · ',nullif(s.note,''),'Cerrada por cancelación del pedido')
  from erp_supply.order_tasks t
  where s.task_id=t.id
    and t.order_id=new.id
    and s.ended_at is null;

  update erp_supply.order_tasks
  set status='CANCELLED',
      completed_at=coalesce(completed_at,now()),
      result_code='CANCELLED_BY_APPROVAL',
      result_detail=coalesce(nullif(result_detail,''),'Pedido cancelado por autorización de Jefatura Logística')
  where order_id=new.id
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED');

  -- Cualquier incidencia abierta deja de bloquear una operación que ya no existe.
  update erp_supply.order_issues
  set status='CLOSED',
      resolved_by=coalesce(resolved_by,v_actor),
      resolved_at=coalesce(resolved_at,now()),
      resolution=coalesce(nullif(resolution,''),'Pedido cancelado'),
      resolution_code=coalesce(nullif(resolution_code,''),'CANCELLED'),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'closedByOrderCancellation',true,
        'closedAt',now(),
        'version','10.22.4'
      )
  where order_id=new.id and status='OPEN';

  -- Los cortes de este pedido dejan de ser trabajo físico pendiente. NO_CUT es
  -- la resolución canónica y COLLECTED evita que un pedido cancelado reaparezca
  -- como corte por recoger.
  update erp_supply.cut_requirements
  set process_status='READY',
      resolution_code='NO_CUT',
      collection_status='COLLECTED',
      ready_at=coalesce(ready_at,now()),
      ready_by=coalesce(ready_by,v_actor),
      collected_at=coalesce(collected_at,now()),
      collected_by=coalesce(collected_by,v_actor),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
        'cancelledOrder',true,
        'cancelledOrderId',new.id,
        'cancelledAt',coalesce(new.cancelled_at,now()),
        'cancelledWithoutCollection',true,
        'version','10.22.4'
      ),
      updated_at=now()
  where order_id=new.id
    and (process_status<>'READY' or collection_status<>'COLLECTED' or coalesce(resolution_code,'')<>'NO_CUT');

  -- Si el pedido estaba congelado dentro de una ejecución de Corte, se retira
  -- únicamente su requerimiento. Una ejecución compartida continúa con los demás.
  for v_exec_id in
    select distinct e.id
    from erp_supply.cut_execution_requirements er
    join erp_supply.cut_executions e on e.id=er.execution_id
    where er.order_id=new.id
      and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE')
  loop
    if not exists(
      select 1
      from erp_supply.cut_execution_requirements er2
      join erp_supply.orders o2 on o2.id=er2.order_id
      where er2.execution_id=v_exec_id
        and o2.status not in('CLOSED','CANCELLED')
    ) and not exists(
      select 1 from erp_supply.cut_batches b where b.execution_id=v_exec_id
    ) then
      update erp_supply.cut_execution_pauses
      set ended_at=coalesce(ended_at,now()),
          ended_by=coalesce(ended_by,v_actor),
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('closedByOrderCancellation',true,'version','10.22.4')
      where execution_id=v_exec_id and ended_at is null;

      update erp_supply.cut_executions
      set status='CANCELLED',
          completed_by=coalesce(completed_by,v_actor),
          completed_at=coalesce(completed_at,now()),
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'cancelledBecauseAllOrdersCancelled',true,
            'cancelledAt',now(),
            'version','10.22.4'
          ),
          updated_at=now()
      where id=v_exec_id;
    else
      perform erp_supply.sync_cut_execution_state(v_exec_id,v_actor);
    end if;
  end loop;

  -- Otras aprobaciones pendientes pierden objeto al cancelarse el pedido.
  update erp_supply.approval_requests
  set status='CANCELLED',
      decision_reason=coalesce(decision_reason,'Pedido cancelado'),
      decided_by=coalesce(decided_by,v_actor),
      decided_at=coalesce(decided_at,now())
  where order_id=new.id and status='PENDING';

  update erp_supply.operational_alerts
  set status='CLOSED',closed_at=coalesce(closed_at,now())
  where order_id=new.id and status<>'CLOSED';

  return new;
end;
$$;

revoke all on function erp_supply.trg_cleanup_cancelled_order() from public;
drop trigger if exists trg_cleanup_cancelled_order on erp_supply.orders;
create trigger trg_cleanup_cancelled_order
after update of status on erp_supply.orders
for each row
when (old.status is distinct from new.status and new.status='CANCELLED')
execute function erp_supply.trg_cleanup_cancelled_order();

-- ---------------------------------------------------------------------------
-- 2. PROTECCIÓN TRANSVERSAL: CANCELLATION SOLO LA DECIDE JEFE LOGÍSTICO
-- ---------------------------------------------------------------------------
create or replace function erp_supply.trg_guard_cancellation_decision()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
begin
  if old.request_type='CANCELLATION'
     and old.status='PENDING'
     and new.status is distinct from old.status
     and new.status in('APPROVED','REJECTED','EXECUTED')
     and auth.uid() is not null
     and not erp_supply.has_role('jefe_logistica') then
    raise exception 'Solo Jefatura Logística puede decidir la cancelación de un pedido' using errcode='42501';
  end if;
  return new;
end;
$$;

revoke all on function erp_supply.trg_guard_cancellation_decision() from public;
drop trigger if exists trg_guard_cancellation_decision on erp_supply.approval_requests;
create trigger trg_guard_cancellation_decision
before update of status on erp_supply.approval_requests
for each row execute function erp_supply.trg_guard_cancellation_decision();

-- ---------------------------------------------------------------------------
-- 3. SOLICITUD DEDICADA: DISPONIBLE PARA TODO USUARIO QUE PUEDA VER EL PEDIDO
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_request_order_cancellation(
  p_order_id uuid,
  p_note text
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_req erp_supply.approval_requests%rowtype;
  v_note text:=trim(coalesce(p_note,''));
  v_roles text[]:=erp_supply.current_roles();
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id
    and organization_id=v_org
    and erp_supply.can_view_order_or_reception_shadow(id)
  for update;

  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;
  if v_order.is_test then raise exception 'Los pedidos Sandbox no usan la aprobación productiva de cancelación'; end if;
  if v_order.status in('CLOSED','CANCELLED') then raise exception 'Solo se puede solicitar la cancelación de un pedido activo'; end if;
  if v_note='' then raise exception 'Debe registrar la nota de cancelación'; end if;
  if length(v_note)>1000 then raise exception 'La nota de cancelación no puede superar 1000 caracteres'; end if;

  if exists(
    select 1 from erp_supply.approval_requests
    where order_id=v_order.id and request_type='CANCELLATION' and status='PENDING'
  ) then
    raise exception 'Este pedido ya tiene una solicitud de cancelación pendiente';
  end if;

  insert into erp_supply.approval_requests(
    organization_id,order_id,request_type,requested_by,assigned_role_code,reason,request_payload
  ) values(
    v_org,v_order.id,'CANCELLATION',v_actor,'jefe_logistica',v_note,
    jsonb_build_object(
      'requestType','CANCELLATION',
      'assignedRole','jefe_logistica',
      'note',v_note,
      'requestedStep',v_order.current_step_code,
      'requestedStatus',v_order.status,
      'requestedVersion',v_order.version,
      'source','ORDER_CANCELLATION_V10_22_4',
      'requestedAt',now()
    )
  ) returning * into v_req;

  insert into erp_supply.order_events(
    organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,'APPROVAL_REQUEST','REQUEST_CANCELLATION',
    v_order.current_step_code,v_order.current_step_code,v_order.status,v_order.status,
    v_actor,(v_roles)[1],jsonb_build_object(
      'requestId',v_req.id,'requestType','CANCELLATION','note',v_note,
      'assignedRole','jefe_logistica','version','10.22.4'
    )
  );

  insert into erp_supply.system_audit(
    organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata
  ) values(
    v_org,v_actor,'REQUEST_CANCELLATION','ORDER',v_order.id::text,
    jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),
    jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),
    jsonb_build_object('requestId',v_req.id,'note',v_note,'assignedRole','jefe_logistica','version','10.22.4')
  );

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_org,'ORDER_CANCELLATION_REQUESTED','ORDER',v_order.id,jsonb_build_object(
    'requestId',v_req.id,'orderNumber',v_order.order_number,'requestedBy',v_actor,'assignedRole','jefe_logistica'
  ));

  return jsonb_build_object(
    'success',true,'requestId',v_req.id,'orderId',v_order.id,'orderNumber',v_order.order_number,
    'status','PENDING','assignedRole','jefe_logistica','version','10.22.4'
  );
end;
$$;

revoke all on function public.erp_x_request_order_cancellation(uuid,text) from public,anon;
grant execute on function public.erp_x_request_order_cancellation(uuid,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. DECISIÓN DEDICADA: SOLO JEFE LOGÍSTICO
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_decide_order_cancellation(
  p_request_id uuid,
  p_decision text default 'APPROVED',
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth,pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_req erp_supply.approval_requests%rowtype;
  v_order erp_supply.orders%rowtype;
  v_decision text:=upper(trim(coalesce(p_decision,'APPROVED')));
  v_reason text:=nullif(trim(coalesce(p_reason,'')),'');
  v_before_status text;
  v_before_step text;
  v_roles text[]:=erp_supply.current_roles();
begin
  if not erp_supply.has_role('jefe_logistica') then
    raise exception 'Solo Jefatura Logística puede decidir la cancelación de un pedido' using errcode='42501';
  end if;
  if v_decision not in('APPROVED','REJECTED') then raise exception 'Decisión inválida'; end if;

  select * into v_req
  from erp_supply.approval_requests
  where id=p_request_id
    and organization_id=v_org
    and request_type='CANCELLATION'
  for update;
  if not found then raise exception 'Solicitud de cancelación no encontrada'; end if;
  if v_req.status<>'PENDING' then raise exception 'La solicitud de cancelación ya fue decidida'; end if;

  select * into v_order from erp_supply.orders where id=v_req.order_id and organization_id=v_org for update;
  if not found then raise exception 'Pedido asociado no encontrado'; end if;
  v_before_status:=v_order.status;
  v_before_step:=v_order.current_step_code;

  if v_decision='REJECTED' then
    update erp_supply.approval_requests
    set status='REJECTED',
        decision_reason=coalesce(v_reason,'Cancelación no autorizada por Jefatura Logística'),
        decided_by=v_actor,
        decided_at=now()
    where id=v_req.id
    returning * into v_req;
  else
    if v_order.status='CANCELLED' then
      update erp_supply.approval_requests
      set status='EXECUTED',decision_reason='El pedido ya se encontraba cancelado',decided_by=v_actor,
          decided_at=now(),executed_at=now()
      where id=v_req.id returning * into v_req;
    else
      if v_order.status='CLOSED' then raise exception 'El pedido ya está cerrado y no puede cancelarse'; end if;

      update erp_supply.approval_requests
      set status='EXECUTED',
          decision_reason=coalesce(v_reason,'Cancelación aprobada por Jefatura Logística'),
          decided_by=v_actor,
          decided_at=now(),
          executed_at=now()
      where id=v_req.id
      returning * into v_req;

      update erp_supply.orders
      set status='CANCELLED',
          cancelled_at=coalesce(cancelled_at,now()),
          current_assignee_id=null,
          current_role_code=null,
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'cancellation',jsonb_build_object(
              'requestId',v_req.id,
              'requestedBy',v_req.requested_by,
              'requestNote',v_req.reason,
              'approvedBy',v_actor,
              'approvedAt',now(),
              'version','10.22.4'
            )
          ),
          version=coalesce(version,0)+1,
          updated_at=now()
      where id=v_order.id
      returning * into v_order;
    end if;
  end if;

  insert into erp_supply.order_events(
    organization_id,order_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,'APPROVAL_DECISION',v_decision,
    v_before_step,v_order.current_step_code,v_before_status,v_order.status,v_actor,(v_roles)[1],
    jsonb_build_object(
      'requestId',v_req.id,'requestType','CANCELLATION','requestNote',v_req.reason,
      'decisionReason',v_req.decision_reason,'requestStatus',v_req.status,'version','10.22.4'
    )
  );

  insert into erp_supply.system_audit(
    organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata
  ) values(
    v_org,v_actor,'CANCELLATION_'||v_decision,'ORDER',v_order.id::text,
    jsonb_build_object('status',v_before_status,'step',v_before_step),
    jsonb_build_object('status',v_order.status,'step',v_order.current_step_code),
    jsonb_build_object('requestId',v_req.id,'requestNote',v_req.reason,'decisionReason',v_req.decision_reason,'version','10.22.4')
  );

  insert into erp_supply.outbox_events(organization_id,event_type,aggregate_type,aggregate_id,payload)
  values(v_org,case when v_decision='APPROVED' then 'ORDER_CANCELLED' else 'ORDER_CANCELLATION_REJECTED' end,
    'ORDER',v_order.id,jsonb_build_object(
      'requestId',v_req.id,'orderNumber',v_order.order_number,'decision',v_decision,'decidedBy',v_actor
    ));

  return jsonb_build_object(
    'success',true,'requestId',v_req.id,'decision',v_decision,'requestStatus',v_req.status,
    'orderId',v_order.id,'orderNumber',v_order.order_number,'orderStatus',v_order.status,
    'currentStep',v_order.current_step_code,'version',v_order.version
  );
end;
$$;

revoke all on function public.erp_x_decide_order_cancellation(uuid,text,text) from public,anon;
grant execute on function public.erp_x_decide_order_cancellation(uuid,text,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. RETIRA CANCELLATION DEL FORMULARIO GENÉRICO DE APROBACIONES
-- ---------------------------------------------------------------------------
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
  v_assigned text;
begin
  select * into v_order from erp_supply.orders where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order_or_reception_shadow(id);
  if not found then raise exception 'Pedido no disponible para este usuario' using errcode='42501'; end if;

  if v_action in('CLAIM','START','RESUME','COMPLETE') and exists(
    select 1 from erp_supply.order_issues i where i.order_id=p_order_id and i.blocking and i.status='OPEN'
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
    v_type:=upper(trim(coalesce(p_payload->>'requestType','')));
    if v_type='CANCELLATION' then
      raise exception 'La cancelación se solicita desde el botón Solicitar cancelación';
    end if;
    v_assigned:=coalesce(nullif(trim(p_payload->>'assignedRole'),''),'jefe_logistica');
    if v_type not in('PRIORITY','ROUTE_CHANGE','REOPEN','STOCK_EXCEPTION','FLOW_EXCEPTION','PAYMENT_EXCEPTION','DATA_CORRECTION') then raise exception 'Tipo de solicitud inválido'; end if;
    if nullif(trim(p_payload->>'reason'),'') is null then raise exception 'Debe registrar el motivo'; end if;
    if v_assigned not in('auditoria','gerencia','jefe_logistica') then raise exception 'La aprobación debe dirigirse a Auditoría, Gerencia o Jefatura Logística'; end if;
    if v_type='PRIORITY' and upper(coalesce(p_payload->>'priority','')) not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida'; end if;
    if v_type='ROUTE_CHANGE' and not exists(select 1 from erp_supply.delivery_routes where code=p_payload->>'route' and active) then raise exception 'Ruta inválida'; end if;
  end if;
  return erp_supply.execute_action_internal(p_order_id,v_action,coalesce(p_payload,'{}'::jsonb),v_actor,false,p_expected_version,p_idempotency_key);
end;
$$;

revoke all on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) from public,anon;
grant execute on function public.erp_x_execute_action(uuid,text,jsonb,integer,text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. BANDEJA DE APROBACIONES: EXPONE canDecide Y EJECUTADAS COMO APROBADAS
-- ---------------------------------------------------------------------------
create or replace function public.erp_x_list_approvals(
  p_status text default 'PENDING',p_page integer default 1,p_page_size integer default 50
)
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
  v_status text:=upper(nullif(trim(coalesce(p_status,'')),''));
begin
  perform erp_supply.refresh_exception_sla(v_org);

  select count(*) into v_total
  from erp_supply.approval_requests a
  join erp_supply.orders o on o.id=a.order_id
  where a.organization_id=v_org and not o.is_test
    and (
      v_status is null
      or (v_status='APPROVED' and a.status in('APPROVED','EXECUTED'))
      or a.status=v_status
    )
    and (
      a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles)
      or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')
      or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica')
    );

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items
  from (
    select
      a.id,a.order_id "orderId",o.order_number "orderNumber",o.client_name "clientName",o.priority,
      o.current_step_code "processCode",a.request_type "requestType",a.status,a.reason,a.request_payload "requestPayload",
      rq.display_name "requestedBy",a.assigned_role_code "assignedRole",a.decision_reason "decisionReason",
      a.created_at "createdAt",a.decided_at "decidedAt",
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) "ageBusinessSeconds",
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) "slaLevel",
      case
        when a.status<>'PENDING' then false
        when a.request_type='CANCELLATION' then erp_supply.has_role('jefe_logistica')
        else (
          a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles)
          or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')
          or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica')
        )
      end "canDecide"
    from erp_supply.approval_requests a
    join erp_supply.orders o on o.id=a.order_id
    join erp_supply.profiles rq on rq.id=a.requested_by
    where a.organization_id=v_org and not o.is_test
      and (
        v_status is null
        or (v_status='APPROVED' and a.status in('APPROVED','EXECUTED'))
        or a.status=v_status
      )
      and (
        a.requested_by=v_profile or a.assigned_profile_id=v_profile or a.assigned_role_code=any(v_roles)
        or erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia')
        or erp_supply.has_role('auditoria') or erp_supply.has_role('jefe_logistica')
      )
    order by coalesce((a.request_payload#>>'{sla,level}')::integer,0) desc,a.created_at asc
    offset (v_page-1)*v_size limit v_size
  ) x;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object(
      'page',v_page,'pageSize',v_size,'totalItems',v_total,
      'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end
    ),
    'version','10.22.4'
  );
end;
$$;

revoke all on function public.erp_x_list_approvals(text,integer,integer) from public,anon;
grant execute on function public.erp_x_list_approvals(text,integer,integer) to authenticated;

notify pgrst,'reload schema';
commit;
