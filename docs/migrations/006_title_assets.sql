-- ===========================================================================
-- 006 — title_assets: one title, many files, and a poster you can change
--
-- Paste the WHOLE file into the SQL Editor and Run. Safe to run twice.
--
-- WHAT THIS SOLVES
--   `titles.locator` and `titles.poster_url` are single columns, so a title
--   can have exactly one video and one picture. The requirement is a FOLDER
--   per title holding the film, its clips and as many photos as wanted - with
--   one of those photos chosen as the card image, changeable later.
--
--   A column cannot express that. A second table can.
--
-- THE CLIENT DOES NOT CHANGE.
--   The app reads `titles.poster_url`, `titles.locator`, `photo_count` and
--   `video_count`. All four stay exactly where they are and become MAINTAINED
--   values: a trigger writes them from whichever asset is marked primary.
--   The app keeps reading four columns and never learns this table exists.
--   That is the additive-only rule doing its job.
--
-- SHAPES TAKEN FROM THE CLIENT, NOT INVENTED
--   `AlbumItem` in video_content.dart keeps `source` and `thumbnail` SEPARATE
--   ("a grid of thirty items must never fetch thirty full-size files"), and
--   carries a free/trailer flag ("free to open even inside a premium title").
--   So this table has `thumb_key` and `is_free`. Designing without reading
--   that would have produced a table the app could never populate.
-- ===========================================================================

do $mig$
begin
  if exists (select 1 from public.schema_migrations where version = '006') then
    raise notice '006 already applied, skipping';
    return;
  end if;

  create table if not exists public.title_assets (
    id          uuid primary key default gen_random_uuid(),
    title_id    uuid not null references public.titles(id) on delete cascade,

    -- text + check rather than an enum, to match `category` and `status`
    -- already in this schema. Widening it later is one ALTER instead of a
    -- type change, which matters when every change is pasted from a phone.
    kind        text not null
                check (kind in ('video','clip','trailer','photo','subtitle','audio')),

    bucket      text not null default 'innocent-media',
    object_key  text not null,      -- 'titles/spider-man-2026/main.mp4'

    -- The small still for a grid tile. Separate from object_key because the
    -- client says so: a row of thirty tiles must not fetch thirty full files.
    -- Lives in the PUBLIC bucket even when object_key is private.
    thumb_key   text,

    -- WHICH ASSET IS THE ONE. Per kind, so a title has one primary photo AND
    -- one primary video - not one primary asset in total.
    is_primary  boolean not null default false,

    -- Openable without an entitlement, even inside a premium title: the
    -- trailer slot. An explicit flag, not a rule like "the first clip is
    -- free", because which clip is the taste is an editorial decision.
    is_free     boolean not null default false,

    sort_order  int not null default 0,
    label       text,               -- '720p', 'Behind the scenes'
    language    text,               -- subtitle and audio tracks
    duration_s  int,
    width       int,
    height      int,
    bytes       bigint,
    mime        text,

    extra       jsonb not null default '{}'::jsonb,
    added_at    timestamptz not null default now(),

    -- The same file cannot be registered twice. Catches the commonest
    -- data-entry slip: pasting the same key into two rows.
    unique (bucket, object_key)
  );

  create index if not exists title_assets_title on public.title_assets (title_id, kind, sort_order);

  -- At most one primary PER KIND per title. A partial unique index, not a
  -- trigger: the database REFUSES a second primary rather than silently
  -- keeping two and letting the poster flicker between them.
  create unique index if not exists title_assets_one_primary
    on public.title_assets (title_id, kind) where is_primary;

  -- "Automatically expose new tables" is OFF, so nothing is granted by
  -- default - to service_role either. That has now bitten this project twice
  -- (migrations 002 and 005). Granting it here, in the same migration that
  -- creates the table, is how it stops happening.
  grant all privileges on public.title_assets to service_role;

  -- DELIBERATELY NOT GRANTED TO anon.
  -- This table holds `object_key` for VIDEOS. Exposing it would hand out
  -- every media path and undo the entire `locator` protection that migration
  -- 001 exists to provide - and that the self-test checks on every run.
  -- Photos reach the app through the view below instead.

  insert into public.schema_migrations (version, note)
  values ('006', 'title_assets + primary sync trigger + title_media view');
end
$mig$;


-- ---------------------------------------------------------------------------
-- WHERE PUBLIC FILES LIVE — one function, so the domain changes in one place
-- ---------------------------------------------------------------------------
-- Today this is the r2.dev development URL, which Cloudflare rate-limits and
-- says is for testing. When a custom domain replaces it, this function is the
-- only thing that changes - not a hundred rows of stored URLs. That is the
-- same reason `locator` is a path and not a URL.
create or replace function public.public_asset_base()
returns text language sql immutable as $fn$
  select 'https://pub-18c62521649645be87d4d36225021e15.r2.dev/'
$fn$;


-- ---------------------------------------------------------------------------
-- THE TRIGGER — keeps the four client columns true
-- ---------------------------------------------------------------------------
create or replace function public.sync_title_from_assets()
returns trigger language plpgsql security definer
set search_path = public as $fn$
declare
  tid uuid := coalesce(new.title_id, old.title_id);
begin
  update public.titles t set
    -- The primary photo becomes the card image. `coalesce` so that deleting
    -- the last photo leaves the previous URL rather than blanking the card:
    -- a stale poster is better than none while the replacement is uploaded.
    poster_url = coalesce((
      select public.public_asset_base() || a.object_key
      from public.title_assets a
      where a.title_id = tid and a.kind = 'photo' and a.is_primary
      limit 1), t.poster_url),

    -- The primary video becomes what request-playback signs. Falls back to
    -- lowest sort_order so a title with one unmarked video still plays.
    locator = coalesce((
      select a.object_key from public.title_assets a
      where a.title_id = tid and a.kind = 'video'
      order by a.is_primary desc, a.sort_order, a.added_at
      limit 1), t.locator),

    -- These two are nullable ON PURPOSE and the app draws nothing for null.
    -- Now that assets are counted they can hold an honest number.
    photo_count = (select count(*) from public.title_assets a
                   where a.title_id = tid and a.kind = 'photo'),
    video_count = (select count(*) from public.title_assets a
                   where a.title_id = tid and a.kind in ('video','clip','trailer'))
  where t.id = tid;
  return null;
end;
$fn$;

drop trigger if exists title_assets_sync on public.title_assets;
create trigger title_assets_sync
  after insert or update or delete on public.title_assets
  for each row execute function public.sync_title_from_assets();


-- ---------------------------------------------------------------------------
-- CHANGING THE CARD IMAGE — one call
-- ---------------------------------------------------------------------------
-- Without this it takes two statements in the right order, because the unique
-- index rejects a second primary before the first is cleared. One function
-- removes that trap.
create or replace function public.set_primary_asset(asset_id uuid)
returns void language plpgsql security definer
set search_path = public as $fn$
declare
  t uuid; k text;
begin
  select title_id, kind into t, k from public.title_assets where id = asset_id;
  if t is null then
    raise exception 'no asset with id %', asset_id;
  end if;

  update public.title_assets set is_primary = false
   where title_id = t and kind = k and is_primary;
  update public.title_assets set is_primary = true where id = asset_id;
end;
$fn$;

revoke execute on function public.set_primary_asset(uuid) from public, anon, authenticated;
grant execute on function public.set_primary_asset(uuid) to service_role;


-- ---------------------------------------------------------------------------
-- THE SAFE VIEW — photos to the app, never video paths
-- ---------------------------------------------------------------------------
-- Maps onto the client's `AlbumItem`: a full-size `source`, a separate
-- `thumbnail`, a duration, and the free/trailer flag.
--
-- `url` is filled for photos only. A clip's playable URL is NEVER handed out
-- here - it has to come from request-playback, exactly as the main video
-- does, or the ten-minute expiry becomes optional.
create or replace view public.title_media
with (security_invoker = true)
as
  select a.id, a.title_id, a.kind, a.is_free, a.sort_order,
         a.duration_s, a.width, a.height, a.label, a.language,
         case when a.kind = 'photo'
              then public.public_asset_base() || a.object_key end as url,
         case when a.thumb_key is not null
              then public.public_asset_base() || a.thumb_key end as thumb_url
  from public.title_assets a
  join public.titles t on t.id = a.title_id
  where t.published and a.kind in ('photo','clip','trailer');

grant select on public.title_media to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- BACKFILL — the title that already exists keeps working
-- ---------------------------------------------------------------------------
insert into public.title_assets (title_id, kind, bucket, object_key, is_primary)
select t.id, 'video', 'innocent-media', t.locator, true
from public.titles t
where t.locator is not null
  and not exists (select 1 from public.title_assets a
                  where a.title_id = t.id and a.kind = 'video')
on conflict (bucket, object_key) do nothing;

insert into public.title_assets (title_id, kind, bucket, object_key, is_primary)
select t.id, 'photo', 'innocent-public',
       replace(t.poster_url, public.public_asset_base(), ''), true
from public.titles t
where t.poster_url like public.public_asset_base() || '%'
  and not exists (select 1 from public.title_assets a
                  where a.title_id = t.id and a.kind = 'photo')
on conflict (bucket, object_key) do nothing;


-- ---------------------------------------------------------------------------
-- PROVE IT
-- ---------------------------------------------------------------------------
select t.title, t.photo_count, t.video_count, t.poster_url, t.locator
from public.titles t;
-- photo_count and video_count must now be 1 and 1, not null.
-- poster_url and locator must be unchanged.

-- And the view must never leak a video path:
--   set role anon;
--   select * from public.title_media;          -- photos have url, clips do not
--   select object_key from public.title_assets; -- must ERROR
--   reset role;
