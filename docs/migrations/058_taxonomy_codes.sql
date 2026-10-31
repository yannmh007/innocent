-- 058 — categories and genres known by code (2026-10-31).
--
-- WHAT THE OWNER ASKED FOR. A title says what it is with a code the app and
-- the database both know — C01, C02 for its category, G001, G002 for its
-- genres — and the words for each code (English, Burmese, Thai) live in one
-- place, which only the console changes: add, rename, translate, reorder,
-- hide, retire, delete an unused one, merge two genres into one.
--
-- WHY, HONESTLY. Not secrecy: the words are what every viewer reads on every
-- card, and the table that maps a code to its words is in this database and
-- in the app. What codes do buy is the industry's reason for them (TMDB
-- knows Science Fiction as 878): a genre is written once, so it cannot be
-- typed two ways ("Sci-Fi", "SciFi"); a rename or a translation touches one
-- row, not every title; and a code never changes, so analytics, saved filters
-- and the app's caches keep meaning the same thing.
--
-- HOW, AND WHAT IT DOES NOT BREAK. Additive. `titles.category` (the text id,
-- 'movies') and `titles.genres` (the English words) stay, because every app
-- in the field reads them; they now FOLLOW the codes, set by a trigger, and
-- go once no app that reads them is left (TAX phase 4). A writer that still
-- sends the old fields (an older console, the open-film seeder) is mapped to
-- codes by the same trigger, so nothing writes around them.
--
-- THE RULES THE CODES KEEP (each one a lesson others learned the hard way):
--   * A code is given by the database (a sequence), never typed, and never
--     given twice — not even after the row it named is deleted. A reused
--     code would make old data and every app's cache mean something else.
--   * A code never changes. The words change.
--   * A genre a title uses cannot be deleted: it is retired (no new title
--     gets it, titles that have it keep it) or merged into another.
--   * The legacy text is derived, never the other way round, once a writer
--     sends codes.

-- ── 1. CATEGORIES: a code beside the id ───────────────────────────────────

create sequence if not exists public.category_code_seq minvalue 1 maxvalue 99;

alter table public.categories
  add column if not exists code text,
  add column if not exists label_th text,
  add column if not exists retired_at timestamptz;

update public.categories set code = case id
    when 'all'    then 'C00'
    when 'movies' then 'C01'
    when 'series' then 'C02'
    when 'reels'  then 'C03'
  end
 where code is null and id in ('all', 'movies', 'series', 'reels');

-- Any other section the console added before this gets the next codes, in
-- the order the tabs show.
select setval('public.category_code_seq',
  greatest(3, coalesce((select max(substr(code, 2)::int) from public.categories
                         where code ~ '^C[0-9]{2}$'), 0)));
update public.categories c
   set code = 'C' || lpad(nextval('public.category_code_seq')::text, 2, '0')
  from (select id from public.categories where code is null order by sort_order, id) x
 where c.id = x.id;

alter table public.categories
  alter column code set default 'C' || lpad(nextval('public.category_code_seq')::text, 2, '0'),
  alter column code set not null,
  add constraint categories_code_key unique (code),
  add constraint categories_code_ck check (code ~ '^C[0-9]{2}$');

update public.categories set label_th = case id
    when 'all'    then 'ทั้งหมด'
    when 'movies' then 'ภาพยนตร์'
    when 'series' then 'ซีรีส์'
    when 'reels'  then 'รีลส์'
  end
 where label_th is null and id in ('all', 'movies', 'series', 'reels');

-- ── 2. GENRES: a table, where there was free text on every title ──────────

create sequence if not exists public.genre_code_seq minvalue 1 maxvalue 999;

create table if not exists public.genres (
  code        text primary key
              default 'G' || lpad(nextval('public.genre_code_seq')::text, 3, '0')
              check (code ~ '^G[0-9]{3}$'),
  label       text not null check (length(btrim(label)) between 1 and 40),
  label_mm    text check (label_mm is null or length(btrim(label_mm)) between 1 and 60),
  label_th    text check (label_th is null or length(btrim(label_th)) between 1 and 60),
  sort_order  integer not null default 0,
  is_visible  boolean not null default true,
  retired_at  timestamptz,
  -- Merged into another genre: the titles moved there, and an app holding
  -- this code in a cache or a saved filter can follow it.
  merged_into text references public.genres(code),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter sequence public.genre_code_seq owned by public.genres.code;

-- One genre per English name, whatever the case: "Thriller" and "thriller"
-- are the same genre, and the second is refused rather than made.
create unique index if not exists genres_label_key on public.genres (lower(btrim(label)));

alter table public.genres enable row level security;
drop policy if exists genres_read on public.genres;
create policy genres_read on public.genres for select to anon, authenticated using (true);
revoke all on public.genres from anon, authenticated;
grant select on public.genres to anon, authenticated;

-- The genres titles have today, most used first.
insert into public.genres (label, sort_order)
select g, row_number() over (order by count(*) desc, g)
  from (select btrim(x) g from public.titles, unnest(coalesce(genres, '{}')) x) s
 where g <> ''
 group by g
 order by count(*) desc, g
on conflict do nothing;

update public.genres set label_mm = 'ကာတွန်း', label_th = 'แอนิเมชัน'
 where lower(label) = 'animation' and label_mm is null;
update public.genres set label_mm = 'စိတ်ကူးယဉ်', label_th = 'แฟนตาซี'
 where lower(label) = 'fantasy' and label_mm is null;

-- ── 3. TITLES: the codes, and the old text following them ─────────────────

alter table public.titles
  add column if not exists category_code text references public.categories(code),
  add column if not exists genre_codes text[] not null default '{}';

update public.titles t set category_code = c.code
  from public.categories c
 where c.id = t.category and t.category_code is distinct from c.code;

update public.titles t
   set genre_codes = coalesce((
         select array_agg(g.code order by u.n)
           from unnest(coalesce(t.genres, '{}')) with ordinality u(x, n)
           join public.genres g on lower(g.label) = lower(btrim(u.x))), '{}');

-- No default: the trigger below sets it from the category id when a writer
-- sends only that, and the code wins when a writer sends the code.
alter table public.titles alter column category_code set not null;

-- title_cards reads titles as its caller (security_invoker), and anon and
-- signed-in readers may see only the columns granted to them: the two new
-- ones are granted, or the view would refuse every reader.
grant select (category_code, genre_codes) on public.titles to anon, authenticated;

create index if not exists titles_category_code_idx on public.titles (category_code);
create index if not exists titles_genre_codes_idx on public.titles using gin (genre_codes);

-- THE ONE PLACE A TITLE'S CATEGORY AND GENRES ARE SETTLED. Runs first of the
-- titles triggers (they fire by name), so the search text and the review
-- triggers see the settled values.
create or replace function public.titles_taxonomy()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare
  by_code boolean := false;
  by_text boolean := false;
  prev    text[] := '{}';
  codes   text[];
  word    text;
  gcode   text;
begin
  if tg_op = 'UPDATE' then
    prev := coalesce(old.genre_codes, '{}');
  end if;

  -- CATEGORY. The code decides; a writer that sent only the old id is
  -- mapped to its code.
  if tg_op = 'INSERT' then
    by_code := new.category_code is not null;
  else
    by_code := new.category_code is distinct from old.category_code;
  end if;
  if by_code then
    select id into word from categories where code = new.category_code;
    if word is null then
      raise exception 'unknown category code %', new.category_code using errcode = '23503';
    end if;
    new.category := word;
  else
    select code into gcode from categories where id = new.category;
    if gcode is null then
      raise exception 'unknown category %', new.category using errcode = '23503';
    end if;
    new.category_code := gcode;
  end if;

  -- GENRES. Codes if the writer sent codes; otherwise its words, each
  -- matched to the genre it names (in any of the three languages), and a
  -- word no genre has yet becomes a new genre.
  if tg_op = 'INSERT' then
    by_code := cardinality(coalesce(new.genre_codes, '{}')) > 0;
    by_text := not by_code and cardinality(coalesce(new.genres, '{}')) > 0;
  else
    by_code := new.genre_codes is distinct from old.genre_codes;
    by_text := not by_code and new.genres is distinct from old.genres;
  end if;

  if by_text then
    codes := '{}';
    foreach word in array coalesce(new.genres, '{}') loop
      word := btrim(word);
      continue when word = '';
      select g.code into gcode from genres g
       where lower(g.label) = lower(word) or lower(g.label_mm) = lower(word) or lower(g.label_th) = lower(word)
       order by (lower(g.label) = lower(word)) desc, (g.retired_at is null) desc, g.code
       limit 1;
      if gcode is null then
        word := left(word, 40);
        insert into genres (label, sort_order)
        values (word, coalesce((select max(sort_order) from genres), 0) + 1)
        on conflict do nothing
        returning code into gcode;
        -- Made by another write in the same moment: that one is it.
        if gcode is null then
          select g.code into gcode from genres g where lower(btrim(g.label)) = lower(word);
        end if;
      end if;
      -- A retired genre is not given to a title that did not have it; the
      -- words are dropped rather than the write refused, so an old writer
      -- does not fail on a genre the console has retired.
      continue when exists (select 1 from genres g where g.code = gcode and g.retired_at is not null)
                and not gcode = any(prev);
      if not gcode = any(codes) then codes := codes || gcode; end if;
    end loop;
    new.genre_codes := codes;
  elsif by_code then
    if exists (select 1 from unnest(new.genre_codes) u(x)
                where not exists (select 1 from genres g where g.code = u.x)) then
      raise exception 'unknown genre code in %', new.genre_codes using errcode = '23503';
    end if;
    if exists (select 1 from unnest(new.genre_codes) u(x) join genres g on g.code = u.x
                where g.retired_at is not null
                  and not u.x = any(prev)) then
      raise exception 'genre retired' using errcode = '23514';
    end if;
  end if;

  if by_text or by_code then
    -- Each code once, in the order given.
    new.genre_codes := coalesce((select array_agg(u.x order by u.n)
        from (select v.x, min(v.n) n from unnest(new.genre_codes) with ordinality v(x, n) group by v.x) u), '{}');
    new.genres := coalesce((select array_agg(g.label order by u.n)
        from unnest(new.genre_codes) with ordinality u(x, n)
        join genres g on g.code = u.x), '{}');
  end if;
  return new;
end;
$$;

drop trigger if exists titles_a_taxonomy on public.titles;
create trigger titles_a_taxonomy
  before insert or update of category, category_code, genres, genre_codes on public.titles
  for each row execute function public.titles_taxonomy();

-- SEARCH finds a title by its genres in all three languages (it read the
-- English words only), and runs when only the codes change.
create or replace function public.titles_search_text()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.search_text := lower(concat_ws(' ',
    new.title,
    new.title_mm,
    new.synopsis,
    array_to_string(coalesce(new.genres,   '{}'), ' '),
    (select string_agg(concat_ws(' ', g.label_mm, g.label_th), ' ')
       from public.genres g where g.code = any(coalesce(new.genre_codes, '{}'))),
    array_to_string(coalesce(new.keywords, '{}'), ' '),
    new.quality_label,
    new.year::text
  ));
  return new;
end;
$$;

drop trigger if exists titles_search_text_trg on public.titles;
create trigger titles_search_text_trg
  before insert or update of title, title_mm, synopsis, genres, genre_codes, keywords, quality_label, year
  on public.titles for each row execute function public.titles_search_text();

-- The search text of the titles there are, now with every language.
update public.titles set genre_codes = genre_codes;

-- ── 4. A GENRE'S WORDS CHANGE: the titles that have it follow ─────────────

create or replace function public.genres_changed()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  new.updated_at := now();
  if new.code <> old.code then
    raise exception 'a genre code never changes' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists genres_a_changed on public.genres;
create trigger genres_a_changed before update on public.genres
  for each row execute function public.genres_changed();

create or replace function public.genres_relabel_titles()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  -- Setting `genres` again re-runs the search text (now in every language)
  -- and the legacy words; the codes are unchanged, so each word maps back
  -- to the genre it came from.
  update public.titles t
     set genres = coalesce((select array_agg(g.label order by u.n)
                   from unnest(t.genre_codes) with ordinality u(x, n)
                   join public.genres g on g.code = u.x), '{}')
   where t.genre_codes @> array[new.code];
  return null;
end;
$$;

drop trigger if exists genres_z_relabel on public.genres;
create trigger genres_z_relabel
  after update of label, label_mm, label_th on public.genres
  for each row execute function public.genres_relabel_titles();

-- A genre a title has is not deleted; it is retired or merged.
create or replace function public.genres_keep_used()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if exists (select 1 from public.titles where genre_codes @> array[old.code]) then
    raise exception 'genre in use' using errcode = '23503';
  end if;
  return old;
end;
$$;

drop trigger if exists genres_keep_used on public.genres;
create trigger genres_keep_used before delete on public.genres
  for each row execute function public.genres_keep_used();

-- A category's code never changes either, and All (C00) is not a section a
-- title can be in, nor one to delete.
create or replace function public.categories_code_fixed()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if tg_op = 'DELETE' then
    if old.code = 'C00' then
      raise exception 'All is fixed' using errcode = '23514';
    end if;
    return old;
  end if;
  if new.code <> old.code then
    raise exception 'a category code never changes' using errcode = '23514';
  end if;
  return new;
end;
$$;

drop trigger if exists categories_code_fixed on public.categories;
create trigger categories_code_fixed before update or delete on public.categories
  for each row execute function public.categories_code_fixed();

-- ── 5. MERGE: two genres become one ───────────────────────────────────────

create or replace function public.genre_merge(p_from text, p_into text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  moved integer;
begin
  if p_from = p_into then
    return jsonb_build_object('error', 'same');
  end if;
  if not exists (select 1 from genres where code = p_from) then
    return jsonb_build_object('error', 'not_found', 'code', p_from);
  end if;
  if not exists (select 1 from genres where code = p_into and retired_at is null) then
    return jsonb_build_object('error', 'not_found', 'code', p_into);
  end if;
  update titles
     set genre_codes = array_replace(genre_codes, p_from, p_into)
   where genre_codes @> array[p_from];
  get diagnostics moved = row_count;
  update genres set retired_at = coalesce(retired_at, now()), merged_into = p_into,
                    is_visible = false
   where code = p_from;
  return jsonb_build_object('ok', true, 'moved', moved);
end;
$$;

revoke all on function public.genre_merge(text, text) from public, anon, authenticated;
grant execute on function public.genre_merge(text, text) to service_role;

-- ── 6. WHAT THE APP READS ─────────────────────────────────────────────────

-- The words for every code, in one answer the app caches (`version` changes
-- whenever any of them does). Retired codes are there with `retired`, so a
-- title that still has one is labelled; the app does not offer them.
create or replace function public.taxonomy()
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'version', greatest(
       (select max(updated_at) from categories),
       (select max(updated_at) from genres)),
    'categories', coalesce((select jsonb_agg(jsonb_build_object(
        'code', c.code, 'id', c.id, 'label', c.label, 'label_mm', c.label_mm,
        'label_th', c.label_th, 'sort_order', c.sort_order,
        'visible', c.is_visible, 'retired', c.retired_at is not null)
        order by c.sort_order, c.code) from categories c), '[]'::jsonb),
    'genres', coalesce((select jsonb_agg(jsonb_build_object(
        'code', g.code, 'label', g.label, 'label_mm', g.label_mm,
        'label_th', g.label_th, 'sort_order', g.sort_order,
        'visible', g.is_visible, 'retired', g.retired_at is not null,
        'merged_into', g.merged_into)
        order by g.sort_order, g.code) from genres g), '[]'::jsonb));
$$;

revoke all on function public.taxonomy() from public;
grant execute on function public.taxonomy() to anon, authenticated, service_role;

-- Cards carry the codes beside the old fields (an older app ignores them).
create or replace function public._card(tt titles)
returns jsonb
language sql
stable
set search_path to 'public'
as $$
  select jsonb_build_object(
    'id', tt.id, 'title', tt.title, 'title_mm', tt.title_mm, 'synopsis', tt.synopsis, 'category', tt.category,
    'category_code', tt.category_code,
    'poster_url', tt.poster_url, 'year', tt.year, 'rating', tt.rating, 'quality_label', tt.quality_label, 'genres', tt.genres,
    'genre_codes', tt.genre_codes,
    'episode_count', tt.episode_count, 'view_count', tt.view_count, 'access_tier', tt.access_tier,
    'photo_count', tt.photo_count, 'video_count', tt.video_count);
$$;

create or replace view public.title_cards with (security_invoker = true) as
 select id, title, title_mm, synopsis, category, poster_url, year, rating,
        quality_label, genres, episode_count, view_count, access_tier,
        photo_count, video_count, is_featured,
        category_code, genre_codes
   from titles
  where published;

-- The filter sheet's choices: the codes too, and a category asked for by
-- its code or its id.
create or replace function public.catalogue_facets(category_filter text default null, row_key text default null)
returns json
language sql
stable
set search_path to 'public'
as $$
  select json_build_object(
    'genres', coalesce((
      select json_agg(distinct g) from public.titles, unnest(genres) g
       where published
         and (category_filter is null or category = category_filter or category_code = category_filter)
    ), '[]'::json),
    'genre_codes', coalesce((
      select json_agg(distinct g) from public.titles, unnest(genre_codes) g
       where published
         and (category_filter is null or category = category_filter or category_code = category_filter)
    ), '[]'::json),
    'years', coalesce((
      select json_agg(distinct year order by year desc) from public.titles
       where published and year is not null
         and (category_filter is null or category = category_filter or category_code = category_filter)
    ), '[]'::json),
    'qualities', coalesce((
      select json_agg(distinct quality_label) from public.titles
       where published and quality_label is not null
         and (category_filter is null or category = category_filter or category_code = category_filter)
    ), '[]'::json)
  );
$$;
