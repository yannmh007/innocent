-- 017 — the metric that could never arrive, and the stutter that could never
-- be explained.
--
-- ── THE FIRST IS A BUG I SHIPPED ────────────────────────────────────────
--
-- 016 added `startup_latency()`, which reads `play_open` events, and the app
-- has been emitting `play_open` since v1.64.21. The table has none. Not a few
-- — none, across twenty-one `play_start` rows in the same sessions.
--
-- `record_events()` drops any event whose kind is not in a list written by
-- hand inside the function body, and `play_open` was never added to it. The
-- drop is silent by design: an unknown kind is skipped, the row is counted as
-- not written, and the client is told how many were written — never which
-- were refused. So the app posted, the server accepted the request, the
-- function returned a smaller number than the client sent, and nobody was in
-- a position to notice. A dashboard was built on a column that could not fill.
--
-- The fix is in three parts, and only the first is the missing kind.
--
--   1. `play_open` and `play_stall` are allowed.
--   2. THE LIST BECOMES A TABLE. A kind is a row now, so the next one is an
--      insert rather than a function rewrite — and a function rewrite is
--      exactly the step that gets skipped when the client change is the
--      interesting half of the work.
--   3. A REFUSED KIND IS COUNTED. `event_kind_rejects` records every kind
--      that arrived and was not known, with a count and a last-seen time.
--      That is the part that actually matters: the failure mode here was not
--      a missing line, it was a missing line that NOTHING COULD SEE. A
--      mismatch between what the app sends and what the server stores is now
--      a row an operator can read, in the same minute it starts happening.
--
-- ── THE SECOND IS THE STUTTER ───────────────────────────────────────────
--
-- A viewer reports that some videos play two seconds, stall, play two
-- seconds, stall — while others on the same connection are perfect. Every
-- explanation available today is a guess, because the only thing recorded is
-- that a stall happened, and the two causes want opposite fixes:
--
--   * THE NETWORK cannot deliver the file's bitrate. A camera clip is tens
--     of megabits per second; a link doing 6 MB/s has 48, and the margin is
--     gone the moment anything else uses the connection. Nothing in the app
--     can fix it — the file has to be smaller.
--   * THE DEVICE cannot decode the file in real time. 4K60 from a phone
--     camera is a different workload from a 480p clip, and when the decoder
--     falls behind the symptom on screen is identical: it stops, it starts,
--     it stops. The buffer, meanwhile, is full.
--
-- Those are distinguishable, precisely, at the moment it happens: libmpv
-- knows how many seconds of data it is holding, how fast the bytes are
-- arriving, what the file's bitrate is, and how many frames the decoder has
-- dropped. The client reads all four when a stall lasts long enough to be
-- worth a spinner and sends them as `play_stall`. `stall_reasons()` is where
-- that becomes an answer instead of an anecdote.

-- ===========================================================================
-- 1. KINDS AS DATA
-- ===========================================================================
create table if not exists public.event_kinds (
  kind     text primary key,
  added_at timestamptz not null default now(),
  note     text
);

insert into public.event_kinds (kind, note) values
  ('impression',        'a card was drawn'),
  ('card_click',        'a card was tapped'),
  ('detail_view',       'the detail screen opened'),
  ('play_start',        'play was pressed'),
  ('play_open',         'ms of black screen before the first frame'),
  ('play_stall',        'playback stopped mid-film, with the cause'),
  ('play_progress',     'a position sample, every ~30s'),
  ('play_complete',     'watched past the completion threshold'),
  ('playback_denied',   'the server refused to hand out a URL'),
  ('search',            null),
  ('search_open',       null),
  ('filter_apply',      null),
  ('bookmark_add',      null),
  ('bookmark_remove',   null),
  ('download_start',    null),
  ('download_complete', null),
  ('app_open',          null),
  ('error',             null)
on conflict (kind) do nothing;

-- READABLE BY NOBODY THROUGH THE API. It is a list of strings with no secret
-- in it, but it is also not something a client has any reason to read, and a
-- table with no policy is the cheapest way to say so.
alter table public.event_kinds enable row level security;

-- ===========================================================================
-- 2. REFUSALS ARE COUNTED
-- ===========================================================================
create table if not exists public.event_kind_rejects (
  kind       text primary key,
  n          bigint not null default 0,
  first_seen timestamptz not null default now(),
  last_seen  timestamptz not null default now()
);
alter table public.event_kind_rejects enable row level security;

-- ===========================================================================
-- 3. record_events, with the two changes
-- ===========================================================================
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
  the_kind   text;
begin
  if jsonb_typeof(batch) <> 'array' then return 0; end if;

  hdr := current_setting('request.headers', true)::json;

  key := coalesce(auth.uid()::text, hdr ->> 'x-install-id');
  if key is null then return 0; end if;

  ip   := coalesce(hdr ->> 'cf-connecting-ip', hdr ->> 'x-real-ip');
  ctry := nullif(upper(coalesce(hdr ->> 'cf-ipcountry', '')), '');
  if ctry in ('XX', 'T1') then ctry := null; end if;

  if ip is not null then
    select salt into the_salt from public.event_secrets where id = 1;
    ip_h := encode(extensions.hmac(ip, the_salt, 'sha256'), 'hex');
  end if;

  for e in select * from jsonb_array_elements(batch) limit 200 loop
    the_kind := coalesce(e ->> 'kind', '');

    -- An unknown kind is still dropped — one typo'd kind shipped in one app
    -- version would split a metric in two forever, and a log that stores
    -- whatever it is sent is not a log, it is a landfill. What is new is that
    -- the drop LEAVES A MARK.
    if not exists (select 1 from public.event_kinds k where k.kind = the_kind)
    then
      begin
        -- Capped at fifty distinct kinds. This is written from an
        -- unauthenticated path, and a client posting random strings must not
        -- be able to grow a table without limit. Fifty is far more than a
        -- real mismatch produces and far less than an attack needs.
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

    begin
      insert into public.events (
        occurred_at, viewer_key, session_id, kind, title_id, asset_id,
        position_s, duration_s, device_kind, network_kind, app_version,
        locale, tz_offset_min, country, ip_hash, meta
      ) values (
        least(coalesce((e ->> 'at')::timestamptz, now()), now()),
        key,
        nullif(e ->> 'session_id', ''),
        the_kind,
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
      when others then null;
    end;
  end loop;

  return written;
end;
$fn$;

revoke all on function public.record_events(jsonb) from public;
grant execute on function public.record_events(jsonb) to anon, authenticated;

-- ===========================================================================
-- 4. WHY PLAYBACK STOPPED
-- ===========================================================================
-- One row per reason per day, with the numbers that justify it. The columns
-- are medians rather than means for the reason 016 gives: one viewer on a
-- dying connection drags an average somewhere nobody actually is.
--
-- SECURITY: definer, like every other reader of `events`, which has RLS on
-- and no policy for anybody. This returns aggregates only.
create or replace function public.stall_reasons(p_days int default 7)
returns table (
  day            date,
  reason         text,
  stalls         bigint,
  sessions       bigint,
  med_need_kbps  int,
  med_have_kbps  int,
  med_cache_s    int
)
language sql
security definer
set search_path = public
as $$
  select
    (e.occurred_at at time zone 'UTC')::date as day,
    coalesce(nullif(e.meta ->> 'reason', ''), 'unknown') as reason,
    count(*) as stalls,
    count(distinct e.session_id) as sessions,
    -- `~ '^[0-9]+$'` before the cast, always. A meta field written by an app
    -- build is text until it has been checked, and one malformed value from a
    -- future build would abort the whole query rather than skew one column.
    percentile_disc(0.5) within group (
      order by case when e.meta ->> 'need_kbps' ~ '^[0-9]+$'
                    then (e.meta ->> 'need_kbps')::int end)::int,
    percentile_disc(0.5) within group (
      order by case when e.meta ->> 'have_kbps' ~ '^[0-9]+$'
                    then (e.meta ->> 'have_kbps')::int end)::int,
    percentile_disc(0.5) within group (
      order by case when e.meta ->> 'cache_s' ~ '^[0-9]+$'
                    then (e.meta ->> 'cache_s')::int end)::int
  from public.events e
  where e.kind = 'play_stall'
    and e.occurred_at >= now() - make_interval(days => greatest(p_days, 1))
  group by 1, 2
  order by 1 desc, 3 desc;
$$;

revoke all on function public.stall_reasons(int) from public;
grant execute on function public.stall_reasons(int) to service_role;

-- ===========================================================================
-- 5. WHAT THE SERVER IS REFUSING
-- ===========================================================================
-- Read by the console's Health panel. Empty is the answer that means the app
-- and the server agree about what an event is.
create or replace function public.event_rejects()
returns table (kind text, n bigint, first_seen timestamptz, last_seen timestamptz)
language sql
security definer
set search_path = public
as $$
  select r.kind, r.n, r.first_seen, r.last_seen
  from public.event_kind_rejects r
  order by r.last_seen desc
  limit 50;
$$;

revoke all on function public.event_rejects() from public;
grant execute on function public.event_rejects() to service_role;
