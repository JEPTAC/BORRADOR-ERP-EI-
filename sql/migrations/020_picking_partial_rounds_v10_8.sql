-- ERP Electroingeniería V10.8
-- Alistamiento guiado, verificación línea a línea y rondas parciales del mismo pedido.
-- Ejecutar una sola vez en Supabase SQL Editor.

begin;

create table if not exists erp_supply.picking_rounds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references erp_supply.organizations(id),
  order_id uuid not null references erp_supply.orders(id) on delete cascade,
  task_id uuid not null references erp_supply.order_tasks(id) on delete cascade,
  round_no integer not null check (round_no > 0),
  status text not null check (status in ('COMPLETE','PARTIAL')),
  picked_profile_id uuid not null references erp_supply.profiles(id),
  total_lines integer not null default 0,
  found_lines integer not null default 0,
  missing_lines integer not null default 0,
  started_at timestamptz not null,
  completed_at timestamptz not null,
  raw_seconds bigint not null default 0,
  business_seconds bigint not null default 0,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(order_id,round_no),
  unique(task_id)
);

create table if not exists erp_supply.picking_round_items (
  id uuid primary key default gen_random_uuid(),
  picking_round_id uuid not null references erp_supply.picking_rounds(id) on delete cascade,
  order_item_id uuid not null references erp_supply.order_items(id) on delete cascade,
  result text not null check (result in ('FOUND','MISSING')),
  novelty text,
  quantity numeric(18,4) not null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique(picking_round_id,order_item_id),
  check (result='FOUND' or nullif(trim(novelty),'') is not null)
);

create index if not exists idx_picking_rounds_order on erp_supply.picking_rounds(order_id,round_no);
create index if not exists idx_picking_rounds_status on erp_supply.picking_rounds(organization_id,status,completed_at desc);
create index if not exists idx_picking_round_items_item on erp_supply.picking_round_items(order_item_id,created_at desc);

create or replace function public.erp_x_confirm_picking_round(
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
  v_round erp_supply.picking_rounds%rowtype;
  v_result jsonb;
  v_row jsonb;
  v_rows jsonb:=coalesce(p_payload->'items','[]'::jsonb);
  v_item erp_supply.order_items%rowtype;
  v_item_id uuid;
  v_seen uuid[]:='{}'::uuid[];
  v_round_no integer;
  v_pending integer;
  v_processed integer:=0;
  v_found integer:=0;
  v_missing integer:=0;
  v_found_cut_count integer:=0;
  v_status text;
  v_novelty text;
  v_started timestamptz;
  v_version integer;
  v_fulfillment jsonb;
  v_found_ids jsonb:='[]'::jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','update')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then
    raise exception 'No autorizado para confirmar Alistamiento' using errcode='42501';
  end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)
  for update;

  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;
  if v_order.current_step_code<>'ALISTAMIENTO' then raise exception 'El pedido no está en Alistamiento'; end if;
  if jsonb_typeof(v_rows)<>'array' or jsonb_array_length(v_rows)=0 then
    raise exception 'Debes verificar las líneas pendientes del pedido';
  end if;

  select * into v_task
  from erp_supply.order_tasks
  where order_id=v_order.id and step_code='ALISTAMIENTO'
    and status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')
  order by sequence_no desc limit 1 for update;

  if not found then raise exception 'El pedido no tiene una tarea activa de Alistamiento'; end if;
  if v_task.status<>'IN_PROGRESS' then raise exception 'Primero debes tomar el pedido'; end if;
  if v_task.assigned_profile_id is distinct from v_actor
     and not erp_supply.has_role('jefe_logistica')
     and not erp_supply.has_role('super_admin') then
    raise exception 'El pedido está siendo gestionado por otro usuario' using errcode='42501';
  end if;

  select count(*) into v_pending
  from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.item_status not in('FULFILLED','CANCELLED');

  if v_pending=0 then raise exception 'El pedido no tiene mercancía pendiente de verificar'; end if;
  if jsonb_array_length(v_rows)<>v_pending then
    raise exception 'Debes marcar todas las líneas pendientes antes de enviar a facturación';
  end if;

  select coalesce(max(round_no),0)+1 into v_round_no
  from erp_supply.picking_rounds where order_id=v_order.id;

  v_started:=coalesce(
    (select min(s.started_at) from erp_supply.task_sessions s where s.task_id=v_task.id and s.ended_at is null),
    v_task.started_at,
    now()
  );

  insert into erp_supply.picking_rounds(
    organization_id,order_id,task_id,round_no,status,picked_profile_id,
    total_lines,found_lines,missing_lines,started_at,completed_at,metadata
  ) values(
    v_org,v_order.id,v_task.id,v_round_no,'COMPLETE',v_actor,
    v_pending,0,0,v_started,now(),jsonb_build_object('source','ALISTAMIENTO_V10_8')
  ) returning * into v_round;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    if jsonb_typeof(v_row)<>'object' then raise exception 'Resultado de línea inválido'; end if;
    v_item_id:=erp_supply.safe_uuid(v_row->>'orderItemId');
    if v_item_id is null or v_item_id=any(v_seen) then raise exception 'Hay una línea inválida o repetida'; end if;

    select * into v_item
    from erp_supply.order_items
    where id=v_item_id and order_id=v_order.id
      and coalesce(metadata->>'receptionActive','true')<>'false'
      and item_status not in('FULFILLED','CANCELLED')
    for update;
    if not found then raise exception 'Una línea ya no está pendiente en este pedido'; end if;

    v_status:=upper(coalesce(nullif(trim(v_row->>'result'),''),''));
    if v_status not in('FOUND','MISSING') then raise exception 'Marca Encontrado o No encontrado en todas las líneas'; end if;
    v_novelty:=nullif(trim(v_row->>'novelty'),'');
    if v_status='MISSING' and v_novelty is null then
      raise exception 'Explica por qué no se encontró la línea %',v_item.line_number;
    end if;

    insert into erp_supply.picking_round_items(
      picking_round_id,order_item_id,result,novelty,quantity,metadata
    ) values(
      v_round.id,v_item.id,v_status,v_novelty,v_item.quantity,
      jsonb_build_object('lineNumber',v_item.line_number,'sku',v_item.sku,'reference',v_item.reference)
    );

    if v_status='FOUND' then
      v_found:=v_found+1;
      if v_item.requires_cut then v_found_cut_count:=v_found_cut_count+1; end if;
      v_found_ids:=v_found_ids||jsonb_build_array(v_item.id);
      update erp_supply.order_items
      set item_status='FULFILLED',
          metadata=metadata||jsonb_build_object(
            'fulfillmentStatus','FULFILLED','fulfilledRound',v_round_no,
            'fulfilledAt',now(),'fulfilledBy',v_actor,'lastNovelty',null
          ),
          updated_at=now()
      where id=v_item.id;
    else
      v_missing:=v_missing+1;
      update erp_supply.order_items
      set item_status='PENDING',
          metadata=metadata||jsonb_build_object(
            'fulfillmentStatus','PENDING','lastCheckedRound',v_round_no,
            'lastCheckedAt',now(),'lastCheckedBy',v_actor,'lastNovelty',v_novelty
          ),
          updated_at=now()
      where id=v_item.id;

      insert into erp_supply.order_comments(order_id,author_profile_id,comment_type,visibility,body,metadata)
      values(
        v_order.id,v_actor,'NOVELTY','INTERNAL',
        format('Línea %s no encontrada: %s',v_item.line_number,v_novelty),
        jsonb_build_object('source','ALISTAMIENTO','roundNo',v_round_no,'orderItemId',v_item.id)
      );
    end if;

    v_processed:=v_processed+1;
    v_seen:=array_append(v_seen,v_item.id);
  end loop;

  if v_processed<>v_pending then raise exception 'No se verificaron todas las líneas pendientes'; end if;
  v_status:=case when v_missing>0 then 'PARTIAL' else 'COMPLETE' end;

  update erp_supply.picking_rounds
  set status=v_status,found_lines=v_found,missing_lines=v_missing,
      metadata=metadata||jsonb_build_object('foundItemIds',v_found_ids)
  where id=v_round.id returning * into v_round;

  update erp_supply.task_checklist
  set completed=true,completed_by=v_actor,completed_at=now(),
      note=case when v_status='PARTIAL'
        then format('Ronda %s enviada con %s línea(s) pendiente(s)',v_round_no,v_missing)
        else format('Ronda %s verificada completamente',v_round_no) end,
      metadata=metadata||jsonb_build_object('source','ALISTAMIENTO_V10_8','roundNo',v_round_no,'result',v_status)
  where task_id=v_task.id and required;

  v_fulfillment:=
    (case when jsonb_typeof(coalesce(v_order.metadata->'fulfillment','{}'::jsonb))='object'
      then coalesce(v_order.metadata->'fulfillment','{}'::jsonb) else '{}'::jsonb end)
    ||jsonb_build_object(
      'status',v_status,
      'partialLabel',(v_status='PARTIAL'),
      'roundCount',v_round_no,
      'activeRound',v_round_no,
      'pendingItemCount',v_missing,
      'foundItemCount',v_found,
      'lastPickingAt',now(),
      'lastPickingBy',v_actor,
      'currentShipmentItemIds',v_found_ids,
      'currentShipmentRequiresCut',(v_found_cut_count>0),
      'firstPartialAt',case
        when v_status='PARTIAL' then coalesce(v_order.metadata#>'{fulfillment,firstPartialAt}',to_jsonb(now()))
        else v_order.metadata#>'{fulfillment,firstPartialAt}' end,
      'completedAt',case when v_status='COMPLETE' then to_jsonb(now()) else 'null'::jsonb end
    );

  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('fulfillment',v_fulfillment),
      requires_cut=(v_found_cut_count>0),
      version=version+1,updated_at=now()
  where id=v_order.id returning version into v_version;

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'DOMAIN_RECORD','PICKING_ROUND',
    'ALISTAMIENTO','ALISTAMIENTO',v_order.status,v_order.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('roundId',v_round.id,'roundNo',v_round_no,'result',v_status,
      'foundLines',v_found,'missingLines',v_missing,'foundItemIds',v_found_ids,
      'currentShipmentRequiresCut',(v_found_cut_count>0))
  );

  v_result:=erp_supply.execute_action_internal(
    v_order.id,'COMPLETE',
    jsonb_build_object(
      'resultCode',case when v_status='PARTIAL' then 'PICKING_PARTIAL' else 'PICKING_COMPLETE' end,
      'detail',case when v_status='PARTIAL'
        then format('Alistamiento parcial: %s encontrada(s), %s pendiente(s)',v_found,v_missing)
        else format('Alistamiento completo: %s línea(s) encontrada(s)',v_found) end,
      'pickingRoundId',v_round.id,'roundNo',v_round_no,
      'foundLines',v_found,'missingLines',v_missing,'partial',(v_status='PARTIAL'),
      'currentShipmentRequiresCut',(v_found_cut_count>0)
    ),
    v_actor,false,v_version,
    'PICKING-ROUND-'||v_order.id::text||'-'||v_round_no::text
  );

  update erp_supply.picking_rounds r
  set raw_seconds=t.raw_seconds,business_seconds=t.business_seconds,
      completed_at=coalesce(t.completed_at,r.completed_at)
  from erp_supply.order_tasks t where r.id=v_round.id and t.id=r.task_id;

  return v_result||jsonb_build_object(
    'pickingConfirmed',true,'roundId',v_round.id,'roundNo',v_round_no,
    'result',v_status,'foundLines',v_found,'missingLines',v_missing,
    'partial',(v_status='PARTIAL')
  );
end;
$$;

create or replace function public.erp_x_resume_partial_picking(p_order_id uuid)
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
  v_sequence integer;
  v_pending integer;
  v_fulfillment jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','update')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
  ) then raise exception 'No autorizado para retomar Alistamiento' using errcode='42501'; end if;

  select * into v_order
  from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id)
  for update;
  if not found then raise exception 'Pedido no disponible' using errcode='42501'; end if;

  select count(*) into v_pending from erp_supply.order_items i
  where i.order_id=v_order.id
    and coalesce(i.metadata->>'receptionActive','true')<>'false'
    and i.item_status not in('FULFILLED','CANCELLED');

  if coalesce(v_order.metadata#>>'{fulfillment,status}','')<>'PARTIAL' or v_pending=0 then
    raise exception 'El pedido no tiene mercancía parcial pendiente';
  end if;
  if exists(select 1 from erp_supply.order_tasks t where t.order_id=v_order.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')) then
    raise exception 'La salida parcial actual debe finalizar antes de retomar lo pendiente';
  end if;
  if v_order.status<>'CLOSED' then
    raise exception 'El pedido parcial todavía no ha terminado su salida anterior';
  end if;

  select coalesce(max(sequence_no),0)+1 into v_sequence from erp_supply.order_tasks where order_id=v_order.id;
  v_fulfillment:=coalesce(v_order.metadata->'fulfillment','{}'::jsonb)||jsonb_build_object(
    'status','PARTIAL','partialLabel',true,'pendingItemCount',v_pending,
    'resumeRequestedAt',now(),'resumeRequestedBy',v_actor
  );
  update erp_supply.orders
  set metadata=metadata||jsonb_build_object('fulfillment',v_fulfillment),
      closed_at=null,version=version+1,updated_at=now()
  where id=v_order.id returning * into v_order;

  select * into v_task from erp_supply.create_task(v_order,'ALISTAMIENTO',v_sequence);

  insert into erp_supply.order_events(
    organization_id,order_id,task_id,event_type,action_code,
    from_step_code,to_step_code,from_status,to_status,
    actor_profile_id,actor_role_code,payload
  ) values(
    v_org,v_order.id,v_task.id,'WORKFLOW_ACTION','PICKING_RESUME',
    'CLOSED','ALISTAMIENTO','CLOSED',v_task.status,
    v_actor,(erp_supply.current_roles())[1],
    jsonb_build_object('pendingItems',v_pending,'sequenceNo',v_sequence)
  );

  return jsonb_build_object('success',true,'orderId',v_order.id,'currentStep','ALISTAMIENTO',
    'status',v_task.status,'pendingItems',v_pending,'version',(select version from erp_supply.orders where id=v_order.id));
end;
$$;

create or replace function public.erp_x_picking_pending(
  p_search text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_profile uuid:=erp_supply.require_profile();
  v_page integer:=greatest(coalesce(p_page,1),1);
  v_size integer:=least(greatest(coalesce(p_page_size,50),1),250);
  v_total bigint;
  v_items jsonb;
begin
  if not (
    erp_supply.can_access_module('picking','read')
    or erp_supply.has_role('aux_logistica')
    or erp_supply.has_role('jefe_logistica')
    or erp_supply.has_role('super_admin')
    or erp_supply.has_role('auditoria')
  ) then raise exception 'No autorizado para consultar parciales' using errcode='42501'; end if;

  with rows as (
    select o.id
    from erp_supply.orders o
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'
      and exists(select 1 from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED'))
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
  ) select count(*) into v_total from rows;

  with rows as (
    select o.*,
      (select count(*) from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED')) pending_count,
      (select count(*) from erp_supply.picking_rounds r where r.order_id=o.id) round_count,
      not exists(select 1 from erp_supply.order_tasks t where t.order_id=o.id and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED'))
        and o.status='CLOSED' can_resume,
      coalesce((select p.display_name from erp_supply.profiles p where p.id=erp_supply.safe_uuid(o.metadata#>>'{receptionAssignment,pickingProfileId}')),'Auxiliar asignado') picking_name,
      erp_supply.business_seconds_between(v_org,
        coalesce(erp_supply.safe_timestamptz(o.metadata#>>'{fulfillment,firstPartialAt}'),o.updated_at),now()) age_seconds
    from erp_supply.orders o
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'
      and exists(select 1 from erp_supply.order_items i where i.order_id=o.id
        and coalesce(i.metadata->>'receptionActive','true')<>'false'
        and i.item_status not in('FULFILLED','CANCELLED'))
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
    order by coalesce(erp_supply.safe_timestamptz(o.metadata#>>'{fulfillment,firstPartialAt}'),o.updated_at)
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'clientName',client_name,'orderType',order_type_code,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep','ALISTAMIENTO',
    'stepName','Alistamiento pendiente','status',case when can_resume then 'WAITING' else status end,
    'priority',priority,'assigneeName',picking_name,'ageBusinessSeconds',age_seconds,
    'pendingItemCount',pending_count,'pickingRoundCount',round_count,'fulfillmentStatus','PARTIAL',
    'canResume',can_resume,'actualStep',current_step_code,'actualStatus',status,'version',version
  )),'[]'::jsonb) into v_items from rows;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object(
    'page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::integer
  ),'generatedAt',now());
end;
$$;

create or replace function public.erp_x_partial_fulfillment_metrics(
  p_date_from date default current_date-30,
  p_date_to date default current_date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if p_date_from is null or p_date_to is null or p_date_from>p_date_to then raise exception 'Rango de fechas inválido'; end if;
  return jsonb_build_object(
    'summary',jsonb_build_object(
      'partialPending',(select count(*) from erp_supply.orders o where o.organization_id=v_org and not o.is_test
        and erp_supply.can_view_order(o.id) and coalesce(o.metadata#>>'{fulfillment,status}','')='PARTIAL'),
      'completedAfterPartial',(select count(*) from erp_supply.orders o where o.organization_id=v_org and not o.is_test
        and erp_supply.can_view_order(o.id) and coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE'
        and o.metadata#>>'{fulfillment,firstPartialAt}' is not null)
    ),
    'orders',(select coalesce(jsonb_agg(to_jsonb(x) order by x."firstPartialAt" desc),'[]'::jsonb) from (
      select o.id,o.order_number "orderNumber",o.client_name "clientName",
        coalesce(o.metadata#>>'{fulfillment,status}','PARTIAL') status,
        count(r.id)::integer "roundCount",
        coalesce((select count(*) from erp_supply.order_items i where i.order_id=o.id and i.item_status not in('FULFILLED','CANCELLED')),0)::integer "pendingItemCount",
        min(r.started_at) "firstStartedAt",
        min(r.completed_at) filter(where r.status='PARTIAL') "firstPartialAt",
        max(r.completed_at) filter(where coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE') "completedAt",
        round((coalesce((array_agg(r.business_seconds order by r.round_no))[1],0)/3600.0)::numeric,2) "partialHours",
        round((erp_supply.business_seconds_between(v_org,min(r.started_at),
          case when coalesce(o.metadata#>>'{fulfillment,status}','')='COMPLETE' then max(r.completed_at) else now() end)/3600.0)::numeric,2) "realHours"
      from erp_supply.orders o
      join erp_supply.picking_rounds r on r.order_id=o.id
      where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
        and exists(select 1 from erp_supply.picking_rounds rp where rp.order_id=o.id and rp.status='PARTIAL')
        and r.completed_at::date between p_date_from and p_date_to
      group by o.id,o.order_number,o.client_name,o.metadata
    ) x),
    'range',jsonb_build_object('from',p_date_from,'to',p_date_to)
  );
end;
$$;

-- Mantiene la etiqueta parcial en todas las colas sin crear un segundo pedido.
create or replace function public.erp_x_list_orders(
  p_search text default null,
  p_step text default null,
  p_status text default null,
  p_order_type text default null,
  p_route text default null,
  p_assignment text default 'ALL',
  p_page integer default 1,
  p_page_size integer default 50,
  p_include_history boolean default true
)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile uuid:=erp_supply.require_profile(); v_page int:=greatest(coalesce(p_page,1),1); v_size int:=least(greatest(coalesce(p_page_size,50),1),250); v_total bigint; v_items jsonb;
begin
  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o
    left join erp_supply.profiles p on p.id=o.current_assignee_id
    join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
  ) select count(*) into v_total from filtered;

  with filtered as (
    select o.*,p.display_name assignee_name,s.name step_name,s.sla_hours,
      erp_supply.business_seconds_between(v_org,o.updated_at,now()) age_business_seconds
    from erp_supply.orders o left join erp_supply.profiles p on p.id=o.current_assignee_id join erp_supply.workflow_steps s on s.code=o.current_step_code
    where o.organization_id=v_org and not o.is_test and erp_supply.can_view_order(o.id)
      and (p_include_history or not o.is_history)
      and (p_search is null or p_search='' or lower(o.order_number||' '||o.client_name||' '||coalesce(o.external_reference,'')) like '%'||lower(p_search)||'%')
      and (p_step is null or p_step='' or o.current_step_code=p_step)
      and (p_status is null or p_status='' or o.status=p_status)
      and (p_order_type is null or p_order_type='' or o.order_type_code=p_order_type)
      and (p_route is null or p_route='' or o.delivery_route_code=p_route)
      and (upper(coalesce(p_assignment,'ALL'))='ALL' or (upper(p_assignment)='MINE' and o.current_assignee_id=v_profile) or (upper(p_assignment)='UNASSIGNED' and o.current_assignee_id is null))
    order by case o.priority when 'CRITICAL' then 1 when 'URGENT' then 2 when 'HIGH' then 3 when 'MEDIUM' then 4 else 5 end,o.updated_at desc
    offset (v_page-1)*v_size limit v_size
  ) select coalesce(jsonb_agg(jsonb_build_object(
    'id',id,'orderNumber',order_number,'externalReference',external_reference,'orderType',order_type_code,'clientName',client_name,
    'paymentCondition',payment_condition_code,'route',delivery_route_code,'currentStep',current_step_code,'stepName',step_name,
    'status',status,'priority',priority,'requiresCut',requires_cut,'requiresPurchase',requires_purchase,'assigneeId',current_assignee_id,
    'assigneeName',assignee_name,'roleCode',current_role_code,'ageBusinessSeconds',age_business_seconds,
    'slaExceeded',(sla_hours is not null and age_business_seconds>sla_hours*3600),'version',version,'isHistory',is_history,'createdAt',created_at,'updatedAt',updated_at,
    'fulfillmentStatus',metadata#>>'{fulfillment,status}',
    'partialLabel',coalesce((metadata#>>'{fulfillment,partialLabel}')::boolean,false),
    'pendingItemCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,pendingItemCount}'),0),
    'pickingRoundCount',coalesce(erp_supply.safe_integer(metadata#>>'{fulfillment,roundCount}'),0)
  )),'[]'::jsonb) into v_items from filtered;

  return jsonb_build_object('items',v_items,'pagination',jsonb_build_object('page',v_page,'pageSize',v_size,'totalItems',v_total,'totalPages',ceil(v_total::numeric/v_size)::int),'generatedAt',now());
end;
$$;

-- El expediente incluye rondas e historial de verificación.
create or replace function public.erp_x_get_order(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_org uuid:=erp_supply.current_org_id();
  v_order erp_supply.orders%rowtype;
begin
  erp_supply.require_profile();
  select * into v_order from erp_supply.orders
  where id=p_order_id and organization_id=v_org and erp_supply.can_view_order(id);
  if not found then raise exception 'Pedido no encontrado'; end if;

  return jsonb_build_object(
    'order',to_jsonb(v_order),
    'items',(select coalesce(jsonb_agg(to_jsonb(i) order by line_number),'[]'::jsonb)
      from erp_supply.order_items i where i.order_id=p_order_id and coalesce(i.metadata->>'receptionActive','true')<>'false'),
    'tasks',(select coalesce(jsonb_agg(to_jsonb(t) order by sequence_no),'[]'::jsonb) from erp_supply.order_tasks t where t.order_id=p_order_id),
    'sessions',(select coalesce(jsonb_agg(to_jsonb(s) order by s.started_at),'[]'::jsonb) from erp_supply.task_sessions s join erp_supply.order_tasks t on t.id=s.task_id where t.order_id=p_order_id),
    'checklist',(select coalesce(jsonb_agg(to_jsonb(c) order by c.sort_order),'[]'::jsonb) from erp_supply.task_checklist c join erp_supply.order_tasks t on t.id=c.task_id where t.order_id=p_order_id),
    'events',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'eventType',e.event_type,'actionCode',e.action_code,'fromStep',e.from_step_code,'toStep',e.to_step_code,'fromStatus',e.from_status,'toStatus',e.to_status,'actorName',p.display_name,'actorRole',e.actor_role_code,'payload',e.payload,'createdAt',e.created_at) order by e.created_at),'[]'::jsonb) from erp_supply.order_events e left join erp_supply.profiles p on p.id=e.actor_profile_id where e.order_id=p_order_id),
    'comments',(select coalesce(jsonb_agg(jsonb_build_object('id',c.id,'type',c.comment_type,'visibility',c.visibility,'body',c.body,'metadata',c.metadata,'author',p.display_name,'createdAt',c.created_at) order by c.created_at),'[]'::jsonb) from erp_supply.order_comments c join erp_supply.profiles p on p.id=c.author_profile_id where c.order_id=p_order_id),
    'approvals',(select coalesce(jsonb_agg(to_jsonb(a) order by a.created_at),'[]'::jsonb) from erp_supply.approval_requests a where a.order_id=p_order_id),
    'files',(select coalesce(jsonb_agg(to_jsonb(f) order by f.created_at),'[]'::jsonb) from erp_supply.drive_files f where f.order_id=p_order_id),
    'purchaseOrders',(select coalesce(jsonb_agg(to_jsonb(po) order by po.created_at),'[]'::jsonb) from erp_supply.purchase_orders po where po.order_id=p_order_id),
    'financialValidations',(select coalesce(jsonb_agg(to_jsonb(fv) order by fv.created_at),'[]'::jsonb) from erp_supply.financial_validations fv where fv.order_id=p_order_id),
    'receipts',(select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at),'[]'::jsonb) from erp_supply.receipts r where r.order_id=p_order_id),
    'cutJobs',(select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at),'[]'::jsonb) from erp_supply.cut_jobs c where c.order_id=p_order_id),
    'invoices',(select coalesce(jsonb_agg(to_jsonb(i) order by i.created_at),'[]'::jsonb) from erp_supply.invoices i where i.order_id=p_order_id),
    'deliveries',(select coalesce(jsonb_agg(to_jsonb(d) order by d.created_at),'[]'::jsonb) from erp_supply.deliveries d where d.order_id=p_order_id),
    'pickingRounds',(select coalesce(jsonb_agg(to_jsonb(r) order by r.round_no),'[]'::jsonb) from erp_supply.picking_rounds r where r.order_id=p_order_id),
    'pickingRoundItems',(select coalesce(jsonb_agg(to_jsonb(ri) order by r.round_no,i.line_number),'[]'::jsonb)
      from erp_supply.picking_round_items ri join erp_supply.picking_rounds r on r.id=ri.picking_round_id
      join erp_supply.order_items i on i.id=ri.order_item_id where r.order_id=p_order_id),
    'actions',public.erp_x_get_actions(p_order_id)
  );
end;
$$;

revoke all on function public.erp_x_confirm_picking_round(uuid,jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_resume_partial_picking(uuid) from public,anon,authenticated;
revoke all on function public.erp_x_picking_pending(text,integer,integer) from public,anon,authenticated;
revoke all on function public.erp_x_partial_fulfillment_metrics(date,date) from public,anon,authenticated;
grant execute on function public.erp_x_confirm_picking_round(uuid,jsonb) to authenticated;
grant execute on function public.erp_x_resume_partial_picking(uuid) to authenticated;
grant execute on function public.erp_x_picking_pending(text,integer,integer) to authenticated;
grant execute on function public.erp_x_partial_fulfillment_metrics(date,date) to authenticated;
grant execute on function public.erp_x_list_orders(text,text,text,text,text,text,integer,integer,boolean) to authenticated;
grant execute on function public.erp_x_get_order(uuid) to authenticated;

commit;
