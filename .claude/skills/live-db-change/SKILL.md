---
name: live-db-change
description: "Change the live Supabase database safely (migrations, grants, functions, data fixes): reproduce, dry-run rolled back as each role, apply, then run the SQL tests. Use before any apply_migration or write through execute_sql."
---

# Changing the live database

The database is production. Every change goes through the same steps.

1. **Reproduce first.** Show the problem with a read-only query or a test
   that fails today (as the role that hits it: `set local role service_role`
   / `anon` / `authenticated` inside a `do $$ ... $$` block).
2. **Dry run, rolled back.** `begin; <migration>; <test do-block that ends
   with raise exception 'X TEST PASSED'>;` — the exception rolls everything
   back. Then confirm nothing stayed (privileges, rows).
   - Views and grants: try as anon AND authenticated AND service_role (O11).
   - A sequence is not transactional: a test that inserts rows with codes
     from a sequence spends them even when rolled back. Ask with
     `has_sequence_privilege` instead.
   - `has_table_privilege(t, 'INSERT, UPDATE')` is true if ANY is held: one
     privilege per call.
3. **Apply** with `apply_migration` (name `NNN_snake_case`), the same SQL as
   `docs/migrations/NNN_*.sql`, whose header says why.
4. **Test again on live**, rolled back: the new test, and after changes to
   r2 refs, claims or key tables the existing `tool/sql/*_test.sql` that
   cover them (R5).
5. **New table?** Grant the service role explicitly — a new table gives it
   nothing here (060, 062, 077). Add the table to FUNCTION_TABLES in
   `tool/sql/service_role_grants_test.sql` if a function uses it
   (`tool/function_tables.py` enforces this).
6. Commit the migration and test; note it in BACKLOG.

Never: print secrets or payment numbers from queries; touch titles outside
the open films unless the owner named them; run destructive SQL without the
owner's go-ahead.
