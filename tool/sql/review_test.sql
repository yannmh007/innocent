-- The review queue   (migration 027)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `REVIEW TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter most are the silent ones: an uploader approving their
-- own film, a title going live with no files by the Table Editor's door, the
-- review state and `published` disagreeing, and history being rewritten.
do $$
declare
  owner_id uuid := '6c679480-3387-4442-ad3d-4423b8aceb71';
  up_id    uuid := '00000000-0000-4000-8000-0000000000a1';
  ed_id    uuid := '00000000-0000-4000-8000-0000000000a2';
  t1       uuid;
  t2       uuid;
  v        text;
  r        record;
  n        integer;
  blocked  boolean;
begin
  -- ── people: an uploader and an editor beside the real owner ────────────
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at)
  values (up_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'up@example.com', now()),
         (ed_id, '00000000-0000-0000-0000-000000000000', 'authenticated',
          'authenticated', 'ed@example.com', now());
  insert into public.admins (user_id, email, role)
  values (up_id, 'up@example.com', 'uploader'), (ed_id, 'ed@example.com', 'editor');

  -- ── a draft made by the uploader, with one file ────────────────────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Review test one', 'review-test-one-zz', false, 'draft', up_id)
  returning id into t1;
  select review_state into v from public.titles where id = t1;
  if v <> 'editing' then raise exception 'a new draft started as %', v; end if;

  -- no files yet: cannot be sent, cannot be approved
  if public.review_decide(t1, up_id, 'submit') <> 'no_files' then
    raise exception 'a title with no files was sent for review';
  end if;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  values (t1, 'video', 'innocent-media', 'review-test-one-zz/video/a.mp4', 0);

  -- ── the uploader cannot approve, even their own ────────────────────────
  if public.review_decide(t1, up_id, 'approve') <> 'not_allowed' then
    raise exception 'an uploader approved a title';
  end if;
  -- ── an editor cannot send back without saying why ──────────────────────
  if public.review_decide(t1, ed_id, 'send_back', '   ') <> 'note_required' then
    raise exception 'a send-back with no note was accepted';
  end if;

  -- ── submit → send back → submit → approve ──────────────────────────────
  v := public.review_decide(t1, up_id, 'submit');
  if v <> 'submitted' then raise exception 'submit answered %', v; end if;
  select review_state, submitted_by into r from public.titles where id = t1;
  if r.review_state <> 'ready' or r.submitted_by <> up_id then
    raise exception 'after submit: % by %', r.review_state, r.submitted_by;
  end if;
  if public.review_decide(t1, up_id, 'submit') <> 'bad_state' then
    raise exception 'a title already waiting was submitted twice';
  end if;

  v := public.review_decide(t1, ed_id, 'send_back', 'Cover is blurry');
  if v <> 'sent_back' then raise exception 'send_back answered %', v; end if;
  select review_state, review_note, published into r from public.titles where id = t1;
  if r.review_state <> 'changes' or r.review_note <> 'Cover is blurry' or r.published then
    raise exception 'after send_back: % / % / %', r.review_state, r.review_note, r.published;
  end if;

  if public.review_decide(t1, up_id, 'submit') <> 'submitted' then
    raise exception 'a sent-back title could not be sent again';
  end if;
  select review_note into v from public.titles where id = t1;
  if v is not null then raise exception 'the old note survived a resubmit'; end if;

  v := public.review_decide(t1, ed_id, 'approve');
  if v <> 'approved' then raise exception 'approve answered %', v; end if;
  select published, status, review_state, decided_by into r from public.titles where id = t1;
  if not r.published or r.status <> 'published' or r.review_state <> 'approved'
     or r.decided_by <> ed_id then
    raise exception 'after approve: % % % %', r.published, r.status, r.review_state, r.decided_by;
  end if;
  if public.review_decide(t1, ed_id, 'approve') <> 'already_live' then
    raise exception 'a live title was approved again';
  end if;

  -- ── unpublish sends it back to editing ─────────────────────────────────
  if public.review_decide(t1, up_id, 'unpublish') <> 'not_allowed' then
    raise exception 'an uploader took a title down';
  end if;
  if public.review_decide(t1, ed_id, 'unpublish', 'wrong audio') <> 'unpublished' then
    raise exception 'unpublish failed';
  end if;
  select published, status, review_state into r from public.titles where id = t1;
  if r.published or r.status <> 'draft' or r.review_state <> 'editing' then
    raise exception 'after unpublish: % % %', r.published, r.status, r.review_state;
  end if;

  -- ── the history has every step, and cannot be rewritten ────────────────
  select count(*) into n from public.title_reviews where title_id = t1;
  if n <> 5 then raise exception 'history has % lines, expected 5', n; end if;
  blocked := false;
  begin
    update public.title_reviews set note = 'nothing happened' where title_id = t1;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'review history was edited'; end if;
  blocked := false;
  begin
    delete from public.title_reviews where title_id = t1;
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'review history was deleted'; end if;

  -- ── the two-person rule ────────────────────────────────────────────────
  insert into public.titles (title, slug, published, status, created_by)
  values ('Review test two', 'review-test-two-zz', false, 'draft', ed_id)
  returning id into t2;
  insert into public.title_assets (title_id, kind, bucket, object_key, sort_order)
  values (t2, 'photo', 'innocent-public', 'review-test-two-zz/photo/a.jpg', 0);
  update public.admin_settings set two_person = true where id;
  if public.review_decide(t2, ed_id, 'approve') <> 'two_person' then
    raise exception 'the maker approved their own title with two_person on';
  end if;
  if public.review_decide(t2, owner_id, 'approve') <> 'approved' then
    raise exception 'somebody else could not approve with two_person on';
  end if;
  update public.admin_settings set two_person = false where id;

  -- ── reject and reopen ──────────────────────────────────────────────────
  perform public.review_decide(t2, owner_id, 'unpublish');
  if public.review_decide(t2, ed_id, 'reject', 'duplicate') <> 'rejected' then
    raise exception 'reject failed';
  end if;
  if public.review_decide(t2, ed_id, 'approve') <> 'bad_state' then
    raise exception 'a rejected title was approved without being reopened';
  end if;
  if public.review_decide(t2, up_id, 'reopen') <> 'not_allowed' then
    raise exception 'an uploader reopened somebody else''s title';
  end if;
  if public.review_decide(t2, ed_id, 'reopen') <> 'reopened' then
    raise exception 'reopen failed';
  end if;

  -- ── a disabled admin decides nothing ───────────────────────────────────
  update public.admins set disabled = true where user_id = ed_id;
  if public.review_decide(t2, ed_id, 'submit') <> 'not_an_admin' then
    raise exception 'a removed admin was still heard';
  end if;
  update public.admins set disabled = false where user_id = ed_id;

  -- ── the Table Editor's doors keep the two in step ──────────────────────
  update public.titles set status = 'published' where id = t2;
  select published, review_state into r from public.titles where id = t2;
  if not r.published or r.review_state <> 'approved' then
    raise exception 'status=published left % / %', r.published, r.review_state;
  end if;
  update public.titles set published = false where id = t2;
  select review_state into v from public.titles where id = t2;
  if v <> 'editing' then raise exception 'published=false left %', v; end if;

  -- and the hole in 024: status=published on a title with no files
  insert into public.titles (title, slug, published, status, created_by)
  values ('Review test empty', 'review-test-empty-zz', false, 'draft', ed_id)
  returning id into t2;
  blocked := false;
  begin
    update public.titles set status = 'published' where id = t2;
  exception when check_violation then blocked := true;
  end;
  if not blocked then raise exception 'an empty title went live through status'; end if;

  -- ── the queue: waiting first, live never ───────────────────────────────
  perform public.review_decide(t1, up_id, 'submit');
  select * into r from public.review_queue() limit 1;
  if r.id <> t1 or r.review_state <> 'ready' or r.creator_email <> 'up@example.com'
     or r.videos <> 1 then
    raise exception 'the queue did not open with the waiting title: %', r;
  end if;
  if exists (select 1 from public.review_queue() q join public.titles t on t.id = q.id
              where t.published) then
    raise exception 'a live title is in the queue';
  end if;

  -- ── discard_ingest takes only what is finished and unfiled ─────────────
  insert into public.ingest_jobs (tg_file_id, tg_unique_id, tg_chat_id, tg_message_id,
                                  kind, bucket, object_key, state)
  values ('f1', 'zz-review-u1', 1, 1, 'video', 'innocent-media', 'zz-review-folder/video/1.mp4', 'done'),
         ('f2', 'zz-review-u2', 1, 2, 'video', 'innocent-media', 'zz-review-folder/video/2.mp4', 'queued'),
         ('f3', 'zz-review-u3', 1, 3, 'video', 'innocent-media', 'zz-review-folder/video/3.mp4', 'failed');
  n := public.discard_ingest(null, 'zz-review-folder');
  if n <> 2 then raise exception 'discard took % jobs, expected 2', n; end if;
  if not exists (select 1 from public.ingest_jobs where tg_unique_id = 'zz-review-u2') then
    raise exception 'discard took a queued job the runner may be holding';
  end if;
  if public.discard_ingest(null, '') <> 0 then
    raise exception 'an empty folder discarded something';
  end if;

  raise exception 'REVIEW TEST PASSED';
end $$;
