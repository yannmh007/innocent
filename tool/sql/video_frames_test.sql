-- Video frames   (migration 043)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `FRAMES TEST PASSED`; any other
-- exception names the case that failed.
--
-- What must hold: a video with no thumbnail gets frame 0; a thumbnail the
-- operator chose is never replaced; a strange key is refused; a failure is
-- recorded and not picked up again by itself; a film whose original lives
-- only in Telegram is framed from its best streaming copy; the Files page
-- counts the choices as in use.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  t1 uuid; a1 uuid; a2 uuid; a3 uuid; p1 uuid;
  v text; n integer; r record; frames jsonb;
begin
  -- Nothing already waiting may answer the claims below.
  update public.title_assets set frames_state = 'done' where frames_state is null or frames_state in ('queued', 'running');

  insert into public.titles (title, slug, published, status, created_by)
  values ('Frames test', 'zz-frames', false, 'draft', owner_id) returning id into t1;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state, duration_s)
  values (t1, 'video', 'innocent-media', 'zz-frames/video/20261006-a-11111111.mp4', 1, 'r2', 100)
  returning id into a1;
  insert into public.title_assets (title_id, kind, bucket, object_key, thumb_key, sort_order, master_state)
  values (t1, 'video', 'innocent-media', 'zz-frames/video/20261006-b-22222222.mp4',
          'zz-frames/thumb/chosen-by-hand.jpg', 2, 'r2')
  returning id into a2;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order, master_state)
  values (t1, 'video', 'innocent-media', 'zz-frames/video/20261006-c-33333333.mp4', 3, 'telegram')
  returning id into a3;
  insert into public.asset_renditions (asset_id, height, kbps, object_key)
  values (a3, 360, 600, 'zz-frames/video/20261006-c-33333333-360p.mp4'),
         (a3, 720, 2000, 'zz-frames/video/20261006-c-33333333-720p.mp4');
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  values (t1, 'photo', 'innocent-public', 'zz-frames/photo/p.jpg', 4) returning id into p1;

  -- ── the batch ────────────────────────────────────────────────────────────
  select count(*) into n from public.claim_frames(20);
  if n <> 3 then raise exception 'claim: expected the 3 videos, got %', n; end if;
  if exists (select 1 from public.title_assets where id = p1 and frames_state is not null) then
    raise exception 'claim: a photo was claimed';
  end if;
  select count(*) into n from public.claim_frames(20);
  if n <> 0 then raise exception 'claim: a running batch was handed out twice'; end if;
  -- The Telegram-only film is framed from its best copy, not from nothing.
  update public.title_assets set frames_state = 'queued' where id = a3;
  select * into r from public.claim_frames(5);
  if r.src_key <> 'zz-frames/video/20261006-c-33333333-720p.mp4' then
    raise exception 'claim: telegram-only film framed from %', r.src_key;
  end if;

  -- ── the answer ───────────────────────────────────────────────────────────
  frames := '[{"at":1,"key":"zz-frames/thumb/20261006-a-11111111-f00.jpg"},
              {"at":10,"key":"zz-frames/thumb/20261006-a-11111111-f01.jpg"}]';
  v := public.record_frames(a1, frames, 'ok');
  if v <> 'zz-frames/thumb/20261006-a-11111111-f00.jpg' then
    raise exception 'record: a video with no thumbnail did not get frame 0 (%)', v;
  end if;
  v := public.record_frames(a2, '[{"at":1,"key":"zz-frames/thumb/20261006-b-22222222-f00.jpg"}]', 'ok');
  if v <> 'zz-frames/thumb/chosen-by-hand.jpg' then
    raise exception 'record: the operator''s own thumbnail was replaced by %', v;
  end if;
  begin
    perform public.record_frames(a1, '[{"at":1,"key":"../../etc/passwd.jpg"}]', 'ok');
    raise exception 'record: a strange key was accepted';
  exception when others then
    if sqlerrm like 'record: a strange%' then raise; end if;
  end;
  if (select thumb_key from public.title_assets where id = a1) <> 'zz-frames/thumb/20261006-a-11111111-f00.jpg' then
    raise exception 'record: the refused call changed the row';
  end if;

  -- A failure is recorded, and is not picked up again by itself.
  v := public.record_frames(a3, null, 'ffmpeg could not read it');
  if (select frames_state from public.title_assets where id = a3) <> 'failed' then
    raise exception 'record: a failure was not recorded';
  end if;
  select count(*) into n from public.claim_frames(20) c where c.asset_id = a3;
  if n <> 0 then raise exception 'claim: a failed video came round again by itself'; end if;
  -- …until somebody asks.
  if public.queue_frames(a3) <> 'queued' then raise exception 'queue: not queued'; end if;
  if public.queue_frames(p1) is not null then raise exception 'queue: a photo was queued'; end if;

  -- ── the Files page ───────────────────────────────────────────────────────
  if not exists (select 1 from public.r2_refs()
                  where key = 'zz-frames/thumb/20261006-a-11111111-f01.jpg'
                    and how = 'thumbnail choice') then
    raise exception 'refs: an offered frame would be listed as unused';
  end if;

  -- ── nobody but the service may call them ─────────────────────────────────
  if has_function_privilege('anon', 'public.claim_frames(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.record_frames(uuid,jsonb,text)', 'execute')
     or has_function_privilege('authenticated', 'public.queue_frames(uuid)', 'execute') then
    raise exception 'grants: a viewer can call a frames function';
  end if;

  raise exception 'FRAMES TEST PASSED';
end $$;
