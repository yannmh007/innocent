---
name: edge-deploy
description: "Deploy a Supabase edge function of Innocent (docs/edge/*.ts) from a pushed commit and prove it is live. Use for every edge function change."
---

# Deploying an edge function

1. **What is live now:** `get_edge_function` → the shim's SHA. Diff the
   function and every module it imports against that SHA
   (`git diff <sha> -- docs/edge/<name>.ts docs/edge/<imports>`). Only your
   change may differ.
2. **Test it:** the `tool/js/*_test.mjs` that cover the file; `python3
   tool/check.py`. For a changed op, boot it locally:
   `tool/edge_stub/boot.sh <name> <workdir> [routes.json]` (deno on PATH;
   `npm install -g deno` if missing). It starts a stand-in REST server that
   records every call and answers from the routes file, with fake keys and
   the runner secret `runner-secret-for-test`. Drive the op with curl on
   127.0.0.1:8000, read `<workdir>/calls.json`, then `kill $(cat <workdir>/pids)`.
3. **Live database parts** (grants, RPCs it calls) first: skill
   `live-db-change`.
4. **Commit and push**, then deploy the shim:
   `deploy_edge_function` name `<name>`, entrypoint `index.ts`, content
   `import 'https://raw.githubusercontent.com/yannmh007/innocent/<pushed sha>/docs/edge/<name>.ts';`,
   `verify_jwt: false` (true only for premium-request and delete-account).
5. **Prove it:** `list_edge_functions` shows the new version; then a real
   call answers 200 (dispatch the runner that calls it, or wait for the
   console/app) — `query_logs` on `function_edge_logs` for the function's
   URL since the deploy; boot errors show as 5xx or "boot error". A deploy
   that did not take shows the old version: deploy again.
6. Record the version in BACKLOG next to what it carries.
