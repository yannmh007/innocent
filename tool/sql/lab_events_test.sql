-- The labs' plays are kept apart from viewers'   (migration 081)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates or changes survives. Success is the message `LAB EVENTS TEST
-- PASSED`; any other exception names the case that failed. Its events carry
-- negative ids: no value is drawn from the events sequence.
--
--   1. every event of an install that only ever reported 1.64.78+391 is
--      marked 'lab'; the viewer's own 1.64.78 events are not;
--   2. a lab event moves neither Trending (trending_titles,
--      trending_title_ids) nor the start-up and stall readings; a phone's
--      does;
--   3. the daily rollup counts the phone's event and not the lab's, and
--      event_geo names the lab's audience 'lab';
--   4. co-watch's reach of a title counts viewers only;
--   5. who may call what is as before.
do $$
declare
  film   uuid := (select id from public.titles
                   where slug like 'open-film-%' order by slug limit 1);
  d0     date := current_date - 80;  -- before the first event (23 Sep)
  heat0  numeric;
  heat1  numeric;
  rank0  integer;
  n0     bigint;
  n1     bigint;
  s0     bigint;
  s1     bigint;
  r      integer;
begin
  if film is null then raise exception 'setup: no open film'; end if;

  -- 1.
  if exists (select 1 from public.events e
              where e.app_version = '1.64.78+391'
                and e.device_kind is distinct from 'lab'
                and not exists (select 1 from public.events o
                                 where o.viewer_key = e.viewer_key
                                   and o.app_version is distinct from '1.64.78+391')) then
    raise exception 'case 1: a lab install''s event is not marked lab';
  end if;
  if exists (select 1 from public.events e
              where e.device_kind = 'lab'
                and exists (select 1 from public.events o
                             where o.viewer_key = e.viewer_key
                               and o.app_version is distinct from '1.64.78+391')) then
    raise exception 'case 1: a viewer''s event was marked lab';
  end if;

  -- 2. Trending.
  select heat into heat0 from public.trending_titles(100) where title_id = film;
  select rank into rank0 from public.trending_title_ids(100) where title_id = film;
  insert into public.events (id, occurred_at, viewer_key, session_id, kind, title_id,
                             position_s, duration_s, device_kind, meta)
  values (-81001, now(), 'lab-test-a', 'lab-test-a', 'play_start', film, 0, 600, 'lab', '{}'),
         (-81002, now(), 'lab-test-b', 'lab-test-b', 'play_start', film, 0, 600, 'lab', '{}'),
         (-81003, now(), 'lab-test-c', 'lab-test-c', 'play_complete', film, 600, 600, 'lab', '{}');
  select heat into heat1 from public.trending_titles(100) where title_id = film;
  if heat1 is distinct from heat0 then
    raise exception 'case 2: lab plays moved the heat (% -> %)', heat0, heat1;
  end if;
  if (select rank from public.trending_title_ids(100) where title_id = film) is distinct from rank0 then
    raise exception 'case 2: lab plays moved the trending rank';
  end if;
  insert into public.events (id, occurred_at, viewer_key, session_id, kind, title_id,
                             position_s, duration_s, device_kind, meta)
  values (-81004, now(), 'phone-test-a', 'phone-test-a', 'play_start', film, 0, 600, 'phone', '{}');
  select heat into heat1 from public.trending_titles(100) where title_id = film;
  if heat1 is null or heat1 <= coalesce(heat0, 0) then
    raise exception 'case 2: a phone''s play did not move the heat (% -> %)', heat0, heat1;
  end if;

  -- 2. Start-up and stalls, today.
  select coalesce(sum(samples), 0) into n0 from public.startup_latency(1)
   where day = (now() at time zone 'UTC')::date;
  select coalesce(sum(stalls), 0) into s0 from public.stall_reasons(1)
   where day = (now() at time zone 'UTC')::date;
  insert into public.events (id, occurred_at, viewer_key, session_id, kind, title_id, device_kind, meta)
  values (-81005, now(), 'lab-test-a', 'lab-test-a', 'play_open', film, 'lab', '{"open_ms": 4625}'),
         (-81006, now(), 'lab-test-a', 'lab-test-a', 'play_stall', film, 'lab', '{"reason": "ladder"}');
  select coalesce(sum(samples), 0) into n1 from public.startup_latency(1)
   where day = (now() at time zone 'UTC')::date;
  select coalesce(sum(stalls), 0) into s1 from public.stall_reasons(1)
   where day = (now() at time zone 'UTC')::date;
  if n1 <> n0 or s1 <> s0 then
    raise exception 'case 2: a lab open or stall was counted (opens % -> %, stalls % -> %)', n0, n1, s0, s1;
  end if;
  insert into public.events (id, occurred_at, viewer_key, session_id, kind, title_id, device_kind, meta)
  values (-81007, now(), 'phone-test-a', 'phone-test-a', 'play_open', film, 'phone', '{"open_ms": 1727}');
  select coalesce(sum(samples), 0) into n1 from public.startup_latency(1)
   where day = (now() at time zone 'UTC')::date;
  if n1 <> n0 + 1 then
    raise exception 'case 2: a phone''s open was not counted (% -> %)', n0, n1;
  end if;

  -- 3. The rollup of a day with nothing else in it.
  insert into public.events (id, occurred_at, viewer_key, kind, title_id, country,
                             tz_offset_min, locale, device_kind, meta)
  values (-81008, d0 + time '12:00', 'lab-test-a', 'play_start', film, 'US', 0, 'en-US', 'lab', '{}'),
         (-81009, d0 + time '12:01', 'phone-test-a', 'play_start', film, 'MM', 390, 'my', 'phone', '{}'),
         (-81010, d0 + time '12:02', 'lab-test-a', 'search', null, 'US', 0, 'en-US', 'lab',
          '{"q": "Lab Test", "results": 0}');
  if (select audience from public.event_geo where id = -81008) is distinct from 'lab' then
    raise exception 'case 3: event_geo did not name the lab''s audience lab';
  end if;
  if (select audience from public.event_geo where id = -81009) is distinct from 'MM' then
    raise exception 'case 3: event_geo moved a viewer''s audience';
  end if;
  r := public.rollup_events(d0);
  if (select coalesce(sum(events), 0) from public.event_daily
       where day = d0 and kind = 'play_start') <> 1 then
    raise exception 'case 3: the day''s play_start rolled up as %, expected the phone''s 1',
      (select sum(events) from public.event_daily where day = d0 and kind = 'play_start');
  end if;
  if exists (select 1 from public.event_daily where day = d0 and audience = 'lab')
     or exists (select 1 from public.search_daily where day = d0) then
    raise exception 'case 3: the lab''s events were rolled up';
  end if;

  -- 4. Reach counts viewers only.
  perform public._refresh_cowatch();
  if (select coalesce(n, 0) from public.title_reach where title_id = film)
     is distinct from (select count(distinct e.viewer_key)::int from public.events e
                        where e.title_id = film
                          and e.occurred_at > now() - interval '180 days'
                          and e.kind in ('play_progress', 'play_complete')
                          and (e.kind = 'play_complete'
                               or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
                          and e.device_kind is distinct from 'lab') then
    raise exception 'case 4: the film''s reach counts the lab';
  end if;

  -- 5.
  if has_function_privilege('anon', 'public.rollup_events(date)', 'execute')
     or has_function_privilege('anon', 'public.startup_latency(integer)', 'execute')
     or has_function_privilege('anon', 'public.trending_titles(integer)', 'execute')
     or has_function_privilege('authenticated', 'public._refresh_heat()', 'execute')
     or has_table_privilege('anon', 'public.event_geo', 'select')
     or has_table_privilege('authenticated', 'public.event_geo', 'select') then
    raise exception 'case 5: a reader opened to anon or authenticated';
  end if;
  if not has_function_privilege('anon', 'public.trending_title_ids(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.startup_latency(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.trending_titles(integer)', 'execute')
     or not has_table_privilege('service_role', 'public.event_geo', 'select') then
    raise exception 'case 5: a reader lost a grant it had';
  end if;

  raise exception 'LAB EVENTS TEST PASSED';
end $$;
