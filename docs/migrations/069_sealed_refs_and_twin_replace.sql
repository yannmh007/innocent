-- 069 — a sealed object is a file in use, and a twin follows its object
-- (docs/MEDIA_ENCRYPTION.md §7.2).
--
-- 1. THE FILES PAGE SEES SEALED OBJECTS AS IN USE. Every `s/<32 hex>` named
--    by a key row (media_keys, media_image_keys) is in `r2_refs()`, as
--    "sealed copy". Without this the next Files → Scan lists them all as
--    unused, "empty unused" bins them, and the purge deletes them a week
--    later: for a twin, the encrypted copy; for an object born sealed, the
--    only copy there is. The bin's own purge checks `r2_refs()` again, so a
--    sealed object binned by mistake comes back out ("in use again — kept").
--
-- 2. ONE TWIN PER PLAIN OBJECT, in films as in images. media_image_keys has
--    had `unique (bucket, plain_key)` since 063; media_keys gains it.
--    (NULL plain keys — objects born sealed — are distinct, as before.)
--
-- 3. `media_key_put(kind, row)`: how a pipeline records a sealed object it
--    made. When the plain object at that key already has a twin, the
--    pipeline has just MADE THAT OBJECT AGAIN (a rung re-encoded, the ten
--    stills taken again), so the old twin is stale: its row is replaced by
--    the new one in the same transaction, and its sealed object goes to the
--    bin for seven days (a phone that holds a grant for it can still finish
--    the film; the purge then deletes it, unless something names it again).
--    A row already there with the same dek_id is kept as it is: `done` is
--    called after every rung and repeats the ones before.
--
--    The row was checked by media_issue.js `record` (the wrap is the
--    function's for this dek_id, the sizes, the header, the first and last
--    segments open) before it gets here; this only keeps the tables in step.
--    Service role only.

-- ── 2 ───────────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.media_keys'::regclass
                    and conname = 'media_keys_bucket_plain_key_key') then
    alter table public.media_keys
      add constraint media_keys_bucket_plain_key_key unique (bucket, plain_key);
  end if;
end $$;

-- ── 1 ───────────────────────────────────────────────────────────────────────
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select a.object_key, a.title_id, 'file'::text from public.title_assets a
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
  union all
  -- 069: every sealed object a key row names. The title is the one whose
  -- file or streaming copy the twin is of, when there is one.
  select k.sealed_key,
         coalesce((select a.title_id from public.title_assets a
                    where a.object_key in (k.plain_key, k.sealed_key) limit 1),
                  (select a.title_id from public.asset_renditions r
                     join public.title_assets a on a.id = r.asset_id
                    where r.object_key in (k.plain_key, k.sealed_key) limit 1)),
         'sealed copy'
    from public.media_keys k
  union all
  select k.sealed_key,
         (select a.title_id from public.title_assets a
           where a.thumb_key in (k.plain_key, k.sealed_key)
              or a.object_key in (k.plain_key, k.sealed_key) limit 1),
         'sealed copy'
    from public.media_image_keys k;
$function$;

-- ── 3 ───────────────────────────────────────────────────────────────────────
create or replace function public.media_key_put(p_kind text, p_row jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id     uuid := (p_row->>'dek_id')::uuid;
  v_bucket text := p_row->>'bucket';
  v_plain  text := nullif(p_row->>'plain_key', '');
  old      record;
  replaced jsonb := '[]'::jsonb;
begin
  if p_kind not in ('video', 'image') then
    raise exception 'media_key_put: kind % is neither video nor image', p_kind;
  end if;
  if v_id is null or coalesce(v_bucket, '') = '' or coalesce(p_row->>'sealed_key', '') !~ '^s/[0-9a-f]{32}$' then
    raise exception 'media_key_put: a row without its dek_id, bucket or sealed key';
  end if;

  -- Already recorded: `done` repeats the rungs before.
  if (p_kind = 'video' and exists (select 1 from public.media_keys where dek_id = v_id))
     or (p_kind = 'image' and exists (select 1 from public.media_image_keys where dek_id = v_id)) then
    return jsonb_build_object('recorded', true, 'kept', true, 'replaced', replaced);
  end if;

  -- The plain object was made again: its old twin goes, row and object.
  if v_plain is not null then
    if p_kind = 'video' then
      for old in delete from public.media_keys
                  where bucket = v_bucket and plain_key = v_plain
                  returning sealed_key, sealed_size loop
        insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
        values (v_bucket, old.sealed_key, old.sealed_size,
                'sealed copy replaced: its film was made again', now() + interval '7 days')
        on conflict do nothing;
        replaced := replaced || to_jsonb(old.sealed_key);
      end loop;
    else
      for old in delete from public.media_image_keys
                  where bucket = v_bucket and plain_key = v_plain
                  returning sealed_key, sealed_size loop
        insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
        values (v_bucket, old.sealed_key, old.sealed_size,
                'sealed copy replaced: its picture was made again', now() + interval '7 days')
        on conflict do nothing;
        replaced := replaced || to_jsonb(old.sealed_key);
      end loop;
    end if;
  end if;

  if p_kind = 'video' then
    insert into public.media_keys
      (dek_id, bucket, sealed_key, plain_key, kek_version, wrapped, plain_size, sealed_size, kind, header)
    values
      (v_id, v_bucket, p_row->>'sealed_key', v_plain,
       coalesce((p_row->>'kek_version')::smallint, 1), p_row->>'wrapped',
       (p_row->>'plain_size')::bigint, (p_row->>'sealed_size')::bigint,
       coalesce(p_row->>'kind', 'video'), p_row->>'header');
  else
    insert into public.media_image_keys
      (dek_id, bucket, plain_key, sealed_key, dek, header, plain_size, sealed_size)
    values
      (v_id, v_bucket, v_plain, p_row->>'sealed_key', p_row->>'dek', p_row->>'header',
       (p_row->>'plain_size')::bigint, (p_row->>'sealed_size')::bigint);
  end if;
  return jsonb_build_object('recorded', true, 'kept', false, 'replaced', replaced);
end;
$function$;

revoke all on function public.media_key_put(text, jsonb) from public, anon, authenticated;
grant execute on function public.media_key_put(text, jsonb) to service_role;
