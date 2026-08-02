-- ================================================================================
--  MODULE 10 VERIFICATION — accounting (ZZTEST personas, Law 9)
--  ZZ Director · ZZ Jagdish (finance view+edit) · ZZ Pradeep (finance view+edit+approve)
--  · ZZ Sales (sales only, must see nothing) · ZZ Staff (a salaried employee)
-- ================================================================================
drop table if exists public.zztest_results;
create table public.zztest_results (seq serial primary key, test text, ok boolean, detail text);
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
 ('00000000-0000-0000-0000-000000000000','f0000000-0000-4000-8000-000000000d01','authenticated','authenticated','zztest_dir10@test.local','',now(),'{}','{"full_name":"ZZTEST Director10"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','f0000000-0000-4000-8000-0000000000a1','authenticated','authenticated','zztest_jag10@test.local','',now(),'{}','{"full_name":"ZZTEST Jagdish10"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','f0000000-0000-4000-8000-0000000000b2','authenticated','authenticated','zztest_pra10@test.local','',now(),'{}','{"full_name":"ZZTEST Pradeep10"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','f0000000-0000-4000-8000-0000000000c3','authenticated','authenticated','zztest_sal10@test.local','',now(),'{}','{"full_name":"ZZTEST Sales10"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','f0000000-0000-4000-8000-0000000000d4','authenticated','authenticated','zztest_emp10@test.local','',now(),'{}','{"full_name":"ZZTEST Employee10"}',now(),now())
on conflict (id) do nothing;
update adm.users set role='DIRECTOR' where id='f0000000-0000-4000-8000-000000000d01';
update adm.users set permissions_json='{"finance":{"view":true,"edit":true}}' where id='f0000000-0000-4000-8000-0000000000a1';
update adm.users set permissions_json='{"finance":{"view":true,"edit":true,"approve":true}}' where id='f0000000-0000-4000-8000-0000000000b2';
update adm.users set permissions_json='{"sales":{"view":true,"add":true,"edit":true}}' where id='f0000000-0000-4000-8000-0000000000c3';

select public.zzset('dir','f0000000-0000-4000-8000-000000000d01');
select public.zzset('jag','f0000000-0000-4000-8000-0000000000a1');
select public.zzset('pra','f0000000-0000-4000-8000-0000000000b2');
select public.zzset('sal','f0000000-0000-4000-8000-0000000000c3');
select public.zzset('emp','f0000000-0000-4000-8000-0000000000d4');

-- Director sets up a bank account
do $t$
declare v_id uuid;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into acct.bank_accounts (name, bank_name, account_tail, opening_balance, created_by)
  values ('ZZTEST Current A/C', 'HDFC', '4321', 100000, 'f0000000-0000-4000-8000-000000000d01') returning id into v_id;
  perform public.zzset('bank', v_id::text);
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail) values ('Bank account created, opening ₹1,00,000', true, 'ZZTEST Current A/C');
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Bank account created, opening ₹1,00,000', false, 'Error: '||sqlerrm);
end $t$;

-- T1: Jagdish makes a bank-in entry → PENDING; balance unchanged until approved
do $t$
declare v_e uuid; v_st text; v_bal numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_e := acct.create_entry('BANK_IN', 25000, public.zzget('bank')::uuid, null, null, current_date, 'NEFT', 'ZZ-UTR-1', null, null, 'ZZTEST customer', 'ZZTEST deposit');
  select status into v_st from acct.entries where id = v_e;
  select balance into v_bal from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  perform public.zzset('entry1', v_e::text);
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Jagdish entry is PENDING; balance still ₹1,00,000', v_st='PENDING_APPROVAL' and v_bal=100000, format('status=%s balance=%s', v_st, v_bal));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Jagdish entry is PENDING; balance still ₹1,00,000', false, 'Error: '||sqlerrm);
end $t$;

-- T2: Jagdish cannot approve his own entry
do $t$
declare ok1 boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  begin perform acct.approve_entry(public.zzget('entry1')::uuid); exception when others then ok1 := true; end;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail) values ('Jagdish cannot approve entries', ok1, 'refused='||ok1);
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Jagdish cannot approve entries', false, 'Error: '||sqlerrm);
end $t$;

-- T3: Pradeep approves → balance rises to 1,25,000
do $t$
declare v_st text; v_bal numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000b2","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform acct.approve_entry(public.zzget('entry1')::uuid);
  select status into v_st from acct.entries where id = public.zzget('entry1')::uuid;
  select balance into v_bal from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Pradeep approves → balance ₹1,25,000', v_st='APPROVED' and v_bal=125000, format('status=%s balance=%s', v_st, v_bal));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Pradeep approves → balance ₹1,25,000', false, 'Error: '||sqlerrm);
end $t$;

-- T4: Director edits the entry amount → balance re-derives (25000→30000 ⇒ 1,30,000)
do $t$
declare v_bal numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform acct.edit_entry(public.zzget('entry1')::uuid, 30000, null, null, null, 'ZZTEST corrected amount');
  select balance into v_bal from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail) values ('Director edits entry → balance ₹1,30,000', v_bal=130000, 'balance='||v_bal);
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Director edits entry → balance ₹1,30,000', false, 'Error: '||sqlerrm);
end $t$;

-- T5: Jagdish cannot edit or delete; Director deletes a fresh entry
do $t$
declare v_e uuid; ok_edit boolean := false; ok_del boolean := false; gone int;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_e := acct.create_entry('BANK_OUT', 5000, public.zzget('bank')::uuid, null, null, current_date, 'UPI', 'ZZ-2', null, null, 'ZZTEST petty', 'ZZTEST to delete');
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  begin perform acct.edit_entry(v_e, 1); exception when others then ok_edit := true; end;
  begin perform acct.delete_entry(v_e); exception when others then ok_del := true; end;
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  perform acct.delete_entry(v_e);
  select count(*) into gone from acct.entries where id = v_e;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Jagdish cannot edit/delete; Director deletes', ok_edit and ok_del and gone=0, format('jagdish_edit_refused=%s jagdish_delete_refused=%s director_deleted=%s', ok_edit, ok_del, gone=0));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Jagdish cannot edit/delete; Director deletes', false, 'Error: '||sqlerrm);
end $t$;

-- T6: salary — structure, generate slip, approve, pay → ledger OUT reduces balance
do $t$
declare v_slip uuid; v_gross numeric; v_net numeric; v_st text; v_entry uuid; v_bal_before numeric; v_bal_after numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  perform acct.set_salary_structure(public.zzget('emp')::uuid, 30000, 12000, 8000, 3600, 200, 0, 0);  -- gross 50000, ded 3800
  v_slip := acct.generate_salary_slip(public.zzget('emp')::uuid, '2026-08', 0, null, 0);
  select gross, net_pay, status into v_gross, v_net, v_st from acct.salary_slips where id = v_slip;
  perform public.zzset('slip', v_slip::text);
  select balance into v_bal_before from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  -- Pradeep approves + pays
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000b2","role":"authenticated"}', true);
  perform acct.approve_salary_slip(v_slip);
  v_entry := acct.pay_salary_slip(v_slip, public.zzget('bank')::uuid, 'NEFT', 'ZZ-SAL-1');
  select status into v_st from acct.salary_slips where id = v_slip;
  select balance into v_bal_after from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Salary slip: gross 50000, net 46200, paid → balance −46200',
          v_gross=50000 and v_net=46200 and v_st='PAID' and (v_bal_before - v_bal_after)=46200,
          format('gross=%s net=%s status=%s bank_drop=%s', v_gross, v_net, v_st, v_bal_before - v_bal_after));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Salary slip: gross 50000, net 46200, paid → balance −46200', false, 'Error: '||sqlerrm);
end $t$;

-- T7: advance — Jagdish records (PENDING), Pradeep approves+pays → bank OUT; recovery via slip reduces outstanding
do $t$
declare v_adv uuid; v_st text; v_out numeric; v_slip2 uuid; v_out2 numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  v_adv := acct.create_advance(public.zzget('emp')::uuid, 10000, 'ZZTEST festival advance');
  select status into v_st from acct.advances where id = v_adv;
  perform public.zzset('adv', v_adv::text);
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000b2","role":"authenticated"}', true);
  perform acct.approve_advance(v_adv, public.zzget('bank')::uuid, false, 'NEFT', 'ZZ-ADV-1');
  select outstanding into v_out from acct.v_advances where id = v_adv;
  -- recover 4000 via Sept slip
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  v_slip2 := acct.generate_salary_slip(public.zzget('emp')::uuid, '2026-09', 4000, v_adv, 0);
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000b2","role":"authenticated"}', true);
  perform acct.approve_salary_slip(v_slip2);
  select outstanding into v_out2 from acct.v_advances where id = v_adv;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Advance: PENDING→APPROVED, outstanding 10000, then 6000 after 4000 recovery',
          v_st='PENDING_APPROVAL' and v_out=10000 and v_out2=6000,
          format('created=%s out_after_pay=%s out_after_recovery=%s', v_st, v_out, v_out2));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Advance: PENDING→APPROVED, outstanding 10000, then 6000 after 4000 recovery', false, 'Error: '||sqlerrm);
end $t$;

-- T8: over-recovery refused
do $t$
declare ok1 boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000a1","role":"authenticated"}', true);
  execute 'set local role authenticated';
  begin perform acct.generate_salary_slip(public.zzget('emp')::uuid, '2026-10', 99999, public.zzget('adv')::uuid, 0); exception when others then ok1 := true; end;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail) values ('Recovery beyond advance outstanding refused', ok1, 'refused='||ok1);
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Recovery beyond advance outstanding refused', false, 'Error: '||sqlerrm);
end $t$;

-- T9: the whole section is invisible to a sales-only user
do $t$
declare c1 int; c2 int; c3 int; c4 int; ok_entry boolean := false; ok_slip boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-0000000000c3","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select count(*) into c1 from acct.bank_accounts;
  select count(*) into c2 from acct.entries;
  select count(*) into c3 from acct.salary_slips;
  select count(*) into c4 from acct.advances;
  begin perform acct.create_entry('BANK_IN', 1, public.zzget('bank')::uuid); exception when others then ok_entry := true; end;
  begin perform acct.generate_salary_slip(public.zzget('emp')::uuid, '2026-11'); exception when others then ok_slip := true; end;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Sales user sees nothing & cannot post in Accounting',
          c1=0 and c2=0 and c3=0 and c4=0 and ok_entry and ok_slip,
          format('banks=%s entries=%s slips=%s advances=%s entry_refused=%s slip_refused=%s', c1,c2,c3,c4,ok_entry,ok_slip));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Sales user sees nothing & cannot post in Accounting', false, 'Error: '||sqlerrm);
end $t$;

-- T10: a transfer moves money between two accounts, netting to zero across the pair
do $t$
declare v_b2 uuid; v_e uuid; v_b1 numeric; v_b2bal numeric; v_before numeric;
begin
  perform set_config('request.jwt.claims', '{"sub":"f0000000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  insert into acct.bank_accounts (name, opening_balance, created_by) values ('ZZTEST Savings A/C', 0, 'f0000000-0000-4000-8000-000000000d01') returning id into v_b2;
  select balance into v_before from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  v_e := acct.create_entry('TRANSFER', 20000, public.zzget('bank')::uuid, null, v_b2, current_date, 'RTGS', 'ZZ-TR', null, null, null, 'ZZTEST move to savings');
  select balance into v_b1 from acct.v_bank_balances where id = public.zzget('bank')::uuid;
  select balance into v_b2bal from acct.v_bank_balances where id = v_b2;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Transfer: −20000 from current, +20000 to savings (auto-approved by Director)',
          (v_before - v_b1)=20000 and v_b2bal=20000, format('current_drop=%s savings=%s', v_before - v_b1, v_b2bal));
exception when others then
  insert into public.zztest_results (test, ok, detail) values ('Transfer: −20000 from current, +20000 to savings (auto-approved by Director)', false, 'Error: '||sqlerrm);
end $t$;

select seq, test, case when ok then 'PASS' else 'FAIL' end as result, detail from public.zztest_results order by seq;
