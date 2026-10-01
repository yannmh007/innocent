-- 029 — Telegram is the archive, R2 is the working set.
--
-- THE POLICY (design review, Phase 5). Viewers only ever stream from R2
-- through Cloudflare, because that is what does not stutter in Myanmar. What
-- R2 does NOT have to hold is the second copy of a film Telegram already has:
--
--   * a MASTER whose streaming copies exist can live only in Telegram — the
--     app streams a rung whenever there is a ladder, so the master is only
--     ever read to make the ladder again or to be downloaded whole;
--   * a whole TITLE nobody watches can be ARCHIVED: everything of its films
--     leaves R2, the title leaves the app, and RESTORE brings it back from
--     Telegram (a 400 MB film is about three minutes on the runner);
--   * a PINNED title keeps everything in R2, whatever the policy says.
--
-- WHAT KEEPS THIS SAFE, because the cost of being wrong is a film nobody can
-- get back:
--
--   1. Nothing leaves R2 at once. Every file goes to the seven-day bin
--      (migration 028), restorable instantly until then.
--   2. The bin does not delete a file whose only other copy is in Telegram
--      unless the runner has LOOKED at that Telegram message in the last three
--      days and found the same file there (`vault_copies.state = 'ok'`). A
--      check that has not happened yet holds the delete back; a check that
--      found the message gone or changed puts everything back in R2 at once
--      (`vault_rescue`) and the owner is told.
--   3. A Telegram copy is looked at again every week after that, so "the
--      archive is gone" is found out early, not on the day it is needed.
--   4. Automatic freeing of masters is OFF until the owner turns it on.
--
-- WHAT IS NOT A TELEGRAM COPY. Only a film that arrived by being forwarded to
-- the bot has one: the runner can fetch that message again. A film uploaded
-- from the console never touched Telegram, so it can be neither freed nor
-- archived — the console says so rather than pretending.
--
-- INFREQUENT ACCESS IS NOT USED, deliberately. R2's free 10 GB applies only to
-- Standard storage, Infrequent Access has a 30-day minimum and charges for
-- every byte read, and this catalogue is far below 10 GB. Moving anything there
-- today would turn a free month into a paid one. The console shows the sum.

-- ---------------------------------------------------------------------------
-- where things are
-- ---------------------------------------------------------------------------

alter table public.titles
  add column if not exists storage_state     text not null default 'hot',
  add column if not exists pinned            boolean not null default false,
  add column if not exists archived_at       timestamptz,
  -- Whether the title was in the app when it was archived, so restoring puts
  -- it back exactly where it was and a draft stays a draft.
  add column if not exists archived_was_live boolean,
  add column if not exists storage_note      text;

alter table public.titles drop constraint if exists titles_storage_state_ck;
alter table public.titles add constraint titles_storage_state_ck
  check (storage_state in ('hot', 'archived', 'restoring'));

-- 'r2'         the master is in R2 (everything before this migration)
-- 'telegram'   the master is only in Telegram (its R2 copy is in the bin, or
--              deleted after its week there)
-- 'restoring'  a runner is fetching it back from Telegram
alter table public.title_assets
  add column if not exists master_state    text not null default 'r2',
  add column if not exists master_moved_at timestamptz,
  -- An archived film's ladder rows, kept so a restore inside the bin's week
  -- puts the same streaming copies straight back instead of encoding again.
  -- `[]` for a film that never needed a ladder ("already light").
  add column if not exists archived_ladder jsonb;

alter table public.title_assets drop constraint if exists title_assets_master_state_ck;
alter table public.title_assets add constraint title_assets_master_state_ck
  check (master_state in ('r2', 'telegram', 'restoring'));

alter table public.admin_settings
  add column if not exists auto_offload       boolean not null default false,
  add column if not exists storage_alert_gb   numeric not null default 9,
  add column if not exists storage_noticed_at timestamptz,
  add column if not exists storage_notice     text;

-- A bin row that is the R2 copy of something whose other copy is in Telegram.
-- No foreign key: the bin outlives deleted titles, and a deleted title's files
-- are simply unused.
alter table public.r2_trash add column if not exists vault_asset uuid;

-- ---------------------------------------------------------------------------
-- the Telegram copies
-- ---------------------------------------------------------------------------
--
-- One row per film that has one: the chat and message the runner fetches, and
-- what the file was. `state` is what the runner found when it last looked.
create table if not exists public.vault_copies (
  asset_id    uuid primary key references public.title_assets(id) on delete cascade,
  chat_id     bigint not null,
  message_id  bigint not null,
  unique_id   text,
  bytes       bigint,
  source      text not null default 'forwarded to the bot',
  state       text not null default 'unverified'
              check (state in ('unverified', 'ok', 'missing', 'changed')),
  verified_at timestamptz,
  note        text,
  created_at  timestamptz not null default now()
);

-- Work for the runner that needs Telegram: look at a message, or fetch a film
-- back into R2. Same shape as ingest_jobs, and handed out by the same claim.
create table if not exists public.vault_jobs (
  id           uuid primary key default gen_random_uuid(),
  asset_id     uuid not null references public.title_assets(id) on delete cascade,
  kind         text not null check (kind in ('verify', 'restore')),
  state        text not null default 'queued'
               check (state in ('queued', 'running', 'done', 'failed')),
  attempts     integer not null default 0,
  not_before   timestamptz not null default now(),
  claimed_at   timestamptz,
  finished_at  timestamptz,
  note         text,
  requested_by uuid,
  created_at   timestamptz not null default now()
);
create unique index if not exists vault_jobs_open
  on public.vault_jobs (asset_id, kind) where state in ('queued', 'running');
create index if not exists vault_jobs_queue on public.vault_jobs (state, not_before);

do $$
declare t text;
begin
  foreach t in array array['vault_copies', 'vault_jobs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- small rules used everywhere below
-- ---------------------------------------------------------------------------

create or replace function public.storage_role(p_actor uuid)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select ad.role from public.admins ad where ad.user_id = p_actor and not ad.disabled;
$$;

-- LOOKED AT RECENTLY AND FOUND INTACT. The one condition under which the R2
-- copy of something may actually be deleted.
create or replace function public.vault_fresh(p_asset uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from public.vault_copies c
                  where c.asset_id = p_asset and c.state = 'ok'
                    and c.verified_at > now() - interval '3 days');
$$;

-- A finished ladder with at least one rung. "Ready" alone is not enough: a
-- film that was already light enough is ready with NO rungs, and its master
-- is the only thing the app can play.
create or replace function public.asset_has_ladder(p_asset uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from public.title_assets a
                  where a.id = p_asset and a.transcode_state = 'ready'
                    and exists (select 1 from public.asset_renditions r where r.asset_id = a.id));
$$;

-- Ask the runner to look at a film's Telegram copy. Idempotent.
create or replace function public.vault_request(p_asset uuid, p_kind text, p_actor uuid default null)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into public.vault_jobs (asset_id, kind, requested_by)
  select p_asset, p_kind, p_actor
   where exists (select 1 from public.vault_copies c where c.asset_id = p_asset)
  on conflict (asset_id, kind) where state in ('queued', 'running') do nothing;
$$;

-- Every forwarded film that is now a title's file gets its Telegram copy
-- recorded. Run by the housekeeping on every runner tick; cheap when there is
-- nothing new.
create or replace function public.vault_sync()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.vault_copies (asset_id, chat_id, message_id, unique_id, bytes)
  select a.id, j.tg_chat_id, j.tg_message_id, j.tg_unique_id, coalesce(j.bytes, a.bytes)
    from public.title_assets a
    join lateral (
      select x.* from public.ingest_jobs x
       where x.object_key = a.object_key and x.state = 'done'
         and x.tg_chat_id is not null and x.tg_message_id is not null
       order by x.finished_at desc nulls last limit 1) j on true
   where a.kind = 'video'
  on conflict (asset_id) do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- freeing a master
-- ---------------------------------------------------------------------------
--
-- p_actor null means the automatic policy (the edge function decides that);
-- otherwise it must be an owner. Answers one word.
create or replace function public.master_offload(p_asset uuid, p_actor uuid default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a record;
  t record;
  em text;
begin
  if p_actor is not null and public.storage_role(p_actor) is distinct from 'owner' then
    return 'not_owner';
  end if;
  select * into a from public.title_assets where id = p_asset for update;
  if not found then return 'no_such_asset'; end if;
  if a.kind <> 'video' then return 'not_a_video'; end if;
  if a.master_state <> 'r2' then return 'already_in_telegram'; end if;
  select * into t from public.titles where id = a.title_id;
  if t.pinned then return 'pinned'; end if;
  if t.storage_state <> 'hot' then return 'archived'; end if;
  if not public.asset_has_ladder(p_asset) then return 'no_streaming_copies'; end if;
  if not exists (select 1 from public.vault_copies c where c.asset_id = p_asset) then
    return 'no_telegram_copy';
  end if;
  if not public.vault_fresh(p_asset) then
    perform public.vault_request(p_asset, 'verify', p_actor);
    return 'not_verified';
  end if;

  select ad.email into em from public.admins ad where ad.user_id = p_actor;
  insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email,
                               purge_after, vault_asset)
  values (a.bucket, a.object_key, a.bytes,
          case when p_actor is null then 'master kept in Telegram (automatic)'
               else 'master kept in Telegram' end,
          p_actor, coalesce(em, 'storage policy'), now() + interval '7 days', a.id)
  on conflict (bucket, key) where purged_at is null and restored_at is null
  do update set vault_asset = excluded.vault_asset, reason = excluded.reason;

  update public.title_assets set master_state = 'telegram', master_moved_at = now()
   where id = p_asset;
  return 'offloaded';
end;
$$;

-- Put a freed master back in R2: out of the bin if it is still there,
-- otherwise fetched from Telegram by the runner.
create or replace function public.master_keep(p_asset uuid, p_actor uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare a record;
begin
  if coalesce(public.storage_role(p_actor), '') not in ('owner', 'editor') then return 'not_allowed'; end if;
  select * into a from public.title_assets where id = p_asset for update;
  if not found then return 'no_such_asset'; end if;
  if a.master_state = 'restoring' then return 'restoring'; end if;
  if a.master_state <> 'telegram' then return 'not_in_telegram'; end if;
  update public.r2_trash set restored_at = now(), restored_by = p_actor
   where bucket = a.bucket and key = a.object_key and purged_at is null and restored_at is null;
  if found then
    update public.title_assets set master_state = 'r2', master_moved_at = now() where id = p_asset;
    return 'kept';
  end if;
  if not exists (select 1 from public.vault_copies c where c.asset_id = p_asset) then
    return 'no_telegram_copy';
  end if;
  update public.title_assets set master_state = 'restoring', master_moved_at = now() where id = p_asset;
  perform public.vault_request(p_asset, 'restore', p_actor);
  return 'restoring';
end;
$$;

-- ---------------------------------------------------------------------------
-- archiving and restoring a title
-- ---------------------------------------------------------------------------

create or replace function public.title_archive(p_title uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  t record;
  a record;
  r record;
  em text;
  files integer := 0;
  films integer := 0;
  missing integer := 0;
  stale integer := 0;
begin
  if public.storage_role(p_actor) is distinct from 'owner' then
    return jsonb_build_object('error', 'not_owner');
  end if;
  select * into t from public.titles where id = p_title for update;
  if not found then return jsonb_build_object('error', 'no_such_title'); end if;
  if t.storage_state <> 'hot' then return jsonb_build_object('error', 'already_archived'); end if;
  if t.pinned then return jsonb_build_object('error', 'pinned'); end if;
  if not exists (select 1 from public.title_assets x where x.title_id = p_title and x.kind = 'video') then
    return jsonb_build_object('error', 'no_films');
  end if;
  if exists (select 1 from public.title_assets x where x.title_id = p_title and x.kind = 'video'
               and x.master_state = 'restoring') then
    return jsonb_build_object('error', 'restoring');
  end if;

  -- EVERY FILM MUST HAVE A TELEGRAM COPY LOOKED AT RECENTLY. One that does
  -- not would be gone for good once its week in the bin is over.
  for a in select x.id from public.title_assets x where x.title_id = p_title and x.kind = 'video' loop
    if not exists (select 1 from public.vault_copies c where c.asset_id = a.id) then
      missing := missing + 1;
    elsif not public.vault_fresh(a.id) then
      stale := stale + 1;
      perform public.vault_request(a.id, 'verify', p_actor);
    end if;
  end loop;
  if missing > 0 then
    return jsonb_build_object('error', 'no_telegram_copy', 'films', missing);
  end if;
  if stale > 0 then
    return jsonb_build_object('error', 'not_verified', 'films', stale);
  end if;

  select ad.email into em from public.admins ad where ad.user_id = p_actor;
  for a in select * from public.title_assets x where x.title_id = p_title and x.kind = 'video'
           for update loop
    films := films + 1;
    if a.master_state = 'r2' then
      insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email,
                                   purge_after, vault_asset)
      values (a.bucket, a.object_key, a.bytes, 'title archived', p_actor, em,
              now() + interval '7 days', a.id)
      on conflict (bucket, key) where purged_at is null and restored_at is null
      do update set vault_asset = excluded.vault_asset, reason = excluded.reason;
      files := files + 1;
    end if;
    for r in select * from public.asset_renditions x where x.asset_id = a.id loop
      insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email,
                                   purge_after, vault_asset)
      values ('innocent-media', r.object_key, r.bytes, 'title archived (streaming copy)',
              p_actor, em, now() + interval '7 days', a.id)
      on conflict (bucket, key) where purged_at is null and restored_at is null
      do update set vault_asset = excluded.vault_asset, reason = excluded.reason;
      files := files + 1;
    end loop;
    update public.title_assets
       set archived_ladder = coalesce((
             select jsonb_agg(jsonb_build_object('height', x.height, 'kbps', x.kbps,
                      'object_key', x.object_key, 'bytes', x.bytes, 'fps', x.fps) order by x.height)
               from public.asset_renditions x where x.asset_id = a.id), '[]'::jsonb),
           master_state = 'telegram', master_moved_at = now(),
           transcode_state = 'none', transcode_note = 'archived', transcode_at = now()
     where id = a.id;
    delete from public.asset_renditions where asset_id = a.id;
  end loop;

  update public.titles
     set archived_was_live = published,
         storage_state = 'archived', archived_at = now(),
         storage_note = null,
         status = case when published then 'hidden' else status end
   where id = p_title;
  return jsonb_build_object('archived', films, 'binned', files);
end;
$$;

-- Bring a title back. Instant for whatever is still in the bin; the rest is
-- fetched from Telegram and, if it had streaming copies, encoded again. The
-- title goes back into the app (if it was there) when every film is back AND
-- its streaming copies are, so restoring never puts a stuttering film live.
create or replace function public.title_restore(p_title uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  t record;
  a record;
  keys text[];
  pending integer;
  instant integer := 0;
  jobs integer := 0;
begin
  if coalesce(public.storage_role(p_actor), '') not in ('owner', 'editor') then
    return jsonb_build_object('error', 'not_allowed');
  end if;
  select * into t from public.titles where id = p_title for update;
  if not found then return jsonb_build_object('error', 'no_such_title'); end if;
  if t.storage_state = 'hot' then return jsonb_build_object('error', 'not_archived'); end if;

  for a in select * from public.title_assets x where x.title_id = p_title and x.kind = 'video'
           and x.master_state = 'telegram' for update loop
    -- The master.
    update public.r2_trash set restored_at = now(), restored_by = p_actor
     where bucket = a.bucket and key = a.object_key and purged_at is null and restored_at is null;
    if found then
      update public.title_assets set master_state = 'r2', master_moved_at = now() where id = a.id;
      instant := instant + 1;
    else
      update public.title_assets set master_state = 'restoring', master_moved_at = now() where id = a.id;
      perform public.vault_request(a.id, 'restore', p_actor);
      jobs := jobs + 1;
    end if;

    -- The streaming copies. Taken out of the bin whatever happens: if they
    -- are all still there they are the ladder again, and if some are gone
    -- the encoder writes the same names — which the bin must not then delete.
    select coalesce(array_agg(x ->> 'object_key'), '{}') into keys
      from jsonb_array_elements(coalesce(a.archived_ladder, '[]'::jsonb)) x;
    if array_length(keys, 1) > 0 then
      select count(*) into pending from public.r2_trash
       where bucket = 'innocent-media' and key = any(keys) and purged_at is null and restored_at is null;
      update public.r2_trash set restored_at = now(), restored_by = p_actor
       where bucket = 'innocent-media' and key = any(keys) and purged_at is null and restored_at is null;
      if pending = array_length(keys, 1) then
        insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes, fps)
        select a.id, (x ->> 'height')::int, (x ->> 'kbps')::int, x ->> 'object_key',
               nullif(x ->> 'bytes', '')::bigint, nullif(x ->> 'fps', '')::numeric
          from jsonb_array_elements(a.archived_ladder) x
        on conflict (asset_id, height) do nothing;
        update public.title_assets
           set transcode_state = 'ready', transcode_note = 'restored from the bin',
               transcode_at = now(), archived_ladder = null
         where id = a.id;
      end if;
    elsif a.archived_ladder is not null then
      -- Never needed a ladder: back to what it was.
      update public.title_assets
         set transcode_state = 'ready', transcode_note = 'already light (restored)',
             transcode_at = now(), archived_ladder = null
       where id = a.id;
    end if;
  end loop;

  update public.titles set storage_state = 'restoring', storage_note = null where id = p_title;
  perform public.vault_tick(p_title);
  return jsonb_build_object('instant', instant, 'fetching', jobs,
    'state', (select storage_state from public.titles where id = p_title));
end;
$$;

-- Move restoring titles on: queue the encoder for films that are back and
-- need their ladder, and put a title back where it was when it is whole.
create or replace function public.vault_tick(p_title uuid default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  t record;
  done integer := 0;
begin
  for t in select * from public.titles x
            where x.storage_state = 'restoring' and (p_title is null or x.id = p_title)
            for update loop
    if exists (select 1 from public.title_assets a where a.title_id = t.id and a.kind = 'video'
                 and a.master_state <> 'r2') then
      continue;
    end if;
    -- Back, and needs its streaming copies made again.
    update public.title_assets a
       set transcode_state = 'queued', transcode_note = 'rebuilding after restore', transcode_at = now()
     where a.title_id = t.id and a.kind = 'video' and a.master_state = 'r2'
       and jsonb_array_length(coalesce(a.archived_ladder, '[]'::jsonb)) > 0
       and a.transcode_state not in ('queued', 'running', 'ready', 'failed');
    -- Waiting for the encoder. `ready` with no rungs counts as finished: the
    -- encoder decided the film is light enough, and waiting for rungs that
    -- will never come would keep the title out of the app for ever.
    if exists (select 1 from public.title_assets a where a.title_id = t.id and a.kind = 'video'
                 and jsonb_array_length(coalesce(a.archived_ladder, '[]'::jsonb)) > 0
                 and a.transcode_state <> 'ready') then
      if exists (select 1 from public.title_assets a where a.title_id = t.id and a.kind = 'video'
                   and a.transcode_state = 'failed'
                   and jsonb_array_length(coalesce(a.archived_ladder, '[]'::jsonb)) > 0) then
        update public.titles set storage_note = 'streaming copies failed — Finish restore to put it back anyway'
         where id = t.id and storage_note is distinct from
               'streaming copies failed — Finish restore to put it back anyway';
      end if;
      continue;
    end if;
    perform public.vault_finish_title(t.id);
    done := done + 1;
  end loop;
  return done;
end;
$$;

-- The last step of a restore, and of a rescue: the title is whole in R2.
create or replace function public.vault_finish_title(p_title uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.title_assets set archived_ladder = null
   where title_id = p_title and kind = 'video' and master_state = 'r2';
  update public.titles
     set storage_state = 'hot',
         status = case when archived_was_live then 'published' else status end,
         archived_was_live = null, archived_at = null
   where id = p_title;
end;
$$;

-- An owner's "put it back now" when the encoder failed: the films are in R2,
-- so the title can go live on its masters.
create or replace function public.title_restore_finish(p_title uuid, p_actor uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if public.storage_role(p_actor) is distinct from 'owner' then return 'not_owner'; end if;
  if not exists (select 1 from public.titles where id = p_title and storage_state = 'restoring') then
    return 'not_restoring';
  end if;
  if exists (select 1 from public.title_assets a where a.title_id = p_title and a.kind = 'video'
               and a.master_state <> 'r2') then
    return 'films_not_back';
  end if;
  perform public.vault_finish_title(p_title);
  update public.titles set storage_note = 'put back before its streaming copies were ready'
   where id = p_title;
  return 'finished';
end;
$$;

-- THE TELEGRAM COPY IS GONE OR NOT THE SAME FILE: everything of that film
-- still in the bin comes out, and the film stays in R2.
create or replace function public.vault_rescue(p_asset uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a record;
  keys text[];
  pending integer;
  master_back boolean := false;
begin
  select * into a from public.title_assets where id = p_asset for update;
  if not found then return 'no_such_asset'; end if;
  update public.r2_trash set restored_at = now(),
         purge_error = 'kept: the Telegram copy is gone or different'
   where bucket = a.bucket and key = a.object_key and purged_at is null and restored_at is null;
  master_back := found;
  if master_back then
    update public.title_assets set master_state = 'r2', master_moved_at = now() where id = p_asset;
  end if;
  select coalesce(array_agg(x ->> 'object_key'), '{}') into keys
    from jsonb_array_elements(coalesce(a.archived_ladder, '[]'::jsonb)) x;
  if array_length(keys, 1) > 0 then
    select count(*) into pending from public.r2_trash
     where bucket = 'innocent-media' and key = any(keys) and purged_at is null and restored_at is null;
    update public.r2_trash set restored_at = now(),
           purge_error = 'kept: the Telegram copy is gone or different'
     where bucket = 'innocent-media' and key = any(keys) and purged_at is null and restored_at is null;
    if pending = array_length(keys, 1) then
      insert into public.asset_renditions (asset_id, height, kbps, object_key, bytes, fps)
      select a.id, (x ->> 'height')::int, (x ->> 'kbps')::int, x ->> 'object_key',
             nullif(x ->> 'bytes', '')::bigint, nullif(x ->> 'fps', '')::numeric
        from jsonb_array_elements(a.archived_ladder) x
      on conflict (asset_id, height) do nothing;
      update public.title_assets set transcode_state = 'ready', transcode_note = 'kept in R2',
             archived_ladder = null where id = p_asset;
    end if;
  end if;
  update public.titles
     set storage_note = 'Telegram copy of a film is gone or changed — kept in R2'
   where id = a.title_id;
  -- An archived title whose films are all back is whole again.
  if exists (select 1 from public.titles t where t.id = a.title_id and t.storage_state = 'archived')
     and not exists (select 1 from public.title_assets x where x.title_id = a.title_id
                       and x.kind = 'video' and x.master_state <> 'r2') then
    update public.titles set storage_state = 'restoring' where id = a.title_id;
    perform public.vault_tick(a.title_id);
  end if;
  return case when master_back then 'rescued' else 'nothing_in_bin' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- the runner's side
-- ---------------------------------------------------------------------------

create or replace function public.vault_claim()
returns table(job_id uuid, kind text, asset_id uuid, chat_id bigint, message_id bigint,
              unique_id text, bytes bigint, bucket text, object_key text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare j uuid;
begin
  select x.id into j from public.vault_jobs x
   where ((x.state = 'queued' and x.not_before <= now())
          or (x.state = 'running' and x.claimed_at < now() - interval '7 hours'))
     and exists (select 1 from public.vault_copies c where c.asset_id = x.asset_id)
   order by (x.kind = 'verify'), x.created_at
   for update skip locked
   limit 1;
  if j is null then return; end if;
  update public.vault_jobs
     set state = 'running', claimed_at = now(), attempts = attempts + 1, note = 'claimed'
   where id = j;
  return query
    select x.id, x.kind, x.asset_id, c.chat_id, c.message_id, c.unique_id,
           coalesce(c.bytes, a.bytes), a.bucket, a.object_key
      from public.vault_jobs x
      join public.vault_copies c on c.asset_id = x.asset_id
      join public.title_assets a on a.id = x.asset_id
     where x.id = j;
end;
$$;

-- What the runner found. `p_state` is its verdict on a verify ('ok',
-- 'missing', 'changed'); `p_ok` false means it could not tell (an error, not a
-- verdict), which spends one of three attempts.
create or replace function public.vault_finish(p_job uuid, p_ok boolean, p_state text,
                                               p_note text, p_bytes bigint)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record;
  want bigint;
  tid uuid;
begin
  select * into j from public.vault_jobs where id = p_job for update;
  if not found then return 'no_such_job'; end if;
  if j.state <> 'running' then return 'not_running'; end if;
  select a.title_id into tid from public.title_assets a where a.id = j.asset_id;

  if not coalesce(p_ok, false) then
    if j.attempts >= 3 then
      update public.vault_jobs set state = 'failed', finished_at = now(), note = left(p_note, 300)
       where id = p_job;
      if j.kind = 'restore' then
        update public.title_assets set master_state = 'telegram' where id = j.asset_id
           and master_state = 'restoring';
        update public.titles set storage_note = 'restore failed: ' || left(coalesce(p_note, ''), 200)
         where id = tid;
      end if;
      return 'failed';
    end if;
    update public.vault_jobs set state = 'queued', note = left(p_note, 300),
           not_before = now() + interval '10 minutes'
     where id = p_job;
    return 'retry';
  end if;

  if j.kind = 'verify' then
    if p_state not in ('ok', 'missing', 'changed') then return 'bad_state'; end if;
    update public.vault_copies set state = p_state, verified_at = now(), note = left(p_note, 300)
     where asset_id = j.asset_id;
    update public.vault_jobs set state = 'done', finished_at = now(), note = p_state
     where id = p_job;
    if p_state <> 'ok' then
      perform public.vault_rescue(j.asset_id);
    end if;
    return p_state;
  end if;

  -- restore: the bucket must now hold the film, whole.
  select coalesce(c.bytes, a.bytes) into want
    from public.title_assets a left join public.vault_copies c on c.asset_id = a.id
   where a.id = j.asset_id;
  if want is not null and p_bytes is distinct from want then
    update public.vault_jobs set state = 'failed', finished_at = now(),
           note = format('fetched %s bytes, expected %s', p_bytes, want)
     where id = p_job;
    update public.title_assets set master_state = 'telegram' where id = j.asset_id
       and master_state = 'restoring';
    update public.titles set storage_note = 'restore failed: the file from Telegram is not the same size'
     where id = tid;
    return 'size_mismatch';
  end if;
  update public.title_assets set master_state = 'r2', master_moved_at = now()
   where id = j.asset_id and master_state = 'restoring';
  update public.vault_copies set state = 'ok', verified_at = now() where asset_id = j.asset_id;
  update public.vault_jobs set state = 'done', finished_at = now(), note = 'restored'
   where id = p_job;
  perform public.vault_tick(tid);
  return 'restored';
end;
$$;

-- Telegram said wait: back in the queue without spending the attempt.
create or replace function public.vault_defer(p_job uuid, p_seconds integer)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.vault_jobs
     set state = 'queued', attempts = greatest(attempts - 1, 0),
         not_before = now() + make_interval(secs => greatest(coalesce(p_seconds, 0), 0)),
         note = format('waiting: Telegram asked for %ss', coalesce(p_seconds, 0))
   where id = p_job and state = 'running';
  return case when found then 'deferred' else 'not_running' end;
end;
$$;

-- ---------------------------------------------------------------------------
-- housekeeping, on every runner tick
-- ---------------------------------------------------------------------------

-- Which copies to look at. Each is a reason something is waiting on it.
create or replace function public.vault_schedule()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  n integer := 0;
  k integer;
  auto boolean;
begin
  -- (a) R2 copies in the bin that wait on a check: looked at within two days
  --     of their delete, so the three-day rule is met on the day.
  insert into public.vault_jobs (asset_id, kind)
  select distinct t.vault_asset, 'verify' from public.r2_trash t
    join public.vault_copies c on c.asset_id = t.vault_asset
   where t.purged_at is null and t.restored_at is null
     and t.purge_after < now() + interval '2 days'
     and (c.verified_at is null or c.verified_at < now() - interval '2 days')
  on conflict (asset_id, kind) where state in ('queued', 'running') do nothing;
  get diagnostics k = row_count; n := n + k;

  -- (b) every film that is only in Telegram, once a week.
  insert into public.vault_jobs (asset_id, kind)
  select a.id, 'verify' from public.title_assets a
    join public.vault_copies c on c.asset_id = a.id
   where a.master_state = 'telegram'
     and (c.verified_at is null or c.verified_at < now() - interval '7 days')
  on conflict (asset_id, kind) where state in ('queued', 'running') do nothing;
  get diagnostics k = row_count; n := n + k;

  -- (c) with automatic freeing on: the films it could free next.
  select s.auto_offload into auto from public.admin_settings s limit 1;
  if coalesce(auto, false) then
    insert into public.vault_jobs (asset_id, kind)
    select a.id, 'verify' from public.title_assets a
      join public.vault_copies c on c.asset_id = a.id
      join public.titles t on t.id = a.title_id
     where a.kind = 'video' and a.master_state = 'r2' and not t.pinned and t.storage_state = 'hot'
       and public.asset_has_ladder(a.id)
       and (c.verified_at is null or c.verified_at < now() - interval '3 days')
       and c.state in ('unverified', 'ok')
    on conflict (asset_id, kind) where state in ('queued', 'running') do nothing;
    get diagnostics k = row_count; n := n + k;
  end if;
  return n;
end;
$$;

-- Automatic freeing, when the owner has turned it on: masters whose ladder
-- has been finished for a day and whose Telegram copy was just looked at.
create or replace function public.vault_auto_offload(p_limit integer default 20)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a record;
  n integer := 0;
begin
  if not coalesce((select s.auto_offload from public.admin_settings s limit 1), false) then
    return 0;
  end if;
  for a in select x.id from public.title_assets x join public.titles t on t.id = x.title_id
            where x.kind = 'video' and x.master_state = 'r2' and not t.pinned
              and t.storage_state = 'hot' and x.transcode_at < now() - interval '1 day'
              and public.asset_has_ladder(x.id) and public.vault_fresh(x.id)
            limit greatest(p_limit, 0) loop
    if public.master_offload(a.id, null) = 'offloaded' then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

-- What R2 holds, by the catalogue's own numbers (the Files page has the
-- bucket's). Photos and covers count; a master only in Telegram does not.
create or replace function public.storage_bytes()
returns bigint
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select sum(coalesce(a.bytes, 0)) from public.title_assets a
                    where a.kind <> 'video' or a.master_state <> 'telegram'), 0)
       + coalesce((select sum(coalesce(r.bytes, 0)) from public.asset_renditions r), 0);
$$;

-- The owner's message, at most once a day and only when something is worth
-- saying: R2 is near the threshold, or a Telegram copy that a film depends on
-- is gone. Null when there is nothing to say.
create or replace function public.storage_notice()
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  s record;
  gb numeric;
  lost integer;
  failed integer;
  msg text := '';
begin
  select * into s from public.admin_settings limit 1;
  gb := round(public.storage_bytes() / 1e9, 2);
  select count(*) into lost from public.vault_copies c
    join public.title_assets a on a.id = c.asset_id
   where c.state in ('missing', 'changed') and a.master_state = 'telegram';
  select count(*) into failed from public.vault_jobs j
   where j.state = 'failed' and j.finished_at > now() - interval '1 day';
  if gb >= coalesce(s.storage_alert_gb, 9) then
    msg := msg || format('R2 holds %s GB (free up to 10 GB; your alert is %s GB). ',
                         gb, coalesce(s.storage_alert_gb, 9));
  end if;
  if lost > 0 then
    msg := msg || format('%s film(s) exist only in Telegram and their Telegram copy is GONE. ', lost);
  end if;
  if failed > 0 then
    msg := msg || format('%s Telegram check(s) or restore(s) failed today. ', failed);
  end if;
  if msg = '' then return null; end if;
  msg := 'Storage: ' || msg || 'Open Storage in the console.';
  if s.storage_noticed_at is not null and s.storage_noticed_at > now() - interval '1 day'
     and s.storage_notice is not distinct from msg then
    return null;
  end if;
  update public.admin_settings set storage_noticed_at = now(), storage_notice = msg where id;
  return msg;
end;
$$;

-- ---------------------------------------------------------------------------
-- what the Storage page reads
-- ---------------------------------------------------------------------------
create or replace function public.storage_overview()
returns table(title_id uuid, title text, slug text, published boolean, storage_state text,
              pinned boolean, archived_at timestamptz, storage_note text,
              last_viewed date, views_30d integer,
              films integer, films_with_copy integer, copies_ok integer, copies_bad integer,
              masters_r2 integer, masters_telegram integer, masters_restoring integer,
              master_bytes_r2 bigint, master_bytes_telegram bigint, ladder_bytes bigint,
              other_bytes bigint, freeable integer, jobs_open integer, assets jsonb)
language sql
stable
security definer
set search_path to 'public'
as $$
  select t.id, t.title, t.slug, t.published, t.storage_state, t.pinned, t.archived_at, t.storage_note,
         (select max(v.viewed_on) from public.title_views v where v.title_id = t.id),
         (select count(*)::int from public.title_views v
           where v.title_id = t.id and v.viewed_on > current_date - 30),
         count(*) filter (where a.kind = 'video')::int,
         count(c.asset_id)::int,
         count(*) filter (where c.state = 'ok' and c.verified_at > now() - interval '3 days')::int,
         count(*) filter (where c.state in ('missing', 'changed'))::int,
         count(*) filter (where a.kind = 'video' and a.master_state = 'r2')::int,
         count(*) filter (where a.kind = 'video' and a.master_state = 'telegram')::int,
         count(*) filter (where a.kind = 'video' and a.master_state = 'restoring')::int,
         coalesce(sum(a.bytes) filter (where a.kind = 'video' and a.master_state <> 'telegram'), 0)::bigint,
         coalesce(sum(a.bytes) filter (where a.kind = 'video' and a.master_state = 'telegram'), 0)::bigint,
         coalesce(sum((select sum(coalesce(r.bytes, 0)) from public.asset_renditions r where r.asset_id = a.id)), 0)::bigint,
         coalesce(sum(a.bytes) filter (where a.kind <> 'video'), 0)::bigint,
         count(*) filter (where a.kind = 'video' and a.master_state = 'r2' and c.asset_id is not null
                            and public.asset_has_ladder(a.id))::int,
         (select count(*)::int from public.vault_jobs j join public.title_assets y on y.id = j.asset_id
           where y.title_id = t.id and j.state in ('queued', 'running')),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'key', a.object_key, 'bytes', a.bytes, 'master', a.master_state,
           'ladder', public.asset_has_ladder(a.id), 'transcode', a.transcode_state,
           'copy', c.state, 'verified_at', c.verified_at, 'copy_note', c.note)
           order by a.sort_order) filter (where a.kind = 'video'), '[]'::jsonb)
    from public.titles t
    left join public.title_assets a on a.title_id = t.id
    left join public.vault_copies c on c.asset_id = a.id
   group by t.id
   order by coalesce(sum(a.bytes), 0) desc;
$$;

-- ---------------------------------------------------------------------------
-- the parts of 018, 027 and 028 that have to know about this
-- ---------------------------------------------------------------------------

-- A master only in Telegram is not a key the catalogue points at, so the
-- Files page shows its R2 copy as what it is — in the bin — and the bin does
-- not take it back out as "in use again".
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select a.object_key, a.title_id, 'file'::text from public.title_assets a
   where a.object_key is not null and a.master_state <> 'telegram'
  union all
  select a.thumb_key, a.title_id, 'thumbnail' from public.title_assets a
   where a.thumb_key is not null
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
   where j.title_id is null;
$$;

-- The bin, with the Telegram rule: a file whose other copy is in Telegram is
-- deleted only when that copy was looked at in the last three days and was
-- intact; if it was gone, everything of that film comes back out instead.
create or replace function public.r2_trash_due(p_limit integer default 200)
returns table(id bigint, bucket text, key text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare v uuid;
begin
  for v in select distinct t.vault_asset from public.r2_trash t
             join public.vault_copies c on c.asset_id = t.vault_asset
            where t.purged_at is null and t.restored_at is null
              and c.state in ('missing', 'changed') loop
    perform public.vault_rescue(v);
  end loop;

  update public.r2_trash t
     set restored_at = now(), purge_error = 'in use again — kept'
   where t.purged_at is null and t.restored_at is null and t.purge_after <= now()
     and exists (select 1 from public.r2_refs() r where r.key = t.key);
  return query
    select t.id, t.bucket, t.key from public.r2_trash t
     where t.purged_at is null and t.restored_at is null and t.purge_after <= now()
       and (t.vault_asset is null
            or not exists (select 1 from public.title_assets a where a.id = t.vault_asset)
            or public.vault_fresh(t.vault_asset))
     order by t.purge_after
     limit greatest(p_limit, 0);
end;
$$;

-- Restoring a freed master from the Files page puts it back in R2's books too.
create or replace function public.r2_trash_restore(p_id bigint, p_actor uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r text;
  b record;
begin
  select ad.role into r from public.admins ad where ad.user_id = p_actor and not ad.disabled;
  if r is distinct from 'owner' then return 'not_owner'; end if;
  update public.r2_trash set restored_at = now(), restored_by = p_actor
   where id = p_id and purged_at is null and restored_at is null
   returning * into b;
  if not found then return 'not_in_bin'; end if;
  if b.vault_asset is not null then
    update public.title_assets set master_state = 'r2', master_moved_at = now()
     where id = b.vault_asset and object_key = b.key and master_state = 'telegram';
  end if;
  return 'restored';
end;
$$;

-- The encoder never claims a film whose master is not in R2 — it would be
-- handed a URL to nothing.
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
      where x.kind <> 'photo'
        and x.master_state = 'r2'
        and (
          x.transcode_state = 'queued'
          or (x.transcode_state = 'running'
              and x.transcode_at < now() - interval '7 hours')
        )
      order by (x.transcode_state = 'running'), x.added_at asc
      for update skip locked
      limit 1
   )
  returning a.id, a.object_key, a.bucket, a.height, a.duration_s, a.bytes;
$$;

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
   where id = p_asset and kind <> 'photo' and master_state = 'r2'
  returning transcode_state;
$$;

-- An archived title is taken out of the app without being sent back to
-- editing — it is still approved, it is only not in R2 — and cannot be put
-- back in the app until its films are.
create or replace function public.title_review_follows_published()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if tg_op = 'INSERT' then
    if new.published then
      new.review_state := 'approved';
    end if;
    return new;
  end if;

  if new.published and not coalesce(old.published, false) then
    if coalesce(new.storage_state, 'hot') <> 'hot' then
      raise exception 'this title is archived — restore it before it can be in the app'
        using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.title_assets a where a.title_id = new.id) then
      raise exception 'a title with no files cannot be published'
        using errcode = 'check_violation';
    end if;
    if new.review_state is not distinct from old.review_state then
      new.review_state := 'approved';
    end if;
  elsif not new.published and coalesce(old.published, false) then
    if new.review_state is not distinct from old.review_state
       and coalesce(new.storage_state, 'hot') = 'hot' then
      new.review_state := 'editing';
    end if;
  end if;
  return new;
end;
$$;

-- The review queue lists every title not in the app. An archived one is not
-- waiting for anybody's decision — it is approved and parked — and offering
-- Approve on it would only meet the trigger above. It is on the Storage page.
create or replace function public.review_queue()
returns table(id uuid, title text, title_mm text, poster_url text, category text, folder text,
              review_state text, review_note text, created_at timestamptz, created_by uuid,
              creator_email text, submitted_at timestamptz, decided_at timestamptz,
              decider_email text, photos integer, videos integer)
language sql
security definer
set search_path to 'public'
as $$
  select t.id, t.title, t.title_mm, t.poster_url, t.category, t.slug,
         t.review_state, t.review_note, t.created_at, t.created_by,
         c.email, t.submitted_at, t.decided_at, d.email,
         (select count(*) from public.title_assets x
           where x.title_id = t.id and x.kind = 'photo')::integer,
         (select count(*) from public.title_assets x
           where x.title_id = t.id and x.kind <> 'photo')::integer
    from public.titles t
    left join public.admins c on c.user_id = t.created_by
    left join public.admins d on d.user_id = t.decided_by
   where not t.published and t.storage_state = 'hot'
   order by case t.review_state
              when 'ready' then 0 when 'changes' then 1
              when 'editing' then 2 else 3 end,
            coalesce(t.submitted_at, t.created_at) desc
   limit 300;
$$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'storage_role(uuid)', 'vault_fresh(uuid)', 'asset_has_ladder(uuid)',
    'vault_request(uuid, text, uuid)', 'vault_sync()',
    'master_offload(uuid, uuid)', 'master_keep(uuid, uuid)',
    'title_archive(uuid, uuid)', 'title_restore(uuid, uuid)', 'vault_tick(uuid)',
    'vault_finish_title(uuid)', 'title_restore_finish(uuid, uuid)', 'vault_rescue(uuid)',
    'vault_claim()', 'vault_finish(uuid, boolean, text, text, bigint)', 'vault_defer(uuid, integer)',
    'vault_schedule()', 'vault_auto_offload(integer)', 'storage_bytes()', 'storage_notice()',
    'storage_overview()', 'r2_refs()', 'r2_trash_due(integer)', 'r2_trash_restore(bigint, uuid)',
    'claim_transcode()', 'queue_transcode(uuid)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
