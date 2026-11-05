-- 073 — the Files page keeps the key rows in step (docs/MEDIA_ENCRYPTION.md
-- §7.3, ENC-4 step 5).
--
-- 1. A MOVE RE-POINTS THE TWINS. `r2_move_switch` rewrites every reference
--    to a moved file from its old key to its new one; the key rows of its
--    sealed twins named the old key, so a twin moved with nothing and
--    became "a twin of a file that is gone" — the app, asking for the film
--    by its new key, found no sealed copy, and the purge a week later would
--    have left the twin behind for ever. Now `plain_key` follows the file.
--    (The sealed objects themselves do not move: `s/<32 hex>` is in no
--    folder, and the AAD names the dek_id, not the path.)
--
--    AND THE COVER PICKER'S STILLS. A move also rewrote `thumb_key` but not
--    the ten keys in `title_assets.frames` (migration 043): after a folder
--    move the stills were copied, the old ones binned, and the picker
--    pointed at the old ones — gone a week later. They follow too.
--
-- 2. A DELETED FILE TAKES ITS TWIN WITH IT. When the bin's purge deletes a
--    plain object, a twin that nothing else names (r2_refs, which counts a
--    master kept in Telegram — its twin stays) loses its key row and goes to
--    the bin for a day. Before, it stayed in R2 under a row that named a
--    plain object that was gone.

-- ── 1 ───────────────────────────────────────────────────────────────────────
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
  twin     record;
begin
  if p_error is null then
    update public.r2_trash set purged_at = now(), purge_error = null where id = p_id
    returning bucket, key into v_bucket, v_key;
    delete from public.r2_inventory i where i.bucket = v_bucket and i.key = v_key;
    if coalesce(v_key, '') ~ '^s/[0-9a-f]{32}$' then
      -- 071: the key rows of a sealed object that is gone.
      delete from public.media_keys k where k.bucket = v_bucket and k.sealed_key = v_key;
      delete from public.media_image_keys k where k.bucket = v_bucket and k.sealed_key = v_key;
    elsif v_key is not null then
      -- 073: a plain object that is gone takes the twins nothing else names.
      for twin in
        delete from public.media_keys k
         where k.bucket = v_bucket and k.plain_key = v_key
           and not exists (select 1 from public.r2_refs() r where r.key = k.sealed_key)
        returning k.sealed_key, k.sealed_size
      loop
        insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
        values (v_bucket, twin.sealed_key, twin.sealed_size,
                'sealed copy of a deleted file', now() + interval '1 day')
        on conflict do nothing;
      end loop;
      for twin in
        delete from public.media_image_keys k
         where k.bucket = v_bucket and k.plain_key = v_key
           and not exists (select 1 from public.r2_refs() r where r.key = k.sealed_key)
        returning k.sealed_key, k.sealed_size
      loop
        insert into public.r2_trash (bucket, key, bytes, reason, purge_after)
        values (v_bucket, twin.sealed_key, twin.sealed_size,
                'sealed copy of a deleted file', now() + interval '1 day')
        on conflict do nothing;
      end loop;
    end if;
  else
    update public.r2_trash set purge_error = left(p_error, 300) where id = p_id;
  end if;
end;
$function$;

revoke all on function public.r2_move_switch(uuid, uuid) from public, anon, authenticated;
grant execute on function public.r2_move_switch(uuid, uuid) to service_role;
revoke all on function public.r2_trash_done(bigint, text) from public, anon, authenticated;
grant execute on function public.r2_trash_done(bigint, text) to service_role;
