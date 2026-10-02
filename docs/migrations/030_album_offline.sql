-- 030 — what the app needs to download an album item by item.
--
-- TWO COLUMNS ON title_media, appended at the END. `create or replace view`
-- may only add columns after the existing ones, and every installed app selects
-- its columns by name, so an old build reads exactly what it read before.
--
-- is_main — THIS ITEM IS THE TITLE'S FILM. The main film is the asset whose
-- object key is `titles.locator`, and it is ALSO listed in the album (every
-- published title with a film has it there today). The app downloads the film
-- through the title's own Download button, keyed by the title id. Without this
-- flag an album "Download all" cannot tell which clip is that same film, and
-- would fetch it a second time — the largest file in the album, twice, on
-- mobile data.
--
-- bytes — HOW BIG EACH ITEM IS, before anything is fetched. "Download all"
-- asks once — "4 videos, 5 photos, 1.2 GB" — instead of once per video, and
-- the "+2 Video" offer after an admin adds media can say what it would cost.
-- A size says nothing about where the file lives; object_key stays private.
--
-- OWNER RIGHTS RESTATED. `create or replace view` resets reloptions — the bug
-- 013b records — so the security_invoker = false that makes this view the
-- access control has to be written again here, or the album silently empties
-- for every viewer.
create or replace view public.title_media as
 select a.id,
    a.title_id,
    a.kind,
    a.is_free,
    a.sort_order,
    a.duration_s,
    a.width,
    a.height,
    a.label,
    a.language,
        case
            when a.kind = 'photo'::text then public_asset_base() || a.object_key
            else null::text
        end as url,
    coalesce(
        case
            when a.thumb_key is not null then public_asset_base() || a.thumb_key
            else null::text
        end,
        case
            when a.kind = 'photo'::text then public_asset_base() || a.object_key
            else null::text
        end, t.poster_url) as thumb_url,
    (a.kind <> 'photo' and a.object_key = t.locator) as is_main,
    a.bytes
   from title_assets a
     join titles t on t.id = a.title_id
  where t.published and (a.kind = any (array['video'::text, 'clip'::text, 'trailer'::text, 'photo'::text]));

alter view public.title_media set (security_invoker = false);

insert into public.schema_migrations (version, note)
values ('030', 'title_media: is_main and bytes, for album downloads item by item')
on conflict (version) do nothing;

-- CHECKS
--
--   set local role anon;
--   select count(*) filter (where is_main) as mains,
--          count(*) filter (where kind <> 'photo' and url is not null) as leaked
--     from public.title_media;
--   -- mains = one per title with a film; leaked MUST be 0.
--
--   select reloptions from pg_class where relname = 'title_media';
--   -- MUST be {security_invoker=false}.
