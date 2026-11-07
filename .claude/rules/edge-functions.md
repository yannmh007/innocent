---
paths:
  - "docs/edge/**"
---

# Edge functions (docs/edge)

- **Deploy only a pushed commit.** The live function is a one-line shim:
  `import 'https://raw.githubusercontent.com/yannmh007/innocent/<sha>/docs/edge/<name>.ts';`
  Why: the shim fetches the file at that SHA; an unpushed SHA 404s. How:
  commit, push, `deploy_edge_function` with the new SHA, then confirm the
  version with `list_edge_functions` and a 200 in the logs (once, three
  deploys in a row did not take and had to be redone). `verify_jwt` is false except
  premium-request and delete-account. Skill `edge-deploy` has the steps.
- **Diff against the live SHA first** (`get_edge_function` shows it): only
  your change may differ, or you ship someone else's unfinished work.
- **Keys:** `pickKey(..., { prefer: 'new' })`, raw calls with
  `...SERVICE_HEADERS` (the `sb_secret_` key goes in `apikey` only),
  supabase-js through `clientOptions`. Never log a key, a prefix, a DEK or a
  presigned URL.
- **Origins:** `consoleOrigins(Deno.env.get('STUDIO_ORIGINS'))`, never a
  hand-written list.
- **A new table name in `.from()` or `rest()`** must be in FUNCTION_TABLES
  (`tool/sql/service_role_grants_test.sql`), and the service role granted.
  Why: supabase-js returns a refusal as data; 058's genres failed silently
  for a week (077).
- **Stateless.** Per-isolate memo (key caches) only; whatever must survive
  goes to Postgres or R2. Work longer than a request (transcode, ingest,
  backups, rollups) is a job row claimed `for update skip locked` by a
  runner, never done inline. Map of who does what: `docs/architecture.md`.
- **Test before deploy:** the slice tests in `tool/js/` that cover the file,
  and for a changed op a local boot with `tool/edge_stub/boot.sh` (a
  stand-in REST server records the calls). `deno check` errors that
  HEAD already had (ingest 6, studio 6, premium 10, delete 7) are known.
