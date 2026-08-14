-- ERP ELECTROINGENIERIA V10.33.0
-- Integridad canónica: identidad ERP, ownership, Auditoría read-only y routing de Compras.

create or replace function erp_supply.profile_is_read_only_auditor(p_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, pg_catalog
as $$
  select exists(
    select 1 from erp_supply.profile_roles pr
    where pr.profile_id=p_profile_id and pr.role_code='auditoria'
  ) and not exists(
    select 1 from erp_supply.profile_roles pr
    where pr.profile_id=p_profile_id and pr.role_code<>'auditoria'
  )
$$;

create or replace function erp_supply.actor_can(
  p_actor uuid,
  p_step text,
  p_action text,
  p_assignee uuid default null
)
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, pg_catalog
as $$
  select exists(
    select 1
    from erp_supply.profile_roles pr
    join erp_supply.step_roles sr
      on sr.role_code=pr.role_code
     and sr.step_code=p_step
    where pr.profile_id=p_actor
      and case upper(coalesce(p_action,''))
        when 'CLAIM' then sr.can_claim
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'ASSIGN' then sr.can_assign
        when 'START' then sr.can_start
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'COMPLETE' then sr.can_complete
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'WAIT' then sr.can_block
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'BLOCK' then sr.can_block
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        when 'RESUME' then sr.can_start
          and (p_assignee is null or p_assignee=p_actor or sr.can_override)
        else sr.can_view
      end
  )
$$;

create or replace function erp_supply.active_task_owned_by_actor(
  p_order_id uuid,
  p_step text,
  p_actor uuid,
  p_require_in_progress boolean default true
)
returns boolean
language sql
stable
security definer
set search_path = erp_supply, public, pg_catalog
as $$
  select
    exists(select 1 from erp_supply.profile_roles pr where pr.profile_id=p_actor and pr.role_code in('super_admin','jefe_logistica'))
    or exists(
      select 1
      from erp_supply.order_tasks t
      where t.order_id=p_order_id
        and (p_step is null or t.step_code=p_step)
        and t.status = case when p_require_in_progress then 'IN_PROGRESS' else t.status end
        and (not p_require_in_progress or t.status='IN_PROGRESS')
        and (p_require_in_progress or t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED'))
        and t.assigned_profile_id=p_actor
      order by t.sequence_no desc
      limit 1
    )
$$;

create or replace function erp_supply.initial_step(
  p_order_type text,
  p_payment_condition text,
  p_requires_purchase boolean,
  p_has_credit_arrears boolean,
  p_held_by_cashier boolean
)
returns text
language sql
immutable
as $$
  select case
    when upper(p_order_type) in('PVC','PVP') and coalesce(p_has_credit_arrears,false) then 'CARTERA'
    when upper(p_order_type) in('PVN','PNV') and coalesce(p_held_by_cashier,false) then 'CAJA'
    when upper(p_order_type)='PVE' or coalesce(p_requires_purchase,false) then 'COMPRAS'
    else 'RECEPCION_PEDIDO'
  end
$$;

create or replace function erp_supply.next_step(
  p_current_step text,
  p_order_type text,
  p_payment_condition text,
  p_delivery_route text,
  p_requires_cut boolean,
  p_requires_purchase boolean
)
returns text
language sql
immutable
as $$
  select case upper(p_current_step)
    when 'CARTERA' then case when coalesce(p_requires_purchase,false) then 'COMPRAS' else 'RECEPCION_PEDIDO' end
    when 'CAJA' then case when coalesce(p_requires_purchase,false) then 'COMPRAS' else 'RECEPCION_PEDIDO' end
    when 'COMPRAS' then 'RECEPCION_MERCANCIA'
    when 'RECEPCION_MERCANCIA' then 'RECEPCION_PEDIDO'
    when 'RECEPCION_PEDIDO' then 'ALISTAMIENTO'
    when 'CORTE' then 'ALISTAMIENTO'
    when 'ALISTAMIENTO' then case when upper(p_order_type) in('PVN','PNV') then 'CAJA_FACTURACION' else 'FACTURACION' end
    when 'CAJA_FACTURACION' then p_delivery_route
    when 'FACTURACION' then p_delivery_route
    when 'CLIENT_POINT' then 'CLOSURE'
    when 'CLIENT_PICKUP' then 'CLOSURE'
    when 'LOCAL_DISPATCH' then 'CLOSURE'
    when 'NATIONAL_DISPATCH' then 'CLOSURE'
    when 'CLOSURE' then 'CLOSED'
    else 'CLOSED'
  end
$$;

create or replace function erp_supply.refresh_material_reservation(p_order_item_id uuid)
returns void
language plpgsql
security definer
set search_path = erp_supply, public, pg_catalog
as $$
declare
  v_item erp_supply.order_items%rowtype;
  v_order erp_supply.orders%rowtype;
  v_required numeric;
  v_physical numeric;
  v_reserved numeric;
  v_shortage numeric;
  v_actor uuid;
begin
  select * into v_item from erp_supply.order_items where id=p_order_item_id;
  if not found then return; end if;

  select * into v_order from erp_supply.orders where id=v_item.order_id;
  if not found then return; end if;

  if coalesce(v_order.is_test,false) then
    raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo';
  end if;

  if v_item.material_master_id is null then
    delete from erp_supply.material_reservations where order_item_id=v_item.id;
    return;
  end if;

  if v_item.item_status='FULFILLED' then
    update erp_supply.material_reservations
       set status='CONSUMED',
           consumed_at=coalesce(consumed_at,now()),
           updated_at=now()
     where order_item_id=v_item.id and status<>'CONSUMED';
    return;
  elsif exists(
    select 1 from erp_supply.cut_requirements r
    where r.order_item_id=v_item.id
      and r.process_status='READY'
      and coalesce(r.resolution_code,'') in('CUT','FULL_REEL')
  ) then
    update erp_supply.material_reservations
       set status='CONSUMED',
           consumed_at=coalesce(consumed_at,now()),
           updated_at=now(),
           metadata=metadata||jsonb_build_object('consumedBy','CORTE','reservationVersion','10.33.0')
     where order_item_id=v_item.id and status<>'CONSUMED';
    return;
  elsif v_item.item_status='CANCELLED'
     or coalesce(v_item.metadata->>'receptionActive','true')='false'
     or v_order.status='CANCELLED' then
    update erp_supply.material_reservations
       set status='RELEASED',
           released_at=coalesce(released_at,now()),
           updated_at=now()
     where order_item_id=v_item.id and status='ACTIVE';
    return;
  end if;

  v_required:=erp_supply.order_item_required_quantity(v_item);
  if v_required is null or v_required<=0 then return; end if;

  v_physical:=erp_supply.material_physical_available(
    v_order.organization_id,v_item.material_master_id,v_item.material_variant_id
  );
  v_reserved:=erp_supply.material_erp_reserved(
    v_order.organization_id,v_item.material_master_id,v_item.material_variant_id,v_item.id
  );
  v_shortage:=greatest(v_required-greatest(v_physical-v_reserved,0),0);

  -- Todas las FK de actor de erp_supply apuntan a profiles.id, nunca a auth.users.id.
  v_actor:=erp_supply.current_profile_id();
  if v_actor is null then
    v_actor:=v_order.seller_profile_id;
  end if;
  if v_actor is not null and not exists(select 1 from erp_supply.profiles p where p.id=v_actor) then
    v_actor:=null;
  end if;

  insert into erp_supply.material_reservations(
    organization_id,order_id,order_item_id,material_master_id,material_variant_id,
    quantity,unit,status,shortage_quantity,created_by,metadata
  ) values(
    v_order.organization_id,v_order.id,v_item.id,v_item.material_master_id,v_item.material_variant_id,
    v_required,v_item.unit,'ACTIVE',v_shortage,v_actor,
    jsonb_build_object(
      'source','SALES_V10_33',
      'reference',v_item.reference,
      'lineNumber',v_item.line_number,
      'requiresCut',v_item.requires_cut,
      'reservationVersion','10.33.0'
    )
  )
  on conflict(order_item_id) do update set
    material_master_id=excluded.material_master_id,
    material_variant_id=excluded.material_variant_id,
    quantity=excluded.quantity,
    unit=excluded.unit,
    status='ACTIVE',
    shortage_quantity=excluded.shortage_quantity,
    created_by=coalesce(erp_supply.material_reservations.created_by,excluded.created_by),
    consumed_at=null,
    released_at=null,
    metadata=erp_supply.material_reservations.metadata||excluded.metadata,
    updated_at=now();
end;
$$;

create or replace function erp_supply.trg_forbid_automated_test_orders()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, pg_catalog
as $$
begin
  if coalesce(new.is_test,false) then
    raise exception 'Los pedidos automatizados de prueba fueron retirados del ERP productivo';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_forbid_automated_test_orders on erp_supply.orders;
create trigger trg_forbid_automated_test_orders
before insert or update of is_test on erp_supply.orders
for each row execute function erp_supply.trg_forbid_automated_test_orders();

create or replace function erp_supply.trg_guard_domain_task_ownership_v1033()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid;
  v_order_id uuid;
  v_step text;
  v_source text;
begin
  if auth.uid() is null then return new; end if;
  v_actor:=erp_supply.current_profile_id();
  if v_actor is null then
    raise exception 'Usuario sin perfil operativo activo' using errcode='42501';
  end if;

  if tg_table_name='financial_validations' then
    v_order_id:=new.order_id;
    v_step:=upper(new.validation_type);
  elsif tg_table_name='purchase_orders' then
    v_order_id:=new.order_id;
    v_step:='COMPRAS';
  elsif tg_table_name='invoices' then
    v_order_id:=new.order_id;
    v_step:=upper(coalesce(new.metadata->>'registeredStep','FACTURACION'));
  elsif tg_table_name='receipts' then
    v_order_id:=new.order_id;
    v_step:='RECEPCION_MERCANCIA';
    v_source:=coalesce(new.metadata->>'source','');
    if v_source='MERCANCIA_OK_V10_22' and coalesce((new.metadata->>'automaticArrival')::boolean,false) then
      return new;
    end if;
  else
    return new;
  end if;

  if not erp_supply.active_task_owned_by_actor(v_order_id,v_step,v_actor,true) then
    raise exception 'La tarea está asignada a otro usuario. Actualiza la pantalla antes de continuar.' using errcode='42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_financial_task_owner_v1033 on erp_supply.financial_validations;
create trigger trg_guard_financial_task_owner_v1033
before insert on erp_supply.financial_validations
for each row execute function erp_supply.trg_guard_domain_task_ownership_v1033();

drop trigger if exists trg_guard_purchase_task_owner_v1033 on erp_supply.purchase_orders;
create trigger trg_guard_purchase_task_owner_v1033
before insert or update on erp_supply.purchase_orders
for each row execute function erp_supply.trg_guard_domain_task_ownership_v1033();

drop trigger if exists trg_guard_invoice_task_owner_v1033 on erp_supply.invoices;
create trigger trg_guard_invoice_task_owner_v1033
before insert on erp_supply.invoices
for each row execute function erp_supply.trg_guard_domain_task_ownership_v1033();

drop trigger if exists trg_guard_receipt_task_owner_v1033 on erp_supply.receipts;
create trigger trg_guard_receipt_task_owner_v1033
before insert on erp_supply.receipts
for each row execute function erp_supply.trg_guard_domain_task_ownership_v1033();

create or replace function erp_supply.trg_guard_audit_order_comments_v1033()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare v_actor uuid;
begin
  if auth.uid() is null then return new; end if;
  v_actor:=erp_supply.current_profile_id();
  if v_actor is not null and erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_audit_order_comments_v1033 on erp_supply.order_comments;
create trigger trg_guard_audit_order_comments_v1033
before insert on erp_supply.order_comments
for each row execute function erp_supply.trg_guard_audit_order_comments_v1033();

create or replace function erp_supply.trg_guard_order_issue_write_v1033()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare
  v_actor uuid;
  v_task erp_supply.order_tasks%rowtype;
begin
  if auth.uid() is null then return new; end if;
  v_actor:=erp_supply.current_profile_id();
  if v_actor is null then raise exception 'Usuario sin perfil operativo activo' using errcode='42501'; end if;

  if erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;

  if upper(new.issue_type) in('NOVELTY','REPORT') then
    -- Ventas conserva el flujo específico de no-entrega, que se resuelve en Logística.
    if upper(coalesce(new.source_code,''))='NO_DELIVERY'
       and (erp_supply.has_role('ventas') or erp_supply.has_role('super_admin')) then
      return new;
    end if;

    select * into v_task
    from erp_supply.order_tasks
    where order_id=new.order_id
      and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
    order by sequence_no desc
    limit 1;

    if not found then
      raise exception 'El pedido no tiene una tarea operativa activa';
    end if;

    if not erp_supply.active_task_owned_by_actor(new.order_id,v_task.step_code,v_actor,false) then
      raise exception 'Solo el responsable de la tarea o Jefatura puede registrar una novedad bloqueante' using errcode='42501';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_order_issue_write_v1033 on erp_supply.order_issues;
create trigger trg_guard_order_issue_write_v1033
before insert on erp_supply.order_issues
for each row execute function erp_supply.trg_guard_order_issue_write_v1033();

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

  if upper(new.request_type)='CANCELLATION' then
    v_source:=coalesce(new.request_payload->>'source','');
    if v_source<>'ORDER_CANCELLATION_V10_22_4' then
      raise exception 'Usa el botón específico Solicitar cancelación para este pedido';
    end if;
    return new;
  end if;

  if not erp_supply.can_access_module('approvals','create')
     and not erp_supply.has_role('super_admin') then
    raise exception 'No autorizado para solicitar aprobaciones' using errcode='42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_approval_insert_v1033 on erp_supply.approval_requests;
create trigger trg_guard_approval_insert_v1033
before insert on erp_supply.approval_requests
for each row execute function erp_supply.trg_guard_approval_insert_v1033();

create or replace function erp_supply.trg_guard_approval_decision_v1033()
returns trigger
language plpgsql
security definer
set search_path = erp_supply, public, auth, pg_catalog
as $$
declare v_actor uuid; v_roles text[];
begin
  if old.status is not distinct from new.status or old.status<>'PENDING' then return new; end if;
  if new.status not in('APPROVED','REJECTED','EXECUTED') then return new; end if;
  if auth.uid() is null then return new; end if;

  v_actor:=erp_supply.current_profile_id();
  if v_actor is null then raise exception 'Usuario sin perfil operativo activo' using errcode='42501'; end if;
  v_roles:=erp_supply.current_roles();

  if erp_supply.profile_is_read_only_auditor(v_actor) then
    raise exception 'Auditoría es un perfil de solo lectura' using errcode='42501';
  end if;

  if old.request_type='CANCELLATION' then
    if not erp_supply.has_role('jefe_logistica') then
      raise exception 'Solo Jefatura Logística puede decidir la cancelación de un pedido' using errcode='42501';
    end if;
    return new;
  end if;

  if not erp_supply.can_access_module('approvals','approve') then
    raise exception 'No autorizado para decidir esta solicitud' using errcode='42501';
  end if;

  if old.assigned_profile_id is not null
     and old.assigned_profile_id<>v_actor
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'La solicitud está asignada a otro responsable' using errcode='42501';
  end if;

  if old.assigned_role_code is not null
     and not (old.assigned_role_code=any(v_roles))
     and not (erp_supply.has_role('super_admin') or erp_supply.has_role('gerencia') or erp_supply.has_role('jefe_logistica')) then
    raise exception 'La solicitud está asignada a otro rol' using errcode='42501';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_approval_decision_v1033 on erp_supply.approval_requests;
create trigger trg_guard_approval_decision_v1033
before update of status on erp_supply.approval_requests
for each row execute function erp_supply.trg_guard_approval_decision_v1033();

-- ACL explícita para helpers internos.
revoke all on function erp_supply.profile_is_read_only_auditor(uuid) from public;
revoke all on function erp_supply.active_task_owned_by_actor(uuid,text,uuid,boolean) from public;
revoke all on function erp_supply.trg_guard_domain_task_ownership_v1033() from public;
revoke all on function erp_supply.trg_guard_audit_order_comments_v1033() from public;
revoke all on function erp_supply.trg_guard_order_issue_write_v1033() from public;
revoke all on function erp_supply.trg_guard_approval_insert_v1033() from public;
revoke all on function erp_supply.trg_guard_approval_decision_v1033() from public;
revoke all on function erp_supply.trg_forbid_automated_test_orders() from public;
