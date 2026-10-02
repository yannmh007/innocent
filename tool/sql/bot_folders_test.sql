-- The bot's /folder session (migration 033)
--
-- One transaction that ends on a deliberate exception, so nothing it creates
-- survives. Success is the message `BOT FOLDERS TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter: a session that outlives three idle hours (and puts
-- tomorrow's film in today's folder); an album whose files split between the
-- session folder and its caption's; a name that is not a folder, or is one
-- the system already uses; a second session in another chat leaking into
-- this one.
do $$
declare
  me  bigint := -987654321001;   -- not a real chat
  you bigint := -987654321002;
  js jsonb; r record; n integer;
begin
  -- names
  if public.bot_folder_name_ok('solo-girl-collection') <> 'ok' then raise exception 'good name refused'; end if;
  if public.bot_folder_name_ok('') <> 'empty' then raise exception 'empty name'; end if;
  if public.bot_folder_name_ok('Solo Girl') <> 'bad_name' then raise exception 'unslugged name'; end if;
  if public.bot_folder_name_ok('apk') <> 'reserved' then raise exception 'apk is not reserved'; end if;
  if public.bot_folder_name_ok('inbox') <> 'reserved' then raise exception 'inbox is not reserved'; end if;
  if public.bot_folder_open(me, 'inbox') ->> 'error' <> 'reserved' then raise exception 'opened inbox'; end if;

  -- nothing open
  if public.bot_folder_current(me) ->> 'folder' is not null then raise exception 'open before /folder'; end if;

  -- open, and only for this chat
  js := public.bot_folder_open(me, 'zz-bot-test');
  if (js ->> 'ok')::boolean is not true then raise exception 'open: %', js; end if;
  if public.bot_folder_current(me) ->> 'folder' <> 'zz-bot-test' then raise exception 'not current'; end if;
  if public.bot_folder_current(you) ->> 'folder' is not null then raise exception 'leaked to another chat'; end if;

  -- an album forwarded with a Burmese caption on one file goes, whole, to the folder
  perform public.enqueue_ingest('f1', 'zz-u1', me, 1, 'a.jpg', 'image/jpeg', 10, null, null, null,
    'photo', 'innocent-public', 'zz-bot-test', 'photo/a.jpg', 'zz-group-1', 'ချစ်သူ အပိုင်း ၁');
  perform public.enqueue_ingest('f2', 'zz-u2', me, 2, 'b.jpg', 'image/jpeg', 10, null, null, null,
    'photo', 'innocent-public', 'zz-bot-test', 'photo/b.jpg', 'zz-group-1', null);
  -- and a second album, different caption, same folder
  perform public.enqueue_ingest('f3', 'zz-u3', me, 3, 'c.mp4', 'video/mp4', 10, null, null, null,
    'video', 'innocent-media', 'zz-bot-test', 'video/c.mp4', 'zz-group-2', 'Something Else');
  select count(*) into n from public.ingest_jobs where tg_unique_id like 'zz-u%'
     and split_part(object_key, '/', 1) = 'zz-bot-test';
  if n <> 3 then raise exception 'files in the folder: %', n; end if;
  -- the caption is still kept, for the console's description
  if not exists (select 1 from public.ingest_jobs where tg_unique_id = 'zz-u2'
                   and tg_caption = 'ချစ်သူ အပိုင်း ၁') then
    raise exception 'caption lost';
  end if;

  -- what the bot reports
  js := public.bot_folder_stats('zz-bot-test');
  if (js ->> 'files')::int <> 3 or (js ->> 'queued')::int <> 3 then raise exception 'stats: %', js; end if;
  if not exists (select 1 from jsonb_array_elements(public.bot_folders_recent(30)) f
                  where f ->> 'folder' = 'zz-bot-test' and (f ->> 'files')::int = 3) then
    raise exception 'recent folders';
  end if;

  -- /done counts what this session added
  js := public.bot_folder_close(me);
  if js ->> 'folder' <> 'zz-bot-test' or (js ->> 'added')::int <> 3 then raise exception 'close: %', js; end if;
  if public.bot_folder_current(me) ->> 'folder' is not null then raise exception 'still open after /done'; end if;
  if public.bot_folder_close(me) ->> 'folder' is not null then raise exception 'closed twice'; end if;

  -- continuing later: the same name again, and the stats show what is there
  js := public.bot_folder_open(me, 'zz-bot-test');
  if (js -> 'stats' ->> 'files')::int <> 3 then raise exception 'continue: %', js; end if;

  -- switching folders says which one was closed
  js := public.bot_folder_open(me, 'zz-bot-test-2');
  if js ->> 'previous' <> 'zz-bot-test' then raise exception 'previous: %', js; end if;

  -- three idle hours close it, once, and say which
  update public.bot_folder_sessions set touched_at = now() - interval '4 hours' where chat_id = me;
  js := public.bot_folder_current(me);
  if js ->> 'folder' is not null or js ->> 'expired' <> 'zz-bot-test-2' then raise exception 'expiry: %', js; end if;
  js := public.bot_folder_current(me);
  if js ->> 'expired' is not null then raise exception 'expired twice: %', js; end if;

  -- /retry puts a spent file back, and nothing else
  update public.ingest_jobs set state = 'failed', attempts = 3 where tg_unique_id = 'zz-u3';
  if public.bot_retry_folder('zz-bot-test') <> 1 then raise exception 'retry'; end if;
  if public.bot_retry_folder('zz-bot-test') <> 0 then raise exception 'retry twice'; end if;

  -- status answers
  js := public.bot_queue_status();
  if not (js ? 'queued' and js ? 'runner_at' and js ? 'archive_queued') then raise exception 'status: %', js; end if;

  raise exception 'BOT FOLDERS TEST PASSED';
end $$;
