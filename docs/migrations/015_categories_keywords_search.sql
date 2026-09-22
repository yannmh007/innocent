-- 015 + 015b — server-owned category names, hidden keywords, real search
--
-- APPLIED 22 Sep 2026, as two statements: 015, then 015b when running the new
-- function as `anon` refused it. Both are here, in their final state.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 1. CATEGORIES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE SPLIT BETWEEN id AND label IS THE WHOLE FEATURE, and the owner has
-- confirmed the rule it rests on — "id မပြောင်းလဲ ရတယ်", only the text
-- changes:
--
--   id      what `titles.category` stores, what analytics group by, what a
--           saved tab selection holds, and what the client's enum is keyed
--           on. FROZEN FOREVER. Changing one orphans every title using it.
--   label   what a viewer reads. Changing it is the point.
--
-- Renaming "Movies" to "Video" is now one UPDATE and takes effect on the next
-- app launch. So does reordering the bar, and so does hiding a tab.
--
-- WHAT THIS DOES NOT DO, said plainly rather than discovered later: a NEW
-- category still needs an app release. The client keys off a Dart enum and
-- nothing the server sends can make a build draw a tab it has never heard of.
-- Renaming, reordering and hiding are the honest scope.
create table if not exists public.categories (
  id          text primary key,
  label       text not null,
  label_mm    text,
  sort_order  int  not null default 0,
  is_visible  boolean not null default true,
  updated_at  timestamptz not null default now()
);

-- Seeded to match lib/features/video_hub/domain/content_category.dart exactly.
-- 'all' is in here too: it is a client-side landing tab rather than a stored
-- category, but its NAME is a label like any other.
insert into public.categories (id, label, label_mm, sort_order) values
  ('all',    'All',    'အားလုံး',      0),
  ('movies', 'Movies', 'ရုပ်ရှင်',      1),
  ('series', 'Series', 'ဇာတ်လမ်းတွဲ',  2),
  ('reels',  'Reels',  'ရီးလ်',        3)
on conflict (id) do nothing;

alter table public.categories enable row level security;

-- READABLE BY EVERYONE, including signed-out viewers: the tab bar is drawn
-- before the age gate and before any account exists. There is nothing
-- confidential in a tab name.
drop policy if exists categories_read on public.categories;
create policy categories_read on public.categories
  for select to anon, authenticated using (true);

grant select on public.categories to anon, authenticated;
grant select, insert, update, delete on public.categories to service_role;

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. KEYWORDS — SEARCHABLE, NEVER RENDERED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Deliberately NOT a second `genres`. `genres` is already wired end to end —
-- it draws the chips on a card, it fills the filter bar, and the facet RPC
-- reads it — so it IS the tag field and the console edits it as one.
--
-- This is the other job, which genres cannot do without making a mess of the
-- card: alternate spellings, a Burmese transliteration of an English title,
-- an actor's name. The words people actually type. Findable, invisible.
alter table public.titles add column if not exists keywords text[] default '{}';

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. SEARCH
-- ═══════════════════════════════════════════════════════════════════════════
--
-- What search did before this, from api_content_repository.dart:
--
--     or=(title.ilike."*q*",title_mm.ilike."*q*")
--
-- Two columns. A viewer searching a word from the synopsis, a genre, a
-- keyword or an actor got nothing; one mistyped letter got nothing.
--
-- pg_trgm rather than to_tsvector, and the reason is the audience: Postgres
-- has no Burmese text-search configuration, so stemming has nothing to work
-- with. Trigram similarity needs no language at all — it compares three
-- characters at a time, which works identically for Burmese, English, and a
-- title that mixes both.
create extension if not exists pg_trgm with schema extensions;

-- A MAINTAINED COLUMN, not a generated one: the searchable text spans several
-- fields, and a trigger is explicit about when it runs and what it read.
alter table public.titles add column if not exists search_text text;

create or replace function public.titles_search_text()
returns trigger language plpgsql
set search_path = public as $fn$
begin
  new.search_text := lower(concat_ws(' ',
    new.title,
    new.title_mm,
    new.synopsis,
    array_to_string(coalesce(new.genres,   '{}'), ' '),
    array_to_string(coalesce(new.keywords, '{}'), ' '),
    new.quality_label,
    new.year::text
  ));
  return new;
end;
$fn$;

drop trigger if exists titles_search_text_trg on public.titles;
create trigger titles_search_text_trg
  before insert or update of title, title_mm, synopsis, genres, keywords,
                             quality_label, year
  on public.titles
  for each row execute function public.titles_search_text();

update public.titles set search_text = lower(concat_ws(' ',
  title, title_mm, synopsis,
  array_to_string(coalesce(genres,   '{}'), ' '),
  array_to_string(coalesce(keywords, '{}'), ' '),
  quality_label, year::text));

create index if not exists titles_search_trgm
  on public.titles using gin (search_text extensions.gin_trgm_ops);

-- ───────────────────────────────────────────────────────────────────────────
-- 015b — why this function has OWNER RIGHTS
-- ───────────────────────────────────────────────────────────────────────────
--
-- 015 created it as a plain SQL function, which runs as the CALLER. Running
-- it as anon refused immediately:
--
--   set local role anon;
--   select count(*) from public.search_titles('solar');
--   ERROR:  permission denied for table titles
--
-- THE SAME CLASS OF FAULT AS 013b, one migration later. This project grants
-- `anon` SELECT on named COLUMNS of `titles` — nineteen of them, deliberately
-- excluding `locator` — and `search_text` was a column added minutes earlier
-- with no grant at all.
--
-- It would have failed SILENTLY in the app. `search()` catches an
-- ApiException and falls back to the old two-column query, so search would
-- have kept working, kept missing the synopsis and the keywords, and nothing
-- would have said why.
--
-- The fix is NOT `grant select (search_text) to anon`: that column is the
-- concatenation of everything searchable INCLUDING keywords, which exist
-- precisely so an operator can make a title findable by words that are not
-- shown. Publishing the blob would put them back on display.
--
-- Owner rights, for the reason 013b sets out: THE FUNCTION IS THE ACCESS
-- CONTROL. Its result type is `setof title_cards`, so it can only ever return
-- the exact column list anon already reads from that view, and title_cards
-- itself filters to published titles. `search_text` is read inside the
-- function and never leaves it.
create or replace function public.search_titles(q text, lim int default 50)
returns setof public.title_cards
language sql
stable
security definer
set search_path = public, extensions
as $fn$
  with needle as (select lower(btrim(coalesce(q, ''))) as n)
  select c.*
    from public.title_cards c
    join public.titles t on t.id = c.id, needle
   where needle.n <> ''
     and (
       -- Substring first: this is what makes an exact Burmese phrase work,
       -- and it is the match a user expects to be certain.
       t.search_text like '%' || needle.n || '%'
       -- Then fuzzy, for the mistyped letter. word_similarity compares the
       -- query against the best-matching RUN of words rather than against the
       -- whole blob, so a short query is not drowned by a long synopsis.
       or extensions.word_similarity(needle.n, t.search_text) > 0.45
     )
   order by
     -- Exact substring outranks fuzzy, always. Then the better fuzzy score,
     -- then the more-watched title as the tiebreak.
     (t.search_text like '%' || needle.n || '%') desc,
     extensions.word_similarity(needle.n, t.search_text) desc,
     c.view_count desc nulls last
   limit least(greatest(coalesce(lim, 50), 1), 100);
$fn$;

revoke all on function public.search_titles(text, int) from public;
grant execute on function public.search_titles(text, int)
  to anon, authenticated, service_role;

insert into public.schema_migrations (version, note) values
  ('015',  'categories table, titles.keywords, trigram search_text + search_titles()'),
  ('015b', 'search_titles: owner rights — anon has no grant on titles.search_text')
on conflict (version) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- CHECKS — run every one as `anon`, because `postgres` proves nothing here.
-- ═══════════════════════════════════════════════════════════════════════════
--
--   set local role anon;
--   select 'categories'     as check, count(*)::text from public.categories
--   union all select 'exact',         count(*)::text from public.search_titles('solar')
--   union all select 'burmese kw',    count(*)::text from public.search_titles('နေရောင်')
--   union all select 'from synopsis', count(*)::text from public.search_titles('yangon')
--   union all select 'from genre',    count(*)::text from public.search_titles('documentary')
--   union all select 'typo',          count(*)::text from public.search_titles('solra')
--   union all select 'nonsense',      count(*)::text from public.search_titles('zzzzqqq')
--   union all select 'empty',         count(*)::text from public.search_titles('  ');
--
-- Every row but the last two must be non-zero; the last two must be 0.
--
-- And the half that is easy to forget — the keywords must stay invisible:
--
--   set local role anon;
--   select search_text from public.titles limit 1;  -- permission denied
--   select keywords    from public.titles limit 1;  -- permission denied
--
-- If either starts returning a row, the point of a hidden keyword is gone.
