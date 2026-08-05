-- ERP Supply Enterprise V10
-- Verificación posterior a la instalación. No crea ni modifica datos.

select
  to_regnamespace('erp_supply') is not null as esquema_instalado,
  to_regprocedure('public.erp_x_session()') is not null as rpc_sesion,
  to_regprocedure('public.erp_x_create_order(jsonb,text)') is not null as rpc_crear_pedido,
  to_regprocedure('public.erp_x_execute_action(uuid,text,jsonb,integer,text)') is not null as rpc_acciones,
  to_regprocedure('public.erp_x_run_qa_matrix(boolean)') is not null as bot_matriz,
  to_regprocedure('public.erp_x_run_qa_control_suite(boolean)') is not null as bot_controles,
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

select *
from public.erp_x_health_check()
order by section,check_name;

select *
from public.erp_x_health_check()
where not ok
order by section,check_name;
