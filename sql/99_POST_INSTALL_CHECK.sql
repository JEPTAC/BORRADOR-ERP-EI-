-- ERP Electroingeniería V10.25.4
-- Verificación posterior. Solo lectura; no crea ni modifica datos.

select
  to_regnamespace('erp_supply') is not null as esquema_instalado,
  to_regprocedure('public.erp_x_session()') is not null as rpc_sesion,
  to_regprocedure('public.erp_x_create_order(jsonb,text)') is not null as rpc_crear_pedido,
  to_regprocedure('public.erp_x_execute_action(uuid,text,jsonb,integer,text)') is not null as rpc_acciones,
  to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null as bot_matriz_336,
  to_regprocedure('public.erp_x_run_qa_control_suite(boolean)') is not null as bot_controles,
  to_regprocedure('public.erp_x_run_qa_v10_22(boolean)') is not null as qa_integral_v10_22,
  to_regprocedure('public.erp_x_v10_22_self_check()') is not null as autodiagnostico_v10_22,
  to_regprocedure('public.erp_x_flow_integrity()') is not null as integridad_flujos,
  to_regprocedure('public.erp_x_receipt_progress(uuid)') is not null as progreso_recepcion_pve,
  to_regprocedure('public.erp_x_inventory_filtered(jsonb)') is not null as inventario_lista_filtrable_v10_22_3,
  to_regprocedure('public.erp_x_inventory_lots(uuid,text)') is not null as rpc_lotes_inventario,
  to_regprocedure('public.erp_x_request_order_cancellation(uuid,text)') is not null as solicitar_cancelacion_pedido,
  to_regprocedure('public.erp_x_decide_order_cancellation(uuid,text,text)') is not null as decidir_cancelacion_pedido,
  to_regprocedure('public.erp_x_work_my_day(date)') is not null as mi_jornada_v10_23,
  to_regprocedure('public.erp_x_work_create_catalog_item(jsonb)') is not null as catalogo_dinamico_v10_23_1,
  to_regprocedure('public.erp_x_work_propose_assignment(jsonb)') is not null as propuesta_actividad_v10_24,
  to_regprocedure('public.erp_x_work_pending_approvals()') is not null as bandeja_aprobacion_v10_24,
  to_regprocedure('public.erp_x_work_decide_assignment(uuid,text,text,boolean)') is not null as decision_actividad_v10_24,
  to_regprocedure('public.erp_x_work_occupation(date,date,uuid)') is not null as ocupacion_integrada_v10_24,
  to_regprocedure('public.erp_x_work_save_assignment(jsonb)') is not null as planificador_v10_23,
  to_regprocedure('public.erp_x_work_ledger(date,date,uuid)') is not null as libro_mayor_tiempo_v10_23,
  to_regprocedure('public.erp_x_work_analytics(date,date,uuid)') is not null as analitica_capacidad_v10_23,
  to_regprocedure('public.erp_x_work_health()') is not null as diagnostico_actividades_v10_23,
  case when to_regprocedure('public.erp_x_inventory_lots(uuid,text)') is null then false
       else position('x.lot_number' in pg_get_functiondef(to_regprocedure('public.erp_x_inventory_lots(uuid,text)')))=0 end as alias_lot_number_corregido,
  to_regprocedure('erp_supply.initial_step(text,text,boolean)') is null as routing_legacy_eliminado,
  to_regprocedure('erp_supply.initial_step(text,text,boolean,boolean,boolean)') is not null as routing_vigente,
  not has_schema_privilege('anon','erp_supply','USAGE') as anon_sin_esquema,
  not has_schema_privilege('authenticated','erp_supply','USAGE') as navegador_sin_esquema;

select
  count(*) as rpc_erp_x,
  count(*) filter (where p.prosecdef) as security_definer,
  count(*) filter (where has_function_privilege('authenticated',p.oid,'EXECUTE')) as disponibles_authenticated,
  count(*) filter (where has_function_privilege('anon',p.oid,'EXECUTE')) as expuestos_anon
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and p.proname like 'erp_x_%';


select
  exists(
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='order_tasks'
      and t.tgname='trg_require_complete_receipt_before_task_complete' and not t.tgisinternal and t.tgenabled<>'D'
  ) as gate_recepcion_pve,
  exists(
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='picking_round_items'
      and t.tgname='trg_require_collected_cut_for_picking' and not t.tgisinternal and t.tgenabled<>'D'
  ) as gate_corte_recogido_alistamiento,
  exists(
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='orders'
      and t.tgname='trg_cleanup_cancelled_order' and not t.tgisinternal and t.tgenabled<>'D'
  ) as limpieza_cancelacion_activa,
  exists(
    select 1 from pg_trigger t join pg_class c on c.oid=t.tgrelid join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='erp_supply' and c.relname='approval_requests'
      and t.tgname='trg_guard_cancellation_decision' and not t.tgisinternal and t.tgenabled<>'D'
  ) as decision_cancelacion_solo_jefatura;

select *
from public.erp_x_health_check()
order by section,check_name;

select *
from public.erp_x_health_check()
where not ok
order by section,check_name;

-- Ejecutar como Super Admin para una comprobación completa de arquitectura y datos:
select public.erp_x_v10_22_self_check();
select public.erp_x_flow_integrity();

-- V10.23 · Estructura y salud del subsistema transversal de actividades.
select
  exists(select 1 from erp_supply.modules where code='workforce' and active) as modulo_mi_jornada_activo,
  not exists(
    select 1 from erp_supply.roles r
    where r.active and not exists(
      select 1 from erp_supply.role_module_permissions p
      where p.role_code=r.code and p.module_code='workforce' and p.can_read and p.can_create
    )
  ) as todos_los_roles_con_mi_jornada,
  to_regclass('erp_supply.work_activity_catalog') is not null as catalogo_actividades,
  to_regclass('erp_supply.work_assignments') is not null as planificacion_actividades,
  to_regclass('erp_supply.work_executions') is not null as ejecuciones_cronometradas,
  to_regclass('erp_supply.work_evidence') is not null as evidencias_actividades,
  to_regclass('erp_supply.work_delivery_reviews') is not null as revision_entregables,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='work_activity_catalog' and column_name='catalog_origin') as origen_catalogo_v10_23_1,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='work_activity_catalog' and column_name='created_by') as creador_catalogo_v10_23_1;

-- Ejecutar con Super Admin, Gerencia, Jefatura Logística o Auditoría.
select * from public.erp_x_work_health();



-- V10.24 · Gobierno y ocupación integrada.
select
  exists(select 1 from erp_supply.roles where code='lider_logistica' and active) as rol_lider_logistico_activo,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='work_assignments' and column_name='approval_status') as gobierno_aprobacion_activo,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='work_assignments' and column_name='request_reason') as motivo_solicitud_activo,
  pg_get_functiondef('erp_supply.work_classified_business_seconds(uuid,timestamptz,timestamptz)'::regprocedure) like '%cut_executions%' as ocupacion_incluye_corte,
  pg_get_functiondef('public.erp_x_work_start(uuid,uuid,jsonb)'::regprocedure) like '%approval_status%' as inicio_respeta_aprobacion;

-- V10.25 · Robot QA total del sistema (ejecutar como Super Admin).
select
  to_regclass('erp_supply.qa_robot_checks') is not null as ledger_qa_total,
  to_regprocedure('public.erp_x_qa_robot_plan()') is not null as plan_robot_qa,
  to_regprocedure('public.erp_x_qa_robot_create_run(jsonb)') is not null as crear_ejecucion_qa_total,
  to_regprocedure('public.erp_x_qa_robot_record_check(uuid,jsonb)') is not null as registrar_comprobacion_qa,
  to_regprocedure('public.erp_x_qa_robot_finish_run(uuid,boolean)') is not null as cerrar_ejecucion_qa,
  to_regprocedure('public.erp_x_qa_robot_seed_order(uuid,jsonb)') is not null as semilla_pedido_test_qa,
  to_regprocedure('public.erp_x_qa_robot_branch_suite(uuid)') is not null as suite_ramas_criticas,
  not exists(
    select 1 from erp_supply.role_module_permissions p
    where p.module_code='qa' and p.role_code<>'super_admin' and p.can_read
  ) as qa_exclusivo_super_admin;

select public.erp_x_qa_robot_plan();
select public.erp_x_qa_robot_system_contract();


-- V10.25.1 · Diagnóstico fiel, campaña profunda y capacidad/concurrencia.
select
  to_regclass('erp_supply.qa_deep_cases') is not null as casos_qa_profundos,
  to_regclass('erp_supply.qa_capacity_runs') is not null as historial_capacidad,
  to_regprocedure('public.erp_x_qa_robot_build_deep_campaign(uuid,text)') is not null as construir_campana_profunda,
  to_regprocedure('public.erp_x_qa_robot_execute_deep_case(uuid)') is not null as ejecutar_caso_aislado,
  to_regprocedure('public.erp_x_qa_robot_deep_progress(uuid,integer)') is not null as progreso_campana_profunda,
  to_regprocedure('public.erp_x_qa_capacity_record(jsonb)') is not null as registrar_capacidad,
  to_regprocedure('public.erp_x_qa_capacity_runs(integer)') is not null as consultar_capacidad,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_scenarios' and column_name='error_sqlstate') as qa_con_sqlstate_original,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_scenarios' and column_name='failure_step_code') as qa_con_etapa_fallida,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_scenarios' and column_name='failure_action') as qa_con_accion_fallida,
  position('qa_existing_order_id' in pg_get_functiondef('public.erp_x_run_qa_matrix(boolean)'::regprocedure))>0 as matriz_336_no_guarda_fk_huerfana,
  position('rolledBackOrDeletedOrderId' in pg_get_functiondef('public.erp_x_qa_robot_record_check(uuid,jsonb)'::regprocedure))>0 as ledger_robot_preserva_uuid_revertido,
  position('NO_DELIVERY' in pg_get_functiondef('public.erp_x_qa_robot_execute_deep_case(uuid)'::regprocedure))>0 as qa_profundo_prueba_no_entrega,
  position('CANCELLATION' in pg_get_functiondef('public.erp_x_qa_robot_execute_deep_case(uuid)'::regprocedure))>0 as qa_profundo_prueba_cancelacion,
  position('deepFailures' in pg_get_functiondef('public.erp_x_qa_robot_detail(uuid)'::regprocedure))>0 as detalle_qa_expone_fallos_profundos;


-- V10.25.2 · Certificación reanudable de liberación.
select
  to_regprocedure('public.erp_x_qa_robot_build_release_campaign(uuid)') is not null as construir_certificacion_release,
  to_regprocedure('public.erp_x_qa_robot_build_route_campaign(uuid)') is not null as construir_336_rutas_aisladas,
  to_regprocedure('public.erp_x_qa_robot_transport_failure(uuid,text,boolean)') is not null as registrar_transporte_sin_cortar_campana,
  to_regprocedure('public.erp_x_qa_robot_reset_stale_cases(uuid,integer)') is not null as recuperar_casos_interrumpidos,
  to_regprocedure('public.erp_x_qa_robot_release_certificate(uuid)') is not null as certificado_release,
  to_regprocedure('public.erp_x_qa_robot_latest_resumable()') is not null as reanudar_certificacion,
  to_regprocedure('public.erp_x_qa_robot_finish_directed_run(uuid,text)') is not null as cierre_prueba_dirigida,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_deep_cases' and column_name='attempt_count') as casos_con_reintentos,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_deep_cases' and column_name='transport_failures') as transporte_persistido,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_deep_cases' and column_name='timeout_failures') as timeout_persistido,
  exists(select 1 from information_schema.columns where table_schema='erp_supply' and table_name='qa_deep_cases' and column_name='cleanup_verified') as limpieza_verificable,
  position('ROUTE_CANONICAL' in pg_get_functiondef('public.erp_x_qa_robot_execute_deep_case(uuid)'::regprocedure))>0 as ejecutor_prueba_336_aisladas,
  position('JOURNEY_FULL' in pg_get_functiondef('public.erp_x_qa_robot_execute_deep_case(uuid)'::regprocedure))>0 as ejecutor_prueba_recorridos_completos,
  position('release_certificate' in lower(pg_get_functiondef('public.erp_x_qa_robot_finish_run(uuid,boolean)'::regprocedure)))>0 as cierre_subordinado_a_certificado,
  position('10.25.3' in pg_get_functiondef('public.erp_x_qa_robot_plan()'::regprocedure))>0 as plan_release_v10_25_3;

-- V10.25.3 · QA release estable por etapas y prerrequisitos reales.
select
  to_regclass('erp_supply.qa_release_journey_state') is not null as estado_recorridos_persistente,
  to_regprocedure('public.erp_x_qa_robot_execute_release_slice(uuid)') is not null as recorrido_por_etapa,
  to_regprocedure('public.erp_x_qa_release_flow_integrity()') is not null as integridad_release_sin_contaminacion_test,
  to_regprocedure('public.erp_x_qa_release_health(uuid)') is not null as health_release_corrida_actual,
  to_regprocedure('public.erp_x_qa_robot_deep_progress(uuid,integer)') is not null as progreso_priorizado,
  to_regprocedure('public.erp_x_qa_robot_create_run(jsonb)') is not null as crear_corrida_v10_25_3,
  (select c.confdeltype='c' from pg_constraint c where c.conname='receipt_lines_order_item_id_fkey' limit 1) as receipt_lines_cascade_al_borrar_item,
  position('ERP_X_SHIPPING_SAVE_LOCATION' in upper(pg_get_functiondef('erp_supply.qa_execute_step_domain(uuid,text,uuid,uuid)'::regprocedure)))>0 as recorrido_prueba_destino_despacho,
  position('CUTTING_PICKUP_AND_PICKING_FULL' in pg_get_functiondef('erp_supply.qa_execute_step_domain(uuid,text,uuid,uuid)'::regprocedure))>0 as recorrido_prueba_corte_recogida_y_alistamiento,
  position('10.25.3' in pg_get_functiondef('public.erp_x_qa_robot_plan()'::regprocedure))>0 as plan_qa_v10_25_3;

-- Ejecutar como Super Admin: debe devolver una estructura con success/counts.
select public.erp_x_qa_release_flow_integrity();



-- V10.25.4 · Observatorio auditable de rutas.
select
  to_regclass('erp_supply.qa_release_step_evidence') is not null as evidencia_etapas_qa,
  to_regprocedure('public.erp_x_qa_release_route_matrix(uuid,text,text,text,integer,integer)') is not null as matriz_visual_rutas,
  to_regprocedure('public.erp_x_qa_release_case_evidence(uuid)') is not null as detalle_evidencia_ruta,
  position('10.25.4' in pg_get_functiondef('public.erp_x_qa_release_route_matrix(uuid,text,text,text,integer,integer)'::regprocedure))>0 as observatorio_v10_25_4;

-- V10.25.5 · Certificación del flujo del pedido por roles/módulos.
select
  to_regclass('erp_supply.qa_flow_case_state') is not null as flow_state_ok,
  to_regclass('erp_supply.qa_flow_step_audit') is not null as flow_audit_ok,
  to_regprocedure('public.erp_x_qa_flow_create_run()') is not null as flow_create_ok,
  to_regprocedure('public.erp_x_qa_flow_execute_slice(uuid)') is not null as flow_slice_ok,
  to_regprocedure('public.erp_x_qa_flow_progress(uuid)') is not null as flow_progress_ok,
  to_regprocedure('public.erp_x_qa_flow_case_detail(uuid)') is not null as flow_detail_ok,
  to_regprocedure('public.erp_x_qa_flow_user_readiness()') is not null as flow_usuarios_reales_ok,
  to_regprocedure('public.erp_x_qa_flow_delivery_exception_suite(uuid)') is not null as flow_no_entrega_roles_ok,
  to_regprocedure('public.erp_x_qa_flow_finish(uuid)') is not null as flow_finish_ok,
  position('10.25.5' in pg_get_functiondef('public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure))>0 as flow_v10_25_5;

select
  s.code as step_code,
  s.module_code,
  erp_supply.default_role_for_step(s.code,null) as default_role,
  exists(
    select 1 from erp_supply.step_roles sr
    where sr.step_code=s.code
      and sr.role_code=erp_supply.default_role_for_step(s.code,null)
      and sr.can_view
  ) as role_can_view
from erp_supply.workflow_steps s
where s.active and not s.terminal
order by s.sort_order;


-- Debe devolver success=true antes de certificar salida.
select public.erp_x_qa_flow_user_readiness();
