-- ===========================================================================
-- 020  ADDING A CATEGORY IS AN INSERT, NOT A RELEASE
-- ===========================================================================
--
-- 015 gave categories a table so the operator could RENAME and REORDER them
-- without shipping an app, and said plainly what it did not buy: a brand-new
-- category still needed a release. Three separate things stood in the way and
-- this migration removes the two that live in the database.
--
--   1. `titles_category_check` hard-coded ('movies','series','reels','adult'),
--      so a new id could not be stored at all. Replaced by a FOREIGN KEY to
--      public.categories: whatever is in that table is a category, and the
--      rule is now written once instead of twice.
--
--   2. `landing_rows()` filtered `category <> 'adult'` — a hard-coded name for
--      a category that no longer exists, and no rule at all for a category an
--      operator adds. Replaced by a join on `is_visible`, which means hiding a
--      category now hides its films from the front page as well as its tab.
--      That is what somebody setting that flag wants: they are taking a
--      section down, not renaming it.
--
-- The third is the app, which keys its tab bar off a compiled enum and is
-- handled separately. Until that ships, a new category stores and queries
-- correctly and simply has no tab of its own — which is a far better failure
-- than a refused INSERT.
--
-- `on update cascade` is insurance rather than a licence. Ids are meant to be
-- frozen, but if one is ever renamed the titles follow it instead of becoming
-- rows pointing at a category that no longer exists.
--
-- `on delete` is deliberately NO ACTION: deleting a category that titles still
-- use is refused, which is what stops an operator emptying a tab's worth of
-- films into a state nothing can query.

alter table public.titles drop constraint if exists titles_category_check;

-- 'all' is the landing TAB, not a category a title can belong to. The foreign
-- key would happily accept it, so this is the one thing the table cannot say
-- on its own.
alter table public.titles drop constraint if exists titles_category_not_all;
alter table public.titles
  add constraint titles_category_not_all check (category <> 'all');

alter table public.titles drop constraint if exists titles_category_fkey;
alter table public.titles
  add constraint titles_category_fkey
  foreign key (category) references public.categories(id)
  on update cascade;

-- So the foreign key check and the per-category grid are both cheap.
create index if not exists titles_category_idx on public.titles (category);

-- ---------------------------------------------------------------------------
-- The landing page honours visibility
-- ---------------------------------------------------------------------------
-- The foreign key above is what makes an INNER join safe here: every title's
-- category is now guaranteed to exist as a row, so the join can never silently
-- drop a film because of a typo in its category.
create or replace function public.landing_rows()
returns json
language sql
stable
set search_path = public
as $fn$
  select coalesce(json_agg(row_data order by ord), '[]'::json) from (
    select 1 as ord, json_build_object(
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
    select 2 as ord, json_build_object(
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
  ) rows;
$fn$;
