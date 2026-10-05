-- 038: a remote switch for the player's video output.
--
-- 1.64.54 renders video through a Flutter SurfaceProducer (ImageReader)
-- instead of a SurfaceTexture: no per-frame copy on Impeller/Vulkan. It is
-- the path Flutter's own video_player uses, but it is new to this app, and a
-- phone model that draws it wrong must not need an APK to be fixed.
--
-- The app already reads this one row once a day for updates; it now also
-- reads `player_flags`, a space-separated list of words:
--   legacy_surface   every install goes back to the SurfaceTexture path
--                    (takes effect the next time the app starts).
-- Empty means defaults. Unknown words are ignored.
--
-- ORDER: run this BEFORE publishing a build that selects the column —
-- PostgREST rejects the whole update check when one selected column is
-- missing. Older builds never select it, so adding it first is harmless.

alter table public.app_releases
  add column if not exists player_flags text not null default '';
