-- 028 — the Files page: what is in R2, who uses it, a bin, and moves
--
-- WHAT THE OPERATOR ASKED FOR. See the bucket by folder; for every file, its
-- size, which title uses it, where it came from and what it costs; rename and
-- move folders; delete what nothing uses — without R2 swelling with files
-- nobody can see, and without breaking a film somebody is watching.
--
-- THE HARD PART IS THAT R2 HAS NO RENAME. A "folder" is the front of each
-- file's key, and every key is written down in the database: title_assets
-- (the file and its thumbnail), asset_renditions (the streaming copies),
-- titles.locator and titles.poster_url (copies of those), ingest_jobs (what
-- came from Telegram) and titles.slug (the folder itself). Moving files in R2
-- without changing all of those at once is how a film stops playing. So a
-- move here is five steps:
--
--   1. copy   every file to its new key, inside R2 (no phone data used)
--   2. check  the copy is the size of the original
--   3. switch every reference, in ONE transaction (r2_move_switch)
--   4. keep   the old files seven days — an app holding an old poster URL
--             in its cache still finds the picture
--   5. delete them after that, from the bin
--
-- THE BIN. Nothing here deletes a file at once. A delete puts it in the bin
-- for seven days (R2 has no recycle bin; this is the only undo there is), and
-- a file any title still uses cannot be put there at all — checked when it is
-- binned AND again when the bin is emptied.
--
-- THE INVENTORY. Listing a bucket a thousand keys at a time on every visit to
-- the page would be slow on a phone and grows with the catalogue, so the
-- console keeps a copy of the listing (r2_inventory), refreshed by a scan the
-- page runs. Everything the page shows about sizes and costs reads it.

-- ---------------------------------------------------------------------------
-- the inventory
-- ---------------------------------------------------------------------------
create table if not exists public.r2_inventory (
  bucket   text not null,
  key      text not null,
  bytes    bigint not null default 0,
  modified timestamptz,
  scan     uuid not null,
  seen_at  timestamptz not null default now(),
  primary key (bucket, key)
);
create table if not exists public.r2_scans (
  bucket      text primary key,
  scan        uuid,
  started_at  timestamptz,
  finished_at timestamptz,
  objects     integer,
  bytes       bigint
);

-- One page of a listing. The first page of a new scan marks it started.
create or replace function public.inventory_upsert(p_bucket text, p_scan uuid, p_rows jsonb)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  insert into public.r2_scans (bucket, scan, started_at)
  values (p_bucket, p_scan, now())
  on conflict (bucket) do update
    set started_at = case when public.r2_scans.scan is distinct from excluded.scan
                          then now() else public.r2_scans.started_at end,
        scan = excluded.scan;
  insert into public.r2_inventory (bucket, key, bytes, modified, scan, seen_at)
  select p_bucket, r->>'key', coalesce((r->>'bytes')::bigint, 0),
         nullif(r->>'modified', '')::timestamptz, p_scan, now()
    from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
   where coalesce(r->>'key', '') <> ''
  on conflict (bucket, key) do update
    set bytes = excluded.bytes, modified = excluded.modified,
        scan = excluded.scan, seen_at = excluded.seen_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- The last page: whatever this scan did not see is no longer in the bucket.
create or replace function public.inventory_finish(p_bucket text, p_scan uuid)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare n integer;
begin
  delete from public.r2_inventory where bucket = p_bucket and scan <> p_scan;
  get diagnostics n = row_count;
  update public.r2_scans s
     set finished_at = now(),
         objects = (select count(*) from public.r2_inventory i where i.bucket = p_bucket),
         bytes = (select coalesce(sum(bytes), 0) from public.r2_inventory i where i.bucket = p_bucket)
   where s.bucket = p_bucket;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- which folder a key is in, and who uses it
-- ---------------------------------------------------------------------------
--
-- A key is <folder>/<video|photo|thumb>/<name>, the folder up to three
-- levels deep. The old flat keys from before foldering (`v/…`, `p/…`) and
-- anything else fall back to their first segment, so they still group.
-- tool/js/files_test.mjs checks studio.ts's copy of this rule agrees.
create or replace function public.r2_folder_of(p_key text)
returns text
language sql
immutable
as $$
  select coalesce(
    substring(p_key from '^(.*)/(?:video|photo|thumb)/[^/]+$'),
    case when position('/' in coalesce(p_key, '')) > 0
         then split_part(p_key, '/', 1) else '' end);
$$;

-- Every key the catalogue points at, and through what. `poster` and the
-- titles' own `locator` are included on purpose: they are copies the app
-- reads, and a key only they mention is still a key in use.
create or replace function public.r2_refs()
returns table(key text, title_id uuid, how text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select a.object_key, a.title_id, 'file'::text from public.title_assets a
   where a.object_key is not null
  union all
  select a.thumb_key, a.title_id, 'thumbnail' from public.title_assets a
   where a.thumb_key is not null
  union all
  select r.object_key, a.title_id, 'streaming copy'
    from public.asset_renditions r join public.title_assets a on a.id = r.asset_id
  union all
  select t.locator, t.id, 'file' from public.titles t where coalesce(t.locator, '') <> ''
  union all
  select substr(t.poster_url, length(public.public_asset_base()) + 1), t.id, 'cover'
    from public.titles t
   where t.poster_url like public.public_asset_base() || '%'
  union all
  select j.object_key, j.title_id, 'telegram inbox' from public.ingest_jobs j
   where j.title_id is null;
$$;

create table if not exists public.r2_folder_labels (
  folder     text primary key,
  label      text not null,
  updated_by uuid,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- the bin
-- ---------------------------------------------------------------------------
create table if not exists public.r2_trash (
  id              bigint generated always as identity primary key,
  bucket          text not null,
  key             text not null,
  bytes           bigint,
  reason          text,
  requested_by    uuid,
  requested_email text,
  requested_at    timestamptz not null default now(),
  purge_after     timestamptz not null,
  restored_at     timestamptz,
  restored_by     uuid,
  purged_at       timestamptz,
  purge_error     text
);
create unique index if not exists r2_trash_pending
  on public.r2_trash (bucket, key) where purged_at is null and restored_at is null;

-- ---------------------------------------------------------------------------
-- moves
-- ---------------------------------------------------------------------------
--
-- `objects` is the plan: [{bucket, from, to, bytes, done}], one per file,
-- with a multipart copy's progress folded in for a file over 5 GB.
create table if not exists public.r2_moves (
  id              uuid primary key default gen_random_uuid(),
  mode            text not null check (mode in ('folder', 'title')),
  from_folder     text,
  to_folder       text not null,
  title_id        uuid,
  state           text not null default 'copying'
                  check (state in ('copying', 'switched', 'cancelled', 'failed')),
  objects         jsonb not null,
  requested_by    uuid,
  requested_email text,
  created_at      timestamptz not null default now(),
  switched_at     timestamptz,
  note            text
);

do $$
declare t text;
begin
  foreach t in array array['r2_inventory', 'r2_scans', 'r2_folder_labels', 'r2_trash', 'r2_moves'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on public.%I to service_role', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- what the Files page reads
-- ---------------------------------------------------------------------------

-- One row per folder: how much, how much of it nothing uses, how much is in
-- the bin, and the title that owns it (titles.slug).
create or replace function public.files_summary()
returns table(folder text, files integer, bytes bigint, unused_files integer,
              unused_bytes bigint, bin_bytes bigint, media_bytes bigint,
              title_id uuid, title text, label text, newest timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  with refs as materialized (select distinct key from public.r2_refs()),
  bin as materialized (
    select bucket, key from public.r2_trash where purged_at is null and restored_at is null),
  inv as (
    select i.*, public.r2_folder_of(i.key) as f,
           exists (select 1 from refs r where r.key = i.key) as used,
           exists (select 1 from bin b where b.bucket = i.bucket and b.key = i.key) as binned
      from public.r2_inventory i)
  select inv.f,
         count(*)::integer,
         sum(inv.bytes)::bigint,
         count(*) filter (where not inv.used and not inv.binned)::integer,
         coalesce(sum(inv.bytes) filter (where not inv.used and not inv.binned), 0)::bigint,
         coalesce(sum(inv.bytes) filter (where inv.binned), 0)::bigint,
         coalesce(sum(inv.bytes) filter (where inv.key ~ '(^|/)(video|v)/'), 0)::bigint,
         (select t.id from public.titles t where t.slug = inv.f limit 1),
         (select t.title from public.titles t where t.slug = inv.f limit 1),
         (select l.label from public.r2_folder_labels l where l.folder = inv.f),
         max(inv.modified)
    from inv
   group by inv.f
   order by sum(inv.bytes) desc;
$$;

-- The files of one folder, each with who uses it and where it came from.
create or replace function public.files_list(p_folder text)
returns table(bucket text, key text, bytes bigint, modified timestamptz,
              used_by uuid, used_title text, how text, source text,
              bin_id bigint, purge_after timestamptz)
language sql
stable
security definer
set search_path to 'public'
as $$
  with refs as materialized (select * from public.r2_refs())
  select i.bucket, i.key, i.bytes, i.modified,
         r.title_id, t.title, r.how,
         case
           when exists (select 1 from public.ingest_jobs j where j.object_key = i.key) then 'telegram'
           when exists (select 1 from public.asset_renditions x where x.object_key = i.key) then 'streaming copy'
           when i.key like '\_selftest/%' then 'bucket check'
           else 'upload'
         end,
         b.id, b.purge_after
    from public.r2_inventory i
    left join lateral (
      select rr.title_id, rr.how from refs rr where rr.key = i.key
       order by (rr.how = 'telegram inbox') limit 1) r on true
    left join public.titles t on t.id = r.title_id
    left join public.r2_trash b
      on b.bucket = i.bucket and b.key = i.key and b.purged_at is null and b.restored_at is null
   where public.r2_folder_of(i.key) = p_folder
   order by i.key;
$$;

-- A display name for a folder: shown on the Files page, moves nothing.
create or replace function public.folder_label_set(p_folder text, p_label text, p_actor uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare v text := nullif(btrim(coalesce(p_label, '')), '');
begin
  if coalesce(btrim(p_folder), '') = '' then return 'no_folder'; end if;
  if v is null then
    delete from public.r2_folder_labels where folder = p_folder;
    return 'cleared';
  end if;
  insert into public.r2_folder_labels (folder, label, updated_by, updated_at)
  values (p_folder, left(v, 120), p_actor, now())
  on conflict (folder) do update
    set label = excluded.label, updated_by = excluded.updated_by, updated_at = now();
  return 'saved';
end;
$$;

-- ---------------------------------------------------------------------------
-- the bin, in and out
-- ---------------------------------------------------------------------------

-- Owner only — checked here as well as in the edge function. A key anything
-- uses is refused, by name; the rest go in for p_days (seven, unless a move
-- or a cancelled copy says nought).
create or replace function public.r2_trash_add(
  p_items jsonb, p_actor uuid, p_reason text, p_days integer default 7
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a        record;
  it       record;
  added    integer := 0;
  refused  jsonb := '[]'::jsonb;
begin
  select ad.email, ad.role into a from public.admins ad
   where ad.user_id = p_actor and not ad.disabled;
  if a.role is distinct from 'owner' then
    return jsonb_build_object('error', 'not_owner');
  end if;
  for it in select x->>'bucket' as bucket, x->>'key' as key
              from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) x loop
    if coalesce(it.key, '') = '' or coalesce(it.bucket, '') = '' then continue; end if;
    if exists (select 1 from public.r2_refs() r where r.key = it.key) then
      refused := refused || jsonb_build_object('key', it.key, 'why', 'in_use');
      continue;
    end if;
    if exists (select 1 from public.r2_trash t where t.bucket = it.bucket and t.key = it.key
                 and t.purged_at is null and t.restored_at is null) then
      continue;
    end if;
    insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email, purge_after)
    values (it.bucket, it.key,
            (select i.bytes from public.r2_inventory i where i.bucket = it.bucket and i.key = it.key),
            p_reason, p_actor, a.email, now() + make_interval(days => greatest(p_days, 0)));
    added := added + 1;
  end loop;
  return jsonb_build_object('added', added, 'refused', refused);
end;
$$;

create or replace function public.r2_trash_restore(p_id bigint, p_actor uuid)
returns text
language plpgsql
security definer
set search_path to 'public'
as $$
declare r text;
begin
  select ad.role into r from public.admins ad where ad.user_id = p_actor and not ad.disabled;
  if r is distinct from 'owner' then return 'not_owner'; end if;
  update public.r2_trash set restored_at = now(), restored_by = p_actor
   where id = p_id and purged_at is null and restored_at is null;
  if not found then return 'not_in_bin'; end if;
  return 'restored';
end;
$$;

-- For the runner that empties the bin: what is due. CHECKED AGAIN HERE — a
-- file binned a week ago and attached to a title since must not be deleted,
-- so one that is in use again is taken back out of the bin instead.
create or replace function public.r2_trash_due(p_limit integer default 200)
returns table(id bigint, bucket text, key text)
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  update public.r2_trash t
     set restored_at = now(), purge_error = 'in use again — kept'
   where t.purged_at is null and t.restored_at is null and t.purge_after <= now()
     and exists (select 1 from public.r2_refs() r where r.key = t.key);
  return query
    select t.id, t.bucket, t.key from public.r2_trash t
     where t.purged_at is null and t.restored_at is null and t.purge_after <= now()
     order by t.purge_after
     limit greatest(p_limit, 0);
end;
$$;

create or replace function public.r2_trash_done(p_id bigint, p_error text default null)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if p_error is null then
    update public.r2_trash set purged_at = now(), purge_error = null where id = p_id;
    delete from public.r2_inventory i
     using public.r2_trash t where t.id = p_id and i.bucket = t.bucket and i.key = t.key;
  else
    update public.r2_trash set purge_error = left(p_error, 300) where id = p_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- moves
-- ---------------------------------------------------------------------------

-- Records a move the edge function has planned (it lists R2 to find the
-- files; this checks the plan). Owner only. Answers {id} or {error}.
create or replace function public.r2_move_create(
  p_actor uuid, p_mode text, p_from text, p_to text, p_title uuid, p_objects jsonb
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a    record;
  v_id uuid;
begin
  select ad.email, ad.role into a from public.admins ad
   where ad.user_id = p_actor and not ad.disabled;
  if a.role is distinct from 'owner' then return jsonb_build_object('error', 'not_owner'); end if;
  if p_mode not in ('folder', 'title') then return jsonb_build_object('error', 'bad_mode'); end if;
  if coalesce(p_to, '') !~ '^[a-z0-9]+(-[a-z0-9]+)*(/[a-z0-9]+(-[a-z0-9]+)*){0,2}$' then
    return jsonb_build_object('error', 'bad_folder');
  end if;
  if p_mode = 'folder' and (coalesce(p_from, '') = '' or p_from = p_to) then
    return jsonb_build_object('error', 'same_folder');
  end if;
  -- THE NEW FOLDER IS FREE: no other title is called that, and nothing is
  -- in it — unless it is a title being tidied into its own folder.
  if exists (select 1 from public.titles t where t.slug = p_to
               and (p_mode = 'folder' or t.id is distinct from p_title)) then
    return jsonb_build_object('error', 'folder_taken');
  end if;
  if p_mode = 'folder' and exists (
       select 1 from public.r2_inventory i where public.r2_folder_of(i.key) = p_to) then
    return jsonb_build_object('error', 'folder_not_empty');
  end if;
  if exists (select 1 from public.r2_moves m where m.state = 'copying'
               and (m.from_folder = p_from or m.to_folder = p_to
                    or (p_title is not null and m.title_id = p_title))) then
    return jsonb_build_object('error', 'move_in_progress');
  end if;
  if jsonb_array_length(coalesce(p_objects, '[]'::jsonb)) = 0 then
    return jsonb_build_object('error', 'nothing_to_move');
  end if;
  if exists (select 1 from jsonb_array_elements(p_objects) o
               join public.r2_refs() r on r.key = o->>'to') then
    return jsonb_build_object('error', 'destination_in_use');
  end if;
  insert into public.r2_moves (mode, from_folder, to_folder, title_id, objects,
                               requested_by, requested_email)
  values (p_mode, p_from, p_to, p_title, p_objects, p_actor, a.email)
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end;
$$;

-- One file's progress in a move: `done`, or a multipart copy's state.
create or replace function public.r2_move_progress(p_id uuid, p_index integer, p_patch jsonb)
returns void
language sql
security definer
set search_path to 'public'
as $$
  update public.r2_moves
     set objects = jsonb_set(objects, array[p_index::text],
                             (objects -> p_index) || coalesce(p_patch, '{}'::jsonb))
   where id = p_id and state = 'copying';
$$;

-- THE SWITCH. Every reference to every moved key changes in this one
-- transaction, by EXACT key — never by a blind replace of a prefix, which
-- would also rewrite `movies/solar-2` while moving `movies/solar`. Then the
-- old files go in the bin for seven days.
create or replace function public.r2_move_switch(p_id uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
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
  update public.asset_renditions x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  update public.ingest_jobs x set object_key = r.to_key
    from r2_map r where x.object_key = r.from_key;
  update public.titles x set locator = r.to_key
    from r2_map r where x.locator = r.from_key;
  update public.titles x set poster_url = base || r.to_key
    from r2_map r where x.poster_url = base || r.from_key;

  if m.mode = 'folder' then
    update public.titles set slug = m.to_folder where slug = m.from_folder;
    update public.r2_folder_labels set folder = m.to_folder where folder = m.from_folder;
  else
    update public.titles set slug = m.to_folder where id = m.title_id;
  end if;

  -- The new keys are in the bucket now; say so, so the page shows them
  -- before its next scan.
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
$$;

-- Stop a move before the switch. Nothing points at the copies made so far,
-- so they go in the bin to be deleted at the next emptying.
create or replace function public.r2_move_cancel(p_id uuid, p_actor uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  a record;
  m public.r2_moves%rowtype;
begin
  select ad.email, ad.role into a from public.admins ad
   where ad.user_id = p_actor and not ad.disabled;
  if a.role is distinct from 'owner' then return jsonb_build_object('error', 'not_owner'); end if;
  select * into m from public.r2_moves where id = p_id for update;
  if m.id is null or m.state <> 'copying' then
    return jsonb_build_object('error', 'not_copying');
  end if;
  insert into public.r2_trash (bucket, key, bytes, reason, requested_by, requested_email, purge_after)
  select o->>'bucket', o->>'to', nullif(o->>'bytes', '')::bigint, 'cancelled move', p_actor, a.email, now()
    from jsonb_array_elements(m.objects) o
   where coalesce((o->>'done')::boolean, false)
     and not exists (select 1 from public.r2_refs() r where r.key = o->>'to')
     and not exists (select 1 from public.r2_trash t where t.bucket = o->>'bucket'
                       and t.key = o->>'to' and t.purged_at is null and t.restored_at is null);
  update public.r2_moves set state = 'cancelled' where id = p_id;
  return jsonb_build_object('cancelled', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.inventory_upsert(text, uuid, jsonb)',
    'public.inventory_finish(text, uuid)',
    'public.r2_refs()',
    'public.files_summary()',
    'public.files_list(text)',
    'public.folder_label_set(text, text, uuid)',
    'public.r2_trash_add(jsonb, uuid, text, integer)',
    'public.r2_trash_restore(bigint, uuid)',
    'public.r2_trash_due(integer)',
    'public.r2_trash_done(bigint, text)',
    'public.r2_move_create(uuid, text, text, text, uuid, jsonb)',
    'public.r2_move_progress(uuid, integer, jsonb)',
    'public.r2_move_switch(uuid, uuid)',
    'public.r2_move_cancel(uuid, uuid)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
