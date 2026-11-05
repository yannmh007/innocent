-- Sealed objects in the Files page, a twin that follows its object, sealed
-- work only for a runner that seals, the Telegram pipeline's keys, and the
-- Files page's moves and deletes (migrations 069, 070, 071, 073).
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `MEDIA KEYS TEST PASSED`; any
-- other exception names the case that failed.
--
-- What would lose a film without a word: a sealed object the Files page
-- calls unused (binned, then purged a week later), and a re-made rung or
-- still whose OLD twin stays — the app opens the stale copy, or two rows
-- name one plain object and either may be read.
do $$
declare
  b      text := 'zz-media';
  w      text := repeat('A', 80);                    -- a wrap's shape (length 80)
  h      text := 'K' || repeat('A', 53) || '==';     -- a header's shape
  d      text := repeat('B', 43) || '=';             -- an image DEK's shape
  k1     text := 's/' || md5('zz-one');
  k2     text := 's/' || md5('zz-two');
  k3     text := 's/' || md5('zz-three');
  k4     text := 's/' || md5('zz-four');
  k5     text := 's/' || md5('zz-five');
  id1    uuid := gen_random_uuid();
  id2    uuid := gen_random_uuid();
  id3    uuid := gen_random_uuid();
  id4    uuid := gen_random_uuid();
  id5    uuid := gen_random_uuid();
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  t_open uuid; t_other uuid; a_open uuid; a_other uuid; a_born uuid;
  t_cat  uuid; a_cat uuid; a_tg uuid; a_rest uuid; job uuid; vj uuid; tid bigint;
  k_new  text := 's/' || md5('zz-restored');
  k_old  text := 's/' || md5('zz-old-master');
  t_mv   uuid; a_mv uuid; mv uuid; id_mv uuid := gen_random_uuid(); id_mvi uuid := gen_random_uuid();
  j      jsonb;
  v      text;
  n      integer;
begin
  -- The catalogue names the twins' plain objects (071: a twin is in use
  -- while what it copies is).
  insert into public.titles (title, slug, published, status, created_by)
  values ('Seal test catalogue', 'zz-seal-cat', false, 'draft', owner_id) returning id into t_cat;
  insert into public.title_assets (title_id, kind, bucket, object_key, thumb_key, sort_order, master_state)
  values (t_cat, 'video', b, 'zz-film/video/a.mp4', 'zz-film/video/thumb/a-f00.jpg', 1, 'r2')
  returning id into a_cat;
  insert into public.asset_renditions (asset_id, height, kbps, object_key)
  values (a_cat, 240, 300, 'zz-film/video/a-240p.mp4');

  -- ── a film's twin: recorded, then the rung is made again ──────────────
  j := public.media_key_put('video', jsonb_build_object(
    'dek_id', id1, 'bucket', b, 'sealed_key', k1, 'plain_key', 'zz-film/video/a-240p.mp4',
    'kek_version', 1, 'wrapped', w, 'plain_size', 1000, 'sealed_size', public.media_sealed_size(1000),
    'kind', 'video', 'header', h));
  if not (j->>'recorded')::boolean or (j->>'kept')::boolean then raise exception 'first twin: %', j; end if;
  if not exists (select 1 from public.r2_refs() where key = k1 and how = 'sealed copy') then
    raise exception 'a film''s sealed copy is not in use for the Files page';
  end if;

  -- `done` repeats the rungs before: the same dek_id is kept as it is.
  j := public.media_key_put('video', jsonb_build_object(
    'dek_id', id1, 'bucket', b, 'sealed_key', k1, 'plain_key', 'zz-film/video/a-240p.mp4',
    'kek_version', 1, 'wrapped', w, 'plain_size', 1000, 'sealed_size', public.media_sealed_size(1000),
    'kind', 'video', 'header', h));
  if not (j->>'kept')::boolean then raise exception 'a repeat was not kept: %', j; end if;

  -- Made again: one row for the plain object, the new one; the old copy binned.
  j := public.media_key_put('video', jsonb_build_object(
    'dek_id', id2, 'bucket', b, 'sealed_key', k2, 'plain_key', 'zz-film/video/a-240p.mp4',
    'kek_version', 1, 'wrapped', w, 'plain_size', 2000, 'sealed_size', public.media_sealed_size(2000),
    'kind', 'video', 'header', h));
  if j->'replaced' <> jsonb_build_array(k1) then raise exception 'replaced: %', j; end if;
  select count(*) into n from public.media_keys where bucket = b and plain_key = 'zz-film/video/a-240p.mp4';
  if n <> 1 then raise exception 'two rows name one plain object (%)', n; end if;
  if not exists (select 1 from public.media_keys where dek_id = id2 and plain_size = 2000) then
    raise exception 'the new twin is not the row';
  end if;
  if not exists (select 1 from public.r2_trash where bucket = b and key = k1 and purged_at is null
                   and restored_at is null and purge_after > now() + interval '6 days') then
    raise exception 'the old sealed copy is not in the bin for a week';
  end if;
  if exists (select 1 from public.r2_refs() where key = k1) then
    raise exception 'the old sealed copy is still in use';
  end if;
  -- The bin's purge does not take it back out (nothing names it now), and
  -- it is not due before its week.
  if exists (select 1 from public.r2_trash_due(1000) x where x.key = k1) then
    raise exception 'the old copy is due at once';
  end if;

  -- A second row for one plain object is refused by the table itself.
  begin
    insert into public.media_keys (dek_id, bucket, sealed_key, plain_key, kek_version, wrapped,
                                   plain_size, sealed_size, kind, header)
    values (gen_random_uuid(), b, 's/' || md5('zz-dup'), 'zz-film/video/a-240p.mp4', 1, w, 5,
            public.media_sealed_size(5), 'video', h);
    raise exception 'DUP_ALLOWED';
  exception
    when unique_violation then null;
    when raise_exception then
      if sqlerrm = 'DUP_ALLOWED' then raise exception 'media_keys took a second twin of one object'; end if;
      raise;
  end;

  -- Born sealed: no plain key, never replaces anything, many may coexist.
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', id3, 'bucket', b, 'sealed_key', k3, 'plain_key', null,
    'kek_version', 1, 'wrapped', w, 'plain_size', 10, 'sealed_size', public.media_sealed_size(10),
    'kind', 'video', 'header', h));
  j := public.media_key_put('video', jsonb_build_object(
    'dek_id', id4, 'bucket', b, 'sealed_key', k4, 'plain_key', null,
    'kek_version', 1, 'wrapped', w, 'plain_size', 11, 'sealed_size', public.media_sealed_size(11),
    'kind', 'video', 'header', h));
  if j->'replaced' <> '[]'::jsonb then raise exception 'a born object replaced another: %', j; end if;
  if (select count(*) from public.media_keys where dek_id in (id3, id4)) <> 2 then
    raise exception 'two born objects do not coexist';
  end if;

  -- ── an image twin: the same rule in media_image_keys ──────────────────
  perform public.media_key_put('image', jsonb_build_object(
    'dek_id', id5, 'bucket', b, 'sealed_key', k5, 'plain_key', 'zz-film/video/thumb/a-f00.jpg',
    'dek', d, 'header', h, 'plain_size', 100, 'sealed_size', 140));
  if not exists (select 1 from public.r2_refs() where key = k5 and how = 'sealed copy') then
    raise exception 'an image''s sealed copy is not in use for the Files page';
  end if;
  j := public.media_key_put('image', jsonb_build_object(
    'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', 's/' || md5('zz-six'),
    'plain_key', 'zz-film/video/thumb/a-f00.jpg', 'dek', d, 'header', h,
    'plain_size', 120, 'sealed_size', 160));
  if j->'replaced' <> jsonb_build_array(k5) then raise exception 'image replaced: %', j; end if;
  if (select count(*) from public.media_image_keys where plain_key = 'zz-film/video/thumb/a-f00.jpg') <> 1
     or not exists (select 1 from public.media_image_keys where plain_key = 'zz-film/video/thumb/a-f00.jpg'
                      and plain_size = 120) then
    raise exception 'the new image twin is not the row';
  end if;

  -- ── what is refused ───────────────────────────────────────────────────
  begin
    perform public.media_key_put('audio', jsonb_build_object('dek_id', gen_random_uuid()));
    raise exception 'KIND_ALLOWED';
  exception when raise_exception then
    if sqlerrm = 'KIND_ALLOWED' then raise exception 'a kind that is neither video nor image'; end if;
  end;
  begin
    perform public.media_key_put('video', jsonb_build_object(
      'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', 'video/not-sealed.mp4'));
    raise exception 'KEY_ALLOWED';
  exception when raise_exception then
    if sqlerrm = 'KEY_ALLOWED' then raise exception 'a sealed key that is not s/<32 hex>'; end if;
  end;

  -- ── who may call it ───────────────────────────────────────────────────
  if has_function_privilege('anon', 'public.media_key_put(text, jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.media_key_put(text, jsonb)', 'execute') then
    raise exception 'an app role can record keys';
  end if;
  if not has_function_privilege('service_role', 'public.media_key_put(text, jsonb)', 'execute') then
    raise exception 'the functions cannot record keys';
  end if;

  -- ── 070: a runner that does not seal is never handed sealed work ──────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Seal test open', 'open-film-zz-seal', false, 'draft', owner_id) returning id into t_open;
  insert into public.titles (title, slug, published, status, created_by)
  values ('Seal test other', 'zz-seal-other', false, 'draft', owner_id) returning id into t_other;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state,
                                   transcode_state, added_at)
  values (t_open, 'video', b, 'open-film-zz-seal/video/m.mp4', 1, 'r2', 'queued', '2000-01-01')
  returning id into a_open;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state,
                                   transcode_state, added_at)
  values (t_other, 'video', b, 'zz-seal-other/video/m.mp4', 1, 'r2', 'queued', '2000-01-02')
  returning id into a_other;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state,
                                   transcode_state, added_at)
  values (t_other, 'video', b, k3, 2, 'r2', 'queued', '2000-01-03')
  returning id into a_born;

  update public.admin_settings set seal_new = 'canary';
  if not public.needs_sealing_runner('open-film-zz-seal/video/m.mp4', t_open) then
    raise exception 'canary: an open film does not need a sealing runner';
  end if;
  if public.needs_sealing_runner('zz-seal-other/video/m.mp4', t_other) then
    raise exception 'canary: another film needs a sealing runner';
  end if;
  if not public.needs_sealing_runner(k3, t_other) then
    raise exception 'a sealed master does not need a sealing runner';
  end if;
  -- Canary: the old runner gets the other film, never the open one or the born one.
  select count(*) into n from public.claim_transcode(false) c where c.asset_id in (a_open, a_born);
  if n <> 0 then raise exception 'canary: a runner that does not seal got sealed work'; end if;
  if (select transcode_state from public.title_assets where id = a_other) <> 'running' then
    raise exception 'canary: the runner that does not seal did not get the film it can do';
  end if;
  -- A sealing runner gets the open film first (the oldest).
  if not exists (select 1 from public.claim_transcode(true) c where c.asset_id = a_open) then
    raise exception 'canary: the sealing runner did not get the open film';
  end if;
  -- `on`: nothing for a runner that does not seal.
  update public.title_assets set transcode_state = 'queued' where id in (a_open, a_other);
  update public.admin_settings set seal_new = 'on';
  select count(*) into n from public.claim_transcode(false) c where c.asset_id in (a_open, a_other, a_born);
  if n <> 0 then raise exception 'on: a runner that does not seal got work'; end if;
  -- `off`: every plain film for anyone, never the born one.
  update public.admin_settings set seal_new = 'off';
  update public.title_assets set frames_state = 'queued' where id in (a_open, a_born);
  select count(*) into n from public.claim_frames(50, false) c where c.asset_id = a_born;
  if n <> 0 then raise exception 'off: a runner that does not seal got the stills of a sealed master'; end if;
  if not exists (select 1 from public.title_assets where id = a_open and frames_state = 'running') then
    raise exception 'off: the stills of a plain film were not claimed';
  end if;
  -- What a caller that names nothing gets is what it got before: everything.
  update public.title_assets set transcode_state = 'queued' where id = a_born;
  update public.title_assets set transcode_state = 'ready' where id in (a_open, a_other);
  if not exists (select 1 from public.claim_transcode() c where c.asset_id = a_born) then
    raise exception 'the default claim no longer takes sealed work';
  end if;

  -- ── 070: settle — a twin never outlives its object ────────────────────
  -- (id2 twins zz-film/…/a-240p.mp4; id3, id4 are born sealed k3, k4.)
  -- The rung written again, its new twin not made (sealing failed): the old one goes.
  j := public.media_keys_settle('video', b, array['zz-film/video/a-240p.mp4'], null, null);
  if j->'binned' <> jsonb_build_array(k2) then raise exception 'settle remade: %', j; end if;
  if exists (select 1 from public.media_keys where dek_id = id2) then
    raise exception 'a stale twin outlived its rung';
  end if;
  -- A born rung the ladder no longer names goes; one the catalogue still
  -- names (k3 is a_born's master) stays, and so does one made in this job.
  j := public.media_keys_settle('video', b, null, array[k3, k4], null);
  if j->'binned' <> jsonb_build_array(k4) then raise exception 'settle gone: %', j; end if;
  if not exists (select 1 from public.media_keys where dek_id = id3) then
    raise exception 'a sealed object still in use lost its key';
  end if;
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', id4, 'bucket', b, 'sealed_key', k4, 'plain_key', null,
    'kek_version', 1, 'wrapped', w, 'plain_size', 11, 'sealed_size', public.media_sealed_size(11),
    'kind', 'video', 'header', h));
  j := public.media_keys_settle('video', b, null, array[k4], array[id4]);
  if j->'binned' <> '[]'::jsonb then raise exception 'settle dropped what this job made: %', j; end if;
  -- Images: a still taken again with no new twin.
  j := public.media_keys_settle('image', b, array['zz-film/video/thumb/a-f00.jpg'], null, null);
  if jsonb_array_length(j->'binned') <> 1
     or exists (select 1 from public.media_image_keys where plain_key = 'zz-film/video/thumb/a-f00.jpg') then
    raise exception 'settle image: %', j;
  end if;
  if has_function_privilege('authenticated', 'public.media_keys_settle(text, text, text[], text[], uuid[])', 'execute')
     or has_function_privilege('anon', 'public.claim_transcode(boolean)', 'execute')
     or has_function_privilege('anon', 'public.needs_sealing_runner(text, uuid)', 'execute') then
    raise exception 'an app role can call a pipeline function';
  end if;

  -- ── 071: a key row lives as long as what it opens ─────────────────────
  -- A born object is in use through the catalogue's own entries, not twice.
  if exists (select 1 from public.r2_refs() where key = k3 and how = 'sealed copy') then
    raise exception 'a born object counted again as its own sealed copy';
  end if;
  -- A twin of a plain object nobody names is not in use.
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', 's/' || md5('zz-loose'),
    'plain_key', 'zz-film/video/nobody.mp4', 'kek_version', 1, 'wrapped', w, 'plain_size', 7,
    'sealed_size', public.media_sealed_size(7), 'kind', 'video', 'header', h));
  if exists (select 1 from public.r2_refs() where key = 's/' || md5('zz-loose')) then
    raise exception 'a twin of an unnamed object is in use';
  end if;
  -- A twin of a master kept in Telegram stays (a restore brings it back byte for byte).
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state, bytes)
  values (t_cat, 'video', b, 'zz-film/video/kept.mp4', 2, 'telegram', 7) returning id into a_tg;
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', 's/' || md5('zz-kept'),
    'plain_key', 'zz-film/video/kept.mp4', 'kek_version', 1, 'wrapped', w, 'plain_size', 7,
    'sealed_size', public.media_sealed_size(7), 'kind', 'video', 'header', h));
  if not exists (select 1 from public.r2_refs() where key = 's/' || md5('zz-kept') and how = 'sealed copy') then
    raise exception 'the twin of a master kept in Telegram is not in use';
  end if;
  if exists (select 1 from public.r2_refs() where key = 'zz-film/video/kept.mp4') then
    raise exception 'a master kept in Telegram counted as an R2 file';
  end if;

  -- The purge takes a sealed object's key row with it.
  -- (k4 is in the bin already: settle put it there above.)
  insert into public.r2_inventory (bucket, key, bytes, scan) values (b, k4, 11, gen_random_uuid());
  insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
  values (b, k4, 11, 'test', now()) on conflict do nothing;
  select id into tid from public.r2_trash
   where bucket = b and key = k4 and purged_at is null and restored_at is null;
  perform public.r2_trash_done(tid, null);
  if exists (select 1 from public.media_keys where sealed_key = k4)
     or exists (select 1 from public.r2_inventory where bucket = b and key = k4) then
    raise exception 'a purged sealed object kept its key row (or its listing)';
  end if;
  -- …and a purge that failed keeps it.
  insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
  values (b, k3, 10, 'test', now() + interval '1 day') returning id into tid;
  perform public.r2_trash_done(tid, 'http 500');
  if not exists (select 1 from public.media_keys where sealed_key = k3) then
    raise exception 'a failed purge dropped the key row';
  end if;
  delete from public.r2_trash where id = tid;

  -- Forwarded files: none needing a seal for a runner that does not seal.
  update public.admin_settings set seal_new = 'on';
  insert into public.ingest_jobs (tg_file_id, tg_unique_id, kind, bucket, object_key, created_at)
  values ('f', 'u', 'video', b, 'inbox/video/zz-a.mp4', '2000-01-01') returning id into job;
  if exists (select 1 from public.claim_ingest(false) c where c.job_id = job) then
    raise exception 'on: a runner that does not seal got a forwarded file';
  end if;
  select * into j from (select to_jsonb(c) from public.claim_ingest(true) c where c.job_id = job) x(c);
  if j is null or j->>'kind' <> 'video' or not (j ? 'title_id') then
    raise exception 'claim_ingest: no kind or title for the sealing runner (%)', j;
  end if;
  -- Born sealed: the job takes its s/ key once the key row is there.
  if public.ingest_seal_key(job, 'video/not-sealed.mp4') <> 'not_a_sealed_key' then
    raise exception 'ingest_seal_key took a plain key';
  end if;
  if public.ingest_seal_key(job, 's/' || md5('zz-no-row')) <> 'no_key_row' then
    raise exception 'ingest_seal_key took a key with no row';
  end if;
  v := public.ingest_seal_key(job, k3);
  if v <> 'sealed' or (select object_key from public.ingest_jobs where id = job) <> k3 then
    raise exception 'ingest_seal_key: % ', v;
  end if;
  update public.admin_settings set seal_new = 'off';

  -- A restore of a sealed master: only for a runner that seals, and under
  -- a new key, sealed afresh.
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state, bytes)
  values (t_cat, 'video', b, k_old, 3, 'restoring', 7) returning id into a_rest;
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', k_old, 'plain_key', null,
    'kek_version', 1, 'wrapped', w, 'plain_size', 7, 'sealed_size', public.media_sealed_size(7),
    'kind', 'video', 'header', h));
  insert into public.vault_copies (asset_id, chat_id, message_id, bytes) values (a_rest, 1, 1, 7);
  insert into public.vault_jobs (asset_id, kind, created_at) values (a_rest, 'restore', '2000-01-01')
  returning id into vj;
  if exists (select 1 from public.vault_claim_v2(false) c where c.job_id = vj)
     or exists (select 1 from public.vault_claim() c where c.job_id = vj) then
    raise exception 'a runner that does not seal got the restore of a sealed master';
  end if;
  if not exists (select 1 from public.vault_claim_v2(true) c where c.job_id = vj) then
    raise exception 'the sealing runner did not get the restore';
  end if;
  v := public.vault_finish(vj, true, null, 'restored', 7);
  if v <> 'no_sealed_key' then raise exception 'a sealed master restored without a new key: %', v; end if;
  update public.vault_jobs set state = 'running' where id = vj;
  update public.title_assets set master_state = 'restoring' where id = a_rest;
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', gen_random_uuid(), 'bucket', b, 'sealed_key', k_new, 'plain_key', null,
    'kek_version', 1, 'wrapped', w, 'plain_size', 7, 'sealed_size', public.media_sealed_size(7),
    'kind', 'video', 'header', h));
  v := public.vault_finish(vj, true, null, 'restored', 7, k_new);
  if v <> 'restored' then raise exception 'restore: %', v; end if;
  if (select object_key || ' ' || master_state from public.title_assets where id = a_rest) <> k_new || ' r2' then
    raise exception 'the restored master is not its new sealed object';
  end if;
  if exists (select 1 from public.media_keys where sealed_key = k_old)
     or not exists (select 1 from public.r2_trash where key = k_old and purged_at is null and restored_at is null) then
    raise exception 'the old sealed master kept its key, or is not in the bin';
  end if;

  if has_function_privilege('authenticated', 'public.ingest_seal_key(uuid, text)', 'execute')
     or has_function_privilege('anon', 'public.claim_ingest(boolean)', 'execute')
     or has_function_privilege('anon', 'public.vault_finish(uuid, boolean, text, text, bigint, text)', 'execute') then
    raise exception 'an app role can call a Telegram pipeline function';
  end if;

  -- ── 073: a move re-points the twins and the cover picker's stills ─────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Seal test move', 'zz-mv-old', false, 'draft', owner_id) returning id into t_mv;
  insert into public.title_assets (title_id, kind, bucket, object_key, thumb_key, sort_order, master_state, frames)
  values (t_mv, 'video', b, 'zz-mv-old/video/a.mp4', 'zz-mv-old/thumb/a-f00.jpg', 1, 'r2',
          '[{"at":1,"key":"zz-mv-old/thumb/a-f00.jpg"},{"at":9,"key":"zz-mv-old/thumb/a-f01.jpg"}]')
  returning id into a_mv;
  perform public.media_key_put('video', jsonb_build_object(
    'dek_id', id_mv, 'bucket', b, 'sealed_key', 's/' || md5('zz-mv-v'), 'plain_key', 'zz-mv-old/video/a.mp4',
    'kek_version', 1, 'wrapped', w, 'plain_size', 7, 'sealed_size', public.media_sealed_size(7),
    'kind', 'video', 'header', h));
  perform public.media_key_put('image', jsonb_build_object(
    'dek_id', id_mvi, 'bucket', b, 'sealed_key', 's/' || md5('zz-mv-i'), 'plain_key', 'zz-mv-old/thumb/a-f01.jpg',
    'dek', d, 'header', h, 'plain_size', 10, 'sealed_size', 60));
  insert into public.r2_moves (mode, from_folder, to_folder, title_id, objects, requested_by)
  values ('folder', 'zz-mv-old', 'zz-mv-new', t_mv, jsonb_build_array(
    jsonb_build_object('bucket', b, 'from', 'zz-mv-old/video/a.mp4', 'to', 'zz-mv-new/video/a.mp4', 'bytes', 7, 'done', true),
    jsonb_build_object('bucket', b, 'from', 'zz-mv-old/thumb/a-f00.jpg', 'to', 'zz-mv-new/thumb/a-f00.jpg', 'bytes', 5, 'done', true),
    jsonb_build_object('bucket', b, 'from', 'zz-mv-old/thumb/a-f01.jpg', 'to', 'zz-mv-new/thumb/a-f01.jpg', 'bytes', 10, 'done', true)),
    owner_id)
  returning id into mv;
  j := public.r2_move_switch(mv, owner_id);
  if (j->>'switched')::int <> 3 then raise exception 'move: %', j; end if;
  if (select plain_key from public.media_keys where dek_id = id_mv) <> 'zz-mv-new/video/a.mp4'
     or (select plain_key from public.media_image_keys where dek_id = id_mvi) <> 'zz-mv-new/thumb/a-f01.jpg' then
    raise exception 'a moved file left its twin naming the old key';
  end if;
  if (select frames->1->>'key' || ' ' || (frames->0->>'at') from public.title_assets where id = a_mv)
     <> 'zz-mv-new/thumb/a-f01.jpg 1' then
    raise exception 'the cover picker''s stills were not moved with their files';
  end if;
  if not exists (select 1 from public.r2_refs() where key = 's/' || md5('zz-mv-v') and how = 'sealed copy') then
    raise exception 'a moved film''s twin is no longer in use';
  end if;

  -- ── 073: a deleted file takes its twin; a master kept in Telegram does not ─
  insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
  values (b, 'zz-film/video/nobody.mp4', 7, 'test', now()) returning id into tid;
  perform public.r2_trash_done(tid, null);
  if exists (select 1 from public.media_keys where sealed_key = 's/' || md5('zz-loose'))
     or not exists (select 1 from public.r2_trash where key = 's/' || md5('zz-loose')
                      and reason = 'sealed copy of a deleted file' and purged_at is null) then
    raise exception 'a deleted file left its twin behind';
  end if;
  insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
  values (b, 'zz-film/video/kept.mp4', 7, 'master kept in Telegram (test)', now()) returning id into tid;
  perform public.r2_trash_done(tid, null);
  if not exists (select 1 from public.media_keys where sealed_key = 's/' || md5('zz-kept')) then
    raise exception 'the twin of a master kept in Telegram went with the R2 copy';
  end if;

  raise exception 'MEDIA KEYS TEST PASSED';
end $$;
