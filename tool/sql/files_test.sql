-- The Files page's database   (migration 028)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `FILES TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter are the ones that would break a film without a word:
-- a move that misses one reference (the thumbnail, a streaming copy, the
-- cover URL), a move of `zz-old` that also rewrites `zz-old-2`, and a bin that
-- deletes a file somebody is using.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  ed_id    uuid := '00000000-0000-4000-8000-0000000000b2';
  base     text := public.public_asset_base();
  s1 uuid := gen_random_uuid();
  s2 uuid := gen_random_uuid();
  t1 uuid; t2 uuid; t3 uuid; a1 uuid; a2 uuid; mv uuid; mv2 uuid;
  j jsonb; v text; n integer; r record;
begin
  -- ── which folder a key is in ───────────────────────────────────────────
  if public.r2_folder_of('movies/solar/video/x.mp4') <> 'movies/solar' then raise exception 'nested folder'; end if;
  if public.r2_folder_of('test006/video/a-720p.mp4') <> 'test006' then raise exception 'rendition folder'; end if;
  if public.r2_folder_of('v/20260922-a.mp4') <> 'v' then raise exception 'old flat key'; end if;
  if public.r2_folder_of('inbox/photo/a.jpg') <> 'inbox' then raise exception 'inbox'; end if;
  if public.r2_folder_of('loose.mp4') <> '' then raise exception 'a key with no folder'; end if;

  -- ── the inventory: a second scan forgets what it did not see ───────────
  perform public.inventory_upsert('zz-bucket', s1,
    '[{"key":"zz-a/video/1.mp4","bytes":10},{"key":"zz-a/video/2.mp4","bytes":20}]');
  perform public.inventory_finish('zz-bucket', s1);
  perform public.inventory_upsert('zz-bucket', s2, '[{"key":"zz-a/video/1.mp4","bytes":11}]');
  n := public.inventory_finish('zz-bucket', s2);
  if n <> 1 then raise exception 'the second scan forgot % keys, expected 1', n; end if;
  select objects, bytes into r from public.r2_scans where bucket = 'zz-bucket';
  if r.objects <> 1 or r.bytes <> 11 then raise exception 'scan totals % / %', r.objects, r.bytes; end if;

  -- ── a title in zz-old, with every kind of reference ────────────────────
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at)
  values (ed_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'ed2@example.com', now());
  insert into public.admins (user_id, email, role) values (ed_id, 'ed2@example.com', 'editor');

  insert into public.titles (title, slug, published, status, created_by)
  values ('Files test', 'zz-old', false, 'draft', owner_id) returning id into t1;
  insert into public.title_assets (title_id, kind, bucket, object_key, thumb_key, sort_order, is_primary)
  values (t1, 'video', 'innocent-media', 'zz-old/video/film.mp4', 'zz-old/thumb/film.jpg', 0, true)
  returning id into a1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary)
  values (t1, 'photo', 'innocent-public', 'zz-old/photo/cover.jpg', 1, true) returning id into a2;
  insert into public.asset_renditions (asset_id, height, kbps, object_key)
  values (a1, 720, 2500, 'zz-old/video/film-720p.mp4');
  -- the neighbour whose name starts the same way
  insert into public.titles (title, slug, published, status, created_by)
  values ('Neighbour', 'zz-old-2', false, 'draft', owner_id) returning id into t2;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, is_primary)
  values (t2, 'video', 'innocent-media', 'zz-old-2/video/other.mp4', 0, true);
  insert into public.titles (title, slug, published, status, created_by)
  values ('Taken', 'zz-taken', false, 'draft', owner_id) returning id into t3;

  select locator, poster_url into r from public.titles where id = t1;
  if r.locator <> 'zz-old/video/film.mp4' or r.poster_url <> base || 'zz-old/photo/cover.jpg' then
    raise exception 'the sync trigger did not set locator/poster: % %', r.locator, r.poster_url;
  end if;

  perform public.inventory_upsert('innocent-media', gen_random_uuid(),
    '[{"key":"zz-old/video/film.mp4","bytes":1000},{"key":"zz-old/video/film-720p.mp4","bytes":300},
      {"key":"zz-old/video/stray.mp4","bytes":50},{"key":"zz-old-2/video/other.mp4","bytes":70}]');
  perform public.inventory_upsert('innocent-public', gen_random_uuid(),
    '[{"key":"zz-old/thumb/film.jpg","bytes":5},{"key":"zz-old/photo/cover.jpg","bytes":6}]');

  -- ── what the page reads ────────────────────────────────────────────────
  select * into r from public.files_summary() where folder = 'zz-old';
  if r.files <> 5 or r.bytes <> 1361 or r.unused_files <> 1 or r.unused_bytes <> 50 or r.title_id <> t1 then
    raise exception 'summary for zz-old: %', r;
  end if;
  select * into r from public.files_list('zz-old') where key = 'zz-old/video/film-720p.mp4';
  if r.used_by <> t1 or r.source <> 'streaming copy' then raise exception 'list row: %', r; end if;
  if (select count(*) from public.files_list('zz-old')) <> 5 then raise exception 'zz-old lists zz-old-2'; end if;

  -- ── the bin ────────────────────────────────────────────────────────────
  j := public.r2_trash_add('[{"bucket":"innocent-media","key":"zz-old/video/stray.mp4"}]', ed_id, 'test');
  if j->>'error' <> 'not_owner' then raise exception 'an editor binned a file: %', j; end if;
  j := public.r2_trash_add('[{"bucket":"innocent-media","key":"zz-old/video/film.mp4"},
                             {"bucket":"innocent-media","key":"zz-old/video/stray.mp4"}]', owner_id, 'test');
  if (j->>'added')::int <> 1 or jsonb_array_length(j->'refused') <> 1
     or j->'refused'->0->>'key' <> 'zz-old/video/film.mp4' then
    raise exception 'bin: the used file must be refused and the stray taken: %', j;
  end if;
  select * into r from public.r2_trash where key = 'zz-old/video/stray.mp4' and purged_at is null;
  if r.purge_after < now() + interval '6 days 23 hours' then raise exception 'not seven days: %', r.purge_after; end if;
  if (public.r2_trash_add('[{"bucket":"innocent-media","key":"zz-old/video/stray.mp4"}]', owner_id, 'x')->>'added')::int <> 0 then
    raise exception 'binned twice';
  end if;
  if public.r2_trash_restore(r.id, owner_id) <> 'restored' then raise exception 'restore'; end if;
  if public.r2_trash_restore(r.id, owner_id) <> 'not_in_bin' then raise exception 'restored twice'; end if;

  -- due, and in use again by then: kept, not deleted
  perform public.r2_trash_add('[{"bucket":"innocent-media","key":"zz-old/video/stray.mp4"}]', owner_id, 'again');
  update public.r2_trash set purge_after = now() - interval '1 minute'
   where key = 'zz-old/video/stray.mp4' and purged_at is null and restored_at is null;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  values (t2, 'video', 'innocent-media', 'zz-old/video/stray.mp4', 5);
  if exists (select 1 from public.r2_trash_due(50) d where d.key = 'zz-old/video/stray.mp4') then
    raise exception 'the bin would have deleted a file a title uses';
  end if;
  delete from public.title_assets where object_key = 'zz-old/video/stray.mp4';
  perform public.r2_trash_add('[{"bucket":"innocent-media","key":"zz-old/video/stray.mp4"}]', owner_id, 'third');
  update public.r2_trash set purge_after = now() - interval '1 minute'
   where key = 'zz-old/video/stray.mp4' and purged_at is null and restored_at is null;
  select d.id into n from public.r2_trash_due(50) d where d.key = 'zz-old/video/stray.mp4';
  if n is null then raise exception 'a due, unused file was not offered for deleting'; end if;
  perform public.r2_trash_done(n, null);
  if exists (select 1 from public.r2_inventory where key = 'zz-old/video/stray.mp4') then
    raise exception 'a deleted file is still in the inventory';
  end if;

  -- ── a move: refusals first ─────────────────────────────────────────────
  j := '[{"bucket":"innocent-media","from":"zz-old/video/film.mp4","to":"zz-new/video/film.mp4","bytes":1000},
         {"bucket":"innocent-media","from":"zz-old/video/film-720p.mp4","to":"zz-new/video/film-720p.mp4","bytes":300},
         {"bucket":"innocent-public","from":"zz-old/thumb/film.jpg","to":"zz-new/thumb/film.jpg","bytes":5},
         {"bucket":"innocent-public","from":"zz-old/photo/cover.jpg","to":"zz-new/photo/cover.jpg","bytes":6}]';
  if public.r2_move_create(ed_id, 'folder', 'zz-old', 'zz-new', null, j)->>'error' <> 'not_owner' then
    raise exception 'an editor started a move';
  end if;
  if public.r2_move_create(owner_id, 'folder', 'zz-old', 'zz-taken', null, j)->>'error' <> 'folder_taken' then
    raise exception 'moved into a folder another title owns';
  end if;
  if public.r2_move_create(owner_id, 'folder', 'zz-old', 'Bad Name', null, j)->>'error' <> 'bad_folder' then
    raise exception 'a bad folder name was accepted';
  end if;
  if public.r2_move_create(owner_id, 'folder', 'zz-old', 'zz-old-2', null, j)->>'error' <> 'folder_taken' then
    raise exception 'moved onto the neighbour';
  end if;
  mv := (public.r2_move_create(owner_id, 'folder', 'zz-old', 'zz-new', null, j)->>'id')::uuid;
  if mv is null then raise exception 'the move was not created'; end if;
  if public.r2_move_create(owner_id, 'folder', 'zz-old', 'zz-new3', null, j)->>'error' <> 'move_in_progress' then
    raise exception 'two moves of one folder at once';
  end if;

  -- the switch waits for every copy
  if public.r2_move_switch(mv, owner_id)->>'error' <> 'not_copied' then raise exception 'switched before copying'; end if;
  for n in 0..3 loop perform public.r2_move_progress(mv, n, '{"done":true}'); end loop;
  j := public.r2_move_switch(mv, owner_id);
  if (j->>'switched')::int <> 4 or (j->>'binned')::int <> 4 then raise exception 'switch: %', j; end if;

  -- every reference, exactly
  select object_key, thumb_key into r from public.title_assets where id = a1;
  if r.object_key <> 'zz-new/video/film.mp4' or r.thumb_key <> 'zz-new/thumb/film.jpg' then
    raise exception 'asset after move: %', r;
  end if;
  if (select object_key from public.title_assets where id = a2) <> 'zz-new/photo/cover.jpg' then raise exception 'photo'; end if;
  if (select object_key from public.asset_renditions where asset_id = a1) <> 'zz-new/video/film-720p.mp4' then
    raise exception 'streaming copy not moved';
  end if;
  select slug, locator, poster_url into r from public.titles where id = t1;
  if r.slug <> 'zz-new' or r.locator <> 'zz-new/video/film.mp4' or r.poster_url <> base || 'zz-new/photo/cover.jpg' then
    raise exception 'title after move: %', r;
  end if;
  -- and nothing else
  if (select slug from public.titles where id = t2) <> 'zz-old-2' then raise exception 'the neighbour was renamed'; end if;
  if not exists (select 1 from public.title_assets where object_key = 'zz-old-2/video/other.mp4') then
    raise exception 'the neighbour''s file was rewritten';
  end if;
  -- the old files wait seven days in the bin; the new ones are in the inventory
  if (select count(*) from public.r2_trash where key like 'zz-old/%' and reason like 'moved to %'
        and purged_at is null and restored_at is null and purge_after > now() + interval '6 days') <> 4 then
    raise exception 'the old files are not in the bin for seven days';
  end if;
  if (select count(*) from public.r2_inventory where key like 'zz-new/%') <> 4 then raise exception 'inventory'; end if;
  if public.r2_move_switch(mv, owner_id)->>'error' <> 'not_copying' then raise exception 'switched twice'; end if;

  -- ── a cancelled move bins its copies at once ───────────────────────────
  mv2 := (public.r2_move_create(owner_id, 'title', null, 'zz-tidy', t2,
     '[{"bucket":"innocent-media","from":"zz-old-2/video/other.mp4","to":"zz-tidy/video/other.mp4","bytes":70}]')->>'id')::uuid;
  perform public.r2_move_progress(mv2, 0, '{"done":true}');
  if (public.r2_move_cancel(mv2, owner_id)->>'cancelled')::boolean is not true then raise exception 'cancel'; end if;
  if not exists (select 1 from public.r2_trash where key = 'zz-tidy/video/other.mp4' and purge_after <= now()) then
    raise exception 'the cancelled copy was not binned for deleting';
  end if;
  if (select slug from public.titles where id = t2) <> 'zz-old-2' then raise exception 'a cancelled move changed the title'; end if;

  -- ── a display name moves nothing ───────────────────────────────────────
  if public.folder_label_set('zz-new', 'Solar (2025)', owner_id) <> 'saved' then raise exception 'label'; end if;
  if (select label from public.files_summary() where folder = 'zz-new') <> 'Solar (2025)' then raise exception 'label shown'; end if;
  if public.folder_label_set('zz-new', '  ', owner_id) <> 'cleared' then raise exception 'label clear'; end if;

  raise exception 'FILES TEST PASSED';
end $$;
