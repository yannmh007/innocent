-- 039 — the landing page learns who is looking
--
-- Owner request (2026-10-05): the Movies hub should work the way people
-- already know from Netflix and YouTube, with the algorithms on the SERVER
-- so they can be tuned without an app release. docs/movies_personalisation.md
-- has the research; this is what it turned into.
--
-- What the hub showed before: Trending, Recently added, a row per category —
-- the same page for everybody, and a film reopened from the start every time
-- (the app never wrote a stream's position down; see player_provider.dart
-- `_isEphemeral`). Every serious platform puts two things at the top that
-- this did not have:
--
--   Continue watching   Netflix's most used row (Gomez-Uribe & Hunt 2015):
--                       what you started and did not finish, newest first,
--                       with where you stopped. Android's Engage SDK makes
--                       the same row a platform feature ("Continuation").
--   For you            a ranking of the catalogue for THIS viewer: what they
--                       watch, weighted by how much of it they watched —
--                       watch time, not clicks, because ranking on clicks
--                       promotes what people open and abandon (Covington et
--                       al. 2016, YouTube).
--
-- Plus "Because you watched X" (Netflix's BYW row) and `similar_titles()`
-- for the detail page's "More like this".
--
-- EVERYTHING IS BUILT FROM `events`, which the app already sends:
-- play_progress every 30 s with position and duration, a final event with the
-- furthest point, play_complete at 90 %, detail_view, bookmark_add. Nothing
-- new is collected. The viewer is the request's own: auth.uid() when signed
-- in, the install id otherwise, and both on a signed-in phone (the history
-- from before signing in is the same person's). There is no argument naming
-- a viewer, so no caller can read another viewer's rows.
--
-- SMALL-CATALOGUE HONESTY. Ten titles and a dozen viewers today. Item-to-item
-- co-watching ("people who watched X watched Y") means nothing at that size,
-- so similarity leans on what a title IS (category, genres, keywords) and the
-- co-watch term only grows as there are viewers behind it. Global quality is
-- a Bayesian-smoothed completion rate (five imaginary viewings at the
-- catalogue's average), so one person finishing a title does not make it the
-- best thing in the catalogue. A viewer with no history gets no personal row
-- at all — Trending is the honest answer for them, not a fake "for you".
--
-- Adult titles never appear on these rows (as on every general listing): a
-- Continue watching row is on the first screen, where anybody glancing at
-- the phone sees it.

-- ===========================================================================
-- 0. A new event: "remove from Continue watching"
-- ===========================================================================
insert into public.event_kinds (kind)
values ('cw_remove')
on conflict (kind) do nothing;

-- ===========================================================================
-- 1. Who is asking
-- ===========================================================================
create or replace function public._request_viewer_keys()
returns text[]
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(array_remove(array[
           auth.uid()::text,
           nullif(nullif(current_setting('request.headers', true), '')::json
                    ->> 'x-install-id', '')
         ], null), '{}'::text[]);
$$;

-- ===========================================================================
-- 2. Where each viewing stands
-- ===========================================================================
-- One row per (title, clip) the viewer has played in the last 120 days:
-- where they are (the latest progress point), the furthest they got, the
-- length, when, and whether it is finished. "Finished" is the latest
-- viewing's: a film finished in March and restarted today is in progress.
create or replace function public._watch_state(p_keys text[])
returns table (
  title_id uuid, asset_id uuid, position_s int, furthest_s int,
  duration_s int, last_at timestamptz, finished boolean, removed boolean
)
language sql
stable
security definer
set search_path to 'public'
as $$
  with ev as (
    select e.title_id, e.asset_id, e.kind, e.position_s, e.duration_s,
           e.occurred_at
      from public.events e
     where e.viewer_key = any(p_keys)
       and e.title_id is not null
       and e.occurred_at > now() - interval '120 days'
       and e.kind in ('play_progress', 'play_complete', 'cw_remove')
  ), plays as (
    select * from ev where kind <> 'cw_remove'
  ), latest as (
    select distinct on (title_id, asset_id)
           title_id, asset_id, kind, position_s, occurred_at
      from plays
     order by title_id, asset_id, occurred_at desc
  ), agg as (
    select title_id, asset_id,
           max(position_s) as furthest_s,
           max(duration_s) as duration_s,
           max(occurred_at) as last_at
      from plays
     group by title_id, asset_id
  )
  select a.title_id, a.asset_id, l.position_s, a.furthest_s, a.duration_s,
         a.last_at,
         l.kind = 'play_complete'
           or (a.duration_s > 0 and l.position_s >= a.duration_s * 0.92)
           as finished,
         exists (select 1 from ev r
                  where r.kind = 'cw_remove' and r.title_id = a.title_id
                    and r.occurred_at > a.last_at) as removed
    from agg a join latest l using (title_id, asset_id);
$$;

revoke all on function public._watch_state(text[]) from public, anon, authenticated;
revoke all on function public._request_viewer_keys() from public, anon, authenticated;

-- What a client asks for itself: its own viewings (the app keeps a copy for
-- the resume point, so a film reopens where it stopped on another phone too).
create or replace function public.my_watch_state()
returns table (
  title_id uuid, asset_id uuid, position_s int, duration_s int,
  last_at timestamptz, finished boolean
)
language sql
stable
security definer
set search_path to 'public'
as $$
  select w.title_id, w.asset_id, w.position_s, w.duration_s, w.last_at,
         w.finished
    from public._watch_state(public._request_viewer_keys()) w
   order by w.last_at desc
   limit 200;
$$;

grant execute on function public.my_watch_state() to anon, authenticated;

-- ===========================================================================
-- 3. A title as a card, the one shape every row hands out
-- ===========================================================================
create or replace function public._card(tt public.titles)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'id', tt.id, 'title', tt.title, 'title_mm', tt.title_mm,
    'synopsis', tt.synopsis, 'category', tt.category,
    'poster_url', tt.poster_url, 'year', tt.year, 'rating', tt.rating,
    'quality_label', tt.quality_label, 'genres', tt.genres,
    'episode_count', tt.episode_count, 'view_count', tt.view_count,
    'access_tier', tt.access_tier, 'photo_count', tt.photo_count,
    'video_count', tt.video_count);
$$;

-- ===========================================================================
-- 4. Continue watching
-- ===========================================================================
-- Started, not finished, not removed, touched in the last 60 days, one card
-- per title (its most recent clip), newest first. "Started" means past the
-- first 30 s or 3 %: a film opened by mistake is not something to continue.
-- Each card carries where to resume: `resume` = {asset_id, position_s,
-- duration_s}.
create or replace function public._continue_watching(p_keys text[], p_limit int)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(jsonb_agg(c order by last_at desc), '[]'::jsonb) from (
    select c, last_at from (
      select distinct on (w.title_id)
             public._card(tt) || jsonb_build_object('resume', jsonb_build_object(
               'asset_id', w.asset_id, 'position_s', w.position_s,
               'duration_s', w.duration_s)) as c,
             w.last_at
        from public._watch_state(p_keys) w
        join public.titles tt on tt.id = w.title_id and tt.published
        join public.categories cat on cat.id = tt.category and cat.is_visible
       where not w.finished and not w.removed
         and tt.category <> 'adult'
         and w.last_at > now() - interval '60 days'
         and w.position_s >= greatest(30, coalesce(w.duration_s, 0) * 0.03)
       order by w.title_id, w.last_at desc
    ) d
    order by last_at desc
    limit greatest(1, least(p_limit, 30))
  ) x;
$$;

revoke all on function public._continue_watching(text[], int) from public, anon, authenticated;

-- ===========================================================================
-- 5. How alike two titles are
-- ===========================================================================
-- What they ARE, and — once there are viewers enough to mean anything — who
-- watched both. Each term is 0..1:
--
--   genre    Jaccard overlap of the genre lists              weight 0.40
--   kind     same category                                   weight 0.25
--   words    Jaccard overlap of the keywords                 weight 0.15
--   cowatch  viewers who got 20 %+ into both, over those      weight 0.20
--            into either, shrunk by n/(n+10) so two people
--            are a hint and fifty are evidence
create or replace function public._jaccard(a text[], b text[])
returns numeric
language sql
immutable
as $$
  select case
    when coalesce(cardinality(a), 0) = 0 or coalesce(cardinality(b), 0) = 0
      then 0
    else (select count(*) from (select lower(x) from unnest(a) x
                                intersect select lower(y) from unnest(b) y) i)::numeric
       / nullif((select count(*) from (select lower(x) from unnest(a) x
                                       union select lower(y) from unnest(b) y) u), 0)
  end;
$$;

-- Who watched both is counted once an hour into two small tables, not on
-- every request: every page load scanning the whole event log for every seed
-- title costs nothing with 400 events and seconds with 400,000. The project
-- has no pg_cron, so the landing page refreshes them itself when they are
-- over an hour old (`_maybe_refresh_cowatch`, one caller at a time under an
-- advisory lock; the others read the previous hour's counts). Stale pairs are
-- set to zero rather than deleted.
create table if not exists public.title_cowatch (
  a uuid not null, b uuid not null, both_n int not null, primary key (a, b));
create table if not exists public.title_reach (title_id uuid primary key, n int not null);
create table if not exists public.reco_state (
  id int primary key default 1, cowatch_at timestamptz,
  constraint reco_state_one_row check (id = 1));
insert into public.reco_state (id) values (1) on conflict (id) do nothing;
-- No policies: only the security-definer functions below read them.
alter table public.title_cowatch enable row level security;
alter table public.title_reach enable row level security;
alter table public.reco_state enable row level security;

create or replace function public._refresh_cowatch()
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare stamp timestamptz := now();
begin
  if not pg_try_advisory_xact_lock(hashtext('innocent.cowatch')) then return; end if;
  -- who got at least 20 % into what, last 180 days
  with engaged as (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete'
            or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
  ), pairs as (
    select x.title_id as a, y.title_id as b, count(*)::int as n
      from engaged x join engaged y
        on y.viewer_key = x.viewer_key and y.title_id <> x.title_id
     group by 1, 2
  )
  insert into public.title_cowatch (a, b, both_n)
  select a, b, n from pairs
  on conflict (a, b) do update set both_n = excluded.both_n;

  with engaged as (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete'
            or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
  ), pairs as (
    select x.title_id as a, y.title_id as b
      from engaged x join engaged y
        on y.viewer_key = x.viewer_key and y.title_id <> x.title_id
     group by 1, 2
  )
  update public.title_cowatch c set both_n = 0
   where c.both_n <> 0
     and not exists (select 1 from pairs p where p.a = c.a and p.b = c.b);

  insert into public.title_reach (title_id, n)
  select title_id, count(*)::int from (
    select distinct e.viewer_key, e.title_id from public.events e
     where e.occurred_at > now() - interval '180 days'
       and e.kind in ('play_progress', 'play_complete') and e.title_id is not null
       and (e.kind = 'play_complete'
            or (e.duration_s > 0 and e.position_s >= e.duration_s * 0.2))
  ) g group by 1
  on conflict (title_id) do update set n = excluded.n;

  update public.reco_state set cowatch_at = stamp where id = 1;
end;
$$;

create or replace function public._maybe_refresh_cowatch()
returns void
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
begin
  if coalesce((select cowatch_at from public.reco_state where id = 1), 'epoch')
       < now() - interval '1 hour' then
    perform public._refresh_cowatch();
  end if;
end;
$$;

revoke all on function public._refresh_cowatch() from public, anon, authenticated;
revoke all on function public._maybe_refresh_cowatch() from public, anon, authenticated;

create or replace function public._similar_scores(p_title uuid)
returns table (title_id uuid, score numeric)
language sql
stable
security definer
set search_path to 'public'
as $$
  select t.id,
         0.40 * public._jaccard(t.genres, s.genres)
       + 0.25 * (t.category = s.category)::int
       + 0.15 * public._jaccard(t.keywords, s.keywords)
       + 0.20 * coalesce(co.both_n::numeric / nullif(ra.n + rb.n - co.both_n, 0)
                         * (co.both_n::numeric / (co.both_n + 10)), 0)
    from public.titles t
    join public.titles s on s.id = p_title
    left join public.title_cowatch co on co.a = p_title and co.b = t.id
    left join public.title_reach ra on ra.title_id = p_title
    left join public.title_reach rb on rb.title_id = t.id
   where t.published and t.id <> p_title;
$$;

revoke all on function public._similar_scores(uuid) from public, anon, authenticated;

-- "More like this" on a title's page. Public: it says nothing about anyone.
-- An adult title's neighbours may be adult; anything else's never are.
create or replace function public.similar_titles(p_title uuid, p_limit int default 12)
returns setof public.title_cards
language sql
stable
security definer
set search_path to 'public'
as $$
  select c.*
    from public._similar_scores(p_title) s
    join public.title_cards c on c.id = s.title_id
    join public.categories cat on cat.id = c.category and cat.is_visible
   where s.score > 0.05
     and (c.category <> 'adult'
          or (select category from public.titles where id = p_title) = 'adult')
   order by s.score desc, c.view_count desc nulls last, c.id
   limit greatest(1, least(p_limit, 30));
$$;

grant execute on function public.similar_titles(uuid, int) to anon, authenticated;

-- ===========================================================================
-- 6. Trending: watch time from distinct people, decaying
-- ===========================================================================
-- Was: play_start events, decayed over 3 days, times (0.5 + completion). One
-- person replaying a title ten times counted ten times, and a title opened
-- and closed at once counted as much as one watched to the end.
--
-- Now each (viewer, title) counts once, weighted by how much of it they
-- watched (0.3 for pressing Play at all, up to 1.0 for the whole film — the
-- YouTube lesson: watch time, not clicks), decaying with a 3-day e-fold from
-- their last viewing.
create or replace function public.trending_title_ids(p_limit integer default 20)
returns table (title_id uuid, rank integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  with per_viewer as (
    select e.title_id, e.viewer_key,
           max(e.occurred_at) as last_at,
           max(case
                 when e.kind = 'play_complete' then 1.0
                 when e.duration_s > 0
                   then least(1.0, e.position_s::numeric / e.duration_s)
                 else 0
               end) as watched
      from public.events e
     where e.title_id is not null
       and e.occurred_at > now() - interval '14 days'
       and e.kind in ('play_start', 'play_progress', 'play_complete')
     group by e.title_id, e.viewer_key
  ), scored as (
    select title_id,
           sum(exp(-extract(epoch from (now() - last_at)) / 259200.0)
               * (0.3 + 0.7 * watched)) as score
      from per_viewer
     group by title_id
  )
  select s.title_id,
         (row_number() over (order by s.score desc, s.title_id))::int
    from scored s
   where s.score > 0
   order by 2
   limit greatest(1, least(p_limit, 100));
$$;

-- ===========================================================================
-- 7. For you
-- ===========================================================================
-- A ranking of the catalogue for this viewer, by four terms (each 0..1):
--
--   taste     how close the title is to what they watched, each past viewing
--             weighted by how much of it they watched and fading over 30
--             days, a bookmark counting as a strong viewing        0.45
--   quality   completion rate, Bayesian-smoothed: (completes + 5·mean) /
--             (starts + 5), so a title is not "best" on one viewer   0.25
--   heat      Trending's score, as a fraction of the top title's    0.20
--   fresh     added recently (14-day e-fold)                         0.10
--
-- Finished titles and titles in Continue watching are left out (they are
-- either done or already one row up). Nothing at all for a viewer with no
-- history: For you would be Trending with a different heading, and saying so
-- would be a lie.
create or replace function public._for_you(p_keys text[], p_limit int)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with mine as (
    select w.title_id,
           max(least(1.0, coalesce(w.furthest_s::numeric / nullif(w.duration_s, 0), 0.2))
               * exp(-extract(epoch from (now() - w.last_at)) / 2592000.0)) as w,
           bool_or(w.finished) as finished
      from public._watch_state(p_keys) w
     group by w.title_id
  ), marked as (
    select b.title_id, 0.8::numeric as w
      from public.bookmarks b
     where b.user_id::text = any(p_keys)
  ), seeds as (
    -- the eight strongest: a long history is summarised by its recent core,
    -- and each seed is one similarity pass over the catalogue
    select title_id, max(w) as w from (
      select title_id, w from mine union all select title_id, w from marked
    ) s group by title_id
    order by max(w) desc limit 8
  ), taste as (
    select sc.title_id, sum(sd.w * sc.score) / nullif(sum(sd.w), 0) as v
      from seeds sd
      cross join lateral public._similar_scores(sd.title_id) sc
     group by sc.title_id
  ), q as (
    select e.title_id,
           count(distinct e.viewer_key) filter (where e.kind = 'play_start')::numeric as starts,
           count(distinct e.viewer_key) filter (where e.kind = 'play_complete')::numeric as completes
      from public.events e
     where e.title_id is not null and e.kind in ('play_start', 'play_complete')
       and e.occurred_at > now() - interval '180 days'
     group by e.title_id
  ), qmean as (
    select coalesce(sum(completes) / nullif(sum(starts), 0), 0.3) as m from q
  ), heat as (
    select title_id, 1.0 / rank as v from public.trending_title_ids(100)
  ), cw as (
    select (c ->> 'id')::uuid as id
      from jsonb_array_elements(public._continue_watching(p_keys, 30)) c
  ), ranked as (
    select tt.id,
           0.45 * coalesce(ta.v, 0)
         + 0.25 * least(1.0, (coalesce(q.completes, 0) + 5 * qm.m)
                             / (coalesce(q.starts, 0) + 5))
         + 0.20 * coalesce(h.v, 0)
         + 0.10 * exp(-extract(epoch from (now() - tt.created_at)) / 1209600.0)
           as score
      from public.titles tt
      join public.categories cat on cat.id = tt.category and cat.is_visible
      cross join qmean qm
      left join taste ta on ta.title_id = tt.id
      left join q on q.title_id = tt.id
      left join heat h on h.title_id = tt.id
     where tt.published
       and tt.category <> 'adult'
       and not exists (select 1 from mine m where m.title_id = tt.id and m.finished)
       and not exists (select 1 from cw where cw.id = tt.id)
  ), top as (
    select id, score from ranked order by score desc, id
     limit greatest(1, least(p_limit, 30))
  )
  select case
    when not exists (select 1 from seeds) then '[]'::jsonb
    else coalesce((
      select jsonb_agg(public._card(tt) order by top.score desc, tt.id)
        from top join public.titles tt on tt.id = top.id
    ), '[]'::jsonb)
  end;
$$;

revoke all on function public._for_you(text[], int) from public, anon, authenticated;

-- "Because you watched X": X is the most recent title they got 20 %+ into.
create or replace function public._because_you_watched(p_keys text[], p_limit int)
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with seed as (
    select w.title_id
      from public._watch_state(p_keys) w
      join public.titles tt on tt.id = w.title_id and tt.published
     where tt.category <> 'adult'
       and (w.finished
            or (w.duration_s > 0 and w.furthest_s >= w.duration_s * 0.2))
     order by w.last_at desc
     limit 1
  ), done as (
    select title_id from public._watch_state(p_keys) where finished
  )
  select case when not exists (select 1 from seed) then null else
    jsonb_build_object(
      'seed', (select public._card(t) from public.titles t
                where t.id = (select title_id from seed)),
      'items', coalesce((
        select jsonb_agg(public._card(t) order by s.score desc, t.id)
          from (select sc.title_id, sc.score
                  from public._similar_scores((select title_id from seed)) sc
                 where sc.score > 0.1
                   and sc.title_id not in (select title_id from done)
                 order by sc.score desc
                 limit greatest(1, least(p_limit, 20))) s
          join public.titles t on t.id = s.title_id
          join public.categories cat on cat.id = t.category and cat.is_visible
         where t.category <> 'adult'
      ), '[]'::jsonb))
  end;
$$;

revoke all on function public._because_you_watched(text[], int) from public, anon, authenticated;

-- ===========================================================================
-- 8. The landing page, with the viewer's rows on top
-- ===========================================================================
-- Same contract as before (an array of {key, title, title_mm, items, …}); an
-- app that does not know a row's key draws it from `title` / `title_mm` like
-- any other, so the new rows reach the app already installed. Order, as
-- Netflix and YouTube put it: Continue watching, Trending, For you, Because
-- you watched X, Recently added, then the categories. A row with no items is
-- dropped by the app.
-- VOLATILE, not stable: it may refresh the co-watch counts (above). The app
-- calls it by POST, which PostgREST runs read-write for a volatile function.
create or replace function public.landing_rows()
returns json
language plpgsql
volatile
security definer
set search_path to 'public'
as $$
declare
  keys text[] := public._request_viewer_keys();
  cw   jsonb := '[]';
  fy   jsonb := '[]';
  byw  jsonb;
  rows jsonb := '[]';
begin
  perform public._maybe_refresh_cowatch();
  if cardinality(keys) > 0 then
    cw  := public._continue_watching(keys, 20);
    fy  := public._for_you(keys, 20);
    byw := public._because_you_watched(keys, 20);
  end if;

  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'continue', 'title', 'Continue watching',
    'title_mm', 'ဆက်ကြည့်ရန်', 'default_sort', 'newest', 'ranked', false,
    'personal', true, 'items', cw));

  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'trending', 'title', 'Trending', 'default_sort', 'popular',
    'ranked', true,
    'items', (
      select coalesce(jsonb_agg(c order by rk nulls last, vc desc nulls last, id), '[]'::jsonb)
        from (select public._card(tt) as c, r.rank as rk, tt.view_count as vc, tt.id
                from public.titles tt
                join public.categories cat on cat.id = tt.category and cat.is_visible
                left join public.trending_title_ids(20) r on r.title_id = tt.id
               where tt.published
               order by r.rank nulls last, tt.view_count desc nulls last, tt.id
               limit 20) t)));

  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'for_you', 'title', 'Picked for you',
    'title_mm', 'သင့်အတွက် ရွေးပေးထားတာ', 'default_sort', 'popular',
    'ranked', false, 'personal', true, 'items', fy));

  if byw is not null then
    rows := rows || jsonb_build_array(jsonb_build_object(
      'key', 'because:' || (byw -> 'seed' ->> 'id'),
      'title', 'Because you watched ' || (byw -> 'seed' ->> 'title'),
      'title_mm', coalesce(nullif(byw -> 'seed' ->> 'title_mm', ''),
                           byw -> 'seed' ->> 'title') || ' ကြိုက်ရင်',
      'default_sort', 'popular', 'ranked', false, 'personal', true,
      'items', byw -> 'items'));
  end if;

  rows := rows || jsonb_build_array(jsonb_build_object(
    'key', 'newest', 'title', 'Recently added', 'default_sort', 'newest',
    'ranked', false,
    'items', (
      select coalesce(jsonb_agg(c order by created_at desc), '[]'::jsonb)
        from (select public._card(tt) as c, tt.created_at
                from public.titles tt
                join public.categories cat on cat.id = tt.category and cat.is_visible
               where tt.published
               order by tt.created_at desc limit 20) t)));

  rows := rows || coalesce((
    select jsonb_agg(jsonb_build_object(
             'key', 'cat:' || c.id, 'title', c.label, 'title_mm', c.label_mm,
             'category', c.id, 'default_sort', 'newest', 'ranked', false,
             'items', (
               select coalesce(jsonb_agg(x.c order by x.created_at desc), '[]'::jsonb)
                 from (select public._card(tt) as c, tt.created_at
                         from public.titles tt
                        where tt.published and tt.category = c.id
                        order by tt.created_at desc limit 20) x))
           order by c.sort_order, c.id)
      from public.categories c
     where c.is_visible and c.id not in ('all', 'adult')), '[]'::jsonb);

  return rows::json;
end;
$$;

grant execute on function public.landing_rows() to anon, authenticated;

-- "See all" on a personal row: the same ranking, longer.
create or replace function public.row_catalogue(row_key text)
returns setof public.title_cards
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  keys text[] := public._request_viewer_keys();
  ids  uuid[];
begin
  if row_key = 'continue' then
    select array_agg((c ->> 'id')::uuid) into ids
      from jsonb_array_elements(public._continue_watching(keys, 30)) c;
  elsif row_key = 'for_you' then
    select array_agg((c ->> 'id')::uuid) into ids
      from jsonb_array_elements(public._for_you(keys, 30)) c;
  elsif row_key like 'because:%' then
    select array_agg(s.title_id order by s.score desc) into ids
      from (select sc.title_id, sc.score
              from public._similar_scores(substr(row_key, 9)::uuid) sc
             where sc.score > 0.1
             order by sc.score desc limit 30) s;
  end if;

  if ids is not null then
    return query
      select c.* from public.title_cards c
        join unnest(ids) with ordinality u(id, n) on u.id = c.id
       where c.category <> 'adult'
       order by u.n;
    return;
  end if;
  if row_key in ('continue', 'for_you') or row_key like 'because:%' then
    return;
  end if;

  return query
    select * from public.title_cards
     where category <> 'adult'
       and (row_key not like 'cat:%' or category = substr(row_key, 5))
     order by
       case when row_key = 'newest' or row_key like 'cat:%' then null
            else view_count end desc nulls last,
       title asc
     limit 200;
end;
$$;

grant execute on function public.row_catalogue(text) to anon, authenticated;

-- Applied 2026-10-05 by first creating landing_rows_v039, row_catalogue_v039
-- and trending_title_ids_v039 to test them against the live data, then
-- replacing the real ones. Those three are left in the database with every
-- grant revoked (the SQL tool asks for a confirmation on DROP that it cannot
-- give); remove them from the SQL editor:
--   drop function if exists public.landing_rows_v039();
--   drop function if exists public.row_catalogue_v039(text);
--   drop function if exists public.trending_title_ids_v039(integer);
insert into public.schema_migrations (version, note)
values ('039', 'personal rows: continue watching, for you, because you watched, similar titles, watch-time trending, hourly co-watch')
on conflict (version) do nothing;
