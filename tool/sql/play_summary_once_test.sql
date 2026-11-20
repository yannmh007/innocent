-- One play_summary row per playback   (migration 082)
--
-- Run inside one transaction that ends on a deliberate exception. Success is
-- the message `PLAY SUMMARY ONCE TEST PASSED`. Its events carry negative ids
-- (no value drawn from the events sequence), and the second copy is inserted
-- inside its own exception block, as record_events inserts each event.
--   1. a second copy of a summary (the same summary_id) is refused, and the
--      refusal stays inside that event's block: the batch goes on;
--   2. two playbacks' summaries (two ids) are both kept;
--   3. a summary without a summary_id (1.64.81-1.64.85) is outside the rule;
--   4. other kinds are outside it too.
do $$
declare
  skipped int := 0;
begin
  insert into public.events (id, occurred_at, viewer_key, kind, meta)
  values (-82001, now(), 'once-test', 'play_summary', '{"summary_id": "00000000000000aa", "played_s": 10}');

  begin
    insert into public.events (id, occurred_at, viewer_key, kind, meta)
    values (-82002, now(), 'once-test', 'play_summary',
            '{"summary_id": "00000000000000aa", "played_s": 10, "stashed": 1}');
  exception when others then
    skipped := skipped + 1;
  end;
  if skipped <> 1 or exists (select 1 from public.events where id = -82002) then
    raise exception 'case 1: a second copy of one summary was kept';
  end if;

  insert into public.events (id, occurred_at, viewer_key, kind, meta)
  values (-82003, now(), 'once-test', 'play_summary', '{"summary_id": "00000000000000bb"}');
  if (select count(*) from public.events where id in (-82001, -82003)) <> 2 then
    raise exception 'case 2: a second playback''s summary was refused';
  end if;

  insert into public.events (id, occurred_at, viewer_key, kind, meta)
  values (-82004, now(), 'once-test', 'play_summary', '{"played_s": 32}'),
         (-82005, now(), 'once-test', 'play_summary', '{"played_s": 32}');
  if (select count(*) from public.events where id in (-82004, -82005)) <> 2 then
    raise exception 'case 3: summaries without an id were refused';
  end if;

  insert into public.events (id, occurred_at, viewer_key, kind, meta)
  values (-82006, now(), 'once-test', 'play_progress', '{"summary_id": "00000000000000aa"}');

  raise exception 'PLAY SUMMARY ONCE TEST PASSED';
end $$;
