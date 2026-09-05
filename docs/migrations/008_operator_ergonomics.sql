-- ===========================================================================
-- 008 — two lines per film instead of three screens
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
--
-- WHAT THIS CHANGES
--   Today one film costs three places: add_title in SQL, then the Table Editor
--   for the metadata, then the status field. A hundred films is three hundred
--   trips, on a phone. Most of the mistakes in a catalogue this size come from
--   the trips, not from the data.
--
--   After this: one call to describe the film, one to publish it. The Table
--   Editor becomes optional - useful for fixing one field, not required for
--   every title.
-- ===========================================================================

-- The signature changes, so the old one must go first. CREATE OR REPLACE with
-- different parameters makes an OVERLOAD rather than a replacement, and then
-- every four-argument call becomes ambiguous and fails.
drop function if exists public.add_title(text,text,text[],text[],text,text);

create or replace function public.add_title(
  p_slug     text,
  p_title    text,
  p_videos   text[] default '{}',
  p_photos   text[] default '{}',
  p_category text default 'movies',
  p_tier     text default 'free',
  -- Metadata, all optional. Passing null leaves an existing value alone, so a
  -- re-run to add one more clip never wipes the synopsis someone typed.
  p_title_mm text default null,
  p_synopsis text default null,
  p_year     int  default null,
  p_genres   text[] default null,
  p_quality  text default null,
  p_episodes int  default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  tid uuid;
begin
  select id into tid from public.titles where slug = p_slug;

  if tid is null then
    insert into public.titles (slug, title, category, access_tier, status, published)
    values (p_slug, p_title, p_category, p_tier, 'draft', false)
    returning id into tid;
  end if;

  -- coalesce(new, old): every field is optional on a re-run. This is what
  -- makes the function safe to call again with a longer file list.
  update public.titles set
    title         = coalesce(p_title, title),
    title_mm      = coalesce(p_title_mm, title_mm),
    synopsis      = coalesce(p_synopsis, synopsis),
    year          = coalesce(p_year, year),
    genres        = coalesce(p_genres, genres),
    quality_label = coalesce(p_quality, quality_label),
    episode_count = coalesce(p_episodes, episode_count),
    category      = coalesce(p_category, category),
    access_tier   = coalesce(p_tier, access_tier)
  where id = tid;

  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  select tid, 'video', 'innocent-media', p_slug || '/' || f.name, f.ord
  from unnest(p_videos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  select tid, 'photo', 'innocent-public', p_slug || '/' || f.name, f.ord
  from unnest(p_photos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  -- Only when nothing is primary yet: never overrides a poster chosen by hand.
  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'video' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets where title_id = tid
                 and kind = 'video' order by sort_order, added_at limit 1);
  end if;

  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'photo' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets where title_id = tid
                 and kind = 'photo' order by sort_order, added_at limit 1);
  end if;

  return tid;
end;
$fn$;


-- ---------------------------------------------------------------------------
-- publish_title — and it REFUSES to publish something broken
-- ---------------------------------------------------------------------------
-- The failure this prevents: a title with no video, or whose `locator` points
-- at a filename that does not exist, looks perfect in the catalogue and dies
-- on Play. Nobody finds out until a viewer complains, by which time ninety
-- more have been uploaded the same way.
--
-- This cannot check that the FILE exists in R2 - nothing in the database can.
-- It checks everything that is checkable, which is most of it.
create or replace function public.publish_title(p_slug text)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
declare
  t record;
  problems text[] := '{}';
begin
  select * into t from public.titles where slug = p_slug;
  if t is null then
    return 'NOT FOUND: no title with slug ' || p_slug;
  end if;

  if t.locator is null or t.locator = '' then
    problems := problems || 'no video (locator is empty)';
  end if;
  if t.poster_url is null or t.poster_url = '' then
    problems := problems || 'no poster';
  end if;
  if not exists (select 1 from public.title_assets
                 where title_id = t.id and kind = 'video') then
    problems := problems || 'no video asset rows';
  end if;
  if t.title is null or t.title = '' then
    problems := problems || 'no title text';
  end if;

  if array_length(problems, 1) > 0 then
    return 'REFUSED: ' || array_to_string(problems, '; ');
  end if;

  update public.titles set status = 'published' where id = t.id;
  return 'PUBLISHED: ' || t.title || '  ->  ' || t.locator;
end;
$fn$;

create or replace function public.unpublish_title(p_slug text)
returns text
language plpgsql
security definer
set search_path = public
as $fn$
begin
  update public.titles set status = 'hidden' where slug = p_slug;
  if not found then return 'NOT FOUND: ' || p_slug; end if;
  return 'HIDDEN: ' || p_slug;
end;
$fn$;


-- ---------------------------------------------------------------------------
-- catalogue_health — one saved query, run before every publish
-- ---------------------------------------------------------------------------
create or replace view public.catalogue_health as
  select t.slug, t.title, t.status,
         count(*) filter (where a.kind = 'video') as videos,
         count(*) filter (where a.kind = 'photo') as photos,
         t.locator,
         (t.poster_url is not null)               as has_poster,
         case
           when t.locator is null then 'NO VIDEO'
           when t.poster_url is null then 'NO POSTER'
           when count(*) filter (where a.kind = 'video') = 0 then 'NO ASSETS'
           else 'ok'
         end                                      as verdict
  from public.titles t
  left join public.title_assets a on a.title_id = t.id
  group by t.id
  order by t.created_at desc;


do $mig$
begin
  if not exists (select 1 from public.schema_migrations where version = '008') then
    insert into public.schema_migrations (version, note)
    values ('008', 'add_title with metadata, publish_title guard, catalogue_health');
  end if;
end
$mig$;

revoke execute on function public.publish_title(text)   from public, anon, authenticated;
revoke execute on function public.unpublish_title(text) from public, anon, authenticated;
grant  execute on function public.publish_title(text)   to service_role;
grant  execute on function public.unpublish_title(text) to service_role;
revoke all on public.catalogue_health from anon, authenticated;
grant select on public.catalogue_health to service_role;

select * from public.catalogue_health;
