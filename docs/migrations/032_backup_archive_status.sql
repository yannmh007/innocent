-- 032 — a backup every day, an archive channel, and one page that says how
-- the machine is doing.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 1. THE DATABASE IS BACKED UP EVERY DAY, INTO R2
-- ═══════════════════════════════════════════════════════════════════════
--
-- The free plan has NO backups — no daily, no downloadable, no point in time.
-- R2 holds `spiderman/video/…mp4`; only this database knows that is a film,
-- which title it belongs to, who paid for what. Losing it would leave a bucket
-- of files nobody can name. The RUNBOOK's answer was a weekly export by hand,
-- which is a backup that happens when somebody remembers.
--
-- So the ingest function writes one itself, on the runner's tick, once a day:
-- every public table as JSON (in foreign-key order, so a restore can insert
-- parents before children), the account list from auth.users, gzipped, into
-- the PRIVATE media bucket under `_backup/db/`. `db_backups` records each one.
-- Fourteen days are kept, and the first of every month for a year. Analytics
-- events are kept for their last ninety days only — the one table that grows
-- without limit, and the daily summaries hold its history.
--
-- A BACKUP IS NOT AN "UNUSED FILE". `r2_refs` now names every live backup and
-- every published APK, so the Files page neither offers them for the bin nor
-- lets the bin delete them.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 2. THE ARCHIVE CHANNEL
-- ═══════════════════════════════════════════════════════════════════════
--
-- A film's Telegram copy was the message the operator forwarded to the bot —
-- one private chat, and nothing at all for a film uploaded from the console.
-- With an archive channel connected (the bot made an admin of a private
-- channel BY AN OPERATOR — the webhook checks who), the runner copies every
-- film there: a forwarded one with Telegram's own server-side copy, a console
-- upload by fetching it from R2 and sending it. The film's `vault_copies` row
-- then POINTS AT THE CHANNEL COPY, so every check and restore since 029 works
-- unchanged; the original chat and message are kept beside it. Console uploads
-- become archivable for the first time.
--
-- ═══════════════════════════════════════════════════════════════════════
-- 3. WHAT THE STATUS PAGE READS
-- ═══════════════════════════════════════════════════════════════════════
--
-- `runner_ticks`: when each runner was last seen, and which of its secrets were
-- set (yes or no, never a value). `ops_status()`: queues, backups, the archive,
-- the newest migration and release, in one call.

-- APPLIED 2 Oct 2026 in pieces (032a, then the rest), because the tool that
-- applies migrations stops to ask about any DROP. Nothing here drops anything.
--
-- ---------------------------------------------------------------------------
-- 1. backups
-- ---------------------------------------------------------------------------

create table if not exists public.db_backups (
  id          bigserial primary key,
  taken_at    timestamptz not null default now(),
  object_key  text not null,
  bytes       bigint,
  raw_bytes   bigint,
  sha256      text,
  tables      jsonb,
  trigger     text not null default 'daily' check (trigger in ('daily', 'manual')),
  actor       uuid,
  deleted_at  timestamptz,
  note        text
);
create index if not exists db_backups_live on public.db_backups (taken_at desc)
  where deleted_at is null;

-- What a backup holds, parents before children. Every table in public except
-- admin_sessions (who is signed in right now is not worth restoring).
create or replace function public.backup_tables()
returns table(name text, ord integer)
language sql
stable
security definer
set search_path to 'public'
as $$
  with recursive t as (
    select c.oid, c.relname::text as relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r'
       and c.relname not in ('admin_sessions')
  ), deps as (
    select con.conrelid as child, con.confrelid as parent
      from pg_constraint con
     where con.contype = 'f' and con.conrelid <> con.confrelid
       and con.conrelid in (select oid from t) and con.confrelid in (select oid from t)
  ), lvl(oid, depth) as (
    select oid, 0 from t
    union all
    select d.child, l.depth + 1 from lvl l join deps d on d.parent = l.oid where l.depth < 20
  )
  select t.relname, max(l.depth)::integer
    from t join lvl l on l.oid = t.oid
   group by t.relname
   order by 2, 1;
$$;

-- One table as a JSON array. `json`, not text, so PostgREST hands the edge
-- function the array as it is and nothing is encoded twice.
create or replace function public.backup_table(p_name text)
returns json
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare
  out json;
  cond text := '';
begin
  if not exists (select 1 from public.backup_tables() b where b.name = p_name) then
    raise exception 'not a backed-up table: %', p_name;
  end if;
  if p_name = 'events' then
    cond := 'where occurred_at > now() - interval ''90 days''';
  end if;
  execute format('select coalesce(json_agg(t), ''[]''::json) from (select * from public.%I %s) t',
                 p_name, cond) into out;
  return out;
end;
$$;

-- The accounts: who signed up, how, when. No password hashes, no tokens.
create or replace function public.backup_auth_users()
returns json
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(json_agg(u), '[]'::json) from (
    select id, email, phone, created_at, last_sign_in_at, email_confirmed_at,
           raw_app_meta_data, raw_user_meta_data, banned_until
      from auth.users order by created_at) u;
$$;

create or replace function public.backup_due()
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select not exists (select 1 from public.db_backups b
                      where b.deleted_at is null and b.taken_at > now() - interval '20 hours');
$$;

create or replace function public.backup_record(
  p_key text, p_bytes bigint, p_raw bigint, p_sha text, p_tables jsonb,
  p_trigger text, p_actor uuid default null, p_note text default null)
returns bigint
language sql
security definer
set search_path to 'public'
as $$
  insert into public.db_backups (object_key, bytes, raw_bytes, sha256, tables, trigger, actor, note)
  values (p_key, p_bytes, p_raw, p_sha, p_tables,
          case when p_trigger = 'manual' then 'manual' else 'daily' end, p_actor, left(p_note, 300))
  returning id;
$$;

-- What may go: older than fourteen days and not the first of its month within
-- the last year. Never the newest, whatever its age.
create or replace function public.backup_prune_list()
returns table(id bigint, object_key text)
language sql
stable
security definer
set search_path to 'public'
as $$
  with live as (select * from public.db_backups where deleted_at is null),
  monthly as (
    select distinct on (date_trunc('month', l.taken_at)) l.id, l.taken_at
      from live l order by date_trunc('month', l.taken_at), l.taken_at),
  keep as (
    select l.id from live l where l.taken_at > now() - interval '14 days'
    union select m.id from monthly m where m.taken_at > now() - interval '365 days'
    union select max(l.id) from live l)
  select l.id, l.object_key from live l
   where l.id not in (select k.id from keep k where k.id is not null);
$$;

create or replace function public.backup_deleted(p_id bigint)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.db_backups set deleted_at = now() where id = p_id;
$$;

-- A backup and an APK are in use. See the note at the top.
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
   where j.title_id is null
  union all
  select b.object_key, null::uuid, 'database backup' from public.db_backups b
   where b.deleted_at is null
  union all
  select substr(r.apk_url, length(public.public_asset_base()) + 1), null::uuid, 'app update'
    from public.app_releases r
   where r.apk_url like public.public_asset_base() || 'apk/%';
$$;

-- ---------------------------------------------------------------------------
-- 2. the archive channel
-- ---------------------------------------------------------------------------

alter table public.admin_settings
  add column if not exists archive_chat_id bigint,
  add column if not exists archive_chat_title text,
  add column if not exists archive_connected_at timestamptz,
  add column if not exists archive_connected_by text,
  add column if not exists archive_note text;

alter table public.vault_copies
  add column if not exists origin_chat_id bigint,
  add column if not exists origin_message_id bigint,
  add column if not exists archived_at timestamptz;

alter table public.vault_jobs drop constraint if exists vault_jobs_kind_check;
alter table public.vault_jobs add constraint vault_jobs_kind_check
  check (kind in ('verify', 'restore', 'archive'));

-- An operator made the bot an admin of a channel (the webhook checked who), or
-- an owner connected one from the console (the edge function checked the bot
-- may post there).
create or replace function public.archive_connect(p_chat bigint, p_title text, p_by text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare cur bigint;
begin
  if p_chat is null or p_chat >= 0 then return 'not_a_channel'; end if;
  select s.archive_chat_id into cur from public.admin_settings s limit 1 for update;
  update public.admin_settings
     set archive_chat_id = p_chat, archive_chat_title = left(p_title, 200),
         archive_connected_at = case when cur is distinct from p_chat then now()
                                     else archive_connected_at end,
         archive_connected_by = left(p_by, 120), archive_note = null
   where true;
  return case when cur is not distinct from p_chat then 'same' else 'connected' end;
end;
$$;

-- The bot was removed from the channel, or an owner disconnected it. Copies
-- already there stay recorded where they are; nothing new is sent.
create or replace function public.archive_disconnect(p_chat bigint, p_note text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare cur bigint;
begin
  select s.archive_chat_id into cur from public.admin_settings s limit 1 for update;
  if cur is null then return 'none'; end if;
  if p_chat is not null and p_chat <> cur then return 'not_the_archive'; end if;
  update public.admin_settings set archive_chat_id = null, archive_note = left(p_note, 300)
   where true;
  update public.vault_jobs set state = 'failed', finished_at = now(),
         note = 'archive channel disconnected'
   where kind = 'archive' and state = 'queued';
  return 'disconnected';
end;
$$;

-- The claim now hands out archive jobs too: with the channel, and — for a
-- console upload, which has no Telegram copy — the object to fetch from R2.
--
-- A NEW NAME, NOT A NEW RETURN TYPE ON THE OLD ONE. Changing vault_claim's
-- columns means dropping it, and the ingest function already deployed calls it
-- by name; between the drop and the deploy every claim would fail. So the old
-- one keeps its shape and simply never hands out an archive job (it would call
-- one a "verify"), and the new edge function calls vault_claim_v2.
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
     and x.kind <> 'archive'
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

create or replace function public.vault_claim_v2()
returns table(job_id uuid, kind text, asset_id uuid, chat_id bigint, message_id bigint,
              unique_id text, bytes bigint, bucket text, object_key text,
              archive_chat bigint, title text)
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j uuid;
  arch bigint;
begin
  select s.archive_chat_id into arch from public.admin_settings s limit 1;
  select x.id into j from public.vault_jobs x
   where ((x.state = 'queued' and x.not_before <= now())
          or (x.state = 'running' and x.claimed_at < now() - interval '7 hours'))
     and (exists (select 1 from public.vault_copies c where c.asset_id = x.asset_id)
          or (x.kind = 'archive' and exists (select 1 from public.title_assets a
                                               where a.id = x.asset_id and a.master_state = 'r2')))
     and (x.kind <> 'archive' or arch is not null)
   order by case x.kind when 'restore' then 0 when 'verify' then 1 else 2 end, x.created_at
   for update skip locked
   limit 1;
  if j is null then return; end if;
  update public.vault_jobs
     set state = 'running', claimed_at = now(), attempts = attempts + 1, note = 'claimed'
   where id = j;
  return query
    select x.id, x.kind, x.asset_id, c.chat_id, c.message_id, c.unique_id,
           coalesce(c.bytes, a.bytes), a.bucket, a.object_key,
           case when x.kind = 'archive' then arch end, t.title
      from public.vault_jobs x
      join public.title_assets a on a.id = x.asset_id
      join public.titles t on t.id = a.title_id
      left join public.vault_copies c on c.asset_id = x.asset_id
     where x.id = j;
end;
$$;

-- vault_finish, unchanged but for the guard against an archive job.
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
  -- AN ARCHIVE JOB IS NOT FINISHED HERE. Its answer is a new message in the
  -- archive channel, which only vault_archive_finish records; letting it fall
  -- through would run the RESTORE branch below on a film nobody asked to move.
  if j.kind = 'archive' then return 'use_vault_archive_finish'; end if;
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

-- The runner's answer to an archive job: the film is now message `p_message`
-- of channel `p_chat`, and the copy row points there.
create or replace function public.vault_archive_finish(
  p_job uuid, p_ok boolean, p_note text, p_chat bigint, p_message bigint,
  p_unique text, p_bytes bigint)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j record;
  arch bigint;
  want bigint;
begin
  select * into j from public.vault_jobs where id = p_job for update;
  if not found then return 'no_such_job'; end if;
  if j.state <> 'running' then return 'not_running'; end if;
  if j.kind <> 'archive' then return 'not_an_archive_job'; end if;

  if not coalesce(p_ok, false) then
    if j.attempts >= 3 then
      update public.vault_jobs set state = 'failed', finished_at = now(), note = left(p_note, 300)
       where id = p_job;
      return 'failed';
    end if;
    update public.vault_jobs set state = 'queued', note = left(p_note, 300),
           not_before = now() + interval '30 minutes'
     where id = p_job;
    return 'retry';
  end if;

  select s.archive_chat_id into arch from public.admin_settings s limit 1;
  if p_chat is null or p_message is null or arch is distinct from p_chat then
    update public.vault_jobs set state = 'failed', finished_at = now(),
           note = 'the copy is not in the archive channel'
     where id = p_job;
    return 'wrong_chat';
  end if;
  -- THE SAME FILE OR NOTHING. A short upload recorded as the archive would be
  -- the one copy a restore trusts.
  select coalesce(c.bytes, a.bytes) into want
    from public.title_assets a left join public.vault_copies c on c.asset_id = a.id
   where a.id = j.asset_id;
  if want is not null and p_bytes is not null and p_bytes <> want then
    update public.vault_jobs set state = 'failed', finished_at = now(),
           note = format('archived %s bytes, expected %s', p_bytes, want)
     where id = p_job;
    return 'size_mismatch';
  end if;

  insert into public.vault_copies as c
         (asset_id, chat_id, message_id, unique_id, bytes, source, state, verified_at, archived_at)
  values (j.asset_id, p_chat, p_message, nullif(p_unique, ''), coalesce(p_bytes, want),
          'archive channel', 'ok', now(), now())
  on conflict (asset_id) do update
     set origin_chat_id = coalesce(c.origin_chat_id, c.chat_id),
         origin_message_id = coalesce(c.origin_message_id, c.message_id),
         chat_id = excluded.chat_id, message_id = excluded.message_id,
         unique_id = coalesce(excluded.unique_id, c.unique_id),
         bytes = coalesce(c.bytes, excluded.bytes),
         source = 'archive channel', state = 'ok', verified_at = now(),
         archived_at = now(), note = null;
  update public.vault_jobs set state = 'done', finished_at = now(), note = 'archived'
   where id = p_job;
  return 'archived';
end;
$$;

-- vault_schedule, with (d): films not yet in the archive channel.
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
  arch bigint;
  open_jobs integer;
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

  -- (d) with an archive channel connected (migration 032): films not in it
  --     yet, a few at a time. Forwarded films first — Telegram copies those
  --     server side in a second; a console upload is a download from R2 and
  --     an upload to Telegram, so it waits its turn. Over Telegram's 2000 MB
  --     a bot cannot send, and is left alone. A failure waits a day.
  select s.archive_chat_id into arch from public.admin_settings s limit 1;
  if arch is not null then
    select count(*) into open_jobs from public.vault_jobs v
     where v.kind = 'archive' and v.state in ('queued', 'running');
    if open_jobs < 5 then
      insert into public.vault_jobs (asset_id, kind)
      select a.id, 'archive' from public.title_assets a
        left join public.vault_copies c on c.asset_id = a.id
       where a.kind = 'video'
         and (c.asset_id is null or c.archived_at is null)
         and (c.asset_id is not null
              or (a.master_state = 'r2' and coalesce(a.bytes, 0) between 1 and 2097152000))
         and not exists (select 1 from public.vault_jobs v
                          where v.asset_id = a.id and v.kind = 'archive'
                            and (v.state in ('queued', 'running')
                                 or (v.state = 'failed' and v.finished_at > now() - interval '1 day')))
       order by (c.asset_id is null), a.added_at
       limit 5 - open_jobs
      on conflict (asset_id, kind) where state in ('queued', 'running') do nothing;
      get diagnostics k = row_count; n := n + k;
    end if;
  end if;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. what the Status page reads
-- ---------------------------------------------------------------------------

create table if not exists public.runner_ticks (
  name    text primary key,
  seen_at timestamptz not null default now(),
  info    jsonb
);

create or replace function public.runner_tick(p_name text, p_info jsonb)
returns void
language sql
security definer
set search_path to 'public'
as $$
  insert into public.runner_ticks (name, seen_at, info)
  values (left(p_name, 40), now(), p_info)
  on conflict (name) do update
     set seen_at = now(), info = coalesce(excluded.info, runner_ticks.info);
$$;

create or replace function public.ops_status()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'db_bytes', pg_database_size(current_database()),
    'migration', (select max(m.version) from public.schema_migrations m),
    'runners', coalesce((select jsonb_agg(jsonb_build_object(
                   'name', r.name, 'seen_at', r.seen_at, 'info', r.info) order by r.name)
                   from public.runner_ticks r), '[]'::jsonb),
    'ingest', (select jsonb_build_object(
                 'queued', count(*) filter (where j.state = 'queued'),
                 'running', count(*) filter (where j.state = 'running'),
                 'failed', count(*) filter (where j.state = 'failed'),
                 'last_done', max(j.finished_at) filter (where j.state = 'done'))
                 from public.ingest_jobs j),
    'vault', coalesce((select jsonb_object_agg(v.kind, v.s) from (
                 select x.kind, jsonb_build_object(
                   'queued', count(*) filter (where x.state = 'queued'),
                   'running', count(*) filter (where x.state = 'running'),
                   'failed_7d', count(*) filter (where x.state = 'failed'
                                                  and x.finished_at > now() - interval '7 days'),
                   'done_7d', count(*) filter (where x.state = 'done'
                                                and x.finished_at > now() - interval '7 days'),
                   'last_note', (array_agg(x.note order by x.created_at desc))[1]) s
                   from public.vault_jobs x group by x.kind) v), '{}'::jsonb),
    'transcode', coalesce((select jsonb_object_agg(z.st, z.n) from (
                 select coalesce(a.transcode_state, 'none') st, count(*) n
                   from public.title_assets a where a.kind = 'video' group by 1) z), '{}'::jsonb),
    'last_transcode', (select max(a.transcode_at) from public.title_assets a),
    'backups', coalesce((select jsonb_agg(to_jsonb(b) order by b.taken_at desc) from (
                 select x.id, x.taken_at, x.bytes, x.raw_bytes, x.tables, x.trigger, x.note
                   from public.db_backups x where x.deleted_at is null
                  order by x.taken_at desc limit 10) b), '[]'::jsonb),
    'backup_due', public.backup_due(),
    'archive', (select jsonb_build_object(
                 'chat_id', s.archive_chat_id, 'title', s.archive_chat_title,
                 'connected_at', s.archive_connected_at, 'connected_by', s.archive_connected_by,
                 'note', s.archive_note) from public.admin_settings s limit 1),
    'films', (select jsonb_build_object(
                 'total', count(*), 'with_copy', count(c.asset_id), 'archived', count(c.archived_at),
                 'console_only', count(*) filter (where c.asset_id is null),
                 'too_big', count(*) filter (where c.asset_id is null
                                              and coalesce(a.bytes, 0) > 2097152000))
                from public.title_assets a left join public.vault_copies c on c.asset_id = a.id
               where a.kind = 'video'),
    'previews_missing', (select count(*) from public.title_assets a
                          where a.kind in ('photo', 'video', 'clip', 'trailer') and a.preview is null),
    'release', (select jsonb_build_object('version', r.version_name, 'code', r.version_code,
                                          'at', r.released_at)
                  from public.app_releases r order by r.version_code desc limit 1)
  );
$$;

-- ---------------------------------------------------------------------------
-- who may call what: the service role, nobody else
-- ---------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['db_backups', 'runner_ticks'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;
grant usage, select on sequence public.db_backups_id_seq to service_role;

do $$
declare f text;
begin
  foreach f in array array[
    'backup_tables()', 'backup_table(text)', 'backup_auth_users()', 'backup_due()',
    'backup_record(text,bigint,bigint,text,jsonb,text,uuid,text)', 'backup_prune_list()',
    'backup_deleted(bigint)', 'archive_connect(bigint,text,text)',
    'archive_disconnect(bigint,text)', 'vault_claim()', 'vault_claim_v2()',
    'vault_archive_finish(uuid,boolean,text,bigint,bigint,text,bigint)',
    'vault_finish(uuid,boolean,text,text,bigint)', 'vault_schedule()',
    'runner_tick(text,jsonb)', 'ops_status()', 'r2_refs()'] loop
    execute format('revoke all on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

insert into public.schema_migrations (version, note)
values ('032', 'daily database backup to R2, the Telegram archive channel, the Status page')
on conflict (version) do nothing;
