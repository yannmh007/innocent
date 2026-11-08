-- The restore drill is asked for weekly, and daily again after a failure   (migration 079)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it changes survives. Success is the message `BACKUP DRILL TEST PASSED`;
-- any other exception names the case that failed. It needs at least one
-- live backup (there is one a day).
--
--   1. only the service role may ask for or record a drill;
--   2. with no drill yet, the newest live backup is due;
--   3. a passed drill makes nothing due for seven days, and then it is;
--   4. a failed drill is not asked again within twenty hours, then it is;
--   5. a drill cannot be recorded on a deleted backup.
do $$
declare
  newest bigint;
  got    bigint;
  ok     boolean;
begin
  if has_function_privilege('anon', 'public.backup_verify_due()', 'execute')
     or has_function_privilege('authenticated', 'public.backup_verify_due()', 'execute')
     or has_function_privilege('anon', 'public.backup_verified(bigint,text)', 'execute')
     or has_function_privilege('authenticated', 'public.backup_verified(bigint,text)', 'execute') then
    raise exception 'case 1: anon or authenticated may use the drill functions';
  end if;
  if not has_function_privilege('service_role', 'public.backup_verify_due()', 'execute')
     or not has_function_privilege('service_role', 'public.backup_verified(bigint,text)', 'execute') then
    raise exception 'case 1: the service role may not use the drill functions';
  end if;

  update public.db_backups set verified_at = null, verify_error = null;
  select id into newest from public.db_backups
   where deleted_at is null order by taken_at desc limit 1;
  if newest is null then
    raise exception 'case 2: no live backup to test with';
  end if;

  set local role service_role;
  select id into got from public.backup_verify_due();
  if got is distinct from newest then
    raise exception 'case 2: due % instead of the newest live backup %', got, newest;
  end if;
  ok := public.backup_verified(newest, null);
  if ok is not true then
    raise exception 'case 3: the drill was not recorded';
  end if;
  got := null;
  select id into got from public.backup_verify_due();
  if got is not null then
    raise exception 'case 3: due again right after a passed drill';
  end if;
  reset role;

  update public.db_backups set verified_at = now() - interval '8 days' where id = newest;
  set local role service_role;
  select id into got from public.backup_verify_due();
  if got is distinct from newest then
    raise exception 'case 3: not due eight days after a passed drill';
  end if;

  ok := public.backup_verified(newest, 'the sealed file does not open');
  got := null;
  select id into got from public.backup_verify_due();
  if got is not null then
    raise exception 'case 4: a failed drill was asked again at once';
  end if;
  reset role;

  update public.db_backups set verified_at = now() - interval '21 hours' where id = newest;
  set local role service_role;
  select id into got from public.backup_verify_due();
  if got is distinct from newest then
    raise exception 'case 4: a failed drill was not asked again the next day';
  end if;
  reset role;

  update public.db_backups set deleted_at = now() where id = newest;
  set local role service_role;
  ok := public.backup_verified(newest, null);
  if ok is not null then
    raise exception 'case 5: a drill was recorded on a deleted backup';
  end if;
  reset role;

  raise exception 'BACKUP DRILL TEST PASSED';
end $$;
