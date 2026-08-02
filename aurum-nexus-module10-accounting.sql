-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 10: ACCOUNTING (BANKS · LEDGER · PAYROLL · ADVANCES)
--  Accounts + Director only. Maker-checker:
--    · Jagdish (finance edit)     → creates entries; they wait as PENDING_APPROVAL
--    · Pradeep  (finance approve)  → approves / rejects entries
--    · Director                    → creates (auto-approved), edits, deletes, approves
--  Money only moves on APPROVED entries. Additive. Idempotent. Run once.
--  NOTE: after running, add the 'acct' schema to the Data API exposed schemas.
-- ================================================================================
create schema if not exists acct;
grant usage on schema acct to anon, authenticated;

-- Small helper: may the current user act in Accounting at all?
create or replace function app.in_accounts()
returns boolean language sql stable security definer set search_path = adm, app, public as $$
  select app.my_role() = 'DIRECTOR' or app.can('finance','view')
      or app.can('finance','edit') or app.can('finance','approve')
$$;
grant execute on function app.in_accounts() to authenticated;

-- ---------- 1. BANK ACCOUNTS ----------
create table if not exists acct.bank_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,                       -- "Aurum Current A/C — HDFC Thane"
  bank_name text,
  account_tail text,                        -- last 4 digits only
  ifsc text,
  opening_balance numeric not null default 0,
  is_active boolean not null default true,
  created_by uuid references adm.users(id),
  created_at timestamptz not null default now()
);

-- ---------- 2. STAFF SALARY STRUCTURE (standing monthly figures) ----------
create table if not exists acct.staff_salary (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid not null references adm.users(id),
  effective_from date not null default current_date,
  basic numeric not null default 0,
  hra numeric not null default 0,
  allowances numeric not null default 0,     -- conveyance + special + others
  pf numeric not null default 0,
  prof_tax numeric not null default 0,
  tds numeric not null default 0,
  other_deductions numeric not null default 0,
  is_active boolean not null default true,
  created_by uuid references adm.users(id),
  created_at timestamptz not null default now(),
  unique (staff_id, effective_from)
);

-- ---------- 3. ADVANCES ----------
create table if not exists acct.advances (
  id uuid primary key default gen_random_uuid(),
  adv_no text not null unique,               -- ADV/26-27/0001
  staff_id uuid not null references adm.users(id),
  amount numeric not null check (amount > 0),
  given_on date not null default current_date,
  reason text,
  status text not null default 'PENDING_APPROVAL'
    check (status in ('PENDING_APPROVAL','APPROVED','REJECTED','CLOSED')),
  bank_account_id uuid references acct.bank_accounts(id),
  created_by uuid not null references adm.users(id),
  approved_by uuid references adm.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------- 4. SALARY SLIPS (immutable snapshots once generated) ----------
create table if not exists acct.salary_slips (
  id uuid primary key default gen_random_uuid(),
  slip_no text not null unique,              -- SAL/26-27/0001
  staff_id uuid not null references adm.users(id),
  period text not null check (period ~ '^\d{4}-\d{2}$'),
  basic numeric not null default 0,
  hra numeric not null default 0,
  allowances numeric not null default 0,
  gross numeric not null default 0,
  pf numeric not null default 0,
  prof_tax numeric not null default 0,
  tds numeric not null default 0,
  other_deductions numeric not null default 0,
  advance_recovery numeric not null default 0,
  advance_id uuid references acct.advances(id),
  total_deductions numeric not null default 0,
  net_pay numeric not null default 0,
  status text not null default 'DRAFT'
    check (status in ('DRAFT','APPROVED','PAID','CANCELLED')),
  paid_entry_id uuid,                         -- the ledger entry that paid it
  created_by uuid not null references adm.users(id),
  approved_by uuid references adm.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (staff_id, period)
);

-- ---------- 5. THE UNIVERSAL FINANCE LEDGER ----------
create table if not exists acct.entries (
  id uuid primary key default gen_random_uuid(),
  entry_no text not null unique,             -- FIN/26-27/0001
  entry_date date not null default current_date,
  kind text not null check (kind in
    ('BANK_IN','BANK_OUT','TRANSFER','PAYMENT','SALARY','ADVANCE','RECOVERY','OTHER')),
  direction text not null check (direction in ('IN','OUT')),
  bank_account_id uuid references acct.bank_accounts(id),
  counter_bank_account_id uuid references acct.bank_accounts(id),  -- TRANSFER destination
  amount numeric not null check (amount > 0),
  mode text check (mode in ('NEFT','RTGS','UPI','CHEQUE','CASH','OTHER')),
  ref_no text,
  party_id uuid references sales.parties(id),
  staff_id uuid references adm.users(id),
  payee text,                                -- free text when not a party/staff
  narration text,
  salary_slip_id uuid references acct.salary_slips(id),
  advance_id uuid references acct.advances(id),
  status text not null default 'PENDING_APPROVAL'
    check (status in ('PENDING_APPROVAL','APPROVED','REJECTED')),
  created_by uuid not null references adm.users(id),
  approved_by uuid references adm.users(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_acct_entries_bank on acct.entries (bank_account_id);
create index if not exists idx_acct_entries_status on acct.entries (status);
create index if not exists idx_acct_entries_staff on acct.entries (staff_id);

-- ---------- 6. VIEWS ----------
-- Bank balance = opening + approved money in − approved money out (transfers net).
create or replace view acct.v_bank_balances with (security_invoker = true) as
select b.id, b.name, b.bank_name, b.account_tail, b.ifsc, b.is_active, b.opening_balance,
       b.opening_balance
       + coalesce((select sum(amount) from acct.entries e
                    where e.status='APPROVED' and e.direction='IN'  and e.bank_account_id = b.id), 0)
       - coalesce((select sum(amount) from acct.entries e
                    where e.status='APPROVED' and e.direction='OUT' and e.bank_account_id = b.id), 0)
       + coalesce((select sum(amount) from acct.entries e
                    where e.status='APPROVED' and e.kind='TRANSFER' and e.counter_bank_account_id = b.id), 0)
       as balance
from acct.bank_accounts b;

-- Advance outstanding = amount − recovered (through salary slips + recovery entries).
create or replace view acct.v_advances with (security_invoker = true) as
select a.*, u.full_name as staff_name,
       coalesce((select sum(s.advance_recovery) from acct.salary_slips s
                  where s.advance_id = a.id and s.status in ('APPROVED','PAID')), 0)
     + coalesce((select sum(e.amount) from acct.entries e
                  where e.advance_id = a.id and e.kind='RECOVERY' and e.status='APPROVED'), 0)
       as recovered,
       a.amount
     - coalesce((select sum(s.advance_recovery) from acct.salary_slips s
                  where s.advance_id = a.id and s.status in ('APPROVED','PAID')), 0)
     - coalesce((select sum(e.amount) from acct.entries e
                  where e.advance_id = a.id and e.kind='RECOVERY' and e.status='APPROVED'), 0)
       as outstanding
from acct.advances a join adm.users u on u.id = a.staff_id;

-- Entries with human labels (staff / party names).
create or replace view acct.v_entries with (security_invoker = true) as
select e.*, u.full_name as staff_name, p.name as party_name,
       ba.name as bank_name_label, cba.name as counter_bank_label
from acct.entries e
left join adm.users u on u.id = e.staff_id
left join sales.parties p on p.id = e.party_id
left join acct.bank_accounts ba on ba.id = e.bank_account_id
left join acct.bank_accounts cba on cba.id = e.counter_bank_account_id;

-- ---------- 7. LEDGER RPCs ----------
create or replace function acct.create_entry(
  p_kind text, p_amount numeric, p_bank uuid,
  p_direction text default null, p_counter_bank uuid default null,
  p_date date default null, p_mode text default null, p_ref text default null,
  p_party uuid default null, p_staff uuid default null, p_payee text default null,
  p_narration text default null)
returns uuid language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_id uuid; v_dir text; v_auto boolean;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may make finance entries.';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Amount must be above zero.'; end if;
  v_dir := case p_kind
    when 'BANK_IN' then 'IN' when 'RECOVERY' then 'IN'
    when 'OTHER' then p_direction else 'OUT' end;
  if v_dir is null then raise exception 'For an OTHER entry, say whether it is money IN or OUT.'; end if;
  if p_kind = 'TRANSFER' then
    if p_counter_bank is null or p_counter_bank = p_bank then
      raise exception 'A transfer needs a different destination bank account.'; end if;
  end if;
  if p_bank is null and p_kind <> 'OTHER' then raise exception 'Choose a bank account.'; end if;
  v_auto := (app.my_role() = 'DIRECTOR' or app.can('finance','approve'));
  insert into acct.entries (entry_no, entry_date, kind, direction, bank_account_id, counter_bank_account_id,
                            amount, mode, ref_no, party_id, staff_id, payee, narration,
                            status, created_by, approved_by, approved_at)
  values (app.next_code('FIN'), coalesce(p_date, current_date), p_kind, v_dir, p_bank, p_counter_bank,
          p_amount, p_mode, p_ref, p_party, p_staff, p_payee, p_narration,
          case when v_auto then 'APPROVED' else 'PENDING_APPROVAL' end,
          auth.uid(), case when v_auto then auth.uid() end, case when v_auto then now() end)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function acct.create_entry(text,numeric,uuid,text,uuid,date,text,text,uuid,uuid,text,text) to authenticated;

create or replace function acct.approve_entry(p_entry uuid, p_reject boolean default false, p_note text default null)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_cur text;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','approve')) then
    raise exception 'Only the Accounts head (approve right) or a Director may approve entries.';
  end if;
  select status into v_cur from acct.entries where id = p_entry;
  if v_cur is null then raise exception 'Entry not found.'; end if;
  if v_cur <> 'PENDING_APPROVAL' then raise exception 'This entry is % — only a pending entry can be decided.', v_cur; end if;
  update acct.entries
     set status = case when p_reject then 'REJECTED' else 'APPROVED' end,
         approved_by = auth.uid(), approved_at = now(),
         narration = case when p_reject and p_note is not null
                          then coalesce(narration || ' · ', '') || 'Rejected: ' || p_note else narration end,
         updated_at = now()
   where id = p_entry;
end $$;
grant execute on function acct.approve_entry(uuid, boolean, text) to authenticated;

-- Director-only: edit any entry (money re-derives from the new figures).
create or replace function acct.edit_entry(
  p_entry uuid, p_amount numeric default null, p_date date default null,
  p_mode text default null, p_ref text default null, p_narration text default null)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
begin
  if app.my_role() <> 'DIRECTOR' then raise exception 'Only a Director may edit a finance entry.'; end if;
  if not exists (select 1 from acct.entries where id = p_entry) then raise exception 'Entry not found.'; end if;
  if p_amount is not null and p_amount <= 0 then raise exception 'Amount must be above zero.'; end if;
  update acct.entries set
    amount = coalesce(p_amount, amount),
    entry_date = coalesce(p_date, entry_date),
    mode = coalesce(p_mode, mode),
    ref_no = coalesce(p_ref, ref_no),
    narration = coalesce(p_narration, narration),
    updated_at = now()
  where id = p_entry;
end $$;
grant execute on function acct.edit_entry(uuid, numeric, date, text, text, text) to authenticated;

-- Director-only: delete an entry (unless it paid a salary slip — cancel the slip first).
create or replace function acct.delete_entry(p_entry uuid)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
begin
  if app.my_role() <> 'DIRECTOR' then raise exception 'Only a Director may delete a finance entry.'; end if;
  if exists (select 1 from acct.salary_slips s where s.paid_entry_id = p_entry) then
    raise exception 'This entry paid a salary slip — cancel that slip first.'; end if;
  delete from acct.entries where id = p_entry;
  if not found then raise exception 'Entry not found.'; end if;
end $$;
grant execute on function acct.delete_entry(uuid) to authenticated;

-- ---------- 8. SALARY RPCs ----------
-- Set / revise a staff member's salary structure (Director or finance edit).
create or replace function acct.set_salary_structure(
  p_staff uuid, p_basic numeric, p_hra numeric, p_allow numeric,
  p_pf numeric default 0, p_ptax numeric default 0, p_tds numeric default 0, p_other_ded numeric default 0)
returns uuid language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_id uuid;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may set salary structures.';
  end if;
  update acct.staff_salary set is_active = false where staff_id = p_staff and is_active;
  insert into acct.staff_salary (staff_id, basic, hra, allowances, pf, prof_tax, tds, other_deductions, created_by)
  values (p_staff, coalesce(p_basic,0), coalesce(p_hra,0), coalesce(p_allow,0),
          coalesce(p_pf,0), coalesce(p_ptax,0), coalesce(p_tds,0), coalesce(p_other_ded,0), auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function acct.set_salary_structure(uuid,numeric,numeric,numeric,numeric,numeric,numeric,numeric) to authenticated;

-- Generate a month's slip from the structure (finance edit) — DRAFT, immutable snapshot.
create or replace function acct.generate_salary_slip(
  p_staff uuid, p_period text, p_advance_recovery numeric default 0,
  p_advance uuid default null, p_extra_deduction numeric default 0)
returns uuid language plpgsql security definer set search_path = acct, app, adm, public as $$
declare s record; v_id uuid; v_gross numeric; v_ded numeric; v_net numeric; v_adv_out numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may generate salary slips.';
  end if;
  if p_period !~ '^\d{4}-\d{2}$' then raise exception 'Period must look like 2026-08.'; end if;
  select * into s from acct.staff_salary where staff_id = p_staff and is_active order by effective_from desc limit 1;
  if s.id is null then raise exception 'No salary structure for this staff member — set one first.'; end if;
  if p_advance_recovery < 0 then raise exception 'Advance recovery cannot be negative.'; end if;
  if p_advance is not null and p_advance_recovery > 0 then
    select outstanding into v_adv_out from acct.v_advances where id = p_advance;
    if v_adv_out is null then raise exception 'Advance not found.'; end if;
    if p_advance_recovery > v_adv_out then
      raise exception 'Recovery (%) is more than the advance outstanding (%).', p_advance_recovery, v_adv_out; end if;
  end if;
  v_gross := s.basic + s.hra + s.allowances;
  v_ded := s.pf + s.prof_tax + s.tds + s.other_deductions + coalesce(p_advance_recovery,0) + coalesce(p_extra_deduction,0);
  v_net := v_gross - v_ded;
  if v_net < 0 then raise exception 'Deductions exceed gross — net pay would be negative.'; end if;
  insert into acct.salary_slips (slip_no, staff_id, period, basic, hra, allowances, gross,
                                 pf, prof_tax, tds, other_deductions, advance_recovery, advance_id,
                                 total_deductions, net_pay, created_by)
  values (app.next_code('SAL'), p_staff, p_period, s.basic, s.hra, s.allowances, v_gross,
          s.pf, s.prof_tax, s.tds, s.other_deductions + coalesce(p_extra_deduction,0),
          coalesce(p_advance_recovery,0), p_advance, v_ded, v_net, auth.uid())
  returning id into v_id;
  return v_id;
end $$;
grant execute on function acct.generate_salary_slip(uuid,text,numeric,uuid,numeric) to authenticated;

-- Approve a slip (Director or finance approve).
create or replace function acct.approve_salary_slip(p_slip uuid, p_reject boolean default false)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_cur text;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','approve')) then
    raise exception 'Only the Accounts head (approve right) or a Director may approve salary slips.';
  end if;
  select status into v_cur from acct.salary_slips where id = p_slip;
  if v_cur is null then raise exception 'Slip not found.'; end if;
  if v_cur <> 'DRAFT' then raise exception 'This slip is % — only a draft can be decided.', v_cur; end if;
  update acct.salary_slips set status = case when p_reject then 'CANCELLED' else 'APPROVED' end,
         approved_by = auth.uid(), approved_at = now() where id = p_slip;
end $$;
grant execute on function acct.approve_salary_slip(uuid, boolean) to authenticated;

-- Pay an approved slip (Director or finance approve): books an APPROVED SALARY entry.
create or replace function acct.pay_salary_slip(p_slip uuid, p_bank uuid, p_mode text default 'NEFT', p_ref text default null)
returns uuid language plpgsql security definer set search_path = acct, app, adm, public as $$
declare s record; v_entry uuid;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','approve')) then
    raise exception 'Only the Accounts head (approve right) or a Director may pay salaries.';
  end if;
  select * into s from acct.salary_slips where id = p_slip;
  if s.id is null then raise exception 'Slip not found.'; end if;
  if s.status <> 'APPROVED' then raise exception 'Only an APPROVED slip can be paid (now %).', s.status; end if;
  if p_bank is null then raise exception 'Choose the bank account to pay from.'; end if;
  insert into acct.entries (entry_no, entry_date, kind, direction, bank_account_id, amount, mode, ref_no,
                            staff_id, narration, salary_slip_id, status, created_by, approved_by, approved_at)
  values (app.next_code('FIN'), current_date, 'SALARY', 'OUT', p_bank, s.net_pay, p_mode, p_ref,
          s.staff_id, 'Salary ' || s.period || ' (' || s.slip_no || ')', p_slip, 'APPROVED',
          auth.uid(), auth.uid(), now())
  returning id into v_entry;
  update acct.salary_slips set status = 'PAID', paid_entry_id = v_entry where id = p_slip;
  return v_entry;
end $$;
grant execute on function acct.pay_salary_slip(uuid, uuid, text, text) to authenticated;

-- Director-only: cancel/delete a slip (reverses PAID by removing its entry).
create or replace function acct.delete_salary_slip(p_slip uuid)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_entry uuid;
begin
  if app.my_role() <> 'DIRECTOR' then raise exception 'Only a Director may delete a salary slip.'; end if;
  select paid_entry_id into v_entry from acct.salary_slips where id = p_slip;
  delete from acct.salary_slips where id = p_slip;
  if not found then raise exception 'Slip not found.'; end if;
  if v_entry is not null then delete from acct.entries where id = v_entry; end if;
end $$;
grant execute on function acct.delete_salary_slip(uuid) to authenticated;

-- ---------- 9. ADVANCE RPCs ----------
create or replace function acct.create_advance(p_staff uuid, p_amount numeric, p_reason text default null, p_date date default null)
returns uuid language plpgsql security definer set search_path = acct, app, adm, public as $$
declare v_id uuid; v_auto boolean;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may record advances.';
  end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Advance amount must be above zero.'; end if;
  v_auto := (app.my_role() = 'DIRECTOR' or app.can('finance','approve'));
  insert into acct.advances (adv_no, staff_id, amount, given_on, reason, status, created_by, approved_by, approved_at)
  values (app.next_code('ADV'), p_staff, p_amount, coalesce(p_date, current_date), p_reason,
          case when v_auto then 'APPROVED' else 'PENDING_APPROVAL' end,
          auth.uid(), case when v_auto then auth.uid() end, case when v_auto then now() end)
  returning id into v_id;
  return v_id;
end $$;
grant execute on function acct.create_advance(uuid, numeric, text, date) to authenticated;

-- Approve an advance and pay it out (Director or finance approve): books an APPROVED ADVANCE entry.
create or replace function acct.approve_advance(p_adv uuid, p_bank uuid, p_reject boolean default false,
                                                p_mode text default 'NEFT', p_ref text default null)
returns void language plpgsql security definer set search_path = acct, app, adm, public as $$
declare a record;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','approve')) then
    raise exception 'Only the Accounts head (approve right) or a Director may approve advances.';
  end if;
  select * into a from acct.advances where id = p_adv;
  if a.id is null then raise exception 'Advance not found.'; end if;
  if a.status <> 'PENDING_APPROVAL' then raise exception 'This advance is % — only a pending one can be decided.', a.status; end if;
  if p_reject then
    update acct.advances set status = 'REJECTED', approved_by = auth.uid(), approved_at = now() where id = p_adv;
    return;
  end if;
  if p_bank is null then raise exception 'Choose the bank account to pay the advance from.'; end if;
  update acct.advances set status = 'APPROVED', bank_account_id = p_bank, approved_by = auth.uid(), approved_at = now() where id = p_adv;
  insert into acct.entries (entry_no, entry_date, kind, direction, bank_account_id, amount, mode, ref_no,
                            staff_id, narration, advance_id, status, created_by, approved_by, approved_at)
  values (app.next_code('FIN'), current_date, 'ADVANCE', 'OUT', p_bank, a.amount, p_mode, p_ref,
          a.staff_id, 'Advance ' || a.adv_no, p_adv, 'APPROVED', auth.uid(), auth.uid(), now());
end $$;
grant execute on function acct.approve_advance(uuid, uuid, boolean, text, text) to authenticated;

-- ---------- 10. GRANTS + RLS (accounts + director only, everywhere) ----------
grant select on acct.bank_accounts, acct.staff_salary, acct.advances, acct.salary_slips, acct.entries,
                acct.v_bank_balances, acct.v_advances, acct.v_entries to authenticated;
grant insert, update on acct.bank_accounts to authenticated;

alter table acct.bank_accounts enable row level security;
alter table acct.staff_salary  enable row level security;
alter table acct.advances      enable row level security;
alter table acct.salary_slips  enable row level security;
alter table acct.entries       enable row level security;

do $$ declare t text;
begin
  foreach t in array array['bank_accounts','staff_salary','advances','salary_slips','entries'] loop
    execute format('drop policy if exists %I_read on acct.%I', t, t);
    execute format('create policy %I_read on acct.%I for select using ( app.is_active() and app.in_accounts() )', t, t);
  end loop;
end $$;

-- Bank accounts: masters editable by Director + finance edit. Everything else via RPCs.
drop policy if exists bank_write on acct.bank_accounts;
create policy bank_write on acct.bank_accounts for all
  using ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') )
  with check ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') );

select 'MODULE 10 ACCOUNTING APPLIED' as status;
