begin;

-- V10.25.10 · Resiliencia de timeout del QA de flujo
-- Alcance: SOLO infraestructura QA. No modifica reglas productivas.
-- Motivo observado: durante la campaña de 336 casos el primer statement_timeout
-- podía saturar la conexión y hacer fallar también progress/latest/list_orders/work_my_day.

do $$
begin
  if to_regprocedure('public.erp_x_qa_flow_execute_slice(uuid)') is null then
    raise exception 'Falta public.erp_x_qa_flow_execute_slice(uuid). Instale primero las migraciones previas del QA de flujo.';
  end if;
end
$$;

-- Ventana mayor SOLO para RPC de certificación. Se conserva intacto el timeout
-- del rol authenticated y de todas las RPC productivas del ERP.
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
      execute format('alter function %s set statement_timeout to %L',v_proc,'45s');
    end if;
  end loop;
end
$$;

create or replace function public.erp_x_qa_flow_v102510_timeout_contract()
returns jsonb
language sql
stable
security definer
set search_path=pg_catalog,public
as $$
  select jsonb_build_object(
    'version','10.25.10',
    'success',
      coalesce((select 'statement_timeout=45s'=any(coalesce(p.proconfig,'{}'::text[]))
                from pg_proc p
                where p.oid='public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure),false),
    'executeSliceConfig',
      coalesce((select to_jsonb(p.proconfig)
                from pg_proc p
                where p.oid='public.erp_x_qa_flow_execute_slice(uuid)'::regprocedure),'[]'::jsonb),
    'progressConfig',
      coalesce((select to_jsonb(p.proconfig)
                from pg_proc p
                where p.oid='public.erp_x_qa_flow_progress(uuid)'::regprocedure),'[]'::jsonb),
    'latestResumableConfig',
      coalesce((select to_jsonb(p.proconfig)
                from pg_proc p
                where p.oid='public.erp_x_qa_flow_latest_resumable()'::regprocedure),'[]'::jsonb)
  );
$$;

revoke all on function public.erp_x_qa_flow_v102510_timeout_contract() from public,anon;
grant execute on function public.erp_x_qa_flow_v102510_timeout_contract() to authenticated;

commit;
