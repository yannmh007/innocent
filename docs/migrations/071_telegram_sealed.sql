-- 071 — the Telegram pipeline seals, and a key row lives exactly as long as
-- what it opens (docs/MEDIA_ENCRYPTION.md §7.2, §7.3; ENC-4 step 3).
--
-- 1. A TWIN IS IN USE WHEN WHAT IT COPIES IS. 069 counted every key row's
--    sealed object as in use, unconditionally. That kept a born-sealed
--    master in R2 after the storage policy moved it to Telegram (the bin's
--    purge found it "in use again" and took it back out) — while the row
--    said `telegram`. Now:
--      · an object born sealed IS the catalogue's object, named by the
--        entries that name any object (file, streaming copy, thumbnail,
--        cover…); the key row adds nothing;
--      · a twin is in use while its plain object is named — or while that
--        plain object is a master kept in Telegram, which a restore brings
--        back byte for byte, so the twin is still right.
--
-- 2. A PURGED SEALED OBJECT TAKES ITS KEY ROW WITH IT. When the bin's purge
--    deletes an `s/` object, the key rows naming it go: a row whose object
--    is gone would hand a phone a key to nothing.
--
-- 3. TELEGRAM WORK FOR A RUNNER THAT SEALS. `claim_ingest(p_seals)` and
--    `vault_claim_v2(p_seals)`, as 070 did for the encoder: a runner that
--    does not say it seals is never handed a forwarded file the switch
--    wants sealed, nor an archive or restore of a sealed master.
--    `claim_ingest` also answers the job's kind and title, which decide
--    whether it is a film or an image and whether it is an open film.
--
-- 4. `ingest_seal_key(job, key)`: a file born sealed is recorded under its
--    `s/` key — the job's `object_key` becomes it, once its key row exists
--    (born: no plain key) in the job's bucket. `finish_ingest` and
--    `attach_ingest` then make the asset with that key, unchanged.
--
-- 5. A RESTORED SEALED MASTER GETS A NEW NAME. Its bytes come back from
--    Telegram plain; the runner seals them under a NEW DEK (one nonce never
--    covers two plaintexts) to a NEW `s/` key (the Worker's edge cache keys
--    on the object's name, and an old name with new bytes would serve the
--    old ciphertext). `vault_finish(…, p_key)` makes that key the asset's
--    object once its key row exists at the film's own size; the old row, if
--    any is left, goes and its object to the bin.

-- ── 1 ───────────────────────────────────────────────────────────────────────
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  with base as materialized (
    select a.object_key as key, a.title_id, 'file'::text as how from public.title_assets a
     where a.object_key is not null and a.master_state <> 'telegram'
    union all
    select a.thumb_key, a.title_id, 'thumbnail' from public.title_assets a
     where a.thumb_key is not null
    union all
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
      from public.titles t where t.poster_url like public.public_asset_base() || '%'
    union all
    select j.object_key, j.title_id, 'telegram inbox' from public.ingest_jobs j where j.title_id is null
    union all
    select b.object_key, null::uuid, 'database backup' from public.db_backups b where b.deleted_at is null
    union all
    select substr(r.apk_url, length(public.public_asset_base()) + 1), null::uuid, 'app update'
      from public.app_releases r where r.apk_url like public.public_asset_base() || 'apk/%'
  ),
  plain_in_use as materialized (
    select distinct b.key, b.title_id from base b
    union
    -- A master kept in Telegram comes back byte for byte: its twin stays.
    select a.object_key, a.title_id from public.title_assets a
     where a.master_state = 'telegram' and a.object_key is not null
  )
  select b.key, b.title_id, b.how from base b
  union all
  select k.sealed_key, p.title_id, 'sealed copy'
    from public.media_keys k join plain_in_use p on p.key = k.plain_key
  union all
  select k.sealed_key, p.title_id, 'sealed copy'
    from public.media_image_keys k join plain_in_use p on p.key = k.plain_key;
$function$;

-- ── 2 ───────────────────────────────────────────────────────────────────────
create or replace function public.r2_trash_done(p_id bigint, p_error text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_bucket text;
  v_key    text;
begin
  if p_error is null then
    update public.r2_trash set purged_at = now(), purge_error = null where id = p_id
    returning bucket, key into v_bucket, v_key;
    delete from public.r2_inventory i where i.bucket = v_bucket and i.key = v_key;
    -- 071: the key rows of a sealed object that is gone.
    if coalesce(v_key, '') ~ '^s/[0-9a-f]{32}$' then
      delete from public.media_keys k where k.bucket = v_bucket and k.sealed_key = v_key;
      delete from public.media_image_keys k where k.bucket = v_bucket and k.sealed_key = v_key;
    end if;
  else
    update public.r2_trash set purge_error = left(p_error, 300) where id = p_id;
  end if;
end;
$function$;

-- ── 3 ───────────────────────────────────────────────────────────────────────
drop function if exists public.claim_ingest();
create function public.claim_ingest(p_seals boolean default true)
returns table(job_id uuid, tg_file_id text, tg_chat_id bigint, tg_message_id bigint,
              object_key text, bucket text, file_name text, bytes bigint,
              kind text, title_id uuid)
language sql
security definer
set search_path to 'public'
as $function$
  update public.ingest_jobs j
     set state = 'running',
         note = 'claimed',
         claimed_at = now(),
         attempts = j.attempts + 1
   where j.id = (
     select x.id from public.ingest_jobs x
      where (x.state = 'queued'
             -- A runner that died leaves a row saying 'running' for ever.
             -- Seven hours is past the platform's own ceiling, so a live job
             -- is never stolen from itself.
             or (x.state = 'running' and x.claimed_at < now() - interval '7 hours'))
        and (coalesce(p_seals, true) or not public.needs_sealing_runner(x.object_key, x.title_id))
      order by (x.state = 'running'), x.created_at asc
      for update skip locked
      limit 1
   )
  returning j.id, j.tg_file_id, j.tg_chat_id, j.tg_message_id,
            j.object_key, j.bucket, j.file_name, j.bytes, j.kind, j.title_id;
$function$;

drop function if exists public.vault_claim_v2();
create function public.vault_claim_v2(p_seals boolean default true)
returns table(job_id uuid, kind text, asset_id uuid, chat_id bigint, message_id bigint,
              unique_id text, bytes bigint, bucket text, object_key text,
              archive_chat bigint, title text)
language plpgsql
security definer
set search_path to 'public'
as $function$
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
     -- 071: an archive or restore of a sealed master needs a runner that
     -- seals (it opens the master to send it, or seals what comes back).
     and (coalesce(p_seals, true) or x.kind = 'verify'
          or not exists (select 1 from public.title_assets a
                          where a.id = x.asset_id and a.object_key ~ '^s/[0-9a-f]{32}$'))
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
$function$;

-- The claim of a runner from before 032 (no `can`): it never seals.
create or replace function public.vault_claim()
returns table(job_id uuid, kind text, asset_id uuid, chat_id bigint, message_id bigint,
              unique_id text, bytes bigint, bucket text, object_key text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare j uuid;
begin
  select x.id into j from public.vault_jobs x
   where ((x.state = 'queued' and x.not_before <= now())
          or (x.state = 'running' and x.claimed_at < now() - interval '7 hours'))
     and x.kind <> 'archive'
     and exists (select 1 from public.vault_copies c where c.asset_id = x.asset_id)
     and (x.kind = 'verify'
          or not exists (select 1 from public.title_assets a
                          where a.id = x.asset_id and a.object_key ~ '^s/[0-9a-f]{32}$'))
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
$function$;

-- ── 4 ───────────────────────────────────────────────────────────────────────
create or replace function public.ingest_seal_key(p_job uuid, p_key text)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  j public.ingest_jobs%rowtype;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then return 'no_such_job'; end if;
  if j.state <> 'running' then return 'not_running'; end if;
  if coalesce(p_key, '') !~ '^s/[0-9a-f]{32}$' then return 'not_a_sealed_key'; end if;
  if not exists (select 1 from public.media_keys k
                  where k.bucket = j.bucket and k.sealed_key = p_key and k.plain_key is null)
     and not exists (select 1 from public.media_image_keys k
                      where k.bucket = j.bucket and k.sealed_key = p_key and k.plain_key is null) then
    return 'no_key_row';
  end if;
  update public.ingest_jobs set object_key = p_key where id = p_job;
  return 'sealed';
end;
$function$;

-- ── 5 ───────────────────────────────────────────────────────────────────────
drop function if exists public.vault_finish(uuid, boolean, text, text, bigint);
create function public.vault_finish(p_job uuid, p_ok boolean, p_state text, p_note text,
                                    p_bytes bigint, p_key text default null)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  j record;
  want bigint;
  tid uuid;
  old_key text;
  bkt text;
  gone record;
begin
  select * into j from public.vault_jobs where id = p_job for update;
  if not found then return 'no_such_job'; end if;
  if j.state <> 'running' then return 'not_running'; end if;
  if j.kind = 'archive' then return 'use_vault_archive_finish'; end if;
  select a.title_id, a.object_key, a.bucket into tid, old_key, bkt
    from public.title_assets a where a.id = j.asset_id;

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

  -- 071: a sealed master comes back under a new key, sealed afresh.
  if old_key ~ '^s/[0-9a-f]{32}$' then
    if coalesce(p_key, '') !~ '^s/[0-9a-f]{32}$' or p_key = old_key
       or not exists (select 1 from public.media_keys k
                       where k.bucket = bkt and k.sealed_key = p_key and k.plain_key is null
                         and (want is null or k.plain_size = want)) then
      update public.vault_jobs set state = 'failed', finished_at = now(),
             note = 'a sealed master came back without its new sealed key'
       where id = p_job;
      update public.title_assets set master_state = 'telegram' where id = j.asset_id
         and master_state = 'restoring';
      return 'no_sealed_key';
    end if;
    update public.title_assets set object_key = p_key where id = j.asset_id;
    for gone in delete from public.media_keys k where k.bucket = bkt and k.sealed_key = old_key
                returning k.sealed_key, k.sealed_size loop
      insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
      values (bkt, gone.sealed_key, gone.sealed_size,
              'sealed master replaced by its restore', now() + interval '7 days')
      on conflict do nothing;
    end loop;
  end if;

  update public.title_assets set master_state = 'r2', master_moved_at = now()
   where id = j.asset_id and master_state = 'restoring';
  update public.vault_copies set state = 'ok', verified_at = now() where asset_id = j.asset_id;
  update public.vault_jobs set state = 'done', finished_at = now(), note = 'restored'
   where id = p_job;
  perform public.vault_tick(tid);
  return 'restored';
end;
$function$;

-- ── grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.r2_refs()',
    'public.r2_trash_done(bigint, text)',
    'public.claim_ingest(boolean)',
    'public.vault_claim_v2(boolean)',
    'public.vault_claim()',
    'public.ingest_seal_key(uuid, text)',
    'public.vault_finish(uuid, boolean, text, text, bigint, text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
