-- ERP Supply Enterprise V10
-- Migration 010: reuse Supabase Auth identities and established logistics routing without importing legacy orders.

begin;

-- Import only identity and role configuration from the previous public.profiles table when it exists.
do $$
begin
  if to_regclass('public.profiles') is not null
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='auth_user_id')
     and exists(select 1 from information_schema.columns where table_schema='public' and table_name='profiles' and column_name='role_code')
  then
    execute $q$
      insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,employee_code,active,preferences)
      select o.id,lp.auth_user_id,lower(lp.email),coalesce(nullif(lp.display_name,''),split_part(lp.email,'@',1)),null,
             coalesce(lp.active,true),jsonb_build_object('legacyProfileImported',true)
      from public.profiles lp cross join erp_supply.organizations o
      where o.code='EI' and lp.email is not null
      on conflict(organization_id,email) do update set
        auth_user_id=coalesce(excluded.auth_user_id,erp_supply.profiles.auth_user_id),
        display_name=excluded.display_name,
        active=excluded.active,
        preferences=erp_supply.profiles.preferences||excluded.preferences
    $q$;

    execute $q$
      insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
      select ep.id,lp.role_code,true
      from public.profiles lp
      join erp_supply.profiles ep on lower(ep.email)=lower(lp.email)
      join erp_supply.roles r on r.code=lp.role_code
      where lp.role_code is not null
      on conflict(profile_id,role_code) do update set is_primary=true
    $q$;
  end if;
end $$;

-- Every Supabase Auth account is visible to the administrator even if it had no legacy profile.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active,preferences)
select o.id,u.id,lower(u.email),coalesce(nullif(u.raw_user_meta_data->>'full_name',''),split_part(u.email,'@',1)),false,jsonb_build_object('createdFromAuth',true)
from auth.users u cross join erp_supply.organizations o
where o.code='EI' and u.email is not null
on conflict(organization_id,email) do update set auth_user_id=coalesce(erp_supply.profiles.auth_user_id,excluded.auth_user_id);

-- Explicit bootstrap for the designated Super Admin. This is idempotent and only
-- activates the exact corporate account already present in Supabase Auth.
insert into erp_supply.profiles(organization_id,auth_user_id,email,display_name,active,preferences)
select o.id,u.id,lower(u.email),coalesce(nullif(u.raw_user_meta_data->>'full_name',''),'Juan Esteban Pérez'),true,
       jsonb_build_object('bootstrapSuperAdmin',true)
from auth.users u cross join erp_supply.organizations o
where o.code='EI' and lower(u.email)='j.perez@ei.com.co'
on conflict(organization_id,email) do update set
  auth_user_id=excluded.auth_user_id,
  display_name=coalesce(nullif(erp_supply.profiles.display_name,''),excluded.display_name),
  active=true,
  preferences=erp_supply.profiles.preferences||excluded.preferences;

insert into erp_supply.profile_roles(profile_id,role_code,is_primary)
select p.id,'super_admin',true
from erp_supply.profiles p
where lower(p.email)='j.perez@ei.com.co'
on conflict(profile_id,role_code) do update set is_primary=true;

-- Established local/national route ownership.
insert into erp_supply.routing_rules(organization_id,step_code,route_code,assigned_role_code,assigned_profile_id,priority,metadata)
select o.id,x.step_code,x.route_code,x.role_code,p.id,x.priority,jsonb_build_object('source','established-routing')
from erp_supply.organizations o
join (values
  ('FACTURACION','CLIENT_POINT','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','CLIENT_PICKUP','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','LOCAL_DISPATCH','coordinador_logistico','d.diaz@ei.com.co',10),
  ('FACTURACION','NATIONAL_DISPATCH','despacho_nacional','j.laverde@ei.com.co',10),
  ('CLIENT_POINT','CLIENT_POINT','coordinador_logistico','d.diaz@ei.com.co',10),
  ('CLIENT_PICKUP','CLIENT_PICKUP','coordinador_logistico','d.diaz@ei.com.co',10),
  ('LOCAL_DISPATCH','LOCAL_DISPATCH','coordinador_logistico','d.diaz@ei.com.co',10),
  ('NATIONAL_DISPATCH','NATIONAL_DISPATCH','despacho_nacional','j.laverde@ei.com.co',10)
) x(step_code,route_code,role_code,email,priority) on true
left join erp_supply.profiles p on p.organization_id=o.id and lower(p.email)=x.email
where o.code='EI'
  and not exists(
    select 1 from erp_supply.routing_rules rr
    where rr.organization_id=o.id and rr.step_code=x.step_code and rr.route_code=x.route_code
      and rr.order_type_code is null and rr.assigned_role_code=x.role_code
  );

commit;
