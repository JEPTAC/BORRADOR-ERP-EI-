-- ERP ELECTROINGENIERIA V10.33.1
-- Health Check ampliado con canarios de evidencia de Corte e idempotencia.
create or replace function public.erp_x_health_check()
returns table(section text,check_name text,ok boolean,detail text)
language sql
stable security definer
set search_path to 'erp_supply','public','auth','pg_catalog'
as $function$
with defs as (
  select
    pg_get_functiondef(to_regprocedure('public.erp_x_register_drive_file(jsonb)')) drive_def,
    pg_get_functiondef(to_regprocedure('public.erp_x_execute_action(uuid,text,jsonb,integer,text)')) action_def
)
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
('07_CORTE','Evidencia de Corte autorizada por ejecución',(select position('CUTTING_EVIDENCE' in drive_def)>0 and position('cut_execution_requirements' in drive_def)>0 and position('authorizationVersion' in drive_def)>0 from defs),'El auxiliar de Corte puede registrar evidencia de su propia ejecución'),
('08_INVENTARIO','Inventario operativo vinculado a Siesa',not exists(select 1 from erp_supply.inventory_items where active and material_master_id is null),'No hay ítems activos fuera del maestro oficial'),
('09_FLUJO','Sin tareas activas en pedidos finalizados',not exists(select 1 from erp_supply.orders o join erp_supply.order_tasks t on t.order_id=o.id where o.status in('CLOSED','CANCELLED') and t.status in('QUEUED','ASSIGNED','IN_PROGRESS','WAITING','BLOCKED')),'Estados finales y tareas activas son consistentes'),
('10_IDEMPOTENCIA','Reintento de acciones protegido',(select position('p_idempotency_key is not null and exists' in action_def)>0 and position('return erp_supply.execute_action_internal' in action_def)>position('p_idempotency_key is not null and exists' in action_def) from defs),'Un reintento con la misma clave se resuelve antes del control de versión')
) v(section,check_name,ok,detail)
order by section,check_name
$function$;
revoke all on function public.erp_x_health_check() from public,anon;
grant execute on function public.erp_x_health_check() to authenticated,service_role;
