-- ================================================================================
--  MODULE 8 VERIFICATION — RM purchases & inventory (ZZTEST personas, Law 9)
--  Personas: ZZ Director · ZZ Accounts (finance) · ZZ Production (mfg) · ZZ Sales
-- ================================================================================
drop table if exists public.zztest_results;
create table public.zztest_results (seq serial primary key, section text, test text, ok boolean, detail text);
grant select, insert on public.zztest_results to authenticated;
grant usage, select on sequence public.zztest_results_seq_seq to authenticated;
drop table if exists public.zztest_counters_before;
create table public.zztest_counters_before as select * from app.doc_counters;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('00000000-0000-0000-0000-000000000000','cccc0000-0000-4000-8000-000000000d01','authenticated','authenticated','zztest_dir8@test.local','',now(),'{}','{"full_name":"ZZTEST Director8"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','cccc0000-0000-4000-8000-00000000ac01','authenticated','authenticated','zztest_acc8@test.local','',now(),'{}','{"full_name":"ZZTEST Accounts8"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','cccc0000-0000-4000-8000-00000000f601','authenticated','authenticated','zztest_mfg8@test.local','',now(),'{}','{"full_name":"ZZTEST Production8"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','cccc0000-0000-4000-8000-00000000a501','authenticated','authenticated','zztest_sal8@test.local','',now(),'{}','{"full_name":"ZZTEST Sales8"}',now(),now())
on conflict (id) do nothing;
update adm.users set role = 'DIRECTOR' where id = 'cccc0000-0000-4000-8000-000000000d01';
update adm.users set permissions_json = '{"finance":{"view":true,"edit":true}}' where id = 'cccc0000-0000-4000-8000-00000000ac01';
update adm.users set permissions_json = '{"mfg":{"view":true,"add":true,"edit":true}}' where id = 'cccc0000-0000-4000-8000-00000000f601';
update adm.users set permissions_json = '{"sales":{"view":true,"add":true,"edit":true}}' where id = 'cccc0000-0000-4000-8000-00000000a501';

drop table if exists public.zztest_vars;
create table public.zztest_vars (k text primary key, v text);
grant select, insert, update on public.zztest_vars to authenticated;
create or replace function public.zzset(p_k text, p_v text) returns void language sql as
$fn$ insert into public.zztest_vars values (p_k, p_v) on conflict (k) do update set v = excluded.v $fn$;
create or replace function public.zzget(p_k text) returns text language sql stable as
$fn$ select v from public.zztest_vars where k = p_k $fn$;
grant execute on function public.zzset(text,text), public.zzget(text) to authenticated;

-- ZZTEST vendor (as Director, the register's owner)
do $t$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into sales.vendors (code, name, category, status, created_by)
  values (app.next_code('VEN'), 'ZZTEST_RM SUPPLIES CO', 'Raw material', 'ACTIVE', 'cccc0000-0000-4000-8000-000000000d01')
  returning id into v_id;
  perform public.zzset('vendor', v_id::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Vendor registered for the test', true, 'ZZTEST_RM SUPPLIES CO');
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Vendor registered for the test', false, 'Error: ' || sqlerrm);
end $t$;

-- T1: production raises an RM request (indent)
do $t$
declare v_id uuid; v_no text;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000f601","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_id := mfg.create_rm_request(
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 200))::jsonb from mfg.rm_items where code = 'ENA'),
    current_date + 7, 'ZZTEST need for next batch');
  select req_no into v_no from mfg.rm_requests where id = v_id;
  perform public.zzset('req', v_id::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Production raises RM request', v_no like 'RMR/%', v_no || ' for 200 L ENA');
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Production raises RM request', false, 'Error: ' || sqlerrm);
end $t$;

-- T2: Accounts places a PO on the vendor, linked to the request; production cannot
do $t$
declare v_po uuid; v_no text; v_req_status text; ok_deny boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_po := mfg.create_po(public.zzget('vendor')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 200, 'rate', 85.50))::jsonb from mfg.rm_items where code = 'ENA'),
    current_date + 5, public.zzget('req')::uuid, 'ZZTEST PO');
  select po_no into v_no from mfg.purchase_orders where id = v_po;
  select status into v_req_status from mfg.rm_requests where id = public.zzget('req')::uuid;
  perform public.zzset('po', v_po::text);
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000f601","role":"authenticated"}', true);
  begin
    perform mfg.create_po(public.zzget('vendor')::uuid,
      (select json_build_array(json_build_object('rm_item_id', id, 'qty', 1, 'rate', 1))::jsonb from mfg.rm_items where code = 'ENA'),
      null, null, 'ZZTEST rogue');
  exception when others then ok_deny := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','Accounts places PO (request → ORDERED); production cannot place',
          v_no like 'PO/%' and v_req_status = 'ORDERED' and ok_deny,
          format('%s · request=%s · production refused=%s', v_no, v_req_status, ok_deny));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Accounts places PO (request → ORDERED); production cannot place', false, 'Error: ' || sqlerrm);
end $t$;

-- T3: money split — Accounts sees PO value (₹17,100), production sees none
do $t$
declare a_amt numeric; p_cnt int;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select sum(v.amount) into a_amt from mfg.po_values v join mfg.po_lines l on l.id = v.line_id where l.po_id = public.zzget('po')::uuid;
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000f601","role":"authenticated"}', true);
  select count(*) into p_cnt from mfg.po_values;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','PO money visible to Accounts, hidden from production', a_amt = 17100.00 and p_cnt = 0,
          format('accounts sees ₹%s (want 17100.00) · production sees %s rows', a_amt, p_cnt));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','PO money visible to Accounts, hidden from production', false, 'Error: ' || sqlerrm);
end $t$;

-- T4: tracking — dispatched; wrong transitions refused
do $t$
declare v_st text; ok1 boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform mfg.po_set_status(public.zzget('po')::uuid, 'DISPATCHED');
  select status into v_st from mfg.purchase_orders where id = public.zzget('po')::uuid;
  begin perform mfg.po_set_status(public.zzget('po')::uuid, 'CANCELLED'); exception when others then ok1 := true; end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','PO tracked to DISPATCHED; cancel-after-dispatch refused', v_st = 'DISPATCHED' and ok1,
          format('status=%s cancel_refused=%s', v_st, ok1));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','PO tracked to DISPATCHED; cancel-after-dispatch refused', false, 'Error: ' || sqlerrm);
end $t$;

-- T5: partial receipt → PARTIAL; over-receipt refused; full receipt → RECEIVED + request FULFILLED + store stock
do $t$
declare v_st text; ok_over boolean := false; v_bal numeric; v_req text;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform mfg.po_receive(public.zzget('po')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 80))::jsonb from mfg.rm_items where code = 'ENA'),
    'ZZTEST-CH-01', 'ZZTEST-INV-01');
  select status into v_st from mfg.purchase_orders where id = public.zzget('po')::uuid;
  begin
    perform mfg.po_receive(public.zzget('po')::uuid,
      (select json_build_array(json_build_object('rm_item_id', id, 'qty', 500))::jsonb from mfg.rm_items where code = 'ENA'),
      'ZZTEST-CH-XX', null);
  exception when others then ok_over := true;
  end;
  perform mfg.po_receive(public.zzget('po')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 120))::jsonb from mfg.rm_items where code = 'ENA'),
    'ZZTEST-CH-02', 'ZZTEST-INV-02');
  select status into v_st from mfg.purchase_orders where id = public.zzget('po')::uuid;
  select store_balance into v_bal from mfg.v_rm_store where code = 'ENA';
  select status into v_req from mfg.rm_requests where id = public.zzget('req')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','Partial→full receipt; over-receipt refused; store=200; request FULFILLED',
          v_st = 'RECEIVED' and ok_over and v_bal = 200 and v_req = 'FULFILLED',
          format('status=%s over_refused=%s store=%s request=%s', v_st, ok_over, v_bal, v_req));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Partial→full receipt; over-receipt refused; store=200; request FULFILLED', false, 'Error: ' || sqlerrm);
end $t$;

-- T6: issue to MMC draws the store down; issuing more than the store holds is refused
do $t$
declare v_store numeric; v_mmc numeric; ok_guard boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into mfg.rm_issues (rm_item_id, qty, challan_no, remarks, created_by)
  values ((select id from mfg.rm_items where code='ENA'), 150, 'ZZTEST-ISS-1', 'ZZTEST', 'cccc0000-0000-4000-8000-000000000d01');
  select store_balance into v_store from mfg.v_rm_store where code = 'ENA';
  select balance into v_mmc from mfg.v_rm_stock where code = 'ENA';
  begin
    insert into mfg.rm_issues (rm_item_id, qty, challan_no, remarks, created_by)
    values ((select id from mfg.rm_items where code='ENA'), 500, 'ZZTEST-ISS-2', 'ZZTEST', 'cccc0000-0000-4000-8000-000000000d01');
  exception when others then ok_guard := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','Issue to MMC: store 200−150=50, MMC custody 150; over-issue refused',
          v_store = 50 and v_mmc = 150 and ok_guard,
          format('store=%s mmc=%s over_issue_refused=%s', v_store, v_mmc, ok_guard));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Issue to MMC: store 200−150=50, MMC custody 150; over-issue refused', false, 'Error: ' || sqlerrm);
end $t$;

-- T7: walls — sales staff sees nothing; PO on inactive vendor refused; direct receipt by Accounts refused
do $t$
declare c1 int; c2 int; ok1 boolean := false; ok2 boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000a501","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select count(*) into c1 from mfg.purchase_orders;
  select count(*) into c2 from mfg.rm_requests;
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  update sales.vendors set status = 'INACTIVE' where id = public.zzget('vendor')::uuid;
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  begin
    perform mfg.create_po(public.zzget('vendor')::uuid,
      (select json_build_array(json_build_object('rm_item_id', id, 'qty', 1, 'rate', 1))::jsonb from mfg.rm_items where code = 'ENA'),
      null, null, 'ZZTEST inactive vendor');
  exception when others then ok1 := true;
  end;
  begin
    insert into mfg.rm_receipts (po_id, rm_item_id, qty, created_by)
    values (null, (select id from mfg.rm_items where code='ENA'), 999, 'cccc0000-0000-4000-8000-00000000ac01');
  exception when others then ok2 := true;
  end;
  execute 'reset role';
  update sales.vendors set status = 'ACTIVE' where id = public.zzget('vendor')::uuid;
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','Walls: sales sees 0; inactive vendor refused; free-hand receipt refused',
          c1 = 0 and c2 = 0 and ok1 and ok2,
          format('sales: pos=%s reqs=%s · inactive_vendor_refused=%s freehand_receipt_refused=%s', c1, c2, ok1, ok2));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Walls: sales sees 0; inactive vendor refused; free-hand receipt refused', false, 'Error: ' || sqlerrm);
end $t$;

-- T8: tracking view shows ordered vs received without money
do $t$
declare v_ord numeric; v_rec numeric; v_vendor text;
begin
  perform set_config('request.jwt.claims', '{"sub":"cccc0000-0000-4000-8000-00000000f601","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select ordered_qty, received_qty, vendor_name into v_ord, v_rec, v_vendor
    from mfg.v_po_tracking where id = public.zzget('po')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8','Production tracks PO progress (qty only)', v_ord = 200 and v_rec = 200 and v_vendor like '%ZZTEST%',
          format('ordered=%s received=%s vendor=%s', v_ord, v_rec, v_vendor));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8','Production tracks PO progress (qty only)', false, 'Error: ' || sqlerrm);
end $t$;

select seq, section, test, case when ok then 'PASS' else 'FAIL' end as result, detail
from public.zztest_results order by seq;
