begin;

-- V10.25.11 · Protección del pool / reversión del timeout QA de V10.25.10
-- Alcance: SOLO infraestructura QA. No modifica reglas productivas.
-- Motivo: mantener llamadas QA hasta 45 s puede retener conexiones durante una
-- degradación y agravar 503/504. Se elimina la excepción por función para volver
-- al timeout normal del rol/API.

do $$
declare
  v_sig text;
  v_proc regprocedure;
begin
  foreach v_sig in array array[
    'public.erp_x_qa_flow_execute_slice(uuid)',
    'public.erp_x_qa_flow_execute_slice_v10257_core(uuid)',
    'public.erp_x_qa_flow_pending_cases(uuid)',
    'public.erp_x_qa_flow_progress(uuid)',
    'public.erp_x_qa_flow_latest()',
    'public.erp_x_qa_flow_latest_resumable()',
    'public.erp_x_qa_flow_matrix(uuid,text)',
    'public.erp_x_qa_flow_summary(uuid)',
    'public.erp_x_qa_flow_case_detail(uuid)',
    'public.erp_x_qa_flow_finish(uuid)',
    'public.erp_x_qa_flow_delivery_exception_suite(uuid)'
  ] loop
    v_proc:=to_regprocedure(v_sig);
    if v_proc is not null then
      execute format('alter function %s reset statement_timeout',v_proc);
    end if;
  end loop;
end
$$;

create or replace function public.erp_x_qa_flow_v102511_pool_contract()
returns jsonb
language sql
stable
security definer
set search_path=pg_catalog,public
as $$
  select jsonb_build_object(
    'version','10.25.11',
    'success',
      coalesce((select not ('statement_timeout=45s'=any(coalesce(p.proconfig,'{}'::text[])))
                from pg_proc p
                where p.oid='public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure),false),
    'executeSliceConfig',
      coalesce((select to_jsonb(p.proconfig) from pg_proc p
                where p.oid='public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure),'[]'::jsonb),
    'message','QA usa nuevamente el timeout normal del rol/API; reintentos PostgREST se desactivan en frontend.'
  );
$$;

revoke all on function public.erp_x_qa_flow_v102511_pool_contract() from public,anon;
grant execute on function public.erp_x_qa_flow_v102511_pool_contract() to authenticated;

commit;
