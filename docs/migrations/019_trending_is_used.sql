-- ===========================================================================
-- 019  THE RANKING THAT MEASURED SOMETHING FINALLY DECIDES SOMETHING
-- ===========================================================================
--
-- `trending_titles()` has existed since 014 and nothing has ever read it. The
-- landing page's "Trending" row was ordered by `view_count desc`, which cannot
-- tell a good film from good artwork: a title with a striking poster collects
-- the taps, and the row then recommends it to everybody else, and the row is
-- now measuring its own poster.
--
-- 014 said the switch-over would be "one line in landing_rows()" once there
-- were two weeks of events. There are events now — and looking at them says
-- the switch-over as described would have been WRONG. Fourteen days hold 32
-- plays across TWO titles, out of five published. Ranking five titles by a
-- signal that exists for two of them means three of them get an arbitrary
-- order dressed up as a measurement, which is worse than `view_count desc`
-- because it looks authoritative.
--
-- So this is not a switch. The measured order leads, for exactly the titles
-- that have evidence, and everything else follows by view count. With two
-- titles measured the row is barely different from today's; with two hundred
-- it is entirely driven by what people actually watch, and nothing has to be
-- changed in between. A ranking that improves as the catalogue grows, rather
-- than a flag somebody has to remember to flip.
--
--   heat        a play today counts double one from three days ago
--               (259200 seconds = a 72-hour half-life)
--   completion  plays that reached the end over plays that started
--   score       heat * (0.5 + completion)
--
-- The completion factor is the part that answers the poster problem: a title
-- with good artwork and a bad film gets the plays and loses the multiplier.

-- ---------------------------------------------------------------------------
-- 1. The ids, and NOTHING ELSE, readable by the app
-- ---------------------------------------------------------------------------
--
-- WHY A SECOND FUNCTION RATHER THAN CALLING trending_titles() DIRECTLY.
-- `trending_titles()` reads public.events, which anon cannot read and must
-- never be able to. A plain SQL function runs as the CALLER, so landing_rows()
-- calling it as anon would simply be refused — and the fix that suggests
-- itself, making landing_rows() security definer, would hand the whole of that
-- function's reach to an unauthenticated caller for ever.
--
-- This one is security definer and returns a title id and a position. No
-- timestamps, no device ids, no counts, no scores: everything it discloses is
-- already visible on the screen it feeds, which is the test for whether a
-- definer function is safe to grant.
create or replace function public.trending_title_ids(p_limit int default 20)
returns table (title_id uuid, rank int)
language sql
stable
security definer
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
  ), scored as (
    -- `heat > 0` IS THE EVIDENCE TEST. A title nobody played in a fortnight
    -- has no measured position, so it must not be given one — it falls through
    -- to the view-count ordering below instead of being ranked last on the
    -- strength of a zero.
    select w.title_id,
           coalesce(w.heat, 0) * (0.5 + coalesce(w.completion, 0)) as score
      from w
     where coalesce(w.heat, 0) > 0
  )
  select s.title_id,
         -- Tie-broken on the id so the order is STABLE between two calls.
         -- Without it, two titles with identical scores can swap places on a
         -- refresh, which reads as the app shuffling itself.
         (row_number() over (order by s.score desc, s.title_id))::int as rank
    from scored s
   order by rank
   limit greatest(1, least(p_limit, 100));
$fn$;

revoke all on function public.trending_title_ids(int) from public;
grant execute on function public.trending_title_ids(int) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. The landing page uses it
-- ---------------------------------------------------------------------------
create or replace function public.landing_rows()
returns json
language sql
stable
set search_path = public
as $fn$
  -- ORDERED. `union all` guarantees no order at all, so without the ordinal
  -- the landing page could put "Recently added" above "Trending" on one call
  -- and below it on the next - which reads as the app shuffling itself.
  select coalesce(json_agg(row_data order by ord), '[]'::json) from (
    select 1 as ord, json_build_object(
      'key', 'trending',
      'title', 'Trending',
      'default_sort', 'popular',
      'ranked', true,
      'items', (
        select coalesce(json_agg(t), '[]'::json) from (
          -- MEASURED FIRST, THEN POPULAR. The left join is what makes this a
          -- blend rather than a switch: a title with a measured position gets
          -- it, and a title without one keeps the only ordering there is any
          -- evidence for. See the note at the top for why a straight switch
          -- would have been wrong on this catalogue.
          select tt.id, tt.title, tt.title_mm, tt.synopsis, tt.category,
                 tt.poster_url, tt.year, tt.rating, tt.quality_label,
                 tt.genres, tt.episode_count, tt.view_count, tt.access_tier,
                 tt.photo_count, tt.video_count
            from public.titles tt
            left join public.trending_title_ids(20) r on r.title_id = tt.id
           where tt.published and tt.category <> 'adult'
           order by r.rank nulls last, tt.view_count desc nulls last, tt.id
           limit 20
        ) t
      )
    ) as row_data
    union all
    select 2 as ord, json_build_object(
      'key', 'newest',
      'title', 'Recently added',
      'default_sort', 'newest',
      'ranked', false,
      'items', (
        select coalesce(json_agg(t), '[]'::json) from (
          select id, title, title_mm, synopsis, category, poster_url,
                 year, rating, quality_label, genres, episode_count,
                 view_count, access_tier, photo_count, video_count
            from public.titles
           where published and category <> 'adult'
           order by created_at desc
           limit 20
        ) t
      )
    )
  ) rows;
$fn$;
