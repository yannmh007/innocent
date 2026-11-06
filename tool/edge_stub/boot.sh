#!/bin/bash
# Boot one edge function locally against a stand-in REST server, with fake
# keys, for testing an op end to end (skill edge-deploy, step 2).
#
#   tool/edge_stub/boot.sh <function> <workdir> [routes.json]
#     -> the function on http://127.0.0.1:8000/, the stand-in REST on :54399,
#        every REST call recorded in <workdir>/calls.json, deno's output in
#        <workdir>/deno.log. Stop both with: kill $(cat <workdir>/pids)
#
# Runner secret for ops that need one: runner-secret-for-test.
set -euo pipefail
fn="$1"; work="$2"; routes="${3:-}"
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
mkdir -p "$work"
export NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost
DENO="$(command -v deno || true)"
if [ -z "$DENO" ]; then
  echo "deno not on PATH: npm install -g deno (or set DENO=/path/to/deno)" >&2; exit 2
fi
node "$here/fake_rest.mjs" "$work/calls.json" 54399 $routes & echo $! > "$work/pids"
# Fake keys, built here so no key-shaped literal sits in the repository.
fake_secret="sb_secret_""$(printf 'test%.0s' 1 2 3 4 5 6)"
SUPABASE_URL=http://127.0.0.1:54399 \
SUPABASE_SECRET_KEYS="{\"default\":\"$fake_secret\"}" \
SUPABASE_PUBLISHABLE_KEYS='{"default":"sb_publishable_testtesttest"}' \
INGEST_SECRET=runner-secret-for-test TRANSCODE_SECRET=runner-secret-for-test \
R2_ACCOUNT_ID=acct R2_ACCESS_KEY_ID=k R2_SECRET_ACCESS_KEY=s R2_BUCKET=media \
R2_PUBLIC_BUCKET=pub R2_PUBLIC_BASE=https://cdn.example/ \
  "$DENO" run --allow-net --allow-env --import-map="$here/map.json" "$root/docs/edge/$fn.ts" \
  > "$work/deno.log" 2>&1 & echo $! >> "$work/pids"
for _ in $(seq 1 60); do
  curl -s -o /dev/null http://127.0.0.1:8000/ && { echo "up: http://127.0.0.1:8000/ (calls: $work/calls.json)"; exit 0; }
  timeout 0.5 tail -f /dev/null || true
done
echo "did not come up; see $work/deno.log" >&2; exit 1
