#!/usr/bin/env python3
"""How many ingest lanes to open: ingest.yml's plan job, and its tests.

Reads the ingest function's `depth` answer on stdin — {"queued": n,
"running": r} — and the cap (the repository variable INGEST_LANES) as its
argument, and prints the matrix: [1, 2, ..., k] with

    k = max(1, min(cap, queued + running)),   cap in 1..10, 10 when unset.

WHY queued + running. A lane is one job at a time across every run (its
concurrency group). Lanes 1..r may be the ones an earlier run is still busy
in; opening 1..(q + r) leaves at least q of them free whichever numbers the
busy ones hold, so files forwarded behind a long download do not wait for it.

AT LEAST ONE, ALWAYS. One lane is the old workflow: it also does the
Telegram checks, restores, archive and off-site copies when nothing was
forwarded. An answer that cannot be read — the function down, a secret
missing — is one lane, never none and never ten.

    echo '{"queued": 3, "running": 1}' | python3 tool/ingest_lanes.py 10
    [1,2,3,4]

WAIT FOR THE BATCH TO LAND (--settle, what ingest.yml runs). The webhook
starts the workflow on the FIRST file forwarded, and Telegram delivers a
batch one file every second or two: on 30 Oct the plan counted five of
eight, opened five lanes, and the other three queued behind them. So when
anything is waiting, the count is read again every STEP seconds until it
stops growing, at most MAX_WAIT; an empty queue is not waited on, so the
five-minute schedule costs nothing more.

    SB_URL=... RUNNER_SECRET=... python3 tool/ingest_lanes.py --settle 10
    lanes=[1,2,3,4,5,6,7,8]
"""

import json
import os
import sys
import time
import urllib.request

HARD_CAP = 10
STEP = 10
MAX_WAIT = 60


def queued_of(answer):
    try:
        d = json.loads(answer) if answer.strip() else {}
        return max(0, int(d.get('queued') or 0))
    except (ValueError, TypeError, AttributeError):
        return 0


def settle(read, sleep, step=STEP, max_wait=MAX_WAIT, log=lambda m: None):
    """The depth answer once the queue stops growing: read() again every
    [step] seconds while each reading is larger than the one before, for at
    most [max_wait]. Nothing waiting: the first answer, at once."""
    last = read()
    if queued_of(last) == 0:
        return last
    waited = 0
    while waited + step <= max_wait:
        sleep(step)
        waited += step
        now = read()
        log('after %ds: %d waiting (was %d)' % (waited, queued_of(now), queued_of(last)))
        if queued_of(now) <= queued_of(last):
            return now
        last = now
    return last


def fetch_depth():
    """The ingest function's depth answer, or '{}' when it cannot be had."""
    url = os.environ.get('SB_URL', '').rstrip('/')
    secret = os.environ.get('RUNNER_SECRET', '')
    if not url or not secret:
        return '{}'
    req = urllib.request.Request(
        url + '/functions/v1/ingest', data=b'{"op":"depth"}', method='POST',
        headers={'Authorization': 'Bearer ' + secret, 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.read().decode('utf-8', 'replace')
    except Exception:                              # noqa: BLE001
        return '{}'


def lanes(answer, cap_text):
    try:
        cap = int(str(cap_text).strip())
    except ValueError:
        cap = HARD_CAP
    cap = max(1, min(cap, HARD_CAP))
    try:
        d = json.loads(answer) if answer.strip() else {}
        queued = max(0, int(d.get('queued') or 0))
        running = max(0, int(d.get('running') or 0))
    except (ValueError, TypeError, AttributeError):
        queued = running = 0
    k = max(1, min(cap, queued + running)) if queued else 1
    return list(range(1, k + 1))


def as_matrix(numbers):
    return '[' + ','.join(str(n) for n in numbers) + ']'


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--settle':
        cap = args[1] if len(args) > 1 else ''
        answer = settle(fetch_depth, time.sleep,
                        log=lambda m: print(m, file=sys.stderr, flush=True))
        out = lanes(answer, cap)
        print('waiting: %d -> lanes %s' % (queued_of(answer), as_matrix(out)), file=sys.stderr)
        print('lanes=' + as_matrix(out))
    else:
        print(as_matrix(lanes(sys.stdin.read(), args[0] if args else '')))
