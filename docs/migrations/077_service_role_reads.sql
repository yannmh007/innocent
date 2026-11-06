-- 077 — the functions may use the tables they name (fixes 058, and 018's reads)
--
-- WHAT WAS WRONG. In this project a new table gives the service role nothing
-- (060 and 062 met it for media_keys): every grant is written out. Two were
-- not, and nothing said so, because supabase-js hands the error back and the
-- callers carried on:
--
--   genres (058). The console's Categories page lists genres as the service
--   role, and its editor saves a title's genre_codes the same way. Both read
--   genres — the list directly, the save through titles_taxonomy(), a plain
--   (invoker) trigger. So the Genres section did not load (the owner's
--   console, 6 Nov 11:37: "permission denied for table genres"), no title's
--   genres could be changed, no genre or category could be added (their codes
--   come from genre_code_seq and category_code_seq), and a title made with
--   genre words — the open-film seed sends "Open Movie" — could not be made.
--   Nothing has changed a genre since 058 went live on 31 Oct, which is why
--   it went unseen.
--
--   asset_renditions (018). Its rule is that a viewer reads the ladder only
--   through request-playback's definer function, never through the API — a
--   rule about the anon key. Three service-role reads expect the table:
--   the console's preview of a film (it falls back to the master, heavier),
--   the Files page's move of a title (its rungs were not listed), and the
--   transcode function's check that no sealed twin outlives its rung (5 Nov
--   12:42, three times, during the transcode canary: it saw no rungs).
--
-- WHAT THIS GIVES. The service role only — anon and authenticated keep what
-- they had (genres: read; asset_renditions: nothing). The service role
-- bypasses row level security, so these grants are the whole of it.
--
-- tool/sql/service_role_grants_test.sql checks every table the functions
-- name, and each path above, as the service role in a rolled-back
-- transaction.

grant select, insert, update, delete on public.genres to service_role;
grant usage, select on sequence public.genre_code_seq to service_role;
grant usage, select on sequence public.category_code_seq to service_role;
grant select on public.asset_renditions to service_role;
