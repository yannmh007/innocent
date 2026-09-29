-- Does an album keep its caption's folder and its text?   (migrations 023, 024)
--
-- WHY THIS IS A SQL FILE AND NOT A UNIT TEST. The whole behaviour is a race
-- between messages that arrive milliseconds apart in an order nobody promises,
-- resolved by a lock and two statements in one transaction. There is nothing
-- to extract and test as a pure function: the thing that can be wrong is what
-- Postgres does, so this asks Postgres.
--
-- IT CHANGES NOTHING. Every case runs inside one transaction that ends on a
-- deliberate exception, so the rows exist for the length of the check and are
-- gone afterwards. Success is the message `ALBUM FOLDER TEST PASSED`; any other
-- exception names the case that failed.
--
-- RUN: paste into the SQL editor, or
--      supabase db execute --file tool/sql/album_folder_test.sql
do $$
declare
  r       record;
  v_key   text;
  v_st    text;
  v_cap   text;
  v_title uuid;
  n       integer;
begin
  -- ── caption first, siblings inherit ────────────────────────────────────
  select * into r from public.enqueue_ingest(
    'F-A', 'U-A', 1, 101, 'a.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'chief-of-war', 'photo/a.jpg', 'G1', null);
  if r.status <> 'queued' or r.folder <> 'chief-of-war' or r.moved <> 0 then
    raise exception 'caption-first: the captioned message itself: % % %',
      r.status, r.folder, r.moved;
  end if;

  select * into r from public.enqueue_ingest(
    'F-B', 'U-B', 1, 102, 'b.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', '', 'photo/b.jpg', 'G1', null);
  if r.folder <> 'chief-of-war' then
    raise exception 'caption-first: a captionless sibling did not inherit: %',
      r.folder;
  end if;
  select object_key into v_key from public.ingest_jobs where tg_unique_id = 'U-B';
  if v_key not like 'chief-of-war/%' then
    raise exception 'caption-first: the inherited key is wrong: %', v_key;
  end if;

  -- ── caption second, siblings are moved ─────────────────────────────────
  select * into r from public.enqueue_ingest(
    'F-C', 'U-C', 1, 201, 'c.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', '', 'photo/c.jpg', 'G2', null);
  if r.folder <> 'inbox' then
    raise exception 'caption-second: the first one should park in inbox: %',
      r.folder;
  end if;

  select * into r from public.enqueue_ingest(
    'F-D', 'U-D', 1, 202, 'd.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'the-war', 'photo/d.jpg', 'G2', null);
  if r.moved <> 1 then
    raise exception 'caption-second: expected to move 1 sibling, moved %',
      r.moved;
  end if;
  select object_key into v_key from public.ingest_jobs where tg_unique_id = 'U-C';
  if v_key <> 'the-war/photo/c.jpg' then
    raise exception 'caption-second: the moved key is wrong: %', v_key;
  end if;

  -- ── a sibling a runner already holds is NOT moved ──────────────────────
  --
  -- The key is in a presigned PUT by then. Moving the row would leave it
  -- pointing at one object while the bytes go to another — a file in the
  -- bucket that nothing in the catalogue can reach, which is the exact
  -- failure this whole folder business exists to avoid.
  perform public.enqueue_ingest(
    'F-E', 'U-E', 1, 301, 'e.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', '', 'photo/e.jpg', 'G3', null);
  update public.ingest_jobs set state = 'running' where tg_unique_id = 'U-E';

  select * into r from public.enqueue_ingest(
    'F-F', 'U-F', 1, 302, 'f.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'too-late', 'photo/f.jpg', 'G3', null);
  if r.moved <> 0 then
    raise exception 'a claimed sibling was moved out from under a runner';
  end if;
  select object_key into v_key from public.ingest_jobs where tg_unique_id = 'U-E';
  if v_key not like 'inbox/%' then
    raise exception 'a claimed sibling was rewritten: %', v_key;
  end if;

  -- ── a single file with no album still works ────────────────────────────
  select * into r from public.enqueue_ingest(
    'F-G', 'U-G', 1, 401, 'g.mp4', 'video/mp4', 100, null, null, null,
    'video', 'innocent-media', 'solar', 'video/g.mp4', '', null);
  if r.folder <> 'solar' or r.moved <> 0 then
    raise exception 'a lone file: % %', r.folder, r.moved;
  end if;

  select * into r from public.enqueue_ingest(
    'F-H', 'U-H', 1, 402, 'h.mp4', 'video/mp4', 100, null, null, null,
    'video', 'innocent-media', '', 'video/h.mp4', '', null);
  if r.folder <> 'inbox' then
    raise exception 'a lone file with no caption: %', r.folder;
  end if;

  -- ── the same file twice is one job ─────────────────────────────────────
  select * into r from public.enqueue_ingest(
    'F-A2', 'U-A', 1, 103, 'a.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'chief-of-war', 'photo/a2.jpg', 'G1', null);
  if r.status <> 'duplicate' then
    raise exception 'the same file was queued twice: %', r.status;
  end if;

  -- ── retry only takes a spent job, and only once ────────────────────────
  select public.retry_ingest(id) into v_st
    from public.ingest_jobs where tg_unique_id = 'U-A';
  if v_st <> 'not_failed' then
    raise exception 'retry took a queued job: %', v_st;
  end if;

  update public.ingest_jobs
     set state = 'failed', attempts = 3, finished_at = now()
   where tg_unique_id = 'U-H';
  select public.retry_ingest(id) into v_st
    from public.ingest_jobs where tg_unique_id = 'U-H';
  if v_st <> 'queued' then
    raise exception 'retry refused a failed job: %', v_st;
  end if;
  select state, attempts into r
    from public.ingest_jobs where tg_unique_id = 'U-H';
  if r.state <> 'queued' or r.attempts <> 0 then
    raise exception 'retry left the row wrong: % %', r.state, r.attempts;
  end if;

  -- The same file forwarded again since it failed. Retrying would be a second
  -- copy of bytes already being paid for, and the partial unique index would
  -- refuse the row anyway.
  update public.ingest_jobs
     set state = 'failed', attempts = 3 where tg_unique_id = 'U-G';
  perform public.enqueue_ingest(
    'F-G2', 'U-G', 1, 403, 'g.mp4', 'video/mp4', 100, null, null, null,
    'video', 'innocent-media', 'solar', 'video/g2.mp4', '', null);
  select public.retry_ingest(id) into v_st
    from public.ingest_jobs where tg_unique_id = 'U-G' and state = 'failed';
  if v_st <> 'duplicate' then
    raise exception 'retry would have fetched the same file twice: %', v_st;
  end if;

  -- ═══════════════════════════════════════════════════════════════════════
  -- 024: THE CAPTION, AND THE WHOLE ALBUM AT ONCE
  -- ═══════════════════════════════════════════════════════════════════════

  -- The caption travels with the folder, because they come from the same
  -- message. The operator writes a name, a blank line and a synopsis; all of
  -- it belongs to every file of the album, not to the one that carried it.
  perform public.enqueue_ingest(
    'C-A', 'CU-A', 1, 101, 'a.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'my-film', 'photo/a.jpg', 'CG1',
    'My Film' || chr(10) || chr(10) || 'A long Burmese synopsis goes here.');
  perform public.enqueue_ingest(
    'C-B', 'CU-B', 1, 102, 'b.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', '', 'photo/b.jpg', 'CG1', null);
  select tg_caption into v_cap from public.ingest_jobs where tg_unique_id = 'CU-B';
  if v_cap is null or v_cap not like 'My Film%' then
    raise exception 'caption-first: sibling did not inherit the caption: %', v_cap;
  end if;

  -- Arriving second, the caption reaches siblings in ANY state. It is only
  -- metadata — nothing is signed against it — unlike the key.
  perform public.enqueue_ingest(
    'C-C', 'CU-C', 1, 201, 'c.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', '', 'photo/c.jpg', 'CG2', null);
  update public.ingest_jobs set state = 'done' where tg_unique_id = 'CU-C';
  perform public.enqueue_ingest(
    'C-D', 'CU-D', 1, 202, 'd.jpg', 'image/jpeg', 100, null, null, null,
    'photo', 'innocent-public', 'late', 'photo/d.jpg', 'CG2',
    'Late Name' || chr(10) || 'body');
  select tg_caption into v_cap from public.ingest_jobs where tg_unique_id = 'CU-C';
  if v_cap is null then
    raise exception 'caption-second: a done sibling was not back-filled';
  end if;

  -- THE KEY STILL IS NOT. That file is already in the bucket at the old key.
  select object_key into v_key from public.ingest_jobs where tg_unique_id = 'CU-C';
  if v_key not like 'inbox/%' then
    raise exception 'caption-second: a done sibling had its key rewritten: %', v_key;
  end if;

  -- One album, one attach.
  insert into public.titles (title, category, access_tier)
    values ('Folder test title', 'movies', 'premium') returning id into v_title;
  update public.ingest_jobs set state = 'done' where tg_media_group = 'CG1';
  select public.attach_ingest_folder('my-film', v_title) into n;
  if n <> 2 then
    raise exception 'attach_ingest_folder attached % of 2', n;
  end if;
  select count(*) into n from public.title_assets where title_id = v_title;
  if n <> 2 then
    raise exception 'title_assets got % rows, expected 2', n;
  end if;

  -- Idempotent per folder, the way attach_ingest is idempotent per job. A
  -- second tap on Attach all must not make a second copy of every asset.
  select public.attach_ingest_folder('my-film', v_title) into n;
  if n <> 0 then
    raise exception 'attach_ingest_folder ran twice and attached % again', n;
  end if;

  -- And it never points a title at bytes that are not there yet.
  select public.attach_ingest_folder('late', v_title) into n;
  if n <> 0 then
    raise exception 'attach_ingest_folder attached % unfinished files', n;
  end if;

  raise exception 'ALBUM FOLDER TEST PASSED';
end;
$$;
