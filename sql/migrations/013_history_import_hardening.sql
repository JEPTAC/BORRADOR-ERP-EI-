-- ERP Supply Enterprise V10
-- Migration 013: robust, resumable and auditable historical CSV import.

begin;

create or replace function erp_supply.try_boolean(p_value text,p_default boolean default false)
returns boolean
language plpgsql
immutable
as $$
begin
  if p_value is null or btrim(p_value)='' then return p_default; end if;
  case lower(btrim(p_value))
    when '1' then return true; when 'true' then return true; when 't' then return true;
    when 'yes' then return true; when 'si' then return true; when 'sí' then return true; when 'x' then return true;
    when '0' then return false; when 'false' then return false; when 'f' then return false;
    when 'no' then return false;
    else return p_default;
  end case;
end;
$$;

create or replace function erp_supply.try_timestamptz(p_value text,p_default timestamptz default null)
returns timestamptz
language plpgsql
stable
as $$
begin
  if p_value is null or btrim(p_value)='' then return p_default; end if;
  return p_value::timestamptz;
exception when others then
  return p_default;
end;
$$;

create or replace function public.erp_x_import_history(p_file_name text,p_rows jsonb,p_batch_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_batch erp_supply.import_batches%rowtype;
  v_row jsonb;
  v_n integer:=0;
  v_ok integer:=0;
  v_bad integer:=0;
  v_status text;
  v_step text;
  v_type text;
  v_payment text;
  v_route text;
  v_priority text;
  v_created timestamptz;
  v_updated timestamptz;
  v_closed timestamptz;
  v_cancelled timestamptz;
begin
  if not erp_supply.can_access_module('imports','create') then
    raise exception 'No autorizado para importar históricos' using errcode='42501';
  end if;
  if jsonb_typeof(coalesce(p_rows,'null'::jsonb))<>'array' then raise exception 'p_rows debe ser un arreglo JSON'; end if;
  if jsonb_array_length(p_rows)=0 then raise exception 'El lote no contiene filas'; end if;
  if jsonb_array_length(p_rows)>500 then raise exception 'Máximo 500 filas por lote'; end if;
  if nullif(btrim(p_file_name),'') is null then raise exception 'Nombre de archivo requerido'; end if;

  if p_batch_id is null then
    insert into erp_supply.import_batches(organization_id,import_type,file_name,imported_by,total_rows,status)
    values(v_org,'ORDER_HISTORY',btrim(p_file_name),v_actor,jsonb_array_length(p_rows),'PROCESSING')
    returning * into v_batch;
  else
    select * into v_batch from erp_supply.import_batches
    where id=p_batch_id and organization_id=v_org and import_type='ORDER_HISTORY'
    for update;
    if not found then raise exception 'Lote de importación no encontrado'; end if;
    update erp_supply.import_batches
    set total_rows=total_rows+jsonb_array_length(p_rows),status='PROCESSING',completed_at=null
    where id=v_batch.id returning * into v_batch;
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_n:=v_n+1;
    begin
      if nullif(btrim(v_row->>'orderNumber'),'') is null then raise exception 'Número de pedido requerido'; end if;
      if nullif(btrim(v_row->>'clientName'),'') is null then raise exception 'Cliente requerido'; end if;

      v_type:=upper(coalesce(nullif(btrim(v_row->>'orderType'),''),'PVC'));
      v_payment:=upper(coalesce(nullif(btrim(v_row->>'paymentCondition'),''),'CREDIT'));
      v_route:=upper(coalesce(nullif(btrim(v_row->>'deliveryRoute'),''),'LOCAL_DISPATCH'));
      v_priority:=upper(coalesce(nullif(btrim(v_row->>'priority'),''),'MEDIUM'));
      v_status:=upper(coalesce(nullif(btrim(v_row->>'status'),''),'CLOSED'));

      if not exists(select 1 from erp_supply.order_types where code=v_type and active) then raise exception 'Tipo de pedido inválido: %',v_type; end if;
      if not exists(select 1 from erp_supply.payment_conditions where code=v_payment and active) then raise exception 'Condición de pago inválida: %',v_payment; end if;
      if not exists(select 1 from erp_supply.delivery_routes where code=v_route and active) then raise exception 'Ruta inválida: %',v_route; end if;
      if v_priority not in('LOW','MEDIUM','HIGH','URGENT','CRITICAL') then raise exception 'Prioridad inválida: %',v_priority; end if;
      if v_status not in('CLOSED','CANCELLED') then v_status:='CLOSED'; end if;
      v_step:=case when v_status='CLOSED' then 'CLOSED' else coalesce(nullif(upper(v_row->>'currentStep'),''),'CLOSED') end;
      if not exists(select 1 from erp_supply.workflow_steps where code=v_step) then v_step:='CLOSED'; end if;

      v_created:=erp_supply.try_timestamptz(v_row->>'createdAt',now());
      v_updated:=erp_supply.try_timestamptz(v_row->>'updatedAt',v_created);
      v_closed:=case when v_status='CLOSED' then erp_supply.try_timestamptz(v_row->>'closedAt',v_updated) end;
      v_cancelled:=case when v_status='CANCELLED' then erp_supply.try_timestamptz(v_row->>'cancelledAt',v_updated) end;

      insert into erp_supply.orders(
        organization_id,order_number,external_reference,order_type_code,payment_condition_code,delivery_route_code,
        client_name,client_document,client_city,current_step_code,status,priority,requires_cut,requires_purchase,
        source,is_history,metadata,created_at,updated_at,closed_at,cancelled_at
      ) values(
        v_org,btrim(v_row->>'orderNumber'),nullif(btrim(v_row->>'externalReference'),''),v_type,v_payment,v_route,
        btrim(v_row->>'clientName'),nullif(btrim(v_row->>'clientDocument'),''),nullif(btrim(v_row->>'clientCity'),''),
        v_step,v_status,v_priority,erp_supply.try_boolean(v_row->>'requiresCut',false),
        erp_supply.try_boolean(v_row->>'requiresPurchase',v_type='PVE'),'CSV_HISTORY',true,v_row,
        v_created,v_updated,v_closed,v_cancelled
      )
      on conflict(organization_id,order_number) do update set
        external_reference=coalesce(excluded.external_reference,erp_supply.orders.external_reference),
        order_type_code=excluded.order_type_code,payment_condition_code=excluded.payment_condition_code,
        delivery_route_code=excluded.delivery_route_code,client_name=excluded.client_name,
        client_document=coalesce(excluded.client_document,erp_supply.orders.client_document),
        client_city=coalesce(excluded.client_city,erp_supply.orders.client_city),current_step_code=excluded.current_step_code,
        status=excluded.status,priority=excluded.priority,requires_cut=excluded.requires_cut,
        requires_purchase=excluded.requires_purchase,source='CSV_HISTORY',is_history=true,
        metadata=erp_supply.orders.metadata||excluded.metadata,updated_at=greatest(erp_supply.orders.updated_at,excluded.updated_at),
        closed_at=coalesce(excluded.closed_at,erp_supply.orders.closed_at),
        cancelled_at=coalesce(excluded.cancelled_at,erp_supply.orders.cancelled_at);
      v_ok:=v_ok+1;
    exception when others then
      v_bad:=v_bad+1;
      insert into erp_supply.import_errors(batch_id,row_number,error_code,error_message,raw_row)
      values(v_batch.id,v_batch.inserted_rows+v_batch.rejected_rows+v_n,sqlstate,sqlerrm,v_row);
    end;
  end loop;

  update erp_supply.import_batches
  set inserted_rows=inserted_rows+v_ok,rejected_rows=rejected_rows+v_bad,
      status=case when rejected_rows+v_bad=0 then 'COMPLETED' when inserted_rows+v_ok=0 then 'FAILED' else 'PARTIAL' end,
      completed_at=now(),summary=summary||jsonb_build_object('lastChunkRows',v_n,'lastChunkInserted',v_ok,'lastChunkRejected',v_bad,'updatedAt',now())
  where id=v_batch.id returning * into v_batch;

  insert into erp_supply.system_audit(organization_id,actor_profile_id,action,entity_type,entity_id,after_data,metadata)
  values(v_org,v_actor,'IMPORT_HISTORY_CHUNK','IMPORT_BATCH',v_batch.id::text,
    jsonb_build_object('processed',v_n,'inserted',v_ok,'rejected',v_bad,'status',v_batch.status),jsonb_build_object('fileName',p_file_name));

  return jsonb_build_object('success',v_bad=0,'batchId',v_batch.id,'processed',v_n,'inserted',v_ok,'rejected',v_bad,
    'status',v_batch.status,'totals',jsonb_build_object('rows',v_batch.total_rows,'inserted',v_batch.inserted_rows,'rejected',v_batch.rejected_rows));
end;
$$;

revoke all on function public.erp_x_import_history(text,jsonb,uuid) from public,anon,authenticated;
grant execute on function public.erp_x_import_history(text,jsonb,uuid) to authenticated;

commit;
