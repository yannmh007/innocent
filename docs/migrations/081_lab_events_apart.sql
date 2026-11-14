-- 081: the labs' plays are kept apart from viewers'   (14 Nov 2026)
--
-- WHAT WAS WRONG. Lab builds (device lab and Test Lab, INNOCENT_LAB=true)
-- send their events to production like any phone: device_kind 'phone',
-- app_version 1.64.78+391 (the work branch's own; main bumps alone). The 7
-- days to 14 Nov: 1,594 of 1,798 events, 170 fresh installs, 170 of 179
-- play_open, all on open films. They led Trending (trending_titles 7 of 7;
-- the home's heat reads the same), fed co-watch and the daily rollups, and
-- set the console's start-up percentiles (the labs' weak line: p50 3257 /
-- p95 4625 ms; viewers' 9 opens p50 1727 / p95 3008). The owner chose to
-- mark them and leave them out (BACKLOG §0, "(a)").
--
-- WHAT THIS CHANGES.
--   1. Lab builds send device_kind 'lab' (EventSender.build). The events
--      already sent are marked the same: every event of an install that
--      only ever reported 1.64.78+391 (211 installs, a fresh one per lab
--      run). NOT every 1.64.78+391 event: 1.64.78 was a release, and one
--      install that reports every other version too ran it on 30-31 Oct
--      (26 events, two sessions) — a viewer's, and kept so.
--   2. Heat (_refresh_heat, trending_title_ids, trending_titles), co-watch
--      (_refresh_cowatch), the daily rollup (rollup_events) and the
--      console's start-up and stall readings (startup_latency,
--      startup_by_title, stall_reasons) leave device_kind 'lab' out;
--      event_geo names the labs' audience 'lab' (the console's audience
--      tally shows them apart, not as the runners' country). Each body is
--      as it was live on 14 Nov but for that line; grants are unchanged
--      (create or replace keeps them).
--   3. _refresh_cowatch also sets title_reach to 0 for a title no viewer
--      engaged with any more: it only ever upserted, so a title the labs
--      alone had reached kept that reach (_similar_scores divides by it
--      through nullif, so 0 is safe).
--   4. The days already rolled are rolled again without the labs (every
--      day in event_daily still has its raw events: the oldest is 23 Sep,
--      inside the 90 days kept), and heat and co-watch are recomputed now.
--
-- Additive for the app: no RPC's arguments or result columns change.
-- Callers: unchanged (the home's _maybe_refresh_* on read, the ingest
-- tick's events_housekeeping).
-- PROVED BY tool/sql/lab_events_test.sql.

-- 1. The labs' events so far.
update public.events e
   set device_kind = 'lab'
 where e.app_version = '1.64.78+391'
   and e.device_kind is distinct from 'lab'
   and not exists (select 1 from public.events o
                    where o.viewer_key = e.viewer_key
                      and o.app_version is distinct from '1.64.78+391');

-- 2. The readers.
create or replace view public.event_geo as
 SELECT id,
    occurred_at,
    viewer_key,
    session_id,
    kind,
    title_id,
    asset_id,
    position_s,
    duration_s,
    device_kind,
    network_kind,
    app_version,
    locale,
    tz_offset_min,
    country,
    ip_hash,
    meta,
        CASE
            WHEN country IS NULL THEN 'unknown'::text
            WHEN tz_offset_min IS NULL THEN 'ip_only'::text
            WHEN tz_offset_min = 390 AND country = 'MM'::text THEN 'consistent'::text
            WHEN tz_offset_min = 390 THEN 'vpn_suspect'::text
            WHEN country = 'MM'::text THEN 'traveller_or_proxy'::text
            ELSE 'foreign'::text
        END AS geo_trust,
        CASE
            WHEN device_kind = 'lab'::text THEN 'lab'::text
            WHEN tz_offset_min = 390 THEN 'MM'::text
            WHEN locale ~~ 'my%'::text THEN 'MM'::text
            ELSE COALESCE(country, '??'::text)
        END AS audience
   FROM events e;

create or replace function public.rollup_events(p_day date default (current_date - 1))
 returns integer
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare n int;
begin
  insert into public.event_daily (day, title_id, kind, audience, events, viewers)
  select p_day,
         coalesce(g.title_id, '00000000-0000-0000-0000-000000000000'::uuid),
         g.kind, g.audience, count(*), count(distinct g.viewer_key)
    from public.event_geo g
   where g.occurred_at >= p_day and g.occurred_at < p_day + 1
     and g.device_kind is distinct from 'lab'
   group by 2, g.kind, g.audience
  on conflict (day, title_id, kind, audience)
  do update set events = excluded.events, viewers = excluded.viewers;
  get diagnostics n = row_count;

  insert into public.search_daily (day, q, audience, searches, no_result)
  select p_day,
         left(lower(trim(g.meta ->> 'q')), 120),
         g.audience,
         count(*),
         count(*) filter (where coalesce((g.meta ->> 'results')::int, -1) = 0)
    from public.event_geo g
   where g.kind = 'search'
     and g.occurred_at >= p_day and g.occurred_at < p_day + 1
     and g.device_kind is distinct from 'lab'
     and coalesce(trim(g.meta ->> 'q'), '') <> ''
   group by 2, 3
  on conflict (day, q, audience)
  do update set searches = excluded.searches, no_result = excluded.no_result;

  return n;
end;
$function$;

create or replace function public.trending_title_ids(p_limit integer default 20)
 returns table(title_id uuid, rank integer)
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with per_viewer as (
    select e.title_id, e.viewer_key, max(e.occurred_at) as last_at,
           max(case when e.kind = 'play_complete' then 1.0
                    when e.duration_s > 0 then least(1.0, e.position_s::numeric / e.duration_s)
                    else 0 end) as watched
      from public.events e
     where e.title_id is not null and e.occurred_at > now() - interval '14 days'
       and e.kind in ('play_start', 'play_progress', 'play_complete')
       and e.device_kind is distinct from 'lab'
     group by e.title_id, e.viewer_key
  ), scored as (
    select title_id, sum(exp(-extract(epoch from (now() - last_at)) / 259200.0) * (0.3 + 0.7 * watched)) as score
      from per_viewer group by title_id
  )
  select s.title_id, (row_number() over (order by s.score desc, s.title_id))::int
    from scored s where s.score > 0 order by 2 limit greatest(1, least(p_limit, 100));
$function$;

create or replace function public.trending_titles(p_limit integer default 20)
 returns table(title_id uuid, heat numeric, completion numeric, score numeric)
 language sql
 stable
 set search_path to 'public'
as $function$
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
       and e.device_kind is distinct from 'lab'
     group by e.title_id
  )
  select w.title_id,
         round(coalesce(w.heat, 0), 4),
         round(coalesce(w.completion, 0), 4),
         round(coalesce(w.heat, 0) * (0.5 + coalesce(w.completion, 0)), 4) as score
    from w
   order by score desc
   limit greatest(1, least(p_limit, 100));
$function$;

create or replace function public._refresh_heat()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare stamp timestamptz := now();
begin
  if not pg_try_advisory_xact_lock(hashtext('innocent.heat')) then return; end if;
  insert into public.title_heat (title_id, trend_rank, starts, completes)
  select t.id, tr.rank, coalesce(q.starts, 0), coalesce(q.completes, 0)
    from public.titles t
    left join public.trending_title_ids(100) tr on tr.title_id = t.id
    left join (
      select e.title_id,
             count(distinct e.viewer_key) filter (where e.kind = 'play_start')::int as starts,
             count(distinct e.viewer_key) filter (where e.kind = 'play_complete')::int as completes
        from public.events e
       where e.title_id is not null and e.kind in ('play_start', 'play_complete')
         and e.occurred_at > now() - interval '180 days'
         and e.device_kind is distinct from 'lab'
       group by e.title_id
    ) q on q.title_id = t.id
  on conflict (title_id) do update
     set trend_rank = excluded.trend_rank,
         starts     = excluded.starts,
         completes  = excluded.completes;
  update public.reco_state set heat_at = stamp where id = 1;
end;
$function$;

create or replace function public._refresh_cowatch()
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare stamp timestamptz := now();
begin
  if not pg_try_advisory_xact_lock(hashtext('innocent.cowatch')) then return; end if;
  with engaged as (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete' or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
       and e.device_kind is distinct from 'lab'
  ), pairs as (
    select x.title_id as a, y.title_id as b, count(*)::int as n
      from engaged x join engaged y on y.viewer_key = x.viewer_key and y.title_id <> x.title_id
     group by 1, 2
  )
  insert into public.title_cowatch (a, b, both_n)
  select a, b, n from pairs
  on conflict (a, b) do update set both_n = excluded.both_n;
  with engaged as (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete' or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
       and e.device_kind is distinct from 'lab'
  ), pairs as (
    select x.title_id as a, y.title_id as b
      from engaged x join engaged y on y.viewer_key = x.viewer_key and y.title_id <> x.title_id
     group by 1, 2
  )
  update public.title_cowatch c set both_n = 0
   where c.both_n <> 0 and not exists (select 1 from pairs p where p.a = c.a and p.b = c.b);
  insert into public.title_reach (title_id, n)
  select title_id, count(*)::int from (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete' or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
       and e.device_kind is distinct from 'lab'
  ) g group by 1
  on conflict (title_id) do update set n = excluded.n;
  -- A title no viewer engaged with any more keeps no reach (081).
  update public.title_reach r set n = 0
   where r.n <> 0 and not exists (
     select 1 from public.events e
      where e.title_id = r.title_id
        and e.occurred_at > now() - interval '180 days'
        and e.kind in ('play_progress', 'play_complete')
        and (e.kind = 'play_complete' or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
        and e.device_kind is distinct from 'lab');
  update public.reco_state set cowatch_at = stamp where id = 1;
end;
$function$;

create or replace function public.startup_latency(p_days integer default 7)
 returns table(day date, samples bigint, p50_ms integer, p95_ms integer, p99_ms integer, worst_ms integer)
 language sql
 security definer
 set search_path to 'public'
as $function$
  select
    (src.occurred_at at time zone 'UTC')::date as day,
    count(*) as samples,
    percentile_disc(0.50) within group (order by src.ms)::int as p50_ms,
    percentile_disc(0.95) within group (order by src.ms)::int as p95_ms,
    percentile_disc(0.99) within group (order by src.ms)::int as p99_ms,
    max(src.ms)::int as worst_ms
  from (
    select e.occurred_at,
      case when (e.meta ->> 'open_ms') ~ '^[0-9]{1,8}$'
           then (e.meta ->> 'open_ms')::int end as ms
    from public.events e
    where e.kind = 'play_open'
      and e.occurred_at >= now() - make_interval(days => greatest(p_days, 1))
      and e.device_kind is distinct from 'lab'
  ) src
  where src.ms is not null
  group by 1
  order by 1 desc;
$function$;

create or replace function public.startup_by_title(p_days integer default 7, p_limit integer default 20)
 returns table(title_id uuid, title text, samples bigint, p50_ms integer, p95_ms integer)
 language sql
 security definer
 set search_path to 'public'
as $function$
  select e.title_id, t.title, count(*) as samples,
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
    and e.device_kind is distinct from 'lab'
    and m.ms is not null
  group by 1, 2
  having count(*) >= 3
  order by p95_ms desc
  limit greatest(p_limit, 1);
$function$;

create or replace function public.stall_reasons(p_days integer default 7)
 returns table(day date, reason text, stalls bigint, sessions bigint, med_need_kbps integer, med_have_kbps integer, med_cache_s integer)
 language sql
 security definer
 set search_path to 'public'
as $function$
  select
    (e.occurred_at at time zone 'UTC')::date as day,
    coalesce(nullif(e.meta ->> 'reason', ''), 'unknown') as reason,
    count(*) as stalls,
    count(distinct e.session_id) as sessions,
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
    and e.device_kind is distinct from 'lab'
  group by 1, 2
  order by 1 desc, 3 desc;
$function$;

-- 4. What was rolled and computed with the labs in it, again without.
do $$
declare d date;
begin
  for d in select distinct ed.day from public.event_daily ed
            where ed.day >= (select min(occurred_at)::date from public.events)
              and ed.day > (now() - interval '90 days')::date
            order by 1
  loop
    delete from public.event_daily where day = d;
    delete from public.search_daily where day = d;
    perform public.rollup_events(d);
  end loop;
end $$;

select public._refresh_heat();
select public._refresh_cowatch();
