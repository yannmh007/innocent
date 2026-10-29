-- 052 — THE HOME PAGE NO LONGER READS THE EVENT LOG (2026-10-29)
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. It deletes nothing and drops nothing.
--
-- WHY. `landing_rows()` is the first thing every app open asks for. It
-- scanned the last 14 days of `events` for Trending, then — for a signed-in
-- viewer — `_for_you` scanned them again for Trending and 180 days of them for
-- each film's starts and completions. With 1,700 events that is 42 ms on
-- average (pg_stat_statements); it grows with every play, and every play
-- writes several events. 039 already counts "who watched both" once an hour
-- instead of on every request (`_maybe_refresh_cowatch`); this does the same
-- for the rest, every ten minutes, into one small table.
--
-- WHAT CHANGES FOR A VIEWER. Trending and Picked for you are at most ten
-- minutes behind instead of live. The order and the scores are computed by
-- the same expressions as before (`trending_title_ids`, the same counts).
--
-- One caller at a time refreshes, under an advisory lock; the others read
-- the previous ten minutes' table, as for the co-watch counts.

-- ─── The table ──────────────────────────────────────────────────────────
--
-- One row per title. `trend_rank` is `trending_title_ids(100)`'s rank (null:
-- not trending); `starts` and `completes` are distinct viewers over 180 days,
-- the `q` of `_for_you`. No policies: only security-definer functions read it.
create table if not exists public.title_heat (
  title_id  uuid primary key,
  trend_rank int,
  starts    int not null default 0,
  completes int not null default 0
);
alter table public.title_heat enable row level security;
revoke all on public.title_heat from anon, authenticated;

alter table public.reco_state add column if not exists heat_at timestamptz;

create or replace function public._refresh_heat()
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
declare stamp timestamptz := now();
begin
  if not pg_try_advisory_xact_lock(hashtext('innocent.heat')) then return; end if;
  -- Every title gets a row, so a title that fell out of Trending is set
  -- back to null rather than left at its old rank.
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
       group by e.title_id
    ) q on q.title_id = t.id
  on conflict (title_id) do update
     set trend_rank = excluded.trend_rank,
         starts     = excluded.starts,
         completes  = excluded.completes;
  update public.reco_state set heat_at = stamp where id = 1;
end;
$$;
revoke all on function public._refresh_heat() from public, anon, authenticated;

create or replace function public._maybe_refresh_heat()
returns void
language plpgsql
security definer
set search_path = 'public'
as $$
begin
  if coalesce((select heat_at from public.reco_state where id = 1), 'epoch')
       < now() - interval '10 minutes' then
    perform public._refresh_heat();
  end if;
end;
$$;
revoke all on function public._maybe_refresh_heat() from public, anon, authenticated;

-- ─── Picked for you: the counts and the heat from the table ─────────────
--
-- As 039, but `q` and `heat` read `title_heat`. A title with no events has
-- zeros there, which adds nothing to `qmean`'s sums — the same mean.
create or replace function public._for_you(p_keys text[], p_limit integer)
returns jsonb
language sql
stable
security definer
set search_path = 'public'
as $$
  with mine as (
    select w.title_id,
           max(least(1.0, coalesce(w.furthest_s::numeric / nullif(w.duration_s, 0), 0.2))
               * exp(-extract(epoch from (now() - w.last_at)) / 2592000.0)) as w,
           bool_or(w.finished) as finished
      from public._watch_state(p_keys) w group by w.title_id
  ), marked as (
    select b.title_id, 0.8::numeric as w from public.bookmarks b where b.user_id::text = any(p_keys)
  ), seeds as (
    select title_id, max(w) as w from (select title_id, w from mine union all select title_id, w from marked) s
     group by title_id order by max(w) desc limit 8
  ), taste as (
    select sc.title_id, sum(sd.w * sc.score) / nullif(sum(sd.w), 0) as v
      from seeds sd cross join lateral public._similar_scores(sd.title_id) sc group by sc.title_id
  ), q as (
    select h.title_id, h.starts::numeric as starts, h.completes::numeric as completes
      from public.title_heat h
  ), qmean as (select coalesce(sum(completes) / nullif(sum(starts), 0), 0.3) as m from q
  ), heat as (
    select h.title_id, 1.0 / h.trend_rank as v from public.title_heat h where h.trend_rank is not null
  ), cw as (select (c ->> 'id')::uuid as id from jsonb_array_elements(public._continue_watching(p_keys, 30)) c
  ), ranked as (
    select tt.id,
           0.45 * coalesce(ta.v, 0)
         + 0.25 * least(1.0, (coalesce(q.completes, 0) + 5 * qm.m) / (coalesce(q.starts, 0) + 5))
         + 0.20 * coalesce(h.v, 0)
         + 0.10 * exp(-extract(epoch from (now() - tt.created_at)) / 1209600.0) as score
      from public.titles tt
      join public.categories cat on cat.id = tt.category and cat.is_visible
      cross join qmean qm
      left join taste ta on ta.title_id = tt.id
      left join q on q.title_id = tt.id
      left join heat h on h.title_id = tt.id
     where tt.published and tt.category <> 'adult'
       and not exists (select 1 from mine m where m.title_id = tt.id and m.finished)
       and not exists (select 1 from cw where cw.id = tt.id)
  ), top as (select id, score from ranked order by score desc, id limit greatest(1, least(p_limit, 30)))
  select case when not exists (select 1 from seeds) then '[]'::jsonb
    else coalesce((select jsonb_agg(public._card(tt) order by top.score desc, tt.id)
                     from top join public.titles tt on tt.id = top.id), '[]'::jsonb) end;
$$;

-- ─── The landing page: refresh if due, Trending from the table ──────────
--
-- As 039, with `_maybe_refresh_heat()` beside the co-watch refresh and the
-- Trending row joined to `title_heat` instead of `trending_title_ids(20)`.
create or replace function public.landing_rows()
returns json
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  keys text[] := public._request_viewer_keys();
  cw   jsonb := '[]';
  fy   jsonb := '[]';
  byw  jsonb;
  rows jsonb := '[]';
begin
  perform public._maybe_refresh_cowatch();
  perform public._maybe_refresh_heat();
  if cardinality(keys) > 0 then
    cw  := public._continue_watching(keys, 20);
    fy  := public._for_you(keys, 20);
    byw := public._because_you_watched(keys, 20);
  end if;
  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'continue', 'title', 'Continue watching', 'title_mm', 'ဆက်ကြည့်ရန်',
    'default_sort', 'newest', 'ranked', false, 'personal', true, 'items', cw));
  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'trending', 'title', 'Trending', 'default_sort', 'popular', 'ranked', true,
    'items', (
      select coalesce(jsonb_agg(c order by rk nulls last, vc desc nulls last, id), '[]'::jsonb)
        from (select public._card(tt) as c, r.trend_rank as rk, tt.view_count as vc, tt.id
                from public.titles tt
                join public.categories cat on cat.id = tt.category and cat.is_visible
                left join public.title_heat r on r.title_id = tt.id and r.trend_rank <= 20
               where tt.published
               order by r.trend_rank nulls last, tt.view_count desc nulls last, tt.id
               limit 20) t)));
  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'for_you', 'title', 'Picked for you', 'title_mm', 'သင့်အတွက် ရွေးပေးထားတာ',
    'default_sort', 'popular', 'ranked', false, 'personal', true, 'items', fy));
  if byw is not null then
    rows := rows || jsonb_build_array(jsonb_build_object(
      'key', 'because:' || (byw -> 'seed' ->> 'id'),
      'title', 'Because you watched ' || (byw -> 'seed' ->> 'title'),
      'title_mm', coalesce(nullif(byw -> 'seed' ->> 'title_mm', ''), byw -> 'seed' ->> 'title') || ' ကြိုက်ရင်',
      'default_sort', 'popular', 'ranked', false, 'personal', true, 'items', byw -> 'items'));
  end if;
  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'newest', 'title', 'Recently added', 'default_sort', 'newest', 'ranked', false,
    'items', (
      select coalesce(jsonb_agg(c order by created_at desc), '[]'::jsonb)
        from (select public._card(tt) as c, tt.created_at
                from public.titles tt
                join public.categories cat on cat.id = tt.category and cat.is_visible
               where tt.published order by tt.created_at desc limit 20) t)));
  rows := rows || coalesce((
    select jsonb_agg(jsonb_build_object(
             'key', 'cat:' || c.id, 'title', c.label, 'title_mm', c.label_mm,
             'category', c.id, 'default_sort', 'newest', 'ranked', false,
             'items', (
               select coalesce(jsonb_agg(x.c order by x.created_at desc), '[]'::jsonb)
                 from (select public._card(tt) as c, tt.created_at from public.titles tt
                        where tt.published and tt.category = c.id
                        order by tt.created_at desc limit 20) x))
           order by c.sort_order, c.id)
      from public.categories c
     where c.is_visible and c.id not in ('all', 'adult')), '[]'::jsonb);
  return rows::json;
end;
$$;

-- Filled now, so the first app open after this does not do it.
select public._refresh_heat();
