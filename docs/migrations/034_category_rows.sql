-- 034 — the landing page shows a row for every category
--
-- Reported 2026-10-02: the Movies hub's "All" tab showed Trending and
-- Recently added and then nothing — an empty screen below two rows. It
-- should read Trending, Recently added, then one row per category (Movies,
-- Series, Reels, …), named as the categories table names them, so renaming a
-- category in the console renames its row.
--
-- `landing_rows()` only ever built the two. It now appends one row per
-- VISIBLE category except `all` (which is the landing tab itself) and
-- `adult` (never on a general listing), in `sort_order`, each carrying:
--
--   key       'cat:<id>'       stable, never the label
--   title     categories.label         the English heading
--   title_mm  categories.label_mm      the Burmese heading
--   category  <id>              the app titles the row from its LIVE category
--                               list and opens that tab on See all
--   items     the 20 newest published titles of that category
--
-- A category with no published title produces a row with no items, which the
-- app drops: no empty headings.
--
-- `row_catalogue(row_key)` (the See all list of a row) was never in a
-- migration — it was written in the SQL editor. It is defined here for the
-- first time, with the same behaviour as the one in the database (adult
-- excluded, 200 at most, popular first except for `newest`), and it also
-- answers `cat:<id>` keys, for a build that opens a category row's own list
-- instead of switching tabs.

create or replace function public.landing_rows()
returns json
language sql
stable
set search_path to 'public'
as $$
  select coalesce(json_agg(row_data order by ord, sub, rkey), '[]'::json) from (
    select 1 as ord, 0 as sub, 'trending' as rkey, json_build_object(
      'key', 'trending',
      'title', 'Trending',
      'default_sort', 'popular',
      'ranked', true,
      'items', (
        select coalesce(json_agg(t), '[]'::json) from (
          select tt.id, tt.title, tt.title_mm, tt.synopsis, tt.category,
                 tt.poster_url, tt.year, tt.rating, tt.quality_label,
                 tt.genres, tt.episode_count, tt.view_count, tt.access_tier,
                 tt.photo_count, tt.video_count
            from public.titles tt
            join public.categories c on c.id = tt.category and c.is_visible
            left join public.trending_title_ids(20) r on r.title_id = tt.id
           where tt.published
           order by r.rank nulls last, tt.view_count desc nulls last, tt.id
           limit 20
        ) t
      )
    ) as row_data
    union all
    select 2, 0, 'newest', json_build_object(
      'key', 'newest',
      'title', 'Recently added',
      'default_sort', 'newest',
      'ranked', false,
      'items', (
        select coalesce(json_agg(t), '[]'::json) from (
          select tt.id, tt.title, tt.title_mm, tt.synopsis, tt.category,
                 tt.poster_url, tt.year, tt.rating, tt.quality_label,
                 tt.genres, tt.episode_count, tt.view_count, tt.access_tier,
                 tt.photo_count, tt.video_count
            from public.titles tt
            join public.categories c on c.id = tt.category and c.is_visible
           where tt.published
           order by tt.created_at desc
           limit 20
        ) t
      )
    )
    union all
    select 3, c.sort_order, c.id, json_build_object(
      'key', 'cat:' || c.id,
      'title', c.label,
      'title_mm', c.label_mm,
      'category', c.id,
      'default_sort', 'newest',
      'ranked', false,
      'items', (
        select coalesce(json_agg(t), '[]'::json) from (
          select tt.id, tt.title, tt.title_mm, tt.synopsis, tt.category,
                 tt.poster_url, tt.year, tt.rating, tt.quality_label,
                 tt.genres, tt.episode_count, tt.view_count, tt.access_tier,
                 tt.photo_count, tt.video_count
            from public.titles tt
           where tt.published and tt.category = c.id
           order by tt.created_at desc
           limit 20
        ) t
      )
    )
      from public.categories c
     where c.is_visible and c.id not in ('all', 'adult')
  ) rows;
$$;

create or replace function public.row_catalogue(row_key text)
returns setof public.title_cards
language sql
stable
set search_path to 'public'
as $$
  select * from public.title_cards
   where category <> 'adult'
     and (row_key not like 'cat:%' or category = substr(row_key, 5))
   order by
     case when row_key = 'newest' or row_key like 'cat:%' then null
          else view_count end desc nulls last,
     title asc
   limit 200;
$$;

insert into public.schema_migrations (version, note)
values ('034', 'landing page: a row per visible category, titled from categories')
on conflict (version) do nothing;
