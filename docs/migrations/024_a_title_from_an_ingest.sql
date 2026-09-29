-- ===========================================================================
-- 024  A TITLE CAN BE BORN FROM AN INGEST   (I5)
-- ===========================================================================
--
-- Found by the first album that went all the way through. Fifteen files landed
-- in R2, in the right two folders, and there was nothing to be done with them.
--
-- ---------------------------------------------------------------------------
-- 1. A TITLE COULD NOT BE CREATED WITHOUT UPLOADING A FILE FROM THE PHONE
-- ---------------------------------------------------------------------------
--
-- The console's New tab refuses to save unless at least one file is picked,
-- and `create` in studio.ts refuses a body with no assets. That was right when
-- the only way a file reached the bucket was the phone's own uplink.
--
-- The whole point of the Telegram ingest is that it is NOT the phone's uplink.
-- After it runs, the files are already in R2 — and the operator's next step,
-- "choose the title in the console", cannot be taken, because creating that
-- title demands uploading a file that is already there. The From Telegram
-- panel's picker offered five old test titles and nothing else, and attaching
-- a 416 MB film to `Test 001` is not a workaround.
--
-- THE FIX IS NOT TO LOOSEN THAT GUARD. Relaxing `create` would leave the
-- operator doing five steps — fill the form, save with no files, go back to
-- Health, find the folder, attach — to express one intention: "this album is
-- this title". `create_title_from_ingest` does it in one statement, and the
-- title is never empty for a moment, because the files are attached inside the
-- same transaction that creates it.
--
-- It deliberately does LESS than studio.ts's `create`: no locator, no
-- poster_url. Those are maintained denormalisations, and the trigger on
-- title_assets rewrites both the instant the first asset lands — which here is
-- three lines later. Setting them by hand would be a second opinion about
-- something the database already decides.
--
-- The title is born a DRAFT. Everything a card needs beyond a name and its
-- files — category, year, rating, the Burmese title, the tags — is typed in
-- the editor afterwards, which is where the operator is standing anyway once
-- the title exists.
--
-- ---------------------------------------------------------------------------
-- 2. THE CAPTION WAS THROWN AWAY EXCEPT FOR ITS FIRST LINE
-- ---------------------------------------------------------------------------
--
-- The operator writes the whole thing in Telegram, in Burmese, while
-- forwarding: a name, a blank line, three paragraphs of synopsis. The webhook
-- took `caption.split('\n')[0]`, slugified it into a folder, and dropped the
-- rest on the floor — so the description had to be typed a second time, into a
-- phone, from memory or by scrolling back through Telegram.
--
-- The whole caption is kept now, and inherited across an album exactly as the
-- folder is, because it arrives on one message of the group and belongs to all
-- of them. Unlike the folder it is only metadata, so a sibling that a runner
-- has already claimed gets it too — there is no key to disagree with.
--
-- ---------------------------------------------------------------------------
-- 3. FIFTEEN ROWS MEANT FIFTEEN DROPDOWNS
-- ---------------------------------------------------------------------------
--
-- `attach_ingest` points one job at one title. An album is one thing to the
-- person who sent it, and picking the same title from a dropdown fifteen times
-- is fifteen chances to pick the wrong one on the eleventh.
-- `attach_ingest_folder` takes the folder, which is what the album agreed on
-- in 023, and attaches everything finished in it.
-- ===========================================================================

alter table public.ingest_jobs
  add column if not exists tg_caption text;

comment on column public.ingest_jobs.tg_caption is
  'The whole caption the operator typed while forwarding, not just the first '
  'line the folder is slugified from. Inherited across a media group.';

-- ---------------------------------------------------------------------------
-- enqueue_ingest — now also carries the caption
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_ingest(
  p_file_id     text,
  p_unique_id   text,
  p_chat_id     bigint,
  p_message_id  bigint,
  p_file_name   text,
  p_mime        text,
  p_bytes       bigint,
  p_duration    integer,
  p_width       integer,
  p_height      integer,
  p_kind        text,
  p_bucket      text,
  p_folder      text,
  p_key_tail    text,
  p_media_group text,
  p_caption     text default null
) returns table(status text, folder text, moved integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_folder  text := nullif(btrim(coalesce(p_folder, '')), '');
  v_group   text := nullif(btrim(coalesce(p_media_group, '')), '');
  v_caption text := nullif(btrim(coalesce(p_caption, '')), '');
  v_moved   integer := 0;
  v_id      uuid;
begin
  -- One delivery of one album at a time. See 023.
  if v_group is not null then
    perform pg_advisory_xact_lock(hashtext('ingest_group:' || v_group));
  end if;

  -- No caption of its own: take what a sibling was given. The folder and the
  -- caption travel together because they come from the same message.
  if v_folder is null and v_group is not null then
    select split_part(j.object_key, '/', 1), j.tg_caption
      into v_folder, v_caption
      from public.ingest_jobs j
     where j.tg_media_group = v_group
       and split_part(j.object_key, '/', 1) <> 'inbox'
     order by j.created_at asc
     limit 1;
  end if;

  insert into public.ingest_jobs
    (tg_file_id, tg_unique_id, tg_chat_id, tg_message_id, file_name, mime,
     bytes, duration_s, width, height, kind, bucket, object_key,
     tg_media_group, tg_caption)
  values
    (p_file_id, p_unique_id, p_chat_id, p_message_id, p_file_name,
     nullif(p_mime, ''), nullif(p_bytes, 0), p_duration, p_width, p_height,
     p_kind, p_bucket, coalesce(v_folder, 'inbox') || '/' || p_key_tail,
     v_group, v_caption)
  on conflict (tg_unique_id) where state <> 'failed' do nothing
  returning id into v_id;

  if v_id is null then
    return query select 'duplicate'::text, coalesce(v_folder, 'inbox'), 0;
    return;
  end if;

  -- The caption arrived after its siblings.
  if v_group is not null and v_folder is not null and v_folder <> 'inbox' then
    -- The KEY may only be rewritten while nothing holds it: a claimed row has
    -- a presigned PUT for the old one.
    update public.ingest_jobs j
       set object_key = v_folder || substr(j.object_key, length('inbox') + 1)
     where j.tg_media_group = v_group
       and j.id <> v_id
       and j.state = 'queued'
       and j.object_key like 'inbox/%';
    get diagnostics v_moved = row_count;
  end if;

  -- The CAPTION has no such constraint — nothing is signed against it — so it
  -- reaches siblings in any state, including ones already in the bucket.
  if v_group is not null and v_caption is not null then
    update public.ingest_jobs j
       set tg_caption = v_caption
     where j.tg_media_group = v_group
       and j.id <> v_id
       and j.tg_caption is null;
  end if;

  return query select 'queued'::text, coalesce(v_folder, 'inbox'), v_moved;
end;
$$;

revoke all on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text, text) to service_role;

-- The fifteen-argument version 023 created. Dropped rather than left to rot:
-- two overloads differing only in a trailing default is how PostgREST comes to
-- pick the wrong one and the caption silently stops being stored.
drop function if exists public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text);

-- ---------------------------------------------------------------------------
-- attach_ingest_folder — the whole album at once
-- ---------------------------------------------------------------------------
--
-- Returns how many were attached. Skips anything not finished, because
-- pointing a title at a half-written object publishes a film that cannot play,
-- and skips anything already attached, because `attach_ingest` is idempotent
-- per job and this should be idempotent per folder.
create or replace function public.attach_ingest_folder(
  p_folder text, p_title uuid
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j      record;
  n      integer := 0;
  v_pref text := btrim(coalesce(p_folder, ''));
begin
  if v_pref = '' or p_title is null then
    return 0;
  end if;
  -- IN THE ORDER THEY WERE SENT. `attach_ingest` gives each asset the next
  -- sort_order for its kind, so the album appears in the app the way the
  -- operator laid it out in Telegram rather than in whatever order the runner
  -- happened to finish them.
  for j in
    select id from public.ingest_jobs
     where state = 'done'
       and title_id is null
       and object_key like v_pref || '/%'
     order by created_at asc
  loop
    perform public.attach_ingest(j.id, p_title);
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke all on function public.attach_ingest_folder(text, uuid)
  from public, anon, authenticated;
grant execute on function public.attach_ingest_folder(text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- a title must not go live with nothing in it
-- ---------------------------------------------------------------------------
--
-- Now that a title can exist before its files do — for the few milliseconds
-- inside create_title_from_ingest, and for as long as the operator likes if an
-- attach fails — the editor is a place where an empty one can be ticked
-- Published. That is a card in the app that opens onto nothing, and the only
-- reading a viewer has for it is that the app is broken.
--
-- ON UPDATE ONLY, and that is not an oversight. `create` in studio.ts inserts
-- the title row with `published` already true and inserts its assets a line
-- later, so an INSERT trigger would refuse the ordinary way a published title
-- has always been made. The INSERT side is guarded by studio.ts still
-- requiring assets on create, and by this function always creating drafts.
create or replace function public.no_empty_title_goes_live()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if new.published and not coalesce(old.published, false) then
    if not exists (select 1 from public.title_assets a where a.title_id = new.id) then
      raise exception 'a title with no files cannot be published'
        using errcode = 'check_violation';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists titles_no_empty_publish on public.titles;
create trigger titles_no_empty_publish
  before update on public.titles
  for each row execute function public.no_empty_title_goes_live();

-- ---------------------------------------------------------------------------
-- create_title_from_ingest — one album becomes one title
-- ---------------------------------------------------------------------------
--
-- Everything it needs is already in the queue: the folder the album agreed on,
-- and the name and synopsis the operator typed in Telegram while forwarding.
-- Returns the new title and how many files went onto it.
create or replace function public.create_title_from_ingest(
  p_folder   text,
  p_title    text,
  p_synopsis text default null
) returns table(title_id uuid, attached integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_folder text := btrim(coalesce(p_folder, ''));
  v_name   text := btrim(coalesce(p_title, ''));
  v_id     uuid;
  n        integer;
begin
  if v_folder = '' then
    raise exception 'no folder' using errcode = 'check_violation';
  end if;
  if v_name = '' then
    raise exception 'a title needs a name' using errcode = 'check_violation';
  end if;
  -- `titles_slug_key` is unique, so this is also the check that the folder is
  -- not already some other title's. Letting the index refuse it is better than
  -- asking first and racing between the question and the insert.
  if exists (select 1 from public.titles t where t.slug = v_folder) then
    raise exception 'that folder already belongs to another title'
      using errcode = 'unique_violation';
  end if;

  insert into public.titles (title, synopsis, slug, published, status)
  values (v_name, nullif(btrim(coalesce(p_synopsis, '')), ''), v_folder,
          false, 'draft')
  returning id into v_id;

  select public.attach_ingest_folder(v_folder, v_id) into n;
  return query select v_id, n;
end;
$$;

revoke all on function public.create_title_from_ingest(text, text, text)
  from public, anon, authenticated;
grant execute on function public.create_title_from_ingest(text, text, text)
  to service_role;
