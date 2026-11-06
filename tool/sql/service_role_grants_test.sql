-- What the edge functions do as the service role, they may do   (migration 077)
--
-- Run inside one transaction that ends on a deliberate exception, so nothing
-- it creates survives. Success is the message `SERVICE ROLE GRANTS TEST
-- PASSED`; any other exception names the case that failed.
--
-- WHY. A new table here gives the service role nothing, and supabase-js
-- hands a refusal back as data the caller may never look at: the console's
-- Genres section and every genre change failed for a week (058) before a
-- seed run met it. So, as the service role:
--   1. every table the functions name can be read (tool/check.py checks
--      this list against docs/edge, so a new name has to be added here);
--   2. a title is made with genre words, and they become codes;
--   3. its genre codes are changed, as the console's editor does;
--   4. a genre and a category could be added, as the Categories page does;
--   5. the console's listings of genres and of a film's rungs answer.
do $$
declare
  rel   text;
  t     uuid;
  codes text[];
  g     text;
  n     integer;
begin
  set local role service_role;

  -- ── 1. every table the functions name ───────────────────────────────────
  -- FUNCTION_TABLES (keep sorted; tool/check.py reads this list)
  foreach rel in array array[
    'admin_audit', 'admin_requests', 'admin_settings', 'admins',
    'asset_renditions', 'catalogue_health', 'categories', 'db_backups',
    'devices', 'event_geo', 'events', 'genres', 'ingest_jobs',
    'media_health', 'media_image_keys', 'media_keys', 'media_upload_keys',
    'offsite_jobs', 'payment_instructions', 'pending_requests', 'premium_requests',
    'r2_moves', 'r2_scans', 'r2_trash', 'search_gaps', 'subscriptions',
    'title_assets', 'title_reviews', 'titles', 'vault_jobs'
  ] loop
    begin
      execute format('select 1 from public.%I limit 1', rel);
    exception when insufficient_privilege then
      raise exception 'the service role cannot read %', rel;
    end;
  end loop;

  -- ── 2. a title made with genre words ────────────────────────────────────
  insert into public.titles (title, category, genres, slug, access_tier, provider,
                             locator, status, published)
  values ('Grants test', 'movies', array['Open Movie'], 'open-film-grants-test',
          'free', 'r2', 'video/open-film-grants-test/master.mp4', 'draft', false)
  returning id, genre_codes into t, codes;
  if coalesce(cardinality(codes), 0) = 0 then
    raise exception 'genre words were not turned into codes: %', codes;
  end if;

  -- ── 3. its genres changed by code ───────────────────────────────────────
  select code into g from public.genres where retired_at is null and code <> codes[1]
   order by sort_order limit 1;
  if g is not null then
    update public.titles set genre_codes = array[codes[1], g] where id = t
    returning genre_codes into codes;
    if cardinality(codes) <> 2 then raise exception 'genre codes not saved: %', codes; end if;
  end if;

  -- ── 4. a genre and a category can be added ──────────────────────────────
  -- Asked, not done: a code drawn here would be spent even though the
  -- transaction rolls back (a sequence is not transactional), and a category
  -- has only 99 codes.
  -- One privilege per call: given a list, has_table_privilege answers true
  -- when ANY of them is held.
  if not (has_table_privilege('public.genres', 'INSERT') and
          has_table_privilege('public.genres', 'UPDATE') and
          has_table_privilege('public.genres', 'DELETE')) then
    raise exception 'the service role cannot add, rename or remove a genre';
  end if;
  if not has_sequence_privilege('public.genre_code_seq', 'USAGE') then
    raise exception 'a new genre could not draw its code';
  end if;
  if not (has_table_privilege('public.categories', 'INSERT') and
          has_table_privilege('public.categories', 'UPDATE')) then
    raise exception 'the service role cannot add or change a category';
  end if;
  if not has_sequence_privilege('public.category_code_seq', 'USAGE') then
    raise exception 'a new category could not draw its code';
  end if;

  -- ── 5. the console's listings ───────────────────────────────────────────
  select count(*) into n from public.genres;
  if n < 2 then raise exception 'genres listed % rows', n; end if;
  select count(*) into n from public.asset_renditions;
  if n = 0 then raise exception 'no rendition is readable (the ladder exists for open films)'; end if;

  raise exception 'SERVICE ROLE GRANTS TEST PASSED';
end $$;
