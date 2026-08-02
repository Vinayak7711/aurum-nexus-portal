-- ================================================================================
--  AURUM SPIRITS — ERP · MODULE 9: DEPARTMENT MAIL
--  Each department's email inbox (Gmail-hosted @aurumspirits.com) inside the ERP:
--  read, reply, compose, mark handled. Sync/send run in Edge Functions (server-
--  side); passwords live ONLY in Supabase secrets, set by the Director, never in
--  the browser and never in this database. Additive. Idempotent.
--  NOTE: after running, the 'mail' schema must be in the Data API exposed schemas.
-- ================================================================================
create schema if not exists mail;
grant usage on schema mail to anon, authenticated;

-- ---------- 1. MAILBOXES: which department box, who may open it ----------
create table if not exists mail.mailboxes (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,          -- 'info','accounts','sales','production','director'
  address text not null unique,      -- info@aurumspirits.com
  display text not null,             -- shown on the tab
  grant_module text,                 -- permission that opens it (null = role-based only)
  grant_action text,
  admin_ok boolean not null default false,   -- ADMIN role may open (for info@)
  dir_only boolean not null default false,   -- Director only (director@)
  is_active boolean not null default true
);

-- Who may open a mailbox: Director always; director@ only the Director;
-- info@ also the ADMIN role; department boxes by their module grant.
create or replace function mail.can_access(p_mailbox uuid)
returns boolean language sql stable security definer
set search_path = mail, adm, app, public as $$
  select case
    when (select role from adm.users where id = auth.uid()) = 'DIRECTOR' then true
    when not exists (select 1 from mail.mailboxes b where b.id = p_mailbox and b.is_active) then false
    when (select dir_only from mail.mailboxes where id = p_mailbox) then false
    when (select admin_ok from mail.mailboxes where id = p_mailbox)
         and (select role from adm.users where id = auth.uid()) = 'ADMIN' then true
    when (select grant_module from mail.mailboxes where id = p_mailbox) is not null
         and app.can((select grant_module from mail.mailboxes where id = p_mailbox),
                     (select grant_action from mail.mailboxes where id = p_mailbox)) then true
    else false end
$$;
grant execute on function mail.can_access(uuid) to authenticated;

-- ---------- 2. MESSAGES (synced in + sent out) ----------
create table if not exists mail.messages (
  id uuid primary key default gen_random_uuid(),
  mailbox_id uuid not null references mail.mailboxes(id),
  folder text not null check (folder in ('IN','SENT')),
  pop_uidl text,                     -- Gmail POP unique id (IN only)
  msg_id text,                       -- Message-ID header
  from_addr text, to_addr text,
  subject text,
  sent_at timestamptz,
  body_text text,
  is_handled boolean not null default false,
  handled_by uuid references adm.users(id),
  handled_at timestamptz,
  created_by uuid references adm.users(id),   -- who sent (SENT only)
  created_at timestamptz not null default now()
);
create unique index if not exists idx_mail_uidl on mail.messages (mailbox_id, folder, pop_uidl) where pop_uidl is not null;
create index if not exists idx_mail_box_date on mail.messages (mailbox_id, folder, sent_at desc);

-- ---------- 3. RLS ----------
alter table mail.mailboxes enable row level security;
alter table mail.messages  enable row level security;
grant select on mail.mailboxes, mail.messages to authenticated;

drop policy if exists boxes_read on mail.mailboxes;
create policy boxes_read on mail.mailboxes for select
  using ( app.is_active() and mail.can_access(id) );
drop policy if exists msgs_read on mail.messages;
create policy msgs_read on mail.messages for select
  using ( app.is_active() and mail.can_access(mailbox_id) );
-- No insert/update policies for clients: writing happens only through the
-- server-side sync/send functions and the RPC below.

-- ---------- 4. MARK HANDLED ----------
create or replace function mail.mark_handled(p_msg uuid, p_undo boolean default false)
returns void language plpgsql security definer set search_path = mail, adm, app, public as $$
declare v_box uuid;
begin
  select mailbox_id into v_box from mail.messages where id = p_msg;
  if v_box is null then raise exception 'Message not found.'; end if;
  if not mail.can_access(v_box) then raise exception 'You do not have access to this mailbox.'; end if;
  update mail.messages
     set is_handled = not p_undo,
         handled_by = case when p_undo then null else auth.uid() end,
         handled_at = case when p_undo then null else now() end
   where id = p_msg;
end $$;
grant execute on function mail.mark_handled(uuid, boolean) to authenticated;

-- ---------- 5. SEED: the five department boxes ----------
insert into mail.mailboxes (key, address, display, grant_module, grant_action, admin_ok, dir_only) values
  ('info',       'info@aurumspirits.com',       'Info / Office',  null,      null,   true,  false),
  ('accounts',   'accounts@aurumspirits.com',   'Accounts',       'finance', 'view', false, false),
  ('sales',      'sales@aurumspirits.com',      'Sales',          'sales',   'view', false, false),
  ('production', 'production@aurumspirits.com', 'Production',     'mfg',     'view', false, false),
  ('director',   'director@aurumspirits.com',   'Director',       null,      null,   false, true)
on conflict (key) do nothing;

select 'MODULE 9 DEPARTMENT MAIL SCHEMA APPLIED' as status;
