-- ERP ELECTROINGENIERIA V10.33.1
-- Autoriza evidencia final de Corte por pertenencia a requerimiento/ejecución,
-- sin relajar la visibilidad genérica de archivos para otros módulos.
create or replace function public.erp_x_register_drive_file(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'erp_supply','public','auth','pg_catalog'
as $function$
declare
  v_actor uuid:=erp_supply.require_profile();
  v_org uuid:=erp_supply.current_org_id();
  v_file erp_supply.drive_files%rowtype;
  v_order_id uuid:=erp_supply.safe_uuid(p_payload->>'orderId');
  v_task_id uuid:=erp_supply.safe_uuid(p_payload->>'taskId');
  v_category text:=upper(coalesce(nullif(trim(p_payload->>'category'),''),'EVIDENCE'));
  v_cut_allowed boolean:=false;
begin
  if v_order_id is not null and not erp_supply.can_view_order(v_order_id) then
    if v_category='CUTTING_EVIDENCE' then
      select exists(
        select 1
        from erp_supply.cut_requirements r
        where r.order_id=v_order_id
          and (
            r.assigned_profile_id=v_actor
            or exists(
              select 1
              from erp_supply.cut_execution_requirements er
              join erp_supply.cut_executions e on e.id=er.execution_id
              where er.cut_requirement_id=r.id
                and e.started_by=v_actor
                and e.status in('IN_PROGRESS','PAUSED','WAITING_EVIDENCE','COMPLETED')
            )
          )
      ) into v_cut_allowed;
    end if;
    if not v_cut_allowed and not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica')) then
      raise exception 'Pedido no disponible' using errcode='42501';
    end if;
  end if;

  if v_task_id is not null and not exists(
    select 1 from erp_supply.order_tasks t
    where t.id=v_task_id and (v_order_id is null or t.order_id=v_order_id)
  ) then
    raise exception 'La tarea indicada no pertenece al pedido';
  end if;

  if nullif(trim(p_payload->>'driveFileId'),'') is null
     or nullif(trim(p_payload->>'fileName'),'') is null then
    raise exception 'Identificador y nombre de archivo requeridos';
  end if;

  insert into erp_supply.drive_files(
    organization_id,order_id,task_id,file_category,drive_file_id,file_name,mime_type,
    web_view_link,web_content_link,size_bytes,uploaded_by,metadata
  ) values(
    v_org,v_order_id,v_task_id,v_category,p_payload->>'driveFileId',p_payload->>'fileName',
    p_payload->>'mimeType',p_payload->>'webViewLink',p_payload->>'webContentLink',
    erp_supply.safe_integer(p_payload->>'sizeBytes'),v_actor,
    coalesce(p_payload->'metadata','{}'::jsonb)||jsonb_build_object('authorizationVersion','10.33.1')
  ) returning * into v_file;

  return jsonb_build_object('success',true,'file',to_jsonb(v_file),'contractVersion','10.33.1');
end;
$function$;
revoke all on function public.erp_x_register_drive_file(jsonb) from public,anon;
grant execute on function public.erp_x_register_drive_file(jsonb) to authenticated,service_role;
