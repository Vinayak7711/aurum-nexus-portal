-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 7: SALES ACTIVITY REPORTS & TARGETS
--  Daily activity reports + monthly reports by the sales team, linked to
--  monthly and quarterly targets IN CASES (no money visible to the team).
--  Team leaders (reports_to) review their team; Director sees everything.
--  Additive on Modules 1–6. Idempotent. Run once in the Supabase SQL editor.
-- ================================================================================

-- ---------- 1. TEAM STRUCTURE: who reports to whom ----------
alter table adm.users add column if not exists reports_to uuid references adm.users(id);
-- Set in Control Panel: each salesman's "Reports to" = his team leader (Kunal).

-- ---------- 2. DAILY ACTIVITY REPORTS ----------
create table if not exists sales.activity_reports (
  id uuid primary key default gen_random_uuid(),
  user_id     uuid not null references adm.users(id),
  report_date date not null default current_date,
  outlets_visited  int not null default 0 check (outlets_visited  >= 0),
  productive_calls int not null default 0 check (productive_calls >= 0),
  new_leads        int not null default 0 check (new_leads        >= 0),
  payment_followups int not null default 0 check (payment_followups >= 0),
  market_feedback text,
  remarks         text,
  reviewed_by uuid references adm.users(id),
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (user_id, report_date)
);

-- ---------- 3. MONTHLY REPORTS ----------
create table if not exists sales.monthly_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references adm.users(id),
  period  text not null check (period ~ '^\d{4}-\d{2}$'),      -- '2026-08'
  summary text not null,
  challenges text,
  next_month_plan text,
  reviewed_by uuid references adm.users(id),
  reviewed_at timestamptz,
  submitted_at timestamptz not null default now(),
  unique (user_id, period)
);

-- ---------- 4. TARGETS (cases; monthly + quarterly) ----------
create table if not exists sales.targets (
  id uuid primary key default gen_random_uuid(),
  user_id      uuid not null references adm.users(id),
  period_type  text not null check (period_type in ('MONTH','QUARTER')),
  period       text not null,     -- MONTH: '2026-08' · QUARTER: '26-27-Q2' (FY Apr–Mar)
  target_cases numeric not null check (target_cases > 0),
  set_by       uuid references adm.users(id),
  created_at   timestamptz not null default now(),
  unique (user_id, period_type, period),
  check ( (period_type = 'MONTH'   and period ~ '^\d{4}-\d{2}$')
       or (period_type = 'QUARTER' and period ~ '^\d{2}-\d{2}-Q[1-4]$') )
);

-- ---------- 5. PERIOD HELPERS ----------
create or replace function app.month_label(p_date date default current_date)
returns text language sql immutable as $$ select to_char(p_date, 'YYYY-MM') $$;

-- Indian FY quarters: Q1 Apr–Jun · Q2 Jul–Sep · Q3 Oct–Dec · Q4 Jan–Mar
create or replace function app.quarter_label(p_date date default current_date)
returns text language sql immutable as $$
  select app.fy_label(p_date) || '-Q' ||
         (case when extract(month from p_date) >= 4
               then ((extract(month from p_date)::int - 4) / 3) + 1
               else ((extract(month from p_date)::int + 8) / 3) + 1 end)
$$;

-- Date range [start, end) for a stored target period
create or replace function app.period_range(p_type text, p_period text)
returns table (d_from date, d_to date) language plpgsql immutable as $$
declare y int; q int;
begin
  if p_type = 'MONTH' then
    d_from := to_date(p_period || '-01', 'YYYY-MM-DD');
    d_to   := (d_from + interval '1 month')::date;
  else
    y := 2000 + split_part(p_period, '-', 1)::int;          -- '26-27-Q2' → 2026
    q := right(p_period, 1)::int;
    d_from := make_date(y, 4, 1) + make_interval(months => (q-1)*3);
    d_to   := (d_from + interval '3 months')::date;
  end if;
  return next;
end $$;
grant execute on function app.month_label(date), app.quarter_label(date), app.period_range(text, text) to authenticated;

-- ---------- 6. ACHIEVEMENT COUNTER + VIEWS ----------
-- Cases achieved = cases on live orders (not cancelled) of parties OWNED by the
-- salesperson, counted by order date. The order book is the truth — a salesman
-- cannot inflate his achievement from the report form.
-- Security definer (cases only, never money) so a team LEADER can see his
-- team's achievement even though he cannot see their parties or orders.
-- Guarded: answers only for yourself, your direct reports, or a Director.
create or replace function sales.cases_for(p_user uuid, p_from date, p_to date)
returns numeric language sql stable security definer
set search_path = sales, adm, public as $$
  select case
    when auth.uid() = p_user
      or (select role from adm.users where id = auth.uid()) = 'DIRECTOR'
      or exists (select 1 from adm.users u where u.id = p_user and u.reports_to = auth.uid())
    then coalesce((
      select sum(l.cases)
        from sales.orders o
        join sales.parties p on p.id = o.party_id
        join sales.order_lines l on l.order_id = o.id
       where p.owner_id = p_user
         and o.status <> 'CANCELLED'
         and o.order_date >= p_from and o.order_date < p_to), 0)
    else null end
$$;
grant execute on function sales.cases_for(uuid, date, date) to authenticated;

create or replace view sales.v_target_progress with (security_invoker = true) as
select t.id, t.user_id, u.full_name, t.period_type, t.period, t.target_cases,
       coalesce(sales.cases_for(t.user_id, r.d_from, r.d_to), 0) as achieved_cases,
       round(coalesce(sales.cases_for(t.user_id, r.d_from, r.d_to), 0) * 100.0 / t.target_cases, 1) as pct,
       r.d_from, r.d_to
from sales.targets t
join adm.users u on u.id = t.user_id
cross join lateral app.period_range(t.period_type, t.period) r;

-- Daily reports with auto-counted cases booked that day (from the order book)
create or replace view sales.v_activity_reports with (security_invoker = true) as
select ar.*, u.full_name,
       coalesce(sales.cases_for(ar.user_id, ar.report_date, (ar.report_date + 1)), 0) as cases_booked
from sales.activity_reports ar
join adm.users u on u.id = ar.user_id;

-- ---------- 7. RPCs ----------
-- Salesman submits (or corrects, until reviewed) his day's report.
create or replace function sales.submit_daily_report(
  p_date date, p_outlets int, p_calls int, p_leads int, p_followups int,
  p_feedback text default null, p_remarks text default null)
returns uuid language plpgsql security definer set search_path = sales, app, adm, public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('sales','view')) then
    raise exception 'You do not have permission to file sales reports.';
  end if;
  if not app.is_active() then raise exception 'Account suspended.'; end if;
  if p_date > current_date then raise exception 'A report cannot be filed for a future date.'; end if;
  if p_date < current_date - 7 then raise exception 'Reports older than 7 days need the Director — ask to have it entered.'; end if;
  insert into sales.activity_reports
    (user_id, report_date, outlets_visited, productive_calls, new_leads, payment_followups, market_feedback, remarks)
  values (v_uid, p_date, coalesce(p_outlets,0), coalesce(p_calls,0), coalesce(p_leads,0), coalesce(p_followups,0), p_feedback, p_remarks)
  on conflict (user_id, report_date) do update
     set outlets_visited = excluded.outlets_visited,
         productive_calls = excluded.productive_calls,
         new_leads = excluded.new_leads,
         payment_followups = excluded.payment_followups,
         market_feedback = excluded.market_feedback,
         remarks = excluded.remarks,
         updated_at = now()
   where sales.activity_reports.reviewed_by is null
  returning id into v_id;
  if v_id is null then
    raise exception 'This report was already reviewed by your leader and is locked.';
  end if;
  return v_id;
end $$;
grant execute on function sales.submit_daily_report(date, int, int, int, int, text, text) to authenticated;

-- Salesman submits (or corrects, until reviewed) his month's report.
create or replace function sales.submit_monthly_report(
  p_period text, p_summary text, p_challenges text default null, p_plan text default null)
returns uuid language plpgsql security definer set search_path = sales, app, adm, public as $$
declare v_uid uuid := auth.uid(); v_id uuid;
begin
  if not (app.my_role() = 'DIRECTOR' or app.can('sales','view')) then
    raise exception 'You do not have permission to file sales reports.';
  end if;
  if p_period !~ '^\d{4}-\d{2}$' then raise exception 'Period must look like 2026-08.'; end if;
  if p_period > app.month_label() then raise exception 'A report cannot be filed for a future month.'; end if;
  if coalesce(trim(p_summary), '') = '' then raise exception 'The monthly summary cannot be empty.'; end if;
  insert into sales.monthly_reports (user_id, period, summary, challenges, next_month_plan)
  values (v_uid, p_period, p_summary, p_challenges, p_plan)
  on conflict (user_id, period) do update
     set summary = excluded.summary, challenges = excluded.challenges,
         next_month_plan = excluded.next_month_plan, submitted_at = now()
   where sales.monthly_reports.reviewed_by is null
  returning id into v_id;
  if v_id is null then
    raise exception 'This report was already reviewed by your leader and is locked.';
  end if;
  return v_id;
end $$;
grant execute on function sales.submit_monthly_report(text, text, text, text) to authenticated;

-- Leader / Director marks a report reviewed (locks it).
create or replace function sales.review_report(p_kind text, p_id uuid)
returns void language plpgsql security definer set search_path = sales, app, adm, public as $$
declare v_owner uuid;
begin
  if p_kind = 'DAILY' then
    select user_id into v_owner from sales.activity_reports where id = p_id;
  elsif p_kind = 'MONTHLY' then
    select user_id into v_owner from sales.monthly_reports where id = p_id;
  else
    raise exception 'Kind must be DAILY or MONTHLY.';
  end if;
  if v_owner is null then raise exception 'Report not found.'; end if;
  if not (app.my_role() = 'DIRECTOR'
          or exists (select 1 from adm.users u where u.id = v_owner and u.reports_to = auth.uid())) then
    raise exception 'Only the team leader or a Director may review this report.';
  end if;
  if p_kind = 'DAILY' then
    update sales.activity_reports set reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  else
    update sales.monthly_reports set reviewed_by = auth.uid(), reviewed_at = now() where id = p_id;
  end if;
end $$;
grant execute on function sales.review_report(text, uuid) to authenticated;

-- Director sets / revises a target (a revision overwrites the same period row).
create or replace function sales.set_target(p_user uuid, p_type text, p_period text, p_cases numeric)
returns uuid language plpgsql security definer set search_path = sales, app, adm, public as $$
declare v_id uuid;
begin
  if app.my_role() <> 'DIRECTOR' then raise exception 'Only a Director may set targets.'; end if;
  if p_cases is null or p_cases <= 0 then raise exception 'Target must be above zero cases.'; end if;
  insert into sales.targets (user_id, period_type, period, target_cases, set_by)
  values (p_user, p_type, p_period, p_cases, auth.uid())
  on conflict (user_id, period_type, period) do update
     set target_cases = excluded.target_cases, set_by = excluded.set_by, created_at = now()
  returning id into v_id;
  return v_id;
end $$;
grant execute on function sales.set_target(uuid, text, text, numeric) to authenticated;

-- ---------- 8. GRANTS + RLS ----------
grant select, insert, update on sales.activity_reports, sales.monthly_reports, sales.targets to authenticated;
grant select on sales.v_target_progress, sales.v_activity_reports to authenticated;

alter table sales.activity_reports enable row level security;
alter table sales.monthly_reports  enable row level security;
alter table sales.targets          enable row level security;

-- Read: own rows · your direct team's rows (reports_to = you) · Director all.
drop policy if exists ar_read on sales.activity_reports;
create policy ar_read on sales.activity_reports for select
  using ( app.is_active() and ( user_id = auth.uid() or app.my_role() = 'DIRECTOR'
          or exists (select 1 from adm.users u where u.id = user_id and u.reports_to = auth.uid()) ) );
drop policy if exists mr_read on sales.monthly_reports;
create policy mr_read on sales.monthly_reports for select
  using ( app.is_active() and ( user_id = auth.uid() or app.my_role() = 'DIRECTOR'
          or exists (select 1 from adm.users u where u.id = user_id and u.reports_to = auth.uid()) ) );
drop policy if exists tg_read on sales.targets;
create policy tg_read on sales.targets for select
  using ( app.is_active() and ( user_id = auth.uid() or app.my_role() = 'DIRECTOR'
          or exists (select 1 from adm.users u where u.id = user_id and u.reports_to = auth.uid()) ) );

-- Writes flow through the RPCs (security definer). Direct writes: own unreviewed
-- rows only; targets Director-only.
drop policy if exists ar_write on sales.activity_reports;
create policy ar_write on sales.activity_reports for all
  using ( user_id = auth.uid() and reviewed_by is null )
  with check ( user_id = auth.uid() );
drop policy if exists mr_write on sales.monthly_reports;
create policy mr_write on sales.monthly_reports for all
  using ( user_id = auth.uid() and reviewed_by is null )
  with check ( user_id = auth.uid() );
drop policy if exists tg_write on sales.targets;
create policy tg_write on sales.targets for all
  using ( app.my_role() = 'DIRECTOR' ) with check ( app.my_role() = 'DIRECTOR' );

-- ---------- 9. INDEXES ----------
create index if not exists idx_ar_user_date   on sales.activity_reports (user_id, report_date desc);
create index if not exists idx_mr_user_period on sales.monthly_reports (user_id, period);
create index if not exists idx_tg_user        on sales.targets (user_id, period_type, period);
create index if not exists idx_users_reports_to on adm.users (reports_to);

select 'MODULE 7 SALES REPORTS & TARGETS APPLIED' as status;
