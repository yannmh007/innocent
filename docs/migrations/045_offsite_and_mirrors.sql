-- 045 — a copy of everything outside Cloudflare and Telegram, and the update
-- APK in more than one place.
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. Nothing here drops anything.
--
-- ═══════════════════════════════════════════════════════════════════════
-- WHY
-- ═══════════════════════════════════════════════════════════════════════
--
-- Every film is in R2 and, through the archive channel (032), in Telegram.
-- Two companies — but the storage policy (029) can take a master OUT of R2,
-- and then Telegram is the only copy. The database backups (032) are in R2
-- only, in the same account that serves every viewer. And the update APK is
-- downloaded from R2 alone: an account suspended over a report — a real one
-- or a false one — would stop playback, lose the backups and stop updates in
-- one stroke, and the update is the only way to ship the app anything else.
--
-- So a THIRD place, at a third company, private, that nobody outside can
-- see or report: an S3-compatible bucket (Backblaze B2 is the one set up in
-- docs/RUNBOOK.md; any S3-compatible store works). The ingest function holds
-- its key, as it holds R2's — Supabase secrets OFFSITE_*. Nothing in this
-- repository, the runner or the app ever does.
--
--   * every title file (masters, photos) is copied there by the runner, the
--     same way it copies films into the archive channel: one presigned GET
--     from R2 — or the film from Telegram when R2 no longer has it — and one
--     presigned PUT to the off-site bucket. The ingest function then asks the
--     bucket itself what arrived (HEAD) and only that size is recorded;
--   * every database backup is written there too, as it is made;
--   * every copy is looked at again each week; one found missing is copied
--     again;
--   * a copy whose file was deleted from the catalogue is deleted a week
--     later (the bin's week), so deleting really deletes;
--   * automatic freeing of masters (029) waits for the off-site copy.
--
-- And `app_releases.apk_mirrors`: where else the same APK is — a public
-- bucket at the same off-site company, then the GitHub release. The app
-- asks them in order only when the CDN does not deliver, and checks every
-- one against the same SHA-256.
--
-- UNTIL THE SECRETS ARE SET NOTHING HAPPENS. `offsite_where` stays null, no
-- job is queued, the Status page says "not set up" and how.

-- ---------------------------------------------------------------------------
-- 1. the APK's mirrors
-- ---------------------------------------------------------------------------

create or replace function public.all_https(p text[])
returns boolean
language sql
immutable
set search_path to 'public'
as $$
  select coalesce(bool_and(u like 'https://%'), true) from unnest(p) u;
$$;

alter table public.app_releases
  add column if not exists apk_mirrors       text[] not null default '{}',
  add column if not exists apk_mirrors_arm32 text[] not null default '{}';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conname = 'app_releases_mirrors_ck'
                    and conrelid = 'public.app_releases'::regclass) then
    alter table public.app_releases add constraint app_releases_mirrors_ck
      check (cardinality(apk_mirrors) <= 4 and cardinality(apk_mirrors_arm32) <= 4
             and public.all_https(apk_mirrors) and public.all_https(apk_mirrors_arm32));
  end if;
end $$;

comment on column public.app_releases.apk_mirrors is
  'The same arm64 APK elsewhere, best first (off-site bucket, GitHub release). Asked only when apk_url does not deliver; checked against apk_sha256.';
comment on column public.app_releases.apk_mirrors_arm32 is
  'The same 32-bit APK elsewhere, best first. Checked against apk_sha256_arm32.';

-- ---------------------------------------------------------------------------
-- 2. where the off-site copy is, as the ingest function last said
-- ---------------------------------------------------------------------------

alter table public.admin_settings
  add column if not exists offsite_where   text,   -- host/bucket, never a key
  add column if not exists offsite_public  text,   -- public base for the APK mirror
  add column if not exists offsite_seen_at timestamptz;

alter table public.db_backups
  add column if not exists offsite_key text,
  add column if not exists offsite_at  timestamptz;

-- ---------------------------------------------------------------------------
-- 3. the copies, and the work
-- ---------------------------------------------------------------------------
--
-- NO FOREIGN KEY on the copies, deliberately: a copy outlives the file it is
-- a copy of by the bin's week, and finding "a copy of nothing" is how it is
-- found to be due for deletion.
create table if not exists public.offsite_copies (
  asset_id    uuid primary key,
  object_key  text not null,
  bytes       bigint,
  sha256      text,
  state       text not null default 'ok' check (state in ('ok', 'missing', 'deleted')),
  copied_at   timestamptz not null default now(),
  verified_at timestamptz,
  orphaned_at timestamptz,
  deleted_at  timestamptz,
  note        text
);

create table if not exists public.offsite_jobs (
  id          uuid primary key default gen_random_uuid(),
  asset_id    uuid not null references public.title_assets(id) on delete cascade,
  state       text not null default 'queued'
              check (state in ('queued', 'running', 'done', 'failed')),
  attempts    integer not null default 0,
  not_before  timestamptz not null default now(),
  claimed_at  timestamptz,
  finished_at timestamptz,
  note        text,
  created_at  timestamptz not null default now()
);
create unique index if not exists offsite_jobs_open
  on public.offsite_jobs (asset_id) where state in ('queued', 'running');
create index if not exists offsite_jobs_queue on public.offsite_jobs (state, not_before);

do $$
declare t text;
begin
  foreach t in array array['offsite_copies', 'offsite_jobs'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 4. small rules
-- ---------------------------------------------------------------------------

-- The function said in the last two days that it has an off-site bucket. A
-- secret removed stops the queue within two days without anything stuck.
create or replace function public.offsite_on()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce((select s.offsite_where is not null and s.offsite_seen_at > now() - interval '2 days'
                     from public.admin_settings s limit 1), false);
$$;

-- An off-site copy that was found in place in the last eight days.
create or replace function public.offsite_fresh(p_asset uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (select 1 from public.offsite_copies c
                  where c.asset_id = p_asset and c.state = 'ok' and c.deleted_at is null
                    and coalesce(c.verified_at, c.copied_at) > now() - interval '8 days');
$$;

-- S3's limit for one PUT. Larger files stay without an off-site copy, and
-- the Status page counts them.
create or replace function public.offsite_max_bytes()
returns bigint
language sql
immutable
as $$ select 5368709120::bigint; $$;

-- ---------------------------------------------------------------------------
-- 5. what the ingest function calls
-- ---------------------------------------------------------------------------

-- On every runner tick: where the bucket is (host/bucket and the public
-- base, never a key), or nulls when the secrets are not set.
create or replace function public.offsite_config(p_where text, p_public text)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.admin_settings
     set offsite_where   = nullif(left(coalesce(p_where, ''), 200), ''),
         offsite_public  = nullif(left(coalesce(p_public, ''), 300), ''),
         offsite_seen_at = now()
   where true;
$$;

-- Queue copies of title files that have none, five open at a time. A file
-- whose copy failed today waits for tomorrow; one too big for a PUT is not
-- queued at all.
create or replace function public.offsite_schedule()
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  open_jobs integer;
  n integer;
begin
  if not public.offsite_on() then return 0; end if;
  select count(*) into open_jobs from public.offsite_jobs where state in ('queued', 'running');
  if open_jobs >= 5 then return 0; end if;
  insert into public.offsite_jobs (asset_id)
  select a.id from public.title_assets a
   where coalesce(a.bytes, 0) between 1 and public.offsite_max_bytes()
     and coalesce(a.object_key, '') <> ''
     and (a.master_state = 'r2'
          or (a.master_state = 'telegram'
              and exists (select 1 from public.vault_copies v where v.asset_id = a.id)))
     and not exists (select 1 from public.offsite_copies c
                      where c.asset_id = a.id and c.state = 'ok' and c.deleted_at is null)
     and not exists (select 1 from public.offsite_jobs j
                      where j.asset_id = a.id
                        and (j.state in ('queued', 'running')
                             or (j.state = 'failed' and j.finished_at > now() - interval '1 day')))
   order by (a.kind <> 'video'), a.added_at
   limit 5 - open_jobs
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- One copy job for the runner. Scheduled here as well, so a run that empties
-- the queue fills it again instead of waiting for the next tick.
create or replace function public.offsite_claim()
returns table(job_id uuid, asset_id uuid, kind text, bucket text, object_key text,
              bytes bigint, master_state text, chat_id bigint, message_id bigint,
              unique_id text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare j uuid;
begin
  if not public.offsite_on() then return; end if;
  if not exists (select 1 from public.offsite_jobs x
                  where x.state = 'queued' and x.not_before <= now()) then
    perform public.offsite_schedule();
  end if;
  -- Oldest first; within one tick's batch (one created_at), films first.
  select x.id into j from public.offsite_jobs x
    join public.title_assets a on a.id = x.asset_id
   where (x.state = 'queued' and x.not_before <= now())
      or (x.state = 'running' and x.claimed_at < now() - interval '7 hours')
   order by x.created_at, (a.kind <> 'video'), a.added_at
   for update of x skip locked
   limit 1;
  if j is null then return; end if;
  update public.offsite_jobs
     set state = 'running', claimed_at = now(), attempts = attempts + 1, note = 'claimed'
   where id = j;
  return query
    select x.id, a.id, a.kind, a.bucket, a.object_key, coalesce(a.bytes, v.bytes),
           a.master_state, v.chat_id, v.message_id, v.unique_id
      from public.offsite_jobs x
      join public.title_assets a on a.id = x.asset_id
      left join public.vault_copies v on v.asset_id = a.id
     where x.id = j;
end;
$$;

-- The runner's answer, with the size THE BUCKET reported (the ingest
-- function asks it, not the runner). A copy is recorded only at the file's
-- own size.
create or replace function public.offsite_finish(
  p_job uuid, p_ok boolean, p_note text, p_key text, p_bytes bigint, p_sha text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record;
  want bigint;
begin
  select * into j from public.offsite_jobs where id = p_job for update;
  if not found then return 'no_such_job'; end if;
  if j.state <> 'running' then return 'not_running'; end if;

  if not coalesce(p_ok, false) or coalesce(p_key, '') = '' then
    if j.attempts >= 3 then
      update public.offsite_jobs set state = 'failed', finished_at = now(),
             note = left(coalesce(p_note, 'failed'), 300)
       where id = p_job;
      return 'failed';
    end if;
    update public.offsite_jobs set state = 'queued', note = left(coalesce(p_note, 'retry'), 300),
           not_before = now() + interval '10 minutes'
     where id = p_job;
    return 'retry';
  end if;

  select coalesce(a.bytes, v.bytes) into want
    from public.title_assets a left join public.vault_copies v on v.asset_id = a.id
   where a.id = j.asset_id;
  if want is not null and p_bytes is distinct from want then
    update public.offsite_jobs set state = 'failed', finished_at = now(),
           note = format('the bucket has %s bytes, the file is %s', p_bytes, want)
     where id = p_job;
    return 'size_mismatch';
  end if;

  insert into public.offsite_copies as c
         (asset_id, object_key, bytes, sha256, state, copied_at, verified_at,
          orphaned_at, deleted_at, note)
  values (j.asset_id, left(p_key, 300), p_bytes,
          case when p_sha ~ '^[0-9a-f]{64}$' then p_sha end,
          'ok', now(), now(), null, null, null)
  on conflict (asset_id) do update
     set object_key = excluded.object_key, bytes = excluded.bytes,
         sha256 = coalesce(excluded.sha256, c.sha256), state = 'ok',
         copied_at = now(), verified_at = now(), orphaned_at = null,
         deleted_at = null, note = null;
  update public.offsite_jobs set state = 'done', finished_at = now(), note = 'copied'
   where id = p_job;
  return 'copied';
end;
$$;

-- Telegram asked the runner to wait (a FLOOD_WAIT while reading a film from
-- its Telegram copy). That is Telegram's scheduling, not a verdict on the
-- file, so the attempt the claim took is given back.
create or replace function public.offsite_defer(p_job uuid, p_seconds integer)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.offsite_jobs
     set state = 'queued', attempts = greatest(attempts - 1, 0),
         not_before = now() + make_interval(secs => least(greatest(coalesce(p_seconds, 0), 0), 86400)),
         note = 'Telegram asked for a wait'
   where id = p_job and state = 'running';
  return case when found then 'deferred' else 'not_running' end;
end;
$$;

-- A COPY WHOSE FILE WAS DELETED WHILE IT WAS BEING MADE. The job went with
-- the file (on delete cascade), so the runner's answer finds no job; the
-- copy it uploaded is recorded here as already an orphan, and goes a week
-- later like any other — deleting still deletes. Only for a file that really
-- is gone.
create or replace function public.offsite_orphan(p_asset uuid, p_key text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if exists (select 1 from public.title_assets a where a.id = p_asset) then
    return 'not_an_orphan';
  end if;
  if coalesce(p_key, '') !~ '^masters/[0-9a-f-]{36}(\.[a-z0-9]{1,5})?$' then
    return 'bad_key';
  end if;
  insert into public.offsite_copies (asset_id, object_key, state, orphaned_at, note)
  values (p_asset, p_key, 'ok', now(), 'its file was deleted while it was being copied')
  on conflict (asset_id) do update
     set orphaned_at = coalesce(public.offsite_copies.orphaned_at, now());
  return 'orphaned';
end;
$$;

-- Copies to look at again: weekly, oldest look first.
create or replace function public.offsite_verify_due(p_limit integer default 20)
returns table(asset_id uuid, object_key text, bytes bigint)
language sql
stable
security definer
set search_path to 'public'
as $$
  select c.asset_id, c.object_key, c.bytes from public.offsite_copies c
   where c.state = 'ok' and c.deleted_at is null
     and exists (select 1 from public.title_assets a where a.id = c.asset_id)
     and coalesce(c.verified_at, c.copied_at) < now() - interval '7 days'
   order by coalesce(c.verified_at, c.copied_at)
   limit greatest(p_limit, 0);
$$;

-- What the bucket answered. A copy not there, or not at its size, is marked
-- missing — and offsite_schedule copies it again on the next tick.
create or replace function public.offsite_verified(p_asset uuid, p_found boolean, p_bytes bigint)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare c record;
begin
  select * into c from public.offsite_copies where asset_id = p_asset for update;
  if not found then return 'no_copy'; end if;
  if coalesce(p_found, false) and (c.bytes is null or p_bytes = c.bytes) then
    update public.offsite_copies set verified_at = now(), note = null where asset_id = p_asset;
    return 'ok';
  end if;
  update public.offsite_copies
     set state = 'missing', verified_at = now(),
         note = case when coalesce(p_found, false)
                     then format('the bucket has %s bytes, the copy was %s', p_bytes, c.bytes)
                     else 'not in the bucket' end
   where asset_id = p_asset;
  return 'missing';
end;
$$;

-- COPIES OF NOTHING. A copy whose file has left the catalogue is noticed
-- now and deleted a week later — the same week the bin gives R2's copy —
-- so a mistaken delete can still be undone from here, and a real one does
-- delete.
create or replace function public.offsite_prune_due(p_limit integer default 50)
returns table(asset_id uuid, object_key text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.offsite_copies c set orphaned_at = now()
   where c.orphaned_at is null and c.deleted_at is null
     and not exists (select 1 from public.title_assets a where a.id = c.asset_id);
  update public.offsite_copies c set orphaned_at = null
   where c.orphaned_at is not null and c.deleted_at is null
     and exists (select 1 from public.title_assets a where a.id = c.asset_id);
  return query
    select c.asset_id, c.object_key from public.offsite_copies c
     where c.deleted_at is null and c.orphaned_at < now() - interval '7 days'
     order by c.orphaned_at
     limit greatest(p_limit, 0);
end;
$$;

create or replace function public.offsite_pruned(p_asset uuid)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.offsite_copies set deleted_at = now(), state = 'deleted'
   where asset_id = p_asset and deleted_at is null;
$$;

-- Live backups with no off-site copy yet, newest first.
create or replace function public.backup_offsite_due(p_limit integer default 5)
returns table(id bigint, object_key text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.id, b.object_key from public.db_backups b
   where b.deleted_at is null and b.offsite_at is null
   order by b.taken_at desc
   limit greatest(p_limit, 0);
$$;

create or replace function public.backup_offsite_done(p_id bigint, p_key text)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.db_backups set offsite_key = left(p_key, 300), offsite_at = now()
   where id = p_id;
$$;

-- The off-site key of a backup the prune is about to delete.
create or replace function public.backup_offsite_key(p_id bigint)
returns text
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.offsite_key from public.db_backups b where b.id = p_id;
$$;

-- The Status page's numbers.
create or replace function public.offsite_status()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'on', public.offsite_on(),
    'where', (select s.offsite_where from public.admin_settings s limit 1),
    'mirror', (select s.offsite_public is not null from public.admin_settings s limit 1),
    'seen_at', (select s.offsite_seen_at from public.admin_settings s limit 1),
    'files', (select count(*) from public.title_assets a where coalesce(a.bytes, 0) > 0),
    'too_big', (select count(*) from public.title_assets a
                 where a.bytes > public.offsite_max_bytes()),
    'copied', (select count(*) from public.offsite_copies c
                where c.state = 'ok' and c.deleted_at is null
                  and exists (select 1 from public.title_assets a where a.id = c.asset_id)),
    'bytes', (select coalesce(sum(c.bytes), 0) from public.offsite_copies c
               where c.state = 'ok' and c.deleted_at is null),
    'missing', (select count(*) from public.offsite_copies c
                 where c.state = 'missing' and c.deleted_at is null),
    'last_copied_at', (select max(c.copied_at) from public.offsite_copies c),
    'oldest_check_at', (select min(coalesce(c.verified_at, c.copied_at)) from public.offsite_copies c
                         where c.state = 'ok' and c.deleted_at is null),
    'deleting', (select count(*) from public.offsite_copies c
                  where c.orphaned_at is not null and c.deleted_at is null),
    'jobs', jsonb_build_object(
      'queued', (select count(*) from public.offsite_jobs j where j.state = 'queued'),
      'running', (select count(*) from public.offsite_jobs j where j.state = 'running'),
      'failed_7d', (select count(*) from public.offsite_jobs j
                     where j.state = 'failed' and j.finished_at > now() - interval '7 days'),
      'last_note', (select j.note from public.offsite_jobs j
                     where j.finished_at is not null order by j.finished_at desc limit 1)),
    'backups', jsonb_build_object(
      'live', (select count(*) from public.db_backups b where b.deleted_at is null),
      'copied', (select count(*) from public.db_backups b
                  where b.deleted_at is null and b.offsite_at is not null)));
$$;

-- ---------------------------------------------------------------------------
-- 6. automatic freeing waits for the off-site copy
-- ---------------------------------------------------------------------------
--
-- 029's freeing took a master out of R2 once Telegram's copy had been looked
-- at in the last three days — leaving Telegram the only copy. With an
-- off-site bucket set up, it also waits for that copy to be in place, so a
-- freed master always has two copies at two companies. Without one it is
-- what it was. The console's manual Free and Archive are NOT held back: they
-- are what an owner reaches for when a film must leave the app now.
create or replace function public.vault_auto_offload(p_limit integer default 20)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a record;
  n integer := 0;
  off boolean := public.offsite_on();
begin
  if not coalesce((select s.auto_offload from public.admin_settings s limit 1), false) then
    return 0;
  end if;
  for a in select x.id from public.title_assets x join public.titles t on t.id = x.title_id
            where x.kind = 'video' and x.master_state = 'r2' and not t.pinned
              and t.storage_state = 'hot' and x.transcode_at < now() - interval '1 day'
              and public.asset_has_ladder(x.id) and public.vault_fresh(x.id)
              and (not off or public.offsite_fresh(x.id))
            limit greatest(p_limit, 0) loop
    if public.master_offload(a.id, null) = 'offloaded' then n := n + 1; end if;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- who may call what: the service role, nobody else
-- ---------------------------------------------------------------------------

do $$
declare f text;
begin
  foreach f in array array[
    'offsite_on()', 'offsite_fresh(uuid)', 'offsite_config(text,text)',
    'offsite_schedule()', 'offsite_claim()',
    'offsite_finish(uuid,boolean,text,text,bigint,text)', 'offsite_defer(uuid,integer)',
    'offsite_orphan(uuid,text)',
    'offsite_verify_due(integer)', 'offsite_verified(uuid,boolean,bigint)',
    'offsite_prune_due(integer)', 'offsite_pruned(uuid)',
    'backup_offsite_due(integer)', 'backup_offsite_done(bigint,text)',
    'backup_offsite_key(bigint)', 'offsite_status()',
    'vault_auto_offload(integer)'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

insert into public.schema_migrations (version, note)
values ('045', 'off-site copy of every file and backup; APK mirrors')
on conflict (version) do nothing;
