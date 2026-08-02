-- MODULE 7 SWEEP — remove every ZZTEST entry, restore counters, prove clean.
reset role;
do $sweep$
declare zz uuid[];
begin
  select coalesce(array_agg(id), '{}') into zz from adm.users where email like 'zztest_%@test.local';
  delete from sales.activity_reports where user_id = any(zz);
  delete from sales.monthly_reports  where user_id = any(zz);
  delete from sales.targets          where user_id = any(zz) or set_by = any(zz);
  delete from sales.order_values     where line_id in (select l.id from sales.order_lines l join sales.orders o on o.id = l.order_id where o.created_by = any(zz));
  delete from sales.cm_payables      where order_id in (select id from sales.orders where created_by = any(zz));
  delete from mfg.fg_movements       where order_id in (select id from sales.orders where created_by = any(zz)) or created_by = any(zz);
  delete from sales.orders           where created_by = any(zz);
  delete from sales.parties          where name like 'ZZTEST%' or created_by = any(zz) or owner_id = any(zz);
end $sweep$;
delete from auth.users where email like 'zztest_%@test.local';
do $ctr$ begin
  if exists (select 1 from information_schema.tables where table_schema='public' and table_name='zztest_counters_before') then
    delete from app.doc_counters;
    insert into app.doc_counters select * from public.zztest_counters_before;
  end if;
end $ctr$;
drop table if exists public.zztest_counters_before;
drop table if exists public.zztest_results;

select 'users' as place, count(*) as zz_left from adm.users where email like 'zztest_%@test.local'
union all select 'activity_reports', count(*) from sales.activity_reports ar where not exists (select 1 from adm.users u where u.id = ar.user_id)
union all select 'reports', (select count(*) from sales.activity_reports) + (select count(*) from sales.monthly_reports)
union all select 'targets', count(*) from sales.targets
union all select 'parties', count(*) from sales.parties where name like 'ZZTEST%'
union all select 'orders', count(*) from sales.orders where remarks like 'ZZTEST%'
order by 1;
