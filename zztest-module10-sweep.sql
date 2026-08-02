-- MODULE 10 SWEEP — remove every ZZTEST accounting entry, restore counters, prove clean.
reset role;
do $sweep$
declare zz uuid[];
begin
  select coalesce(array_agg(id), '{}') into zz from adm.users where email like 'zztest_%@test.local';
  delete from acct.entries       where created_by = any(zz);
  delete from acct.salary_slips  where created_by = any(zz);
  delete from acct.advances      where created_by = any(zz);
  delete from acct.staff_salary  where created_by = any(zz);
  delete from acct.bank_accounts where created_by = any(zz) or name like 'ZZTEST%';
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
drop table if exists public.zztest_vars;

select 'users' as place, count(*) as zz_left from adm.users where email like 'zztest_%@test.local'
union all select 'bank_accounts', count(*) from acct.bank_accounts
union all select 'entries', count(*) from acct.entries
union all select 'salary_slips', count(*) from acct.salary_slips
union all select 'advances', count(*) from acct.advances
union all select 'staff_salary', count(*) from acct.staff_salary
order by 1;
