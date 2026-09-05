-- ===========================================================================
-- 007 — slug, and one function that adds a whole folder
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
--
-- THE WORKFLOW THIS EXISTS FOR
--   innocent-media/spiderman/video1.mp4, video2.mp4, ...
--   innocent-public/spiderman/photo1.jpg, photo2.jpg, ...
--   → one line of SQL → the title appears in the app on the next pull-to-refresh
--
-- WHY A SLUG
--   `title_assets.title_id` is a uuid. Copying a uuid between two SQL
--   statements on a phone, correctly, a hundred times, is a data-entry
--   accident waiting to happen - and a wrong one silently attaches a film's
--   video to a different film.
--
--   The R2 FOLDER NAME is already the natural key: `spiderman` identifies the
--   title in both buckets. Storing it makes the folder and the row the same
--   thing, and removes the uuid from the workflow entirely.
-- ===========================================================================

do $mig$
begin
  if exists (select 1 from public.schema_migrations where version = '007') then
    raise notice '007 already applied, skipping';
    return;
  end if;

  alter table public.titles add column if not exists slug text;

  -- Backfill the existing row from the folder its video already sits in, so
  -- the column is correct from the moment it appears rather than being a
  -- field someone has to remember to fill in later.
  update public.titles
     set slug = split_part(locator, '/', case when locator like 'v/%' then 2 else 1 end)
   where slug is null and locator is not null;

  update public.titles set slug = 'title-' || left(id::text, 8)
   where slug is null;

  -- Unique, so `where slug = 'spiderman'` can never match two rows and quietly
  -- attach assets to the wrong film.
  create unique index if not exists titles_slug_key on public.titles (slug);

  insert into public.schema_migrations (version, note)
  values ('007', 'titles.slug + add_title() folder helper');
end
$mig$;


-- ---------------------------------------------------------------------------
-- add_title — one call per folder
-- ---------------------------------------------------------------------------
-- Deliberately RE-RUNNABLE. Upload three more clips to the same folder next
-- month, run the same line with the fuller list, and only the new files are
-- added: `title_assets` has `unique (bucket, object_key)`, so the ones already
-- there are skipped rather than duplicated.
--
-- It also NEVER overrides a primary you have already chosen. If a poster has
-- been picked by hand, re-running this leaves it alone - the first photo is
-- only made primary when there is no primary yet. Otherwise every re-run would
-- silently reset the card image back to photo1, which is exactly the kind of
-- quiet damage that is noticed weeks later.
create or replace function public.add_title(
  p_slug     text,                     -- the R2 folder name: 'spiderman'
  p_title    text,                     -- what viewers see: 'Spider-Man'
  p_videos   text[] default '{}',      -- ['video1.mp4','video2.mp4']
  p_photos   text[] default '{}',      -- ['photo1.jpg','photo2.jpg']
  p_category text default 'movies',
  p_tier     text default 'free'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $fn$
declare
  tid uuid;
begin
  -- Find or create. Re-running with the same slug updates the existing title
  -- instead of creating a second one with the same name.
  select id into tid from public.titles where slug = p_slug;

  if tid is null then
    insert into public.titles (slug, title, category, access_tier, status, published)
    values (p_slug, p_title, p_category, p_tier, 'draft', false)
    returning id into tid;
  end if;

  -- Videos -> the PRIVATE bucket. `with ordinality` keeps the order given,
  -- so video1 stays first however Postgres feels about it.
  insert into public.title_assets
    (title_id, kind, bucket, object_key, sort_order)
  select tid, 'video', 'innocent-media', p_slug || '/' || f.name, f.ord
  from unnest(p_videos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  -- Photos -> the PUBLIC bucket.
  insert into public.title_assets
    (title_id, kind, bucket, object_key, sort_order)
  select tid, 'photo', 'innocent-public', p_slug || '/' || f.name, f.ord
  from unnest(p_photos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

  -- Make the first of each kind primary ONLY if nothing is primary yet.
  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'video' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets
                 where title_id = tid and kind = 'video'
                 order by sort_order, added_at limit 1);
  end if;

  if not exists (select 1 from public.title_assets
                 where title_id = tid and kind = 'photo' and is_primary) then
    update public.title_assets set is_primary = true
     where id = (select id from public.title_assets
                 where title_id = tid and kind = 'photo'
                 order by sort_order, added_at limit 1);
  end if;

  return tid;
end;
$fn$;

-- Operator-only. This writes to the catalogue; nothing holding the anon key
-- may ever call it.
revoke execute on function public.add_title(text,text,text[],text[],text,text)
  from public, anon, authenticated;
grant execute on function public.add_title(text,text,text[],text[],text,text)
  to service_role;


-- ---------------------------------------------------------------------------
-- PROVE IT
-- ---------------------------------------------------------------------------
select slug, title, status, published, photo_count, video_count, poster_url
from public.titles order by created_at;
-- The existing row must now have a slug, and its counts must still be 1 and 1.
