-- The seek bar's pictures made in advance   (migration 083)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `TRICKPLAY TEST PASSED`; any
-- other exception names the case that failed.
--
-- What must hold: only the service role reaches the table and the RPCs; the
-- open scope takes only open films, and only an asset whose smallest rung is
-- plain; a claimed asset is not offered twice; a pack is recorded only under
-- the key minted from its rung; request-playback's reader returns it while
-- the ladder is the one it was made from, and the claim offers it again
-- once the ladder changes; a failure waits a day; the bin never purges a
-- pack a row names (r2_refs); `all` reaches the rest of the catalogue; a
-- move on the Files page takes the pack and its source key with the film.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  t_open uuid; t_other uuid; a1 uuid; a2 uuid; a3 uuid;
  v text; n integer; r record;
begin
  -- ── who may ──────────────────────────────────────────────────────────────
  foreach v in array array['anon', 'authenticated'] loop
    if has_table_privilege(v, 'public.asset_trickplay', 'SELECT')
       or has_table_privilege(v, 'public.asset_trickplay', 'INSERT')
       or has_table_privilege(v, 'public.asset_trickplay', 'UPDATE')
       or has_table_privilege(v, 'public.asset_trickplay', 'DELETE') then
      raise exception 'case 1: % reaches asset_trickplay', v;
    end if;
    if has_function_privilege(v, 'public.claim_trickplay(text, integer)', 'EXECUTE')
       or has_function_privilege(v, 'public.record_trickplay(uuid, jsonb, text)', 'EXECUTE')
       or has_function_privilege(v, 'public.trickplay_for(uuid)', 'EXECUTE')
       or has_function_privilege(v, 'public.trickplay_key(text)', 'EXECUTE') then
      raise exception 'case 1: % may call a trickplay function', v;
    end if;
  end loop;
  if not (has_table_privilege('service_role', 'public.asset_trickplay', 'SELECT')
          and has_table_privilege('service_role', 'public.asset_trickplay', 'INSERT')
          and has_table_privilege('service_role', 'public.asset_trickplay', 'UPDATE')
          and has_function_privilege('service_role', 'public.claim_trickplay(text, integer)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.record_trickplay(uuid, jsonb, text)', 'EXECUTE')
          and has_function_privilege('service_role', 'public.trickplay_for(uuid)', 'EXECUTE')) then
    raise exception 'case 1: the service role cannot do its part';
  end if;

  -- ── three films ──────────────────────────────────────────────────────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Trick test', 'open-film-zz-trick', false, 'draft', owner_id) returning id into t_open;
  insert into public.titles (title, slug, published, status, created_by)
  values ('Trick other', 'zz-trick-other', false, 'draft', owner_id) returning id into t_other;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state)
  values (t_open, 'video', 'innocent-media', 'open-film-zz-trick/video/20261120-a-11111111.mp4', 1, 'r2')
  returning id into a1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state)
  values (t_other, 'video', 'innocent-media', 'zz-trick-other/video/20261120-b-22222222.mp4', 1, 'r2')
  returning id into a2;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state)
  values (t_open, 'video', 'innocent-media', 'open-film-zz-trick/video/20261120-c-33333333.mp4', 2, 'r2')
  returning id into a3;
  insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes)
  values (a1, 240, 300, 'open-film-zz-trick/video/20261120-a-11111111-240p.mp4', 1000000),
         (a1, 480, 900, 'open-film-zz-trick/video/20261120-a-11111111-480p.mp4', 3000000),
         (a2, 240, 300, 'zz-trick-other/video/20261120-b-22222222-240p.mp4', 2000000),
         (a3, 240, 300, 's/0123456789abcdef0123456789abcdef', 1500000);

  -- ── the open scope ───────────────────────────────────────────────────────
  select * into r from public.claim_trickplay('open', 50) c where c.asset_id = a1;
  if r.asset_id is null then raise exception 'case 2: the open film was not offered'; end if;
  if r.src_key <> 'open-film-zz-trick/video/20261120-a-11111111-240p.mp4' or r.src_height <> 240
     or r.src_bytes <> 1000000
     or r.pack_key <> 'open-film-zz-trick/video/20261120-a-11111111-trick.itp' then
    raise exception 'case 2: offered from % (%p, % bytes) as %', r.src_key, r.src_height, r.src_bytes, r.pack_key;
  end if;
  select count(*) into n from public.asset_trickplay where asset_id in (a2, a3);
  if n <> 0 then raise exception 'case 3: a film outside the scope, or a sealed rung, was claimed'; end if;
  select count(*) into n from public.claim_trickplay('open', 50) c where c.asset_id = a1;
  if n <> 0 then raise exception 'case 4: a claimed asset was offered twice'; end if;

  -- ── recording ────────────────────────────────────────────────────────────
  begin
    perform public.record_trickplay(a1, jsonb_build_object('key', 'elsewhere/x-trick.itp', 'bytes', 5,
      'interval_ms', 4000, 'width', 320, 'height', 180, 'count', 9, 'codec', 'jpeg'));
    raise exception 'case 5: a pack under a key nobody minted was taken';
  exception when others then
    if sqlerrm like 'case 5%' then raise; end if;
  end;
  v := public.record_trickplay(a1, jsonb_build_object(
    'key', 'open-film-zz-trick/video/20261120-a-11111111-trick.itp', 'bytes', 50000,
    'interval_ms', 4000, 'width', 320, 'height', 180, 'count', 25, 'codec', 'jpeg'));
  if v is distinct from 'open-film-zz-trick/video/20261120-a-11111111-trick.itp' then
    raise exception 'case 6: recording answered %', v;
  end if;
  select * into r from public.trickplay_for(a1);
  if r.object_key is null or r.bytes <> 50000 or r.interval_ms <> 4000 or r.count <> 25 or r.codec <> 'jpeg' then
    raise exception 'case 6: the reader gave %', row_to_json(r);
  end if;
  begin
    perform public.record_trickplay(a2, null, 'never claimed');
    raise exception 'case 7: an asset never claimed was recorded';
  exception when others then
    if sqlerrm like 'case 7%' then raise; end if;
  end;

  -- ── the bin ──────────────────────────────────────────────────────────────
  select count(*) into n from public.r2_refs() f
   where f.key = 'open-film-zz-trick/video/20261120-a-11111111-trick.itp' and f.how = 'seek-bar pictures';
  if n <> 1 then raise exception 'case 8: r2_refs does not name the pack (% rows)', n; end if;

  -- ── a new ladder ─────────────────────────────────────────────────────────
  update public.asset_renditions set bytes = 1100000 where asset_id = a1 and height = 240;
  select count(*) into n from public.trickplay_for(a1);
  if n <> 0 then raise exception 'case 9: a pack of the old ladder was handed out'; end if;
  select count(*) into n from public.claim_trickplay('open', 50) c where c.asset_id = a1 and c.src_bytes = 1100000;
  if n <> 1 then raise exception 'case 9: the new ladder was not offered again'; end if;

  -- ── a failure waits ──────────────────────────────────────────────────────
  perform public.record_trickplay(a1, null, 'ffmpeg: no picture');
  select state into v from public.asset_trickplay where asset_id = a1;
  if v <> 'failed' then raise exception 'case 10: a failure recorded as %', v; end if;
  select count(*) into n from public.claim_trickplay('open', 50) c where c.asset_id = a1;
  if n <> 0 then raise exception 'case 10: a failure was offered again at once'; end if;

  -- ── the whole catalogue, on the owner's word ─────────────────────────────
  select count(*) into n from public.claim_trickplay('all', 50) c where c.asset_id = a2;
  if n <> 1 then raise exception 'case 11: scope all did not reach the catalogue'; end if;
  select count(*) into n from public.asset_trickplay where asset_id = a3;
  if n <> 0 then raise exception 'case 11: a sealed rung was claimed'; end if;
  begin
    perform public.claim_trickplay('everything', 1);
    raise exception 'case 12: an unknown scope was taken';
  exception when others then
    if sqlerrm like 'case 12%' then raise; end if;
  end;

  -- ── a move on the Files page takes the pack with it ──────────────────────
  declare
    mover uuid; t_m uuid; a_m uuid; mv uuid; res jsonb; k record;
  begin
    select user_id into mover from public.admins where role = 'owner' and not disabled limit 1;
    insert into public.titles (title, slug, published, status, created_by)
    values ('Move test', 'open-film-zz-move', false, 'draft', owner_id) returning id into t_m;
    insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state)
    values (t_m, 'video', 'innocent-media', 'open-film-zz-move/video/m.mp4', 1, 'r2') returning id into a_m;
    insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes)
    values (a_m, 240, 300, 'open-film-zz-move/video/m-240p.mp4', 1000);
    insert into public.asset_trickplay (asset_id, state, object_key, bytes, source_key, source_bytes)
    values (a_m, 'done', 'open-film-zz-move/video/m-trick.itp', 50, 'open-film-zz-move/video/m-240p.mp4', 1000);
    insert into public.r2_moves (mode, to_folder, title_id, objects, state)
    values ('title', 'open-film-zz-moved', t_m, jsonb_build_array(
      jsonb_build_object('bucket', 'innocent-media', 'from', 'open-film-zz-move/video/m.mp4',
                         'to', 'open-film-zz-moved/video/m.mp4', 'done', true, 'bytes', 9),
      jsonb_build_object('bucket', 'innocent-media', 'from', 'open-film-zz-move/video/m-240p.mp4',
                         'to', 'open-film-zz-moved/video/m-240p.mp4', 'done', true, 'bytes', 1000),
      jsonb_build_object('bucket', 'innocent-media', 'from', 'open-film-zz-move/video/m-trick.itp',
                         'to', 'open-film-zz-moved/video/m-trick.itp', 'done', true, 'bytes', 50)),
      'copying') returning id into mv;
    res := public.r2_move_switch(mv, mover);
    if res ? 'error' then raise exception 'case 13: the move was refused: %', res; end if;
    select * into k from public.asset_trickplay where asset_id = a_m;
    if k.object_key <> 'open-film-zz-moved/video/m-trick.itp'
       or k.source_key <> 'open-film-zz-moved/video/m-240p.mp4' then
      raise exception 'case 13: the pack did not follow its film (% from %)', k.object_key, k.source_key;
    end if;
  end;

  raise exception 'TRICKPLAY TEST PASSED';
end $$;
