# Innocent — working notes for Claude

Android media player (Flutter) with a film catalogue. Backend: Supabase
(Postgres, edge functions), Cloudflare (R2, the `stream.` Worker, the console
Worker), GitHub Actions (build, transcode, ingest, labs). The owner works from
the Claude app on a phone. **Reply to the owner in Burmese**, technical terms
in English. Why this file is shaped as it is: `docs/ai_workflow.md`.

## Where things are
- `lib/`, `android/` the app · `test/` Flutter tests · `test_device/` labs
- `docs/edge/*.ts` edge functions, deployed as one-line shims importing the
  file at a commit SHA · `docs/migrations/NNN_*.sql` applied through the
  Supabase MCP, then committed · `docs/studio/` the console ·
  `docs/console/` its Worker · `docs/worker/` the stream Worker
- `tool/check.py` every structural check · `tool/sql/*_test.sql` DB tests
- `docs/BACKLOG.md` open work, newest first — read §0 before starting
- `docs/security_review_2026_11.md`, `docs/MEDIA_ENCRYPTION.md`, `docs/RUNBOOK.md`

## Rules that hold in every session
- Secrets live only in Supabase, Cloudflare or GitHub secrets. Never print a
  secret, a key or key prefix, a presigned URL, or a plain payment number.
  Never ask the owner to paste a key; the owner sets secrets.
- Touch no catalogue title but the open films (slug `open-film-…`) unless the
  owner names it. Labs and canaries use open films only.
- Never rewrite pushed history. No pull request unless asked. Work on the
  session's branch; `git checkout pubspec.lock` before committing.
- `python3 tool/check.py` passes before every push.
- A push to `main` is a production deploy: `docs/**` republishes Pages and
  rebuilds both Workers; most other paths start the app Build. Releases:
  skill `release`. Database changes: skill `live-db-change`. Labs: skill
  `device-labs`.
- No help hosting or streaming films without a licence, and nothing that
  hides the service from rights holders.

## The sandbox
- Supabase REST, Cloudflare APIs, blender.org and archive.org are not
  reachable from here: read the database with the Supabase MCP, and reach the
  rest from a GitHub runner (a workflow task), which can.
- Foreground `sleep` is blocked: wait with `timeout N tail -f /dev/null`.
- Deno: `$SCRATCHPAD/denoinst/node_modules/deno/deno` when it exists; boot a
  function locally with the stub import map and `NO_PROXY=127.0.0.1`.

## Spending tokens well (the owner's standing request, 6 Nov 2026)
Quality first: the main session stays on Opus for this project's work —
releases, migrations, security and the app touch production.
1. **Keep the model fixed inside a session.** A model switch re-reads the
   whole conversation uncached. Choose at the start: Opus for production
   work; for routine sessions (monitoring, seeding, docs) the owner may start
   on Sonnet with `/advisor opus`. Raise effort with `/effort high` for
   releases, migrations and security reviews (on Opus 5.5 an effort change
   keeps the cache).
2. **One workstream per session.** Long sessions re-read everything on every
   tool call. When a workstream ends, say so and suggest a fresh session;
   this file, the skills and BACKLOG carry what it needs.
3. **Small tool outputs.** GitHub: `actions_get` by run id; `actions_list`
   with `perPage` 1–3 and a branch/workflow filter; job logs with
   `tail_lines` ≤ 80. SQL: only the columns needed. Files: read by range,
   grep first. Long command output: filter with grep/tail before it returns.
4. **Delegate only what is verbose or self-contained**, to the project agents
   (owner-approved): `ci-reader` (Actions logs), `lab-reader` (lab results),
   `researcher` (web and docs), `reviewer` (a diff before it goes to main),
   `Explore` (wide code search). A fresh agent spends ~25k tokens before it
   starts, so small edits and lookups stay in the main session. A fork is
   fine when the side task needs this conversation: it shares the cache.
5. **When an agent fails**, re-brief it once with what it lacked; if it fails
   again, do that part in the main session. Never loop on retries.
6. Hooks (`.claude/settings.json`): `trim_github.py` keeps GitHub Actions
   results to their facts; `agent_log.py` logs each delegation to
   `.claude/state/agent-log.tsv`.

## Compact instructions
Keep: the rules above; every open task with its ids (run ids, title ids,
migration numbers, function versions); what is live versus only on the
branch; and what the owner still has to do.
