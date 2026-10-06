-- 043 — every video gets a picture, and ten to choose from
--
-- Owner request (2026-10-06): "a video with no thumbnail chosen shows
-- nothing. Show the frame at 00:01 by default. Better still, like TikTok's
-- cover picker: cut the video into ten even parts and let me pick one of
-- those frames, instead of hunting for the original file on my phone."
--
-- Measured before this: 11 of 17 videos had no `thumb_key`. Everything that
-- came in through Telegram had none (the console's upload grabs a frame on
-- the operator's device; a forwarded film never passes through one), and so
-- did every upload older than that grab.
--
-- THE FRAMES ARE MADE ON THE TRANSCODE RUNNER, NOT IN THE BROWSER. A browser
-- cannot draw a frame of an R2 video onto a canvas without CORS on the media
-- bucket (it allows PUT only), cannot decode HEVC or MKV at all on most
-- devices, and would have to fetch a film to scrub it. ffmpeg on the runner
-- seeks over HTTP with range requests — ten seeks of a two-hour film cost a
-- few megabytes — and tone-maps HDR the same way the ladder does.
--
-- 1. `frames`: `[{ "at": seconds, "key": "<folder>/thumb/<stem>-f00.jpg" }, …]`
--    in the PUBLIC bucket — ten JPEGs, 640 px on the long edge. Frame 0 is at
--    one second (the default thumbnail); 1–9 are at 10 %, 20 % … 90 %.
-- 2. `frames_state`: null = never made (the runner picks these up by itself),
--    'queued' = asked for again from the console, 'running', 'done', 'failed'.
-- 3. `record_frames` sets `thumb_key` to frame 0 ONLY WHEN THERE IS NONE. A
--    thumbnail the operator chose is never replaced.
-- 4. The Files page counts them as in use, and a folder move carries them.

alter table public.title_assets
  add column if not exists frames       jsonb,
  add column if not exists frames_state text,
  add column if not exists frames_at    timestamptz,
  add column if not exists frames_note  text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'title_assets_frames_state') then
    alter table public.title_assets add constraint title_assets_frames_state
      check (frames_state is null or frames_state in ('queued', 'running', 'done', 'failed'));
  end if;
end $$;

-- ── the runner's batch ─────────────────────────────────────────────────────
--
-- Up to `p_limit` videos that need frames, newest first (the one somebody is
-- looking at in the console right now is the newest). The SOURCE is the
-- original when it is in R2, otherwise the best streaming copy — a film whose
-- original lives only in Telegram (029) still has its ladder.
create or replace function public.claim_frames(p_limit integer default 20)
returns table(asset_id uuid, src_key text, master_key text, duration_s integer)
language sql
security definer
set search_path = public
as $$
  with pick as (
    select a.id
      from public.title_assets a
     where a.kind <> 'photo'
       and (a.frames_state is null
            or a.frames_state = 'queued'
            -- A runner that died mid-batch. Two hours is far past the time a
            -- batch of twenty takes.
            or (a.frames_state = 'running' and a.frames_at < now() - interval '2 hours'))
       and (a.master_state = 'r2'
            or exists (select 1 from public.asset_renditions r where r.asset_id = a.id))
     order by (a.frames_state = 'queued') desc nulls last, a.added_at desc
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 20), 50))
  )
  update public.title_assets a
     set frames_state = 'running', frames_at = now(), frames_note = null
    from pick
   where a.id = pick.id
  returning a.id,
    case when a.master_state = 'r2' then a.object_key
         else (select r.object_key from public.asset_renditions r
                where r.asset_id = a.id order by r.height desc limit 1)
    end,
    a.object_key,
    a.duration_s;
$$;

-- ── the runner's answer ────────────────────────────────────────────────────
--
-- Answers the asset's thumbnail after the write: frame 0 if it had none, or
-- the one it already had.
create or replace function public.record_frames(p_asset uuid, p_frames jsonb, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  first_key text;
  out_key   text;
begin
  if p_frames is null or jsonb_typeof(p_frames) <> 'array' or jsonb_array_length(p_frames) = 0 then
    update public.title_assets
       set frames_state = 'failed', frames_at = now(),
           frames_note = left(coalesce(p_note, 'no frames'), 200)
     where id = p_asset;
    return null;
  end if;
  -- Only keys shaped like the ones the function minted: a thumbnail key ends
  -- up in a public URL, and this is the last place to refuse a strange one.
  if exists (select 1 from jsonb_array_elements(p_frames) f
              where coalesce(f->>'key', '') !~ '^([a-z0-9][a-z0-9.\-]*/)*thumb/[a-z0-9][a-z0-9.\-]*\.jpg$'
                 or jsonb_typeof(f->'at') <> 'number') then
    raise exception 'record_frames: unexpected frame entry';
  end if;
  first_key := p_frames->0->>'key';
  update public.title_assets
     set frames = p_frames, frames_state = 'done', frames_at = now(),
         frames_note = left(p_note, 200),
         thumb_key = coalesce(thumb_key, first_key)
   where id = p_asset
  returning thumb_key into out_key;
  return out_key;
end;
$$;

-- ── "make them again" from the console ─────────────────────────────────────
create or replace function public.queue_frames(p_asset uuid)
returns text
language sql
security definer
set search_path = public
as $$
  update public.title_assets
     set frames_state = 'queued', frames_note = null, frames_at = now()
   where id = p_asset and kind <> 'photo'
  returning frames_state;
$$;

revoke all on function public.claim_frames(integer) from public, anon, authenticated;
revoke all on function public.record_frames(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.queue_frames(uuid) from public, anon, authenticated;
grant execute on function public.claim_frames(integer) to service_role;
grant execute on function public.record_frames(uuid, jsonb, text) to service_role;
grant execute on function public.queue_frames(uuid) to service_role;

-- ── the Files page: the ten choices are in use, not clutter ────────────────
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable security definer
set search_path = public
as $$
  select a.object_key, a.title_id, 'file'::text from public.title_assets a
   where a.object_key is not null and a.master_state <> 'telegram'
  union all
  select a.thumb_key, a.title_id, 'thumbnail' from public.title_assets a
   where a.thumb_key is not null
  union all
  -- 043: the frames a thumbnail can be chosen from. Not "unused" — the
  -- console offers them on every video.
  select f->>'key', a.title_id, 'thumbnail choice'
    from public.title_assets a, jsonb_array_elements(a.frames) f
   where a.frames is not null and jsonb_typeof(a.frames) = 'array'
     and a.thumb_key is distinct from f->>'key'
  union all
  select r.object_key, a.title_id, 'streaming copy'
    from public.asset_renditions r join public.title_assets a on a.id = r.asset_id
  union all
  select t.locator, t.id, 'file' from public.titles t
   where coalesce(t.locator, '') <> ''
     and not exists (select 1 from public.title_assets a
                      where a.object_key = t.locator and a.master_state = 'telegram')
  union all
  select substr(t.poster_url, length(public.public_asset_base()) + 1), t.id, 'cover'
    from public.titles t
   where t.poster_url like public.public_asset_base() || '%'
  union all
  select j.object_key, j.title_id, 'telegram inbox' from public.ingest_jobs j
   where j.title_id is null
  union all
  select b.object_key, null::uuid, 'database backup' from public.db_backups b
   where b.deleted_at is null
  union all
  select substr(r.apk_url, length(public.public_asset_base()) + 1), null::uuid, 'app update'
    from public.app_releases r
   where r.apk_url like public.public_asset_base() || 'apk/%';
$$;

-- ── a folder move carries the frames with it ───────────────────────────────
--
-- `r2_move_switch` rewrites every key column it knows; `frames` is a list
-- inside a jsonb, so it is rewritten here, when a move is switched, from the
-- same from → to map. Without it the console would offer ten broken images
-- after a rename, and the Files page would call the moved copies unused.
create or replace function public.r2_move_carry_frames()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.state = 'switched' and old.state is distinct from 'switched' then
    update public.title_assets x
       set frames = (
         select jsonb_agg(
                  case when m.to_key is not null
                       then jsonb_set(e.f, array['key'], to_jsonb(m.to_key))
                       else e.f end
                  order by e.ord)
           from jsonb_array_elements(x.frames) with ordinality e(f, ord)
           left join (select o->>'from' as from_key, o->>'to' as to_key
                        from jsonb_array_elements(new.objects) o) m
             on m.from_key = e.f->>'key')
     where x.frames is not null and jsonb_typeof(x.frames) = 'array'
       and exists (select 1
                     from jsonb_array_elements(x.frames) f
                     join jsonb_array_elements(new.objects) o on o->>'from' = f->>'key');
  end if;
  return new;
end;
$$;

drop trigger if exists r2_move_carry_frames on public.r2_moves;
create trigger r2_move_carry_frames
  after update of state on public.r2_moves
  for each row execute function public.r2_move_carry_frames();
