-- ===========================================================================
-- 010 — the premium backend: subscriptions, devices, requests, payment
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
-- NO CLIENT CHANGE. Every table and column here is named by code the app
-- already ships; this migration is the server catching up to it.
--
-- WHERE THESE NAMES COME FROM
--   Read off `api_account_repository.dart`, not invented and not taken from a
--   document. The catalogue already cost a day to a contract document that had
--   drifted from the code, and PostgREST rejects the WHOLE request when one
--   name in `select` is unknown - so a guess here shows up as "premium is
--   broken" with nothing to go on.
--
--     subscriptions        select plan_id,starts_at,expires_at
--                          order expires_at.desc.nullsfirst  limit 1
--     payment_instructions select payee_name,payee_number,prices,note
--                          UNAUTHENTICATED - the paywall must render before
--                          anyone signs in
--     premium_requests     select id,plan_id,reference,sender_phone,status,
--                                 note,submitted_at   order submitted_at.desc
--                          insert plan_id, reference, sender_phone
--                          -- and NEVER status; see the policy below
--     rpc record_age_consent(terms_version, accepted_at)
--     rpc claim_anonymous_history(anon_id)
--     devices              read by request-playback: user_id, device_id
-- ===========================================================================

do $mig$
begin
  if exists (select 1 from public.schema_migrations where version = '010') then
    raise notice '010 already applied, skipping';
    return;
  end if;

  -- ---- subscriptions ----------------------------------------------------
  -- One row per grant. Renewals INSERT rather than update, so the history of
  -- what someone paid for survives - which is the first thing wanted when a
  -- payment is disputed.
  create table if not exists public.subscriptions (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users(id) on delete cascade,
    plan_id    text not null,
    starts_at  timestamptz not null default now(),
    -- NULL means a lifetime grant. The app reads that as "no expiry", and
    -- `order expires_at.desc.nullsfirst` puts it first on purpose: a lifetime
    -- row must win over any dated one.
    expires_at timestamptz,
    source     text not null default 'manual',
    note       text,
    created_at timestamptz not null default now()
  );
  create index if not exists subscriptions_user on public.subscriptions (user_id, expires_at desc);

  -- ---- devices ----------------------------------------------------------
  -- What makes the concurrency cap real. request-playback counts these rows
  -- and refuses a third with `wrong_device`, which the app has rendered as its
  -- own message since v1.63.5.
  create table if not exists public.devices (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references auth.users(id) on delete cascade,
    device_id  text not null,
    label      text,
    last_seen  timestamptz not null default now(),
    created_at timestamptz not null default now(),
    -- One row per device per account. Without this a retry storm registers
    -- the same phone four times and burns the cap against itself.
    unique (user_id, device_id)
  );

  -- ---- premium_requests -------------------------------------------------
  -- The KPay flow: the viewer transfers money, then files the reference here,
  -- and a human checks it. `status` is NOT insertable by the client.
  create table if not exists public.premium_requests (
    id           uuid primary key default gen_random_uuid(),
    user_id      uuid not null references auth.users(id) on delete cascade,
    plan_id      text not null,
    reference    text not null,
    sender_phone text,
    status       text not null default 'pending'
                 check (status in ('pending','approved','rejected')),
    note         text,
    submitted_at timestamptz not null default now(),
    reviewed_at  timestamptz
  );
  create index if not exists premium_requests_user on public.premium_requests (user_id, submitted_at desc);
  create index if not exists premium_requests_pending on public.premium_requests (submitted_at) where status = 'pending';

  -- ---- payment_instructions --------------------------------------------
  -- One row, edited by hand. Read WITHOUT a session, because the paywall has
  -- to show a price before anyone has a reason to sign in.
  create table if not exists public.payment_instructions (
    id           int primary key default 1 check (id = 1),
    payee_name   text not null default '',
    payee_number text not null default '',
    prices       jsonb not null default '{}'::jsonb,
    note         text,
    updated_at   timestamptz not null default now()
  );
  insert into public.payment_instructions (id) values (1) on conflict do nothing;

  -- ---- age consent ------------------------------------------------------
  create table if not exists public.age_consents (
    viewer_key    text not null,
    terms_version int not null,
    accepted_at   timestamptz not null,
    recorded_at   timestamptz not null default now(),
    primary key (viewer_key, terms_version)
  );

  insert into public.schema_migrations (version, note)
  values ('010', 'subscriptions, devices, premium_requests, payment_instructions, age_consents');
end
$mig$;


-- ---------------------------------------------------------------------------
-- RLS: everyone sees ONLY their own
-- ---------------------------------------------------------------------------
alter table public.subscriptions     enable row level security;
alter table public.devices           enable row level security;
alter table public.premium_requests  enable row level security;
alter table public.payment_instructions enable row level security;
alter table public.age_consents      enable row level security;

drop policy if exists "own subscriptions" on public.subscriptions;
create policy "own subscriptions" on public.subscriptions
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own devices" on public.devices;
create policy "own devices" on public.devices
  for select to authenticated using (user_id = auth.uid());

drop policy if exists "own requests" on public.premium_requests;
create policy "own requests" on public.premium_requests
  for select to authenticated using (user_id = auth.uid());

-- THE ONE INSERT THE CLIENT MAY DO, and the two things it may not decide.
--
-- `user_id = auth.uid()` in the CHECK: a client cannot file a request in
-- someone else's name, even by sending their id.
--
-- `status = 'pending'`: the app deliberately never sends `status`, and this
-- policy is what makes that safe rather than merely polite. Without it a
-- crafted request could arrive pre-approved, and the paywall would be one
-- HTTP call wide.
drop policy if exists "file own request" on public.premium_requests;
create policy "file own request" on public.premium_requests
  for insert to authenticated
  with check (user_id = auth.uid() and status = 'pending');

-- Prices are public by design: the paywall renders before sign-in.
drop policy if exists "prices are public" on public.payment_instructions;
create policy "prices are public" on public.payment_instructions
  for select to anon, authenticated using (true);

-- No policy on age_consents: written only by the function below, read only by
-- the operator. Nobody queries their own consent record.


-- ---------------------------------------------------------------------------
-- Column grants. "Expose new tables" is OFF, so nothing is granted by default
-- to ANY role - service_role included. That has bitten this project three
-- times now (002, 005, 006). Granting inside the migration that creates the
-- table is how it stops.
-- ---------------------------------------------------------------------------
grant select (plan_id, starts_at, expires_at) on public.subscriptions to authenticated;
grant select (device_id, label, last_seen)    on public.devices       to authenticated;
grant select (id, plan_id, reference, sender_phone, status, note, submitted_at)
  on public.premium_requests to authenticated;
grant insert (plan_id, reference, sender_phone, user_id)
  on public.premium_requests to authenticated;
grant select (payee_name, payee_number, prices, note)
  on public.payment_instructions to anon, authenticated;

grant all privileges on public.subscriptions        to service_role;
grant all privileges on public.devices              to service_role;
grant all privileges on public.premium_requests     to service_role;
grant all privileges on public.payment_instructions to service_role;
grant all privileges on public.age_consents         to service_role;


-- ---------------------------------------------------------------------------
-- user_id fills itself
-- ---------------------------------------------------------------------------
-- The app does not send `user_id`, and it should not have to. A trigger sets
-- it from the JWT, which is the only source that cannot be lied about.
create or replace function public.set_request_owner()
returns trigger language plpgsql security definer
set search_path = public as $fn$
begin
  new.user_id := auth.uid();
  new.status := 'pending';   -- belt as well as braces; the policy is the braces
  return new;
end;
$fn$;

drop trigger if exists premium_requests_owner on public.premium_requests;
create trigger premium_requests_owner
  before insert on public.premium_requests
  for each row execute function public.set_request_owner();


-- ---------------------------------------------------------------------------
-- The two RPCs the app calls
-- ---------------------------------------------------------------------------
create or replace function public.record_age_consent(
  terms_version int,
  accepted_at   timestamptz
)
returns void language plpgsql security definer
set search_path = public as $fn$
declare
  key text;
begin
  key := coalesce(
    auth.uid()::text,
    current_setting('request.headers', true)::json ->> 'x-install-id'
  );
  if key is null then return; end if;
  insert into public.age_consents (viewer_key, terms_version, accepted_at)
  values (key, terms_version, accepted_at)
  on conflict (viewer_key, terms_version) do nothing;
end;
$fn$;

-- Moves an anonymous install's view history onto the account that just signed
-- in. Idempotent, and a no-op when there is nothing to move.
create or replace function public.claim_anonymous_history(anon_id text)
returns void language plpgsql security definer
set search_path = public as $fn$
declare
  uid text := auth.uid()::text;
begin
  if uid is null or anon_id is null or anon_id = '' or anon_id = uid then
    return;
  end if;
  -- on conflict do nothing: the account may already have watched the same
  -- title on the same day from another device.
  update public.title_views set viewer_key = uid
   where viewer_key = anon_id
     and not exists (
       select 1 from public.title_views b
       where b.title_id = title_views.title_id
         and b.viewer_key = uid
         and b.viewed_on = title_views.viewed_on
     );
  update public.age_consents set viewer_key = uid
   where viewer_key = anon_id
     and not exists (
       select 1 from public.age_consents c
       where c.viewer_key = uid and c.terms_version = age_consents.terms_version
     );
end;
$fn$;

grant execute on function public.record_age_consent(int, timestamptz)
  to anon, authenticated;
grant execute on function public.claim_anonymous_history(text) to authenticated;


-- ---------------------------------------------------------------------------
-- The operator's two buttons
-- ---------------------------------------------------------------------------
-- Approving a request should not be three statements typed correctly in order
-- at midnight. One call: grant the subscription, mark the request, record why.
create or replace function public.approve_request(p_request_id uuid, p_days int default 30)
returns text language plpgsql security definer
set search_path = public as $fn$
declare
  r record;
begin
  select * into r from public.premium_requests where id = p_request_id;
  if r is null then return 'NOT FOUND'; end if;
  if r.status <> 'pending' then
    return 'ALREADY ' || upper(r.status) || ' - nothing done';
  end if;

  -- Extends an existing subscription rather than overwriting it: someone who
  -- renews early must not lose the days they already paid for.
  insert into public.subscriptions (user_id, plan_id, starts_at, expires_at, source, note)
  values (
    r.user_id, r.plan_id, now(),
    greatest(
      now(),
      coalesce((select max(expires_at) from public.subscriptions
                where user_id = r.user_id), now())
    ) + make_interval(days => p_days),
    'kpay', 'request ' || r.id::text
  );

  update public.premium_requests
     set status = 'approved', reviewed_at = now()
   where id = p_request_id;

  return 'APPROVED ' || r.plan_id || ' for ' || p_days || ' days';
end;
$fn$;

create or replace function public.reject_request(p_request_id uuid, p_note text)
returns text language plpgsql security definer
set search_path = public as $fn$
begin
  update public.premium_requests
     set status = 'rejected', note = p_note, reviewed_at = now()
   where id = p_request_id and status = 'pending';
  if not found then return 'NOT FOUND or already reviewed'; end if;
  return 'REJECTED';
end;
$fn$;

revoke execute on function public.approve_request(uuid,int) from public, anon, authenticated;
revoke execute on function public.reject_request(uuid,text) from public, anon, authenticated;
grant execute on function public.approve_request(uuid,int) to service_role;
grant execute on function public.reject_request(uuid,text) to service_role;

-- The operator's inbox.
create or replace view public.pending_requests as
  select r.id, r.plan_id, r.reference, r.sender_phone, r.submitted_at,
         u.email, u.phone
  from public.premium_requests r
  left join auth.users u on u.id = r.user_id
  where r.status = 'pending'
  order by r.submitted_at;

revoke all on public.pending_requests from anon, authenticated;
grant select on public.pending_requests to service_role;


-- ---------------------------------------------------------------------------
-- PROVE IT
-- ---------------------------------------------------------------------------
-- 1. the paywall must render with no session at all
set role anon;
select payee_name, payee_number, prices from public.payment_instructions;
select count(*) from public.subscriptions;   -- must ERROR: permission denied
reset role;

-- 2. what the operator sees
select * from public.pending_requests;
select version from public.schema_migrations order by version desc limit 1;  -- 010
