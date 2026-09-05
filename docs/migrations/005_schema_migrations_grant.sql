-- ===========================================================================
-- 005 — let the server read its own migration table
--
-- WHAT BROKE
--   self-test reported `schema_migrations readable: FAIL`.
--
-- WHY
--   "Automatically expose new tables" is OFF on this project - deliberately,
--   and correctly. It withholds grants from EVERY API role on every new table,
--   `service_role` included. `schema_migrations` was created in 003 with no
--   grant, so PostgREST refused it.
--
--   This is migration 002 happening again, on a table I added while writing
--   the tool meant to catch exactly this. The setting is right; remembering it
--   is the hard part, which is the argument for the self-test rather than
--   against the setting.
--
-- NOT GRANTED TO `anon`. The public has no business knowing this project's
-- schema history, and it is read only by server-side code.
-- ===========================================================================

do $mig$
begin
  if exists (select 1 from public.schema_migrations where version = '005') then
    raise notice '005 already applied, skipping';
    return;
  end if;

  grant select on public.schema_migrations to service_role;

  insert into public.schema_migrations (version, note)
  values ('005', 'grant select on schema_migrations to service_role');
end
$mig$;

-- PROVE IT: as the role the function actually uses.
set role service_role;
select version from public.schema_migrations order by version desc limit 1;
reset role;
-- Expect: 005
