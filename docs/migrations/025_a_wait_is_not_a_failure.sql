-- ===========================================================================
-- 025  TELEGRAM SAYING "WAIT" IS NOT A FAILED ATTEMPT   (I6)
-- ===========================================================================
--
-- The queue-draining runner from 023's commit took fifteen files in one run
-- and failed seven of them, every one with the same note:
--
--   Telegram says: [420 FLOOD_WAIT_X] - A wait of 394 seconds is required
--   (caused by "auth.ImportBotAuthorization")
--
-- `ImportBotAuthorization` is the bot SIGNING IN. The loop ran the fetch
-- script once per file, and the script signed in to Telegram every time it
-- started — fifteen sign-ins inside two minutes, where there used to be one
-- every fifteen to twenty. Telegram throttled them, and each throttled job
-- went back to the queue, was claimed again a second later by the same loop,
-- signed in again, was throttled again, and had its three attempts spent in
-- under a minute. The waits it asked for climbed 394, 408, 422 … 477 seconds
-- as the loop kept asking.
--
-- The runner now signs in ONCE per run. That is the fix. This migration is
-- the other half: when Telegram does ask for a wait, it is not the file's
-- fault and must not count against it. A FLOOD_WAIT is Telegram's scheduling,
-- not a verdict on the job, and three of them in a row on a busy morning
-- would otherwise mark a perfectly good film as dead.
--
-- `defer_ingest` gives a claimed job back. It returns the attempt the claim
-- took, clears the claim, and says in the note how long Telegram asked for,
-- so the console shows "waiting" rather than a failure. The next run takes
-- it, after the wait has passed — GitHub's own schedule is slower than any
-- wait Telegram has asked of this bot so far.
-- ===========================================================================

create or replace function public.defer_ingest(p_job uuid, p_seconds integer)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  j public.ingest_jobs%rowtype;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;
  -- Only a job a runner is holding. A queued one has no attempt to give
  -- back, and giving one back to a done or failed job would let a later
  -- claim run it a fourth time.
  if j.state <> 'running' then
    return 'not_running';
  end if;

  update public.ingest_jobs
     set state = 'queued',
         attempts = greatest(j.attempts - 1, 0),
         claimed_at = null,
         note = left('waiting: Telegram asked for '
                     || greatest(coalesce(p_seconds, 0), 0)
                     || 's before the next sign-in; the next run takes it', 300)
   where id = p_job;
  return 'deferred';
end;
$$;

revoke all on function public.defer_ingest(uuid, integer)
  from public, anon, authenticated;
grant execute on function public.defer_ingest(uuid, integer) to service_role;
