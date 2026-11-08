-- The analytics rollup and the 90-day prune run, in that order   (migration 078)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates or deletes survives. Success is the message `EVENTS
-- HOUSEKEEPING TEST PASSED`; any other exception names the case that failed.
-- Its events carry negative ids: no value is drawn from the events sequence.
--
--   1. only the service role may call events_housekeeping();
--   2. as the service role, the first call is due: an event past 90 days is
--      rolled into event_daily and search_daily, THEN deleted; yesterday's
--      is rolled and kept;
--   3. the next call is not due and changes nothing;
--   4. it refuses to keep fewer than 30 days.
do $$
declare
  old_day date := current_date - 100;
  r       jsonb;
  n       integer;
begin
  if has_function_privilege('anon', 'public.events_housekeeping(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.events_housekeeping(integer)', 'execute') then
    raise exception 'case 1: anon or authenticated may call events_housekeeping';
  end if;
  if not has_function_privilege('service_role', 'public.events_housekeeping(integer)', 'execute') then
    raise exception 'case 1: the service role may not call events_housekeeping';
  end if;

  insert into public.events (id, occurred_at, viewer_key, kind, country, tz_offset_min, locale, meta)
  values
    (-1, old_day + time '12:00', 'hk-test-a', 'play',   'MM', 390, 'my', '{}'),
    (-2, old_day + time '12:05', 'hk-test-b', 'search', 'MM', 390, 'my',
         '{"q": "Housekeeping Test", "results": 0}'),
    (-3, current_date - 1 + time '12:00', 'hk-test-c', 'play', 'MM', 390, 'my', '{}');

  set local role service_role;
  r := public.events_housekeeping();
  reset role;

  if coalesce((r ->> 'due')::boolean, false) is not true then
    raise exception 'case 2: the first call was not due: %', r;
  end if;
  if (r ->> 'pruned')::int <> 2 then
    -- Only the two test events are past 90 days (the oldest real one is 23 Sep).
    raise exception 'case 2: pruned % events, expected 2: %', r ->> 'pruned', r;
  end if;
  if exists (select 1 from public.events where id in (-1, -2)) then
    raise exception 'case 2: the old events were not deleted';
  end if;
  if not exists (select 1 from public.events where id = -3) then
    raise exception 'case 2: yesterday''s event was deleted';
  end if;
  select events into n from public.event_daily
   where day = old_day and kind = 'play' and audience = 'MM'
     and title_id = '00000000-0000-0000-0000-000000000000';
  if n is distinct from 1 then
    raise exception 'case 2: the old day was not rolled up before the prune (events %)', n;
  end if;
  if not exists (select 1 from public.search_daily
                  where day = old_day and q = 'housekeeping test'
                    and audience = 'MM' and searches = 1 and no_result = 1) then
    raise exception 'case 2: the old search was not rolled into search_daily';
  end if;
  if not exists (select 1 from public.event_daily where day = current_date - 1) then
    raise exception 'case 2: yesterday was not rolled up';
  end if;

  set local role service_role;
  r := public.events_housekeeping();
  reset role;
  if coalesce((r ->> 'due')::boolean, true) is not false then
    raise exception 'case 3: the second call was due again: %', r;
  end if;

  begin
    perform public.events_housekeeping(7);
    raise exception 'case 4: keeping 7 days was accepted';
  exception when raise_exception then
    if sqlerrm not like 'events_housekeeping: keep at least 30 days%' then
      raise;
    end if;
  end;

  raise exception 'EVENTS HOUSEKEEPING TEST PASSED';
end $$;
