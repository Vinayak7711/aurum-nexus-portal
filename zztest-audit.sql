-- ================================================================================
--  AURUM NEXUS — FULL-SYSTEM AUDIT (ZZTEST discipline, Law 9)
--  Makes one entry in EVERY section under simulated personas, verifies behaviour,
--  and records PASS / FAIL / DEFECT rows. Sweep script removes everything after.
--  Personas: ZZ Director · ZZ Salesperson · ZZ Accounts · ZZ MMC staff · ZZ NoAccess
-- ================================================================================

-- ---------- S0: SCAFFOLD ----------
drop table if exists public.zztest_results;
create table public.zztest_results (seq serial primary key, section text, test text, ok boolean, detail text);
grant select, insert on public.zztest_results to authenticated;
grant usage, select on sequence public.zztest_results_seq_seq to authenticated;

drop table if exists public.zztest_vars;
create table public.zztest_vars (k text primary key, v text);
grant select, insert, update on public.zztest_vars to authenticated;

drop table if exists public.zztest_counters_before;
create table public.zztest_counters_before as select * from app.doc_counters;

create or replace function public.zzset(p_k text, p_v text) returns void language sql as
$fn$ insert into public.zztest_vars values (p_k, p_v) on conflict (k) do update set v = excluded.v $fn$;
create or replace function public.zzget(p_k text) returns text language sql stable as
$fn$ select v from public.zztest_vars where k = p_k $fn$;
grant execute on function public.zzset(text,text), public.zzget(text) to authenticated;

-- Personas (auth.users insert fires the auto-onboard trigger = live test of Phase 0)
insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('00000000-0000-0000-0000-000000000000','aaaa0000-0000-4000-8000-000000000d01','authenticated','authenticated','zztest_dir@test.local','',now(),'{}','{"full_name":"ZZTEST Director"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','aaaa0000-0000-4000-8000-00000000a502','authenticated','authenticated','zztest_sales@test.local','',now(),'{}','{"full_name":"ZZTEST Salesperson"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','aaaa0000-0000-4000-8000-00000000ac03','authenticated','authenticated','zztest_acct@test.local','',now(),'{}','{"full_name":"ZZTEST Accounts"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','aaaa0000-0000-4000-8000-00000000f604','authenticated','authenticated','zztest_mfg@test.local','',now(),'{}','{"full_name":"ZZTEST MMC Staff"}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','aaaa0000-0000-4000-8000-000000000005','authenticated','authenticated','zztest_none@test.local','',now(),'{}','{"full_name":"ZZTEST NoAccess"}',now(),now())
on conflict (id) do nothing;

-- S0.1 auto-onboard trigger created all five as STAFF with no permissions
do $t$
declare n int;
begin
  select count(*) into n from adm.users
   where email like 'zztest_%@test.local' and role = 'STAFF' and permissions_json = '{}'::jsonb;
  insert into public.zztest_results (section, test, ok, detail)
  values ('S0 Identity','Auto-onboard: 5 sign-ins auto-created as STAFF, zero access', n = 5, n || ' of 5 rows correct');
end $t$;

-- Grant persona roles (as the Director would in Control Panel)
update adm.users set role = 'DIRECTOR' where id = 'aaaa0000-0000-4000-8000-000000000d01';
update adm.users set permissions_json = '{"sales":{"view":true,"add":true,"edit":true}}' where id = 'aaaa0000-0000-4000-8000-00000000a502';
update adm.users set permissions_json = '{"finance":{"view":true,"edit":true}}' where id = 'aaaa0000-0000-4000-8000-00000000ac03';
update adm.users set permissions_json = '{"mfg":{"view":true,"add":true,"edit":true}}' where id = 'aaaa0000-0000-4000-8000-00000000f604';

-- Stash master ids
select public.zzset('dir',  'aaaa0000-0000-4000-8000-000000000d01');
select public.zzset('sal',  'aaaa0000-0000-4000-8000-00000000a502');
select public.zzset('acc',  'aaaa0000-0000-4000-8000-00000000ac03');
select public.zzset('mfg',  'aaaa0000-0000-4000-8000-00000000f604');
select public.zzset('non',  'aaaa0000-0000-4000-8000-000000000005');
select public.zzset('sku750', (select id::text from sales.skus where sku_code = 'DC-750-PET'));
select public.zzset('sku180', (select id::text from sales.skus where sku_code = 'DC-180-PET'));
select public.zzset('skuGls', (select id::text from sales.skus where sku_code = 'DC-750-GLASS'));
select public.zzset('ena',    (select id::text from mfg.rm_items where code = 'ENA'));
select public.zzset('terr',   (select id::text from sales.territories where name = 'Thane to Khopoli & Thane to Kasara'));

-- ---------- S1: IDENTITY, LOCKS, ISOLATION ----------
-- S1.1 founder lock: a superadmin row cannot be touched by ANY other user, even a
--      Director. Tested on a ZZTEST row so the real founder is never involved.
do $t$
declare v_hit boolean := false;
begin
  update adm.users set is_superadmin = true where email = 'zztest_acct@test.local';
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    update adm.users set role = 'STAFF', full_name = 'ZZ hacked' where email = 'zztest_acct@test.local';
  exception when others then v_hit := true;
  end;
  execute 'reset role';
  alter table adm.users disable trigger trg_protect_superadmin;
  update adm.users set is_superadmin = false where email = 'zztest_acct@test.local';
  alter table adm.users enable trigger trg_protect_superadmin;
  insert into public.zztest_results (section, test, ok, detail)
  values ('S1 Identity','Founder lock blocks edits to a superadmin by anyone else', v_hit,
          case when v_hit then 'Refused as designed' else 'DEFECT: another Director modified a superadmin row' end);
exception when others then
  alter table adm.users enable trigger trg_protect_superadmin;
  insert into public.zztest_results (section, test, ok, detail) values ('S1 Identity','Founder lock blocks edits to a superadmin by anyone else', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S1.2 STAFF with no grants sees nothing anywhere
do $t$
declare c1 int; c2 int; c3 int; c4 int; c5 int; c6 int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('non'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c1 from sales.parties;
  select count(*) into c2 from sales.brands;
  select count(*) into c3 from sales.orders;
  select count(*) into c4 from sales.rate_cards;
  select count(*) into c5 from mfg.batches;
  select count(*) into c6 from comp.documents;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S1 Identity','No-access STAFF sees zero rows in all modules', c1+c2+c3+c4+c5+c6 = 0,
          format('parties=%s brands=%s orders=%s rates=%s batches=%s docs=%s', c1,c2,c3,c4,c5,c6));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S1 Identity','No-access STAFF sees zero rows in all modules', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S1.3 no-access STAFF cannot create an order
do $t$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('non'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform sales.create_order((select id from sales.parties limit 1), '[]'::jsonb, null);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S1 Identity','No-access STAFF blocked from creating orders', false, 'DEFECT: call permitted');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S1 Identity','No-access STAFF blocked from creating orders', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S1 Identity','No-access STAFF blocked from creating orders', false, 'Harness error: ' || sqlerrm);
end $t$;

-- ---------- S2: SALES & MONEY ----------
-- S2.1 salesperson creates a distributor in the merged Thane area
do $t$
declare v_id uuid; v_code text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_code := app.next_party_code();
  insert into sales.parties (code, name, state_id, city, owner_id, created_by, territory_id)
  values (v_code, 'ZZTEST_DISTRIBUTOR PVT LTD', 'MH', 'Thane', public.zzget('sal')::uuid, public.zzget('sal')::uuid, public.zzget('terr')::uuid)
  returning id into v_id;
  perform public.zzset('party1', v_id::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Salesperson creates distributor (merged Thane area)', v_code like 'DST-%', 'code=' || v_code);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Salesperson creates distributor (merged Thane area)', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.2 salesperson places an indent (2 SKUs, cases only — no money fields)
do $t$
declare v_ord uuid; v_no text; v_lines int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_ord := sales.create_order(public.zzget('party1')::uuid,
            json_build_array(json_build_object('sku_id', public.zzget('sku750'), 'cases', 10),
                             json_build_object('sku_id', public.zzget('sku180'), 'cases', 5))::jsonb,
            'ZZTEST order');
  select so_no into v_no from sales.orders where id = v_ord;
  select count(*) into v_lines from sales.order_lines where order_id = v_ord;
  perform public.zzset('order1', v_ord::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Salesperson places indent with 2 SKU lines', v_no like 'SO/%' and v_lines = 2, v_no || ', lines=' || v_lines);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Salesperson places indent with 2 SKU lines', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.3 money stays invisible to the salesperson
do $t$
declare c1 int; c2 int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c1 from sales.rate_cards;
  select count(*) into c2 from sales.order_values;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Rates & order values invisible to salesperson', c1 = 0 and c2 = 0, format('rate_cards=%s order_values=%s', c1, c2));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Rates & order values invisible to salesperson', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.4 salesperson cannot approve
do $t$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform sales.approve_order(public.zzget('order1')::uuid);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Salesperson blocked from approving', false, 'DEFECT: approve permitted');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Salesperson blocked from approving', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Salesperson blocked from approving', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.5 Director approves — rates stamped correctly from the cost card
do $t$
declare v_amt750 numeric; v_amt180 numeric; v_status text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform sales.approve_order(public.zzget('order1')::uuid);
  select status into v_status from sales.orders where id = public.zzget('order1')::uuid;
  select v.amount into v_amt750 from sales.order_values v join sales.order_lines l on l.id = v.line_id
   where l.order_id = public.zzget('order1')::uuid and l.sku_id = public.zzget('sku750')::uuid;
  select v.amount into v_amt180 from sales.order_values v join sales.order_lines l on l.id = v.line_id
   where l.order_id = public.zzget('order1')::uuid and l.sku_id = public.zzget('sku180')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Approval stamps cost-card rates (6288.19/case)',
          v_status = 'APPROVED' and v_amt750 = 62881.90 and v_amt180 = 31440.95,
          format('status=%s 750PETx10=%s (want 62881.90) 180PETx5=%s (want 31440.95)', v_status, v_amt750, v_amt180));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Approval stamps cost-card rates (6288.19/case)', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.6 approval refuses a SKU with no rate on file (750 GLASS — by design)
do $t$
declare v_ord uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_ord := sales.create_order(public.zzget('party1')::uuid,
            json_build_array(json_build_object('sku_id', public.zzget('skuGls'), 'cases', 2))::jsonb, 'ZZTEST glass');
  perform public.zzset('orderGls', v_ord::text);
  begin
    perform sales.approve_order(v_ord);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Approval refuses SKU with no rate (750 GLASS)', false, 'DEFECT: approved without a rate');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Approval refuses SKU with no rate (750 GLASS)', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Approval refuses SKU with no rate (750 GLASS)', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.7 empty order refused
do $t$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform sales.create_order(public.zzget('party1')::uuid, '[]'::jsonb, null);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Empty order refused', false, 'DEFECT: empty order accepted');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Empty order refused', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Empty order refused', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.8 zero-case line refused
do $t$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform sales.create_order(public.zzget('party1')::uuid,
              json_build_array(json_build_object('sku_id', public.zzget('sku750'), 'cases', 0))::jsonb, null);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Zero-case line refused', false, 'DEFECT: zero cases accepted');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Zero-case line refused', true, 'Refused (raw msg): ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Zero-case line refused', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.9 duplicate SKU lines refused
do $t$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    perform sales.create_order(public.zzget('party1')::uuid,
              json_build_array(json_build_object('sku_id', public.zzget('sku750'), 'cases', 1),
                               json_build_object('sku_id', public.zzget('sku750'), 'cases', 2))::jsonb, null);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Duplicate SKU lines refused', false, 'DEFECT: duplicate lines accepted');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Duplicate SKU lines refused', true, 'Refused (raw msg): ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Duplicate SKU lines refused', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.10 PROBE: order against a DEACTIVATED distributor — should be refused
do $t$
declare v_ord uuid;
begin
  update sales.parties set is_active = false where id = public.zzget('party1')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    v_ord := sales.create_order(public.zzget('party1')::uuid,
              json_build_array(json_build_object('sku_id', public.zzget('sku750'), 'cases', 1))::jsonb, 'ZZTEST inactive probe');
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S2 Sales','Order against deactivated distributor refused', false, 'DEFECT: order ' || (select so_no from sales.orders where id = v_ord) || ' accepted for an inactive party');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Order against deactivated distributor refused', true, 'Refused: ' || sqlerrm);
  end;
  update sales.parties set is_active = true where id = public.zzget('party1')::uuid;
exception when others then
  update sales.parties set is_active = true where id = public.zzget('party1')::uuid;
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Order against deactivated distributor refused', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.11 Director dispatches — invoice, CM payable accrual, FG movement
--       (Director first stages FG stock with a manual ADJ so dispatch is honest)
do $t$
declare v_status text; v_cm int; v_cm_amt numeric; v_fg int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into mfg.fg_movements (sku_id, direction, cases, reason, created_by) values
    (public.zzget('sku750')::uuid, 'ADJ', 10, 'ZZTEST opening stock', public.zzget('dir')::uuid),
    (public.zzget('sku180')::uuid, 'ADJ', 5,  'ZZTEST opening stock', public.zzget('dir')::uuid);
  perform sales.dispatch_order(public.zzget('order1')::uuid, 'ZZTEST-INV-001');
  select status into v_status from sales.orders where id = public.zzget('order1')::uuid;
  select count(*), sum(amount) into v_cm, v_cm_amt from sales.cm_payables where order_id = public.zzget('order1')::uuid;
  select count(*) into v_fg from mfg.fg_movements where order_id = public.zzget('order1')::uuid and direction = 'OUT';
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Dispatch: invoice + MMC payable + FG OUT',
          v_status = 'DISPATCHED' and v_cm = 2 and v_cm_amt = 15429.60 and v_fg = 2,
          format('status=%s cm_rows=%s cm_amount=%s (want 15429.60 = 10286.40+5143.20) fg_out=%s', v_status, v_cm, v_cm_amt, v_fg));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Dispatch: invoice + MMC payable + FG OUT', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.12 PROBE: dispatching MORE than FG stock — should be refused, never negative
do $t$
declare v_party uuid; v_ord uuid; v_bal numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into sales.parties (code, name, state_id, owner_id, created_by)
  values (app.next_party_code(), 'ZZTEST_STOCKPROBE PVT LTD', 'MH', public.zzget('dir')::uuid, public.zzget('dir')::uuid)
  returning id into v_party;
  perform public.zzset('party4', v_party::text);
  v_ord := sales.create_order(v_party,
            json_build_array(json_build_object('sku_id', public.zzget('sku180'), 'cases', 2))::jsonb, 'ZZTEST stock probe');
  perform sales.approve_order(v_ord);
  begin
    perform sales.dispatch_order(v_ord, 'ZZTEST-INV-STOCK');
    select cases into v_bal from mfg.v_fg_stock where sku_id = public.zzget('sku180')::uuid;
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S2 Sales','Dispatch guarded by FG stock (no negative stock)', false,
            'DEFECT: dispatched 2 cases with 0 in stock — FG stock now ' || v_bal);
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S2 Sales','Dispatch guarded by FG stock (no negative stock)', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Dispatch guarded by FG stock (no negative stock)', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.13 Accounts records a payment; salesperson cannot; negative amount refused
do $t$
declare ok1 boolean := false; ok2 boolean := false; ok3 boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('acc'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into sales.payments (party_id, order_id, amount, mode, ref_no, remarks, created_by)
  values (public.zzget('party1')::uuid, public.zzget('order1')::uuid, 50000, 'NEFT', 'ZZTEST-UTR', 'ZZTEST', public.zzget('acc')::uuid);
  ok1 := true;
  begin
    insert into sales.payments (party_id, amount, mode, remarks, created_by)
    values (public.zzget('party1')::uuid, -100, 'CASH', 'ZZTEST', public.zzget('acc')::uuid);
  exception when others then ok2 := true;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  begin
    insert into sales.payments (party_id, amount, mode, remarks, created_by)
    values (public.zzget('party1')::uuid, 999, 'CASH', 'ZZTEST', public.zzget('sal')::uuid);
  exception when others then ok3 := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Money','Payments: Accounts can record; negative & salesperson refused', ok1 and ok2 and ok3,
          format('acct_insert=%s negative_refused=%s salesperson_refused=%s', ok1, ok2, ok3));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Money','Payments: Accounts can record; negative & salesperson refused', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.14 PROBE: payment against an order of a DIFFERENT party — should be refused
do $t$
declare v_other uuid;
begin
  insert into sales.parties (code, name, state_id, owner_id, created_by)
  values (app.next_party_code(), 'ZZTEST_OTHER PARTY', 'MH', public.zzget('dir')::uuid, public.zzget('dir')::uuid)
  returning id into v_other;
  perform public.zzset('party2', v_other::text);
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('acc'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into sales.payments (party_id, order_id, amount, mode, remarks, created_by)
    values (v_other, public.zzget('order1')::uuid, 100, 'CASH', 'ZZTEST-MISMATCH', public.zzget('acc')::uuid);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S2 Money','Payment party must match the order''s party', false, 'DEFECT: payment accepted against another party''s order');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Money','Payment party must match the order''s party', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Money','Payment party must match the order''s party', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S2.15 Outstanding: Director sees the truth; Accounts must see the SAME truth
do $t$
declare d_billed numeric; d_out numeric; a_billed numeric; a_out numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select billed, outstanding into d_billed, d_out from sales.v_party_outstanding where party_id = public.zzget('party1')::uuid;
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('acc'), 'role','authenticated')::text, true);
  select billed, outstanding into a_billed, a_out from sales.v_party_outstanding where party_id = public.zzget('party1')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Money','Outstanding correct for Director AND Accounts',
          d_billed = 94322.85 and d_out = 44322.85 and a_billed = 94322.85 and a_out = 44322.85,
          format('director billed=%s out=%s · accounts billed=%s out=%s (want 94322.85 / 44322.85)', d_billed, d_out, a_billed, a_out));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Money','Outstanding correct for Director AND Accounts', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.16 PROBE: Director corrects a wrong payment — via a reversal entry that keeps history
do $t$
declare v_out1 numeric; v_out2 numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into sales.payments (party_id, order_id, amount, mode, ref_no, remarks, created_by)
  values (public.zzget('party1')::uuid, public.zzget('order1')::uuid, -50000, 'NEFT', 'ZZTEST-REV', 'ZZTEST reversal of wrong entry', public.zzget('dir')::uuid);
  select outstanding into v_out1 from sales.v_party_outstanding where party_id = public.zzget('party1')::uuid;
  insert into sales.payments (party_id, order_id, amount, mode, ref_no, remarks, created_by)
  values (public.zzget('party1')::uuid, public.zzget('order1')::uuid, 50000, 'NEFT', 'ZZTEST-UTR2', 'ZZTEST corrected re-entry', public.zzget('dir')::uuid);
  select outstanding into v_out2 from sales.v_party_outstanding where party_id = public.zzget('party1')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Money','Director can correct a mis-entered payment (reversal entry)',
          v_out1 = 94322.85 and v_out2 = 44322.85,
          format('after reversal outstanding=%s (want 94322.85), after re-entry=%s (want 44322.85) — history preserved', v_out1, v_out2));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Money','Director can correct a mis-entered payment (reversal entry)', false,
    'DEFECT/Error: ' || sqlerrm);
end $t$;

-- S2.17 cancel an approved order → drops out of outstanding
do $t$
declare v_ord uuid; v_out numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_ord := sales.create_order(public.zzget('party1')::uuid,
            json_build_array(json_build_object('sku_id', public.zzget('sku750'), 'cases', 3))::jsonb, 'ZZTEST cancel probe');
  perform sales.approve_order(v_ord);
  perform sales.set_order_status(v_ord, 'CANCELLED');
  select outstanding into v_out from sales.v_party_outstanding where party_id = public.zzget('party1')::uuid;
  execute 'reset role';
  perform public.zzset('order2', v_ord::text);
  insert into public.zztest_results (section, test, ok, detail)
  values ('S2 Sales','Cancelled order excluded from outstanding', v_out = 44322.85, 'outstanding=' || v_out || ' (want 44322.85)');
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Sales','Cancelled order excluded from outstanding', false, 'Error: ' || sqlerrm);
end $t$;

-- S2.18 PROBE: SKU master accepts units_per_case = 0 — should be refused
do $t$
declare v_brand uuid; v_sku uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into sales.brands (name, category_id) values ('ZZTEST_BRAND', 'MML') returning id into v_brand;
  perform public.zzset('brand1', v_brand::text);
  begin
    insert into sales.skus (sku_code, brand_id, size_ml, units_per_case, material)
    values ('ZZTEST-750-PET', v_brand, 750, 0, 'PET') returning id into v_sku;
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S2 Masters','SKU with 0 units/case refused', false, 'DEFECT: units_per_case=0 accepted — breaks every per-case calculation');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S2 Masters','SKU with 0 units/case refused', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S2 Masters','SKU with 0 units/case refused', false, 'Harness error: ' || sqlerrm);
end $t$;

-- ---------- S3: MANUFACTURING @ MMC ----------
-- S3.1 Director issues RM to MMC; stationed staff confirms receipt
do $t$
declare v_id uuid; v_rec uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into mfg.rm_issues (rm_item_id, qty, challan_no, remarks, created_by)
  values (public.zzget('ena')::uuid, 100, 'ZZTEST-CH-1', 'ZZTEST', public.zzget('dir')::uuid) returning id into v_id;
  perform public.zzset('rmissue1', v_id::text);
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  update mfg.rm_issues set received_by = public.zzget('mfg')::uuid, received_at = now() where id = v_id;
  select received_by into v_rec from mfg.rm_issues where id = v_id;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','RM issued by Director, receipt confirmed by MMC staff', v_rec = public.zzget('mfg')::uuid, '100 L ENA on challan ZZTEST-CH-1');
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','RM issued by Director, receipt confirmed by MMC staff', false, 'Error: ' || sqlerrm);
end $t$;

-- S3.2 MMC staff records a batch consuming RM; RM balance updates
do $t$
declare v_bat uuid; v_no text; v_bal numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_bat := mfg.create_batch(public.zzget('sku750')::uuid, 50, current_date,
            json_build_array(json_build_object('rm_item_id', public.zzget('ena'), 'qty', 60))::jsonb);
  select batch_no into v_no from mfg.batches where id = v_bat;
  select balance into v_bal from mfg.v_rm_stock where rm_item_id = public.zzget('ena')::uuid;
  perform public.zzset('batch1', v_bat::text);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','Batch recorded, RM consumed (100 issued − 60 used = 40)', v_no like 'BAT/%' and v_bal = 40, v_no || ', ENA balance=' || v_bal);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','Batch recorded, RM consumed (100 issued − 60 used = 40)', false, 'Error: ' || sqlerrm);
end $t$;

-- S3.3 QC pass moves 50 cases into FG stock, exactly once
do $t$
declare v_in int; v_fg numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform mfg.qc_set(public.zzget('batch1')::uuid, 'PASSED', 'ZZTEST QC ok');
  perform mfg.qc_set(public.zzget('batch1')::uuid, 'PASSED', 'ZZTEST QC again');
  select count(*) into v_in from mfg.fg_movements where batch_id = public.zzget('batch1')::uuid and direction = 'IN';
  select cases into v_fg from mfg.v_fg_stock where sku_id = public.zzget('sku750')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','QC PASS books FG IN exactly once', v_in = 1, format('IN rows=%s, FG 750PET stock now=%s (50 in − 10 dispatched earlier = 40 expected)', v_in, v_fg));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','QC PASS books FG IN exactly once', false, 'Error: ' || sqlerrm);
end $t$;

-- S3.4 PROBE: QC reverted to FAILED after PASSED — does FG stock come back out?
do $t$
declare v_in int; v_out int; v_status text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform mfg.qc_set(public.zzget('batch1')::uuid, 'FAILED', 'ZZTEST reverting after pass');
  select qc_status into v_status from mfg.batches where id = public.zzget('batch1')::uuid;
  select count(*) filter (where direction='IN'), count(*) filter (where direction in ('OUT','ADJ'))
    into v_in, v_out from mfg.fg_movements where batch_id = public.zzget('batch1')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','QC revert to FAILED reverses the FG IN', v_out >= 1,
          case when v_out = 0 then 'DEFECT: batch now ' || v_status || ' but its 50 cases are still counted in FG stock' else 'reversal rows=' || v_out end);
  -- put it back to PASSED for later flows
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  perform mfg.qc_set(public.zzget('batch1')::uuid, 'PASSED', 'ZZTEST restore');
  execute 'reset role';
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','QC revert to FAILED reverses the FG IN', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S3.5 PROBE: batch consuming more RM than exists — should be refused
do $t$
declare v_bat uuid; v_bal numeric;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    v_bat := mfg.create_batch(public.zzget('sku180')::uuid, 10, current_date,
              json_build_array(json_build_object('rm_item_id', public.zzget('ena'), 'qty', 500))::jsonb);
    perform public.zzset('batch2', v_bat::text);
    select balance into v_bal from mfg.v_rm_stock where rm_item_id = public.zzget('ena')::uuid;
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S3 Mfg','Batch cannot consume more RM than in custody', false, 'DEFECT: consumed 500 L against 40 L — ENA balance now ' || v_bal);
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','Batch cannot consume more RM than in custody', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','Batch cannot consume more RM than in custody', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S3.6 module isolation: salesperson can't see mfg; MMC staff can't see money
do $t$
declare c1 int; c2 int; c3 int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c1 from mfg.batches;
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  select count(*) into c2 from sales.rate_cards;
  select count(*) into c3 from sales.order_values;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','Module isolation (sales↮mfg, mfg↮money)', c1 = 0 and c2 = 0 and c3 = 0,
          format('sales→batches=%s mfg→rates=%s mfg→values=%s', c1, c2, c3));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','Module isolation (sales↮mfg, mfg↮money)', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S3.7 PROBE: can MMC staff actually SEE products & FG stock on their screens?
do $t$
declare c_sku int; c_fg int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c_sku from sales.skus;
  select count(*) into c_fg from mfg.v_fg_stock;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S3 Mfg','MMC staff can see SKU names & FG stock screen', c_sku > 0 and c_fg > 0,
          case when c_sku = 0 then 'DEFECT: mfg staff see 0 SKUs — their batch & FG screens are blank (skus need a read grant for mfg)'
               else format('skus=%s fg_rows=%s', c_sku, c_fg) end);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S3 Mfg','MMC staff can see SKU names & FG stock screen', false, 'Harness error: ' || sqlerrm);
end $t$;

-- ---------- S4: ONBOARDING & VENDORS ----------
-- S4.1 plain salesperson has no access to onboarding registers
do $t$
declare c1 int; ok1 boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c1 from sales.onboarding;
  begin
    insert into sales.onboarding (app_no, applicant_name, created_by) values (app.next_code('DOF'), 'ZZTEST NOPE', public.zzget('sal')::uuid);
  exception when others then ok1 := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S4 Onboarding','Onboarding register hidden from plain salesperson', c1 = 0 and ok1, format('visible=%s insert_refused=%s', c1, ok1));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S4 Onboarding','Onboarding register hidden from plain salesperson', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S4.2 Director files an application and approves it → distributor auto-created
do $t$
declare v_id uuid; v_no text; v_party uuid; v_code text; ok_dup boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_no := app.next_code('DOF');
  insert into sales.onboarding (app_no, applicant_name, trade_name, state_id, territory, contacts, created_by)
  values (v_no, 'ZZTEST Applicant', 'ZZTEST_TRADERS', 'MH', 'Thane to Khopoli & Thane to Kasara',
          '{"owner":"ZZ Owner","phone":"9999999999","email":"zz@t.local"}'::jsonb, public.zzget('dir')::uuid)
  returning id into v_id;
  perform public.zzset('onb1', v_id::text);
  v_party := sales.onboarding_approve(v_id);
  perform public.zzset('party3', v_party::text);
  select code into v_code from sales.parties where id = v_party;
  begin
    perform sales.onboarding_approve(v_id);
  exception when others then ok_dup := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S4 Onboarding','Application approved → party auto-created; re-approve refused',
          v_no like 'DOF/%' and v_code like 'DST-%' and ok_dup,
          format('%s → %s, double-approve refused=%s', v_no, v_code, ok_dup));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S4 Onboarding','Application approved → party auto-created; re-approve refused', false, 'Error: ' || sqlerrm);
end $t$;

-- S4.3 vendor registered with VEN number
do $t$
declare v_code text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_code := app.next_code('VEN');
  insert into sales.vendors (code, name, category, created_by)
  values (v_code, 'ZZTEST_VENDOR SUPPLIES', 'Packaging', public.zzget('dir')::uuid);
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S4 Onboarding','Vendor registered with VEN number', v_code like 'VEN/%', v_code);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S4 Onboarding','Vendor registered with VEN number', false, 'Error: ' || sqlerrm);
end $t$;

-- ---------- S5: TASKS ----------
-- S5.1 Director assigns; assignee sees it; others don't; assignee can't assign
do $t$
declare v_task uuid; v_no text; c_mfg int; c_sal int; ok_deny boolean := false;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  v_task := tasks.create_task('ZZTEST: check dispatch register', 'ZZTEST detail', public.zzget('mfg')::uuid, current_date - 1, 'HIGH');
  select task_no into v_no from tasks.tasks where id = v_task;
  perform public.zzset('task1', v_task::text);
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  select count(*) into c_mfg from tasks.tasks where title like 'ZZTEST%';
  begin
    perform tasks.create_task('ZZTEST rogue', null, public.zzget('mfg')::uuid, current_date, 'NORMAL');
  exception when others then ok_deny := true;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('sal'), 'role','authenticated')::text, true);
  select count(*) into c_sal from tasks.tasks where title like 'ZZTEST%';
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S5 Tasks','Only Director assigns; visibility is assignee-only',
          v_no like 'TSK/%' and c_mfg = 1 and c_sal = 0 and ok_deny,
          format('%s · assignee sees=%s others see=%s staff-assign refused=%s', v_no, c_mfg, c_sal, ok_deny));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S5 Tasks','Only Director assigns; visibility is assignee-only', false, 'Error: ' || sqlerrm);
end $t$;

-- S5.2 assignee completes the task
do $t$
declare v_status text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  update tasks.tasks set status = 'DONE', completion_note = 'ZZTEST done', completed_at = now()
   where id = public.zzget('task1')::uuid;
  select status into v_status from tasks.tasks where id = public.zzget('task1')::uuid;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S5 Tasks','Assignee completes own task', v_status = 'DONE', 'status=' || v_status);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S5 Tasks','Assignee completes own task', false, 'Error: ' || sqlerrm);
end $t$;

-- S5.3 recurring duty generates its period entry and marks lapses
do $t$
declare v_duty uuid; v_status text; v_due date;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into tasks.duties (title, assignee_id, freq, day_of, created_by)
  values ('ZZTEST duty: FG count', public.zzget('mfg')::uuid, 'MONTHLY', 1, public.zzget('dir')::uuid)
  returning id into v_duty;
  perform public.zzset('duty1', v_duty::text);
  perform tasks.generate_duty_log();
  select status, due_date into v_status, v_due from tasks.duty_log where duty_id = v_duty;
  -- force a lapse check regardless of today's date
  update tasks.duty_log set due_date = current_date - 5, status = 'DUE' where duty_id = v_duty;
  perform tasks.generate_duty_log();
  select status into v_status from tasks.duty_log where duty_id = v_duty;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S5 Tasks','Duty auto-generates period entry; overdue → LAPSED', v_status = 'LAPSED',
          format('period entry due=%s, after backdating status=%s', v_due, v_status));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S5 Tasks','Duty auto-generates period entry; overdue → LAPSED', false, 'Error: ' || sqlerrm);
end $t$;

-- S5.4 PROBE: nonsense duty schedule accepted? (WEEKLY day 45)
do $t$
declare v_duty uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    insert into tasks.duties (title, assignee_id, freq, day_of, created_by)
    values ('ZZTEST bad schedule', public.zzget('mfg')::uuid, 'WEEKLY', 45, public.zzget('dir')::uuid)
    returning id into v_duty;
    perform public.zzset('duty2', v_duty::text);
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S5 Tasks','Duty schedule rejects impossible day (WEEKLY day 45)', false, 'DEFECT: day_of=45 accepted — its due date lands 6 weeks away');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S5 Tasks','Duty schedule rejects impossible day (WEEKLY day 45)', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S5 Tasks','Duty schedule rejects impossible day (WEEKLY day 45)', false, 'Harness error: ' || sqlerrm);
end $t$;

-- ---------- S6: EXCISE & RENEWALS ----------
-- S6.1 all four categories entered; alert colours match the thresholds
do $t$
declare v_exp text; v_red text; v_amb text; v_okl text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  insert into comp.documents (title, category, ref_no, valid_to, created_by) values
    ('ZZTEST Excise Licence',   'EXCISE_LICENSE',   'ZZ-EL', current_date - 1,  public.zzget('dir')::uuid),
    ('ZZTEST Vehicle Insurance','INSURANCE_VEHICLE','ZZ-VI', current_date + 15, public.zzget('dir')::uuid),
    ('ZZTEST Label Regn',       'LABEL_REGN',       'ZZ-LR', current_date + 90, public.zzget('dir')::uuid),
    ('ZZTEST MMC Agreement',    'AGREEMENT',        'ZZ-AG', current_date + 90, public.zzget('dir')::uuid);
  select alert_level into v_exp from comp.v_expiring where ref_no = 'ZZ-EL';
  select alert_level into v_red from comp.v_expiring where ref_no = 'ZZ-VI';
  select alert_level into v_amb from comp.v_expiring where ref_no = 'ZZ-LR';
  select alert_level into v_okl from comp.v_expiring where ref_no = 'ZZ-AG';
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S6 Renewals','4 categories entered; alert colours correct',
          v_exp = 'EXPIRED' and v_red = 'RED' and v_amb = 'AMBER' and v_okl = 'OK',
          format('licence=%s insurance=%s label(120d window)=%s agreement(60d window)=%s', v_exp, v_red, v_amb, v_okl));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S6 Renewals','4 categories entered; alert colours correct', false, 'Error: ' || sqlerrm);
end $t$;

-- S6.2 renewal moves the date and writes history
do $t$
declare v_doc uuid; v_new date; v_hist int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select id into v_doc from comp.documents where ref_no = 'ZZ-VI';
  perform comp.renew_document(v_doc, current_date + 380, 'ZZTEST renewed');
  select valid_to into v_new from comp.documents where id = v_doc;
  select count(*) into v_hist from comp.renewal_log where document_id = v_doc;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S6 Renewals','Renewal updates validity and logs history', v_new = current_date + 380 and v_hist = 1,
          format('new valid_to=%s history rows=%s', v_new, v_hist));
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S6 Renewals','Renewal updates validity and logs history', false, 'Error: ' || sqlerrm);
end $t$;

-- S6.3 PROBE: renewal accepts a date in the PAST?
do $t$
declare v_doc uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('dir'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select id into v_doc from comp.documents where ref_no = 'ZZ-AG';
  begin
    perform comp.renew_document(v_doc, current_date - 100, 'ZZTEST bad renewal');
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail)
    values ('S6 Renewals','Renewal refuses a backdated validity', false, 'DEFECT: renewed BACKWARDS to ' || (current_date - 100) || ' without complaint');
  exception when others then
    execute 'reset role';
    insert into public.zztest_results (section, test, ok, detail) values ('S6 Renewals','Renewal refuses a backdated validity', true, 'Refused: ' || sqlerrm);
  end;
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S6 Renewals','Renewal refuses a backdated validity', false, 'Harness error: ' || sqlerrm);
end $t$;

-- S6.4 compliance register hidden without a comp grant
do $t$
declare c1 int;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', public.zzget('mfg'), 'role','authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into c1 from comp.documents;
  execute 'reset role';
  insert into public.zztest_results (section, test, ok, detail)
  values ('S6 Renewals','Register hidden without comp grant', c1 = 0, 'visible=' || c1);
exception when others then
  insert into public.zztest_results (section, test, ok, detail) values ('S6 Renewals','Register hidden without comp grant', false, 'Harness error: ' || sqlerrm);
end $t$;

-- ---------- S7: NUMBERING ----------
do $t$
declare v_fy text;
begin
  v_fy := app.fy_label();
  insert into public.zztest_results (section, test, ok, detail)
  values ('S7 Numbering','FY label correct for August 2026', v_fy = '26-27', 'fy=' || v_fy);
end $t$;

-- ---------- RESULTS ----------
reset role;
select seq, section, test, case when ok then 'PASS' else 'FAIL' end as result, detail
from public.zztest_results order by seq;
