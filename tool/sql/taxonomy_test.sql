-- Category and genre codes   (migration 058)
--
-- Run after the migration, inside the one transaction that applies it, and
-- end on a deliberate exception so nothing survives (the migration
-- included). Success is the message `TAXONOMY TEST PASSED`; any other
-- exception names the case that failed.
--
-- The cases that matter most are the quiet ones: an old writer that still
-- sends words getting codes behind its back, a rename reaching every title
-- and the search, a code given twice, a genre in use deleted, and the
-- reader's view of titles still opening for anon once it has two new
-- columns.
do $$
declare
  sintel uuid := '0839dacb-59ae-4c95-9279-4901b925965d';
  tears  uuid := 'ab8b0f1e-e23b-4141-94ba-67f1b29a7765';
  v      text;
  a      text[];
  j      jsonb;
  n      integer;
  thr    text;
  w      text;
  blocked boolean;
begin
  -- ── the codes the migration gave ───────────────────────────────────────
  select string_agg(id || '=' || code, ',' order by code) into v from public.categories;
  if v not like 'all=C00,movies=C01,series=C02,reels=C03%' then
    raise exception 'category codes: %', v;
  end if;
  select code into v from public.genres where label = 'Open Movie';
  if v <> 'G001' then raise exception 'the most used genre is %, not G001', v; end if;
  select genre_codes into a from public.titles where id = sintel;
  if a <> (select array_agg(code order by array_position(array['Animation','Fantasy'], label))
             from public.genres where label in ('Animation', 'Fantasy')) then
    raise exception 'Sintel''s genre codes: %', a;
  end if;
  if exists (select 1 from public.titles where category_code is null) then
    raise exception 'a title has no category code';
  end if;

  -- ── an old writer sends words: codes follow, a new word is a new genre ──
  update public.titles set genres = array['Fantasy', ' thriller ', 'fantasy'] where id = sintel;
  select code into thr from public.genres where lower(label) = 'thriller';
  if thr is null then raise exception 'a new word made no genre'; end if;
  if thr !~ '^G[0-9]{3}$' or thr <= 'G003' then raise exception 'the new genre''s code is %', thr; end if;
  select genre_codes, genres into a, v from public.titles where id = sintel;
  if cardinality(a) <> 2 or a[2] <> thr then
    raise exception 'words to codes: % (each once, in order)', a;
  end if;

  -- ── a new writer sends codes: the words follow ─────────────────────────
  update public.titles set genre_codes = array['G001', thr, 'G001'] where id = sintel;
  select genres into a from public.titles where id = sintel;
  if a <> array['Open Movie', 'thriller'] then raise exception 'codes to words: %', a; end if;
  blocked := false;
  begin
    update public.titles set genre_codes = array['G999'] where id = sintel;
  exception when foreign_key_violation then blocked := true;
  end;
  if not blocked then raise exception 'an unknown genre code was taken'; end if;

  -- ── a rename reaches every title that has it, and the search ───────────
  update public.genres set label = 'Thriller', label_mm = 'သည်းထိတ်ရင်ဖို' where code = thr;
  select genres into a from public.titles where id = sintel;
  if a[2] <> 'Thriller' then raise exception 'the rename did not reach the title: %', a; end if;
  select search_text into v from public.titles where id = sintel;
  if position('သည်းထိတ်ရင်ဖို' in v) = 0 or position('thriller' in v) = 0 then
    raise exception 'the search does not find the genre in Burmese and English: %', v;
  end if;
  if (select genre_codes from public.titles where id = sintel) <> array['G001', thr] then
    raise exception 'the rename changed the codes';
  end if;

  -- ── codes do not change, and are not given twice ───────────────────────
  blocked := false;
  begin
    update public.genres set code = 'G900' where code = thr;
  exception when check_violation then blocked := true;
  end;
  if not blocked then raise exception 'a genre code changed'; end if;
  blocked := false;
  begin
    insert into public.genres (label) values ('THRILLER');
  exception when unique_violation then blocked := true;
  end;
  if not blocked then raise exception 'a second genre with the same name was made'; end if;
  insert into public.genres (label) values ('Zz unused') returning code into v;
  delete from public.genres where code = v;
  insert into public.genres (label) values ('Zz unused two') returning code into w;
  if w <= v then raise exception 'code % given again after a delete (got %)', v, w; end if;

  -- ── a genre in use is not deleted; retired, it is not given anew ───────
  blocked := false;
  begin
    delete from public.genres where code = thr;
  exception when foreign_key_violation then blocked := true;
  end;
  if not blocked then raise exception 'a genre in use was deleted'; end if;
  update public.genres set retired_at = now() where code = thr;
  blocked := false;
  begin
    update public.titles set genre_codes = array[thr] where id = tears;
  exception when check_violation then blocked := true;
  end;
  if not blocked then raise exception 'a retired genre was given to a title'; end if;
  -- an old writer sending the retired word: dropped, not refused
  update public.titles set genres = array['Open Movie', 'Thriller'] where id = tears;
  if (select genre_codes from public.titles where id = tears) <> array['G001'] then
    raise exception 'a retired genre came in by its word';
  end if;
  -- a title that had it keeps it through an unrelated edit
  update public.titles set genre_codes = array[thr, 'G001'] where id = sintel;
  if (select genre_codes from public.titles where id = sintel) <> array[thr, 'G001'] then
    raise exception 'a title lost a retired genre it already had';
  end if;
  update public.genres set retired_at = null where code = thr;

  -- ── merge: the titles move, the old genre points at the new one ────────
  j := public.genre_merge(thr, 'G001');
  if not coalesce((j->>'ok')::boolean, false) then raise exception 'merge: %', j; end if;
  if (select genre_codes from public.titles where id = sintel) <> array['G001'] then
    raise exception 'merge left %', (select genre_codes from public.titles where id = sintel);
  end if;
  if (select merged_into from public.genres where code = thr) <> 'G001'
     or (select retired_at from public.genres where code = thr) is null then
    raise exception 'the merged genre is not retired into its new one';
  end if;

  -- ── category: by code, or by the old id ────────────────────────────────
  update public.titles set category_code = 'C02' where id = sintel;
  if (select category from public.titles where id = sintel) <> 'series' then
    raise exception 'category code C02 did not set series';
  end if;
  update public.titles set category = 'reels' where id = sintel;
  if (select category_code from public.titles where id = sintel) <> 'C03' then
    raise exception 'category reels did not set C03';
  end if;
  blocked := false;
  begin
    update public.titles set category_code = 'C77' where id = sintel;
  exception when foreign_key_violation then blocked := true;
  end;
  if not blocked then raise exception 'an unknown category code was taken'; end if;
  insert into public.categories (id, label, sort_order) values ('zz-test', 'Zz', 9) returning code into v;
  if v <> 'C04' then raise exception 'a new section got code %', v; end if;
  blocked := false;
  begin
    update public.categories set code = 'C50' where id = 'zz-test';
  exception when check_violation then blocked := true;
  end;
  if not blocked then raise exception 'a category code changed'; end if;
  blocked := false;
  begin
    delete from public.categories where id = 'all';
  exception when check_violation then blocked := true;
  end;
  if not blocked then raise exception 'All was deleted'; end if;

  if public._card((select t from public.titles t where id = tears)) -> 'genre_codes' is null then
    raise exception 'a card has no genre codes';
  end if;

  -- ── what a reader sees, as anon ────────────────────────────────────────
  set local role anon;
  select count(*) into n from public.title_cards where category_code is not null and genre_codes is not null;
  if n < 1 then raise exception 'anon sees no cards with codes'; end if;
  j := public.taxonomy();
  if jsonb_array_length(j->'categories') < 4 or jsonb_array_length(j->'genres') < 3
     or j->>'version' is null then
    raise exception 'taxonomy(): %', left(j::text, 300);
  end if;
  if (public.catalogue_facets('C01', null)::jsonb -> 'genre_codes') is null then
    raise exception 'facets have no genre codes';
  end if;
  blocked := false;
  begin
    perform public.genre_merge('G001', 'G002');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'anon could merge genres'; end if;
  blocked := false;
  begin
    insert into public.genres (label) values ('anon genre');
  exception when insufficient_privilege then blocked := true;
  end;
  if not blocked then raise exception 'anon could add a genre'; end if;
  reset role;

  raise exception 'TAXONOMY TEST PASSED';
end $$;
