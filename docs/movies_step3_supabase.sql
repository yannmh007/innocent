-- ===========================================================================
-- Innocent Movies - Phase 1, Step 3: the titles table and its RLS
-- Written 31 Aug 2026 for v1.63.5+310.
--
-- HOW TO RUN THIS
--   Supabase dashboard -> SQL Editor -> New query -> paste the whole file ->
--   Run. It is safe to run twice: every statement is IF NOT EXISTS or
--   CREATE OR REPLACE.
--
-- WHERE THESE COLUMN NAMES COME FROM
--   Not from docs/client_api_contract.md, which was WRONG until 31 Aug 2026.
--   They are read off the constant the app actually sends:
--   lib/features/video_hub/data/api/api_content_repository.dart, _titleColumns.
--
--   PostgREST rejects the ENTIRE request if one name in `select` is unknown,
--   so a single missing column here means every catalogue call returns
--   HTTP 400 and the app shows an empty catalogue with no error - a failed
--   fetch and an empty catalogue look identical on screen. If the Movies tab
--   is blank after this, that is the first thing to check.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 1. THE CATALOGUE ROW
-- ---------------------------------------------------------------------------
-- Everything except id, title and category is nullable ON PURPOSE. Phase 1
-- enters rows by hand through the Table Editor, and a title must be able to go
-- live with four fields filled in. A NOT NULL column you have nothing to put in
-- is a column that stops you publishing.

create table if not exists public.titles (
  id             uuid primary key default gen_random_uuid(),

  title          text not null,
  title_mm       text,
  synopsis       text,

  -- The app reads: movies | series | reels | adult.
  -- Anything else is read by ContentCategoryX.fromId as its fallback, so the
  -- constraint is here to stop a typo silently filing a title under nothing.
  category       text not null default 'movies'
                 check (category in ('movies','series','reels','adult')),

  -- A PLAIN PUBLIC URL, not a key. resolveImageUrlSync() returns it only when
  -- it starts with http, and draws a placeholder otherwise. Posters live in
  -- the PUBLIC bucket; only the video is private.
  poster_url     text,

  year           int,
  rating         numeric(3,1),          -- 0.0 - 10.0, shown on the card corner
  quality_label  text,                  -- '4K' / 'HD' / 'CAM'
  genres         text[] default '{}',   -- filtered with genres=ov.{Action,Drama}
  episode_count  int,                   -- null for a single film

  -- "Most watched" orders by THIS. There is no `popularity` column; the old
  -- contract document invented one.
  view_count     int default 0,

  -- free | premium. AccessTierX.fromId reads ANYTHING ELSE AS PREMIUM, which
  -- is the correct direction: a typo hides a title (visible, recoverable)
  -- rather than giving it away (silent, expensive).
  access_tier    text not null default 'premium'
                 check (access_tier in ('free','premium')),

  -- NULLABLE AND LEFT NULL until they are really counted. The app draws
  -- nothing for null and draws "0" for zero, and a reader cannot tell an
  -- honest zero from an unfilled column. Only one of them is true.
  photo_count    int,
  video_count    int,

  -- Filtered by getFeatured(), never selected. It still has to exist.
  is_featured    boolean not null default false,

  -- ===== NOT VISIBLE TO THE APP =====================================
  -- The object PATH inside the private R2 bucket, e.g. 'v/9f2a1c.mp4'.
  -- NEVER a URL: a path lets old MP4 rows and future HLS rows coexist, and a
  -- URL would have to be rewritten a hundred times the day the domain changes.
  --
  -- It is excluded from the app's column list, and the RLS policy below is
  -- written so that even `select=*` cannot reach it. Only the playback
  -- function, which runs with the service role, ever reads it.
  locator        text,
  provider       text not null default 'r2',

  published      boolean not null default false,
  created_at     timestamptz not null default now()
);

-- Ordering and filtering the app actually does. Four small indexes now is
-- cheaper than diagnosing a slow grid later.
create index if not exists titles_category_idx  on public.titles (category);
create index if not exists titles_views_idx     on public.titles (view_count desc);
create index if not exists titles_year_idx      on public.titles (year desc);
create index if not exists titles_featured_idx  on public.titles (is_featured)
  where is_featured;
create index if not exists titles_genres_idx    on public.titles using gin (genres);


-- ---------------------------------------------------------------------------
-- 2. RLS - AND THE ONE THING IT CANNOT DO
-- ---------------------------------------------------------------------------
-- Row Level Security hides ROWS. It does not hide COLUMNS. So a policy alone
-- cannot stop `select=locator` - anyone with the anon key, which ships inside
-- the APK and is meant to, could read every media path.
--
-- Postgres column privileges CAN. The pattern below is the standard one:
--   * turn RLS on so only published rows are visible at all;
--   * then REVOKE every column from the anon and authenticated roles and GRANT
--     back exactly the fifteen the app asks for.
-- Two mechanisms, because they answer two different questions.

alter table public.titles enable row level security;

drop policy if exists "titles are readable when published" on public.titles;
create policy "titles are readable when published"
  on public.titles
  for select
  to anon, authenticated
  using (published = true);

-- No insert / update / delete policy exists, so nobody but the service role
-- can write. That is deliberate: rows are entered from the dashboard, which
-- uses the service role, and the app has no reason to write a title ever.

revoke all on public.titles from anon, authenticated;
grant select (
  id, title, title_mm, synopsis, category, poster_url,
  year, rating, quality_label, genres, episode_count, view_count,
  access_tier, photo_count, video_count, is_featured,
  -- ─── THESE TWO ARE NOT FOR THE APP. DO NOT REMOVE THEM. ───────────────
  -- The app never selects `published` or `created_at`, so the obvious tidy-up
  -- is to drop them from this list. That breaks EVERYTHING, and the error
  -- names neither column:
  --
  --   `permission denied for table titles`
  --
  -- `published` is read by the RLS policy itself. Postgres cannot decide
  -- whether a row is visible without reading the column the policy tests, and
  -- a role that may not read that column is refused the whole table - even for
  -- `select id, title`. The refusal is reported against the TABLE, so nothing
  -- in the message points at the policy or at this list.
  --
  -- `created_at` is what `landing_rows()` orders "Recently added" by. Without
  -- it the catalogue works and the app's HOME TAB is empty, which is worse:
  -- a total failure gets diagnosed, a partial one gets lived with.
  --
  -- Neither is a leak. `published` is true for every row the anon role can
  -- already see, and a creation timestamp reveals nothing the catalogue does
  -- not. The two that matter - `locator` and `provider` - are still absent,
  -- and that is what the proof block below checks.
  published, created_at
) on public.titles to anon, authenticated;

-- PROVE IT. Run each block below in the SQL Editor, in its own query.
--
-- Note the wording of a successful refusal: Postgres says
-- `permission denied for TABLE titles`, never "for column locator", even
-- though it is the column grant doing the work. Do not read the word "table"
-- as a sign that something broader is wrong.
--
--   -- 1. must ERROR
--   set role anon;
--   select locator from public.titles limit 1;
--
--   -- 2. must WORK
--   set role anon;
--   select id, title from public.titles limit 1;
--
--   -- 3. all four must run without error. This is the block that catches a
--   --    missing `created_at`, which the two above cannot see.
--   set role anon;
--   select public.landing_rows();
--   select count(*) from public.row_catalogue('trending');
--   select public.catalogue_facets(null, null);
--   reset role;
--
-- A policy you have not watched refuse something is not evidence of anything -
-- and a permission you have not watched ALLOW something is not either. Both
-- halves have to be run.


-- ---------------------------------------------------------------------------
-- 3. THE THREE RPCs THE APP CALLS
-- ---------------------------------------------------------------------------
-- All three are SECURITY INVOKER, so the RLS policy and the column grants
-- above still apply inside them. SECURITY DEFINER here would quietly bypass
-- both - which is exactly how a locator ends up in a response.

-- landing_rows: the "All" tab, in ONE round trip instead of five.
-- A cold start on a Myanmar mobile network is where round trips are paid for.
create or replace function public.landing_rows()
returns json
language sql
stable
security invoker
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
          select id, title, title_mm, synopsis, category, poster_url,
                 year, rating, quality_label, genres, episode_count,
                 view_count, access_tier, photo_count, video_count
          from public.titles
          where published and category <> 'adult'
          order by view_count desc nulls last
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

-- ---------------------------------------------------------------------------
-- THE SAFE PROJECTION, and why row_catalogue needs it
-- ---------------------------------------------------------------------------
-- getRowCatalogue() sends the row key AND the filter bar's parameters in the
-- same query string: `row_key=trending&year=eq.2024&order=view_count.desc`.
-- PostgREST applies anything that is not a function argument as a FILTER ON
-- THE RESULT. So the function's return type has to have real, filterable
-- columns.
--
-- `returns setof json` does not - the result is one scalar column, and
-- `year=eq.2024` against it fails with "column year does not exist". The
-- See-all screen would work until someone touched a filter chip.
--
-- `returns setof public.titles` would be filterable and WRONG: a function's
-- output rows are computed values, so the column grants above do not apply to
-- them, and `locator` would be selectable through the RPC. The one thing this
-- schema exists to prevent, reintroduced by a return type.
--
-- A view with exactly the sixteen safe columns is both. security_invoker keeps
-- the base table's RLS in force rather than running as the view's owner.
create or replace view public.title_cards
with (security_invoker = true)
as
  select id, title, title_mm, synopsis, category, poster_url,
         year, rating, quality_label, genres, episode_count,
         view_count, access_tier, photo_count, video_count, is_featured
  from public.titles
  where published;

grant select on public.title_cards to anon, authenticated;

-- row_catalogue: a row's See-all. It exists because a row may span categories
-- (Trending covers films, series and clips), which no column filter expresses.
create or replace function public.row_catalogue(row_key text)
returns setof public.title_cards
language sql
stable
security invoker
set search_path = public
as $fn$
  select * from public.title_cards
  where category <> 'adult'
  order by
    case when row_key = 'newest' then null else view_count end desc nulls last,
    title asc
  limit 200;
$fn$;

-- catalogue_facets: only offer a filter that can return something. A genre
-- with zero matches is the classic dead end - the user picks it, gets an empty
-- screen, and blames the app.
create or replace function public.catalogue_facets(
  category_filter text default null,
  row_key text default null
)
returns json
language sql
stable
security invoker
set search_path = public
as $fn$
  select json_build_object(
    'genres', coalesce((
      select json_agg(distinct g) from public.titles, unnest(genres) g
      where published
        and (category_filter is null or category = category_filter)
    ), '[]'::json),
    'years', coalesce((
      select json_agg(distinct year order by year desc) from public.titles
      where published and year is not null
        and (category_filter is null or category = category_filter)
    ), '[]'::json),
    'qualities', coalesce((
      select json_agg(distinct quality_label) from public.titles
      where published and quality_label is not null
        and (category_filter is null or category = category_filter)
    ), '[]'::json)
  );
$fn$;

-- record_view: one per viewer per title per day.
-- The app already de-dupes per SESSION, which only stops it inflating its own
-- numbers - not a user reopening the app six times.
create table if not exists public.title_views (
  title_id   uuid not null references public.titles(id) on delete cascade,
  viewer_key text not null,          -- auth.uid() when signed in, else x-install-id
  viewed_on  date not null default current_date,
  primary key (title_id, viewer_key, viewed_on)
);

alter table public.title_views enable row level security;
-- No policy at all: nobody reads this table through the API. The function
-- below is the only writer, and it is the one place SECURITY DEFINER is
-- correct, because counting a view is exactly the thing a viewer must be
-- allowed to do to a row they cannot otherwise touch.

create or replace function public.record_view(
  title_id uuid,
  viewer_tier text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  key text;
  inserted_rows int;
begin
  -- viewer_tier is accepted and IGNORED. It is a hint the client sends for the
  -- anonymous case; trusting it for anything would let a client name its own
  -- tier, which is the whole mistake this architecture exists to avoid.
  key := coalesce(
    auth.uid()::text,
    current_setting('request.headers', true)::json ->> 'x-install-id'
  );
  if key is null then return; end if;

  insert into public.title_views (title_id, viewer_key)
  values (record_view.title_id, key)
  on conflict do nothing;

  -- INT, NOT BOOLEAN. `get diagnostics x = row_count` yields an integer, and
  -- Postgres has no assignment cast from integer to boolean - a boolean
  -- variable here fails at RUN TIME, on the first view ever recorded, with
  -- "cannot cast type integer to boolean". It parses perfectly.
  get diagnostics inserted_rows = row_count;
  if inserted_rows > 0 then
    update public.titles set view_count = coalesce(view_count, 0) + 1
    where id = record_view.title_id;
  end if;
end;
$fn$;

grant execute on function public.landing_rows()              to anon, authenticated;
grant execute on function public.row_catalogue(text)         to anon, authenticated;
grant execute on function public.catalogue_facets(text,text) to anon, authenticated;
grant execute on function public.record_view(uuid,text)      to anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. ONE TEST ROW
-- ---------------------------------------------------------------------------
-- Free, so it plays before any of the payment machinery exists. Prove the
-- pipe carries water before deciding who is allowed to drink.
--
-- Fill poster_url and locator in with your real values, then set published.

insert into public.titles (title, category, access_tier, poster_url, locator, published)
select 'First test title', 'movies', 'free',
       'https://REPLACE-with-your-public-bucket/poster1.jpg',
       'v/first-test.mp4',
       true
where not exists (select 1 from public.titles where title = 'First test title');
