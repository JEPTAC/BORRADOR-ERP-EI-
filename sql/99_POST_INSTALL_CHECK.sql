-- ERP Electroingeniería V10.22.0
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
  ) as gate_corte_recogido_alistamiento;

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
