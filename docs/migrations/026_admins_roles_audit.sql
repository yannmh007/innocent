-- ===========================================================================
-- 026  ADMINS, ROLES AND AN AUDIT LOG NOBODY CAN REWRITE   (Phase 1)
-- ===========================================================================
--
-- Until now "who may use the console" was one user id, copied into four edge
-- functions as a default for OPERATOR_IDS. That was right for one person on
-- one phone. It is not right for the three or four admins the console is about
-- to have: a list in code cannot say WHAT each person may do, cannot be
-- changed without a deploy, and leaves no record of who did what.
--
-- So the list moves into the database, with a role each:
--
--   owner     everything, including other admins, deleting titles, settings
--   editor    approve and publish, edit anything, payment requests, categories
--   uploader  upload and forward, make and edit their OWN unpublished drafts
--   viewer    read only
--
-- The edge functions ask `admin_resolve` on every request and enforce the
-- role there. The console hides what a role cannot use, but that is manners;
-- the refusal happens on the server, because the console is a public page.
--
-- ---------------------------------------------------------------------------
-- INVITING SOMEBODY BEFORE THEY HAVE EVER SIGNED IN
-- ---------------------------------------------------------------------------
--
-- An owner adds an admin by EMAIL, because a user id does not exist until that
-- person signs in for the first time. On that first sign-in the row is linked
-- to their user id, once, and from then on it is matched by id.
--
-- ONLY A CONFIRMED EMAIL LINKS. Today the only sign-in is Google, whose emails
-- are verified. If an email-and-password sign-up were ever switched on, an
-- unconfirmed address could otherwise be claimed by whoever typed it first —
-- somebody signing up as the invited editor's address before the editor did
-- and walking into the console with their role. The address is read from
-- auth.users inside the function, never taken from the caller.
--
-- ---------------------------------------------------------------------------
-- THE AUDIT LOG
-- ---------------------------------------------------------------------------
--
-- Every write any admin makes through the console lands here: who, as what
-- role, through which function, what, on what, and whether it worked. It is
-- APPEND-ONLY at two levels — the service role is granted only SELECT and
-- INSERT, and a trigger refuses UPDATE, DELETE and TRUNCATE for everyone, so a
-- later change to the grants does not quietly make history editable.
--
-- ---------------------------------------------------------------------------
-- MFA IS SWITCHED ON IN TWO STEPS
-- ---------------------------------------------------------------------------
--
-- `admin_settings.require_mfa` starts FALSE. The owner has no second factor
-- yet, and requiring one before the console can enrol it would lock the only
-- admin out of their own console. The console enrols the authenticator first;
-- once the owner's factor exists in auth.mfa_factors, the flag is set to true
-- and every admin request without `aal2` is refused. It is a database flag and
-- not a deploy because it is also the emergency switch.
-- ===========================================================================

create table if not exists public.admins (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid unique references auth.users(id) on delete set null,
  email        text not null,
  role         text not null check (role in ('owner', 'editor', 'uploader', 'viewer')),
  disabled     boolean not null default false,
  added_by     uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz
);
create unique index if not exists admins_email_key on public.admins (lower(email));

alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;
-- No DELETE: removing an admin DISABLES them. The row is the record of who had
-- access and when, and the audit log's actor ids point at it.
grant select, insert, update on public.admins to service_role;

create table if not exists public.admin_audit (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor       uuid,
  actor_email text,
  actor_role  text,
  fn          text not null,
  action      text not null,
  target      text,
  detail      jsonb,
  ok          boolean not null default true,
  error       text
);
create index if not exists admin_audit_at on public.admin_audit (at desc);
create index if not exists admin_audit_actor on public.admin_audit (actor, at desc);

alter table public.admin_audit enable row level security;
revoke all on public.admin_audit from anon, authenticated;
grant select, insert on public.admin_audit to service_role;

create or replace function public.admin_audit_is_append_only()
returns trigger language plpgsql as $$
begin
  raise exception 'admin_audit is append-only: % refused', tg_op
    using errcode = 'insufficient_privilege';
end;
$$;
drop trigger if exists admin_audit_no_rewrite on public.admin_audit;
create trigger admin_audit_no_rewrite
  before update or delete on public.admin_audit
  for each row execute function public.admin_audit_is_append_only();
drop trigger if exists admin_audit_no_truncate on public.admin_audit;
create trigger admin_audit_no_truncate
  before truncate on public.admin_audit
  for each statement execute function public.admin_audit_is_append_only();

-- One row per sign-in session, so a sign-in is announced once and not on every
-- page load. The session id is the `session_id` claim of the token.
create table if not exists public.admin_sessions (
  session_id uuid primary key,
  user_id    uuid,
  first_seen timestamptz not null default now(),
  user_agent text
);
alter table public.admin_sessions enable row level security;
revoke all on public.admin_sessions from anon, authenticated;
grant select, insert on public.admin_sessions to service_role;

create table if not exists public.admin_settings (
  id             boolean primary key default true check (id),
  require_mfa    boolean not null default false,
  -- How recent the authenticator code has to be for a dangerous action
  -- (deleting a title, changing who is an admin).
  stepup_minutes integer not null default 10 check (stepup_minutes between 1 and 120),
  -- Sign out after this long untouched. The console never counts a running
  -- upload as idle.
  idle_minutes   integer not null default 30 check (idle_minutes between 5 and 480),
  updated_at     timestamptz not null default now()
);
insert into public.admin_settings (id) values (true) on conflict (id) do nothing;
alter table public.admin_settings enable row level security;
revoke all on public.admin_settings from anon, authenticated;
grant select, update on public.admin_settings to service_role;

-- Who made a title. An uploader may edit only drafts they made themselves;
-- titles from before this column are nobody's, so only an editor or owner can
-- touch them.
alter table public.titles
  add column if not exists created_by uuid references auth.users(id) on delete set null;

-- The admin there is today: the user id every edge function defaulted
-- OPERATOR_IDS to. Seeded from auth.users so the email is the one Google
-- confirmed, not one typed here.
insert into public.admins (user_id, email, role)
select u.id, lower(u.email), 'owner'
  from auth.users u
 where u.id = '6c679480-3387-4442-ad3d-4423b8aceb71'
   and u.email is not null
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- admin_resolve — the role of whoever is asking, or nothing
-- ---------------------------------------------------------------------------
create or replace function public.admin_resolve(p_user uuid)
returns table(admin_id uuid, email text, role text, require_mfa boolean,
              stepup_minutes integer, idle_minutes integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a public.admins%rowtype;
  s public.admin_settings%rowtype;
  v_email text;
begin
  if p_user is null then
    return;
  end if;

  select * into a from public.admins x where x.user_id = p_user;

  if not found then
    -- First sign-in of an invited admin. The address comes from auth.users
    -- and only when it is CONFIRMED — see the header.
    select lower(u.email) into v_email
      from auth.users u
     where u.id = p_user and u.email_confirmed_at is not null;
    if v_email is null then
      return;
    end if;
    update public.admins x
       set user_id = p_user
     where x.user_id is null and lower(x.email) = v_email
    returning * into a;
    if not found then
      return;
    end if;
  end if;

  if a.disabled then
    return;
  end if;

  update public.admins x set last_seen_at = now() where x.id = a.id;
  select * into s from public.admin_settings where id;

  return query select a.id, a.email, a.role, s.require_mfa, s.stepup_minutes,
                      s.idle_minutes;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_log — one line of the audit log
-- ---------------------------------------------------------------------------
create or replace function public.admin_log(
  p_actor uuid, p_fn text, p_action text, p_target text default null,
  p_detail jsonb default null, p_ok boolean default true, p_error text default null
) returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  insert into public.admin_audit
    (actor, actor_email, actor_role, fn, action, target, detail, ok, error)
  select p_actor, a.email, a.role, left(p_fn, 40), left(p_action, 60),
         left(p_target, 200), p_detail, coalesce(p_ok, true), left(p_error, 300)
    from (select 1) one
    left join public.admins a on a.user_id = p_actor;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_note_session — true the first time a session is seen
-- ---------------------------------------------------------------------------
create or replace function public.admin_note_session(
  p_session uuid, p_user uuid, p_agent text default null
) returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if p_session is null then
    return false;
  end if;
  insert into public.admin_sessions (session_id, user_id, user_agent)
  values (p_session, p_user, left(p_agent, 200))
  on conflict (session_id) do nothing;
  return found;
end;
$$;

-- ---------------------------------------------------------------------------
-- admin_list — the Admins page
-- ---------------------------------------------------------------------------
create or replace function public.admin_list()
returns table(id uuid, email text, role text, disabled boolean, linked boolean,
              mfa boolean, last_seen_at timestamptz, created_at timestamptz)
language sql
security definer
set search_path to 'public'
as $$
  select a.id, a.email, a.role, a.disabled, a.user_id is not null,
         exists (select 1 from auth.mfa_factors f
                  where f.user_id = a.user_id and f.status = 'verified'),
         a.last_seen_at, a.created_at
    from public.admins a
   order by a.disabled, case a.role when 'owner' then 0 when 'editor' then 1
                                    when 'uploader' then 2 else 3 end, a.email;
$$;

-- ---------------------------------------------------------------------------
-- admin_save / admin_remove — owner only, and never the last owner
-- ---------------------------------------------------------------------------
--
-- The edge function already checks the caller is an owner. These check again,
-- because a function that can hand out the owner role is the one place in this
-- system where a single missed check upstream is the whole system.
--
-- THE LAST ACTIVE OWNER CANNOT BE DEMOTED OR DISABLED. Not by somebody else and
-- not by themselves: a console with no owner has nobody who can add one back,
-- short of somebody with database access — and on a phone-only operation that
-- is nobody.
create or replace function public.admin_save(p_actor uuid, p_email text, p_role text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  cur public.admins%rowtype;
  owners integer;
begin
  if not exists (select 1 from public.admins
                  where user_id = p_actor and role = 'owner' and not disabled) then
    return 'not_owner';
  end if;
  if v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    return 'bad_email';
  end if;
  if p_role not in ('owner', 'editor', 'uploader', 'viewer') then
    return 'bad_role';
  end if;

  select * into cur from public.admins where lower(email) = v_email;
  if found then
    if cur.role = 'owner' and not cur.disabled and p_role <> 'owner' then
      select count(*) into owners from public.admins
       where role = 'owner' and not disabled;
      if owners <= 1 then
        return 'last_owner';
      end if;
    end if;
    update public.admins
       set role = p_role, disabled = false
     where id = cur.id;
    return 'updated';
  end if;

  insert into public.admins (email, role, added_by)
  values (v_email, p_role, p_actor);
  return 'added';
end;
$$;

create or replace function public.admin_remove(p_actor uuid, p_admin uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  cur public.admins%rowtype;
  owners integer;
begin
  if not exists (select 1 from public.admins
                  where user_id = p_actor and role = 'owner' and not disabled) then
    return 'not_owner';
  end if;
  select * into cur from public.admins where id = p_admin;
  if not found then
    return 'no_such_admin';
  end if;
  if cur.disabled then
    return 'already_disabled';
  end if;
  if cur.role = 'owner' then
    select count(*) into owners from public.admins
     where role = 'owner' and not disabled;
    if owners <= 1 then
      return 'last_owner';
    end if;
  end if;
  update public.admins set disabled = true where id = p_admin;
  return 'disabled';
end;
$$;

-- ---------------------------------------------------------------------------
-- create_title_from_ingest — now records who made it
-- ---------------------------------------------------------------------------
create or replace function public.create_title_from_ingest(
  p_folder   text,
  p_title    text,
  p_synopsis text default null,
  p_actor    uuid default null
) returns table(title_id uuid, attached integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_folder text := btrim(coalesce(p_folder, ''));
  v_name   text := btrim(coalesce(p_title, ''));
  v_id     uuid;
  n        integer;
begin
  if v_folder = '' then
    raise exception 'no folder' using errcode = 'check_violation';
  end if;
  if v_name = '' then
    raise exception 'a title needs a name' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.titles t where t.slug = v_folder) then
    raise exception 'that folder already belongs to another title'
      using errcode = 'unique_violation';
  end if;

  insert into public.titles (title, synopsis, slug, published, status, created_by)
  values (v_name, nullif(btrim(coalesce(p_synopsis, '')), ''), v_folder,
          false, 'draft', p_actor)
  returning id into v_id;

  select public.attach_ingest_folder(v_folder, v_id) into n;
  return query select v_id, n;
end;
$$;
-- The three-argument version 024 made. One name, one signature: two overloads
-- differing only by a trailing default is how PostgREST picks the wrong one.
drop function if exists public.create_title_from_ingest(text, text, text);

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.admin_resolve(uuid)',
    'public.admin_log(uuid, text, text, text, jsonb, boolean, text)',
    'public.admin_note_session(uuid, uuid, text)',
    'public.admin_list()',
    'public.admin_save(uuid, text, text)',
    'public.admin_remove(uuid, uuid)',
    'public.create_title_from_ingest(text, text, text, uuid)',
    'public.admin_audit_is_append_only()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;
