-- 082: one play_summary row per playback   (14 Nov 2026)
--
-- WHAT WAS WRONG. The app now keeps a playback's summary on the phone until
-- the batch it went in is known to have been taken, and sends it again
-- otherwise — later in the same run, or at the next start (SummaryOutbox,
-- the work branch's 69374520). A post can reach the server and its answer
-- still be lost (the app frozen or ended mid-post, the line cut): that copy
-- is then sent again, and would be a second row for one playback. Every
-- copy carries the playback's `meta.summary_id` (64 random bits).
--
-- WHAT THIS CHANGES. A unique index on a play_summary's summary_id. The
-- second copy's insert fails on it inside record_events' per-event
-- `exception when others` and is skipped, as a malformed event is: no
-- change to record_events, no error for the app, the batch's other events
-- written. Summaries without a summary_id (1.64.81-1.64.85) are outside it.
-- 4,253 events today: the build takes a moment.
--
-- PROVED BY tool/sql/play_summary_once_test.sql.

create unique index if not exists events_play_summary_once
  on public.events ((meta ->> 'summary_id'))
  where kind = 'play_summary' and meta ? 'summary_id';
