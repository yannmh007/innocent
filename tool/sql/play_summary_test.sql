-- The per-playback summary is accepted, and fits   (migration 080)
--
-- Run inside one transaction that ends on a deliberate exception. Success is
-- the message `PLAY SUMMARY TEST PASSED`. It does not call record_events:
-- that would draw from the events sequence, which a rollback does not undo.
--   1. play_summary, play_stall and error are kinds record_events accepts;
--   2. the largest summary the app can send is under its 2 KB meta limit.
do $$
declare
  big jsonb := jsonb_build_object(
    'engine', 'ladder', 'open_ms', 999999, 'played_s', 99999,
    'stalls', 9999, 'frozen_ms', 99999999, 'longest_ms', 9999999,
    'jumps', 9999, 'jump_ms', 99999999, 'rung_low', 2160, 'rung_high', 2160,
    'rung_changes', 9999,
    'errors', 'damaged_stretch,engine_stuck,link_expired,offline,player_error,stalled,would_not_start');
begin
  if (select count(*) from public.event_kinds
       where kind in ('play_summary', 'play_stall', 'error')) <> 3 then
    raise exception 'case 1: a playback kind is not accepted';
  end if;
  if pg_column_size(big) > 2048 then
    raise exception 'case 2: the largest summary is % bytes, over 2048', pg_column_size(big);
  end if;
  raise exception 'PLAY SUMMARY TEST PASSED';
end $$;
