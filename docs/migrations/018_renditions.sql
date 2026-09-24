-- 018 — so that ANY file can be uploaded and nobody has to think about it.
--
-- THE OPERATOR'S ACTUAL REQUIREMENT, in their own words: whatever the size,
-- however it was shot, 4K or high frame rate, it must not stutter — because
-- the person uploading will not be thinking about bitrates, and should not
-- have to.
--
-- 017 made the problem visible and honest. It did not solve it. A camera
-- clip needing 61 Mbps cannot be streamed over a 48 Mbps link, and no
-- player setting, buffer size or edge cache changes that arithmetic. The
-- only thing that changes it is having a SMALLER COPY of the same video.
--
-- That is what every streaming service does and it is the only thing that
-- works: keep the master, derive a ladder of smaller versions from it, and
-- give each viewer the rung their connection can carry. Netflix and YouTube
-- differ from this in scale, not in kind.
--
-- WHY THE LADDER IS SERVED AS SEPARATE MP4s RATHER THAN HLS. HLS exists so
-- a player can change rung MID-STREAM without interrupting anything. This
-- app plays through libmpv, and libmpv cannot do that: it uses FFmpeg's HLS
-- demuxer, which reads the master playlist, picks one variant at open, and
-- stays on it — `--hls-bitrate` has no effect once playback has started
-- (mpv#15158, mpv#3548). An HLS ladder here would cost segmenting, playlist
-- serving and per-segment tokens to buy a feature the player cannot use.
--
-- So the rungs are plain MP4 objects, the app chooses one at open from what
-- it has measured, and a stall that the app DIAGNOSES as the network (017)
-- reopens one rung lower at the same position. The choice is adaptive; only
-- the switching is not seamless. When this app one day plays the hub through
-- a decoder stack that does real ABR, the ladder built here is exactly what
-- HLS would be packaged from, and nothing below has to change.

-- ===========================================================================
-- 1. THE LADDER
-- ===========================================================================
create table if not exists public.asset_renditions (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.title_assets(id) on delete cascade,
  -- The short side, which is how everyone names a rung: 360, 480, 720, 1080.
  height      int  not null,
  -- What it actually demands, measured from the encoded file rather than
  -- from what the encoder was asked for. The ASKED-FOR number is a target;
  -- the delivered one is what a viewer's connection has to carry, and the
  -- two differ by a lot on high-motion footage.
  kbps        int  not null,
  object_key  text not null,
  bytes       bigint,
  -- Frame rate is kept from the source and recorded, because "60fps" is a
  -- thing an operator chose deliberately and a thing a viewer notices. A
  -- ladder that quietly halved it would be answering a bandwidth question
  -- by changing the film.
  fps         numeric(5,2),
  created_at  timestamptz not null default now(),
  unique (asset_id, height)
);

create index if not exists asset_renditions_asset_idx
  on public.asset_renditions (asset_id, kbps);

-- RLS on with no policy: read through `request-playback`, which is a definer
-- function's job, never through PostgREST. A viewer holding the anon key
-- must not be able to list every object key in the bucket.
alter table public.asset_renditions enable row level security;

-- ===========================================================================
-- 2. WHERE A FILE IS IN THE PIPELINE
-- ===========================================================================
-- `none` is the honest state for everything uploaded before today, and for
-- anything small enough that a ladder would be waste. It means "play the
-- original", which is exactly what happened before this migration existed.
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'title_assets'
      and column_name = 'transcode_state'
  ) then
    alter table public.title_assets
      add column transcode_state text not null default 'none',
      add column transcode_note  text,
      add column transcode_at    timestamptz;
  end if;
end $$;

alter table public.title_assets drop constraint if exists title_assets_transcode_state_ck;
alter table public.title_assets add constraint title_assets_transcode_state_ck
  check (transcode_state in ('none','queued','running','ready','failed'));

-- ===========================================================================
-- 3. WHAT THE PLAYER ASKS FOR
-- ===========================================================================
-- Returns the ladder for one asset, cheapest rung first, with the original
-- appended as the top rung so a viewer on wifi still gets the best copy
-- there is. Called by `request-playback`, which holds the service key.
--
-- SECURITY: definer, because `asset_renditions` has RLS with no policy and
-- must stay that way — the rows are object keys, and a list of object keys
-- is a map of the bucket.
create or replace function public.renditions_for(p_asset uuid)
returns table (height int, kbps int, object_key text, bytes bigint)
language sql
security definer
set search_path = public
as $$
  select r.height, r.kbps, r.object_key, r.bytes
  from public.asset_renditions r
  where r.asset_id = p_asset
  order by r.kbps asc;
$$;

revoke all on function public.renditions_for(uuid) from public;
grant execute on function public.renditions_for(uuid) to service_role;

-- ===========================================================================
-- 4. WHAT THE ENCODER WRITES BACK
-- ===========================================================================
-- One call, the whole ladder, atomically. A partial ladder is worse than no
-- ladder: the app would pick the best rung it could see, and "the best rung
-- that finished uploading first" is not a bandwidth decision.
create or replace function public.record_renditions(
  p_asset uuid,
  p_rows  jsonb,
  p_note  text default null
)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  r       jsonb;
  written int := 0;
begin
  if jsonb_typeof(p_rows) <> 'array' then
    update public.title_assets
      set transcode_state = 'failed',
          transcode_note = coalesce(p_note, 'no rows'),
          transcode_at = now()
      where id = p_asset;
    return 0;
  end if;

  -- REPLACED, NOT APPENDED. A re-encode of the same asset must leave one
  -- ladder behind it, not two generations interleaved by height.
  delete from public.asset_renditions where asset_id = p_asset;

  for r in select * from jsonb_array_elements(p_rows) loop
    begin
      insert into public.asset_renditions
        (asset_id, height, kbps, object_key, bytes, fps)
      values (
        p_asset,
        (r ->> 'height')::int,
        (r ->> 'kbps')::int,
        r ->> 'object_key',
        nullif(r ->> 'bytes', '')::bigint,
        nullif(r ->> 'fps', '')::numeric
      );
      written := written + 1;
    exception when others then null;
    end;
  end loop;

  update public.title_assets
    set transcode_state = case when written > 0 then 'ready' else 'failed' end,
        transcode_note = p_note,
        transcode_at = now()
    where id = p_asset;

  return written;
end;
$$;

revoke all on function public.record_renditions(uuid, jsonb, text) from public;
grant execute on function public.record_renditions(uuid, jsonb, text) to service_role;

-- ===========================================================================
-- 5. WHAT THE CONSOLE SHOWS
-- ===========================================================================
-- One row per video with its ladder summarised, so the operator can see at a
-- glance which files are still being worked on and which are safe to
-- publish. The ORIGINAL's bitrate sits beside the ladder's smallest rung,
-- because the gap between those two numbers IS the work this pipeline does.
create or replace function public.rendition_health()
returns table (
  title        text,
  object_key   text,
  state        text,
  note         text,
  duration_s   int,
  src_kbps     int,
  rungs        int,
  lowest_kbps  int,
  highest_kbps int
)
language sql
security definer
set search_path = public
as $$
  select
    t.title,
    a.object_key,
    a.transcode_state,
    a.transcode_note,
    a.duration_s,
    case when coalesce(a.duration_s, 0) > 0 and a.bytes is not null
         then (a.bytes * 8 / a.duration_s / 1000)::int end,
    (select count(*)::int from public.asset_renditions r where r.asset_id = a.id),
    (select min(r.kbps) from public.asset_renditions r where r.asset_id = a.id),
    (select max(r.kbps) from public.asset_renditions r where r.asset_id = a.id)
  from public.title_assets a
  join public.titles t on t.id = a.title_id
  where a.kind <> 'photo'
  order by a.added_at desc
  limit 100;
$$;

revoke all on function public.rendition_health() from public;
grant execute on function public.rendition_health() to service_role;

-- ===========================================================================
-- 6. THE QUEUE
-- ===========================================================================
-- Applied as a second migration step; kept here so the file is the whole
-- story.
--
-- `for update skip locked` is the whole point of the claim: two runners that
-- start in the same minute — a scheduled tick and a manual kick — must not
-- both take the same file and race each other to write the same objects. The
-- second one skips the locked row and either takes the next job or finds
-- nothing, which is the correct answer for it.
create or replace function public.claim_transcode()
returns table (
  asset_id   uuid,
  object_key text,
  bucket     text,
  height     int,
  duration_s int,
  bytes      bigint
)
language sql
security definer
set search_path = public
as $$
  update public.title_assets a
     set transcode_state = 'running',
         transcode_note = 'claimed',
         transcode_at = now()
   where a.id = (
     select x.id from public.title_assets x
      where x.transcode_state = 'queued'
        and x.kind <> 'photo'
      order by x.added_at asc
      for update skip locked
      limit 1
   )
  returning a.id, a.object_key, a.bucket, a.height, a.duration_s, a.bytes;
$$;

revoke all on function public.claim_transcode() from public;
grant execute on function public.claim_transcode() to service_role;

create or replace function public.queue_transcode(p_asset uuid)
returns text
language sql
security definer
set search_path = public
as $$
  update public.title_assets
     set transcode_state = 'queued',
         transcode_note = null,
         transcode_at = now()
   where id = p_asset and kind <> 'photo'
  returning transcode_state;
$$;

revoke all on function public.queue_transcode(uuid) from public;
grant execute on function public.queue_transcode(uuid) to service_role;

-- A job that was claimed and never reported is a runner that died. Nothing
-- retries it today; this is what makes that visible rather than permanent.
create or replace function public.stuck_transcodes(p_hours int default 7)
returns table (asset_id uuid, object_key text, since timestamptz)
language sql
security definer
set search_path = public
as $$
  select id, object_key, transcode_at
  from public.title_assets
  where transcode_state = 'running'
    and transcode_at < now() - make_interval(hours => greatest(p_hours, 1))
  order by transcode_at asc;
$$;

revoke all on function public.stuck_transcodes(int) from public;
grant execute on function public.stuck_transcodes(int) to service_role;
