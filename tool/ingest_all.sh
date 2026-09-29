#!/usr/bin/env bash
#
# Drain the ingest queue, rather than taking one file and leaving.
#
# WHY THIS EXISTS. The workflow used to claim exactly one job and exit, on the
# reasoning that it ticks every five minutes so the queue drains itself. It
# does not tick every five minutes. `*/5` is what GitHub accepts, not what it
# runs: measured across a morning, the Ingest schedule fired at 02:59, 03:19,
# 03:37, 03:53, 04:07, 04:26, 04:44, 04:58 — fourteen to twenty minutes apart,
# because a cron on a free public repository is best effort and queues behind
# everyone else's. A title's artwork sent as one album of ten photos would
# therefore take between two and three hours to land, and the operator would
# spend it wondering whether the thing was broken.
#
# So one run takes as many as it can. The claim is already safe to call in a
# loop — `claim_ingest` locks and skips — and the marginal cost of a second
# job in a runner that is already booted, has already installed pyrogram and
# already has a warm link to Telegram is the transfer itself.
#
# WHAT BOUNDS IT. A time budget, not a job count: the jobs are films and a
# gigabyte is minutes. The workflow's own timeout is 120 minutes, and stopping
# at 90 leaves room for the job in hand to finish rather than being killed
# halfway with a part-written object and a row stuck on 'running' until the
# seven-hour recovery. Whatever is left is picked up by the next tick.
#
# THE CRASH BACKSTOP IS IN HERE, not in a final `if: failure()` step, and that
# is the reason this is a script at all. `ingest.py` reports its own failures
# and leaves a marker saying so; a step that fires only at the end of the job
# could only ever report the LAST job, so in a loop the first four failures
# would be invisible and the fifth would be blamed. Here it is checked per
# job, immediately, while the claim response for that job is still in hand.
set -uo pipefail

JOB_FILE=/tmp/ingest.json
REPORTED=/tmp/ingest.reported

: "${SB_URL:?SB_URL is not set}"
: "${RUNNER_SECRET:?RUNNER_SECRET is not set}"
# The same secret under the name `ingest.py` already reads it by. Two names
# for one string is the existing convention here: the claim presents it as a
# bearer token, the report puts it in the body.
: "${JOB_TOKEN:?JOB_TOKEN is not set}"

# Minutes, against the workflow's own 120.
BUDGET_MIN="${INGEST_BUDGET_MIN:-90}"
deadline=$(( $(date +%s) + BUDGET_MIN * 60 ))

# A belt to the budget's braces. Nothing should ever queue this many at once,
# and a loop that cannot end is worse than a queue that waits for the next
# tick.
MAX_JOBS="${INGEST_MAX_JOBS:-40}"

done_count=0
fail_count=0

# Report a job that died without reporting itself — a runner killed for
# memory, a python that never reached its own except. The payload is built by
# python rather than by string concatenation because a file name is in it.
report_crash() {
  python3 - <<'PY' > /tmp/ingest-crash.json
import json, os
job = json.load(open('/tmp/ingest.json'))
print(json.dumps({
  'op': 'done',
  'token': os.environ['JOB_TOKEN'],
  'job_id': job['job_id'],
  'ok': False,
  'note': 'runner failed - see the Ingest run in Actions',
}))
PY
  curl -fsS -X POST "$(python3 -c "import json;print(json.load(open('/tmp/ingest.json'))['done_url'])")" \
    -H 'Content-Type: application/json' -d @/tmp/ingest-crash.json >/dev/null || true
  rm -f /tmp/ingest-crash.json
}

# Ask for the next job. Writes JOB_FILE and answers 0 when there is one.
#
# THE PAYLOAD IS NEVER PRINTED. It carries a presigned PUT, and a run log on a
# public repository is public.
claim_next() {
  local code
  code=$(curl -sS -o "$JOB_FILE" -w '%{http_code}' \
    -X POST "$SB_URL/functions/v1/ingest" \
    -H "Authorization: Bearer $RUNNER_SECRET" \
    -H 'Content-Type: application/json' \
    -d '{"op":"claim"}') || return 1
  [ "$code" = "200" ] || { echo "claim returned $code"; return 1; }
  python3 -c "import json,sys; sys.exit(0 if json.load(open('$JOB_FILE')).get('job_id') else 1)"
}

while :; do
  rm -f "$REPORTED"
  if python3 tool/ingest.py; then
    done_count=$((done_count + 1))
  else
    fail_count=$((fail_count + 1))
    # It said why itself. Anything else here would overwrite the one message
    # the operator can act on with "runner failed, see Actions".
    if [ ! -f "$REPORTED" ]; then
      echo "the runner died without reporting; saying so for it"
      report_crash
    fi
  fi

  # A FAILED JOB DOES NOT STOP THE QUEUE. One unreachable file should not hold
  # up the nine behind it, and finish_ingest has already decided whether that
  # one goes round again or is spent.
  if [ $((done_count + fail_count)) -ge "$MAX_JOBS" ]; then
    echo "stopping at $MAX_JOBS jobs; the next tick takes the rest"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "stopping after ${BUDGET_MIN}m; the next tick takes the rest"
    break
  fi
  if ! claim_next; then
    echo "queue is empty"
    break
  fi
  echo "next job claimed"
done

echo "moved $done_count, failed $fail_count"
# ALWAYS ZERO. Every failure above has already been reported to the database,
# which is where the operator looks; failing the workflow as well would mark
# the run red for a file that was simply unreachable and tell nobody anything
# they cannot already see in the console.
exit 0
