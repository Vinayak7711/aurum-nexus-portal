-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 8: RM PURCHASES & INVENTORY
--  Accounts raises purchase orders on REGISTERED VENDORS and tracks them
--  (PLACED → DISPATCHED → PARTIAL → RECEIVED · CANCELLED while placed).
--  Production raises RM requests. Receipts against the PO fill the COMPANY
--  RM STORE; issues to MMC now draw down that store — never below zero.
--  Money split kept: PO rates/amounts live in po_values (Accounts + Director);
--  production sees quantities and status only.
--  Additive on Modules 1–7. Idempotent. Run once in the Supabase SQL editor.
-- ================================================================================

-- ---------- 1. VENDOR VISIBILITY: Accounts must see the vendor register ----------
drop policy if exists vendors_rw on sales.vendors;
drop policy if exists vendors_read on sales.vendors;
create policy vendors_read on sales.vendors for select
  using ( app.is_active() and (app.my_role() = 'DIRECTOR' or app.can('sales','admin') or app.can('finance','view')) );
drop policy if exists vendors_write on sales.vendors;
create policy vendors_write on sales.vendors for all
  using ( app.my_role() = 'DIRECTOR' or app.can('sales','admin') )
  with check ( app.my_role() = 'DIRECTOR' or app.can('sales','admin') );

-- ---------- 1b. RM MASTER & ISSUES VISIBLE TO ACCOUNTS ----------
-- Accounts fills PO lines from the RM master and reads the store balance,
-- which nets receipts against issues — so both need a finance read.
drop policy if exists rm_items_read on mfg.rm_items;
create policy rm_items_read on mfg.rm_items for select
  using ( app.is_active() and (app.my_role() = 'DIRECTOR' or app.can('finance','view')
          or app.can('mfg','view') or app.can('mfg','add') or app.can('mfg','edit')) );
drop policy if exists rm_issues_read on mfg.rm_issues;
create policy rm_issues_read on mfg.rm_issues for select
  using ( app.is_active() and (app.my_role() = 'DIRECTOR' or app.can('finance','view')
          or app.can('mfg','view') or app.can('mfg','add') or app.can('mfg','edit')) );

-- ---------- 2. RM REQUESTS (production indents) ----------
create table if not exists mfg.rm_requests (
  id uuid primary key default gen_random_uuid(),
  req_no text not null unique,                          -- RMR/26-27/0001
  needed_by date,
  remarks text,
  status text not null default 'REQUESTED'
    check (status in ('REQUESTED','ORDERED','FULFILLED','REJECTED')),
  po_id uuid,                                           -- linked when ordered
  created_by uuid not null references adm.users(id),
  created_at timestamptz not null default now()
);
create table if not exists mfg.rm_request_lines (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references mfg.rm_requests(id) on delete cascade,
  rm_item_id uuid not null references mfg.rm_items(id),
  qty numeric not null check (qty > 0),
  unique (request_id, rm_item_id)
);

-- ---------- 3. PURCHASE ORDERS ----------
create table if not exists mfg.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_no text not null unique,                           -- PO/26-27/0001
  vendor_id uuid not null references sales.vendors(id),
  order_date date not null default current_date,
  expected_date date,
  status text not null default 'PLACED'
    check (status in ('PLACED','DISPATCHED','PARTIAL','RECEIVED','CANCELLED')),
  remarks text,
  created_by uuid not null references adm.users(id),
  created_at timestamptz not null default now(),
  dispatched_at timestamptz,
  received_at timestamptz
);
create table if not exists mfg.po_lines (               -- quantities only
  id uuid primary key default gen_random_uuid(),
  po_id uuid not null references mfg.purchase_orders(id) on delete cascade,
  rm_item_id uuid not null references mfg.rm_items(id),
  qty numeric not null check (qty > 0),
  unique (po_id, rm_item_id)
);
create table if not exists mfg.po_values (              -- money: Accounts + Director
  line_id uuid primary key references mfg.po_lines(id) on delete cascade,
  rate_per_unit numeric not null check (rate_per_unit >= 0),
  amount numeric not null
);
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'rm_requests_po_fk') then
    alter table mfg.rm_requests add constraint rm_requests_po_fk
      foreign key (po_id) references mfg.purchase_orders(id);
  end if;
end $$;

-- ---------- 4. RM RECEIPTS (into the company store) ----------
create table if not exists mfg.rm_receipts (
  id uuid primary key default gen_random_uuid(),
  po_id uuid references mfg.purchase_orders(id),        -- null = Director opening/adjustment
  rm_item_id uuid not null references mfg.rm_items(id),
  qty numeric not null check (qty <> 0),                -- negative allowed only for Director adjustment
  received_on date not null default current_date,
  challan_no text, invoice_no text, remarks text,
  created_by uuid not null references adm.users(id),
  created_at timestamptz not null default now()
);

-- ---------- 5. STORE STOCK + GUARD ON ISSUES TO MMC ----------
-- Company store balance = received (purchases/adjustments) − issued to MMC.
drop view if exists mfg.v_rm_store;
create view mfg.v_rm_store with (security_invoker = true) as
select i.id as rm_item_id, i.code, i.name, i.unit,
       coalesce(rc.q, 0) as received,
       coalesce(iss.q, 0) as issued_to_mmc,
       coalesce(rc.q, 0) - coalesce(iss.q, 0) as store_balance
from mfg.rm_items i
left join (select rm_item_id, sum(qty) q from mfg.rm_receipts group by 1) rc  on rc.rm_item_id = i.id
left join (select rm_item_id, sum(qty) q from mfg.rm_issues  group by 1) iss on iss.rm_item_id = i.id;

-- An issue to MMC cannot exceed what the store actually holds.
create or replace function mfg.check_issue_store()
returns trigger language plpgsql security definer set search_path = mfg, public as $$
declare v_bal numeric; v_code text;
begin
  select coalesce((select sum(qty) from mfg.rm_receipts where rm_item_id = new.rm_item_id), 0)
       - coalesce((select sum(qty) from mfg.rm_issues   where rm_item_id = new.rm_item_id), 0),
         i.code
    into v_bal, v_code from mfg.rm_items i where i.id = new.rm_item_id;
  if v_bal < new.qty then
    raise exception 'Not enough % in the company store: % available, % to issue. Receive the purchase first.',
      v_code, v_bal, new.qty;
  end if;
  return new;
end $$;
drop trigger if exists trg_issue_store_guard on mfg.rm_issues;
create trigger trg_issue_store_guard
  before insert on mfg.rm_issues
  for each row execute function mfg.check_issue_store();

-- Vendor label for PO screens: name + code only (never GSTIN/bank), answered
-- only for Accounts, production (mfg grants) and the Director.
create or replace function mfg.vendor_label(p_vendor uuid)
returns text language sql stable security definer
set search_path = sales, adm, public as $$
  select case
    when (select role from adm.users where id = auth.uid()) = 'DIRECTOR'
      or (select coalesce((permissions_json->'finance'->>'view')::boolean, false)
            or coalesce((permissions_json->'mfg'->>'view')::boolean, false)
            or coalesce((permissions_json->'mfg'->>'add')::boolean, false)
            or coalesce((permissions_json->'mfg'->>'edit')::boolean, false)
          from adm.users where id = auth.uid())
    then (select v.name || ' (' || v.code || ')' from sales.vendors v where v.id = p_vendor)
    else null end
$$;
grant execute on function mfg.vendor_label(uuid) to authenticated;

-- PO tracking view (no money): ordered vs received per PO.
drop view if exists mfg.v_po_tracking;
create view mfg.v_po_tracking with (security_invoker = true) as
select po.id, po.po_no, po.status, po.order_date, po.expected_date,
       po.dispatched_at, po.received_at, po.remarks, po.vendor_id,
       mfg.vendor_label(po.vendor_id) as vendor_name,
       coalesce(o.q, 0) as ordered_qty,
       coalesce(r.q, 0) as received_qty
from mfg.purchase_orders po
left join (select po_id, sum(qty) q from mfg.po_lines group by 1) o on o.po_id = po.id
left join (select po_id, sum(qty) q from mfg.rm_receipts group by 1) r on r.po_id = po.id;

-- ---------- 6. RPCs ----------
-- Production raises an indent for material.
create or replace function mfg.create_rm_request(p_lines jsonb, p_needed date default null, p_remarks text default null)
returns uuid language plpgsql security definer set search_path = mfg, app, adm, public as $$
declare v_id uuid; v_line jsonb; v_qty numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('mfg','add')) then
    raise exception 'You do not have permission to raise material requests.';
  end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A request needs at least one material line.';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
  end loop;
  insert into mfg.rm_requests (req_no, needed_by, remarks, created_by)
  values (app.next_code('RMR'), p_needed, p_remarks, auth.uid())
  returning id into v_id;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into mfg.rm_request_lines (request_id, rm_item_id, qty)
    values (v_id, (v_line->>'rm_item_id')::uuid, (v_line->>'qty')::numeric);
  end loop;
  return v_id;
end $$;
grant execute on function mfg.create_rm_request(jsonb, date, text) to authenticated;

-- Accounts (finance edit) or Director places a PO on a registered vendor.
-- Lines: [{"rm_item_id":"...","qty":N,"rate":R}]
create or replace function mfg.create_po(p_vendor uuid, p_lines jsonb,
                                         p_expected date default null,
                                         p_request uuid default null,
                                         p_remarks text default null)
returns uuid language plpgsql security definer set search_path = mfg, sales, app, adm, public as $$
declare v_id uuid; v_line jsonb; v_lid uuid; v_qty numeric; v_rate numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may place purchase orders.';
  end if;
  if not exists (select 1 from sales.vendors where id = p_vendor and status <> 'INACTIVE') then
    raise exception 'Vendor not found or inactive — register the vendor first (Onboarding → Vendors).';
  end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A purchase order needs at least one line.';
  end if;
  if (select count(distinct x->>'rm_item_id') from jsonb_array_elements(p_lines) x) <> jsonb_array_length(p_lines) then
    raise exception 'The same material appears on two lines — combine them into one.';
  end if;
  insert into mfg.purchase_orders (po_no, vendor_id, expected_date, remarks, created_by)
  values (app.next_code('PO'), p_vendor, p_expected, p_remarks, auth.uid())
  returning id into v_id;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty  := (v_line->>'qty')::numeric;
    v_rate := (v_line->>'rate')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Every line needs a quantity above zero.'; end if;
    if v_rate is null or v_rate < 0 then raise exception 'Every line needs a rate (0 or more).'; end if;
    insert into mfg.po_lines (po_id, rm_item_id, qty)
    values (v_id, (v_line->>'rm_item_id')::uuid, v_qty)
    returning id into v_lid;
    insert into mfg.po_values (line_id, rate_per_unit, amount)
    values (v_lid, v_rate, round(v_rate * v_qty, 2));
  end loop;
  if p_request is not null then
    update mfg.rm_requests set status = 'ORDERED', po_id = v_id
     where id = p_request and status = 'REQUESTED';
  end if;
  return v_id;
end $$;
grant execute on function mfg.create_po(uuid, jsonb, date, uuid, text) to authenticated;

-- Track: mark dispatched by vendor · cancel while placed.
create or replace function mfg.po_set_status(p_po uuid, p_status text)
returns void language plpgsql security definer set search_path = mfg, app, adm, public as $$
declare v_cur text;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may update purchase orders.';
  end if;
  select status into v_cur from mfg.purchase_orders where id = p_po;
  if v_cur is null then raise exception 'Purchase order not found.'; end if;
  if p_status = 'DISPATCHED' then
    if v_cur <> 'PLACED' then raise exception 'Only a PLACED order can be marked dispatched (now %).', v_cur; end if;
    update mfg.purchase_orders set status = 'DISPATCHED', dispatched_at = now() where id = p_po;
  elsif p_status = 'CANCELLED' then
    if v_cur <> 'PLACED' then raise exception 'Only a PLACED order can be cancelled (now %).', v_cur; end if;
    if exists (select 1 from mfg.rm_receipts where po_id = p_po) then
      raise exception 'This order already has receipts — it cannot be cancelled.';
    end if;
    update mfg.purchase_orders set status = 'CANCELLED' where id = p_po;
    update mfg.rm_requests set status = 'REQUESTED', po_id = null where po_id = p_po and status = 'ORDERED';
  else
    raise exception 'Use po_receive for receipts. Supported here: DISPATCHED, CANCELLED.';
  end if;
end $$;
grant execute on function mfg.po_set_status(uuid, text) to authenticated;

-- Accounts records what physically arrived, against the PO. Over-receipt refused.
-- Lines: [{"rm_item_id":"...","qty":N}]
create or replace function mfg.po_receive(p_po uuid, p_lines jsonb,
                                          p_challan text default null,
                                          p_invoice text default null,
                                          p_date date default null)
returns void language plpgsql security definer set search_path = mfg, app, adm, public as $$
declare v_cur text; v_line jsonb; v_qty numeric; v_ordered numeric; v_recd numeric; v_code text;
        v_total_ordered numeric; v_total_recd numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may record receipts.';
  end if;
  select status into v_cur from mfg.purchase_orders where id = p_po;
  if v_cur is null then raise exception 'Purchase order not found.'; end if;
  if v_cur in ('RECEIVED','CANCELLED') then raise exception 'This order is already %.', v_cur; end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'A receipt needs at least one line.';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Every receipt line needs a quantity above zero.'; end if;
    select l.qty, coalesce((select sum(r.qty) from mfg.rm_receipts r
                             where r.po_id = p_po and r.rm_item_id = l.rm_item_id), 0), i.code
      into v_ordered, v_recd, v_code
      from mfg.po_lines l join mfg.rm_items i on i.id = l.rm_item_id
     where l.po_id = p_po and l.rm_item_id = (v_line->>'rm_item_id')::uuid;
    if v_ordered is null then raise exception 'This material is not on the purchase order.'; end if;
    if v_recd + v_qty > v_ordered then
      raise exception 'Receipt exceeds the order for %: ordered %, already received %, now %.',
        v_code, v_ordered, v_recd, v_qty;
    end if;
    insert into mfg.rm_receipts (po_id, rm_item_id, qty, received_on, challan_no, invoice_no, created_by)
    values (p_po, (v_line->>'rm_item_id')::uuid, v_qty, coalesce(p_date, current_date), p_challan, p_invoice, auth.uid());
  end loop;
  select sum(l.qty), coalesce((select sum(r.qty) from mfg.rm_receipts r where r.po_id = p_po), 0)
    into v_total_ordered, v_total_recd from mfg.po_lines l where l.po_id = p_po;
  if v_total_recd >= v_total_ordered then
    update mfg.purchase_orders set status = 'RECEIVED', received_at = now() where id = p_po;
    update mfg.rm_requests set status = 'FULFILLED' where po_id = p_po and status = 'ORDERED';
  else
    update mfg.purchase_orders set status = 'PARTIAL' where id = p_po;
  end if;
end $$;
grant execute on function mfg.po_receive(uuid, jsonb, text, text, date) to authenticated;

-- Reject a request (Director or Accounts).
create or replace function mfg.rm_request_reject(p_req uuid, p_note text default null)
returns void language plpgsql security definer set search_path = mfg, app, adm, public as $$
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','edit')) then
    raise exception 'Only Accounts (finance) or a Director may reject requests.';
  end if;
  update mfg.rm_requests set status = 'REJECTED',
         remarks = coalesce(remarks || ' · ', '') || coalesce('Rejected: ' || p_note, 'Rejected')
   where id = p_req and status = 'REQUESTED';
  if not found then raise exception 'Request not found or already decided.'; end if;
end $$;
grant execute on function mfg.rm_request_reject(uuid, text) to authenticated;

-- ---------- 7. GRANTS + RLS ----------
grant select, insert, update on mfg.rm_requests, mfg.rm_request_lines,
      mfg.purchase_orders, mfg.po_lines, mfg.rm_receipts to authenticated;
grant select, insert, update, delete on mfg.po_values to authenticated;
grant select on mfg.v_rm_store, mfg.v_po_tracking to authenticated;

alter table mfg.rm_requests      enable row level security;
alter table mfg.rm_request_lines enable row level security;
alter table mfg.purchase_orders  enable row level security;
alter table mfg.po_lines         enable row level security;
alter table mfg.po_values        enable row level security;
alter table mfg.rm_receipts      enable row level security;

-- Read: production (any mfg grant), Accounts (finance view) and Director.
do $$ declare t text;
begin
  foreach t in array array['rm_requests','rm_request_lines','purchase_orders','po_lines','rm_receipts'] loop
    execute format('drop policy if exists %I_read on mfg.%I', t, t);
    execute format($p$create policy %I_read on mfg.%I for select
      using ( app.is_active() and (app.my_role() = 'DIRECTOR'
              or app.can('finance','view')
              or app.can('mfg','view') or app.can('mfg','add') or app.can('mfg','edit')) )$p$, t, t);
  end loop;
end $$;

-- Money on POs: Accounts and Director only. Production never sees rates.
drop policy if exists po_values_read on mfg.po_values;
create policy po_values_read on mfg.po_values for select
  using ( app.is_active() and (app.my_role() = 'DIRECTOR' or app.can('finance','view')) );
drop policy if exists po_values_write on mfg.po_values;
create policy po_values_write on mfg.po_values for all
  using ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') )
  with check ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') );

-- Direct writes (the RPCs are the normal path):
drop policy if exists rm_requests_write on mfg.rm_requests;
create policy rm_requests_write on mfg.rm_requests for all
  using ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') or created_by = auth.uid() )
  with check ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') or created_by = auth.uid() );
drop policy if exists rm_request_lines_write on mfg.rm_request_lines;
create policy rm_request_lines_write on mfg.rm_request_lines for all
  using ( exists (select 1 from mfg.rm_requests r where r.id = request_id
                  and (app.my_role() = 'DIRECTOR' or app.can('finance','edit') or r.created_by = auth.uid())) )
  with check ( exists (select 1 from mfg.rm_requests r where r.id = request_id
                  and (app.my_role() = 'DIRECTOR' or app.can('finance','edit') or r.created_by = auth.uid())) );
drop policy if exists purchase_orders_write on mfg.purchase_orders;
create policy purchase_orders_write on mfg.purchase_orders for all
  using ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') )
  with check ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') );
drop policy if exists po_lines_write on mfg.po_lines;
create policy po_lines_write on mfg.po_lines for all
  using ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') )
  with check ( app.my_role() = 'DIRECTOR' or app.can('finance','edit') );
-- Receipts: via RPC for Accounts; a DIRECT insert is allowed only to the Director
-- with po_id null (opening stock / correction, qty may be negative).
drop policy if exists rm_receipts_write on mfg.rm_receipts;
create policy rm_receipts_write on mfg.rm_receipts for insert
  with check ( app.my_role() = 'DIRECTOR' and po_id is null );

-- ---------- 8. INDEXES ----------
create index if not exists idx_po_vendor      on mfg.purchase_orders (vendor_id);
create index if not exists idx_po_status      on mfg.purchase_orders (status);
create index if not exists idx_po_lines_po    on mfg.po_lines (po_id);
create index if not exists idx_rm_receipts_po on mfg.rm_receipts (po_id);
create index if not exists idx_rm_receipts_item on mfg.rm_receipts (rm_item_id);
create index if not exists idx_rmr_lines_req  on mfg.rm_request_lines (request_id);

select 'MODULE 8 RM PURCHASES & INVENTORY APPLIED' as status;
