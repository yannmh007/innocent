-- 083 — the seek bar's pictures made in advance (docs/trickplay_plan.md).
--
-- WHAT WAS WRONG. A seek-bar picture of a part not yet seen cost 1.2-1.4 s
-- (device lab S1-S3, G1): a two-second fragment of the smallest rung fetched
-- from the Worker and decoded on the phone. A runner can make them once: one
-- small picture every 4 s, packed into one file (tool/trickplay.py, `ITP1`)
-- the phone reads by byte range.
--
-- WHAT THIS ADDS (additive: nothing an installed app reads changes).
--   * asset_trickplay — one pack per asset: where it is, what is in it, and
--     the rung it was made from (source_bytes: a new ladder makes it stale,
--     so record_renditions is not touched). RLS on, no policy; the service
--     role only.
--   * claim_trickplay(scope, limit) — assets whose smallest rung is PLAIN
--     (a sealed-only film keeps today's previews; v1) and that have no
--     current pack; `open` (the default) only the open films
--     (`open-film-…`), `all` only on the owner's word (CLAUDE.md). Marks them
--     running; a runner that died is offered again after two hours, a
--     failure after a day. Serialised by an advisory lock.
--   * record_trickplay(asset, row, note) — the pack made, or the failure;
--     the key must be the one claim_trickplay minted for that claim: the
--     smallest rung's key with `-NNNp.mp4` → `-trick-<tag>.itp`, beside it in
--     the private media bucket, a NEW key every claim — the stream Worker
--     keeps blocks for 30 days by key, so a pack made again under the same
--     key would be served old and new mixed (review of 20 Nov). The pack it
--     replaces goes to the bin for a week.
--   * trickplay_for(asset) — the pack for request-playback, only while it
--     was made from the ladder that is there now.
--   * r2_refs() names the CURRENT packs ('seek-bar pictures'): the bin's
--     purge never deletes one, the Files page does not call it stray. A pack
--     its film has outgrown — a new ladder, a ladder now sealed only, an
--     archived title — is no longer named, and shows as stray there.
--   * r2_move_switch() re-points a moved pack, as 073 did for the stills.
--
-- CALLERS: docs/edge/transcode.ts ops trick_claim / trick_done, run by
-- .github/workflows/trickplay.yml (tool/trickplay_job.py); request-playback
-- for the grant's `trickplay` field.
-- TEST: tool/sql/trickplay_test.sql (ends in 'TRICKPLAY TEST PASSED').

create table if not exists public.asset_trickplay (
  asset_id     uuid primary key references public.title_assets(id) on delete cascade,
  state        text not null default 'running',
  object_key   text,
  bytes        bigint,
  interval_ms  integer,
  width        integer,
  height       integer,
  count        integer,
  codec        text,
  source_key   text,
  source_bytes bigint,
  pack_key     text,
  note         text,
  claimed_at   timestamptz not null default now(),
  made_at      timestamptz,
  constraint asset_trickplay_state check (state in ('running', 'done', 'failed')),
  constraint asset_trickplay_codec check (codec is null or codec in ('jpeg', 'webp'))
);

alter table public.asset_trickplay enable row level security;
revoke all on table public.asset_trickplay from public, anon, authenticated;
grant select, insert, update, delete on table public.asset_trickplay to service_role;

-- The key a pack gets: the smallest rung's, its `-NNNp.mp4` made
-- `-trick-<tag>.itp` (docs/edge/transcode.ts rungKey: master stem +
-- `-NNNp.mp4`); the tag is new at every claim. Null for a key of any other
-- shape — a sealed `s/<hex>` among them.
create or replace function public.trickplay_key(p_rung_key text, p_tag text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when p_rung_key ~ '-[0-9]{3,4}p\.mp4$' and p_tag ~ '^[0-9a-f]{1,16}$'
              then regexp_replace(p_rung_key, '-[0-9]{3,4}p\.mp4$', '-trick-' || p_tag || '.itp')
              else null end;
$$;

create or replace function public.claim_trickplay(p_scope text default 'open', p_limit integer default 10)
returns table(asset_id uuid, src_key text, src_height integer, src_bytes bigint, pack_key text)
language plpgsql
security definer
set search_path = public
as $$
declare
  tag text := to_hex((extract(epoch from clock_timestamp()) * 1000)::bigint);
begin
  if p_scope is null or p_scope not in ('open', 'all') then
    raise exception 'claim_trickplay: scope is open or all';
  end if;
  -- One claim at a time: two runners never take the same asset.
  perform pg_advisory_xact_lock(hashtext('public.claim_trickplay'));
  return query
  with low as (
    select distinct on (r.asset_id) r.asset_id, r.object_key, r.height, r.bytes
      from public.asset_renditions r
     order by r.asset_id, r.height
  ),
  pick as (
    select l.asset_id, l.object_key, l.height, l.bytes
      from low l
      join public.title_assets a on a.id = l.asset_id
      join public.titles t on t.id = a.title_id
      left join public.asset_trickplay k on k.asset_id = l.asset_id
     where l.object_key !~ '^s/'
       and public.trickplay_key(l.object_key, tag) is not null
       and coalesce(l.bytes, 0) > 0
       and (p_scope = 'all' or t.slug ~ '^open-film-[a-z0-9-]{1,48}$')
       and (k.asset_id is null
            or (k.state = 'done' and k.source_bytes is distinct from l.bytes)
            or (k.state = 'running' and k.claimed_at < now() - interval '2 hours')
            or (k.state = 'failed' and k.claimed_at < now() - interval '1 day'))
     order by (k.asset_id is null) desc, l.asset_id
     limit greatest(1, least(coalesce(p_limit, 10), 50))
  ),
  mark as (
    insert into public.asset_trickplay as k (asset_id, state, source_key, source_bytes, pack_key,
                                             claimed_at, note)
    select p.asset_id, 'running', p.object_key, p.bytes, public.trickplay_key(p.object_key, tag),
           now(), null
      from pick p
    on conflict on constraint asset_trickplay_pkey do update
       set state = 'running', source_key = excluded.source_key,
           source_bytes = excluded.source_bytes, pack_key = excluded.pack_key,
           claimed_at = now(), note = null
    returning k.asset_id, k.pack_key
  )
  select p.asset_id, p.object_key, p.height, p.bytes, m.pack_key
    from pick p join mark m on m.asset_id = p.asset_id;
end;
$$;

create or replace function public.record_trickplay(p_asset uuid, p_row jsonb, p_note text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  k public.asset_trickplay%rowtype;
  n integer;
begin
  select * into k from public.asset_trickplay where asset_id = p_asset for update;
  if k.asset_id is null or k.state <> 'running' then
    raise exception 'record_trickplay: % was not claimed', p_asset;
  end if;
  if p_row is null or jsonb_typeof(p_row) <> 'object' then
    update public.asset_trickplay
       set state = 'failed', note = left(coalesce(p_note, 'no pack'), 200), made_at = null
     where asset_id = p_asset;
    return null;
  end if;
  -- Only the key the claim minted, and numbers a pack can have.
  if k.pack_key is null or (p_row->>'key') is distinct from k.pack_key
     or coalesce((p_row->>'bytes')::bigint, 0) <= 0
     or coalesce((p_row->>'interval_ms')::integer, 0) not between 500 and 60000
     or coalesce((p_row->>'width')::integer, 0) not between 32 and 1280
     or coalesce((p_row->>'height')::integer, 0) not between 16 and 1280
     or coalesce((p_row->>'count')::integer, 0) not between 1 and 100000
     or coalesce(p_row->>'codec', '') not in ('jpeg', 'webp') then
    raise exception 'record_trickplay: unexpected pack entry';
  end if;
  update public.asset_trickplay
     set state = 'done',
         object_key = p_row->>'key',
         bytes = (p_row->>'bytes')::bigint,
         interval_ms = (p_row->>'interval_ms')::integer,
         width = (p_row->>'width')::integer,
         height = (p_row->>'height')::integer,
         count = (p_row->>'count')::integer,
         codec = p_row->>'codec',
         note = left(p_note, 200),
         made_at = now()
   where asset_id = p_asset;
  get diagnostics n = row_count;
  -- The pack it replaces: to the bin for a week (grants made a moment ago
  -- may still name it), unless it is there already.
  if n = 1 and k.object_key is not null and k.object_key <> p_row->>'key' then
    insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
    select a.bucket, k.object_key, k.bytes, 'seek-bar pictures replaced by ' || (p_row->>'key'),
           now() + interval '7 days'
      from public.title_assets a
     where a.id = p_asset
       and not exists (select 1 from public.r2_trash t where t.bucket = a.bucket and t.key = k.object_key
                         and t.purged_at is null and t.restored_at is null);
  end if;
  return case when n = 1 then p_row->>'key' end;
end;
$$;

create or replace function public.trickplay_for(p_asset uuid)
returns table(object_key text, bytes bigint, interval_ms integer, width integer, height integer,
              count integer, codec text)
language sql
stable
security definer
set search_path = public
as $$
  select k.object_key, k.bytes, k.interval_ms, k.width, k.height, k.count, k.codec
    from public.asset_trickplay k
   where k.asset_id = p_asset
     and k.state = 'done'
     and k.object_key is not null
     and k.source_bytes = (select r.bytes from public.asset_renditions r
                            where r.asset_id = p_asset order by r.height limit 1);
$$;

revoke all on function public.trickplay_key(text, text) from public, anon, authenticated;
revoke all on function public.claim_trickplay(text, integer) from public, anon, authenticated;
revoke all on function public.record_trickplay(uuid, jsonb, text) from public, anon, authenticated;
revoke all on function public.trickplay_for(uuid) from public, anon, authenticated;
grant execute on function public.trickplay_key(text, text) to service_role;
grant execute on function public.claim_trickplay(text, integer) to service_role;
grant execute on function public.record_trickplay(uuid, jsonb, text) to service_role;
grant execute on function public.trickplay_for(uuid) to service_role;

-- r2_refs: as live on 20 Nov 2026 (071), and the packs.
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable security definer
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
    -- 083: the seek bar's pictures — the current pack only (trickplay_for's
    -- rule): one its film outgrew is stray, not kept for ever.
    select k.object_key, a.title_id, 'seek-bar pictures'
      from public.asset_trickplay k join public.title_assets a on a.id = k.asset_id
     where k.object_key is not null and k.state = 'done'
       and k.source_bytes = (select r.bytes from public.asset_renditions r
                              where r.asset_id = k.asset_id order by r.height limit 1)
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

-- r2_move_switch: as live on 20 Nov 2026 (073), and a moved pack re-pointed.
create or replace function public.r2_move_switch(p_id uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  a    record;
  m    public.r2_moves%rowtype;
  base text := public.public_asset_base();
  n    integer;
begin
  select ad.email, ad.role into a from public.admins ad
   where ad.user_id = p_actor and not ad.disabled;
  if a.role is distinct from 'owner' then return jsonb_build_object('error', 'not_owner'); end if;
  select * into m from public.r2_moves where id = p_id for update;
  if m.id is null then return jsonb_build_object('error', 'no_such_move'); end if;
  if m.state <> 'copying' then return jsonb_build_object('error', 'not_copying'); end if;
  if exists (select 1 from jsonb_array_elements(m.objects) o
              where coalesce((o->>'done')::boolean, false) is not true) then
    return jsonb_build_object('error', 'not_copied');
  end if;
  create temporary table r2_map on commit drop as
    select o->>'bucket' as bucket, o->>'from' as from_key, o->>'to' as to_key,
           nullif(o->>'bytes', '')::bigint as bytes
      from jsonb_array_elements(m.objects) o;
  update public.title_assets x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  update public.title_assets x set thumb_key = r.to_key
    from r2_map r where x.thumb_key = r.from_key;
  -- 073: the cover picker's stills.
  update public.title_assets x
     set frames = (
       select jsonb_agg(case when r.to_key is not null
                             then jsonb_set(f, '{key}', to_jsonb(r.to_key)) else f end
                        order by ord)
         from jsonb_array_elements(x.frames) with ordinality as e(f, ord)
         left join r2_map r on r.from_key = f->>'key')
   where x.frames is not null and jsonb_typeof(x.frames) = 'array'
     and exists (select 1 from jsonb_array_elements(x.frames) f
                   join r2_map r on r.from_key = f->>'key');
  update public.asset_renditions x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  -- 083: the seek bar's pictures, and the rung they were made from.
  update public.asset_trickplay x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  update public.asset_trickplay x set source_key = r.to_key
    from r2_map r where x.source_key = r.from_key;
  update public.asset_trickplay x set pack_key = r.to_key
    from r2_map r where x.pack_key = r.from_key;
  update public.ingest_jobs x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  update public.titles x set locator = r.to_key
    from r2_map r where x.locator = r.from_key;
  update public.titles x set poster_url = base || r.to_key
    from r2_map r where x.poster_url = base || r.from_key;
  -- 073: the twins follow their files.
  update public.media_keys k set plain_key = r.to_key
    from r2_map r where k.bucket = r.bucket and k.plain_key = r.from_key;
  update public.media_image_keys k set plain_key = r.to_key
    from r2_map r where k.bucket = r.bucket and k.plain_key = r.from_key;
  if m.mode = 'folder' then
    update public.titles set slug = m.to_folder where slug = m.from_folder;
    update public.r2_folder_labels set folder = m.to_folder where folder = m.from_folder;
  else
    update public.titles set slug = m.to_folder where id = m.title_id;
  end if;
  insert into public.r2_inventory (bucket, key, bytes, modified, scan)
  select r.bucket, r.to_key, coalesce(r.bytes, i.bytes, 0), now(),
         coalesce(i.scan, gen_random_uuid())
    from r2_map r
    left join public.r2_inventory i on i.bucket = r.bucket and i.key = r.from_key
  on conflict (bucket, key) do nothing;
  insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email, purge_after)
  select r.bucket, r.from_key, r.bytes, 'moved to ' || r.to_key, p_actor, a.email,
         now() + interval '7 days'
    from r2_map r
   where not exists (select 1 from public.r2_trash t where t.bucket = r.bucket
                       and t.key = r.from_key and t.purged_at is null and t.restored_at is null);
  get diagnostics n = row_count;
  update public.r2_moves set state = 'switched', switched_at = now() where id = p_id;
  return jsonb_build_object('switched', jsonb_array_length(m.objects), 'binned', n);
end;
$function$;
