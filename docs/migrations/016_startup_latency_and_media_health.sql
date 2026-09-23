-- 016 — two things the console could not see, and both of them were the
-- reason a real complaint could not be answered.
--
-- THE FIRST IS START-UP LATENCY. A user reported that opening a video showed
-- "Slow connection — buffering…" for several seconds on a link measured at
-- 13 MB/s, and there was no way to tell whether that was true of everyone,
-- of one title, or of one evening — because nothing recorded it. The client
-- now emits `play_open` carrying `meta.open_ms`, the time between handing the
-- file to the player and the first frame appearing, and this is where that
-- becomes a number somebody can act on.
--
-- PERCENTILES, NOT AN AVERAGE, and the difference is the whole point. A mean
-- start-up time is dragged around by one viewer on a dying connection and
-- hides the shape completely: 500 ms for most people and 20 s for a tenth of
-- them averages out to something that looks acceptable and is not. p50 says
-- what it normally feels like; p95 says what it feels like when it is bad,
-- which is the number that decides whether people come back.
--
-- THE SECOND IS MEDIA HEALTH. Every video row in this database has
-- `thumb_key` null, so the album grid has been drawing the TITLE POSTER for
-- every clip since the first upload — four clips, four copies of the same
-- picture. It looked plausible, which is exactly why it survived: nothing was
-- broken, it was just showing a picture of something else. `media_health`
-- makes that countable so the console can list the rows that need a operator
-- to act, instead of the operator having to notice.

-- ── start-up latency ────────────────────────────────────────────────────
--
-- SECURITY: definer, and deliberately so. `events` has RLS on with no policy
-- for anybody, which is what keeps the raw log unreadable — a row there ties
-- a session to a title to a time. This function returns only aggregates over
-- at least a handful of rows, so it discloses how fast the service is without
-- disclosing who used it.
create or replace function public.startup_latency(p_days int default 7)
returns table (
  day date,
  samples bigint,
  p50_ms int,
  p95_ms int,
  p99_ms int,
  worst_ms int
)
language sql
security definer
set search_path = public
as $$
  select
    (src.occurred_at at time zone 'UTC')::date as day,
    count(*) as samples,
    percentile_disc(0.50) within group (order by src.ms)::int as p50_ms,
    percentile_disc(0.95) within group (order by src.ms)::int as p95_ms,
    percentile_disc(0.99) within group (order by src.ms)::int as p99_ms,
    max(src.ms)::int as worst_ms
  from (
    select
      e.occurred_at,
      -- A meta field written by an app build is not a number until it has
      -- been checked. The regex refuses anything else rather than letting a
      -- cast abort the whole query, which is what a single malformed row
      -- from a future build would otherwise do.
      case when (e.meta ->> 'open_ms') ~ '^[0-9]{1,8}$'
           then (e.meta ->> 'open_ms')::int end as ms
    from public.events e
    where e.kind = 'play_open'
      and e.occurred_at >= now() - make_interval(days => greatest(p_days, 1))
  ) src
  where src.ms is not null
  group by 1
  order by 1 desc;
$$;

revoke all on function public.startup_latency(int) from public;
grant execute on function public.startup_latency(int) to service_role;

-- ── the same, per title ─────────────────────────────────────────────────
--
-- WHICH FILE, not just how bad. Start-up cost is mostly a property of the
-- OBJECT — an MP4 whose moov atom sits at the end of a two-gigabyte file
-- costs an extra round trip and a tail read before the first frame, every
-- time, for everyone. Split by title, that file stands out immediately;
-- pooled, it disappears into the average and looks like "the network".
create or replace function public.startup_by_title(
  p_days int default 7, p_limit int default 20)
returns table (
  title_id uuid,
  title text,
  samples bigint,
  p50_ms int,
  p95_ms int
)
language sql
security definer
set search_path = public
as $$
  select
    e.title_id,
    t.title,
    count(*) as samples,
    percentile_disc(0.50) within group (order by m.ms)::int as p50_ms,
    percentile_disc(0.95) within group (order by m.ms)::int as p95_ms
  from public.events e
  join public.titles t on t.id = e.title_id
  cross join lateral (
    select case when (e.meta ->> 'open_ms') ~ '^[0-9]{1,8}$'
                then (e.meta ->> 'open_ms')::int end as ms
  ) m
  where e.kind = 'play_open'
    and e.occurred_at >= now() - make_interval(days => greatest(p_days, 1))
    and m.ms is not null
  group by 1, 2
  -- Two samples is not a measurement. Ordering by p95 with no floor puts
  -- whichever title one person opened once on a train at the top of the
  -- list, every time.
  having count(*) >= 3
  order by p95_ms desc
  limit greatest(p_limit, 1);
$$;

revoke all on function public.startup_by_title(int, int) from public;
grant execute on function public.startup_by_title(int, int) to service_role;

-- ── media health ────────────────────────────────────────────────────────
--
-- One row per asset that is doing something the app cannot render properly.
-- Not an error table: every row here still works, which is why none of it
-- was ever noticed. It is the list of things that look fine and are not.
create or replace view public.media_health as
  select
    a.id,
    a.title_id,
    t.title,
    a.kind,
    a.object_key,
    -- A video with no thumbnail of its own. `title_media` falls back to the
    -- title poster, so the grid shows the same picture for every clip in a
    -- title and none of them is a picture of the clip.
    (a.kind <> 'photo' and a.thumb_key is null) as borrows_poster,
    -- No width means the mosaic cannot size the tile and gives a portrait
    -- clip a landscape hole.
    (a.width is null or a.height is null) as no_dimensions,
    -- No duration means no length badge, and nothing to measure completion
    -- against: `play_complete` needs a denominator.
    (a.kind <> 'photo' and a.duration_s is null) as no_duration,
    (a.bytes is null) as no_size
  from public.title_assets a
  join public.titles t on t.id = a.title_id;

-- Owner rights, stated rather than inherited.
--
-- `security_invoker` is NOT wanted here and the reason is the same one that
-- bit migration 013: `create or replace view` silently resets reloptions, so
-- a view that relies on the default has no record of what that default was
-- meant to be. This view is read only by the console through the service
-- role, and `title_assets` holds every private video's address — so it runs
-- as its owner and is granted to nobody else.
alter view public.media_health set (security_invoker = false);
revoke all on public.media_health from public, anon, authenticated;
grant select on public.media_health to service_role;

insert into public.schema_migrations (version, note)
values ('016',
  'startup_latency + startup_by_title percentiles, and media_health for assets that look fine and are not')
on conflict (version) do nothing;
