-- 078: the analytics rollup and the 90-day prune, actually run   (7 Nov 2026)
--
-- WHAT WAS WRONG. 014 made rollup_events(day) and prune_events(keep_days)
-- (the owner's B3: keep raw events 90 days, rolled into event_daily and
-- search_daily first). Nothing ever called them: on 7 Nov both rollups
-- were empty and every event since 23 Sep was still kept, so the 90-day
-- promise would have been broken from 22 Dec. And the service role, which
-- the runner's housekeeping calls as, could not execute either.
--
-- WHAT THIS CHANGES.
--   * events_housekeeping(): once a day (the first ingest tick after a day
--     ends with something left to do), roll up the last three whole days
--     again — events sent late from a phone that was offline land in the
--     right day — and any older day never rolled up, then prune_events(90),
--     which rolls up before it deletes. Every other tick it only looks and
--     returns {"due": false}.
--   * Only the service role may call it (the ingest function's house step).
--   * An index on events(occurred_at), which the prune and the check use.
--
-- PROVED BY tool/sql/events_housekeeping_test.sql.

create index if not exists events_occurred_at on public.events (occurred_at);

create or replace function public.events_housekeeping(p_keep_days integer default 90)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  last_event_day date;
  last_rolled    date;
  stale          boolean;
  d              date;
  rolled         integer := 0;
  pruned         integer := 0;
begin
  if p_keep_days is null or p_keep_days < 30 then
    raise exception 'events_housekeeping: keep at least 30 days, not %', p_keep_days;
  end if;
  -- One at a time: two ticks at once would roll the same days twice.
  if not pg_try_advisory_xact_lock(hashtext('public.events_housekeeping')) then
    return jsonb_build_object('due', false, 'busy', true);
  end if;

  select max(occurred_at)::date into last_event_day
    from public.events where occurred_at < current_date;
  select max(day) into last_rolled from public.event_daily;
  stale := exists (select 1 from public.events
                    where occurred_at < now() - make_interval(days => p_keep_days));

  if not stale and (last_event_day is null or last_rolled >= last_event_day) then
    return jsonb_build_object('due', false);
  end if;

  for d in
    select distinct occurred_at::date from public.events
     where occurred_at < current_date
       and (occurred_at >= current_date - 3
            or last_rolled is null or occurred_at >= last_rolled + 1)
     order by 1
  loop
    perform public.rollup_events(d);
    rolled := rolled + 1;
  end loop;

  pruned := public.prune_events(p_keep_days);
  return jsonb_build_object('due', true, 'rolled_days', rolled, 'pruned', pruned);
end;
$$;

revoke all on function public.events_housekeeping(integer) from public, anon, authenticated;
grant execute on function public.events_housekeeping(integer) to service_role;
