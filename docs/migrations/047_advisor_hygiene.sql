-- 047 — what the Supabase advisors found on 2026-10-22, and what was done.
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. Nothing is dropped or deleted.
--
-- ═══════════════════════════════════════════════════════════════════════
-- FIXED HERE
-- ═══════════════════════════════════════════════════════════════════════
--
-- 1. auth_rls_initplan (4 policies). `user_id = auth.uid()` is evaluated
--    once PER ROW; `(select auth.uid())` once per query, as an init plan.
--    Same rows, same rule — Postgres just stops asking the same question
--    for every row a policy looks at. Supabase's own guidance.
--
-- 2. unindexed_foreign_keys (9). A foreign key with no index on its own
--    column makes every delete or key change on the referenced table scan
--    the referencing one. The tables are small today; an index costs
--    nothing now and a lock storm later.
--
-- 3. function_search_path_mutable: offsite_max_bytes(). It references
--    nothing, so an empty search_path changes nothing it does — and leaves
--    nothing for a caller's search_path to redirect.
--
-- ═══════════════════════════════════════════════════════════════════════
-- LOOKED AT AND LEFT, ON PURPOSE
-- ═══════════════════════════════════════════════════════════════════════
--
-- * security_definer_view: public.title_media (ERROR). Owner rights ARE the
--   access control (013b, 041): anon may not read title_assets at all, and
--   the view hands out a photo's address only when the viewer may open it.
--   As security_invoker it would need anon to read title_assets — every
--   object key in the private bucket, and every locked photo's address.
-- * anon/authenticated SECURITY DEFINER functions (10): the public API —
--   catalogue rows, search, events, views, watch state. Each derives the
--   caller from auth.uid() / the request, and does nothing for a caller it
--   cannot place (claim_anonymous_history returns at once without a user).
-- * rls_enabled_no_policy (36): service-role tables; no policy means no
--   client role reads them, which is the point.
-- * auth_leaked_password_protection: the HaveIBeenPwned check is a Pro-plan
--   feature. The app signs in with Google or a code sent to a phone, so
--   passwords are not the door that matters; noted for the day the plan
--   changes. (The console asks its admins for a second step — 026.)
-- * unused_index (8): a catalogue of four titles uses few indexes; the
--   search and genre ones are for the catalogue it is built to hold.

alter policy "own subscriptions" on public.subscriptions
  using (user_id = (select auth.uid()));
alter policy "own devices" on public.devices
  using (user_id = (select auth.uid()));
alter policy "own requests" on public.premium_requests
  using (user_id = (select auth.uid()));
alter policy "file own request" on public.premium_requests
  with check (user_id = (select auth.uid()) and status = 'pending');

create index if not exists admins_added_by_idx on public.admins (added_by);
create index if not exists bookmarks_title_id_idx on public.bookmarks (title_id);
create index if not exists diagnostic_reports_user_id_idx on public.diagnostic_reports (user_id);
create index if not exists events_asset_id_idx on public.events (asset_id);
create index if not exists ingest_jobs_title_id_idx on public.ingest_jobs (title_id);
create index if not exists premium_requests_duplicate_of_idx on public.premium_requests (duplicate_of);
create index if not exists titles_created_by_idx on public.titles (created_by);
create index if not exists titles_decided_by_idx on public.titles (decided_by);
create index if not exists titles_submitted_by_idx on public.titles (submitted_by);

alter function public.offsite_max_bytes() set search_path = '';
