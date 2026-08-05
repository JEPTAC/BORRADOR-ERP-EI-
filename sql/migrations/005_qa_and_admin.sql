-- ERP Supply Enterprise V10
-- Migration 005: bootstrap, administration and deterministic 192-scenario QA bot.

begin;

-- Bootstrap the known administrator only when the Supabase Auth account already exists.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active)
select o.id,u.id,lower(u.email),coalesce(u.raw_user_meta_data->>'full_name','Juan Esteban Pérez'),true
from auth.users u cross join erp_supply.organizations o
where lower(u.email)='j.perez@ei.com.co' and o.code='EI'
on conflict (organization_id,email) do update set auth_user_id=excluded.auth_user_id,active=true;

insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
select p.id,'super_admin',true from erp_supply.profiles p where lower(p.email)='j.perez@ei.com.co'
on conflict (profile_id,role_code) do update set is_primary=true;

create or replace function public.erp_x_admin_save_profile(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_profile erp_supply.profiles%rowtype; v_role text;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede administrar usuarios' using errcode='42501'; end if;
  if p_payload->>'id' is null then
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active)
    values(v_org,(p_payload->>'authUserId')::uuid,lower(p_payload->>'email'),p_payload->>'name',p_payload->>'employeeCode',coalesce((p_payload->>'active')::boolean,true)) returning * into v_profile;
  else
    update erp_supply.profiles set auth_user_id=coalesce((p_payload->>'authUserId')::uuid,auth_user_id),email=lower(p_payload->>'email'),display_name=p_payload->>'name',employee_code=p_payload->>'employeeCode',active=coalesce((p_payload->>'active')::boolean,active)
    where id=(p_payload->>'id')::uuid and organization_id=v_org returning * into v_profile;
  end if;
  delete from erp_supply.profile_roles where profile_id=v_profile.id;
  for v_role in select value#>>'{}' from jsonb_array_elements(coalesce(p_payload->'roles','[]'::jsonb)) loop
    insert into erp_supply.profile_roles(profile_id,role_code,is_primary,granted_by) values(v_profile.id,v_role,not exists(select 1 from erp_supply.profile_roles where profile_id=v_profile.id),erp_supply.current_profile_id());
  end loop;
  return jsonb_build_object('success',true,'profile',to_jsonb(v_profile));
end;
$$;

create or replace function public.erp_x_admin_sync_auth()
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();v_count integer;
begin
  erp_supply.require_profile();
  if not erp_supply.can_access_module('admin','admin') then raise exception 'Solo Super Admin puede sincronizar Auth' using errcode='42501'; end if;
  with inserted as (
    insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active)
    select v_org,u.id,lower(u.email),coalesce(u.raw_user_meta_data->>'full_name',split_part(u.email,'@',1)),false
    from auth.users u
    where u.email is not null and not exists(select 1 from erp_supply.profiles p where p.organization_id=v_org and (p.auth_user_id=u.id or lower(p.email)=lower(u.email)))
    returning 1
  ) select count(*) into v_count from inserted;
  update erp_supply.profiles p set auth_user_id=u.id
  from auth.users u where p.organization_id=v_org and p.auth_user_id is null and lower(p.email)=lower(u.email);
  return jsonb_build_object('success',true,'createdProfiles',v_count);
end;
$$;

create or replace function public.erp_x_calendar()
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  return jsonb_build_object(
    'calendars',(select coalesce(jsonb_agg(to_jsonb(c)),'[]'::jsonb) from erp_supply.work_calendars c where c.organization_id=v_org),
    'segments',(select coalesce(jsonb_agg(to_jsonb(s) order by s.iso_weekday,s.start_time),'[]'::jsonb) from erp_supply.work_calendar_segments s join erp_supply.work_calendars c on c.id=s.calendar_id where c.organization_id=v_org),
    'holidays',(select coalesce(jsonb_agg(to_jsonb(h) order by h.holiday_date),'[]'::jsonb) from erp_supply.holidays h where h.organization_id=v_org)
  );
end;
$$;

create or replace function public.erp_x_run_qa_matrix(p_cleanup boolean default true)
returns jsonb
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_actor uuid:=erp_supply.require_profile(); v_org uuid:=erp_supply.current_org_id(); v_run erp_supply.qa_runs%rowtype;
  v_type text; v_payment text; v_route text; v_cut boolean; v_purchase boolean; v_key text; v_initial text;
  v_order erp_supply.orders%rowtype; v_task erp_supply.order_tasks%rowtype; v_scenario erp_supply.qa_scenarios%rowtype;
  v_expected jsonb; v_actual jsonb; v_step text; v_guard int; v_passed int:=0;v_failed int:=0;v_total int:=0;v_error text;
begin
  if not erp_supply.has_role('super_admin') then raise exception 'El bot QA solo puede ser ejecutado por Super Admin' using errcode='42501'; end if;
  insert into erp_supply.qa_runs(organization_id,requested_by,total_scenarios) values(v_org,v_actor,192) returning * into v_run;
  foreach v_type in array array['PVC','PVN','PVE','PVP'] loop
    foreach v_payment in array array['CREDIT','CASH','MIXED'] loop
      foreach v_route in array array['CLIENT_POINT','CLIENT_PICKUP','LOCAL_DISPATCH','NATIONAL_DISPATCH'] loop
        foreach v_cut in array array[false,true] loop
          foreach v_purchase in array array[false,true] loop
            v_total:=v_total+1; v_error:=null;
            v_key:=format('%s-%s-%s-CUT_%s-BUY_%s',v_type,v_payment,v_route,v_cut,v_purchase);
            v_initial:=erp_supply.initial_step(v_type,v_payment,v_purchase or v_type='PVE');
            v_expected:=jsonb_build_array(v_initial); v_step:=v_initial; v_guard:=0;
            while v_step<>'CLOSED' and v_guard<20 loop
              v_step:=erp_supply.next_step(v_step,v_type,v_payment,v_route,v_cut,v_purchase or v_type='PVE');
              v_expected:=v_expected||jsonb_build_array(v_step); v_guard:=v_guard+1;
            end loop;
            insert into erp_supply.qa_scenarios(qa_run_id,scenario_key,input,expected_path)
            values(v_run.id,v_key,jsonb_build_object('orderType',v_type,'payment',v_payment,'route',v_route,'requiresCut',v_cut,'requiresPurchase',v_purchase),v_expected)
            returning * into v_scenario;
            begin
              insert into erp_supply.orders(organization_id,order_number,order_type_code,payment_condition_code,delivery_route_code,client_name,seller_profile_id,current_step_code,status,requires_cut,requires_purchase,source,is_test,qa_run_id,metadata)
              values(v_org,'QA-'||replace(v_run.id::text,'-','')||'-'||lpad(v_total::text,3,'0'),v_type,v_payment,v_route,'Cliente QA '||v_key,v_actor,v_initial,'QUEUED',v_cut,v_purchase or v_type='PVE','QA_BOT',true,v_run.id,jsonb_build_object('scenario',v_key)) returning * into v_order;
              insert into erp_supply.order_items(order_id,line_number,sku,description,quantity,unit,requires_cut,requested_cut_length)
              values(v_order.id,1,'QA-'||v_type,'Material de prueba automatizada',1,'UND',v_cut,case when v_cut then 10 else null end);
              select * into v_task from erp_supply.create_task(v_order,v_initial,1);
              v_actual:=jsonb_build_array(v_initial); v_guard:=0;
              loop
                select * into v_order from erp_supply.orders where id=v_order.id;
                exit when v_order.status='CLOSED' or v_guard>=20;
                perform erp_supply.execute_action_internal(v_order.id,'START',jsonb_build_object('detail','Inicio QA'),v_actor,true,null,v_key||'-START-'||v_guard);
                perform erp_supply.execute_action_internal(v_order.id,'COMPLETE',jsonb_build_object('detail','Finalización QA'),v_actor,true,null,v_key||'-COMPLETE-'||v_guard);
                select * into v_order from erp_supply.orders where id=v_order.id;
                v_actual:=v_actual||jsonb_build_array(v_order.current_step_code); v_guard:=v_guard+1;
              end loop;
              if v_order.status='CLOSED' and v_actual=v_expected then
                update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=v_actual,status='PASSED',completed_at=now() where id=v_scenario.id; v_passed:=v_passed+1;
              else
                v_error:=format('Estado final %s; paso %s; ruta esperada %s; ruta real %s',v_order.status,v_order.current_step_code,v_expected,v_actual);
                update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=v_actual,status='FAILED',error_message=v_error,completed_at=now() where id=v_scenario.id; v_failed:=v_failed+1;
              end if;
            exception when others then
              v_error:=sqlstate||' - '||sqlerrm;
              update erp_supply.qa_scenarios set order_id=v_order.id,actual_path=coalesce(v_actual,'[]'::jsonb),status='FAILED',error_message=v_error,completed_at=now() where id=v_scenario.id; v_failed:=v_failed+1;
            end;
          end loop;
        end loop;
      end loop;
    end loop;
  end loop;
  update erp_supply.qa_runs set status=case when v_failed=0 then 'PASSED' else 'FAILED' end,total_scenarios=v_total,passed_scenarios=v_passed,failed_scenarios=v_failed,completed_at=now(),summary=jsonb_build_object('matrix','4 order types × 3 payments × 4 routes × 2 cut × 2 purchase','cleanup',p_cleanup)
  where id=v_run.id returning * into v_run;
  if p_cleanup then delete from erp_supply.orders where qa_run_id=v_run.id; end if;
  return jsonb_build_object('runId',v_run.id,'status',v_run.status,'total',v_total,'passed',v_passed,'failed',v_failed,'completedAt',v_run.completed_at);
end;
$$;

create or replace function public.erp_x_qa_runs(p_limit integer default 20)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id();
begin
  erp_supply.require_profile();
  if not (erp_supply.has_role('super_admin') or erp_supply.has_role('jefe_logistica') or erp_supply.has_role('auditoria')) then raise exception 'No autorizado' using errcode='42501'; end if;
  return (select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at desc),'[]'::jsonb) from (
    select q.id,q.run_type "runType",q.status,q.total_scenarios "totalScenarios",q.passed_scenarios "passedScenarios",q.failed_scenarios "failedScenarios",q.started_at "startedAt",q.completed_at "completedAt",q.summary
    from erp_supply.qa_runs q where q.organization_id=v_org order by q.started_at desc limit least(greatest(p_limit,1),100)
  ) x);
end;
$$;

create or replace function public.erp_x_qa_run_detail(p_run_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=erp_supply,public,auth
as $$
declare v_org uuid:=erp_supply.current_org_id(); v_run erp_supply.qa_runs%rowtype;
begin
  erp_supply.require_profile();
  select * into v_run from erp_supply.qa_runs where id=p_run_id and organization_id=v_org;
  if not found then raise exception 'Ejecución QA no encontrada'; end if;
  return jsonb_build_object('run',to_jsonb(v_run),'scenarios',(select coalesce(jsonb_agg(to_jsonb(s) order by s.scenario_key),'[]'::jsonb) from erp_supply.qa_scenarios s where s.qa_run_id=p_run_id));
end;
$$;

revoke all on function public.erp_x_admin_save_profile(jsonb) from public,anon,authenticated;
revoke all on function public.erp_x_admin_sync_auth() from public,anon,authenticated;
revoke all on function public.erp_x_calendar() from public,anon,authenticated;
revoke all on function public.erp_x_run_qa_matrix(boolean) from public,anon,authenticated;
revoke all on function public.erp_x_qa_runs(integer) from public,anon,authenticated;
revoke all on function public.erp_x_qa_run_detail(uuid) from public,anon,authenticated;
grant execute on function public.erp_x_admin_save_profile(jsonb) to authenticated;
grant execute on function public.erp_x_admin_sync_auth() to authenticated;
grant execute on function public.erp_x_calendar() to authenticated;
grant execute on function public.erp_x_run_qa_matrix(boolean) to authenticated;
grant execute on function public.erp_x_qa_runs(integer) to authenticated;
grant execute on function public.erp_x_qa_run_detail(uuid) to authenticated;

commit;
