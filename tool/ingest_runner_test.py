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


class FakeDocument:
    def __init__(self, unique_id, size):
        self.file_unique_id = unique_id
        self.file_size = size


class FakeMessage:
    def __init__(self, mid):
        self.id = mid
        self.empty = mid in W.gone
        media = W.media.get(mid)
        self.document = FakeDocument(*media) if media else None


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
        self.media = {}                  # message_id -> (file_unique_id, size)
        self.gone = set()                # message ids that no longer exist
        self.puts = []
        self.short = {}                  # message_id -> bytes actually delivered
        self.copies = []                 # (to_chat, from_chat, message_id)
        self.sends = []                  # (to_chat, path size)
        self.chat_error = None           # text: get_chat on the archive fails
        self.r2_size = None              # bytes a presigned GET delivers


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

    def get_chat(self, chat_id):
        if W.chat_error:
            raise RuntimeError(W.chat_error)
        return types.SimpleNamespace(id=chat_id)

    def copy_message(self, chat_id, from_chat_id, message_id, caption=None):
        W.copies.append((chat_id, from_chat_id, message_id))
        src = W.media.get(message_id)
        sent = types.SimpleNamespace(id=900 + message_id,
                                     chat=types.SimpleNamespace(id=chat_id))
        sent.document = FakeDocument(*src) if src else None
        return sent

    def send_document(self, chat_id, path, caption=None, file_name=None,
                      force_document=None):
        size = os.path.getsize(path)
        W.sends.append((chat_id, size))
        sent = types.SimpleNamespace(id=777, chat=types.SimpleNamespace(id=chat_id))
        sent.document = FakeDocument('sent-uniq', size)
        return sent

    def download_media(self, msg, file_name):
        size = msg.document.file_size if msg.document else 1000 + msg.id
        size = W.short.get(msg.id, size)
        with open(file_name, 'wb') as fh:
            fh.write(b'x' * size)
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


def vjob(n, kind, unique='u%d', size=None):
    return {
        'job_id': '%s-%d' % (kind, n), 'type': kind, 'tg_chat_id': 1, 'tg_message_id': n,
        'tg_unique_id': unique % n if '%' in unique else unique,
        'bytes': size if size is not None else 5000 + n,
        'put_url': 'https://r2.invalid/put/v%d' % n if kind == 'restore' else None,
        'done_url': 'https://edge.invalid/ingest',
    }


def ajob(n, forwarded=True, size=None):
    """An archive job: a forwarded film (chat + message) or a console upload
    (a presigned GET and nothing in Telegram)."""
    return {
        'job_id': 'archive-%d' % n, 'type': 'archive', 'archive_chat': -100555,
        'tg_chat_id': 1 if forwarded else None,
        'tg_message_id': n if forwarded else None,
        'tg_unique_id': 'u%d' % n if forwarded else None,
        'bytes': size if size is not None else 5000 + n,
        'title': 'Film %d' % n, 'file_name': 'film-%d.mp4' % n,
        'get_url': None if forwarded else 'https://r2.invalid/get/%d' % n,
        'put_url': None, 'done_url': 'https://edge.invalid/ingest',
    }


def run(first, rest, env=None, start_flood=None, flood=None, error=None,
        media=None, gone=None, short=None, chat_error=None, r2_size=None):
    """One runner invocation in a scratch directory. Answers (rc, edge).

    `env` entries set to None are REMOVED for the run, which is how the
    missing-credentials case is made.
    """
    global W
    W = World()
    W.flood_on_start = start_flood
    W.flood_on_message = flood or {}
    W.error_on_message = error or {}
    W.media = media or {}
    W.gone = set(gone or ())
    W.short = dict(short or {})
    W.chat_error = chat_error
    W.r2_size = r2_size
    tmp = tempfile.mkdtemp(prefix='ingest-test-')
    ingest.JOB_FILE = os.path.join(tmp, 'ingest.json')
    ingest.REPORTED = os.path.join(tmp, 'ingest.reported')
    with open(ingest.JOB_FILE, 'w') as fh:
        json.dump(first, fh)
    edge = Edge(rest)
    ingest._post = edge.post
    def put(path, url):
        W.puts.append(url)
        return os.path.getsize(path)
    ingest.put_to_r2 = put
    def get(url, path):
        size = W.r2_size if W.r2_size is not None else 0
        with open(path, 'wb') as fh:
            fh.write(b'y' * size)
        return size
    ingest.get_from_r2 = get
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

# ── THE STORAGE POLICY'S JOBS RIDE THE SAME SIGN-IN ───────────────────────
#
# A forwarded film, then a check of a Telegram copy, then a restore — one run,
# one client, each answered through the op its type belongs to.
rc, edge = run(job(1), [vjob(7, 'verify'), vjob(8, 'restore')],
               media={1: ('x', 1001), 7: ('u7', 5007), 8: ('u8', 5008)})
check('ingest, verify and restore in one run: still one sign-in', W.started == 1)
check('the forwarded film is reported through done', len(edge.ops('done')) == 1)
vd = {c['job_id']: c for c in edge.ops('vault_done')}
check('the check and the restore are reported through vault_done',
      set(vd) == {'verify-7', 'restore-8'})
check('a copy that is there is "ok"',
      vd.get('verify-7', {}).get('state') == 'ok' and vd['verify-7'].get('ok') is True)
check('a restore PUTs to the URL it was given and reports the bytes',
      'https://r2.invalid/put/v8' in W.puts and vd.get('restore-8', {}).get('bytes') == 5008)
check('a verify uploads nothing', not [u for u in W.puts if u.endswith('/v7')])

# the verdicts
rc, edge = run(vjob(9, 'verify'), [], gone={9})
c = (edge.ops('vault_done') or [{}])[0]
check('a deleted message is "missing" — a verdict, not an error',
      c.get('state') == 'missing' and c.get('ok') is True)
rc, edge = run(vjob(10, 'verify'), [], media={10: ('other', 1234)})
c = (edge.ops('vault_done') or [{}])[0]
check('a different file in the message is "changed"', c.get('state') == 'changed')
rc, edge = run(vjob(11, 'verify'), [], media={11: ('re-encoded-id', 5011)})
c = (edge.ops('vault_done') or [{}])[0]
check('a different id but the same size is still "ok"', c.get('state') == 'ok')

# a restore of a message that is gone fetches nothing
rc, edge = run(vjob(12, 'restore'), [], gone={12})
c = (edge.ops('vault_done') or [{}])[0]
check('a restore with nothing to fetch fails, and PUTs nothing',
      c.get('ok') is False and not W.puts)

# a wait during a check costs nothing
rc, edge = run(vjob(13, 'verify'), [vjob(14, 'verify')], flood={13: 900},
               media={13: ('u13', 5013), 14: ('u14', 5014)})
check('a FLOOD_WAIT on a check defers it through vault_defer',
      [c['job_id'] for c in edge.ops('vault_defer')] == ['verify-13'] and
      not edge.ops('vault_done') and not edge.ops('defer'))

# no credentials, with a check in hand
rc, edge = run(vjob(15, 'verify'), [], env={'TG_BOT_TOKEN': None})
check('missing credentials on a check are reported through vault_done',
      any(not c['ok'] and 'credentials' in c['note'] for c in edge.ops('vault_done'))
      and not edge.ops('done'))

# ── A SHORT DOWNLOAD IS NEVER UPLOADED (2026-09-29) ─────────────────────
#
# Telegram's GetFile timed out mid-file and the client handed back the first
# 17 MiB of a 70 MB film; the runner printed a note, uploaded it and said ok.
rc, edge = run(job(1), [job(2)], media={1: ('x', 69870661), 2: ('y', 1002)},
               short={1: 17825792})
d = {c['job_id']: c for c in edge.ops('done')}
check('a download that stopped short is reported as a failure',
      d.get('job-1', {}).get('ok') is False and 'stopped at 17825792 of 69870661' in d['job-1'].get('note', ''))
check('and is not uploaded', 'https://r2.invalid/put/1' not in W.puts)
check('and the queue carries on', d.get('job-2', {}).get('ok') is True)
# Telegram's own size wins over what the job was queued with.
j = job(3); j['bytes'] = 0
rc, edge = run(j, [], media={3: ('z', 4114697)}, short={3: 3145728})
check('Telegram\'s size is checked even when the job has none',
      (edge.ops('done') or [{}])[0].get('ok') is False)
# A restore is held to the same rule.
rc, edge = run(vjob(16, 'restore'), [], media={16: ('u16', 5016)}, short={16: 4096})
c = (edge.ops('vault_done') or [{}])[0]
check('a short restore is not uploaded either', c.get('ok') is False and not W.puts)

# ── THE ARCHIVE CHANNEL (migration 032) ─────────────────────────────────
#
# A forwarded film is copied by Telegram itself; a console upload is fetched
# from R2 and sent. Both answer where the copy now is, through vault_done with
# type 'archive' — and nothing ever goes to R2.
rc, edge = run(ajob(20), [ajob(21, forwarded=False)],
               media={20: ('u20', 5020)}, r2_size=5021)
va = {c['job_id']: c for c in edge.ops('vault_done')}
check('this runner asks for archive work when it claims',
      all(c.get('can') == ['archive'] for c in edge.ops('claim')) and edge.ops('claim'))
check('a forwarded film is COPIED into the channel, not downloaded',
      W.copies == [(-100555, 1, 20)])
check('and reported where it now is, with the same file',
      va.get('archive-20', {}).get('type') == 'archive' and va['archive-20'].get('ok') is True
      and va['archive-20'].get('chat_id') == -100555 and va['archive-20'].get('message_id') == 920
      and va['archive-20'].get('unique_id') == 'u20' and va['archive-20'].get('bytes') == 5020)
check('a console upload is fetched from R2 and SENT to the channel',
      W.sends == [(-100555, 5021)] and va.get('archive-21', {}).get('ok') is True
      and va['archive-21'].get('message_id') == 777)
check('an archive job writes nothing to R2', not W.puts)
check('still one sign-in', W.started == 1)

rc, edge = run(ajob(22, forwarded=False), [], r2_size=100)
c = (edge.ops('vault_done') or [{}])[0]
check('a short fetch from R2 is not sent to the archive',
      c.get('ok') is False and 'fetched 100 of 5022' in c.get('note', '') and not W.sends)

rc, edge = run(ajob(23), [], gone={23})
c = (edge.ops('vault_done') or [{}])[0]
check('a forwarded message that is gone is not "archived"',
      c.get('ok') is False and not W.copies)

rc, edge = run(ajob(24), [], media={24: ('u24', 5024)}, chat_error='CHANNEL_PRIVATE')
c = (edge.ops('vault_done') or [{}])[0]
check('a channel the bot cannot reach is said plainly, and nothing is sent',
      c.get('ok') is False and 'archive channel' in c.get('note', '') and not W.copies)

rc, edge = run(ajob(25), [ajob(26)], flood={25: 900}, media={26: ('u26', 5026)})
check('a FLOOD_WAIT on an archive job defers it and ends the run',
      [c['job_id'] for c in edge.ops('vault_defer')] == ['archive-25'] and
      not edge.ops('vault_done'))

rc, edge = run(ajob(27), [], env={'TG_API_ID': None})
check('missing credentials on an archive job are reported as one',
      any(c.get('type') == 'archive' and not c['ok'] for c in edge.ops('vault_done')))

print()
if failures:
    print('=== %d runner check(s) FAILED ===' % failures)
    sys.exit(1)
print('=== runner: one sign-in per run, and a wait is never a failure ===')
