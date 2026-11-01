-- 062 — media_keys: what the edge functions may do with it.
--
-- New tables in this project give service_role nothing by default (migration
-- 006 notes it bit twice), and 060 granted nothing: request-playback could not
-- read a key and the ingest function could not record one (seal_commit:
-- "insert 403", 1 Nov 2026). SELECT and INSERT only. No UPDATE, no DELETE:
-- a recorded key is never rewritten from a function; a re-wrap under a new
-- KEK version or the retirement of a twin is a migration of its own.
grant select, insert on public.media_keys to service_role;
