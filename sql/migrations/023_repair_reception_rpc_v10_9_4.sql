-- ERP EI V10.9.4
-- Reparación de Recepción: restaura el RPC transaccional para enviar a Alistamiento y Corte.
-- Esta migración NO reemplaza erp_x_get_order, para conservar la versión posterior de pedidos parciales.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

create or replace function erp_supply.create_task(
  p_order erp_supply.orders,
  p_step text,
  p_sequence integer
)
returns erp_supply.order_tasks
language plpgsql
security definer
set search_path=erp_supply,public
as $$
declare
  v_resolved record;
  v_profile_id uuid;
  v_role_code text;
  v_preferred_text text;
  v_task erp_supply.order_tasks;
begin
  if p_step='ALISTAMIENTO' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,pickingProfileId}','');
    v_role_code:='aux_logistica';
  elsif p_step='CORTE' then
    v_preferred_text:=nullif(p_order.metadata#>>'{receptionAssignment,cutProfileId}','');
    v_role_code:='auxiliar_corte';
  end if;

  if v_preferred_text is not null then
    begin
      v_profile_id:=v_preferred_text::uuid;
    exception when others then
      v_profile_id:=null;
    end;

    if v_profile_id is not null and not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      join erp_supply.step_roles sr
        on sr.role_code=pr.role_code
       and sr.step_code=p_step
       and sr.can_view
      where p.id=v_profile_id
        and p.organization_id=p_order.organization_id
        and p.active
        and pr.role_code=v_role_code
    ) then
      v_profile_id:=null;
    end if;
  end if;

  if v_profile_id is null then
    select * into v_resolved
    from erp_supply.resolve_assignment(
      p_order.organization_id,
      p_step,
      p_order.delivery_route_code,
      p_order.order_type_code
    );
    v_profile_id:=v_resolved.profile_id;
    v_role_code:=v_resolved.role_code;
  end if;

  insert into erp_supply.order_tasks(
    order_id,step_code,sequence_no,queue_code,status,
    assigned_profile_id,assigned_role_code,assigned_at,metadata
  )
  select
    p_order.id,p_step,p_sequence,s.queue_code,
    case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
    v_profile_id,v_role_code,
    case when v_profile_id is null then null else now() end,
    case
      when v_preferred_text is not null and v_profile_id is not null
        then jsonb_build_object('assignedFrom','RECEPCION_PEDIDO')
      else '{}'::jsonb
    end
  from erp_supply.workflow_steps s
  where s.code=p_step
  returning * into v_task;

  if v_task.id is null then
    raise exception 'No existe la etapa %',p_step;
  end if;

  insert into erp_supply.task_checklist(task_id,item_code,label,required,sort_order)
  select v_task.id,t.item_code,t.label,t.required,t.sort_order
  from erp_supply.checklist_templates t
  where t.step_code=p_step and t.active
  on conflict(task_id,item_code) do nothing;

  update erp_supply.orders
  set current_step_code=p_step,
      status=case when v_profile_id is null then 'QUEUED' else 'ASSIGNED' end,
      current_assignee_id=v_profile_id,
      current_role_code=v_role_code,
      version=version+1,
      updated_at=now()
  where id=p_order.id;

  return v_task;
end;
$$;

-- Confirma toda la recepción en una transacción: líneas, cortes, responsables y avance.
create or replace function public.erp_x_confirm_order_reception(
  p_order_id uuid,
  p_payload jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
  v_task erp_supply.order_tasks%rowtype;
  v_line jsonb;
  v_lines jsonb:=coalesce(p_payload->'lines','[]'::jsonb);
  v_line_count integer:=0;
  v_cut_count integer:=0;
  v_picking uuid;
  v_cut uuid;
  v_item_id uuid;
  v_candidate uuid;
  v_used_ids uuid[]:='{}'::uuid[];
  v_quantity numeric;
  v_cut_length numeric;
  v_requires_cut boolean;
  v_description text;
  v_unit text;
  v_source_mode text:=upper(coalesce(nullif(trim(p_payload->>'sourceMode'),''),'CORRECT'));
  v_new_version integer;
  v_result jsonb;
begin
  if not (
    erp_supply.can_access_module('receiving','update')
    or erp_supply.has_role('super_admin')
    or erp_supply.has_role('jefe_logistica')
  ) then
    raise exception 'No autorizado para confirmar Recepción de pedidos' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org
  for update;

  if not found or not erp_supply.can_view_order(v_order.id) then
    raise exception 'Pedido no disponible' using errcode='42501';
  end if;
  if v_order.current_step_code<>'RECEPCION_PEDIDO' then
    raise exception 'El pedido ya no está en Recepción de pedidos';
  end if;
  if jsonb_typeof(v_lines)<>'array' or jsonb_array_length(v_lines)=0 then
    raise exception 'Debe confirmar al menos una línea del pedido';
  end if;
  if v_source_mode not in('CORRECT','PDF','MANUAL') then
    raise exception 'Origen de información inválido';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=v_order.id
    and step_code='RECEPCION_PEDIDO'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc
  limit 1
  for update;

  if not found then
    raise exception 'El pedido no tiene una tarea activa de Recepción';
  end if;
  if v_task.status<>'IN_PROGRESS' then
    raise exception 'Primero debes tomar e iniciar el pedido';
  end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not erp_supply.has_role('super_admin')
     and not erp_supply.has_role('jefe_logistica') then
    raise exception 'El pedido está siendo gestionado por otro usuario' using errcode='42501';
  end if;

  begin
    v_picking:=nullif(p_payload->>'pickingProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de alistamiento inválido';
  end;
  if v_picking is null or not exists(
    select 1
    from erp_supply.profiles p
    join erp_supply.profile_roles pr on pr.profile_id=p.id
    where p.id=v_picking
      and p.organization_id=v_org
      and p.active
      and pr.role_code='aux_logistica'
  ) then
    raise exception 'Selecciona un auxiliar de logística activo';
  end if;

  begin
    v_cut:=nullif(p_payload->>'cutProfileId','')::uuid;
  exception when others then
    raise exception 'Auxiliar de corte inválido';
  end;

  -- Mueve temporalmente los números para permitir reordenar sin colisiones únicas.
  update erp_supply.order_items
  set line_number=line_number+100000,
      metadata=metadata||jsonb_build_object('receptionActive',false),
      updated_at=now()
  where order_id=v_order.id;

  for v_line in select value from jsonb_array_elements(v_lines) loop
    v_line_count:=v_line_count+1;
    if jsonb_typeof(v_line)<>'object' then
      raise exception 'La línea % no es válida',v_line_count;
    end if;

    v_description:=nullif(trim(v_line->>'description'),'');
    begin
      v_quantity:=nullif(v_line->>'quantity','')::numeric;
    exception when others then
      raise exception 'Cantidad inválida en la línea %',v_line_count;
    end;
    v_unit:=upper(coalesce(nullif(trim(v_line->>'unit'),''),'UND'));
    v_requires_cut:=coalesce((v_line->>'requiresCut')::boolean,false);
    begin
      v_cut_length:=nullif(v_line->>'requestedCutLength','')::numeric;
    exception when others then
      raise exception 'Longitud de corte inválida en la línea %',v_line_count;
    end;

    if v_description is null then
      raise exception 'La línea % necesita una descripción',v_line_count;
    end if;
    if v_quantity is null or v_quantity<=0 then
      raise exception 'La línea % necesita una cantidad válida',v_line_count;
    end if;
    if v_requires_cut and (v_cut_length is null or v_cut_length<=0) then
      raise exception 'La línea % necesita una longitud de corte válida',v_line_count;
    end if;
    if v_requires_cut then v_cut_count:=v_cut_count+1; end if;

    v_item_id:=null;
    begin
      v_candidate:=nullif(v_line->>'orderItemId','')::uuid;
    exception when others then
      v_candidate:=null;
    end;

    if v_candidate is not null and exists(
      select 1 from erp_supply.order_items
      where id=v_candidate and order_id=v_order.id
    ) and not (v_candidate=any(v_used_ids)) then
      v_item_id:=v_candidate;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'reference'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and reference=trim(v_line->>'reference')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null and nullif(trim(v_line->>'sku'),'') is not null then
      select id into v_item_id
      from erp_supply.order_items
      where order_id=v_order.id
        and sku=trim(v_line->>'sku')
        and not (id=any(v_used_ids))
      order by created_at
      limit 1;
    end if;

    if v_item_id is null then
      insert into erp_supply.order_items(
        order_id,line_number,sku,reference,description,quantity,unit,
        warehouse_location,requires_cut,requested_cut_length,dimensions,metadata
      ) values(
        v_order.id,v_line_count,nullif(trim(v_line->>'sku'),''),
        nullif(trim(v_line->>'reference'),''),v_description,v_quantity,v_unit,
        nullif(trim(v_line->>'warehouseLocation'),''),v_requires_cut,
        case when v_requires_cut then v_cut_length else null end,
        case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
          then coalesce(v_line->'dimensions','{}'::jsonb) else '{}'::jsonb end,
        case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
          then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
        || jsonb_build_object(
          'receptionActive',true,
          'receptionSource',v_source_mode,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ) returning id into v_item_id;
    else
      update erp_supply.order_items
      set line_number=v_line_count,
          sku=nullif(trim(v_line->>'sku'),''),
          reference=nullif(trim(v_line->>'reference'),''),
          description=v_description,
          quantity=v_quantity,
          unit=v_unit,
          warehouse_location=nullif(trim(v_line->>'warehouseLocation'),''),
          requires_cut=v_requires_cut,
          requested_cut_length=case when v_requires_cut then v_cut_length else null end,
          dimensions=case when jsonb_typeof(coalesce(v_line->'dimensions','{}'::jsonb))='object'
            then coalesce(v_line->'dimensions','{}'::jsonb) else dimensions end,
          metadata=metadata
            || case when jsonb_typeof(coalesce(v_line->'metadata','{}'::jsonb))='object'
                 then coalesce(v_line->'metadata','{}'::jsonb) else '{}'::jsonb end
            || jsonb_build_object(
              'receptionActive',true,
              'receptionSource',v_source_mode,
              'confirmedAt',now(),
              'confirmedBy',v_actor
            ),
          updated_at=now()
      where id=v_item_id;
    end if;

    v_used_ids:=array_append(v_used_ids,v_item_id);
  end loop;

  if v_cut_count>0 then
    if v_cut is null or not exists(
      select 1
      from erp_supply.profiles p
      join erp_supply.profile_roles pr on pr.profile_id=p.id
      where p.id=v_cut
        and p.organization_id=v_org
        and p.active
        and pr.role_code='auxiliar_corte'
    ) then
      raise exception 'Selecciona un auxiliar de corte activo';
    end if;
  else
    v_cut:=null;
  end if;

  -- Los registros antiguos con relaciones de recepción se conservan, pero dejan de formar parte del pedido operativo.
  delete from erp_supply.order_items i
  where i.order_id=v_order.id
    and not (i.id=any(v_used_ids))
    and not exists(select 1 from erp_supply.receipt_lines rl where rl.order_item_id=i.id)
    and not exists(select 1 from erp_supply.cut_jobs cj where cj.order_item_id=i.id);

  update erp_supply.task_checklist
  set completed=true,
      completed_by=v_actor,
      completed_at=now(),
      note=case item_code
        when 'DOCUMENTS' then 'Información comercial validada en Recepción de pedidos'
        when 'ASSIGNMENT' then 'Auxiliares asignados desde Recepción de pedidos'
        else note end,
      metadata=metadata||jsonb_build_object('source','RECEPCION_PEDIDO_V10_6')
  where task_id=v_task.id and item_code in('DOCUMENTS','ASSIGNMENT');

  update erp_supply.orders
  set requires_cut=(v_cut_count>0),
      metadata=metadata||jsonb_build_object(
        'receptionAssignment',jsonb_build_object(
          'pickingProfileId',v_picking,
          'cutProfileId',v_cut,
          'sourceMode',v_source_mode,
          'sourceFileId',nullif(p_payload->>'sourceFileId',''),
          'sourceFileName',nullif(p_payload->>'sourceFileName',''),
          'readerVersion',nullif(p_payload->>'readerVersion',''),
          'lineCount',v_line_count,
          'cutLineCount',v_cut_count,
          'confirmedAt',now(),
          'confirmedBy',v_actor
        )
      ),
      version=version+1,
      updated_at=now()
  where id=v_order.id
  returning version into v_new_version;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'DOMAIN_RECORD','RECEPTION_ASSIGNMENT',
    'RECEPCION_PEDIDO','RECEPCION_PEDIDO',v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object(
      'sourceMode',v_source_mode,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count,
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'sourceFileId',nullif(p_payload->>'sourceFileId',''),
      'readerVersion',nullif(p_payload->>'readerVersion','')
    )
  );

  v_result:=erp_supply.execute_action_internal(
    v_order.id,
    'COMPLETE',
    jsonb_build_object(
      'resultCode','RECEPTION_CONFIRMED',
      'detail','Información validada y auxiliares asignados',
      'pickingProfileId',v_picking,
      'cutProfileId',v_cut,
      'lineCount',v_line_count,
      'cutLineCount',v_cut_count
    ),
    v_actor,
    false,
    v_new_version,
    'RECEPTION-CONFIRM-'||v_order.id::text||'-'||v_new_version::text
  );

  return v_result||jsonb_build_object(
    'receptionConfirmed',true,
    'lines',v_line_count,
    'cutLines',v_cut_count,
    'pickingProfileId',v_picking,
    'cutProfileId',v_cut
  );
end;
$$;

revoke all on function public.erp_x_confirm_order_reception(uuid,jsonb) from public;
grant execute on function public.erp_x_confirm_order_reception(uuid,jsonb) to authenticated;

do $$
begin
  if to_regprocedure('public.erp_x_confirm_order_reception(uuid,jsonb)') is null then
    raise exception 'No fue posible instalar public.erp_x_confirm_order_reception(uuid,jsonb)';
  end if;
end;
$$;

commit;

-- Fuerza a PostgREST/Supabase a reconocer inmediatamente la firma nueva.
notify pgrst, 'reload schema';

-- Debe devolver: public.erp_x_confirm_order_reception(uuid,jsonb)
select to_regprocedure('public.erp_x_confirm_order_reception(uuid,jsonb)') as rpc_instalado;
