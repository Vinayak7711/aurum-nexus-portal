-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 6: HARDENING (from the full-system ZZTEST audit)
--  Fixes the 11 defects found on 02-Aug-2026. Additive; functions reissued whole
--  (Law 3). Run once in the Supabase SQL editor.
--
--  D1  Orders could be created against a deactivated distributor
--  D2  Dispatch never checked finished-goods stock (stock went negative)
--  D3  A payment could be recorded against another distributor's order
--  D4  Accounts (finance view) saw outstanding as 0 / negative — order lines
--      were invisible to them, so billed totals never added up
--  D5  A mis-entered payment could never be corrected (no reversal path)
--  D6  SKU master accepted 0 units/case and 0 ml (breaks every calculation)
--  D7  QC reverted after PASSED left phantom cases in FG stock
--  D8  A batch could consume more raw material than was ever issued
--  D9  Duty schedules accepted impossible days (WEEKLY day 45)
--  D10 A renewal could move a licence's validity BACKWARDS
--  D11 MMC-stationed staff saw zero SKUs — batch & FG screens were blank
--  +   Supporting indexes so the busy screens stay fast as data grows
-- ================================================================================

-- ---------- D6: SKU master sanity ----------
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'skus_units_positive') then
    alter table sales.skus add constraint skus_units_positive check (units_per_case > 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'skus_size_positive') then
    alter table sales.skus add constraint skus_size_positive check (size_ml > 0);
  end if;
end $$;

-- ---------- D9: duty schedule sanity ----------
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'duties_day_of_valid') then
    alter table tasks.duties add constraint duties_day_of_valid
      check ( (freq = 'WEEKLY' and day_of between 1 and 7)
           or (freq = 'MONTHLY' and day_of between 1 and 28) );
  end if;
end $$;

-- ---------- D5: payments — reversal entries (Law 3: correct by new row, never edit) ----------
alter table sales.payments drop constraint if exists payments_amount_check;
alter table sales.payments add constraint payments_amount_check check (amount <> 0);

drop policy if exists payments_write on sales.payments;
create policy payments_write on sales.payments for insert
  with check ( (app.my_role() = 'DIRECTOR' and amount <> 0)
            or (app.can('finance','edit') and amount > 0) );
-- Accounts records money in (positive only). A wrong entry is corrected by the
-- Director with a negative reversal row — the history of the mistake stays visible.

-- ---------- D3: a payment must belong to the order's own distributor ----------
create or replace function sales.check_payment_order()
returns trigger language plpgsql security definer set search_path = sales, public as $$
begin
  if new.order_id is not null and not exists
     (select 1 from sales.orders o where o.id = new.order_id and o.party_id = new.party_id) then
    raise exception 'This order belongs to a different distributor — check the party.';
  end if;
  return new;
end $$;
drop trigger if exists trg_check_payment_order on sales.payments;
create trigger trg_check_payment_order
  before insert or update on sales.payments
  for each row execute function sales.check_payment_order();

-- ---------- D4: Accounts must see order lines (cases only — still no rates on lines) ----------
drop policy if exists lines_read on sales.order_lines;
create policy lines_read on sales.order_lines for select
  using ( app.is_active() and exists (
    select 1 from sales.orders o join sales.parties p on p.id = o.party_id
     where o.id = order_id
       and (app.my_role() = 'DIRECTOR' or app.can('finance','view') or p.owner_id = auth.uid()) ) );

-- ---------- D11: product identity (names, packs) is not money — mfg staff may read it ----------
do $$ declare t text;
begin
  foreach t in array array['categories','states','manufacturers','brands','skus'] loop
    execute format('drop policy if exists %I_read on sales.%I', t, t);
    execute format($p$create policy %I_read on sales.%I for select
      using ( app.is_active() and (app.my_role() = 'DIRECTOR'
              or app.can('sales','view')
              or app.can('mfg','view') or app.can('mfg','add') or app.can('mfg','edit')) )$p$, t, t);
  end loop;
end $$;
-- (sku_structures, rate_cards and all money tables keep their Director-only walls.)

-- ---------- D1 (+friendlier messages): create_order reissued ----------
create or replace function sales.create_order(p_party uuid, p_lines jsonb, p_remarks text default null)
returns uuid language plpgsql security definer set search_path = sales, app, adm, public as $$
declare v_uid uuid := auth.uid(); v_order uuid; v_line jsonb; v_cases numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('sales','add')) then
    raise exception 'You do not have permission to create orders.';
  end if;
  if not app.is_active() then raise exception 'Account suspended.'; end if;
  if not exists (select 1 from sales.parties where id = p_party and is_active) then
    raise exception 'This distributor is deactivated — orders cannot be placed for it.';
  end if;
  if app.my_role() <> 'DIRECTOR' and not exists
     (select 1 from sales.parties where id = p_party and owner_id = v_uid) then
    raise exception 'This party is not assigned to you.';
  end if;
  if p_lines is null or jsonb_array_length(p_lines) = 0 then
    raise exception 'Order must have at least one line.';
  end if;
  if (select count(distinct x->>'sku_id') from jsonb_array_elements(p_lines) x)
     <> jsonb_array_length(p_lines) then
    raise exception 'The same SKU appears on two lines — combine them into one.';
  end if;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    v_cases := (v_line->>'cases')::numeric;
    if v_cases is null or v_cases <= 0 then
      raise exception 'Every line needs more than zero cases.';
    end if;
  end loop;
  insert into sales.orders (so_no, party_id, remarks, created_by)
  values (app.next_code('SO'), p_party, p_remarks, v_uid)
  returning id into v_order;
  for v_line in select * from jsonb_array_elements(p_lines) loop
    insert into sales.order_lines (order_id, sku_id, cases)
    values (v_order, (v_line->>'sku_id')::uuid, (v_line->>'cases')::numeric);
  end loop;
  return v_order;
end $$;

-- ---------- D2: dispatch reissued — refuses to ship stock that does not exist ----------
create or replace function sales.dispatch_order(p_order uuid, p_invoice text)
returns void language plpgsql security definer set search_path = sales, mfg, app, adm, public as $$
declare v_state text; r record; v_stock numeric;
begin
  if app.my_role() <> 'DIRECTOR' then raise exception 'Only a Director may dispatch.'; end if;
  select p.state_id into v_state
    from sales.orders o join sales.parties p on p.id = o.party_id
   where o.id = p_order and o.status = 'APPROVED';
  if v_state is null then raise exception 'Order not found or not APPROVED.'; end if;
  for r in select l.sku_id, l.cases, s.sku_code
             from sales.order_lines l join sales.skus s on s.id = l.sku_id
            where l.order_id = p_order loop
    select coalesce(sum(case when direction = 'IN' then cases
                             when direction = 'OUT' then -cases
                             else cases end), 0)
      into v_stock from mfg.fg_movements where sku_id = r.sku_id;
    if v_stock < r.cases then
      raise exception 'Not enough finished stock for %: % in stock, % ordered. Record production (QC-passed batch) first.',
        r.sku_code, v_stock, r.cases;
    end if;
  end loop;
  update sales.orders set status = 'DISPATCHED', invoice_no = p_invoice, dispatched_at = now()
   where id = p_order;
  insert into sales.cm_payables (order_id, manufacturer_id, cases, cm_charge_per_case, amount)
  select p_order, s.manufacturer_id, l.cases,
         st.mc_per_bottle * s.units_per_case,
         round(st.mc_per_bottle * s.units_per_case * l.cases, 2)
    from sales.order_lines l
    join sales.skus s on s.id = l.sku_id
    join lateral (
      select mc_per_bottle from sales.sku_structures
       where sku_id = s.id and state_id = v_state and effective_from <= current_date
       order by effective_from desc limit 1
    ) st on true
   where l.order_id = p_order and s.manufacturer_id is not null;
  insert into mfg.fg_movements (sku_id, direction, cases, order_id, reason, created_by)
  select l.sku_id, 'OUT', l.cases, p_order, 'Dispatched against order', auth.uid()
    from sales.order_lines l where l.order_id = p_order;
end $$;

-- ---------- D7: QC reissued — reverting a PASSED batch pulls its cases back out ----------
create or replace function mfg.qc_set(p_batch uuid, p_status text, p_remarks text default null)
returns void language plpgsql security definer set search_path = mfg, sales, app, adm, public as $$
declare b record; v_net numeric;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('mfg','edit')) then
    raise exception 'You do not have QC permission.';
  end if;
  if p_status not in ('PASSED','FAILED','HOLD','PENDING') then raise exception 'Bad status %', p_status; end if;
  select * into b from mfg.batches where id = p_batch;
  if b.id is null then raise exception 'Batch not found.'; end if;
  select coalesce(sum(case when direction = 'IN' then cases
                           when direction = 'OUT' then -cases
                           else cases end), 0)
    into v_net from mfg.fg_movements where batch_id = p_batch;
  update mfg.batches set qc_status = p_status, qc_remarks = p_remarks, qc_by = auth.uid(), qc_at = now()
   where id = p_batch;
  if p_status = 'PASSED' and v_net <= 0 then
    insert into mfg.fg_movements (sku_id, direction, cases, batch_id, reason, created_by)
    values (b.sku_id, 'IN', b.cases, p_batch, 'QC passed — into FG stock', auth.uid());
  elsif b.qc_status = 'PASSED' and p_status <> 'PASSED' and v_net > 0 then
    insert into mfg.fg_movements (sku_id, direction, cases, batch_id, reason, created_by)
    values (b.sku_id, 'ADJ', -v_net, p_batch, 'QC reverted to ' || p_status || ' — stock withdrawn', auth.uid());
  end if;
end $$;

-- ---------- D8: batches reissued — cannot consume RM that was never issued ----------
create or replace function mfg.create_batch(p_sku uuid, p_cases numeric, p_date date, p_rm jsonb default '[]'::jsonb)
returns uuid language plpgsql security definer set search_path = mfg, sales, app, adm, public as $$
declare v_id uuid; v_line jsonb; v_bal numeric; v_qty numeric; v_code text;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('mfg','add')) then
    raise exception 'You do not have permission to record batches.';
  end if;
  for v_line in select * from jsonb_array_elements(p_rm) loop
    v_qty := (v_line->>'qty')::numeric;
    if v_qty is null or v_qty <= 0 then raise exception 'Every RM line needs a quantity above zero.'; end if;
    select coalesce((select sum(qty) from mfg.rm_issues where rm_item_id = (v_line->>'rm_item_id')::uuid), 0)
         - coalesce((select sum(qty) from mfg.batch_rm  where rm_item_id = (v_line->>'rm_item_id')::uuid), 0),
           i.code
      into v_bal, v_code
      from mfg.rm_items i where i.id = (v_line->>'rm_item_id')::uuid;
    if v_bal is null then raise exception 'Raw-material item not found.'; end if;
    if v_bal < v_qty then
      raise exception 'Not enough % in custody at MMC: % available, % needed. Record the RM issue first.',
        v_code, v_bal, v_qty;
    end if;
  end loop;
  insert into mfg.batches (batch_no, sku_id, cases, production_date, created_by)
  values (app.next_code('BAT'), p_sku, p_cases, coalesce(p_date, current_date), auth.uid())
  returning id into v_id;
  for v_line in select * from jsonb_array_elements(p_rm) loop
    insert into mfg.batch_rm (batch_id, rm_item_id, qty)
    values (v_id, (v_line->>'rm_item_id')::uuid, (v_line->>'qty')::numeric);
  end loop;
  return v_id;
end $$;

-- ---------- D10: renewals reissued — validity can only move FORWARD ----------
create or replace function comp.renew_document(p_doc uuid, p_new_valid_to date, p_note text default null)
returns void language plpgsql security definer set search_path = comp, app, adm, public as $$
declare v_old date;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('comp','admin')) then
    raise exception 'You do not have permission to renew documents.';
  end if;
  select valid_to into v_old from comp.documents where id = p_doc;
  if v_old is null then raise exception 'Document not found.'; end if;
  if p_new_valid_to <= v_old then
    raise exception 'New validity (%) must be after the current expiry (%). A renewal moves forward.',
      p_new_valid_to, v_old;
  end if;
  insert into comp.renewal_log (document_id, old_valid_to, new_valid_to, note, created_by)
  values (p_doc, v_old, p_new_valid_to, p_note, auth.uid());
  update comp.documents set valid_to = p_new_valid_to where id = p_doc;
end $$;

-- ---------- Supporting indexes (keep the busy screens fast as data grows) ----------
create index if not exists idx_payments_party    on sales.payments (party_id);
create index if not exists idx_payments_order    on sales.payments (order_id);
create index if not exists idx_orders_party      on sales.orders (party_id);
create index if not exists idx_fg_mov_sku        on mfg.fg_movements (sku_id);
create index if not exists idx_fg_mov_batch      on mfg.fg_movements (batch_id);
create index if not exists idx_fg_mov_order      on mfg.fg_movements (order_id);
create index if not exists idx_batch_rm_item     on mfg.batch_rm (rm_item_id);
create index if not exists idx_batch_rm_batch    on mfg.batch_rm (batch_id);
create index if not exists idx_rm_issues_item    on mfg.rm_issues (rm_item_id);
create index if not exists idx_rate_cards_lookup on sales.rate_cards (sku_id, state_id, effective_from);
create index if not exists idx_tasks_assignee    on tasks.tasks (assignee_id);
create index if not exists idx_comp_valid_to     on comp.documents (valid_to);

-- done
select 'MODULE 6 HARDENING APPLIED' as status;
