-- 057 — up to ten Telegram files at once (2026-10-30).
--
-- ingest.yml used to run one file at a time: one runner, one Telegram
-- session, the queue drained in order. It now opens as many lanes as there
-- are files waiting, ten at most (the repository variable INGEST_LANES), each
-- its own runner and session. Two things in the database assumed one at a
-- time, and this is them:
--
-- 1. HOW MANY ARE WAITING. The workflow's first job asks `ingest_depth()`
--    and opens that many lanes, so one forwarded photo does not start ten
--    runners and ten Telegram sign-ins. `queued` is counted exactly as
--    claim_ingest chooses (queued, or running and abandoned for seven hours);
--    `running` is the lanes still busy from an earlier run. Opening lanes
--    1..(queued + running) leaves at least `queued` of them free, whichever
--    numbers the busy ones hold.
--
-- 2. AN ALBUM'S PLACES. finish_ingest and attach_ingest give a new file the
--    next sort_order of its kind in its title — max + 1 — and title_assets is
--    unique on (title_id, kind, sort_order). Two lanes finishing two files of
--    one title in the same moment both read the same max, and the second
--    insert failed. Each now takes a lock on the title first (released at the
--    end of its transaction), so the second waits for the first's place.
--    The bodies are otherwise as they are live (read back with
--    pg_get_functiondef before this was written).

drop function if exists public.ingest_depth();
create function public.ingest_depth()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  select jsonb_build_object(
    'queued', count(*) filter (where x.state = 'queued'
                  or (x.state = 'running' and x.claimed_at < now() - interval '7 hours')),
    'running', count(*) filter (where x.state = 'running'
                  and x.claimed_at >= now() - interval '7 hours'))
    from public.ingest_jobs x;
$$;

create or replace function public.finish_ingest(
  p_job uuid, p_ok boolean, p_note text default null, p_bytes bigint default null
) returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  j public.ingest_jobs%rowtype;
  new_asset uuid;
  slot integer;
  -- Three, because the failures worth retrying are transient and the ones
  -- that are not would otherwise tick every five minutes for ever.
  max_tries constant integer := 3;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;

  if not p_ok then
    if j.attempts < max_tries then
      update public.ingest_jobs
         set state = 'queued',
             note = left('attempt ' || j.attempts || ' of ' || max_tries
                         || ' failed: ' || coalesce(p_note, 'no reason given'), 300),
             -- Cleared, because a row the console shows as finished is a row
             -- nobody waits for, and this one is going round again.
             finished_at = null
       where id = p_job;
      return 'requeued';
    end if;
    update public.ingest_jobs
       set state = 'failed',
           note = left('gave up after ' || j.attempts || ' attempts: '
                       || coalesce(p_note, 'no reason given'), 300),
           finished_at = now()
     where id = p_job;
    return 'failed';
  end if;

  -- A job with no title is parked on purpose: the operator can forward
  -- something before deciding which card it belongs to, and `attach_ingest`
  -- finishes the thought later. The bytes are in the bucket either way, which
  -- is the expensive half.
  if j.title_id is not null then
    -- One place at a time per title (057): another lane may be finishing a
    -- file of the same album right now.
    perform pg_advisory_xact_lock(hashtext('title_assets_slot:' || j.title_id::text));
    select coalesce(max(a.sort_order), -1) + 1 into slot
      from public.title_assets a
     where a.title_id = j.title_id and a.kind = j.kind;

    insert into public.title_assets
      (title_id, kind, bucket, object_key, bytes, duration_s, width, height,
       mime, sort_order, transcode_state)
    values
      (j.title_id, j.kind, j.bucket, j.object_key,
       coalesce(p_bytes, j.bytes), j.duration_s, j.width, j.height, j.mime,
       slot,
       case when j.kind = 'photo' then 'none' else 'queued' end)
    returning id into new_asset;
  end if;

  update public.ingest_jobs
     set state = 'done',
         note = left(coalesce(p_note, ''), 300),
         bytes = coalesce(p_bytes, bytes),
         finished_at = now()
   where id = p_job;

  return coalesce(new_asset::text, 'done_unattached');
end;
$function$;

create or replace function public.attach_ingest(p_job uuid, p_title uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  j public.ingest_jobs%rowtype;
  existing uuid;
  new_asset uuid;
  slot integer;
begin
  select * into j from public.ingest_jobs where id = p_job for update;
  if not found then
    return 'no_such_job';
  end if;
  if j.state <> 'done' then
    return 'not_done';
  end if;
  if p_title is null then
    return 'no_title';
  end if;

  select a.id into existing
    from public.title_assets a
   where a.object_key = j.object_key
   limit 1;
  if existing is not null then
    update public.title_assets set title_id = p_title where id = existing;
    update public.ingest_jobs set title_id = p_title where id = p_job;
    return existing::text;
  end if;

  -- One place at a time per title (057), as in finish_ingest.
  perform pg_advisory_xact_lock(hashtext('title_assets_slot:' || p_title::text));
  select coalesce(max(a.sort_order), -1) + 1 into slot
    from public.title_assets a
   where a.title_id = p_title and a.kind = j.kind;

  insert into public.title_assets
    (title_id, kind, bucket, object_key, bytes, duration_s, width, height,
     mime, sort_order, transcode_state)
  values
    (p_title, j.kind, j.bucket, j.object_key, j.bytes, j.duration_s,
     j.width, j.height, j.mime, slot,
     case when j.kind = 'photo' then 'none' else 'queued' end)
  returning id into new_asset;

  update public.ingest_jobs set title_id = p_title where id = p_job;
  return new_asset::text;
end;
$function$;

revoke all on function public.ingest_depth() from public, anon, authenticated;
grant execute on function public.ingest_depth() to service_role;
revoke all on function public.finish_ingest(uuid, boolean, text, bigint) from public, anon, authenticated;
grant execute on function public.finish_ingest(uuid, boolean, text, bigint) to service_role;
revoke all on function public.attach_ingest(uuid, uuid) from public, anon, authenticated;
grant execute on function public.attach_ingest(uuid, uuid) to service_role;

insert into public.schema_migrations (version, note)
values ('057', 'up to ten Telegram files at once: queue depth, one place at a time per title')
on conflict (version) do nothing;
