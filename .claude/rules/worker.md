---
paths:
  - "docs/worker/**"
---

# The stream Worker (docs/worker)

- **A per-isolate cache keeps a settled value, never a promise.** A promise
  belongs to the request that made it: when that request ends first (a
  phone cutting a read — the app's warm-up does, every time Play takes the
  film over), the runtime refuses every other request's await of it ("This
  promise was created by a request that has since ended, so it can never
  settle", handle_cross_request_promise_resolution) — a 500. Why: on 20 Nov
  2026 `strayIndexes` kept the first request's pending bucket read; 166
  front reads of one rung answered 500 for 43-68 s, the starts that stood
  still in device lab T2 (fixed fbaf697d; T4 before 4 of 12 passes, T5
  after 0 of 12). How: `const known = cache.get(k); if (known) return
  known;` then await your own read, and `cache.set(k, value)` only after
  it settled; do not keep a failed read. tool/js/worker_cache_test.mjs
  checks every `*Cache.set` in the Worker.
- **The Worker deploys from main**: a push of `docs/**` to main rebuilds
  both Workers (Workers Builds, about a minute). A Worker change is the
  owner's call; prove it after with `workers_list` (modified_on), the
  deployed code (`workers_get_worker_code`, grep), the Playback check and
  the transport check on main, and the Worker's Observability logs (the
  owner exports them: the dashboard is not reachable from the sandbox).
