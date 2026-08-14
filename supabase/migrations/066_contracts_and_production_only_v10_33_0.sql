-- ERP ELECTROINGENIERIA V10.33.0
-- Contratos de Shipping/Aprobaciones/Crédito + backend productivo sin ramas sintéticas.

create or replace function public.erp_x_shipping_save_guide(p_order_id uuid, p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_delivery erp_supply.deliveries%rowtype;
  v_tracking text:=nullif(trim(p_payload->>'trackingNumber'),'');
  v_carrier text:=nullif(trim(p_payload->>'carrier'),'');
  v_destination jsonb;
  v_city text;
  v_address text;
  v_department text;
  v_country text;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para gestionar despachos' using errcode='42501';
  end if;
  if v_tracking is null then raise exception 'Número de guía requerido'; end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
    raise exception 'El pedido no está en una etapa de despacho';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code=v_order.current_step_code
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El pedido está asignado a otra persona' using errcode='42501';
  end if;

  v_city:=coalesce(nullif(v_order.metadata->>'clientCity',''),nullif(v_order.client_city,''));
  v_address:=coalesce(nullif(v_order.metadata->>'clientAddress',''),nullif(v_order.client_address,''));
  v_department:=nullif(v_order.metadata->>'clientDepartment','');
  v_country:=coalesce(nullif(v_order.metadata->>'clientCountry',''),'Colombia');
  if v_city is null or v_address is null then
    raise exception 'Ventas debe registrar municipio y dirección antes de despachar';
  end if;

  v_destination:=jsonb_strip_nulls(jsonb_build_object(
    'country',v_country,
    'department',v_department,
    'municipality',v_city,
    'address',v_address,
    'source','SALES_ORDER_ADDRESS',
    'capturedAt',now(),
    'snapshotVersion','10.33.0'
  ));

  select * into v_delivery
  from erp_supply.deliveries
  where order_id=p_order_id and status not in('CANCELLED')
  order by created_at desc limit 1 for update;

  if not found then
    insert into erp_supply.deliveries(
      order_id,route_code,status,carrier,tracking_number,assigned_profile_id,metadata
    ) values(
      p_order_id,v_order.delivery_route_code,'PLANNED',v_carrier,v_tracking,v_actor,
      jsonb_build_object(
        'taskId',v_task.id,
        'guideAddedAt',now(),
        'guideFileId',p_payload->>'guideFileId',
        'destination',v_destination,
        'shippingVersion','10.33.0'
      )
    ) returning * into v_delivery;
  else
    update erp_supply.deliveries
       set carrier=v_carrier,
           tracking_number=v_tracking,
           assigned_profile_id=v_actor,
           metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
             'taskId',v_task.id,
             'guideAddedAt',now(),
             'guideFileId',p_payload->>'guideFileId',
             'destination',v_destination,
             'shippingVersion','10.33.0'
           ),
           updated_at=now()
     where id=v_delivery.id
     returning * into v_delivery;
  end if;

  insert into erp_supply.delivery_milestones(
    organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata
  ) values(
    v_org,p_order_id,v_task.id,v_delivery.id,'GUIDE_ADDED',v_actor,
    jsonb_build_object('trackingNumber',v_tracking,'carrier',v_carrier,'guideFileId',p_payload->>'guideFileId','version','10.33.0')
  );

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,from_step_code,to_step_code,
    from_status,to_status,actor_profile_id,actor_role_code,payload
  ) values(
    v_org,p_order_id,v_task.id,'DOMAIN_RECORD','SHIPPING_GUIDE',
    v_order.current_step_code,v_order.current_step_code,v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('trackingNumber',v_tracking,'carrier',v_carrier,'destinationSource','SALES_ORDER_ADDRESS','version','10.33.0')
  );
  return jsonb_build_object('success',true,'delivery',to_jsonb(v_delivery),'version','10.33.0');
end;
$$;

create or replace function public.erp_x_shipping_send_to_closure(p_order_id uuid, p_payload jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_delivery erp_supply.deliveries%rowtype;
  v_result jsonb;
  v_closure erp_supply.order_tasks%rowtype;
  v_role text;
  v_destination jsonb;
  v_city text;
  v_address text;
begin
  if not (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para gestionar despachos' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;
  if not found or v_order.current_step_code not in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') then
    raise exception 'El pedido no está en despacho';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id
    and step_code=v_order.current_step_code
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found or v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'El pedido está asignado a otra persona' using errcode='42501';
  end if;

  v_role:=coalesce(
    v_task.assigned_role_code,
    erp_supply.default_role_for_step(v_order.current_step_code,v_order.delivery_route_code),
    erp_supply.default_role_for_step('CLOSURE',v_order.delivery_route_code)
  );
  if v_role is null then raise exception 'No fue posible resolver el rol operativo de despacho'; end if;

  select * into v_delivery
  from erp_supply.deliveries
  where order_id=p_order_id
  order by created_at desc limit 1 for update;
  if not found or nullif(trim(v_delivery.tracking_number),'') is null then
    raise exception 'Falta registrar la guía';
  end if;

  -- Compatibilidad con deliveries creados por versiones anteriores: reconstruye el snapshot
  -- usando la dirección canónica capturada por Ventas.
  if nullif(v_delivery.metadata#>>'{destination,municipality}','') is null
     or nullif(v_delivery.metadata#>>'{destination,address}','') is null then
    v_city:=coalesce(nullif(v_order.metadata->>'clientCity',''),nullif(v_order.client_city,''));
    v_address:=coalesce(nullif(v_order.metadata->>'clientAddress',''),nullif(v_order.client_address,''));
    if v_city is null or v_address is null then
      raise exception 'Ventas debe registrar municipio y dirección antes de despachar';
    end if;
    v_destination:=jsonb_strip_nulls(jsonb_build_object(
      'country',coalesce(nullif(v_order.metadata->>'clientCountry',''),'Colombia'),
      'department',nullif(v_order.metadata->>'clientDepartment',''),
      'municipality',v_city,
      'address',v_address,
      'source','SALES_ORDER_ADDRESS',
      'capturedAt',now(),
      'snapshotVersion','10.33.0'
    ));
    update erp_supply.deliveries
       set metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('destination',v_destination,'shippingVersion','10.33.0'),
           updated_at=now()
     where id=v_delivery.id
     returning * into v_delivery;
  end if;

  update erp_supply.deliveries
     set status='IN_TRANSIT',
         dispatched_at=coalesce(dispatched_at,now()),
         assigned_profile_id=v_actor,
         metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('sentToClosureAt',now(),'shippingVersion','10.33.0'),
         updated_at=now()
   where id=v_delivery.id
   returning * into v_delivery;

  insert into erp_supply.delivery_milestones(
    organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata
  ) values(
    v_org,p_order_id,v_task.id,v_delivery.id,'DISPATCHED',v_actor,
    jsonb_build_object('trackingNumber',v_delivery.tracking_number,'route',v_order.delivery_route_code,'version','10.33.0')
  );

  v_result:=erp_supply.execute_action_internal(
    p_order_id,'COMPLETE',
    jsonb_build_object(
      'detail',coalesce(nullif(p_payload->>'detail',''),'Pedido despachado y enviado a cierre'),
      'resultCode','DISPATCHED','shippingVersion','10.33.0'
    ),
    v_actor,false,v_order.version,gen_random_uuid()::text
  );

  select * into v_closure
  from erp_supply.order_tasks
  where order_id=p_order_id and step_code='CLOSURE'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;
  if not found then raise exception 'No fue posible crear la etapa de cierre'; end if;

  update erp_supply.order_tasks
     set assigned_profile_id=v_actor,
         assigned_role_code=v_role,
         assigned_at=coalesce(assigned_at,now()),
         status='ASSIGNED',
         metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
           'source','SHIPPING_V10_33','deliveryId',v_delivery.id,'inheritedDispatchRole',v_role
         )
   where id=v_closure.id
   returning * into v_closure;

  update erp_supply.orders
     set current_assignee_id=v_actor,
         current_role_code=v_role,
         status='ASSIGNED',
         version=version+1,
         updated_at=now()
   where id=p_order_id
   returning * into v_order;

  insert into erp_supply.delivery_milestones(
    organization_id,order_id,task_id,delivery_id,milestone_code,actor_profile_id,metadata
  ) values(
    v_org,p_order_id,v_closure.id,v_delivery.id,'CLOSURE_ASSIGNED',v_actor,
    jsonb_build_object('previousTaskId',v_task.id,'role',v_role,'version','10.33.0')
  );

  return jsonb_build_object(
    'success',true,'orderId',p_order_id,'currentStep','CLOSURE','closureRole',v_role,
    'closureProfileId',v_actor,'delivery',to_jsonb(v_delivery),'task',to_jsonb(v_closure),'version','10.33.0'
  );
end;
$$;

create or replace function public.erp_x_list_approvals(
  p_status text default 'PENDING',
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_total bigint;
  v_items jsonb;
  v_page int:=greatest(coalesce(p_page,1),1);
  v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
  v_status text:=upper(nullif(trim(coalesce(p_status,'')),''));
  v_can_approve boolean:=erp_supply.can_access_module('approvals','approve');
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
      coalesce((a.request_payload#>>'{sla,ageBusinessSeconds}')::bigint,
        erp_supply.business_seconds_between(v_org,a.created_at,coalesce(a.decided_at,now()))) "ageBusinessSeconds",
      coalesce((a.request_payload#>>'{sla,level}')::integer,0) "slaLevel",
      case
        when a.status<>'PENDING' then false
        when erp_supply.profile_is_read_only_auditor(v_profile) then false
        when a.request_type='CANCELLATION' then erp_supply.has_role('jefe_logistica')
        when not v_can_approve then false
        when a.assigned_profile_id is not null
             and a.assigned_profile_id<>v_profile
             and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica')) then false
        when a.assigned_role_code is not null
             and not (a.assigned_role_code=any(v_roles))
             and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica')) then false
        else true
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
    'version','10.33.0'
  );
end;
$$;

create or replace function public.erp_x_credit_list(
  p_status text default null,
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_roles text[]:=erp_supply.current_roles();
  v_total bigint;
  v_items jsonb;
  v_page int:=greatest(coalesce(p_page,1),1);
  v_size int:=least(greatest(coalesce(p_page_size,50),1),200);
  v_all boolean;
begin
  if not erp_supply.can_access_module('credit','read') then raise exception 'No autorizado' using errcode='42501'; end if;
  v_all:=v_roles && array['super_admin','gerencia','cartera','auditoria']::text[];

  select count(*) into v_total
  from erp_supply.credit_requests c
  where c.organization_id=v_org and (v_all or c.requested_by=v_profile)
    and (p_status is null or p_status='' or c.status=upper(p_status))
    and (p_search is null or p_search='' or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%');

  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into v_items
  from (
    select
      c.id,c.request_number "requestNumber",c.client_name "clientName",c.client_document "clientDocument",
      c.requested_amount "requestedAmount",c.requested_term_days "requestedTermDays",c.status,
      p.display_name "requestedBy",a.display_name "assignedTo",c.decision_reason "decisionReason",
      c.metadata,c.created_at "createdAt",c.updated_at "updatedAt",
      (
        c.status in('SUBMITTED','UNDER_REVIEW')
        and not erp_supply.profile_is_read_only_auditor(v_profile)
        and (erp_supply.has_role('cartera') or erp_supply.has_role('super_admin'))
        and (c.assigned_to is null or c.assigned_to=v_profile or erp_supply.has_role('super_admin'))
      ) "canTake",
      (
        c.status in('SUBMITTED','UNDER_REVIEW')
        and not erp_supply.profile_is_read_only_auditor(v_profile)
        and (erp_supply.has_role('cartera') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'))
        and (c.assigned_to is null or c.assigned_to=v_profile or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin'))
      ) "canDecide"
    from erp_supply.credit_requests c
    join erp_supply.profiles p on p.id=c.requested_by
    left join erp_supply.profiles a on a.id=c.assigned_to
    where c.organization_id=v_org and (v_all or c.requested_by=v_profile)
      and (p_status is null or p_status='' or c.status=upper(p_status))
      and (p_search is null or p_search='' or lower(c.request_number||' '||c.client_name||' '||coalesce(c.client_document,'')) like '%'||lower(p_search)||'%')
    order by c.created_at desc
    offset (v_page-1)*v_size limit v_size
  ) x;

  return jsonb_build_object(
    'items',v_items,
    'pagination',jsonb_build_object(
      'page',v_page,'pageSize',v_size,'totalItems',v_total,
      'totalPages',case when v_total=0 then 0 else ceil(v_total::numeric/v_size)::int end
    ),
    'version','10.33.0'
  );
end;
$$;

create or replace function public.erp_x_credit_transition(p_request_id uuid, p_action text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_req erp_supply.credit_requests%rowtype;
  v_action text:=upper(trim(coalesce(p_action,'')));
begin
  if erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;

  select * into v_req
  from erp_supply.credit_requests
  where id=p_request_id and organization_id=erp_supply.current_org_id()
  for update;
  if not found then raise exception 'Solicitud de crédito no encontrada'; end if;

  if v_action='TAKE' then
    if v_req.status not in('SUBMITTED','UNDER_REVIEW') then raise exception 'La solicitud no puede tomarse en su estado actual'; end if;
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    if v_req.assigned_to is not null and v_req.assigned_to<>v_actor and not erp_supply.has_role('super_admin') then
      raise exception 'La solicitud está siendo gestionada por otra persona' using errcode='42501';
    end if;
    update erp_supply.credit_requests
       set status='UNDER_REVIEW',assigned_to=v_actor,updated_at=now()
     where id=v_req.id returning * into v_req;

  elsif v_action in('APPROVE','REJECT') then
    if v_req.status not in('SUBMITTED','UNDER_REVIEW') then raise exception 'La solicitud ya no admite decisión'; end if;
    if nullif(trim(p_reason),'') is null then raise exception 'Debe registrar el motivo de la decisión'; end if;
    if not (erp_supply.has_role('cartera') or erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    if v_req.assigned_to is not null and v_req.assigned_to<>v_actor
       and not (erp_supply.has_role('gerencia') or erp_supply.has_role('super_admin')) then
      raise exception 'La solicitud está siendo gestionada por otra persona' using errcode='42501';
    end if;
    update erp_supply.credit_requests
       set status=case when v_action='APPROVE' then 'APPROVED' else 'REJECTED' end,
           assigned_to=coalesce(assigned_to,v_actor),decision_reason=trim(p_reason),updated_at=now()
     where id=v_req.id returning * into v_req;

  elsif v_action='CANCEL' then
    if v_req.status in('APPROVED','REJECTED','CANCELLED') then raise exception 'La solicitud ya no puede cancelarse'; end if;
    if not (v_req.requested_by=v_actor or erp_supply.has_role('super_admin')) then raise exception 'No autorizado' using errcode='42501'; end if;
    update erp_supply.credit_requests
       set status='CANCELLED',decision_reason=coalesce(nullif(trim(p_reason),''),'Cancelada por el solicitante'),updated_at=now()
     where id=v_req.id returning * into v_req;
  else
    raise exception 'Transición de crédito inválida';
  end if;

  return jsonb_build_object('success',true,'request',to_jsonb(v_req),'version','10.33.0');
end;
$$;

create or replace function erp_supply.sync_parallel_cut_requirements(p_order_id uuid)
returns integer
language plpgsql
security definer
set search_path = erp_supply, public, pg_catalog
as $$
declare
  v_order erp_supply.orders%rowtype;
  v_cut_profile uuid;
  v_count integer:=0;
begin
  select * into v_order from erp_supply.orders where id=p_order_id for update;
  if not found then return 0; end if;
  if coalesce(v_order.is_test,false) then
    raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo';
  end if;

  v_cut_profile:=coalesce(
    erp_supply.safe_uuid(v_order.metadata#>>'{receptionAssignment,cutProfileId}'),
    v_order.current_assignee_id
  );

  delete from erp_supply.cut_requirements r
  where r.order_id=p_order_id and r.process_status='PENDING'
    and not exists(
      select 1 from erp_supply.order_items i
      where i.id=r.order_item_id
        and i.requires_cut
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
    );

  insert into erp_supply.cut_requirements(
    organization_id,order_id,order_item_id,task_id,group_key,sku,reference,description,
    unit,units_required,length_each,total_length,assigned_profile_id,material_master_id,material_variant_id,metadata
  )
  select
    v_order.organization_id,v_order.id,i.id,null,
    md5(i.material_master_id::text||'|'||coalesce(i.material_variant_id::text,'SIN_VARIANTE')),
    i.sku,i.reference,i.description,'M',i.quantity,i.requested_cut_length,
    round((i.quantity*i.requested_cut_length)::numeric,4),v_cut_profile,
    i.material_master_id,i.material_variant_id,
    jsonb_build_object(
      'lineNumber',i.line_number,'source','SIESA_PARALLEL_CUT_V10_33',
      'materialMasterId',i.material_master_id,'materialVariantId',i.material_variant_id,'version','10.33.0'
    )
  from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.requires_cut
    and i.requested_cut_length is not null and i.requested_cut_length>0
    and i.material_master_id is not null
  on conflict(order_item_id) do update set
    group_key=excluded.group_key,sku=excluded.sku,reference=excluded.reference,description=excluded.description,
    units_required=excluded.units_required,length_each=excluded.length_each,total_length=excluded.total_length,
    material_master_id=excluded.material_master_id,material_variant_id=excluded.material_variant_id,
    assigned_profile_id=coalesce(excluded.assigned_profile_id,erp_supply.cut_requirements.assigned_profile_id),
    metadata=erp_supply.cut_requirements.metadata||excluded.metadata,updated_at=now();
  get diagnostics v_count=row_count;

  if exists(
    select 1 from erp_supply.order_items i
    where i.order_id=v_order.id and i.requires_cut
      and coalesce(i.metadata->>'receptionActive','true')<>'false'
      and i.material_master_id is null
  ) then
    raise exception 'Hay líneas de corte sin material oficial Siesa. Corrige la referencia en Recepción.';
  end if;

  update erp_supply.orders
     set metadata=metadata||jsonb_build_object(
       'cutFlow',coalesce(metadata->'cutFlow','{}'::jsonb)||jsonb_build_object(
         'version','10.33.0','parallel',true,'materialIdentity','SIESA_MASTER','syncedAt',now(),
         'pendingRequirements',(select count(*) from erp_supply.cut_requirements where order_id=p_order_id and process_status<>'READY')
       )
     ),updated_at=now()
   where id=p_order_id;
  return v_count;
end;
$$;

create or replace function public.erp_x_picking_origin_plan(p_order_item_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_required numeric;
  v_total numeric:=0;
  v_remaining numeric;
  v_single uuid;
  v_row record;
  v_candidates jsonb:='[]'::jsonb;
  v_plan jsonb:='[]'::jsonb;
  v_take numeric;
begin
  perform erp_supply.require_profile();
  select i.* into v_item
  from erp_supply.order_items i
  join erp_supply.orders o on o.id=i.order_id
  where i.id=p_order_item_id and o.organization_id=v_org and erp_supply.can_view_order(o.id);
  if not found then raise exception 'Línea no disponible' using errcode='42501'; end if;
  select * into v_order from erp_supply.orders where id=v_item.order_id;
  if coalesce(v_order.is_test,false) then raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo'; end if;

  if v_item.requires_cut then
    return jsonb_build_object(
      'orderItemId',v_item.id,'managedByCutting',true,
      'required',erp_supply.order_item_required_quantity(v_item),'unit',v_item.unit,
      'candidates','[]'::jsonb,'suggestedPlan','[]'::jsonb,'version','10.33.0'
    );
  end if;
  if v_item.material_master_id is null then raise exception 'La línea no está vinculada al maestro oficial Siesa'; end if;

  v_required:=v_item.quantity;
  select l.id into v_single
  from erp_supply.inventory_lots l
  join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
  where ii.organization_id=v_org and ii.active
    and ii.material_master_id=v_item.material_master_id
    and l.source_active
    and l.material_variant_id is not distinct from v_item.material_variant_id
    and l.quantity_available>=v_required
  order by l.quantity_available asc,l.received_at asc nulls last,l.id
  limit 1;

  for v_row in
    select l.id,l.inventory_item_id,l.lot_number,l.serial_number,l.location,l.quantity_available,
           l.warehouse_code,l.source_location_name,l.source_system,mv.variant_label
    from erp_supply.inventory_lots l
    join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
    left join erp_supply.material_variants mv on mv.id=l.material_variant_id
    where ii.organization_id=v_org and ii.active
      and ii.material_master_id=v_item.material_master_id
      and l.source_active
      and l.material_variant_id is not distinct from v_item.material_variant_id
      and l.quantity_available>0
    order by case when v_single is not null and l.id=v_single then 0 else 1 end,
             case when v_single is null then l.quantity_available end desc,
             l.quantity_available asc,l.location,l.id
  loop
    v_total:=v_total+v_row.quantity_available;
    v_candidates:=v_candidates||jsonb_build_array(jsonb_build_object(
      'lotId',v_row.id,'inventoryItemId',v_row.inventory_item_id,'lotNumber',v_row.lot_number,
      'serialNumber',v_row.serial_number,'location',v_row.location,'locationName',v_row.source_location_name,
      'warehouseCode',v_row.warehouse_code,'available',v_row.quantity_available,'sourceSystem',v_row.source_system,
      'variantLabel',v_row.variant_label,'recommended',v_row.id=v_single
    ));
  end loop;

  v_remaining:=v_required;
  if v_single is not null then
    v_plan:=jsonb_build_array(jsonb_build_object('lotId',v_single,'quantity',v_required));
  else
    for v_row in
      select l.id,l.quantity_available
      from erp_supply.inventory_lots l
      join erp_supply.inventory_items ii on ii.id=l.inventory_item_id
      where ii.organization_id=v_org and ii.active
        and ii.material_master_id=v_item.material_master_id
        and l.source_active
        and l.material_variant_id is not distinct from v_item.material_variant_id
        and l.quantity_available>0
      order by l.quantity_available desc,l.location,l.id
    loop
      exit when v_remaining<=0;
      v_take:=least(v_remaining,v_row.quantity_available);
      v_plan:=v_plan||jsonb_build_array(jsonb_build_object('lotId',v_row.id,'quantity',v_take));
      v_remaining:=v_remaining-v_take;
    end loop;
  end if;

  return jsonb_build_object(
    'orderItemId',v_item.id,'managedByCutting',false,'required',v_required,'unit',v_item.unit,
    'materialMasterId',v_item.material_master_id,'materialVariantId',v_item.material_variant_id,
    'totalAvailable',v_total,'shortage',greatest(v_required-v_total,0),
    'candidates',v_candidates,'suggestedPlan',v_plan,'version','10.33.0'
  );
end;
$$;

create or replace function public.erp_x_save_picking_precheck(p_order_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_task erp_supply.order_tasks%rowtype;
  v_order erp_supply.orders%rowtype;
  v_row jsonb;
  v_item erp_supply.order_items%rowtype;
  v_id uuid;
  v_result text;
  v_novelty text;
  v_origins jsonb;
  v_count int:=0;
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if coalesce(v_order.is_test,false) then raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo'; end if;

  if not (erp_supply.can_access_module('picking','update') or erp_supply.has_role('aux_logistica') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then
    raise exception 'No autorizado para guardar Alistamiento' using errcode='42501';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id and step_code='ALISTAMIENTO' and status='IN_PROGRESS'
  order by sequence_no desc limit 1;
  if not found then raise exception 'Primero debes tomar el pedido en Alistamiento'; end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not (erp_supply.has_role('jefe_logistica') or erp_supply.has_role('super_admin')) then
    raise exception 'Pedido asignado a otro auxiliar' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_items,'[]'::jsonb))<>'array' then raise exception 'Resultados inválidos'; end if;

  for v_row in select value from jsonb_array_elements(p_items)
  loop
    v_id:=erp_supply.safe_uuid(v_row->>'orderItemId');
    v_result:=upper(coalesce(v_row->>'result',''));
    v_novelty:=nullif(trim(v_row->>'novelty'),'');
    v_origins:=coalesce(v_row->'origins','[]'::jsonb);

    select * into v_item
    from erp_supply.order_items
    where id=v_id and order_id=p_order_id and item_status not in('FULFILLED','CANCELLED');
    if not found then raise exception 'Línea no disponible'; end if;

    if v_item.requires_cut and not exists(
      select 1 from erp_supply.cut_requirements r
      where r.order_item_id=v_item.id and r.process_status='READY' and r.collection_status='COLLECTED'
    ) then
      raise exception 'La línea % todavía está en Corte',v_item.line_number;
    end if;

    if v_result not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado'; end if;
    if v_result='MISSING' and v_novelty is null then raise exception 'Explica el faltante de la línea %',v_item.line_number; end if;
    if v_result='FOUND' and not v_item.requires_cut then
      perform erp_supply.validate_picking_origins(v_item,v_origins,false);
    end if;

    insert into erp_supply.picking_prechecks(
      order_item_id,organization_id,order_id,task_id,result,novelty,checked_by,metadata
    ) values(
      v_item.id,v_org,p_order_id,v_task.id,v_result,v_novelty,v_actor,
      jsonb_build_object('lineNumber',v_item.line_number,'source','PARALLEL_PICKING_V10_33','origins',v_origins,'version','10.33.0')
    )
    on conflict(order_item_id) do update set
      result=excluded.result,novelty=excluded.novelty,checked_by=excluded.checked_by,
      checked_at=now(),task_id=excluded.task_id,
      metadata=erp_supply.picking_prechecks.metadata||excluded.metadata;
    v_count:=v_count+1;
  end loop;

  return jsonb_build_object('success',true,'saved',v_count,'version','10.33.0');
end;
$$;

-- get_actions: servidor como fuente de verdad para los botones de operación.
create or replace function public.erp_x_get_actions(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_actions jsonb:='[]';
  v_domains jsonb:='[]';
  v_can_override boolean;
  v_latest_delivery text;
  v_read_only_audit boolean:=erp_supply.profile_is_read_only_auditor(v_actor);
  v_owns_active boolean:=false;
begin
  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=erp_supply.current_org_id() and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=p_order_id and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1;
  select status into v_latest_delivery from erp_supply.deliveries where order_id=p_order_id order by created_at desc limit 1;

  v_can_override:=erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica');
  if v_task.id is not null then
    v_owns_active:=v_task.assigned_profile_id is null or v_task.assigned_profile_id=v_actor or v_can_override;
  end if;

  if v_order.status not in('CLOSED','CANCELLED') and not v_read_only_audit then
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'CLAIM',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','CLAIM','label','Tomar tarea','kind','primary'));
    end if;
    if v_task.status in('QUEUED','ASSIGNED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'START',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','START','label','Iniciar trabajo','kind','primary','requires',jsonb_build_array('detail')));
    end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'COMPLETE',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMPLETE','label','Finalizar etapa','kind','success','requires',jsonb_build_array('detail')));
    end if;
    if v_task.status='IN_PROGRESS' and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','WAIT','label','Poner en espera','kind','warning','requires',jsonb_build_array('reason')));
    end if;
    if v_task.status in('WAITING','BLOCKED') and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','RESUME','label','Reanudar','kind','primary'));
    end if;
    if erp_supply.actor_can(v_actor,v_order.current_step_code,'ASSIGN',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','ASSIGN','label','Asignar responsable','kind','secondary','requires',jsonb_build_array('profileId')));
    end if;
    if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH')
       and v_task.status in('ASSIGNED','IN_PROGRESS')
       and erp_supply.actor_can(v_actor,v_order.current_step_code,'WAIT',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','NO_DELIVERY','label','Registrar no entrega','kind','danger','requires',jsonb_build_array('reason')));
    end if;
    if v_task.status='WAITING' and v_latest_delivery='NOT_DELIVERED'
       and erp_supply.actor_can(v_actor,v_order.current_step_code,'RESUME',v_order.current_assignee_id) then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REPROGRAM','label','Reprogramar entrega','kind','warning','requires',jsonb_build_array('scheduledAt')));
    end if;

    v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','COMMENT','label','Agregar comentario','kind','secondary','requires',jsonb_build_array('body')));
    if erp_supply.can_access_module('approvals','create') or erp_supply.has_role('super_admin') then
      v_actions:=v_actions||jsonb_build_array(jsonb_build_object('code','REQUEST_APPROVAL','label','Solicitar aprobación','kind','secondary','requires',jsonb_build_array('requestType','reason')));
    end if;

    if v_task.status='IN_PROGRESS' and v_owns_active then
      if v_order.current_step_code in('CARTERA','CAJA') and (erp_supply.can_access_module(lower(v_order.current_step_code),'update') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FINANCIAL','label','Registrar validación financiera'));
      end if;
      if v_order.current_step_code='COMPRAS' and (erp_supply.can_access_module('purchasing','create') or erp_supply.can_access_module('purchasing','update') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','PURCHASE','label','Registrar orden de compra'));
      end if;
      if v_order.current_step_code='RECEPCION_MERCANCIA' and (erp_supply.can_access_module('receiving','create') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','RECEIPT','label','Registrar recepción'),jsonb_build_object('code','STICKERS','label','Imprimir stickers'));
      end if;
      if v_order.current_step_code='CORTE' and (erp_supply.can_access_module('cutting','update') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CUT','label','Registrar corte'));
      end if;
      if v_order.current_step_code='FACTURACION' and (erp_supply.can_access_module('billing','create') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','INVOICE','label','Registrar factura'));
      end if;
      if v_order.current_step_code in('CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH') and (erp_supply.can_access_module('shipping','update') or erp_supply.has_role('super_admin')) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','DELIVERY','label','Registrar despacho o entrega'));
      end if;
      if exists(select 1 from erp_supply.task_checklist where task_id=v_task.id) then
        v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','CHECKLIST','label','Lista de verificación'));
      end if;
      v_domains:=v_domains||jsonb_build_array(jsonb_build_object('code','FILE','label','Subir evidencia'));
    end if;
  end if;

  return jsonb_build_object(
    'orderId',v_order.id,'version',v_order.version,'status',v_order.status,'currentStep',v_order.current_step_code,
    'taskId',v_task.id,'taskStatus',v_task.status,'canOverride',v_can_override,'isAssignee',v_owns_active,
    'readOnly',v_read_only_audit,'actions',v_actions,'domainActions',v_domains,'contractVersion','10.33.0'
  );
end;
$$;

create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql
stable
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
  select * from (values
    ('01_BASE'::text,'Organización activa'::text,
      exists(select 1 from erp_supply.organizations where code='EI' and active),
      'Organización EI disponible'::text),
    ('01_BASE','Núcleo operativo instalado',
      to_regclass('erp_supply.orders') is not null
      and to_regclass('erp_supply.order_tasks') is not null
      and to_regclass('erp_supply.inventory_movements') is not null,
      'Pedidos, tareas e inventario disponibles'),
    ('02_SESION','Perfil de sesión vinculado',
      exists(select 1 from erp_supply.profiles p where p.auth_user_id=auth.uid() and p.active),
      'Perfil autenticado activo'),
    ('03_RESERVAS','Identidad Profile en reservas',
      position('auth.uid()' in pg_get_functiondef(to_regprocedure('erp_supply.refresh_material_reservation(uuid)')))=0
      and position('current_profile_id' in pg_get_functiondef(to_regprocedure('erp_supply.refresh_material_reservation(uuid)')))>0,
      'Las FK de reservas usan profiles.id'),
    ('03_ENRUTAMIENTO','Compra opcional realmente enrutable',
      erp_supply.initial_step('PVC','CREDIT',true,false,false)='COMPRAS'
      and erp_supply.next_step('CARTERA','PVC','CREDIT','CLIENT_POINT',false,true)='COMPRAS',
      'Requiere compra participa en el flujo'),
    ('04_OWNERSHIP','Guardas de propietario instaladas',
      to_regprocedure('erp_supply.active_task_owned_by_actor(uuid,text,uuid,boolean)') is not null
      and exists(select 1 from pg_trigger where tgname='trg_guard_invoice_task_owner_v1033' and not tgisinternal),
      'Las mutaciones sensibles validan responsable'),
    ('05_AUDITORIA','Auditoría protegida como solo lectura',
      exists(select 1 from pg_trigger where tgname='trg_guard_order_issue_write_v1033' and not tgisinternal)
      and exists(select 1 from pg_trigger where tgname='trg_guard_audit_order_comments_v1033' and not tgisinternal),
      'Comentarios, novedades y solicitudes operativas están protegidos'),
    ('06_SHIPPING','Destino canónico de Ventas en Shipping',
      position('SALES_ORDER_ADDRESS' in pg_get_functiondef(to_regprocedure('public.erp_x_shipping_save_guide(uuid,jsonb)')))>0,
      'Despacho conserva snapshot de la dirección de Ventas'),
    ('07_CORTE','Modelo productivo de Corte instalado',
      to_regprocedure('erp_supply.sync_cut_execution_state(uuid,uuid)') is not null
      and to_regprocedure('public.erp_x_cutting_finalize(uuid)') is not null,
      'Ejecución y cierre de Corte disponibles'),
    ('07_CORTE','Sin ejecuciones sintéticas activas',
      not exists(select 1 from erp_supply.cut_executions where group_key like 'SBX:%'),
      'No quedan ejecuciones de prueba en Corte'),
    ('08_INVENTARIO','Inventario operativo vinculado a Siesa',
      not exists(select 1 from erp_supply.inventory_items where active and material_master_id is null),
      'No hay ítems activos fuera del maestro oficial'),
    ('09_FLUJO','Sin tareas activas en pedidos finalizados',
      not exists(
        select 1 from erp_supply.orders o
        join erp_supply.order_tasks t on t.order_id=o.id
        where o.status in('CLOSED','CANCELLED') and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
      ),
      'Estados finales y tareas activas son consistentes')
  ) v(section,check_name,ok,detail)
  order by section,check_name
$$;

revoke all on function public.erp_x_shipping_save_guide(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_shipping_send_to_closure(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_list_approvals(text,integer,integer) from public,anon;
revoke all on function public.erp_x_credit_list(text,text,integer,integer) from public,anon;
revoke all on function public.erp_x_credit_transition(uuid,text,text) from public,anon;
revoke all on function public.erp_x_picking_origin_plan(uuid) from public,anon;
revoke all on function public.erp_x_save_picking_precheck(uuid,jsonb) from public,anon;
revoke all on function public.erp_x_get_actions(uuid) from public,anon;
revoke all on function public.erp_x_health_check() from public,anon;

grant execute on function public.erp_x_shipping_save_guide(uuid,jsonb) to authenticated,service_role;
grant execute on function public.erp_x_shipping_send_to_closure(uuid,jsonb) to authenticated,service_role;
grant execute on function public.erp_x_list_approvals(text,integer,integer) to authenticated,service_role;
grant execute on function public.erp_x_credit_list(text,text,integer,integer) to authenticated,service_role;
grant execute on function public.erp_x_credit_transition(uuid,text,text) to authenticated,service_role;
grant execute on function public.erp_x_picking_origin_plan(uuid) to authenticated,service_role;
grant execute on function public.erp_x_save_picking_precheck(uuid,jsonb) to authenticated,service_role;
grant execute on function public.erp_x_get_actions(uuid) to authenticated,service_role;
grant execute on function public.erp_x_health_check() to authenticated,service_role;

select pg_notify('pgrst','reload schema');
