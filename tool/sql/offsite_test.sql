-- The off-site copy and the APK mirrors (migration 045)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `OFFSITE TEST PASSED`; any
-- other exception names the case that failed. No statement here touches a
-- row it did not make (the SQL tool holds blanket updates for a person to
-- confirm, and the live release row is never written by a test).
--
-- The cases that matter: a copy recorded at a size the bucket did not report;
-- work queued while no bucket is set up; a copy found missing and never made
-- again; a deleted film whose copy lives for ever, or one deleted the moment
-- its film was (no week to undo it); a mirror that is not https; anybody but
-- the service role reaching any of it.
do $$
declare
  vid uuid; pic uuid; ghost uuid := gen_random_uuid();
  j record; v text; n integer; js jsonb; b1 bigint; base integer;
begin
  -- The tables are this migration's own and empty until a bucket is set up;
  -- the catalogue's real files count as copied already, so only this test's
  -- are queued.
  if exists (select 1 from public.offsite_jobs where state in ('queued', 'running')) then
    raise exception 'run this before the off-site bucket is set up, or on a copy';
  end if;
  insert into public.offsite_copies (asset_id, object_key, bytes)
  select a.id, 'pre/' || a.id, a.bytes from public.title_assets a
  on conflict (asset_id) do nothing;
  perform public.offsite_config(null, null);

  -- ── no bucket, no work ──────────────────────────────────────────────────
  if public.offsite_on() then raise exception 'on with no bucket'; end if;
  if public.offsite_schedule() <> 0 then raise exception 'queued with no bucket'; end if;
  if exists (select 1 from public.offsite_claim()) then raise exception 'claimed with no bucket'; end if;

  -- A bucket said two days ago and not since: the secret was removed.
  perform public.offsite_config('s3.example.com/innocent-offsite', null);
  update public.admin_settings set offsite_seen_at = now() - interval '3 days'
   where offsite_where is not null;
  if public.offsite_on() then raise exception 'on after the secret went'; end if;

  perform public.offsite_config('s3.example.com/innocent-offsite', 'https://pub.example/apk-bucket/');
  if not public.offsite_on() then raise exception 'not on with a bucket'; end if;
  perform public.offsite_config('', '');
  if public.offsite_on() then raise exception 'an empty name is a bucket'; end if;
  perform public.offsite_config('s3.example.com/innocent-offsite', null);
  base := (public.offsite_status()->>'copied')::int;

  -- ── two files of one title: the film first ──────────────────────────────
  insert into public.titles (title, slug, published)
  values ('offsite test', 'offsite-test-' || substr(md5(random()::text), 1, 8), false)
  returning id into vid;
  insert into public.title_assets (title_id, kind, bucket, object_key, bytes, added_at)
  values (vid, 'photo', 'innocent-public', 'offsite-test/p.jpg', 1000, now() - interval '1 hour')
  returning id into pic;
  insert into public.title_assets (title_id, kind, bucket, object_key, bytes, added_at)
  values (vid, 'video', 'innocent-media', 'offsite-test/film.mp4', 123456789, now())
  returning id into vid;

  -- A file too big for one PUT is not queued.
  insert into public.title_assets (title_id, kind, bucket, object_key, bytes, sort_order)
  select title_id, 'video', 'innocent-media', 'offsite-test/huge.mp4', 6000000000, 1
    from public.title_assets where id = vid;

  n := public.offsite_schedule();
  if n <> 2 then raise exception 'schedule queued % (want 2)', n; end if;
  if public.offsite_schedule() <> 0 then raise exception 'queued twice'; end if;

  select * into j from public.offsite_claim();
  if j.asset_id is distinct from vid then raise exception 'the film is not first'; end if;
  if j.object_key <> 'offsite-test/film.mp4' or j.bytes <> 123456789
     or j.bucket <> 'innocent-media' or j.master_state <> 'r2' then
    raise exception 'claim row: %', row_to_json(j);
  end if;

  -- ── the size is the bucket's, and only the file's own size counts ──────
  v := public.offsite_finish(j.job_id, true, null, 'masters/x.mp4', 123456000, null);
  if v <> 'size_mismatch' then raise exception 'short copy: %', v; end if;
  if exists (select 1 from public.offsite_copies where asset_id = vid) then
    raise exception 'a short copy was recorded';
  end if;
  v := public.offsite_finish(j.job_id, true, null, 'masters/x.mp4', 123456789, null);
  if v <> 'not_running' then raise exception 'finished twice: %', v; end if;

  -- Failed today, so not queued again until tomorrow.
  if public.offsite_schedule() <> 0 then raise exception 'a failed copy was queued at once'; end if;
  update public.offsite_jobs set finished_at = now() - interval '2 days' where id = j.job_id;
  if public.offsite_schedule() <> 1 then raise exception 'a failed copy never comes back'; end if;
  -- One transaction has one now(): make the new job younger, as it would be.
  update public.offsite_jobs set created_at = now() + interval '1 minute'
   where asset_id = vid and state = 'queued';

  -- The photo's job, then the film's again.
  select * into j from public.offsite_claim();
  if j.asset_id is distinct from pic then raise exception 'second claim is not the photo'; end if;
  -- A failure is retried twice, then given up.
  v := public.offsite_finish(j.job_id, false, 'PUT 500', null, null, null);
  if v <> 'retry' then raise exception 'first failure: %', v; end if;
  update public.offsite_jobs set not_before = now(), attempts = 3 where id = j.job_id;
  select * into j from public.offsite_claim();
  if j.asset_id is distinct from pic then raise exception 'the retry was not claimed'; end if;
  v := public.offsite_finish(j.job_id, false, 'PUT 500', null, null, null);
  if v <> 'failed' then raise exception 'fourth failure: %', v; end if;

  select * into j from public.offsite_claim();
  if j.asset_id is distinct from vid then raise exception 'the film did not come back'; end if;
  v := public.offsite_finish(j.job_id, true, null, 'masters/' || vid || '.mp4', 123456789,
                             repeat('a', 64));
  if v <> 'copied' then raise exception 'copy: %', v; end if;
  if not public.offsite_fresh(vid) then raise exception 'a new copy is not fresh'; end if;

  js := public.offsite_status();
  if (js->>'copied')::int <> base + 1 or (js->>'too_big')::int <> 1
     or not (js->>'on')::boolean then
    raise exception 'status: %', js;
  end if;

  -- ── looked at weekly; a missing one is copied again ─────────────────────
  if exists (select 1 from public.offsite_verify_due(20) where asset_id = vid) then
    raise exception 'a new copy is due a check';
  end if;
  update public.offsite_copies set verified_at = now() - interval '8 days' where asset_id = vid;
  if public.offsite_fresh(vid) then raise exception 'an old look is fresh'; end if;
  if not exists (select 1 from public.offsite_verify_due(20) where asset_id = vid) then
    raise exception 'an old copy is not due a check';
  end if;
  v := public.offsite_verified(vid, true, 123456789);
  if v <> 'ok' or not public.offsite_fresh(vid) then raise exception 'a good look: %', v; end if;
  v := public.offsite_verified(vid, true, 99);
  if v <> 'missing' then raise exception 'a wrong size is not missing: %', v; end if;
  update public.offsite_jobs set state = 'done'
   where state in ('queued', 'running') and asset_id in (vid, pic);
  perform public.offsite_schedule();
  if not exists (select 1 from public.offsite_jobs
                  where asset_id = vid and state = 'queued') then
    raise exception 'a missing copy is not made again';
  end if;

  -- ── a deleted file's copy goes a week later, not at once, not never ─────
  insert into public.offsite_copies (asset_id, object_key, bytes)
  values (ghost, 'masters/' || ghost || '.mp4', 5);
  if exists (select 1 from public.offsite_prune_due(50) where asset_id = ghost) then
    raise exception 'deleted the moment its file went';
  end if;
  if (select orphaned_at from public.offsite_copies where asset_id = ghost) is null then
    raise exception 'an orphan was not noticed';
  end if;
  update public.offsite_copies set orphaned_at = now() - interval '8 days' where asset_id = ghost;
  if not exists (select 1 from public.offsite_prune_due(50) where asset_id = ghost) then
    raise exception 'an orphan is never deleted';
  end if;
  perform public.offsite_pruned(ghost);
  if (select state from public.offsite_copies where asset_id = ghost) <> 'deleted' then
    raise exception 'pruned is not deleted';
  end if;
  -- A copy of a file that is still there is never an orphan.
  if (select orphaned_at from public.offsite_copies where asset_id = vid) is not null then
    raise exception 'a live copy was orphaned';
  end if;

  -- ── a copy whose file was deleted while it was being made ───────────────
  if public.offsite_orphan(vid, 'masters/' || vid || '.mp4') <> 'not_an_orphan' then
    raise exception 'a live file was orphaned';
  end if;
  ghost := gen_random_uuid();
  if public.offsite_orphan(ghost, 'evil/../' || ghost) <> 'bad_key' then
    raise exception 'a key outside masters/ was accepted';
  end if;
  if public.offsite_orphan(ghost, 'masters/' || ghost || '.mp4') <> 'orphaned'
     or (select orphaned_at from public.offsite_copies where asset_id = ghost) is null then
    raise exception 'an upload for a deleted file is not an orphan';
  end if;

  -- ── backups ─────────────────────────────────────────────────────────────
  b1 := public.backup_record('_backup/db/test-offsite.json.gz', 10, 20, repeat('b', 64),
                             '{}'::jsonb, 'manual', null, null);
  if not exists (select 1 from public.backup_offsite_due(50) where id = b1) then
    raise exception 'a new backup is not due off-site';
  end if;
  perform public.backup_offsite_done(b1, 'db/test-offsite.json.gz');
  if exists (select 1 from public.backup_offsite_due(50) where id = b1) then
    raise exception 'a copied backup is due again';
  end if;
  if public.backup_offsite_key(b1) <> 'db/test-offsite.json.gz' then
    raise exception 'backup key not kept';
  end if;

  -- ── mirrors (the rule, not the live row) ────────────────────────────────
  if public.all_https(array['http://plain.example/a.apk']) then raise exception 'http is https'; end if;
  if not public.all_https(array['https://a.example/x.apk', 'https://github.com/x']) then
    raise exception 'https refused';
  end if;
  if not public.all_https('{}'::text[]) then raise exception 'none refused'; end if;
  if not exists (select 1 from pg_constraint where conname = 'app_releases_mirrors_ck'
                  and pg_get_constraintdef(oid) like '%cardinality(apk_mirrors) <= 4%'
                  and pg_get_constraintdef(oid) like '%all_https(apk_mirrors_arm32)%') then
    raise exception 'the mirror constraint is missing';
  end if;
  if not has_column_privilege('anon', 'public.app_releases', 'apk_mirrors', 'select')
     or not has_column_privilege('anon', 'public.app_releases', 'apk_mirrors_arm32', 'select') then
    raise exception 'the app cannot read the mirrors';
  end if;

  -- ── nobody but the service role ─────────────────────────────────────────
  if has_function_privilege('anon', 'public.offsite_status()', 'execute')
     or has_function_privilege('authenticated', 'public.offsite_claim()', 'execute')
     or has_function_privilege('anon', 'public.offsite_finish(uuid,boolean,text,text,bigint,text)', 'execute') then
    raise exception 'an off-site function is open to the app';
  end if;
  if has_table_privilege('authenticated', 'public.offsite_copies', 'select')
     or has_table_privilege('anon', 'public.offsite_jobs', 'select') then
    raise exception 'an off-site table is open to the app';
  end if;

  raise exception 'OFFSITE TEST PASSED';
end $$;
