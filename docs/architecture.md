# How Innocent is built, layer by layer (7 Nov 2026)

The classic web-application picture has eleven layers: DNS, load balancer,
app servers, database, cache, job queue, search, services, data warehouse,
cloud storage, CDN. Innocent runs no servers of its own: Cloudflare,
Supabase and GitHub's runners each play some of those roles. This page
says, for each layer, what plays it here, how we know it works, and where
it is weak. It replaces the October plans (list at the end) as the current
shape. Skill `architecture-review` is how a new feature is checked against
it; update this page when a layer changes.

```
phone (Flutter app)
 ├─ DNS: Cloudflare ── innocentplayer.com zone
 ├─ catalogue, events, account ──► Supabase (ap-southeast-1)
 │      PostgREST + 10 public RPCs ─► Postgres 17   edge functions (Deno)
 ├─ play ──► request-playback (grant) ──► stream.innocentplayer.com
 │                                         stream Worker ─► R2 innocent-media
 ├─ posters, APK ──► cdn.innocentplayer.com ─► R2 innocent-public (cached)
 └─ crash reports ──► Sentry (only when SENTRY_DSN is set)
console.innocentplayer.com ─► console Worker (assets) ─► studio function
GitHub runners, every 5 min ─► claim jobs in Postgres: ingest, transcode,
   frames, daily DB backup, R2 bin, off-site copies ─► R2 + off-site bucket
```

| # | Layer | Here | How we know | Weak point, and when it binds |
|---|---|---|---|---|
| 1 | DNS | Cloudflare zone (free plan) and registrar; three records, all proxied: `stream.` and `console.` (Workers), `cdn.` (R2); no apex or www on purpose (no website); workers.dev and r2.dev off | dashboard screenshots 7 Nov | DNSSEC enabled by the owner on 7 Nov, pending while Cloudflare Registrar publishes the DS (1–2 days); to confirm Active. No CAA record, by decision: Cloudflare's CAs issue our certificates, and a wrong CAA blocks their renewal (all three hosts down) for a small gain |
| 2 | Load balancer | Cloudflare's edge in front of Workers and R2; Supabase's in front of Postgres and functions. No second origin | managed | One Supabase region. If it is down, the catalogue replays from the phone (45-day cache) but nothing new plays. APK has 3 mirrors. Accepted at this size |
| 3 | App servers | Edge functions: request-playback, studio, ingest, transcode, premium-request, delete-account, probe-media, backfill-dimensions, self-test. Workers: stream, console | slice tests in `tool/js/`, local boot `tool/edge_stub/` | Stateless except per-isolate key caches: keep it so |
| 4 | Database | Postgres 17, 19 MB (7 Nov). The app reads PostgREST directly; RLS on every table, 41 with no policy (service role only); 10 RPCs open to anon, each budgeted | `tool/sql/*_test.sql`, advisors | Fine for years at this size. Advisor notices are known and decided (`docs/security_review_2026_11.md`) |
| 5 | Cache | Phone: catalogue (45 days, used when offline or 5xx), posters, the stream cache (segments, sealed). Server: none for the catalogue; film bytes `private, no-store` on purpose (tokens); the Worker's edge block cache is built but off (`EDGE_BLOCK_BYTES=0`) | `test/stream_cache_*` | Every app open asks Postgres. Binds when catalogue RPCs load the database: then a short public cache in a Worker for public rows only |
| 6 | Job queue | Postgres tables (ingest_jobs, transcode state on title_assets, frames, vault_jobs, offsite_jobs) claimed `for update skip locked` by runners; 3 tries then failed; 7 h lease; no pg_cron. The work is started by dispatch the moment it is queued; the `*/5` schedules are the fallback and housekeeping, and GitHub runs them every 3–5 hours (7 Nov: 18:18, 23:17, 02:55) | claim tests, console queue pages | Sound. Anything that only the schedule starts waits hours, not minutes: fine for daily work, never for an alarm |
| 7 | Search | `search_titles`: substring first (exact Burmese phrases), then trigram `word_similarity`; GIN trigram index; Myanmar and Thai get trigrams | migration 015, live `show_trgm` | The fuzzy half cannot use the index: EXPLAIN (7 Nov) shows a Seq Scan; written as `<%` it is a Bitmap Index Scan. Nothing at 9 titles; matters at thousands |
| 8 | Services / API | PostgREST + RPC + edge functions; `docs/client_api_contract.md`, `tool/contract_conformance.py` | check.py | No versioning: old installed apps keep calling. Additive-only; `app_releases.min_supported` is the only lever |
| 9 | Warehouse | `events` (append-only, batches of 25 or 30 s from the app); rollups `event_daily`, `search_daily`; title_heat, reach, co-watch; raw events pruned after 90 days | `events_housekeeping` (078) once a day from the ingest tick; first run 7 Nov 03:46: 35 days, 366 rows, all 2,299 events counted | Fixed 7 Nov: the rollups and the prune had never run |
| 10 | Cloud storage | R2 `innocent-media` (private), `innocent-public` (via cdn.), a third bucket at another company (off-site); DB backup daily, sealed, off-site, 14 days + monthly for a year | `db_backups`; the restore drill (079) opens the newest backup weekly in the ingest function: hash, unseal, gunzip, parse, rows per table. First drill 7 Nov 03:52: backup #47, 50 tables, passed | A full restore into an empty database is still by hand (`tool/restore_backup.py`) |
| 11 | CDN | `cdn.innocentplayer.com` cached by Cloudflare; console assets on Workers Assets; film bytes through the stream Worker, uncached, rate-limited 600 requests / 10 s / install | transport-check | — |

## Beyond the eleven (they matter more here)

- **Security**: `docs/security_review_2026_11.md`, `docs/MEDIA_ENCRYPTION.md`.
- **Abuse and cost**: the Worker's rate limit, `take_playback_budget` per
  install, account and network, premium-request caps.
- **Monitoring**: transport-check runs on a schedule on main (since 7 Nov)
  and e-mails the owner when a viewer could not play; the console Status
  page; the ingest runner's Telegram notices (storage, reports, a failed
  restore drill); Workers logs; Sentry when set (not in release builds).
- **Privacy**: the app's Privacy dialog (`privacyBody`, three languages)
  said it ran offline and sent nothing; rewritten 7 Nov to say what it
  sends (usage records with the 90-day rule, playback, the account,
  reports a user sends). Ships with the next release.

## What the classic picture has that we do not need yet

| Classic | Why not here | When it would be |
|---|---|---|
| Own servers behind a load balancer | Workers and Supabase scale and balance themselves | never, unless we leave them |
| Redis / Memcache | The phone caches; Postgres is 19 MB | catalogue RPCs binding the database |
| RabbitMQ / Kafka | Postgres + `skip locked` + runners | jobs per minute in the thousands |
| Elasticsearch / ELK | pg_trgm search; logs in Supabase and Workers | catalogue in the tens of thousands, or log search across systems |
| A warehouse (BigQuery…) | `events` + rollups in Postgres | events in the millions a month |

## Older documents this replaces

`docs/movies_dataflow.md` and `docs/movies_capacity_model.md` (17 Oct)
predate the stream Worker in front of R2 and the encrypted copies;
`docs/movies_platform_plan.md`, `docs/movies_START_HERE.md` and
`docs/endpoint_config_spec.md` are the October plan. Their reasoning still
reads well; their shape is not today's.
