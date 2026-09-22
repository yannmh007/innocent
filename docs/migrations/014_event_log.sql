-- 014 — the event log
--
-- THE ARGUMENT FOR DOING THIS BEFORE THE ALGORITHMS, restated because it is
-- the only reason this is first in the queue and not last:
--
--   A ranking formula can be rewritten in an afternoon, six months from now,
--   against whatever data exists. But if the app never recorded that a viewer
--   opened a title and quit after ninety seconds, that fact is gone
--   permanently. The expensive mistake is not choosing the wrong algorithm.
--   It is not capturing the events.
--
-- `docs/movies_data_model_v2.md` §3 made that argument on 2 Sep and nothing
-- was built. Twenty days of history do not exist because of it.
--
-- What exists today is `title_views`: one row per viewer per title per day,
-- three columns. It can count views and nothing else. It cannot answer "did
-- they finish it", "where did they stop", "did they even press play", or
-- "what did they search for and not find" — and those are the questions every
-- ranking worth having is built on. `landing_rows()` proves the cost: its
-- "Trending" is `order by view_count desc`, a cumulative counter that can
-- never change its own answer, so the first titles to get views sit at the
-- top forever and nothing new is ever discovered.

-- ===========================================================================
-- 1. THE SECRET USED TO HASH AN IP
-- ===========================================================================
--
-- WHY THE RAW IP IS NOT STORED, given the operator explicitly asked for IP
-- checking. The concern behind the request is right and is addressed below —
-- a VPN makes `cf-ipcountry` lie, and an interest model fed a lie recommends
-- the wrong things. But the raw address is the wrong instrument for it:
--
--   * It does not actually detect a VPN. Telling a Singapore VPN exit from a
--     real Singapore viewer needs a commercial IP-intelligence feed, not the
--     address itself. Storing the address buys none of that.
--   * On an adult catalogue, a table joining a person's viewing history to
--     their IP address is the single highest-liability object in the system.
--     It is also the one thing here that could identify a real person to a
--     third party who obtained the database.
--
-- So two things are stored instead, and between them they do everything the
-- request was actually about:
--
--   `ip_hash`   HMAC-SHA256 of the address with a secret that lives in this
--               table and rotates. Two events from the same network have the
--               same hash, so "these forty searches came from one connection"
--               and "this account is being used from nine networks" are both
--               answerable. The address cannot be recovered from it, and
--               rotating the secret makes even the correlation expire.
--
--   `tz_offset_min` + `locale`, reported by the DEVICE. A VPN does not change
--               a phone's clock or its language. A device sitting at UTC+6:30
--               with a Burmese locale is a Myanmar viewer no matter what
--               country the connection claims — and that is a far stronger
--               signal than the IP ever was. See the `event_geo` view.
create table if not exists public.event_secrets (
  id          int primary key default 1,
  salt        text not null,
  rotated_at  timestamptz not null default now(),
  constraint event_secrets_one_row check (id = 1)
);

alter table public.event_secrets enable row level security;
-- No policy at all, for anybody. The only reader is a security definer
-- function, which bypasses RLS by definition. An empty policy set is not an
-- oversight here; it is the strongest available statement.

insert into public.event_secrets (id, salt)
values (1, encode(extensions.gen_random_bytes(32), 'hex'))
on conflict (id) do nothing;

-- ===========================================================================
-- 2. THE LOG
-- ===========================================================================
-- Append only. Never updated, never deleted from except by `prune_events`.
create table if not exists public.events (
  id            bigserial primary key,
  occurred_at   timestamptz not null default now(),

  -- auth.uid() when signed in, otherwise the install id. NEVER a phone number
  -- and never an email: this is a record of what individual people watched,
  -- and it should not be possible to read a name out of it.
  viewer_key    text not null,
  -- One app run. Groups a journey together: which row the card was clicked
  -- from, what was searched before the play, where it stopped.
  session_id    text,

  kind          text not null,
  title_id      uuid references public.titles(id) on delete set null,
  asset_id      uuid references public.title_assets(id) on delete set null,

  -- `position_s` over `duration_s` is the completion ratio, which is the
  -- single most useful number in this whole schema: it is what tells a title
  -- people click and quit from one fewer people finish.
  position_s    int,
  duration_s    int,

  -- Context the device reports. A thirty-minute clip on a phone at lunch and
  -- a two-hour film on Wi-Fi on Saturday night are different experiences, and
  -- without these columns that distinction is unrecoverable.
  device_kind   text,
  network_kind  text,
  app_version   text,
  locale        text,
  tz_offset_min int,

  -- From the connection. May be wrong — see the note on the secret above.
  country       text,
  ip_hash       text,

  meta          jsonb not null default '{}'
);

create index if not exists events_title_time  on public.events (title_id, occurred_at desc);
create index if not exists events_viewer_time on public.events (viewer_key, occurred_at desc);
create index if not exists events_kind_time   on public.events (kind, occurred_at desc);
-- Searches are queried by their text, which lives in meta.
create index if not exists events_meta_gin    on public.events using gin (meta jsonb_path_ops);

alter table public.events enable row level security;
-- Again: no policy for anon or authenticated. Events are WRITTEN through the
-- security definer function below and READ only by the operator.

-- ===========================================================================
-- 3. GEOGRAPHY, DECIDED IN A VIEW RATHER THAN WRITTEN INTO THE ROW
-- ===========================================================================
--
-- The rule for "is this country believable" will be wrong at least once, and
-- a verdict written into ten million rows cannot be corrected. A view can be
-- replaced in one statement and every historical row is re-judged for free.
-- So the table stores FACTS and this decides what they mean.
--
-- 390 minutes is UTC+06:30, which is Myanmar and almost nothing else — the
-- other half-hour offsets nearby are +05:30 (India), +05:45 (Nepal) and
-- +06:00 (Bangladesh). A device reporting +06:30 is a Myanmar device.
create or replace view public.event_geo as
  select e.*,
         case
           when e.country is null              then 'unknown'
           when e.tz_offset_min is null        then 'ip_only'
           when e.tz_offset_min = 390
            and e.country = 'MM'               then 'consistent'
           -- The case the operator asked about: the phone is on Myanmar time
           -- and the connection says somewhere else. Trust the phone.
           when e.tz_offset_min = 390          then 'vpn_suspect'
           when e.country = 'MM'               then 'traveller_or_proxy'
           else 'foreign'
         end as geo_trust,
         -- What a recommender should actually group by. Derived from the
         -- device, which a VPN does not touch.
         case
           when e.tz_offset_min = 390 then 'MM'
           when e.locale like 'my%'   then 'MM'
           else coalesce(e.country, '??')
         end as audience
    from public.events e;

-- ===========================================================================
-- 4. WRITING EVENTS
-- ===========================================================================
-- One call, a batch of them. The client collects and flushes every thirty
-- seconds or on background; a request per tap would be a request per tap.
create or replace function public.record_events(batch jsonb)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $fn$
declare
  hdr        json;
  key        text;
  ip         text;
  the_salt   text;
  ip_h       text;
  ctry       text;
  written    int := 0;
  e          jsonb;
begin
  if jsonb_typeof(batch) <> 'array' then return 0; end if;

  hdr := current_setting('request.headers', true)::json;

  -- Same identity rule as record_view: the signed-in user if there is one,
  -- otherwise the install id. A caller cannot name its own viewer_key.
  key := coalesce(auth.uid()::text, hdr ->> 'x-install-id');
  if key is null then return 0; end if;

  -- `cf-connecting-ip` is what Cloudflare sets in front of the API gateway;
  -- `x-real-ip` is the fallback. Both are set by infrastructure, not by the
  -- client, so neither can be spoofed from the app.
  ip   := coalesce(hdr ->> 'cf-connecting-ip', hdr ->> 'x-real-ip');
  ctry := nullif(upper(coalesce(hdr ->> 'cf-ipcountry', '')), '');
  -- Cloudflare uses XX for "could not determine" and T1 for Tor.
  if ctry in ('XX', 'T1') then ctry := null; end if;

  if ip is not null then
    select salt into the_salt from public.event_secrets where id = 1;
    ip_h := encode(extensions.hmac(ip, the_salt, 'sha256'), 'hex');
  end if;

  -- CAPPED. A batch is a convenience for the client, not an invitation to
  -- post a million rows in one statement.
  for e in select * from jsonb_array_elements(batch) limit 200 loop
    -- Unknown kinds are DROPPED, not stored. The kind column is what every
    -- query groups by, and one typo'd kind shipped in one app version would
    -- split a metric in two forever with nothing to say which half is real.
    continue when coalesce(e ->> 'kind', '') not in (
      'impression', 'card_click', 'detail_view',
      'play_start', 'play_progress', 'play_complete', 'playback_denied',
      'search', 'search_open', 'filter_apply',
      'bookmark_add', 'bookmark_remove',
      'download_start', 'download_complete',
      'app_open', 'error'
    );

    -- THE HANDLER IS PER EVENT, NOT PER BATCH, and the difference matters.
    -- A handler around the whole loop would still catch a malformed uuid —
    -- but PostgreSQL rolls the block's database changes back to where the
    -- handler's BEGIN is, so ONE bad event would silently discard every good
    -- event beside it while the counter kept its value and reported success.
    -- A nested block rolls back only the row that failed.
    begin
      insert into public.events (
        occurred_at, viewer_key, session_id, kind, title_id, asset_id,
        position_s, duration_s, device_kind, network_kind, app_version,
        locale, tz_offset_min, country, ip_hash, meta
      ) values (
        -- The client's own timestamp is accepted because a batch flushed
        -- after thirty seconds offline would otherwise record every event at
        -- the moment the network came back. Clamped to now(): a device with a
        -- wrong clock must not be able to write the future into the log.
        least(coalesce((e ->> 'at')::timestamptz, now()), now()),
        key,
        nullif(e ->> 'session_id', ''),
        e ->> 'kind',
        nullif(e ->> 'title_id', '')::uuid,
        nullif(e ->> 'asset_id', '')::uuid,
        nullif(e ->> 'position_s', '')::int,
        nullif(e ->> 'duration_s', '')::int,
        nullif(e ->> 'device_kind', ''),
        nullif(e ->> 'network_kind', ''),
        nullif(e ->> 'app_version', ''),
        nullif(e ->> 'locale', ''),
        nullif(e ->> 'tz_offset_min', '')::int,
        ctry,
        ip_h,
        coalesce(e -> 'meta', '{}'::jsonb)
      );
      written := written + 1;
    exception
      -- Analytics must never break the app, and a title deleted between the
      -- tap and the flush is an ordinary occurrence, not a fault.
      when others then null;
    end;
  end loop;

  return written;
end;
$fn$;

revoke all on function public.record_events(jsonb) from public;
grant execute on function public.record_events(jsonb) to anon, authenticated;

-- ===========================================================================
-- 5. ROLLUP AND RETENTION
-- ===========================================================================
-- The raw rows are the liability; the aggregates are what the algorithms
-- read. Roll up first, then delete — in that order, always, or a prune is
-- data loss rather than hygiene.
-- NO NULLS IN THE KEY. An event with no title (a search, an app open) is
-- stored against the nil uuid rather than against null, because a primary key
-- cannot contain a null and the alternative — a unique index over a
-- `coalesce(...)` expression — makes `on conflict` inference depend on the
-- expression matching textually. That is a footgun waiting for the first
-- person to reformat this file.
create table if not exists public.event_daily (
  day       date not null,
  title_id  uuid not null default '00000000-0000-0000-0000-000000000000'::uuid,
  kind      text not null,
  audience  text not null default '??',
  events    int  not null default 0,
  viewers   int  not null default 0,
  primary key (day, title_id, kind, audience)
);

create table if not exists public.search_daily (
  day       date not null,
  q         text not null,
  audience  text not null default '??',
  searches  int  not null default 0,
  no_result int  not null default 0,
  primary key (day, q, audience)
);

alter table public.event_daily  enable row level security;
alter table public.search_daily enable row level security;

create or replace function public.rollup_events(p_day date default (current_date - 1))
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare n int;
begin
  insert into public.event_daily (day, title_id, kind, audience, events, viewers)
  select p_day,
         coalesce(g.title_id, '00000000-0000-0000-0000-000000000000'::uuid),
         g.kind, g.audience, count(*), count(distinct g.viewer_key)
    from public.event_geo g
   where g.occurred_at >= p_day and g.occurred_at < p_day + 1
   group by 2, g.kind, g.audience
  on conflict (day, title_id, kind, audience)
  do update set events = excluded.events, viewers = excluded.viewers;
  get diagnostics n = row_count;

  -- SEARCH IS ROLLED UP SEPARATELY because the text is the point. A query
  -- that returned nothing is the audience naming what the catalogue is
  -- missing, in their own words, and it is the most directly actionable row
  -- in this entire schema.
  insert into public.search_daily (day, q, audience, searches, no_result)
  select p_day,
         left(lower(trim(g.meta ->> 'q')), 120),
         g.audience,
         count(*),
         count(*) filter (where coalesce((g.meta ->> 'results')::int, -1) = 0)
    from public.event_geo g
   where g.kind = 'search'
     and g.occurred_at >= p_day and g.occurred_at < p_day + 1
     and coalesce(trim(g.meta ->> 'q'), '') <> ''
   group by 2, 3
  on conflict (day, q, audience)
  do update set searches = excluded.searches, no_result = excluded.no_result;

  return n;
end;
$fn$;

-- 90 days, as decided. Roll up everything still unrolled, THEN delete.
create or replace function public.prune_events(p_keep_days int default 90)
returns int
language plpgsql
security definer
set search_path = public
as $fn$
declare
  d date;
  n int;
begin
  for d in
    select distinct occurred_at::date
      from public.events
     where occurred_at < now() - make_interval(days => p_keep_days)
     order by 1
  loop
    perform public.rollup_events(d);
  end loop;

  delete from public.events
   where occurred_at < now() - make_interval(days => p_keep_days);
  get diagnostics n = row_count;
  return n;
end;
$fn$;

-- Operator only. Neither of these should ever be reachable from the app.
revoke all on function public.rollup_events(date) from public;
revoke all on function public.prune_events(int)  from public;

-- ===========================================================================
-- 6. THE FIRST RANKING THAT CAN CHANGE ITS OWN ANSWER
-- ===========================================================================
--
-- Not wired into landing_rows() yet, deliberately: with three titles and a
-- handful of viewers it would rank noise, and `view_count desc` is at least
-- honest about being arbitrary. This exists so that the day there are two
-- weeks of events, switching over is one line in landing_rows() rather than
-- a design exercise.
--
--   heat        a play today counts double one from three days ago
--               (259200 seconds = a 72-hour half-life)
--   completion  plays that reached the end over plays that started
--   rank        heat * (0.5 + completion)
--
-- The completion factor is what stops a title with good artwork and a bad
-- film from sitting at the top: it gets the clicks and loses the multiplier.
create or replace function public.trending_titles(p_limit int default 20)
returns table (title_id uuid, heat numeric, completion numeric, score numeric)
language sql
stable
set search_path = public
as $fn$
  with w as (
    select e.title_id,
           sum(exp(-extract(epoch from (now() - e.occurred_at)) / 259200.0))
             filter (where e.kind = 'play_start') as heat,
           count(*) filter (where e.kind = 'play_complete')::numeric
             / nullif(count(*) filter (where e.kind = 'play_start'), 0) as completion
      from public.events e
     where e.title_id is not null
       and e.occurred_at > now() - interval '14 days'
       and e.kind in ('play_start', 'play_complete')
     group by e.title_id
  )
  select w.title_id,
         round(coalesce(w.heat, 0), 4),
         round(coalesce(w.completion, 0), 4),
         round(coalesce(w.heat, 0) * (0.5 + coalesce(w.completion, 0)), 4) as score
    from w
   order by score desc
   limit greatest(1, least(p_limit, 100));
$fn$;

-- ===========================================================================
-- 7. WHAT TO ACQUIRE NEXT
-- ===========================================================================
-- Searches that found nothing, most-wanted first. Reads the rollup where it
-- exists and the raw log for today, so it is useful before the first prune.
-- A plain SQL function runs as the CALLER, so anon calling this would simply
-- be refused on public.events. Revoked anyway: a later edit that made it
-- security definer would otherwise open the whole log to the world, silently.
revoke all on function public.trending_titles(int) from public;
grant execute on function public.trending_titles(int) to service_role;

create or replace view public.search_gaps as
  select q, audience, sum(no_result) as misses, sum(searches) as searches
    from public.search_daily
   group by 1, 2
  having sum(no_result) > 0
   order by 3 desc;

-- EXPLICIT, because this project has been bitten by it: migration 002 exists
-- only because "expose new tables" was off and service_role silently had no
-- grant on a table that had just been created. A missing grant here would
-- make the console's stats tab empty with no error worth reading.
grant select, insert, update, delete
  on public.events, public.event_daily, public.search_daily to service_role;
grant select on public.event_geo, public.search_gaps to service_role;
grant usage, select on sequence public.events_id_seq to service_role;

insert into public.schema_migrations (version, note)
values ('014', 'events log, geo view, batched record_events, daily rollup, 90-day prune, trending')
on conflict (version) do nothing;

-- ===========================================================================
-- CHECKS
-- ===========================================================================
--
--   -- What the server actually sees of a caller. Run from the APP, not here:
--   -- the SQL editor is not behind the same gateway and has no such headers.
--   select current_setting('request.headers', true)::json;
--
--   -- Nothing may read the log without the service role.
--   set role anon;
--   select count(*) from public.events;        -- must be permission denied
--   reset role;
--
--   -- The salt must not be readable either.
--   set role authenticated;
--   select * from public.event_secrets;        -- must be permission denied
--   reset role;
