-- ===========================================================================
-- Migrations 003 and 004 — Innocent Movies
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice: each block checks whether it has already been applied and skips.
--
-- 003  migration tracking      — the mechanism for every change after this one
-- 004  title lifecycle         — `extra jsonb` and `status`, both additive
--
-- WHY THESE TWO FIRST, BEFORE ANY FEATURE
--
-- Up to now every schema change has been SQL pasted into an editor with no
-- record of what was applied. That already cost this project once: the
-- `service_role` grants were missing, the symptom was a flat `not_found`, and
-- the only reason it was diagnosable was a hand-added `reason` field. With a
-- migrations table, "has this been applied?" stops being a memory question.
--
-- 004 adds two columns that are trivial today and painful once a hundred
-- titles exist. Both are additive: the app selects columns by name and does
-- not select these, so nothing in the client changes.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 003 — MIGRATION TRACKING
-- ---------------------------------------------------------------------------
create table if not exists public.schema_migrations (
  version    text primary key,
  applied_at timestamptz not null default now(),
  note       text
);

-- Seed the two changes that already exist in this project, so the table tells
-- the truth from its first day rather than claiming the database is empty.
insert into public.schema_migrations (version, note) values
  ('001', 'titles, title_views, title_cards view, RLS, column grants, 4 RPCs'),
  ('002', 'service_role grants — needed because "expose new tables" was off')
on conflict (version) do nothing;

insert into public.schema_migrations (version, note)
values ('003', 'schema_migrations itself')
on conflict (version) do nothing;


-- ---------------------------------------------------------------------------
-- 004 — TITLE LIFECYCLE: `extra` and `status`
-- ---------------------------------------------------------------------------
do $mig$
begin
  if exists (select 1 from public.schema_migrations where version = '004') then
    raise notice '004 already applied, skipping';
    return;
  end if;

  -- ESCAPE HATCH for everything not thought of yet: an award, a content
  -- warning, a festival, a note. No migration, no client change.
  --
  -- Discipline, or it becomes a swamp: `extra` is for experiments and
  -- rarities. Once a key is on most rows, or needs an index, or the app must
  -- DISPLAY it, promote it to a real column in a numbered migration — the app
  -- selects columns by name and can never read out of a jsonb blob.
  alter table public.titles
    add column if not exists extra jsonb not null default '{}'::jsonb;

  -- STATUS, because `published` answers one question and the ones that come
  -- later need more: taken down after a complaint, hidden while a file is
  -- re-encoded, retired but keep the watch history.
  --
  -- `delete from titles` cascades into title_views — and later into events,
  -- bookmarks and progress — destroying history that cannot be rebuilt.
  -- `status = 'removed'` is reversible. DELETE is not.
  alter table public.titles
    add column if not exists status text not null default 'draft';

  -- Constraint added separately and guarded: ALTER TABLE ... ADD CONSTRAINT
  -- has no IF NOT EXISTS in Postgres, so a re-run would error without this.
  if not exists (
    select 1 from pg_constraint where conname = 'titles_status_check'
  ) then
    alter table public.titles add constraint titles_status_check
      check (status in ('draft','published','hidden','removed'));
  end if;

  -- Backfill from the boolean that already exists, so the new column is
  -- correct for every existing row from the moment it appears.
  update public.titles
     set status = case when published then 'published' else 'draft' end;

  insert into public.schema_migrations (version, note)
  values ('004', 'titles.extra jsonb + titles.status lifecycle');
end
$mig$;


-- ---------------------------------------------------------------------------
-- KEEP `published` AS THE CLIENT CONTRACT
-- ---------------------------------------------------------------------------
-- The app reads `published`, and the RLS policy tests it. Neither may change.
-- So `status` becomes the thing the operator edits and `published` becomes a
-- value maintained FROM it — the client keeps reading one boolean and knows
-- nothing about the lifecycle behind it.
--
-- This is the additive-only rule in practice: add the richer column, keep the
-- old one working, never make the app care.
create or replace function public.sync_title_published()
returns trigger language plpgsql as $fn$
begin
  -- Whichever field the operator touched, the other follows. Editing `status`
  -- in the Table Editor is the intended path; editing `published` directly
  -- still works, because someone will.
  if new.status is distinct from old.status then
    new.published := (new.status = 'published');
  elsif new.published is distinct from old.published then
    new.status := case when new.published then 'published' else 'draft' end;
  end if;
  return new;
end;
$fn$;

drop trigger if exists titles_sync_published on public.titles;
create trigger titles_sync_published
  before update on public.titles
  for each row execute function public.sync_title_published();

grant select (status) on public.titles to anon, authenticated;


-- ---------------------------------------------------------------------------
-- PROVE IT
-- ---------------------------------------------------------------------------
select version, applied_at, note
from public.schema_migrations order by version;

-- Expect four rows: 001, 002, 003, 004.
--
-- Then check the trigger really works, rather than trusting that it does:
--   update public.titles set status = 'hidden' where title = 'First test title';
--   select title, status, published from public.titles;   -- published must be false
--   update public.titles set status = 'published' where title = 'First test title';
--   select title, status, published from public.titles;   -- published must be true
