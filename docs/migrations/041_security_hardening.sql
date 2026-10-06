-- 041 — security review, 2026-10-05: what an attacker with the APK could do
--
-- Owner request: "suppose someone skilled and dishonest sets out to attack
-- Innocent — where are we weak?" The answers that live in the database, and
-- their fixes. The whole review is docs/security.md.
--
-- The publishable key ships inside the APK, so everything `anon` may do is
-- something anyone on the internet may do, by hand, as often as they like.
-- Read with that eye, four things were wrong:
--
--   1. title_media gave every viewer the public address of EVERY photo of a
--      premium title. The app blurred the locked ones, and said so honestly
--      ("a presentation choice, not a control") — but the addresses were in
--      the answer, so one request with the anon key opened the whole album.
--      Now the view only hands out the address of a photo this viewer may
--      open; a locked one keeps its blurhash (`preview`) and nothing else.
--   2. record_events had no limit: the same request, looped, writes 200 rows
--      a call until the free 500 MB database is full — and the rows feed
--      Trending, so a loop is also a way to choose what is trending.
--   3. record_view counted one view per install id per title per day, and an
--      install id is whatever the caller says it is: a loop of fresh ids
--      sets any title's view count to any number.
--   4. Housekeeping the advisor and a grant listing turn up: TRUNCATE,
--      TRIGGER and REFERENCES granted to anon/authenticated on every table,
--      trigger functions executable by anyone, five functions without a
--      fixed search_path.
--
-- Nothing here changes what an honest viewer sees, except a locked premium
-- photo, which was blurred already and is now drawn from its blurhash.

-- ===========================================================================
-- 1. A locked photo's address is not sent
-- ===========================================================================
--
-- The rule is AccessPolicy.canOpenItem (lib/…/domain/access_policy.dart),
-- and the numbers are CapabilityMatrix.freePhotoCount — keep them in step:
--
--   free title                    → every photo
--   premium subscriber            → every photo
--   a photo marked is_free        → open (the trailer slot)
--   otherwise the first 3 photos (5 when signed in), in album order
--
-- "Premium" is decided exactly as request-playback decides it: a
-- subscription row with no expiry or an expiry in the future. The view still
-- runs with its owner's rights (013b) — anon cannot read title_assets or
-- subscriptions, and does not need to; auth.uid() is the caller either way.
--
-- A photo's ordinal counts photos only, by (sort_order, id) — the order the
-- app asks for. The app treats a photo without an address as locked whatever
-- its ordinal, so a tie in sort_order can never open something the server
-- withheld; at worst it shows a lock on a photo it could have opened.
create or replace view public.title_media
  with (security_invoker = false) as
with viewer as (
  select auth.uid() is not null
           and coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) = false
           as registered,
         exists (select 1 from public.subscriptions s
                  where s.user_id = auth.uid()
                    and (s.expires_at is null or s.expires_at > now()))
           as premium
), assets as (
  select a.*, t.access_tier, t.locator, t.poster_url,
         count(*) filter (where a.kind = 'photo')
           over (partition by a.title_id order by a.sort_order, a.id
                 rows between unbounded preceding and current row) as photo_no
    from public.title_assets a
    join public.titles t on t.id = a.title_id
   where t.published
     and a.kind = any (array['video', 'clip', 'trailer', 'photo'])
), judged as (
  select x.*,
         x.kind <> 'photo'
           or x.access_tier = 'free'
           or x.is_free
           or v.premium
           or x.photo_no <= case when v.registered then 5 else 3 end
           as may_open
    from assets x cross join viewer v
)
select j.id,
       j.title_id,
       j.kind,
       j.is_free,
       j.sort_order,
       j.duration_s,
       j.width,
       j.height,
       j.label,
       j.language,
       case when j.kind = 'photo' and j.may_open
            then public.public_asset_base() || j.object_key end as url,
       case when j.may_open then
         coalesce(
           case when j.thumb_key is not null
                then public.public_asset_base() || j.thumb_key end,
           case when j.kind = 'photo'
                then public.public_asset_base() || j.object_key end,
           j.poster_url)
       end as thumb_url,
       j.kind <> 'photo' and j.object_key = j.locator as is_main,
       j.bytes,
       j.preview
  from judged j;

-- A view is read, not written. (It is not updatable anyway; the grants said
-- otherwise, and a grant listing should not need a footnote.)
revoke all on public.title_media from anon, authenticated;
grant select on public.title_media to anon, authenticated, service_role;

-- ===========================================================================
-- 2. The caller's network, hashed — one definition for both counters
-- ===========================================================================
-- The same keyed hash record_events has written since 024: the address
-- itself is never stored, only HMAC(ip, salt), so a database dump does not
-- say who watched what.
create or replace function public._request_ip_hash()
returns text language plpgsql stable security definer
set search_path = public, extensions as $fn$
declare
  hdr json := current_setting('request.headers', true)::json;
  ip  text := coalesce(hdr ->> 'cf-connecting-ip', hdr ->> 'x-real-ip');
  s   text;
begin
  if ip is null then return null; end if;
  select salt into s from public.event_secrets where id = 1;
  if s is null then return null; end if;
  return encode(extensions.hmac(ip, s, 'sha256'), 'hex');
end;
$fn$;
revoke execute on function public._request_ip_hash() from public, anon, authenticated;

-- ===========================================================================
-- 3. record_events: a budget per install, per network, and in all
-- ===========================================================================
--
-- The window is the time the SERVER received the event. `occurred_at` is the
-- client's clock (clamped to now), so a flood dated last week would have
-- walked straight past a window on it.
alter table public.events
  add column if not exists received_at timestamptz not null default now();
create index if not exists events_key_received
  on public.events (viewer_key, received_at desc);
create index if not exists events_ip_received
  on public.events (ip_hash, received_at desc) where ip_hash is not null;

-- One row an hour: how many events were written. The global ceiling reads it
-- instead of counting the events table on every call.
create table if not exists public.event_hour_counts (
  hour timestamptz primary key,
  n    int not null default 0
);
alter table public.event_hour_counts enable row level security;
revoke all on public.event_hour_counts from anon, authenticated;

-- THE NUMBERS. The heaviest real install so far wrote 38 events in an hour
-- and 86 in a day (2026-10-05). Per install: 600 an hour, fifteen times that.
-- Per network: 4000 — Myanmar's mobile carriers put many phones behind one
-- address (carrier-grade NAT), so this is far looser than per install; it is
-- the limit for somebody minting install ids from one connection. In all:
-- 30 000 an hour, about 12 MB a day at the worst — a ceiling on what a
-- distributed flood can cost, not a number honest use comes near today.
-- Raise it when the audience grows; a refused batch is counted, below.
create or replace function public.record_events(batch jsonb)
returns integer language plpgsql security definer
set search_path = public, extensions as $function$
declare
  hdr       json;
  key       text;
  ctry      text;
  ip_h      text;
  written   int := 0;
  e         jsonb;
  the_kind  text;
  the_meta  jsonb;
  budget    int;
  used_key  int;
  used_ip   int := 0;
  used_all  int;
  this_hour timestamptz := date_trunc('hour', now());
begin
  if jsonb_typeof(batch) <> 'array' then return 0; end if;

  hdr := current_setting('request.headers', true)::json;
  key := left(coalesce(auth.uid()::text, hdr ->> 'x-install-id'), 64);
  if key is null or key = '' then return 0; end if;

  ctry := nullif(upper(coalesce(hdr ->> 'cf-ipcountry', '')), '');
  if ctry in ('XX', 'T1') then ctry := null; end if;
  ip_h := public._request_ip_hash();

  -- Each count stops at its limit: it never reads more rows than it allows.
  select count(*) into used_key from (
    select 1 from public.events
     where viewer_key = key and received_at > now() - interval '1 hour'
     limit 600) k;
  if ip_h is not null then
    select count(*) into used_ip from (
      select 1 from public.events
       where ip_hash = ip_h and received_at > now() - interval '1 hour'
       limit 4000) i;
  end if;
  select coalesce(sum(n), 0) into used_all from public.event_hour_counts
   where hour = this_hour;

  budget := least(200, 600 - used_key, 4000 - used_ip, 30000 - used_all);
  if budget <= 0 then
    -- Refused, and counted where the console's event health already looks
    -- (event_kind_rejects), so a flood is visible rather than silent.
    begin
      insert into public.event_kind_rejects as r (kind, n)
      values (case when used_all >= 30000 then '(over budget: all)'
                   when used_ip >= 4000 then '(over budget: network)'
                   else '(over budget: install)' end, 1)
      on conflict (kind) do update set n = r.n + 1, last_seen = now();
    exception when others then null;
    end;
    return 0;
  end if;

  for e in select * from jsonb_array_elements(batch) limit budget loop
    the_kind := coalesce(e ->> 'kind', '');

    if not exists (select 1 from public.event_kinds k where k.kind = the_kind)
    then
      begin
        if (select count(*) from public.event_kind_rejects) < 50 then
          insert into public.event_kind_rejects as r (kind, n)
          values (left(nullif(the_kind, ''), 40), 1)
          on conflict (kind) do update
            set n = r.n + 1, last_seen = now();
        end if;
      exception when others then null;
      end;
      continue;
    end if;

    -- The app's largest meta is under 200 bytes. Anything past 2 KB is not
    -- the app, and is dropped rather than stored.
    the_meta := case when jsonb_typeof(e -> 'meta') = 'object'
                      and pg_column_size(e -> 'meta') <= 2048
                     then e -> 'meta' else '{}'::jsonb end;

    begin
      insert into public.events (
        occurred_at, viewer_key, session_id, kind, title_id, asset_id,
        position_s, duration_s, device_kind, network_kind, app_version,
        locale, tz_offset_min, country, ip_hash, meta
      ) values (
        -- Never in the future, and never older than a week (an offline
        -- queue is flushed within days; a date in 1970 is not a queue).
        greatest(least(coalesce((e ->> 'at')::timestamptz, now()), now()),
                 now() - interval '7 days'),
        key,
        left(nullif(e ->> 'session_id', ''), 64),
        the_kind,
        nullif(e ->> 'title_id', '')::uuid,
        nullif(e ->> 'asset_id', '')::uuid,
        nullif(e ->> 'position_s', '')::int,
        nullif(e ->> 'duration_s', '')::int,
        left(nullif(e ->> 'device_kind', ''), 32),
        left(nullif(e ->> 'network_kind', ''), 32),
        left(nullif(e ->> 'app_version', ''), 32),
        left(nullif(e ->> 'locale', ''), 16),
        nullif(e ->> 'tz_offset_min', '')::int,
        ctry,
        ip_h,
        the_meta
      );
      written := written + 1;
    exception
      when others then null;
    end;
  end loop;

  if written > 0 then
    insert into public.event_hour_counts as c (hour, n)
    values (this_hour, written)
    on conflict (hour) do update set n = c.n + excluded.n;
  end if;

  return written;
end;
$function$;

-- ===========================================================================
-- 4. record_view: fresh install ids from one network stop counting
-- ===========================================================================
--
-- One view per install per title per day, as before — and now at most 20
-- installs per network per title per day, and 500 new view rows per network
-- per day. Twenty, not one: a dormitory, an office or a carrier NAT is many
-- real people behind one address. A loop of invented ids from one connection
-- now moves a title's count by twenty a day, not by whatever it likes.
alter table public.title_views add column if not exists ip_hash text;
create index if not exists title_views_ip_day
  on public.title_views (ip_hash, viewed_on) where ip_hash is not null;

create or replace function public.record_view(title_id uuid, viewer_tier text default null)
returns void language plpgsql security definer
set search_path = public as $function$
declare
  key  text;
  ip_h text;
  n    int;
begin
  -- viewer_tier is accepted and IGNORED: trusting a tier the client names is
  -- the mistake this architecture exists to avoid.
  key := left(coalesce(auth.uid()::text,
                       current_setting('request.headers', true)::json ->> 'x-install-id'),
              64);
  if key is null or key = '' then return; end if;

  ip_h := public._request_ip_hash();
  if ip_h is not null then
    if (select count(*) from (
          select 1 from public.title_views v
           where v.ip_hash = ip_h and v.viewed_on = current_date
             and v.title_id = record_view.title_id
           limit 20) x) >= 20 then
      return;
    end if;
    if (select count(*) from (
          select 1 from public.title_views v
           where v.ip_hash = ip_h and v.viewed_on = current_date
           limit 500) x) >= 500 then
      return;
    end if;
  end if;

  insert into public.title_views (title_id, viewer_key, ip_hash)
  values (record_view.title_id, key, ip_h)
  on conflict do nothing;

  -- INT, not boolean: `get diagnostics … = row_count` is an integer, and an
  -- integer does not cast to boolean (it failed at run time once; 004).
  get diagnostics n = row_count;
  if n > 0 then
    update public.titles set view_count = coalesce(view_count, 0) + 1
     where id = record_view.title_id;
  end if;
end;
$function$;

-- ===========================================================================
-- 5. Grants nobody uses, and functions nobody should call
-- ===========================================================================
-- TRUNCATE ignores row level security. PostgREST cannot send it, but a grant
-- that is only safe because of which door is open today is the wrong grant.
do $$
declare r record;
begin
  for r in select c.oid::regclass as rel
             from pg_class c join pg_namespace n on n.oid = c.relnamespace
            where n.nspname = 'public' and c.relkind in ('r', 'v', 'm', 'p')
  loop
    execute format('revoke truncate, references, trigger on %s from anon, authenticated',
                   r.rel);
  end loop;
end $$;
alter default privileges in schema public
  revoke truncate, references, trigger on tables from anon, authenticated;

-- Trigger functions. Postgres refuses to call one outside a trigger, and a
-- trigger does not check EXECUTE when it fires (diagnostic_reports_flood_guard
-- is already revoked and fires on every anon insert) — so this takes away
-- nothing that works, only an entry in the RPC surface.
do $$
declare r record;
begin
  for r in select p.oid::regprocedure as fn
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.prorettype in ('trigger'::regtype, 'event_trigger'::regtype)
  loop
    execute format('revoke execute on function %s from public, anon, authenticated',
                   r.fn);
  end loop;
end $$;

-- A fixed search_path (advisor 0011). None of these five reads a table; the
-- empty path leaves only pg_catalog, which is all they use.
alter function public._jaccard(text[], text[]) set search_path = '';
alter function public.admin_audit_is_append_only() set search_path = '';
alter function public.public_asset_base() set search_path = '';
alter function public.r2_folder_of(text) set search_path = '';
alter function public.sync_title_published() set search_path = '';

insert into public.schema_migrations (version, note)
values ('041', 'security: title_media withholds locked photos; event/view budgets; grants')
on conflict (version) do nothing;

-- ===========================================================================
-- CHECKS (run 2026-10-05 inside transactions that were rolled back)
-- ===========================================================================
--   anon, premium title: url only for photo_no <= 3 or is_free; preview kept
--   a premium subscriber: every url
--   record_events: the 601st event from one install in an hour is refused
--   record_view: the 21st fresh install from one network adds nothing
