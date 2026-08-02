-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 8b: PO APPROVAL GATE
--  Jagdish (finance edit) INITIATES a purchase order → it waits as
--  PENDING_APPROVAL. Pradeep (finance approve) or the Director APPROVES it
--  → PLACED → the normal dispatch/receive flow. Nothing can be received
--  against an unapproved PO. Functions reissued whole (Law 3).
-- ================================================================================

-- ---------- 1. STATUS + APPROVAL STAMPS ----------
alter table mfg.purchase_orders add column if not exists approved_by uuid references adm.users(id);
alter table mfg.purchase_orders add column if not exists approved_at timestamptz;
alter table mfg.purchase_orders drop constraint if exists purchase_orders_status_check;
alter table mfg.purchase_orders add constraint purchase_orders_status_check
  check (status in ('PENDING_APPROVAL','PLACED','DISPATCHED','PARTIAL','RECEIVED','CANCELLED'));
alter table mfg.purchase_orders alter column status set default 'PENDING_APPROVAL';

-- ---------- 2. create_po reissued: starts PENDING unless the creator can approve ----------
create or replace function mfg.create_po(p_vendor uuid, p_lines jsonb,
                                         p_expected date default null,
                                         p_request uuid default null,
                                         p_remarks text default null)
returns uuid language plpgsql security definer set search_path = mfg, sales, app, adm, public as $$
declare v_id uuid; v_line jsonb; v_lid uuid; v_qty numeric; v_rate numeric; v_auto boolean;
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
  v_auto := (app.my_role() = 'DIRECTOR' or app.can('finance','approve'));
  insert into mfg.purchase_orders (po_no, vendor_id, expected_date, remarks, created_by,
                                   status, approved_by, approved_at)
  values (app.next_code('PO'), p_vendor, p_expected, p_remarks, auth.uid(),
          case when v_auto then 'PLACED' else 'PENDING_APPROVAL' end,
          case when v_auto then auth.uid() end,
          case when v_auto then now() end)
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

-- ---------- 3. THE APPROVAL ----------
create or replace function mfg.po_approve(p_po uuid)
returns void language plpgsql security definer set search_path = mfg, app, adm, public as $$
declare v_cur text;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('finance','approve')) then
    raise exception 'Only the Accounts head (approve right) or a Director may approve purchase orders.';
  end if;
  select status into v_cur from mfg.purchase_orders where id = p_po;
  if v_cur is null then raise exception 'Purchase order not found.'; end if;
  if v_cur <> 'PENDING_APPROVAL' then raise exception 'This order is % — only a pending order can be approved.', v_cur; end if;
  update mfg.purchase_orders
     set status = 'PLACED', approved_by = auth.uid(), approved_at = now()
   where id = p_po;
end $$;
grant execute on function mfg.po_approve(uuid) to authenticated;

-- ---------- 4. TRANSITIONS reissued: cancel covers pending too ----------
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
    if v_cur <> 'PLACED' then raise exception 'Only an APPROVED (placed) order can be marked dispatched (now %).', v_cur; end if;
    update mfg.purchase_orders set status = 'DISPATCHED', dispatched_at = now() where id = p_po;
  elsif p_status = 'CANCELLED' then
    if v_cur not in ('PENDING_APPROVAL','PLACED') then raise exception 'Only a pending or placed order can be cancelled (now %).', v_cur; end if;
    if exists (select 1 from mfg.rm_receipts where po_id = p_po) then
      raise exception 'This order already has receipts — it cannot be cancelled.';
    end if;
    update mfg.purchase_orders set status = 'CANCELLED' where id = p_po;
    update mfg.rm_requests set status = 'REQUESTED', po_id = null where po_id = p_po and status = 'ORDERED';
  else
    raise exception 'Use po_approve for approval and po_receive for receipts. Supported here: DISPATCHED, CANCELLED.';
  end if;
end $$;

-- ---------- 5. RECEIVING reissued: an unapproved order cannot be received ----------
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
  if v_cur = 'PENDING_APPROVAL' then raise exception 'This order is not approved yet — it must be approved before anything is received.'; end if;
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

-- ---------- 6. TRACKING VIEW reissued with approval stamp ----------
drop view if exists mfg.v_po_tracking;
create view mfg.v_po_tracking with (security_invoker = true) as
select po.id, po.po_no, po.status, po.order_date, po.expected_date,
       po.dispatched_at, po.received_at, po.approved_at, po.remarks, po.vendor_id,
       mfg.vendor_label(po.vendor_id) as vendor_name,
       coalesce(o.q, 0) as ordered_qty,
       coalesce(r.q, 0) as received_qty
from mfg.purchase_orders po
left join (select po_id, sum(qty) q from mfg.po_lines group by 1) o on o.po_id = po.id
left join (select po_id, sum(qty) q from mfg.rm_receipts group by 1) r on r.po_id = po.id;
grant select on mfg.v_po_tracking to authenticated;

select 'MODULE 8b PO APPROVAL GATE APPLIED' as status;
