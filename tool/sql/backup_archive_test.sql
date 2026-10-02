-- Backups, the archive channel and the Status page's numbers (migration 032)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `BACKUP ARCHIVE TEST PASSED`;
-- any other exception names the case that failed.
--
-- The cases that matter: a backup the bin could delete; a restore order that
-- inserts a child before its parent; an archive copy recorded in the wrong
-- chat or at the wrong size (the one copy a restore would trust); an archive
-- job finished through the restore path; a channel anybody could connect.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  t1 uuid; fwd uuid; con uuid; huge uuid;
  j record; v text; n integer; js jsonb; b1 bigint; b2 bigint; b3 bigint;
  o_titles integer; o_assets integer;
begin
  -- Nothing else in the queue may answer the claims below.
  update public.vault_jobs set state = 'done' where state in ('queued', 'running');
  update public.admin_settings set archive_chat_id = null where true;

  -- ── what a backup holds, and in what order ──────────────────────────────
  select ord into o_titles from public.backup_tables() where name = 'titles';
  select ord into o_assets from public.backup_tables() where name = 'title_assets';
  if o_titles is null or o_assets is null or o_titles >= o_assets then
    raise exception 'backup order: titles % assets %', o_titles, o_assets;
  end if;
  if exists (select 1 from public.backup_tables() where name = 'admin_sessions') then
    raise exception 'sessions are backed up';
  end if;
  if json_typeof(public.backup_table('titles')) <> 'array' then
    raise exception 'a table is not an array';
  end if;
  begin
    perform public.backup_table('pg_authid');
    raise exception 'an unlisted table was dumped';
  exception when raise_exception then
    if sqlerrm = 'an unlisted table was dumped' then raise; end if;
  end;
  if json_typeof(public.backup_auth_users()) <> 'array' then
    raise exception 'accounts are not an array';
  end if;

  -- ── due, recorded, kept, pruned ─────────────────────────────────────────
  update public.db_backups set deleted_at = now() where deleted_at is null;
  if not public.backup_due() then raise exception 'no backup and not due'; end if;
  b1 := public.backup_record('_backup/db/zz-1.json.gz', 10, 100, 'aa', '{"titles":1}', 'daily');
  if public.backup_due() then raise exception 'due straight after a backup'; end if;
  update public.db_backups set taken_at = now() - interval '40 days' where id = b1;
  b2 := public.backup_record('_backup/db/zz-2.json.gz', 10, 100, 'bb', '{}', 'daily');
  update public.db_backups set taken_at = now() - interval '39 days' where id = b2;
  b3 := public.backup_record('_backup/db/zz-3.json.gz', 10, 100, 'cc', '{}', 'manual');
  -- b1 is the first of its month (kept), b2 is old and not (goes), b3 is new.
  if (select count(*) from public.backup_prune_list()) <> 1
     or (select id from public.backup_prune_list()) <> b2 then
    raise exception 'prune: %', (select json_agg(p) from public.backup_prune_list() p);
  end if;
  if not exists (select 1 from public.r2_refs() where key = '_backup/db/zz-3.json.gz'
                   and how = 'database backup') then
    raise exception 'a backup is an unused file';
  end if;
  perform public.backup_deleted(b2);
  if exists (select 1 from public.r2_refs() where key = '_backup/db/zz-2.json.gz') then
    raise exception 'a deleted backup is still in use';
  end if;

  -- ── connecting a channel ────────────────────────────────────────────────
  if public.archive_connect(5, 'a person', 'x') <> 'not_a_channel' then
    raise exception 'a private chat became the archive';
  end if;
  if public.archive_connect(-100123, 'Archive', '111') <> 'connected' then
    raise exception 'connect';
  end if;
  if public.archive_connect(-100123, 'Archive', '111') <> 'same' then
    raise exception 'connect twice';
  end if;

  -- ── three films: forwarded, uploaded, too big for Telegram ──────────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Archive test', 'zz-archive', false, 'draft', owner_id) returning id into t1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes)
  values (t1, 'video', 'innocent-media', 'zz-archive/video/fwd.mp4', 0, true, 1000)
  returning id into fwd;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes)
  values (t1, 'video', 'innocent-media', 'zz-archive/video/con.mp4', 1, false, 2000)
  returning id into con;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes)
  values (t1, 'video', 'innocent-media', 'zz-archive/video/huge.mp4', 2, false, 3000000000)
  returning id into huge;
  insert into public.vault_copies (asset_id, chat_id, message_id, unique_id, bytes)
  values (fwd, 111, 5, 'uniq-fwd', 1000);
  -- The real catalogue's films would take the five places per tick first; a
  -- failure an hour ago keeps each of them out of this test's way.
  insert into public.vault_jobs (asset_id, kind, state, finished_at)
  select a.id, 'archive', 'failed', now() from public.title_assets a
   where a.kind = 'video' and a.title_id <> t1;

  perform public.vault_schedule();
  if not exists (select 1 from public.vault_jobs where asset_id = fwd and kind = 'archive' and state = 'queued')
     or not exists (select 1 from public.vault_jobs where asset_id = con and kind = 'archive' and state = 'queued') then
    raise exception 'archive jobs were not queued';
  end if;
  if exists (select 1 from public.vault_jobs where asset_id = huge and kind = 'archive') then
    raise exception 'a film over 2000 MB was queued for Telegram';
  end if;

  -- ── the forwarded film: copied, and the copy row moves to the channel ───
  update public.vault_jobs set not_before = now() + interval '1 hour'
   where asset_id = con and kind = 'archive';
  select * into j from public.vault_claim_v2();
  if j.asset_id <> fwd or j.kind <> 'archive' or j.archive_chat <> -100123 or j.chat_id <> 111 then
    raise exception 'claim forwarded: %', row_to_json(j);
  end if;
  if public.vault_finish(j.job_id, true, 'ok', 'x', 1000) <> 'use_vault_archive_finish' then
    raise exception 'an archive job went through vault_finish';
  end if;
  v := public.vault_archive_finish(j.job_id, true, 'copied', -999, 77, 'uniq-fwd', 1000);
  if v <> 'wrong_chat' then raise exception 'wrong chat accepted: %', v; end if;
  -- wrong_chat failed the job; queue a fresh one.
  insert into public.vault_jobs (asset_id, kind) values (fwd, 'archive');
  select * into j from public.vault_claim_v2();
  v := public.vault_archive_finish(j.job_id, true, 'copied', -100123, 77, 'uniq-fwd', 1000);
  if v <> 'archived' then raise exception 'archive: %', v; end if;
  if not exists (select 1 from public.vault_copies c where c.asset_id = fwd and c.chat_id = -100123
                   and c.message_id = 77 and c.origin_chat_id = 111 and c.origin_message_id = 5
                   and c.archived_at is not null and c.state = 'ok') then
    raise exception 'copy row: %', (select row_to_json(c) from public.vault_copies c where c.asset_id = fwd);
  end if;

  -- ── the console upload: no Telegram copy until it is in the channel ─────
  update public.vault_jobs set not_before = now() where asset_id = con and kind = 'archive';
  select * into j from public.vault_claim_v2();
  if j.asset_id <> con or j.chat_id is not null or j.object_key <> 'zz-archive/video/con.mp4' then
    raise exception 'claim console upload: %', row_to_json(j);
  end if;
  v := public.vault_archive_finish(j.job_id, true, 'sent', -100123, 78, 'uniq-con', 1999);
  if v <> 'size_mismatch' then raise exception 'short upload accepted: %', v; end if;
  if exists (select 1 from public.vault_copies where asset_id = con) then
    raise exception 'a short upload became the archive copy';
  end if;
  -- A failure waits a day; an archived film is not sent again.
  update public.vault_jobs set finished_at = now() - interval '2 days'
   where asset_id = fwd and state = 'failed';
  perform public.vault_schedule();
  if exists (select 1 from public.vault_jobs where asset_id in (fwd, con) and kind = 'archive'
               and state = 'queued') then
    raise exception 'archived or just-failed film queued again';
  end if;
  update public.vault_jobs set finished_at = now() - interval '2 days'
   where asset_id = con and kind = 'archive' and state = 'failed';
  perform public.vault_schedule();
  select * into j from public.vault_claim_v2();
  if j.asset_id <> con then raise exception 'retry after a day: %', row_to_json(j); end if;
  v := public.vault_archive_finish(j.job_id, true, 'sent', -100123, 79, 'uniq-con', 2000);
  if v <> 'archived' then raise exception 'console archive: %', v; end if;
  if not exists (select 1 from public.vault_copies c where c.asset_id = con and c.chat_id = -100123
                   and c.source = 'archive channel' and c.origin_chat_id is null) then
    raise exception 'console copy row';
  end if;

  -- ── disconnecting ───────────────────────────────────────────────────────
  insert into public.vault_jobs (asset_id, kind) values (huge, 'archive');
  if public.archive_disconnect(-999, 'x') <> 'not_the_archive' then
    raise exception 'another channel disconnected the archive';
  end if;
  if public.archive_disconnect(null, 'removed') <> 'disconnected' then raise exception 'disconnect'; end if;
  if exists (select 1 from public.vault_jobs where kind = 'archive' and state = 'queued') then
    raise exception 'archive work queued with no channel';
  end if;
  if exists (select 1 from public.vault_claim_v2()) then
    raise exception 'archive work handed out with no channel';
  end if;
  -- And the old claim, which the edge function deployed before 032 calls,
  -- never hands out an archive job at all.
  update public.admin_settings set archive_chat_id = -100123 where true;
  -- A film WITH a Telegram copy, which is exactly what the old claim looks for.
  insert into public.vault_jobs (asset_id, kind) values (fwd, 'archive');
  if exists (select 1 from public.vault_claim() c where c.kind = 'archive') then
    raise exception 'the old claim handed out an archive job';
  end if;
  update public.admin_settings set archive_chat_id = null where true;

  -- ── the Status page ─────────────────────────────────────────────────────
  perform public.runner_tick('ingest', '{"tg_api_id": true}');
  perform public.runner_tick('ingest', null);
  js := public.ops_status();
  if js -> 'runners' -> 0 ->> 'name' <> 'ingest'
     or (js -> 'runners' -> 0 -> 'info' ->> 'tg_api_id') <> 'true' then
    raise exception 'runner tick: %', js -> 'runners';
  end if;
  if (js -> 'films' ->> 'archived')::int < 2 or jsonb_array_length(js -> 'backups') < 2
     or not (js ? 'archive') or js ->> 'migration' is null then
    raise exception 'ops_status: %', js;
  end if;

  raise exception 'BACKUP ARCHIVE TEST PASSED';
end $$;
