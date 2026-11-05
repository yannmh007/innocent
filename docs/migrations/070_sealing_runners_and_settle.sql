-- 070 — sealed work only for a runner that seals, and a twin never outlives
-- its object (docs/MEDIA_ENCRYPTION.md §7.2, §7.3).
--
-- 1. A RUNNER SAYS WHETHER IT SEALS. The encoder that seals (tool/
--    transcode_seal.py, tool/unseal_proxy.py) reaches runners one release at
--    a time: while it is on a branch, main's scheduled runner still claims
--    every five minutes and knows nothing of `src_seal` or `seal`. Handed a
--    sealed master it would encode ciphertext; handed a canary film it would
--    make plain rungs and drop the twins. So `claim_transcode` and
--    `claim_frames` take `p_seals`, and a runner that does not say it seals
--    is never handed a job that needs it:
--      · its source is sealed (`s/<32 hex>`), or
--      · the switch is `on`, or
--      · the switch is `canary` and the title is an open film (the same rule
--        as media_twin.js `twinAllowed`: slug `open-film-…`).
--    The default stays `true`: what a caller that names nothing got before.
--
-- 2. `media_keys_settle(kind, bucket, remade, gone, keep)`: after a pipeline
--    records what it made, the key rows it left behind.
--      remade  plain objects it wrote again: a twin not made in this job
--              (not in `keep`) opens to the OLD bytes — stale, so it goes.
--      gone    objects the asset named before and no longer does (a rung
--              dropped from the ladder, a still born sealed and taken
--              again): their twin, or their own row when born sealed, goes —
--              unless something in the catalogue still names the object.
--    Each removed row's sealed object goes to the bin for a week, as in 069.
--    Service role only.

-- ── 1 ───────────────────────────────────────────────────────────────────────
create or replace function public.needs_sealing_runner(p_key text, p_title uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $function$
  select coalesce(p_key, '') ~ '^s/[0-9a-f]{32}$'
      or coalesce((select s.seal_new from public.admin_settings s limit 1), 'off') = 'on'
      or (coalesce((select s.seal_new from public.admin_settings s limit 1), 'off') = 'canary'
          and exists (select 1 from public.titles t
                       where t.id = p_title and t.slug ~ '^open-film-[a-z0-9-]{1,48}$'));
$function$;

drop function if exists public.claim_transcode();
create function public.claim_transcode(p_seals boolean default true)
returns table(asset_id uuid, object_key text, bucket text, height integer, duration_s integer, bytes bigint)
language sql
security definer
set search_path to 'public'
as $function$
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
        and (coalesce(p_seals, true) or not public.needs_sealing_runner(x.object_key, x.title_id))
      order by (x.transcode_state = 'running'), x.added_at asc
      for update skip locked
      limit 1
   )
  returning a.id, a.object_key, a.bucket, a.height, a.duration_s, a.bytes;
$function$;

drop function if exists public.claim_frames(integer);
create function public.claim_frames(p_limit integer default 20, p_seals boolean default true)
returns table(asset_id uuid, src_key text, master_key text, duration_s integer)
language sql
security definer
set search_path to 'public'
as $function$
  with pick as (
    select a.id from public.title_assets a
     where a.kind <> 'photo'
       and (a.frames_state is null or a.frames_state = 'queued'
            or (a.frames_state = 'running' and a.frames_at < now() - interval '2 hours'))
       and (a.master_state = 'r2'
            or exists (select 1 from public.asset_renditions r where r.asset_id = a.id))
       and (coalesce(p_seals, true) or not public.needs_sealing_runner(
              case when a.master_state = 'r2' then a.object_key
                   else (select r.object_key from public.asset_renditions r
                          where r.asset_id = a.id order by r.height desc limit 1) end,
              a.title_id))
     order by (a.frames_state = 'queued') desc nulls last, a.added_at desc
     for update skip locked
     limit greatest(1, least(coalesce(p_limit, 20), 50))
  )
  update public.title_assets a
     set frames_state = 'running', frames_at = now(), frames_note = null
    from pick where a.id = pick.id
  returning a.id,
    case when a.master_state = 'r2' then a.object_key
         else (select r.object_key from public.asset_renditions r
                where r.asset_id = a.id order by r.height desc limit 1) end,
    a.object_key, a.duration_s;
$function$;

-- ── 2 ───────────────────────────────────────────────────────────────────────
create or replace function public.media_keys_settle(
  p_kind text, p_bucket text, p_remade text[], p_gone text[], p_keep uuid[])
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  keep   uuid[] := coalesce(p_keep, '{}'::uuid[]);
  remade text[] := coalesce(p_remade, '{}'::text[]);
  gone   text[] := coalesce(p_gone, '{}'::text[]);
  named  text[];
  old    record;
  binned jsonb := '[]'::jsonb;
begin
  if p_kind not in ('video', 'image') then
    raise exception 'media_keys_settle: kind % is neither video nor image', p_kind;
  end if;
  if cardinality(remade) = 0 and cardinality(gone) = 0 then
    return jsonb_build_object('binned', binned);
  end if;
  -- What the catalogue still names, the key rows' own entries aside.
  select coalesce(array_agg(distinct r.key), '{}'::text[]) into named
    from public.r2_refs() r
   where r.how <> 'sealed copy' and r.key = any(gone);

  if p_kind = 'video' then
    for old in delete from public.media_keys k
                where k.bucket = p_bucket and not (k.dek_id = any(keep))
                  and (k.plain_key = any(remade)
                       or ((k.plain_key = any(gone) or k.sealed_key = any(gone))
                           and not (coalesce(k.plain_key, '') = any(named))
                           and not (k.sealed_key = any(named))))
                returning k.sealed_key, k.sealed_size, k.plain_key loop
      insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
      values (p_bucket, old.sealed_key, old.sealed_size,
              case when old.plain_key = any(remade) then 'sealed copy replaced: its film was made again'
                   else 'sealed copy of a streaming copy no longer used' end,
              now() + interval '7 days')
      on conflict do nothing;
      binned := binned || to_jsonb(old.sealed_key);
    end loop;
  else
    for old in delete from public.media_image_keys k
                where k.bucket = p_bucket and not (k.dek_id = any(keep))
                  and (k.plain_key = any(remade)
                       or ((k.plain_key = any(gone) or k.sealed_key = any(gone))
                           and not (coalesce(k.plain_key, '') = any(named))
                           and not (k.sealed_key = any(named))))
                returning k.sealed_key, k.sealed_size, k.plain_key loop
      insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
      values (p_bucket, old.sealed_key, old.sealed_size,
              case when old.plain_key = any(remade) then 'sealed copy replaced: its picture was made again'
                   else 'sealed copy of a still no longer used' end,
              now() + interval '7 days')
      on conflict do nothing;
      binned := binned || to_jsonb(old.sealed_key);
    end loop;
  end if;
  return jsonb_build_object('binned', binned);
end;
$function$;

-- ── grants ──────────────────────────────────────────────────────────────────
do $$
declare f text;
begin
  foreach f in array array[
    'public.needs_sealing_runner(text, uuid)',
    'public.claim_transcode(boolean)',
    'public.claim_frames(integer, boolean)',
    'public.media_keys_settle(text, text, text[], text[], uuid[])'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
