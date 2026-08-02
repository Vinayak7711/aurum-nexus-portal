-- MODULE 9 VERIFICATION — department mail walls (ZZTEST personas)
drop table if exists public.zztest_results;
create table public.zztest_results (seq serial primary key, test text, ok boolean, detail text);
grant select, insert on public.zztest_results to authenticated;
grant usage, select on sequence public.zztest_results_seq_seq to authenticated;

insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
values
 ('00000000-0000-0000-0000-000000000000','eeee0000-0000-4000-8000-000000000d01','authenticated','authenticated','zztest_dir9@test.local','',now(),'{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','eeee0000-0000-4000-8000-000000000a01','authenticated','authenticated','zztest_adm9@test.local','',now(),'{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','eeee0000-0000-4000-8000-00000000ac01','authenticated','authenticated','zztest_acc9@test.local','',now(),'{}','{}',now(),now()),
 ('00000000-0000-0000-0000-000000000000','eeee0000-0000-4000-8000-00000000f601','authenticated','authenticated','zztest_mfg9@test.local','',now(),'{}','{}',now(),now())
on conflict (id) do nothing;
update adm.users set role = 'DIRECTOR' where id = 'eeee0000-0000-4000-8000-000000000d01';
update adm.users set role = 'ADMIN' where id = 'eeee0000-0000-4000-8000-000000000a01';
update adm.users set permissions_json = '{"finance":{"view":true,"edit":true}}' where id = 'eeee0000-0000-4000-8000-00000000ac01';
update adm.users set permissions_json = '{"mfg":{"view":true}}' where id = 'eeee0000-0000-4000-8000-00000000f601';

-- seed one test message in accounts and one in director
insert into mail.messages (mailbox_id, folder, from_addr, subject, sent_at, body_text)
select id, 'IN', 'vendor@example.com', 'ZZTEST invoice mail', now(), 'ZZTEST body' from mail.mailboxes where key = 'accounts';
insert into mail.messages (mailbox_id, folder, from_addr, subject, sent_at, body_text)
select id, 'IN', 'secret@example.com', 'ZZTEST director-only mail', now(), 'ZZTEST body' from mail.mailboxes where key = 'director';

do $t$
declare d int; a int; ac int; mf int; dmsg int; acmsg int; ok_h boolean := false; ok_deny boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"eeee0000-0000-4000-8000-000000000d01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  select count(*) into d from mail.mailboxes;
  perform set_config('request.jwt.claims', '{"sub":"eeee0000-0000-4000-8000-000000000a01","role":"authenticated"}', true);
  select count(*) into a from mail.mailboxes;
  perform set_config('request.jwt.claims', '{"sub":"eeee0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  select count(*) into ac from mail.mailboxes;
  select count(*) into acmsg from mail.messages where subject like 'ZZTEST%';
  begin
    perform mail.mark_handled((select id from mail.messages where subject = 'ZZTEST invoice mail'), false);
    ok_h := true;
  exception when others then null;
  end;
  begin
    perform mail.mark_handled((select m.id from mail.messages m join mail.mailboxes b on b.id = m.mailbox_id and b.key = 'director' limit 1), false);
  exception when others then ok_deny := true;
  end;
  perform set_config('request.jwt.claims', '{"sub":"eeee0000-0000-4000-8000-00000000f601","role":"authenticated"}', true);
  select count(*) into mf from mail.mailboxes;
  select count(*) into dmsg from mail.messages where subject like 'ZZTEST director%';
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail) values
  ('Mailbox walls: Dir=5 · Admin=1(info) · Accounts=1 · Production=1', d = 5 and a = 1 and ac = 1 and mf = 1,
   format('dir=%s admin=%s accounts=%s mfg=%s', d, a, ac, mf)),
  ('Accounts reads own mail, marks handled; director mail invisible+untouchable', acmsg = 1 and ok_h and ok_deny and dmsg = 0,
   format('acc_msgs=%s handled=%s director_deny=%s mfg_sees_dirmail=%s', acmsg, ok_h, ok_deny, dmsg));
end $t$;

-- client cannot write messages directly
do $t$
declare ok_ins boolean := false;
begin
  perform set_config('request.jwt.claims', '{"sub":"eeee0000-0000-4000-8000-00000000ac01","role":"authenticated"}', true);
  execute 'set local role authenticated';
  begin
    insert into mail.messages (mailbox_id, folder, subject) select id, 'IN', 'ZZTEST forged' from mail.mailboxes limit 1;
  exception when others then ok_ins := true;
  end;
  execute 'reset role';
  insert into public.zztest_results (test, ok, detail)
  values ('Browser can never write mail rows directly', ok_ins, 'insert refused=' || ok_ins);
end $t$;

select seq, test, case when ok then 'PASS' else 'FAIL' end as result, detail from public.zztest_results order by seq;
