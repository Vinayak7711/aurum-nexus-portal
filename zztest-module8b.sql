-- ================================================================================
--  MODULE 8b VERIFICATION — PO approval gate (ZZTEST personas, Law 9)
--  ZZ Jagdish (finance view+edit) · ZZ Pradeep (finance view+edit+approve) · ZZ Director
-- ================================================================================
drop table if exists public.zztest_results;
create table public.zztest_results (seq serial primary key, section text, test text, ok boolean, detail text);
grant select, insert on public.zztest_results to authenticated;
grant usage, select on sequence public.zztest_results_seq_seq to authenticated;
drop table if exists public.zztest_counters_before;
create table public.zztest_counters_before as select * from app.doc_counters;
drop table if exists public.zztest_vars;
create table public.zztest_vars (k text primary key, v text);
grant select, insert, update on public.zztest_vars to authenticated;
create or replace function public.zzset(p_k text, p_v text) returns void language sql as
$fn$ insert into public.zztest_vars values (p_k, p_v) on conflict (k) do update set v = excluded.v $fn$;
create or replace function public.zzget(p_k text) returns text language sql stable as
$fn$ select v from public.zztest_vars where k = p_k $fn$;
grant execute on function public.zzset(text,text), public.zzget(text) to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('00000000-0000-0000-0000-000000000000','dddd0000-0000-4000-8000-000000000d01','authenticated','authenticated','zztest_dirb@test.local','',now(),'{}','{"full_name":"ZZTEST DirectorB"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','dddd0000-0000-4000-8000-000000000101','authenticated','authenticated','zztest_jagdish@test.local','',now(),'{}','{"full_name":"ZZTEST Jagdish"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','dddd0000-0000-4000-8000-000000000102','authenticated','authenticated','zztest_pradeep@test.local','',now(),'{}','{"full_name":"ZZTEST Pradeep"}',now(),now())
on conflict (id) do nothing;
update adm.users set role = 'DIRECTOR' where id = 'dddd0000-0000-4000-8000-000000000d01';
update adm.users set permissions_json = '{"finance":{"view":true,"edit":true}}' where id = 'dddd0000-0000-4000-8000-000000000101';
update adm.users set permissions_json = '{"finance":{"view":true,"edit":true,"approve":true}}' where id = 'dddd0000-0000-4000-8000-000000000102';

-- vendor for the test
do $t$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into sales.vendors (code, name, status, created_by)
  values (app.next_code('VEN'), 'ZZTEST_APPROVAL VENDOR', 'ACTIVE', 'dddd0000-0000-4000-8000-000000000d01')
  returning id into v_id;
  perform public.zzset('vendor', v_id::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Vendor ready', true, 'ZZTEST_APPROVAL VENDOR');
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Vendor ready', false, 'Error: ' || sqlerrm);
end $t$;

-- T1: Jagdish initiates a PO → waits as PENDING_APPROVAL
do $t$
declare v_po uuid; v_st text;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000101","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_po := mfg.create_po(public.zzget('vendor')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 50, 'rate', 10))::jsonb from mfg.rm_items where code = 'CAP'),
    current_date + 4, null, 'ZZTEST approval flow');
  select status into v_st from mfg.purchase_orders where id = v_po;
  perform public.zzset('po', v_po::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8b','Jagdish (edit) initiates PO → PENDING_APPROVAL', v_st = 'PENDING_APPROVAL', 'status=' || v_st);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Jagdish (edit) initiates PO → PENDING_APPROVAL', false, 'Error: ' || sqlerrm);
end $t$;

-- T2: Jagdish cannot approve it, dispatch it, or receive against it
do $t$
declare ok1 boolean := false; ok2 boolean := false; ok3 boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000101","role":"authenticated"}', true);
  execute 'set local role authenticated';
  begin perform mfg.po_approve(public.zzget('po')::uuid); exception when others then ok1 := true; end;
  begin perform mfg.po_set_status(public.zzget('po')::uuid, 'DISPATCHED'); exception when others then ok2 := true; end;
  begin
    perform mfg.po_receive(public.zzget('po')::uuid,
      (select json_build_array(json_build_object('rm_item_id', id, 'qty', 10))::jsonb from mfg.rm_items where code = 'CAP'),
      'ZZ-CH', null);
  exception when others then ok3 := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8b','Unapproved PO: Jagdish cannot approve/dispatch/receive', ok1 and ok2 and ok3,
          format('approve_refused=%s dispatch_refused=%s receive_refused=%s', ok1, ok2, ok3));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Unapproved PO: Jagdish cannot approve/dispatch/receive', false, 'Harness error: ' || sqlerrm);
end $t$;

-- T3: Pradeep approves → PLACED with his stamp; then flow works (dispatch + receive)
do $t$
declare v_st text; v_appr uuid; v_bal numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000102","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform mfg.po_approve(public.zzget('po')::uuid);
  select status, approved_by into v_st, v_appr from mfg.purchase_orders where id = public.zzget('po')::uuid;
  perform mfg.po_set_status(public.zzget('po')::uuid, 'DISPATCHED');
  perform mfg.po_receive(public.zzget('po')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 50))::jsonb from mfg.rm_items where code = 'CAP'),
    'ZZ-CH-1', 'ZZ-INV-1');
  select store_balance into v_bal from mfg.v_rm_store where code = 'CAP';
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8b','Pradeep approves → PLACED (stamped) → dispatch → receive → store +50',
          v_st = 'PLACED' and v_appr = 'dddd0000-0000-4000-8000-000000000102' and v_bal = 50,
          format('after approval=%s stamped=%s store CAP=%s', v_st, v_appr is not null, v_bal));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Pradeep approves → PLACED (stamped) → dispatch → receive → store +50', false, 'Error: ' || sqlerrm);
end $t$;

-- T4: an approver's own PO starts PLACED (no self-waiting); double-approve refused
do $t$
declare v_po uuid; v_st text; ok_dup boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000102","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_po := mfg.create_po(public.zzget('vendor')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 5, 'rate', 2))::jsonb from mfg.rm_items where code = 'LBL'),
    null, null, 'ZZTEST self-approve');
  select status into v_st from mfg.purchase_orders where id = v_po;
  perform public.zzset('po2', v_po::text);
  begin perform mfg.po_approve(v_po); exception when others then ok_dup := true; end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8b','Approver''s own PO starts PLACED; approving again refused', v_st = 'PLACED' and ok_dup,
          format('status=%s re-approve_refused=%s', v_st, ok_dup));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','Approver''s own PO starts PLACED; approving again refused', false, 'Error: ' || sqlerrm);
end $t$;

-- T5: pending PO can be cancelled by Jagdish (initiator correcting himself)
do $t$
declare v_po uuid; v_st text;
begin
  perform set_config('request.jwt.claims', '{"sub":"dddd0000-0000-4000-8000-000000000101","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_po := mfg.create_po(public.zzget('vendor')::uuid,
    (select json_build_array(json_build_object('rm_item_id', id, 'qty', 3, 'rate', 1))::jsonb from mfg.rm_items where code = 'CTN'),
    null, null, 'ZZTEST cancel pending');
  perform mfg.po_set_status(v_po, 'CANCELLED');
  select status into v_st from mfg.purchase_orders where id = v_po;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('M8b','A pending PO can be cancelled before approval', v_st = 'CANCELLED', 'status=' || v_st);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('M8b','A pending PO can be cancelled before approval', false, 'Error: ' || sqlerrm);
end $t$;

select seq, section, test, case when ok then 'PASS' else 'FAIL' end as result, detail
from public.zztest_results order by seq;
