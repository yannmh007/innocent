-- ===========================================================================
-- 023  AN ALBUM IS ONE THING, AND A FAILURE IS NOT A DEAD END   (I1, I3)
-- ===========================================================================
--
-- Two faults found by the first real use of the Telegram ingest, on the day
-- api_id and api_hash finally existed and five files went end to end.
--
-- ---------------------------------------------------------------------------
-- 1. AN ALBUM ARRIVES AS SEPARATE MESSAGES AND ONLY ONE CARRIES THE CAPTION
-- ---------------------------------------------------------------------------
--
-- The operator sent four photos as one album, captioned `Chief of War (2025)`.
-- One landed in `chief-of-war-2025/` and three landed in `inbox/`.
--
-- That is not a mistake anyone made. Telegram does not deliver a media group
-- as one update: it sends one update PER FILE, they share a `media_group_id`,
-- and the caption is attached to exactly one of them — usually the first, but
-- the order is not promised and nothing says which. The webhook read
-- `message.caption` per message, which is correct for a single file and wrong
-- for every album, and an album is the natural way to send a title's artwork
-- from a phone.
--
-- Sorting the strays out afterwards is not a fix. The object key is minted
-- before the bytes move and the runner is handed a presigned PUT for that exact
-- key; once a job is claimed the folder is settled. So the folder has to be
-- agreed at INSERT time, across messages that arrive milliseconds apart, in
-- either order, possibly in parallel — which is a transaction, not a webhook.
--
-- Hence `enqueue_ingest`: the insert and the reconciliation in one statement.
-- It works in both directions, because both happen:
--
--   caption first   — the siblings arrive with none and INHERIT the folder.
--   caption second  — the siblings are already parked in `inbox/` and are
--                     MOVED, as long as no runner has claimed them yet.
--
-- The advisory lock is what makes "in parallel" safe. Two deliveries of the
-- same album can be running in two edge invocations; without it, a sibling
-- inserted a moment after the captioned row has taken its snapshot is invisible
-- to the move and invisible to its own inherit, and stays in `inbox` for ever.
-- It is taken per media group, so albums never wait on each other, and a single
-- forwarded film takes no lock at all.
--
-- THE FOLDER AND THE REST OF THE KEY ARE SPLIT because only the folder is in
-- question. The tail — `<kind>/<date>-<slug>-<random>.<ext>` — is minted by the
-- edge function, has to keep agreeing with what `isMintedKey` in studio.ts
-- accepts, and must not change when a row is moved.
--
-- ---------------------------------------------------------------------------
-- 2. A TERMINALLY FAILED JOB COULD ONLY BE RETRIED FROM TELEGRAM
-- ---------------------------------------------------------------------------
--
-- 022 made a failure re-forwardable, which was the important half. It left the
-- other half: the two rows that failed with `Telegram credentials are not set
-- on this repository` were still sitting there, `failed`, after the credentials
-- were set. Nothing was wrong with those jobs — chat, message and file id were
-- all still good — and the only way back was to find the message in Telegram
-- and forward it again.
--
-- A failure caused by the ENVIRONMENT should be recoverable where it is
-- visible. `retry_ingest` puts the row back in the queue, and refuses when the
-- unique index would refuse: if the same file has since been forwarded again
-- and is queued or done, retrying this row would be a second copy of bytes
-- already paid for.
-- ===========================================================================

alter table public.ingest_jobs
  add column if not exists tg_media_group text;

comment on column public.ingest_jobs.tg_media_group is
  'Telegram media_group_id: the album this file was sent in, or null. The '
  'caption belongs to one message of the group and the folder to all of them.';

-- Only albums are ever looked up by this, and most rows are not in one.
create index if not exists ingest_jobs_media_group
  on public.ingest_jobs (tg_media_group)
  where tg_media_group is not null;

-- ---------------------------------------------------------------------------
-- enqueue_ingest — the webhook's insert, with the album agreed
-- ---------------------------------------------------------------------------
--
-- Returns what the bot should say back: whether the row was taken, which
-- folder it ended up in, and how many siblings moved to join it. The bot used
-- to report the caption it had been given, which for three files out of four
-- was `inbox` — true, and the thing the operator most needed to not be true.
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
  p_media_group text
) returns table(status text, folder text, moved integer)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_folder text := nullif(btrim(coalesce(p_folder, '')), '');
  v_group  text := nullif(btrim(coalesce(p_media_group, '')), '');
  v_moved  integer := 0;
  v_id     uuid;
begin
  -- Everything below reads and writes the other rows of one album, so one
  -- delivery of that album runs at a time. Hashed to a bigint because that is
  -- what an advisory lock takes; a collision between two different albums
  -- costs one of them a few milliseconds of waiting and nothing else.
  if v_group is not null then
    perform pg_advisory_xact_lock(hashtext('ingest_group:' || v_group));
  end if;

  -- No caption of its own: take the folder a sibling was given.
  if v_folder is null and v_group is not null then
    select split_part(j.object_key, '/', 1) into v_folder
      from public.ingest_jobs j
     where j.tg_media_group = v_group
       and split_part(j.object_key, '/', 1) <> 'inbox'
     order by j.created_at asc
     limit 1;
  end if;

  insert into public.ingest_jobs
    (tg_file_id, tg_unique_id, tg_chat_id, tg_message_id, file_name, mime,
     bytes, duration_s, width, height, kind, bucket, object_key,
     tg_media_group)
  values
    (p_file_id, p_unique_id, p_chat_id, p_message_id, p_file_name,
     nullif(p_mime, ''), nullif(p_bytes, 0), p_duration, p_width, p_height,
     p_kind, p_bucket, coalesce(v_folder, 'inbox') || '/' || p_key_tail,
     v_group)
  on conflict (tg_unique_id) where state <> 'failed' do nothing
  returning id into v_id;

  if v_id is null then
    return query select 'duplicate'::text, coalesce(v_folder, 'inbox'), 0;
    return;
  end if;

  -- The caption arrived after its siblings. Move the ones still parked in
  -- `inbox`, and only while they are still QUEUED: a claimed row has already
  -- been handed a presigned PUT for its old key, and moving it would leave the
  -- row pointing at one object and the bytes at another.
  if v_folder is not null and v_folder <> 'inbox' and v_group is not null then
    update public.ingest_jobs j
       set object_key = v_folder || substr(j.object_key, length('inbox') + 1)
     where j.tg_media_group = v_group
       and j.id <> v_id
       and j.state = 'queued'
       and j.object_key like 'inbox/%';
    get diagnostics v_moved = row_count;
  end if;

  return query select 'queued'::text, coalesce(v_folder, 'inbox'), v_moved;
end;
$$;

revoke all on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.enqueue_ingest(
  text, text, bigint, bigint, text, text, bigint, integer, integer, integer,
  text, text, text, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- retry_ingest — put a terminally failed job back in the queue
-- ---------------------------------------------------------------------------
create or replace function public.retry_ingest(p_job uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j public.ingest_jobs%rowtype;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;
  -- Only a spent row. A queued or running one is already on its way, and a
  -- done one has its bytes in the bucket — moving them again is waste.
  if j.state <> 'failed' then
    return 'not_failed';
  end if;

  -- The partial unique index ignores failed rows, so the same file may have
  -- been forwarded again since. Requeueing this one would violate it — and
  -- more to the point would fetch a gigabyte twice.
  if exists (
    select 1 from public.ingest_jobs x
     where x.tg_unique_id = j.tg_unique_id
       and x.state <> 'failed'
  ) then
    return 'duplicate';
  end if;

  update public.ingest_jobs
     set state = 'queued',
         -- Back to zero, because the three attempts were spent on a reason
         -- that no longer applies. A retry that started at three would fail
         -- once and be dead again.
         attempts = 0,
         note = null,
         claimed_at = null,
         finished_at = null
   where id = p_job;
  return 'queued';
end;
$$;

revoke all on function public.retry_ingest(uuid) from public, anon, authenticated;
grant execute on function public.retry_ingest(uuid) to service_role;
