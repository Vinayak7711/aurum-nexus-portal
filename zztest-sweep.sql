-- ================================================================================
--  AURUM NEXUS — ZZTEST SWEEP (Law 9)
--  Removes every test entry the audit created, in reverse dependency order,
--  restores the document counters exactly, and proves the system is clean.
-- ================================================================================
reset role;

-- safety: ensure no ZZTEST row still carries the superadmin flag
alter table adm.users disable trigger trg_protect_superadmin;
update adm.users set is_superadmin = false where email like 'zztest_%@test.local';
alter table adm.users enable trigger trg_protect_superadmin;

do $sweep$
declare zz uuid[];
begin
  select coalesce(array_agg(id), '{}') into zz from adm.users where email like 'zztest_%@test.local';

  delete from sales.cm_payables  where order_id in (select id from sales.orders where created_by = any(zz));
  delete from sales.payments     where created_by = any(zz)
                                    or party_id in (select id from sales.parties where name like 'ZZTEST%');
  delete from sales.order_values where line_id in (select l.id from sales.order_lines l
                                                    join sales.orders o on o.id = l.order_id
                                                   where o.created_by = any(zz));
  delete from mfg.fg_movements   where created_by = any(zz)
                                    or order_id in (select id from sales.orders where created_by = any(zz))
                                    or batch_id in (select id from mfg.batches where created_by = any(zz));
  delete from mfg.batch_rm       where batch_id in (select id from mfg.batches where created_by = any(zz));
  delete from mfg.batches        where created_by = any(zz);
  delete from mfg.rm_issues      where created_by = any(zz);
  delete from tasks.duty_log     where duty_id in (select id from tasks.duties where created_by = any(zz));
  delete from tasks.duties       where created_by = any(zz);
  delete from tasks.task_updates where task_id in (select id from tasks.tasks where created_by = any(zz));
  delete from tasks.tasks        where created_by = any(zz);
  delete from comp.renewal_log   where document_id in (select id from comp.documents where created_by = any(zz));
  delete from comp.documents     where created_by = any(zz);
  delete from sales.onboarding   where created_by = any(zz);
  delete from sales.vendors      where created_by = any(zz) or name like 'ZZTEST%';
  delete from sales.orders       where created_by = any(zz);          -- lines cascade
  delete from sales.rate_cards   where party_id in (select id from sales.parties where name like 'ZZTEST%');
  delete from sales.skus         where sku_code like 'ZZTEST%';
  delete from sales.brands       where name like 'ZZTEST%';
  delete from sales.parties      where name like 'ZZTEST%' or created_by = any(zz) or owner_id = any(zz);
end $sweep$;

-- personas out (adm.users rows cascade from auth.users)
delete from auth.users where email like 'zztest_%@test.local';

-- restore document counters exactly as they were before the audit
do $ctr$
begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='zztest_counters_before') then
    delete from app.doc_counters;
    insert into app.doc_counters select * from public.zztest_counters_before;
  end if;
end $ctr$;

-- drop the audit scaffolding
drop table if exists public.zztest_vars;
drop table if exists public.zztest_counters_before;
drop function if exists public.zzset(text, text);
drop function if exists public.zzget(text);

-- ---------- PROOF OF CLEANLINESS ----------
select 'adm.users'        as place, count(*) as zz_left from adm.users        where email like 'zztest_%@test.local'
union all select 'auth.users',      count(*) from auth.users      where email like 'zztest_%@test.local'
union all select 'parties',         count(*) from sales.parties   where name like 'ZZTEST%'
union all select 'orders',          count(*) from sales.orders    where remarks like 'ZZTEST%'
union all select 'payments',        count(*) from sales.payments  where remarks like 'ZZTEST%'
union all select 'brands+skus',     (select count(*) from sales.brands where name like 'ZZTEST%') + (select count(*) from sales.skus where sku_code like 'ZZTEST%')
union all select 'batches',         count(*) from mfg.batches     where qc_remarks like 'ZZTEST%'
union all select 'rm_issues',       count(*) from mfg.rm_issues   where remarks like 'ZZTEST%'
union all select 'fg_movements',    count(*) from mfg.fg_movements where reason like 'ZZTEST%'
union all select 'onboarding',      count(*) from sales.onboarding where applicant_name like 'ZZTEST%'
union all select 'vendors',         count(*) from sales.vendors   where name like 'ZZTEST%'
union all select 'tasks+duties',    (select count(*) from tasks.tasks where title like 'ZZTEST%') + (select count(*) from tasks.duties where title like 'ZZTEST%')
union all select 'comp.documents',  count(*) from comp.documents  where title like 'ZZTEST%'
union all select 'counters(SO fy)', coalesce((select last_no from app.doc_counters where series='SO' and fy=app.fy_label()), 0)
order by 1;
