-- ===========================================================================
-- 009 — two bugs that only appear once a folder holds more than one file
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
-- No client change: both fixes are server-side, the app is untouched.
--
-- Neither of these could be seen with the current catalogue, because it has
-- exactly one video and one photo. Both appear on the second file.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- BUG 1 — the album order is not deterministic
-- ---------------------------------------------------------------------------
-- `add_title` numbers videos 1,2,3... and photos 1,2,3... So a folder with two
-- of each holds FOUR rows with sort_order 1,1,2,2.
--
-- The app asks for `order=sort_order.asc`. SQL does not promise any particular
-- order among equal keys, so those ties can come back differently on different
-- requests - and the mosaic computes its rows FROM THE ORDER. The album would
-- silently rearrange itself between one visit and the next.
--
-- Fix: photos live at 1000+. Clips first, photos after, no ties, stable
-- forever. Clips lead because the moving picture is the content and the stills
-- are the supporting material.

-- Existing rows first, so old and new titles sort the same way.
update public.title_assets
   set sort_order = sort_order + 1000
 where kind = 'photo' and sort_order < 1000;


-- ---------------------------------------------------------------------------
-- BUG 2 — clips draw as blank grey tiles
-- ---------------------------------------------------------------------------
-- A clip's `source` is `provider:'asset'` with an id and no URL, on purpose -
-- its playable URL must come from request-playback. But the mosaic tile draws
-- `thumbnail`, falling back to `source`, and `resolveImageUrlSync` returns ''
-- for anything not starting with `http`.
--
-- `add_title` never sets `thumb_key`. So every clip is an empty tile with a
-- play glyph on it: tapping works, looking at it tells you nothing.
--
-- Fix in the VIEW, not the client: a clip with no thumbnail of its own borrows
-- the title's poster. Wrong-ish, and enormously better than grey - the tile
-- shows the film it belongs to, which is what a viewer needs to know.
-- Uploading a real per-clip still later overrides it with no further change.
create or replace view public.title_media
with (security_invoker = true)
as
  select a.id, a.title_id, a.kind, a.is_free, a.sort_order,
         a.duration_s, a.width, a.height, a.label, a.language,
         case when a.kind = 'photo'
              then public.public_asset_base() || a.object_key end as url,
         coalesce(
           case when a.thumb_key is not null
                then public.public_asset_base() || a.thumb_key end,
           -- photos are their own thumbnail
           case when a.kind = 'photo'
                then public.public_asset_base() || a.object_key end,
           -- clips fall back to the title's poster
           t.poster_url
         ) as thumb_url
  from public.title_assets a
  join public.titles t on t.id = a.title_id
  where t.published and a.kind in ('photo','clip','trailer');

grant select on public.title_media to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- add_title: keep new photos at 1000+
-- ---------------------------------------------------------------------------
create or replace function public.add_title(
  p_slug     text,
  p_title    text,
  p_videos   text[] default '{}',
  p_photos   text[] default '{}',
  p_category text default 'movies',
  p_tier     text default 'free',
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

  -- 1000 + ord: see BUG 1 above.
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  select tid, 'photo', 'innocent-public', p_slug || '/' || f.name, 1000 + f.ord
  from unnest(p_photos) with ordinality as f(name, ord)
  on conflict (bucket, object_key) do nothing;

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

revoke execute on function public.add_title(text,text,text[],text[],text,text,text,text,int,text[],text,int)
  from public, anon, authenticated;
grant execute on function public.add_title(text,text,text[],text[],text,text,text,text,int,text[],text,int)
  to service_role;


do $mig$
begin
  if not exists (select 1 from public.schema_migrations where version = '009') then
    insert into public.schema_migrations (version, note)
    values ('009', 'deterministic album order + clip thumbnail fallback');
  end if;
end
$mig$;


-- ---------------------------------------------------------------------------
-- PROVE IT
-- ---------------------------------------------------------------------------
select kind, sort_order, object_key,
       thumb_key is not null as has_own_thumb
from public.title_assets
order by sort_order;
-- Clips/videos below 1000, photos at 1001+. No two rows share a sort_order.

select kind, sort_order, (url is not null) as has_url,
       (thumb_url is not null) as has_thumb
from public.title_media order by sort_order;
-- Every row must have a thumb_url now. Clips must still have url = false.
