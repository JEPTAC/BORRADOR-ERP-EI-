-- ERP Supply Enterprise V10
-- Migration 016: append-only audit coverage for every sensitive domain record.

begin;

create or replace function erp_supply.audit_domain_row()
returns trigger
language plpgsql
security definer
set search_path=erp_supply,public,auth
as $$
declare
  v_row jsonb;
  v_old jsonb;
  v_new jsonb;
  v_org uuid;
  v_actor uuid;
  v_order uuid;
  v_task uuid;
  v_receipt uuid;
  v_entity_id text;
  v_is_test boolean:=false;
  v_mode text:=coalesce(TG_ARGV[0],'DIRECT');
begin
  v_old:=case when TG_OP in('UPDATE','DELETE') then to_jsonb(old) end;
  v_new:=case when TG_OP in('INSERT','UPDATE') then to_jsonb(new) end;
  v_row:=coalesce(v_new,v_old,'{}'::jsonb);

  if v_mode='ORDER' then
    begin v_order:=nullif(v_row->>'order_id','')::uuid; exception when others then v_order:=null; end;
  elsif v_mode='TASK' then
    begin v_task:=nullif(v_row->>'task_id','')::uuid; exception when others then v_task:=null; end;
    select t.order_id into v_order from erp_supply.order_tasks t where t.id=v_task;
  elsif v_mode='RECEIPT' then
    begin v_receipt:=nullif(v_row->>'receipt_id','')::uuid; exception when others then v_receipt:=null; end;
    select r.order_id into v_order from erp_supply.receipts r where r.id=v_receipt;
  elsif v_mode='INVENTORY_ITEM' then
    select organization_id into v_org from erp_supply.inventory_items where id=nullif(v_row->>'inventory_item_id','')::uuid;
  elsif v_mode='PROFILE' then
    select organization_id into v_org from erp_supply.profiles where id=nullif(v_row->>'profile_id','')::uuid;
  elsif v_mode='MOVEMENT' then
    begin v_order:=nullif(v_row->>'order_id','')::uuid; exception when others then v_order:=null; end;
    begin v_org:=nullif(v_row->>'organization_id','')::uuid; exception when others then v_org:=null; end;
  else
    begin v_org:=nullif(v_row->>'organization_id','')::uuid; exception when others then v_org:=null; end;
  end if;

  if v_order is not null then
    select organization_id,is_test into v_org,v_is_test from erp_supply.orders where id=v_order;
  end if;
  if v_is_test then
    if TG_OP='DELETE' then return old; else return new; end if;
  end if;

  v_actor:=erp_supply.current_profile_id();
  v_entity_id:=coalesce(v_row->>'id',v_row->>'task_id',v_row->>'profile_id',v_row->>'order_id','UNKNOWN');
  if v_row ? 'item_code' then v_entity_id:=v_entity_id||':'||coalesce(v_row->>'item_code',''); end if;
  if v_row ? 'role_code' then v_entity_id:=v_entity_id||':'||coalesce(v_row->>'role_code',''); end if;

  insert into erp_supply.system_audit(
    organization_id,actor_profile_id,action,entity_type,entity_id,before_data,after_data,metadata
  ) values(
    v_org,v_actor,TG_OP,TG_TABLE_NAME,v_entity_id,v_old,v_new,
    jsonb_build_object('schema',TG_TABLE_SCHEMA,'trigger','domain-audit','orderId',v_order)
  );

  if TG_OP='DELETE' then return old; else return new; end if;
end;
$$;

-- Helper block creates idempotent triggers.
do $$
declare r record;
begin
  for r in select * from (values
    ('order_items','ORDER'),('financial_validations','ORDER'),('purchase_orders','ORDER'),('receipts','ORDER'),('receipt_lines','RECEIPT'),
    ('task_checklist','TASK'),('inventory_items','DIRECT'),('inventory_lots','INVENTORY_ITEM'),('inventory_movements','MOVEMENT'),('cut_jobs','ORDER'),('invoices','ORDER'),
    ('deliveries','ORDER'),('credit_requests','DIRECT'),('drive_files','ORDER'),('approval_requests','ORDER'),
    ('profiles','DIRECT'),('profile_roles','PROFILE')
  ) x(table_name,mode)
  loop
    execute format('drop trigger if exists %I on erp_supply.%I','trg_audit_'||r.table_name,r.table_name);
    execute format('create trigger %I after insert or update or delete on erp_supply.%I for each row execute function erp_supply.audit_domain_row(%L)',
      'trg_audit_'||r.table_name,r.table_name,r.mode);
  end loop;
end $$;

commit;
