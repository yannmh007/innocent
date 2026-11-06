---
paths:
  - "docs/migrations/**"
  - "tool/sql/**"
---

# Migrations and SQL tests

- Next number after the highest in `docs/migrations/`; the header says what
  was wrong, what this changes, and which test proves it.
- **Grant every role explicitly** — anon, authenticated AND service_role.
  Why: a new table here gives the service role nothing (060, 062, 077).
- **Views and functions:** try them as anon and as authenticated in a
  rolled-back transaction before applying (the O11 lesson).
- **Tests end with `raise exception '... TEST PASSED'`** so the run rolls
  back. Never draw from a sequence in a test (`nextval` is not rolled back);
  ask `has_sequence_privilege` instead. `has_table_privilege` with a list
  means ANY: one privilege per call.
- Applying is skill `live-db-change`: reproduce, dry run, apply, test live.
