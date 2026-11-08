-- 079: the restore drill — a backup is opened, not only written   (7 Nov 2026)
--
-- WHAT WAS WRONG. Daily backups are written, sealed and copied off-site
-- (032, 045, 055), and nothing ever opened one: a file that would not
-- unseal, un-gzip or parse would be found on the day it was needed.
--
-- WHAT THIS CHANGES. The ingest function's housekeeping (ingest.ts
-- drillBackup) asks backup_verify_due() for the newest live backup when no
-- drill has passed in seven days and none was tried in the last twenty
-- hours; it reads the file back from R2, checks its hash against the
-- record, unseals it, un-gzips it, parses it and counts every table's rows
-- against the record; then backup_verified() writes the outcome on that
-- backup's row. A failure is told to the owner and tried again the next
-- day. The key never leaves the function and nothing is written anywhere.
-- Service role only.
--
-- PROVED BY tool/sql/backup_drill_test.sql and tool/js/backup_drill_test.mjs.

alter table public.db_backups add column if not exists verified_at  timestamptz;
alter table public.db_backups add column if not exists verify_error text;

create or replace function public.backup_verify_due()
returns table (id bigint, object_key text, sha256 text, tables jsonb)
language sql
stable
security definer
set search_path to 'public'
as $$
  select b.id, b.object_key, b.sha256, b.tables
    from public.db_backups b
   where b.deleted_at is null
     and not exists (select 1 from public.db_backups v
                      where v.verified_at > now() - interval '7 days'
                        and v.verify_error is null)
     and not exists (select 1 from public.db_backups v
                      where v.verified_at > now() - interval '20 hours')
   order by b.taken_at desc
   limit 1;
$$;

create or replace function public.backup_verified(p_id bigint, p_error text)
returns boolean
language sql
security definer
set search_path to 'public'
as $$
  update public.db_backups
     set verified_at = now(), verify_error = left(nullif(p_error, ''), 300)
   where id = p_id and deleted_at is null
  returning true;
$$;

revoke all on function public.backup_verify_due() from public, anon, authenticated;
revoke all on function public.backup_verified(bigint, text) from public, anon, authenticated;
grant execute on function public.backup_verify_due() to service_role;
grant execute on function public.backup_verified(bigint, text) to service_role;
