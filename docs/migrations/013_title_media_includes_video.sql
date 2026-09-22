-- 013 — the main video becomes a tile in the album
--
-- APPLIED 22 Sep 2026. Recorded here after the fact, as 011 and 012 were.
--
-- WHAT WAS WRONG. `title_media` — the view the app reads to draw a title's
-- mixed photo/video grid — filtered on
--
--     a.kind = any (array['photo','clip','trailer'])
--
-- and 'video' is the kind the studio page writes for the main file. So the
-- main video was excluded from the album by one line.
--
-- It was a defensible line once. The main video was what the big Play button
-- on the detail screen played, so listing it again in the grid below would
-- have been a duplicate tile. That reasoning stopped holding when the product
-- direction became "the album IS the way into a title" — many videos and
-- photos in one card, Telegram-style, with a play button on each video tile
-- and no single Play button at the top.
--
-- THE SYMPTOM, which is why this was not obvious. A title uploaded with one
-- video and one photo reached the client as an album of exactly ONE item: the
-- photo — which the same screen already draws, full width, as the poster
-- directly above the grid. So the album looked like a feature nobody had
-- built, when in fact `MediaMosaic`, `AlbumViewerScreen`, the per-tile play
-- glyph, the duration badge, the free-preview tag and the locked-tile blur
-- had all been built months earlier and were waiting for rows.
--
-- SAFE END TO END, checked before applying:
--
--   * The view exposes NO `url` for a non-photo kind, so the client turns a
--     video row into MediaRef(provider: 'asset') and must go through
--     request-playback for it — exactly as it does for the main film. There
--     is no path here that hands a browser or an app a media address.
--   * `request-playback` accepts any asset kind EXCEPT 'photo' and
--     'subtitle', and checks the asset really belongs to the title before
--     signing anything. A video asset is therefore already a supported
--     argument; nothing there needed changing.
--   * `photo_count` / `video_count` come from triggers on `title_assets` and
--     are untouched by a view.
--
-- Everything else in the view is unchanged and is repeated verbatim rather
-- than patched, because `create or replace view` has no way to alter one
-- clause.
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
         case when a.kind = 'photo'
              then public_asset_base() || a.object_key
              else null::text
         end as url,
         coalesce(
           case when a.thumb_key is not null
                then public_asset_base() || a.thumb_key
                else null::text
           end,
           case when a.kind = 'photo'
                then public_asset_base() || a.object_key
                else null::text
           end,
           t.poster_url
         ) as thumb_url
    from title_assets a
    join titles t on t.id = a.title_id
   where t.published
     and a.kind = any (array['video','clip','trailer','photo']);

insert into public.schema_migrations (version, note)
values ('013', 'title_media includes kind=video so the main film is an album tile')
on conflict (version) do nothing;

-- ===========================================================================
-- CHECK — every published title should now return one row per asset.
-- ===========================================================================
--
--   select t.title, m.kind, m.sort_order,
--          (m.url is not null) as has_url,
--          m.duration_s, m.width, m.height
--     from public.title_media m
--     join public.titles t on t.id = m.title_id
--    order by t.title, m.sort_order;
--
-- `has_url` must be TRUE for photo and FALSE for video. A video with a url
-- would mean the private bucket had leaked into a public view.
--
-- `duration_s`, `width` and `height` are null on everything uploaded before
-- 22 Sep, because the old upload page never measured a file. The console
-- does now — see docs/studio/index.html — so anything uploaded from here on
-- carries them. The old rows are best fixed by re-uploading; there is no
-- server-side way to measure a file already in R2 without pulling it back
-- out, which is the one thing this architecture exists to avoid.
