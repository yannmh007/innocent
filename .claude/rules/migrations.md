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
- **A function meant to run on a schedule ships with its caller.** There
  is no pg_cron: schedules are GitHub crons (the ingest tick). Why:
  `rollup_events` and `prune_events` (014) never ran; `event_daily` was
  still empty on 7 Nov. How: name the caller in the header, and after its
  first tick check the rows it should have written.
- **Search and filters that must scale use an operator the index serves.**
  pg_trgm GIN serves `like '%x%'`, `%`, `<%`; `word_similarity(a, b) > x`
  is a function call and a Seq Scan. Prove it: `set local enable_seqscan =
  off; explain …` (search_titles' fuzzy half, 7 Nov).
- **Additive only for what the app reads.** Installed old versions keep
  calling the same RPCs and columns; there is no API versioning, only
  `app_releases.min_supported`. Add; never rename or drop until no
  supported version reads it.
- Applying is skill `live-db-change`: reproduce, dry run, apply, test live.
  A change that adds a table, RPC or job: skill `architecture-review`.
