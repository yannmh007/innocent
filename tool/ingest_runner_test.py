#!/usr/bin/env python3
"""The Telegram runner, against a fake Telegram.

WHY THIS EXISTS. The first queue-draining run signed in to Telegram once per
file. Nothing in the repository could have seen that: the loop was a shell
script around tool/ingest.py, ingest.py signed in every time it started, and
each piece was correct on its own. Telegram saw fifteen sign-ins in two
minutes, answered FLOOD_WAIT on `auth.ImportBotAuthorization`, and seven good
files had their three attempts spent in under a minute.

So the property that matters is checked directly: HOW MANY TIMES THE CLIENT
IS CONSTRUCTED AND STARTED for a run of several jobs. One. And the second
property, that a FLOOD_WAIT is never reported as a failed attempt.

No network, no pyrogram install: a fake `pyrogram` module is put in
sys.modules before the runner imports it, and the runner's two ways out —
`_post` for the edge function and `put_to_r2` for R2 — are replaced with
recorders.

RUN:  python3 tool/ingest_runner_test.py
"""

import json
import os
import sys
import tempfile
import types

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

failures = 0


def check(label, ok):
    global failures
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        failures += 1


# ── a fake Telegram ───────────────────────────────────────────────────────
class FloodWait(Exception):
    def __init__(self, value):
        super().__init__('FLOOD_WAIT_%d' % value)
        self.value = value


class FakeMessage:
    def __init__(self, mid):
        self.id = mid
        self.empty = False


class World:
    """What the fake client does, set per test."""
    def __init__(self):
        self.constructed = 0
        self.started = 0
        self.stopped = 0
        self.kwargs = None
        self.flood_on_start = None       # seconds, or None
        self.flood_on_message = {}       # message_id -> seconds
        self.error_on_message = {}       # message_id -> text


W = World()


class Client:
    def __init__(self, name, **kwargs):
        W.constructed += 1
        W.kwargs = kwargs

    def start(self):
        W.started += 1
        if W.flood_on_start is not None:
            raise FloodWait(W.flood_on_start)

    def stop(self):
        W.stopped += 1

    def get_messages(self, chat_id, message_id):
        if message_id in W.flood_on_message:
            raise FloodWait(W.flood_on_message[message_id])
        if message_id in W.error_on_message:
            raise RuntimeError(W.error_on_message[message_id])
        return FakeMessage(message_id)

    def download_media(self, msg, file_name):
        with open(file_name, 'wb') as fh:
            fh.write(b'x' * (1000 + msg.id))
        return file_name


fake = types.ModuleType('pyrogram')
fake.Client = Client
fake_errors = types.ModuleType('pyrogram.errors')
fake_errors.FloodWait = FloodWait
fake.errors = fake_errors
sys.modules['pyrogram'] = fake
sys.modules['pyrogram.errors'] = fake_errors

import ingest  # noqa: E402  (after the fake is in place)


# ── the edge function, recorded ───────────────────────────────────────────
class Edge:
    def __init__(self, queue):
        self.queue = list(queue)     # jobs still to be claimed after the first
        self.calls = []

    def post(self, url, payload, bearer=None):
        self.calls.append(payload)
        if payload.get('op') == 'claim':
            if self.queue:
                return 200, self.queue.pop(0)
            return 200, {}
        return 200, {'ok': True}

    def ops(self, op):
        return [c for c in self.calls if c.get('op') == op]


def job(n):
    return {
        'job_id': 'job-%d' % n, 'tg_chat_id': 1, 'tg_message_id': n,
        'bytes': 1000 + n, 'put_url': 'https://r2.invalid/put/%d' % n,
        'done_url': 'https://edge.invalid/ingest',
    }


def run(first, rest, env=None, start_flood=None, flood=None, error=None):
    """One runner invocation in a scratch directory. Answers (rc, edge).

    `env` entries set to None are REMOVED for the run, which is how the
    missing-credentials case is made.
    """
    global W
    W = World()
    W.flood_on_start = start_flood
    W.flood_on_message = flood or {}
    W.error_on_message = error or {}
    tmp = tempfile.mkdtemp(prefix='ingest-test-')
    ingest.JOB_FILE = os.path.join(tmp, 'ingest.json')
    ingest.REPORTED = os.path.join(tmp, 'ingest.reported')
    with open(ingest.JOB_FILE, 'w') as fh:
        json.dump(first, fh)
    edge = Edge(rest)
    ingest._post = edge.post
    ingest.put_to_r2 = lambda path, url: os.path.getsize(path)
    base = {
        'TG_API_ID': '1', 'TG_API_HASH': 'h', 'TG_BOT_TOKEN': 't',
        'JOB_TOKEN': 'tok', 'RUNNER_SECRET': 'tok',
        'SB_URL': 'https://edge.invalid',
    }
    base.update(env or {})
    saved = {k: os.environ.get(k) for k in base}
    for k, v in base.items():
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        rc = ingest.main()
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
    edge.marker = open(ingest.REPORTED).read() \
        if os.path.exists(ingest.REPORTED) else None
    return rc, edge


# ── ONE SIGN-IN FOR THE WHOLE QUEUE ───────────────────────────────────────
rc, edge = run(job(1), [job(2), job(3), job(4), job(5)])
check('five jobs are all moved', len([c for c in edge.ops('done') if c['ok']]) == 5)
check('THE CLIENT IS BUILT ONCE for five jobs', W.constructed == 1)
check('AND SIGNS IN ONCE for five jobs', W.started == 1)
check('and signs out at the end', W.stopped == 1)
check('the queue is asked until it is empty', len(edge.ops('claim')) == 5)
check('the run exits 0', rc == 0)
check('short waits are left to the client to sleep through',
      (W.kwargs or {}).get('sleep_threshold', 0) >= 60)
check('no session file is written to the runner',
      (W.kwargs or {}).get('in_memory') is True)
check('the marker names the last job reported, not just "something"',
      edge.marker == 'job-5')

# ── A WAIT ON SIGN-IN IS NOT A FAILURE ────────────────────────────────────
#
# The exact failure that happened: FLOOD_WAIT on auth.ImportBotAuthorization.
# It used to be reported through `done` with ok=false, which spends one of the
# job's three attempts on Telegram's scheduling.
rc, edge = run(job(1), [job(2)], start_flood=394)
check('a FLOOD_WAIT on sign-in defers the job', len(edge.ops('defer')) == 1)
check('with the seconds Telegram asked for',
      edge.ops('defer') and edge.ops('defer')[0]['seconds'] == 394)
check('and does NOT report it as a failed attempt',
      not [c for c in edge.ops('done') if not c['ok']])
check('and claims nothing more, since the next sign-in would be refused too',
      not edge.ops('claim'))
check('the run still exits 0 — a wait is not a broken run', rc == 0)

# ── A WAIT IN THE MIDDLE ENDS THE RUN, AND COSTS NOTHING ──────────────────


rc, edge = run(job(1), [job(2), job(3)], flood={2: 900})
oks = [c['job_id'] for c in edge.ops('done') if c['ok']]
check('the job before the wait is moved', oks == ['job-1'])
check('the job that met the wait is deferred, not failed',
      [c['job_id'] for c in edge.ops('defer')] == ['job-2'] and
      not [c for c in edge.ops('done') if not c['ok']])
check('nothing after it is claimed in this run',
      len(edge.ops('claim')) == 1)
check('still one sign-in', W.started == 1)

# ── A BROKEN FILE DOES NOT STOP THE QUEUE ─────────────────────────────────
rc, edge = run(job(1), [job(2), job(3)], error={2: 'message vanished'})
done = {c['job_id']: c['ok'] for c in edge.ops('done')}
check('the file that broke is reported failed', done.get('job-2') is False)
check('and the files either side of it still move',
      done.get('job-1') is True and done.get('job-3') is True)
check('its reason reaches the console',
      any('message vanished' in c.get('note', '') for c in edge.ops('done')))

# ── NO CREDENTIALS: ONE REPORT, NO SIGN-IN, NO STAMPEDE ───────────────────
rc, edge = run(job(1), [job(2), job(3)], env={'TG_API_HASH': None})
check('missing credentials are reported on the job in hand',
      any(not c['ok'] and 'credentials' in c['note'] for c in edge.ops('done')))
check('without building a client', W.constructed == 0)
check('and without claiming the rest only to fail them the same way',
      not edge.ops('claim'))

print()
if failures:
    print('=== %d runner check(s) FAILED ===' % failures)
    sys.exit(1)
print('=== runner: one sign-in per run, and a wait is never a failure ===')
