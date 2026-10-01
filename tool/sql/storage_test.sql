-- The storage policy's database   (migration 029)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `STORAGE TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter are the ones that lose a film: a master deleted from
-- R2 when its Telegram copy was never looked at, or was gone; an archived
-- title put back in the app before its films are; a restore that accepts a
-- short file; a bin that deletes a streaming copy the encoder has just
-- written again.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  ed_id    uuid := '00000000-0000-4000-8000-0000000000c3';
  t1 uuid; t2 uuid; a1 uuid; p1 uuid; c1 uuid;
  j record; v text; n integer; r record; js jsonb;
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at)
  values (ed_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'ed3@example.com', now());
  insert into public.admins (user_id, email, role) values (ed_id, 'ed3@example.com', 'editor');
  -- Nothing else in the queue may answer the claims below.
  update public.vault_jobs set state = 'done' where state in ('queued', 'running');

  -- ── a live title whose film came from Telegram, with a ladder ──────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Vault test', 'zz-vault', false, 'draft', owner_id) returning id into t1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes,
                                   transcode_state, transcode_at)
  values (t1, 'video', 'innocent-media', 'zz-vault/video/film.mp4', 0, true, 1000,
          'ready', now() - interval '2 days')
  returning id into a1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes)
  values (t1, 'photo', 'innocent-public', 'zz-vault/photo/p.jpg', 1, true, 50) returning id into p1;
  insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes)
  values (a1, 720, 2500, 'zz-vault/video/film-720p.mp4', 300);
  update public.titles set status = 'published' where id = t1;
  if (select review_state from public.titles where id = t1) <> 'approved' then
    raise exception 'fixture: not approved';
  end if;
  insert into public.ingest_jobs (tg_file_id, tg_unique_id, tg_chat_id, tg_message_id, file_name,
                                  bytes, kind, bucket, object_key, state, title_id, finished_at)
  values ('zz-file', 'zz-uniq-vault', 111, 222, 'film.mp4', 1000, 'video', 'innocent-media',
          'zz-vault/video/film.mp4', 'done', t1, now());

  -- ── a console upload: no Telegram copy ─────────────────────────────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Console only', 'zz-console', false, 'draft', owner_id) returning id into t2;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary, bytes,
                                   transcode_state)
  values (t2, 'video', 'innocent-media', 'zz-console/video/c.mp4', 0, true, 500, 'ready')
  returning id into c1;
  insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes)
  values (c1, 480, 1200, 'zz-console/video/c-480p.mp4', 100);

  -- ── the Telegram copy is recorded, once ────────────────────────────────
  perform public.vault_sync();
  perform public.vault_sync();
  if (select count(*) from public.vault_copies where asset_id = a1) <> 1 then
    raise exception 'vault_sync did not record the forwarded film exactly once';
  end if;
  if exists (select 1 from public.vault_copies where asset_id in (c1, p1)) then
    raise exception 'a console upload or a photo got a Telegram copy';
  end if;

  -- ── freeing a master: owner only, and never on an unchecked copy ───────
  if public.master_offload(a1, ed_id) <> 'not_owner' then raise exception 'an editor freed a master'; end if;
  if public.master_offload(c1, owner_id) <> 'no_telegram_copy' then raise exception 'console upload freed'; end if;
  if public.master_offload(p1, owner_id) <> 'not_a_video' then raise exception 'photo freed'; end if;
  v := public.master_offload(a1, owner_id);
  if v <> 'not_verified' then raise exception 'unchecked copy: %', v; end if;
  if not exists (select 1 from public.vault_jobs where asset_id = a1 and kind = 'verify' and state = 'queued') then
    raise exception 'no check was asked for';
  end if;
  if (select master_state from public.title_assets where id = a1) <> 'r2' then
    raise exception 'the master moved before its copy was checked';
  end if;

  -- the runner looks, and finds it
  select * into j from public.vault_claim();
  if j.asset_id is distinct from a1 or j.kind <> 'verify' or j.chat_id <> 111 or j.message_id <> 222
     or j.unique_id <> 'zz-uniq-vault' or j.bytes <> 1000 then
    raise exception 'claim answered %', row_to_json(j);
  end if;
  if public.vault_finish(j.job_id, true, 'ok', 'same file', null) <> 'ok' then raise exception 'verify ok'; end if;
  if not public.vault_fresh(a1) then raise exception 'not fresh after a check'; end if;

  -- a pinned title keeps its master
  update public.titles set pinned = true where id = t1;
  if public.master_offload(a1, owner_id) <> 'pinned' then raise exception 'a pinned master was freed'; end if;
  update public.titles set pinned = false where id = t1;

  v := public.master_offload(a1, owner_id);
  if v <> 'offloaded' then raise exception 'offload: %', v; end if;
  if (select master_state from public.title_assets where id = a1) <> 'telegram' then raise exception 'state'; end if;
  if not exists (select 1 from public.r2_trash where key = 'zz-vault/video/film.mp4' and vault_asset = a1
                   and purged_at is null and restored_at is null) then
    raise exception 'the R2 copy did not go to the bin';
  end if;
  if exists (select 1 from public.r2_refs() where key = 'zz-vault/video/film.mp4') then
    raise exception 'a freed master is still counted as in use';
  end if;
  if not exists (select 1 from public.r2_refs() where key = 'zz-vault/video/film-720p.mp4') then
    raise exception 'the streaming copy stopped being in use';
  end if;

  -- the encoder can neither be queued for it nor claim it
  if public.queue_transcode(a1) is not null then raise exception 'queued with no master'; end if;
  update public.title_assets set transcode_state = 'queued' where id = a1;
  if exists (select 1 from public.claim_transcode() where asset_id = a1) then
    raise exception 'the encoder claimed a film whose master is in Telegram';
  end if;
  update public.title_assets set transcode_state = 'ready' where id = a1;

  -- ── the bin's Telegram rule ────────────────────────────────────────────
  update public.r2_trash set purge_after = now() - interval '1 minute'
   where key = 'zz-vault/video/film.mp4' and purged_at is null and restored_at is null;
  if not exists (select 1 from public.r2_trash_due(500) where key = 'zz-vault/video/film.mp4') then
    raise exception 'a freshly checked copy held the delete back';
  end if;
  update public.vault_copies set verified_at = now() - interval '4 days' where asset_id = a1;
  if exists (select 1 from public.r2_trash_due(500) where key = 'zz-vault/video/film.mp4') then
    raise exception 'deleted on a check four days old';
  end if;
  -- the housekeeping asks for the check the delete is waiting on
  perform public.vault_schedule();
  if not exists (select 1 from public.vault_jobs where asset_id = a1 and kind = 'verify' and state = 'queued') then
    raise exception 'the waiting delete did not ask for a check';
  end if;
  -- …and the check finds the message gone: everything comes back
  select * into j from public.vault_claim();
  if public.vault_finish(j.job_id, true, 'missing', 'message deleted', null) <> 'missing' then
    raise exception 'verify missing';
  end if;
  if (select master_state from public.title_assets where id = a1) <> 'r2' then
    raise exception 'a lost Telegram copy did not put the master back';
  end if;
  if exists (select 1 from public.r2_trash where key = 'zz-vault/video/film.mp4'
               and purged_at is null and restored_at is null) then
    raise exception 'the master is still in the bin after its Telegram copy was lost';
  end if;
  if coalesce((select storage_note from public.titles where id = t1), '') not like 'Telegram copy%' then
    raise exception 'the owner is not told on the page';
  end if;
  if public.master_offload(a1, owner_id) <> 'not_verified' then
    raise exception 'freed again on a copy known to be gone';
  end if;
  update public.vault_jobs set state = 'done' where asset_id = a1 and state = 'queued';

  -- the copy is fine again (say the operator forwarded it again)
  update public.vault_copies set state = 'ok', verified_at = now(), note = null where asset_id = a1;
  update public.titles set storage_note = null where id = t1;

  -- ── keep: straight out of the bin while it is there ────────────────────
  if public.master_offload(a1, owner_id) <> 'offloaded' then raise exception 'offload 2'; end if;
  if public.master_keep(a1, ed_id) <> 'kept' then raise exception 'keep from the bin'; end if;
  if (select master_state from public.title_assets where id = a1) <> 'r2' then raise exception 'keep state'; end if;

  -- restoring it on the Files page counts too
  if public.master_offload(a1, owner_id) <> 'offloaded' then raise exception 'offload 3'; end if;
  select id into n from public.r2_trash where key = 'zz-vault/video/film.mp4'
     and purged_at is null and restored_at is null;
  if public.r2_trash_restore(n, owner_id) <> 'restored' then raise exception 'bin restore'; end if;
  if (select master_state from public.title_assets where id = a1) <> 'r2' then
    raise exception 'restoring a freed master from the bin left it marked as in Telegram';
  end if;

  -- ── keep after the bin: fetched from Telegram, and checked ─────────────
  if public.master_offload(a1, owner_id) <> 'offloaded' then raise exception 'offload 4'; end if;
  update public.r2_trash set purged_at = now() where key = 'zz-vault/video/film.mp4'
     and purged_at is null and restored_at is null;
  if public.master_keep(a1, owner_id) <> 'restoring' then raise exception 'keep after purge'; end if;
  select * into j from public.vault_claim();
  if j.kind <> 'restore' or j.object_key <> 'zz-vault/video/film.mp4' then raise exception 'restore claim'; end if;
  if public.vault_finish(j.job_id, true, null, null, 999) <> 'size_mismatch' then
    raise exception 'a short file was accepted';
  end if;
  if (select master_state from public.title_assets where id = a1) <> 'telegram' then
    raise exception 'state after a short fetch';
  end if;
  if public.master_keep(a1, owner_id) <> 'restoring' then raise exception 'keep again'; end if;
  select * into j from public.vault_claim();
  if public.vault_finish(j.job_id, true, null, null, 1000) <> 'restored' then raise exception 'restore'; end if;
  if (select master_state from public.title_assets where id = a1) <> 'r2' then raise exception 'restored state'; end if;

  -- a wait is not an attempt; three errors are the end
  perform public.vault_request(a1, 'verify', owner_id);
  select * into j from public.vault_claim();
  if public.vault_defer(j.job_id, 60) <> 'deferred' then raise exception 'defer'; end if;
  select attempts, state into r from public.vault_jobs where id = j.job_id;
  if r.attempts <> 0 or r.state <> 'queued' then raise exception 'defer kept the attempt: %', row_to_json(r); end if;
  if exists (select 1 from public.vault_claim()) then raise exception 'claimed before its wait'; end if;
  update public.vault_jobs set not_before = now() where id = j.job_id;
  for n in 1..3 loop
    update public.vault_jobs set not_before = now() where id = j.job_id;
    select * into r from public.vault_claim();
    v := public.vault_finish(r.job_id, false, null, 'network', null);
  end loop;
  if v <> 'failed' then raise exception 'three errors gave %', v; end if;

  -- ── archive: owner, every film checked, out of the app but still approved
  if (public.title_archive(t1, ed_id)) ->> 'error' <> 'not_owner' then raise exception 'editor archived'; end if;
  if (public.title_archive(t2, owner_id)) ->> 'error' <> 'no_telegram_copy' then
    raise exception 'a title with a console upload was archived';
  end if;
  update public.vault_copies set verified_at = now() - interval '5 days' where asset_id = a1;
  if (public.title_archive(t1, owner_id)) ->> 'error' <> 'not_verified' then raise exception 'archive unchecked'; end if;
  update public.vault_jobs set state = 'done' where asset_id = a1 and state = 'queued';
  update public.vault_copies set verified_at = now() where asset_id = a1;
  js := public.title_archive(t1, owner_id);
  if js ->> 'error' is not null or (js ->> 'binned')::int <> 2 then raise exception 'archive: %', js; end if;
  select * into r from public.titles where id = t1;
  if r.published or r.status <> 'hidden' or r.storage_state <> 'archived' or not r.archived_was_live then
    raise exception 'archived title: %', row_to_json(r);
  end if;
  if r.review_state <> 'approved' then
    raise exception 'archiving sent the title back to editing (%)', r.review_state;
  end if;
  if exists (select 1 from public.asset_renditions where asset_id = a1) then raise exception 'ladder rows left'; end if;
  if (select jsonb_array_length(archived_ladder) from public.title_assets where id = a1) <> 1 then
    raise exception 'the ladder was not remembered';
  end if;
  if (select count(*) from public.r2_trash where vault_asset = a1 and purged_at is null and restored_at is null) <> 2 then
    raise exception 'master and rung are not both in the bin';
  end if;
  begin
    update public.titles set status = 'published' where id = t1;
    raise exception 'an archived title went back in the app';
  exception when check_violation then null;
  end;

  -- restore inside the week: instant, and back in the app as it was
  if (public.title_restore(t1, ed_id)) ->> 'state' <> 'hot' then raise exception 'instant restore'; end if;
  select * into r from public.titles where id = t1;
  if not r.published or r.status <> 'published' or r.review_state <> 'approved' or r.storage_state <> 'hot' then
    raise exception 'restored title: %', row_to_json(r);
  end if;
  if not public.asset_has_ladder(a1) then raise exception 'the ladder did not come back'; end if;
  if exists (select 1 from public.r2_trash where vault_asset = a1 and purged_at is null and restored_at is null) then
    raise exception 'files of a restored title are still waiting to be deleted';
  end if;

  -- ── archive, the week passes, restore from Telegram ────────────────────
  js := public.title_archive(t1, owner_id);
  update public.r2_trash set purged_at = now() where vault_asset = a1 and purged_at is null and restored_at is null;
  js := public.title_restore(t1, owner_id);
  if js ->> 'state' <> 'restoring' or (js ->> 'fetching')::int <> 1 then raise exception 'restore: %', js; end if;
  if (select published from public.titles where id = t1) then raise exception 'live with nothing in R2'; end if;
  select * into j from public.vault_claim();
  if public.vault_finish(j.job_id, true, null, null, 1000) <> 'restored' then raise exception 'fetch back'; end if;
  if (select transcode_state from public.title_assets where id = a1) <> 'queued' then
    raise exception 'the ladder was not queued again';
  end if;
  if (select published from public.titles where id = t1) then
    raise exception 'live before its streaming copies were made';
  end if;
  perform public.record_renditions(a1,
    '[{"height":720,"kbps":2500,"object_key":"zz-vault/video/film-720p.mp4","bytes":300}]', 'complete');
  perform public.vault_tick();
  select * into r from public.titles where id = t1;
  if not r.published or r.storage_state <> 'hot' then raise exception 'not back after the encoder: %', row_to_json(r); end if;

  -- the encoder fails: the owner can put it back on its master
  js := public.title_archive(t1, owner_id);
  update public.r2_trash set purged_at = now() where vault_asset = a1 and purged_at is null and restored_at is null;
  js := public.title_restore(t1, owner_id);
  select * into j from public.vault_claim();
  perform public.vault_finish(j.job_id, true, null, null, 1000);
  perform public.record_renditions(a1, null, 'encoder died');
  perform public.vault_tick();
  if coalesce((select storage_note from public.titles where id = t1), '') not like 'streaming copies failed%' then
    raise exception 'a failed encode is not explained';
  end if;
  if public.title_restore_finish(t1, ed_id) <> 'not_owner' then raise exception 'editor finished'; end if;
  if public.title_restore_finish(t1, owner_id) <> 'finished' then raise exception 'finish'; end if;
  if not (select published from public.titles where id = t1) then raise exception 'finish did not publish'; end if;

  -- a draft stays a draft through archive and restore
  update public.titles set status = 'draft' where id = t1;
  if (select review_state from public.titles where id = t1) <> 'editing' then
    raise exception 'taking a hot title down no longer sends it back to editing';
  end if;
  update public.title_assets set transcode_state = 'ready' where id = a1;
  insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes)
  values (a1, 720, 2500, 'zz-vault/video/film-720p.mp4', 300) on conflict do nothing;
  js := public.title_archive(t1, owner_id);
  js := public.title_restore(t1, owner_id);
  if (select published from public.titles where id = t1) then raise exception 'a draft came back live'; end if;

  -- ── the overview and the owner's message ───────────────────────────────
  select * into r from public.storage_overview() where title_id = t1;
  if r.films <> 1 or r.films_with_copy <> 1 or jsonb_array_length(r.assets) <> 1 then
    raise exception 'overview: %', row_to_json(r);
  end if;
  update public.admin_settings set storage_alert_gb = 0, storage_noticed_at = null where id;
  v := public.storage_notice();
  if v is null or v not like 'Storage: R2 holds%' then raise exception 'notice: %', v; end if;
  if public.storage_notice() is not null then raise exception 'the same notice twice in a day'; end if;

  raise exception 'STORAGE TEST PASSED';
end $$;
