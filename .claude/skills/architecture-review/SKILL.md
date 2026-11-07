---
name: architecture-review
description: "Check a feature or the whole Innocent system layer by layer (DNS, edge, functions, database, cache, jobs, search, API, analytics, storage, CDN, plus monitoring, abuse, privacy): what to ask and how to prove it live. Use when a change adds a table, RPC, endpoint, job, schedule, traffic or stored data, or for a periodic health review."
---

# Architecture review

The map is `docs/architecture.md`: each layer, what plays it, how we know,
where it is weak. This skill checks a change (or the whole system) against
it. Proof is live, never from a document: the October plans were wrong by
November.

## 1. Place the change

Say in one line per layer which ones the change touches. A new feature
usually touches 4 (database), 8 (API) and one of 6 (jobs) or 5 (cache).

## 2. Ask, per touched layer

- **DNS / hosts**: a new hostname? Proxied, TLS min 1.2, no workers.dev or
  r2.dev route left on.
- **Load / failover**: what does the phone do when this is down? The
  catalogue replays from its cache; does the new thing degrade, or block?
- **App servers**: stateless? Anything that outlives a request is a row in
  Postgres or an object in R2. Work longer than a request is a job.
- **Database**: grants for anon, authenticated AND service_role; RLS on;
  an index for every filter and foreign key it adds; additive only for
  what the app reads (old versions stay installed).
- **Cache**: may it be cached, and by whom? Public rows may sit in a
  Worker cache; anything per user or tokened is `private, no-store`.
- **Jobs**: claimed `for update skip locked`; an attempts cap; a lease for
  a dead runner; who calls it on a schedule (no pg_cron here: a GitHub
  cron, usually the ingest tick).
- **Search**: does the index serve the operator? pg_trgm GIN serves
  `like '%x%'`, `%`, `<%`; a function call such as `word_similarity() > x`
  does not. Test Myanmar and Thai input.
- **API**: in `docs/client_api_contract.md`; budgeted if anon can call it.
- **Analytics**: through `record_events` with a known kind; nothing that
  names a person; counted in a rollup that something actually runs.
- **Storage**: which bucket; who deletes it and when; in the backup or the
  off-site copy?
- **CDN**: public and cacheable, with a Cache-Control, or private and not.
- **Monitoring**: how would we learn it broke? A scheduled check on main
  alerts the owner by e-mail; a dispatch-only one alerts nobody.
- **Abuse and cost**: a rate limit or budget; the Worker request and R2
  operation counts it adds at 10× today's users.
- **Privacy**: does it send anything new off the phone? Then the Privacy
  text (`privacyBody`, three languages) must say so.

## 3. Prove it live (read-only)

```sql
-- size and the biggest tables
select pg_size_pretty(pg_database_size(current_database()));
-- does a query use its index? (inside a transaction)
begin; set local enable_seqscan = off; explain <the query>; rollback;
-- do the rollups run?
select max(day) from public.event_daily;  -- null = never
-- jobs stuck or given up
select state, count(*) from public.ingest_jobs group by 1;
-- last backup and its off-site copy
select max(taken_at), max(offsite_at) from public.db_backups where deleted_at is null;
```

And `get_advisors` (security and performance): every notice is either
already decided in `docs/security_review_2026_11.md` or new work.

## 4. Record

- The layer's row in `docs/architecture.md` (what, how we know, weak point).
- A gap becomes a BACKLOG item with its trigger ("when X binds").
- A lesson becomes a rule in `.claude/rules/` for the files it concerns.
