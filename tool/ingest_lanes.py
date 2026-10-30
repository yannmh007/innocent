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
"""

import json
import sys

HARD_CAP = 10


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


if __name__ == '__main__':
    out = lanes(sys.stdin.read(), sys.argv[1] if len(sys.argv) > 1 else '')
    print('[' + ','.join(str(n) for n in out) + ']')
