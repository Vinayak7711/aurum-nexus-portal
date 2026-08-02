-- MODULE 8 SWEEP — remove every ZZTEST entry, restore counters, prove clean.
reset role;
do $sweep$
declare zz uuid[];
begin
  select coalesce(array_agg(id), '{}') into zz from adm.users where email like 'zztest_%@test.local';
  delete from mfg.rm_receipts where created_by = any(zz)
     or po_id in (select id from mfg.purchase_orders where created_by = any(zz));
  delete from mfg.po_values where line_id in
     (select l.id from mfg.po_lines l join mfg.purchase_orders p on p.id = l.po_id where p.created_by = any(zz));
  update mfg.rm_requests set po_id = null where created_by = any(zz);
  delete from mfg.purchase_orders where created_by = any(zz);      -- po_lines cascade
  delete from mfg.rm_request_lines where request_id in (select id from mfg.rm_requests where created_by = any(zz));
  delete from mfg.rm_requests where created_by = any(zz);
  delete from mfg.rm_issues where created_by = any(zz);
  delete from sales.vendors where name like 'ZZTEST%' or created_by = any(zz);
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
union all select 'vendors',   count(*) from sales.vendors where name like 'ZZTEST%'
union all select 'pos',       count(*) from mfg.purchase_orders
union all select 'receipts',  count(*) from mfg.rm_receipts
union all select 'requests',  count(*) from mfg.rm_requests
union all select 'rm_issues', count(*) from mfg.rm_issues where remarks like 'ZZTEST%'
union all select 'store_ena', coalesce((select store_balance::int from mfg.v_rm_store where code='ENA'), 0)
order by 1;
