-- 055 — the database backups already in R2, sealed where they lie (2026-10-30).
--
-- From today ingest.ts seals each new backup (docs/edge/pii.ts sealFile, a key
-- derived from the Edge secret PII_ENC_KEY): `….json.gz.sealed`. The sixteen
-- written before that are still plain gzip, and retention keeps the first of
-- each month for a YEAR — the 2 October one would have stayed readable to any
-- leaked R2 or off-site token until next October.
--
-- So on each runner tick ingest.ts takes a few of them: reads the plain file,
-- checks it against the hash recorded when it was made, writes the sealed one
-- beside it, deletes the off-site copy and the plain file, then calls
-- backup_resealed, which points the row at the sealed file and clears its
-- off-site columns so the usual catch-up (backup_offsite_due) copies the
-- sealed one off-site. Nothing is deleted before the sealed file is written;
-- a tick that stops half-way is finished by the next (see ingest.ts).

-- Live backups not sealed yet, oldest first.
create or replace function public.backup_plain_due(p_limit integer default 3)
returns table(id bigint, object_key text, sha256 text, offsite_key text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.id, b.object_key, b.sha256, b.offsite_key from public.db_backups b
   where b.deleted_at is null
     and b.object_key like '\_backup/db/%'
     and b.object_key not like '%.sealed'
   order by b.taken_at
   limit greatest(least(p_limit, 20), 0);
$$;

-- The row now names the sealed file. Only ever `<the old key>.sealed`, so a
-- call cannot point a backup at some other object.
create or replace function public.backup_resealed(
  p_id bigint, p_key text, p_bytes bigint, p_sha text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  update public.db_backups
     set object_key = p_key, bytes = p_bytes, sha256 = p_sha,
         offsite_key = null, offsite_at = null
   where id = p_id and deleted_at is null
     and p_key = object_key || '.sealed'
     and p_sha ~ '^[0-9a-f]{64}$' and p_bytes > 0;
  get diagnostics n = row_count;
  return n = 1;
end;
$$;

revoke all on function public.backup_plain_due(integer) from public, anon, authenticated;
revoke all on function public.backup_resealed(bigint, text, bigint, text) from public, anon, authenticated;
grant execute on function public.backup_plain_due(integer) to service_role;
grant execute on function public.backup_resealed(bigint, text, bigint, text) to service_role;

insert into public.schema_migrations (version, note)
values ('055', 'database backups already in R2 sealed where they lie')
on conflict (version) do nothing;
