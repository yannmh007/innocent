-- 080: the per-playback summary is an event kind   (7 Nov 2026)
--
-- WHAT WAS WRONG. Stalls on the ladder engine (ExoPlayer, the main
-- streaming path) never reached the server, so `play_stall` stopped after
-- 24 Oct and "no stalls" looked like smoothness; tap-to-picture was not
-- measured whole; a playback failure was never reported (`error` was a kind
-- nobody sent). The app now sends one `play_summary` per playback
-- (PlaybackQoe: open_ms, played_s, stalls, frozen_ms, longest_ms, jumps,
-- jump_ms, rung_low/high/changes, error codes), ladder stalls as
-- `play_stall` with reason "ladder", and failures as `error` with a code.
--
-- WHAT THIS CHANGES. record_events() drops a kind it does not know, so the
-- new one is added to event_kinds. Nothing else: the summary's meta is a
-- few hundred bytes, under record_events' 2 KB.
--
-- PROVED BY tool/sql/play_summary_test.sql.

insert into public.event_kinds (kind, note)
values ('play_summary', 'one per playback: what watching was like (open_ms, stalls, frozen_ms, jumps, rungs, error codes)')
on conflict (kind) do nothing;
