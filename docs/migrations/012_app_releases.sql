-- ===========================================================================
-- 012 — app_releases: the one row the in-app updater reads
--
-- Paste the WHOLE file into the Supabase SQL Editor and Run. Safe to run
-- twice. Step 1 of docs/updater_plan.md.
--
-- THE CHECKS ARE COMMENTED OUT AT THE BOTTOM, ON PURPOSE.
--   One of them is a statement that MUST fail (`anon` trying to write). A
--   failing statement inside a pasted script can roll back everything above
--   it, including this table. So the checks are run one at a time, in their
--   own tab, after this file has succeeded - the same shape migration 011
--   uses.
--
-- THIS MIGRATION DOES NOT DEPEND ON 003-011.
--   It was written that way on purpose. `app_releases` has no foreign key to
--   `titles`, no reference to `title_assets`, and no use of `add_title`. The
--   only thing it borrows from an earlier migration is the bookkeeping table
--   `schema_migrations`, and this file creates that itself (identical DDL to
--   003, `if not exists`, so running 003 afterwards is still a no-op).
--
--   Consequence: you can run this TODAY without first finishing 008-011, and
--   run those later in any order. `select version from schema_migrations` will
--   show a gap until you do. The gap is not a fault - it is the table telling
--   you the truth about what has been applied.
--
-- THE GRANT THAT THIS PROJECT HAS FORGOTTEN TWICE
--   "Automatically expose new tables" is OFF on this project. Every API role -
--   `anon`, `authenticated` AND `service_role` - gets NOTHING on a new table
--   unless it is granted here. Migrations 002 and 005 both existed only
--   because that was forgotten, and both times the symptom looked like missing
--   data rather than a permissions problem. So the grants are in the same file
--   as the table, and all three roles are named.
--
--   `authenticated` matters as much as `anon` here. PostgREST resolves the
--   role from the bearer token, so a SIGNED-IN user is `authenticated`, not
--   `anon`. Granting only `anon` would mean the update check works until
--   someone signs in and then silently stops.
--
-- NOTHING IN THIS TABLE IS SECRET.
--   The APK is meant to be downloadable by anyone holding the link, and the
--   hash is published precisely so a client can check it. There is no
--   column-level grant to get right, unlike `titles.locator`.
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 0 — bookkeeping table (same DDL as 003; harmless if 003 already ran)
-- ---------------------------------------------------------------------------
create table if not exists public.schema_migrations (
  version    text primary key,
  applied_at timestamptz not null default now(),
  note       text
);

grant usage on schema public to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 1 — the table
-- ---------------------------------------------------------------------------
create table if not exists public.app_releases (
  id            int primary key default 1 check (id = 1),

  version_name  text not null,            -- '1.64.6'  shown to the user
  version_code  int  not null,            -- 319       the client compares THIS

  -- NULLABLE, and this is a deliberate change from updater_plan.md, which
  -- has both `not null`.
  --
  -- At step 2 the app only CHECKS; nothing downloads. There is no APK
  -- uploaded yet, so a `not null` column would have to be filled with an
  -- invented URL and an invented hash. A fake hash is worse than an absent
  -- one: step 3 compares the downloaded file against it and fails in a way
  -- that reads as tampering.
  --
  -- A null says "not published yet", which is true. When step 3 arrives,
  -- migration 013 fills these in and makes them `not null`.
  apk_url       text,                     -- R2 URL of the APK
  apk_sha256    text,                     -- 64 hex chars, checked before install
  apk_bytes     bigint,                   -- so the client can say "42 MB" first

  min_supported int  not null default 0,  -- below this, force. See §2 of the plan.
  priority      int  not null default 3   -- 1..5, urgency. Changed from SQL, no rebuild.
                     check (priority between 1 and 5),

  notes_en      text,
  notes_mm      text,

  released_at   timestamptz not null default now()
);

comment on table public.app_releases is
  'One row (id=1). The in-app updater reads it. See docs/updater_plan.md.';


-- ---------------------------------------------------------------------------
-- 2 — who may read it
-- ---------------------------------------------------------------------------
-- RLS on, then one policy that allows reading. Belt and braces: the GRANT
-- decides whether the role may touch the table at all, the POLICY decides
-- which rows. Both have to say yes.
--
-- No insert/update/delete policy and no write grant, for anyone. The row is
-- edited by you in the SQL Editor or Table Editor, which runs as the table
-- owner and is not subject to either. An app that could write its own release
-- row could tell every other install to download anything.

alter table public.app_releases enable row level security;

drop policy if exists app_releases_read on public.app_releases;
create policy app_releases_read
  on public.app_releases
  for select
  to anon, authenticated
  using (true);

grant select on public.app_releases to anon, authenticated;
grant all privileges on public.app_releases to service_role;


-- ---------------------------------------------------------------------------
-- 3 — the row
-- ---------------------------------------------------------------------------
-- Seeded with the build you are ABOUT TO INSTALL (1.64.6 / 319), not the one
-- installed now (318). After you install 319 the screen must say "up to date";
-- that is the state worth proving first, because it is the one every user is
-- in almost all of the time.
--
-- To see the OTHER state, change one number - see the bottom of this file.

insert into public.app_releases
  (id, version_name, version_code, apk_bytes, notes_en, notes_mm, priority)
values
  (1, '1.64.6', 319, null,
   'Settings now has an App update screen.',
   'ဆက်တင်ထဲတွင် အက်ပ်အပ်ဒိတ် စခရင် ထည့်သွင်းထားပါသည်။',
   3)
on conflict (id) do nothing;
-- `do nothing`, not `do update`: re-running this file must never overwrite a
-- release you have since edited by hand.


-- ---------------------------------------------------------------------------
-- 4 — record it
-- ---------------------------------------------------------------------------
do $mig$
begin
  if not exists (select 1 from public.schema_migrations where version = '012') then
    insert into public.schema_migrations (version, note)
    values ('012', 'app_releases: in-app updater manifest, one row, anon-readable');
  end if;
end
$mig$;


-- ---------------------------------------------------------------------------
-- 5 - the one live result: what was applied, and what the row now says
-- ---------------------------------------------------------------------------
-- The SQL Editor shows the result of the LAST statement, so there is exactly
-- one, and it is the one worth seeing.
select
  (select count(*) from public.schema_migrations)             as migrations_applied,
  (select string_agg(version, ',' order by version)
     from public.schema_migrations)                           as versions,
  (select version_name from public.app_releases where id = 1) as release_name,
  (select version_code from public.app_releases where id = 1) as release_code;


-- ===========================================================================
-- CHECKS - run these AFTERWARDS, ONE BLOCK AT A TIME, IN A SEPARATE TAB
-- ===========================================================================
--
-- CHECK 1 - the app's own view. It holds the publishable key, which makes it
-- `anon`. This MUST RETURN THE ROW. If it is refused, the update screen shows
-- "could not check" forever and nothing in the app will tell you why.
--
--   set role anon;
--   select version_name, version_code, apk_bytes, notes_en, notes_mm, released_at
--   from public.app_releases limit 1;
--   reset role;
--
--
-- CHECK 2 - and `anon` must NOT be able to write it. This one MUST FAIL with a
-- permission error; the failure IS the pass condition. Run it ALONE, because
-- an error can roll back anything sharing the same run. If it errored, run
-- `reset role;` on its own afterwards.
--
--   set role anon;
--   update public.app_releases set version_code = 999 where id = 1;
--   reset role;
--
--
-- CHECK 3 - which migrations exist on this project right now.
--
--   select version, applied_at, note from public.schema_migrations order by version;


-- ===========================================================================
-- THE TWO-STATE TEST — after build 319 is installed
-- ===========================================================================
-- With 319 installed, Settings → App update must say "up to date".
--
-- Then run ONE line to make a newer release exist:
--
--   update public.app_releases
--      set version_name = '1.65.0', version_code = 320,
--          notes_mm = 'စမ်းသပ်မှု အပ်ဒိတ်', notes_en = 'Test update'
--    where id = 1;
--
-- Tap "Check now". It must switch to "update available", naming 1.65.0.
-- Then put it back:
--
--   update public.app_releases
--      set version_name = '1.64.6', version_code = 319 where id = 1;
--
-- Two states, one number, no rebuild. That is the whole point of the table.
