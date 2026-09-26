-- ===========================================================================
-- 022  THE QUEUE BETWEEN A FORWARDED FILM AND R2   (F1)
-- ===========================================================================
--
-- The operator works from a phone and the films are gigabytes. Uploading one
-- from a handset over a Myanmar connection is hours of holding the screen
-- awake. The film is usually ALREADY on Telegram, on a server with a fast link
-- to everywhere — so the shortest path does not go through the phone at all.
--
-- This is the state between "forwarded to the bot" and "in the bucket". The
-- edge function `ingest` writes a row when Telegram delivers a file; a GitHub
-- Actions runner claims one, moves the bytes, and reports.
--
-- WHY A TABLE AND NOT A DIRECT HANDOFF. The webhook has to answer Telegram in
-- seconds or the delivery is retried, and moving a gigabyte takes minutes. The
-- row is the thing that survives in between — and it is also the record of
-- where a file in the bucket came from, which nothing else keeps.
--
-- This file is the FINAL state of five migrations applied on 2026-09-26. The
-- numbered file is the record; the live database was migrated in steps.
--
-- ---------------------------------------------------------------------------
-- WHAT WENT WRONG THE FIRST TIME, TWICE, AND WHY IT IS WRITTEN DOWN HERE
-- ---------------------------------------------------------------------------
--
-- 1. SECURITY DEFINER DOES NOT COVER POSTGREST. The table was created with RLS
--    on, no policies, and every privilege revoked from anon, authenticated AND
--    service_role, on the reasoning that all access goes through the three
--    SECURITY DEFINER functions below. It does not: the webhook INSERTs through
--    /rest/v1/ingest_jobs and the console's list SELECTs the same way, both
--    with the service key, and PostgREST is an ordinary client. Every claim
--    answered 200 and every test passed, because the tests called the
--    functions — while the one path the operator would actually use, forwarding
--    a film, would have answered "Could not queue that one" for ever.
--
--    Caught by setting role to service_role and running the statement the
--    function runs, rather than the function.
--
-- 2. A FAILURE WAS A DEAD END. finish_ingest(ok => false) set state='failed'
--    and stopped, and the unique index on tg_unique_id was unconditional — so
--    forwarding the same film again, the one gesture a phone operator will
--    reach for, hit the duplicate branch and was told "Already queued", which
--    was false. Nothing was queued and nothing ever would be. The first
--    failure this pipeline was ever going to see is "Telegram credentials are
--    not set on this repository", because api_id and api_hash arrive after the
--    bot does.

create table if not exists public.ingest_jobs (
  id            uuid primary key default gen_random_uuid(),
  -- From Telegram. `tg_file_id` is what the Bot API hands over; the runner is
  -- given the CHAT AND MESSAGE instead and fetches the message, because a file
  -- id is an encoding of an MTProto location and depending on that encoding is
  -- depending on an implementation detail.
  tg_file_id    text not null,
  tg_unique_id  text not null,
  tg_chat_id    bigint,
  tg_message_id bigint,
  file_name     text,
  mime          text,
  bytes         bigint,
  -- Present only when the film was sent as a VIDEO. A document — which is what
  -- the operator should send, because it is byte-for-byte the master — carries
  -- none of these, and probe-media fills them in later.
  duration_s    integer,
  width         integer,
  height        integer,
  -- Chosen in the console afterwards, not guessed from the caption. Matching a
  -- card by a typed name is a guess, and this should not guess about where a
  -- film ends up.
  title_id      uuid references public.titles(id) on delete set null,
  kind          text not null default 'video',
  bucket        text not null default 'innocent-media',
  object_key    text not null,
  state         text not null default 'queued'
                check (state in ('queued', 'running', 'done', 'failed')),
  note          text,
  -- How many runners have taken this row. See finish_ingest: a failure goes
  -- back to 'queued' until three are spent.
  attempts      integer not null default 0,
  claimed_at    timestamptz,
  finished_at   timestamptz,
  created_at    timestamptz not null default now()
);

-- Forwarding the same film twice is the ordinary accident, not an unusual one,
-- and the second one costing nothing is the point of this index.
--
-- PARTIAL, on purpose. It ignores terminally failed rows, so a film whose three
-- attempts are spent can be forwarded again and is accepted as a new job; the
-- failed row stays as history. A 'done' file still cannot be re-forwarded,
-- which is what the index is for: the bytes are in the bucket and paying to
-- move them twice is waste.
drop index if exists public.ingest_jobs_unique_file;
create unique index ingest_jobs_unique_file
  on public.ingest_jobs (tg_unique_id)
  where state <> 'failed';

create index if not exists ingest_jobs_queue
  on public.ingest_jobs (state, created_at);

alter table public.ingest_jobs enable row level security;

-- No policies, so RLS refuses everyone it applies to. service_role has
-- BYPASSRLS and now also the grants it needs — see mistake 1 above. DELETE is
-- left out because nothing deletes: a finished job is the record of where a
-- file came from. anon and authenticated keep nothing; the rows carry Telegram
-- file ids and R2 object keys, and the console reaches them through the edge
-- function.
grant select, insert, update on public.ingest_jobs to service_role;
revoke all on public.ingest_jobs from anon, authenticated;

-- ---------------------------------------------------------------------------

create or replace function public.claim_ingest()
returns table (
  job_id uuid, tg_file_id text, tg_chat_id bigint, tg_message_id bigint,
  object_key text, bucket text, file_name text, bytes bigint
)
language sql
security definer
set search_path to 'public'
as $$
  update public.ingest_jobs j
     set state = 'running',
         note = 'claimed',
         claimed_at = now(),
         -- Incremented here rather than in finish_ingest because a runner that
         -- dies without reporting must also spend an attempt — otherwise a job
         -- that kills its runner every time is claimed for ever, seven hours
         -- apart.
         attempts = j.attempts + 1
   where j.id = (
     select x.id from public.ingest_jobs x
      where x.state = 'queued'
         -- A runner that died leaves a row saying 'running' for ever. GitHub
         -- kills a job at six hours and a runner can vanish at any moment;
         -- nothing about that reaches this database. Seven hours is past the
         -- platform's own ceiling, so a live job is never stolen from itself.
         or (x.state = 'running' and x.claimed_at < now() - interval '7 hours')
      order by (x.state = 'running'), x.created_at asc
      for update skip locked
      limit 1
   )
  returning j.id, j.tg_file_id, j.tg_chat_id, j.tg_message_id,
            j.object_key, j.bucket, j.file_name, j.bytes;
$$;

-- The catalogue row is created HERE, and only on success. A row written when
-- the job was queued would be a title that fails to play for the hour the
-- transfer takes.
create or replace function public.finish_ingest(
  p_job uuid, p_ok boolean, p_note text default null, p_bytes bigint default null
) returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j public.ingest_jobs%rowtype;
  new_asset uuid;
  slot integer;
  -- Three, because the failures worth retrying are transient — Telegram rate
  -- limiting, an R2 hiccup, a runner that lost its network — and the ones that
  -- are not would otherwise tick every five minutes for ever.
  max_tries constant integer := 3;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;

  if not p_ok then
    if j.attempts < max_tries then
      update public.ingest_jobs
         set state = 'queued',
             note = left('attempt ' || j.attempts || ' of ' || max_tries
                         || ' failed: ' || coalesce(p_note, 'no reason given'), 300),
             -- Cleared, because a row the console shows as finished is a row
             -- nobody waits for, and this one is going round again.
             finished_at = null
       where id = p_job;
      return 'requeued';
    end if;
    update public.ingest_jobs
       set state = 'failed',
           note = left('gave up after ' || j.attempts || ' attempts: '
                       || coalesce(p_note, 'no reason given'), 300),
           finished_at = now()
     where id = p_job;
    return 'failed';
  end if;

  -- A job with no title is parked on purpose: the operator can forward
  -- something before deciding which card it belongs to, and `attach_ingest`
  -- finishes the thought later. The bytes are in the bucket either way, which
  -- is the expensive half.
  if j.title_id is not null then
    -- 011's lesson: title_assets is unique on (title_id, kind, sort_order), so
    -- the SECOND video attached to a title collides unless the next free slot
    -- is computed per title and kind.
    select coalesce(max(a.sort_order), -1) + 1 into slot
      from public.title_assets a
     where a.title_id = j.title_id and a.kind = j.kind;

    insert into public.title_assets
      (title_id, kind, bucket, object_key, bytes, duration_s, width, height,
       mime, sort_order, transcode_state)
    values
      (j.title_id, j.kind, j.bucket, j.object_key,
       coalesce(p_bytes, j.bytes), j.duration_s, j.width, j.height, j.mime,
       slot,
       case when j.kind = 'photo' then 'none' else 'queued' end)
    returning id into new_asset;
  end if;

  update public.ingest_jobs
     set state = 'done',
         note = left(coalesce(p_note, ''), 300),
         -- What R2 accepted, not what Telegram claimed. They should agree; the
         -- bucket is the one that is right if they ever do not.
         bytes = coalesce(p_bytes, bytes),
         finished_at = now()
   where id = p_job;

  return coalesce(new_asset::text, 'done_unattached');
end;
$$;

-- Point a finished ingest at a title, afterwards, from the console.
--
-- IDEMPOTENT, because the operator will click twice. If an asset already
-- carries this object key it is repointed rather than duplicated — two rows
-- for one object would mean the unused-file report in 021 calling neither of
-- them an orphan while the album shows the film twice.
create or replace function public.attach_ingest(p_job uuid, p_title uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j public.ingest_jobs%rowtype;
  existing uuid;
  new_asset uuid;
  slot integer;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;
  if j.state <> 'done' then
    return 'not_done';
  end if;
  if p_title is null then
    return 'no_title';
  end if;

  select a.id into existing
    from public.title_assets a
   where a.object_key = j.object_key
   limit 1;
  if existing is not null then
    update public.title_assets set title_id = p_title where id = existing;
    update public.ingest_jobs set title_id = p_title where id = p_job;
    return existing::text;
  end if;

  select coalesce(max(a.sort_order), -1) + 1 into slot
    from public.title_assets a
   where a.title_id = p_title and a.kind = j.kind;

  insert into public.title_assets
    (title_id, kind, bucket, object_key, bytes, duration_s, width, height,
     mime, sort_order, transcode_state)
  values
    (p_title, j.kind, j.bucket, j.object_key, j.bytes, j.duration_s,
     j.width, j.height, j.mime, slot,
     case when j.kind = 'photo' then 'none' else 'queued' end)
  returning id into new_asset;

  update public.ingest_jobs set title_id = p_title where id = p_job;
  return new_asset::text;
end;
$$;
