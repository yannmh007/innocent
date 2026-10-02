#!/usr/bin/env python3
"""Move forwarded Telegram files into R2 — every one queued, in one sign-in.

Run by .github/workflows/ingest.yml after the first job has been claimed.
Reads /tmp/ingest.json — the claim response — and:

  1. signs in to Telegram AS THE BOT over MTProto, ONCE,
  2. for that job and every job claimed after it in the same run:
       fetches the forwarded message and downloads its media,
       PUTs the file at the presigned URL the claim handed over,
       reports the real byte count back, which is what creates the
       catalogue row and queues the transcode,
  3. stops when the queue is empty, the time budget is spent, or Telegram
     asks for a wait longer than is worth sitting through.

ONE SIGN-IN PER RUN, AND THAT IS THE WHOLE POINT OF THE LOOP BEING HERE. The
first version of the queue-draining run looped in a shell script around this
file, and this file signed in every time it started. Fifteen files meant
fifteen sign-ins inside two minutes; Telegram throttled them with FLOOD_WAIT
on `auth.ImportBotAuthorization`, each throttled job was claimed again a
second later by the same loop and throttled again, and seven good files had
their three attempts spent in under a minute. The fetches were never the
problem — the sign-ins were. One session now carries every job of the run.

A WAIT IS NOT A FAILURE. FLOOD_WAIT is Telegram scheduling the bot, not a
verdict on the file. Waits up to SLEEP_THRESHOLD are slept through by the
client itself; a longer one gives the job back with `defer`, which returns
the attempt the claim took, and ends the run — every further call would be
refused the same way, and the next scheduled run is later than the wait.

WHY MTProto AND NOT THE BOT API. The cloud Bot API refuses to download
anything over 20 MB, and moving the bot to a self-hosted Bot API server —
which would lift that to 2000 MB — requires logging it out of the cloud API
first, after which the cloud API stops delivering the updates that put films
in this queue in the first place. An MTProto session for the same bot is
separate from the Bot API's, so both work at once, and it has no such limit.

NO USER SESSION STRING ANYWHERE. `api_id` and `api_hash` identify an
application, not a person, and the login here is `bot_token=`. A user session
string would be the operator's entire Telegram account, and this feature is
not worth that.

THE SAME LOOP CARRIES THE STORAGE POLICY'S TELEGRAM WORK (migration 029).
When nothing has been forwarded, a claim can hand out one of two other jobs,
marked by `type`:

  verify   fetch the message a film came from and say whether the same file
           is still there — the bin will not delete the R2 copy of a film
           whose only other copy is in Telegram until this has said yes;
  restore  download that file again and PUT it back at the key it had.

Both answer through `vault_done` / `vault_defer` instead of `done` / `defer`.

WHAT THIS SCRIPT NEVER SEES: an R2 key. The destination is a presigned PUT
scoped to one object, minted by the edge function and expiring the same day.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

JOB_FILE = '/tmp/ingest.json'
REPORTED = '/tmp/ingest.reported'

# Waits up to this long are slept through by the client, inside the run. Five
# minutes: long enough to absorb the waits Telegram asks of a bot that signs in
# once and then downloads steadily, short enough that a run never sits idle
# for longer than GitHub would take to schedule the next one anyway.
SLEEP_THRESHOLD = 300

# The run's own limits. Minutes against the workflow's 120, so the job in hand
# can finish rather than be killed halfway with a part-written object and a
# row stuck on 'running' until the seven-hour recovery in claim_ingest.
BUDGET_MIN = int(os.environ.get('INGEST_BUDGET_MIN', '90') or 90)
# A belt to the budget's braces. Nothing should queue this many at once, and a
# loop that cannot end is worse than a queue that waits for the next tick.
MAX_JOBS = int(os.environ.get('INGEST_MAX_JOBS', '40') or 40)


def load_job():
    with open(JOB_FILE, 'r', encoding='utf-8') as fh:
        return json.load(fh)


def _post(url, payload, bearer=None):
    """POST JSON with curl; answer (status, parsed body).

    curl rather than urllib so the body goes in a file and never onto a
    command line, where it would be visible in the process list — it carries
    the runner token. The response goes to a file for the same reason in the
    other direction: a claim response carries a presigned PUT, and nothing
    here prints it.
    """
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
        fh.write(json.dumps(payload))
        body_path = fh.name
    out_path = body_path + '.out'
    cmd = ['curl', '-sS', '-o', out_path, '-w', '%{http_code}',
           '-X', 'POST', url,
           '-H', 'Content-Type: application/json', '-d', '@' + body_path]
    if bearer:
        # A header file, not `-H 'Authorization: …'`, for the same reason as
        # the body: argv is readable by every process on the machine.
        hdr_path = body_path + '.hdr'
        with open(hdr_path, 'w') as hf:
            hf.write('Authorization: Bearer %s\n' % bearer)
        cmd += ['-H', '@' + hdr_path]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, check=False)
        code = int((r.stdout or '0').strip() or 0)
        try:
            with open(out_path, 'r', encoding='utf-8') as fh:
                parsed = json.load(fh)
        except (OSError, ValueError):
            parsed = {}
        return code, parsed
    finally:
        for path in (body_path, out_path, body_path + '.hdr'):
            try:
                os.unlink(path)
            except OSError:
                pass


def report(job, ok, note, size=None):
    """Tell the edge function how it went.

    ALWAYS CALLED, on success and on failure, because the alternative is a
    row that says 'running' until the seven-hour recovery in claim_ingest
    takes it back — during which the console shows a film as arriving that
    is not.

    LEAVES A MARKER naming THIS job, so the workflow's own failure reporter
    knows to stand down for it. This script reports the reason it knows —
    "Telegram credentials are not set on this repository" — and the
    `if: failure()` step used to fire anyway and overwrite it with the generic
    "runner failed - see the Ingest run in Actions". The marker holds the job
    id rather than just existing, because one run now handles many jobs and
    the backstop must only stand down for the one that was actually reported.
    """
    payload = {
        'op': 'done',
        'token': os.environ['JOB_TOKEN'],
        'job_id': job['job_id'],
        'ok': bool(ok),
        'note': str(note)[:300],
    }
    if size is not None:
        payload['bytes'] = int(size)
    _post(job['done_url'], payload)
    # Best effort, and deliberately after the report: a marker written for a
    # report that never went out would silence the backstop.
    try:
        with open(REPORTED, 'w') as fh:
            fh.write(str(job['job_id']))
    except OSError:
        pass


def defer(job, seconds):
    """Give the job back without spending an attempt: Telegram said wait.

    Marked as reported too — it has been dealt with, and the backstop saying
    "runner failed" over it would turn a wait back into a failure.
    """
    _post(job['done_url'], {
        'op': 'defer',
        'token': os.environ['JOB_TOKEN'],
        'job_id': job['job_id'],
        'seconds': int(seconds or 0),
    })
    try:
        with open(REPORTED, 'w') as fh:
            fh.write(str(job['job_id']))
    except OSError:
        pass


def vault_report(job, ok, state=None, note='', size=None):
    """Tell the edge function how a verify or restore job went.

    `state` is the verdict on a verify — 'ok', 'missing' or 'changed'. `ok`
    False means this run could not tell (an error, not a verdict), which the
    database counts as one of three attempts.
    """
    payload = {
        'op': 'vault_done',
        'token': os.environ['JOB_TOKEN'],
        'job_id': job['job_id'],
        'ok': bool(ok),
        'note': str(note)[:300],
    }
    if state:
        payload['state'] = state
    if size is not None:
        payload['bytes'] = int(size)
    _post(job['done_url'], payload)
    try:
        with open(REPORTED, 'w') as fh:
            fh.write(str(job['job_id']))
    except OSError:
        pass


def vault_defer(job, seconds):
    _post(job['done_url'], {
        'op': 'vault_defer',
        'token': os.environ['JOB_TOKEN'],
        'job_id': job['job_id'],
        'seconds': int(seconds or 0),
    })
    try:
        with open(REPORTED, 'w') as fh:
            fh.write(str(job['job_id']))
    except OSError:
        pass


def _media_of(msg):
    """The file a message carries, whichever way it was sent, or None."""
    for attr in ('document', 'video', 'animation', 'audio', 'photo'):
        media = getattr(msg, attr, None)
        if media is not None:
            return media
    return None


def judge_copy(msg, job):
    """'ok', 'missing' or 'changed', and why — for a fetched message.

    THE SAME FILE, by Telegram's own id for it when that matches; by size when
    it does not, because the Bot API and MTProto libraries are documented to
    agree on `file_unique_id` but a difference in encoding between them must
    not be read as "the film is gone". A different size is a different file.
    """
    if msg is None or getattr(msg, 'empty', False):
        return 'missing', 'the message is gone'
    media = _media_of(msg)
    if media is None:
        return 'missing', 'the message no longer holds a file'
    want_id = job.get('tg_unique_id') or ''
    got_id = getattr(media, 'file_unique_id', '') or ''
    want_size = int(job.get('bytes') or 0)
    got_size = int(getattr(media, 'file_size', 0) or 0)
    if want_id and got_id and want_id == got_id:
        return 'ok', 'same file'
    if want_size and got_size == want_size:
        return 'ok', 'same size (%d bytes)' % got_size
    if want_size and got_size and got_size != want_size:
        return 'changed', 'a different file: %d bytes, expected %d' % (got_size, want_size)
    return 'changed', 'cannot tell it is the same file'


def short_download(msg, job, size):
    """Why a download is not the whole file, or None when it is.

    Telegram's own size for the file in the message is the authority; the
    size the job was queued with is the fallback. Both were right on the day
    the downloads came back short — what was wrong was ignoring them.
    """
    media = _media_of(msg) if msg is not None else None
    want = int(getattr(media, 'file_size', 0) or 0) or int(job.get('bytes') or 0)
    if want and size != want:
        return ('download stopped at %d of %d bytes (Telegram timed out?) '
                '- will be tried again' % (size, want))
    return None


def vault_one(app, job, flood_type):
    """A verify or a restore, reported through vault_done."""
    chat_id = job.get('tg_chat_id')
    message_id = job.get('tg_message_id')
    if not chat_id or not message_id:
        vault_report(job, False, note='the job has no chat or message')
        return
    work = tempfile.mkdtemp(prefix='vault-')
    target = os.path.join(work, 'payload.bin')
    try:
        msg = app.get_messages(int(chat_id), int(message_id))
        verdict, why = judge_copy(msg, job)
        if job.get('type') == 'verify':
            print('telegram copy: %s (%s)' % (verdict, why))
            vault_report(job, True, verdict, why)
            return
        # restore
        if verdict != 'ok':
            # Nothing to fetch. Reported as a verdict the database can act on
            # rather than three failed attempts at downloading nothing.
            vault_report(job, False, note='cannot restore: %s' % why)
            return
        got = app.download_media(msg, file_name=target)
        if not got or not os.path.exists(target):
            vault_report(job, False, note='nothing was downloaded')
            return
        size = os.path.getsize(target)
        print('downloaded %d bytes' % size)
        short = short_download(msg, job, size)
        if short:
            vault_report(job, False, note=short)
            print('failed: ' + short)
            return
        put = put_to_r2(target, job['put_url'])
        print('restored %d bytes' % put)
        vault_report(job, True, note='restored', size=put)
    except flood_type as exc:
        seconds = int(getattr(exc, 'value', 0) or 0)
        print('Telegram asked for a %ds wait; deferring and ending the run'
              % seconds)
        vault_defer(job, seconds)
        raise _Stop()
    except Exception as exc:                       # noqa: BLE001
        vault_report(job, False, note='failed: %s' % str(exc)[:200])
        print('failed: %s' % exc)
    finally:
        try:
            if os.path.exists(target):
                os.unlink(target)
            os.rmdir(work)
        except OSError:
            pass


def handle(app, job, flood_type):
    """One job of whichever type the claim handed out."""
    if job.get('type') in ('verify', 'restore'):
        vault_one(app, job, flood_type)
    else:
        fetch_one(app, job, flood_type)


def claim_next():
    """Ask for the next job. Writes JOB_FILE and answers it, or None.

    JOB_FILE is overwritten on purpose: it always names the job IN HAND, which
    is the one the workflow's crash backstop must report if this process dies.
    """
    code, body = _post(
        os.environ['SB_URL'].rstrip('/') + '/functions/v1/ingest',
        {'op': 'claim'},
        bearer=os.environ['RUNNER_SECRET'],
    )
    if code != 200:
        print('claim returned %s' % code)
        return None
    if not body.get('job_id'):
        return None
    with open(JOB_FILE, 'w', encoding='utf-8') as fh:
        json.dump(body, fh)
    return body


def put_to_r2(path, url):
    """Upload with curl, and insist on a 2xx.

    `--fail-with-body` rather than `--fail`: R2 explains a rejected signature
    in the body, and throwing that away is how an opaque 403 stays opaque.
    The URL is passed on the command line, which is a presigned URL and
    therefore a secret — but this runner is single-tenant and ephemeral, and
    the alternative (a config file) is read by the same processes.

    ONE PUT AND NO MULTIPART, deliberately. Telegram caps a file at 2 GB and
    R2 takes a single PUT up to 5 GiB, so multipart could never run on this
    path; the console keeps its own multipart uploader for masters that never
    went through Telegram.
    """
    size = os.path.getsize(path)
    result = subprocess.run(
        ['curl', '-sS', '--fail-with-body', '-X', 'PUT',
         '--upload-file', path,
         # Length is set explicitly so a truncated read becomes a failed
         # upload rather than a short object that looks complete.
         '-H', 'Content-Length: %d' % size,
         '-H', 'Content-Type: application/octet-stream',
         url],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError('PUT failed: %s' % (result.stdout or result.stderr)[:300])
    return size


class _Stop(Exception):
    """End the run: whatever comes next would be refused the same way."""


def fetch_one(app, job, flood_type):
    """Move one job's file into R2 with an already signed-in client.

    Reports the outcome itself, success or failure, EXCEPT for a FLOOD_WAIT
    longer than the client was willing to sleep through: that is not this
    file's outcome, so the job is deferred and the run ends.
    """
    chat_id = job.get('tg_chat_id')
    message_id = job.get('tg_message_id')
    if not chat_id or not message_id:
        report(job, False, 'the job has no chat or message to fetch')
        return

    work = tempfile.mkdtemp(prefix='ingest-')
    target = os.path.join(work, 'payload.bin')
    try:
        msg = app.get_messages(int(chat_id), int(message_id))
        if msg is None or getattr(msg, 'empty', False):
            report(job, False, 'the forwarded message is gone')
            return
        # download_media writes the media of whichever kind the message
        # holds — document, video or photo — which is why the message is
        # fetched rather than a file id decoded.
        got = app.download_media(msg, file_name=target)
        if not got or not os.path.exists(target):
            report(job, False, 'nothing was downloaded')
            return

        size = os.path.getsize(target)
        if size <= 0:
            report(job, False, 'downloaded zero bytes')
            return
        print('downloaded %d bytes' % size)

        # A SHORT DOWNLOAD IS A FAILED DOWNLOAD. This used to print a note
        # and upload anyway, on the theory that the bucket is the authority.
        # On 2026-09-29 Telegram's GetFile timed out twice mid-file, the
        # client gave back what it had, and two films went into R2 as their
        # first 17 MiB of 70 MB and 3 MiB of 4 MB — reported "ok", approved,
        # live, and unplayable (no moov atom; the encoder found it three days
        # later). Now it is reported as a failure, which is retried.
        short = short_download(msg, job, size)
        if short:
            report(job, False, short)
            print('failed: ' + short)
            return

        put = put_to_r2(target, job['put_url'])
        print('uploaded %d bytes' % put)
        report(job, True, 'ok', put)
    except flood_type as exc:
        seconds = int(getattr(exc, 'value', 0) or 0)
        print('Telegram asked for a %ds wait; deferring and ending the run'
              % seconds)
        defer(job, seconds)
        raise _Stop()
    except Exception as exc:                       # noqa: BLE001
        # The message is truncated and never includes the presigned URL: a
        # note goes into the database and the database is read by a console.
        report(job, False, 'ingest failed: %s' % str(exc)[:200])
        print('failed: %s' % exc)
    finally:
        try:
            if os.path.exists(target):
                os.unlink(target)
            os.rmdir(work)
        except OSError:
            pass


def fail(job, note):
    """Report a job as failed through the op its type answers to."""
    if job.get('type') in ('verify', 'restore'):
        vault_report(job, False, note=note)
    else:
        report(job, False, note)


def main():
    job = load_job()
    api_id = os.environ.get('TG_API_ID', '')
    api_hash = os.environ.get('TG_API_HASH', '')
    bot_token = os.environ.get('TG_BOT_TOKEN', '')
    if not api_id or not api_hash or not bot_token:
        # One job reported and the run ends. Every other job would fail for
        # the same reason, and spending their attempts on it says nothing new.
        fail(job, 'Telegram credentials are not set on this repository')
        print('TELEGRAM_API_ID / TELEGRAM_API_HASH / TELEGRAM_BOT_TOKEN missing')
        return 1

    # Imported here rather than at the top so a missing dependency is
    # reported to the console as a failed job instead of a stack trace in a
    # log nobody reads.
    try:
        from pyrogram import Client
        from pyrogram.errors import FloodWait
    except Exception as exc:                       # noqa: BLE001
        fail(job, 'telegram client unavailable: %s' % exc)
        return 1

    # `in_memory=True` so no .session file is written to the runner's disk:
    # there is nothing to leak into an artifact and nothing to clean up.
    # `sleep_threshold` makes the client itself sit through short FLOOD_WAITs
    # — including on the sign-in — instead of raising them.
    app = Client(
        'ingest',
        api_id=int(api_id),
        api_hash=api_hash,
        bot_token=bot_token,
        in_memory=True,
        sleep_threshold=SLEEP_THRESHOLD,
    )
    try:
        app.start()
    except FloodWait as exc:
        seconds = int(getattr(exc, 'value', 0) or 0)
        print('Telegram asked for a %ds wait before signing in; deferring'
              % seconds)
        if job.get('type') in ('verify', 'restore'):
            vault_defer(job, seconds)
        else:
            defer(job, seconds)
        return 0
    except Exception as exc:                       # noqa: BLE001
        # A bad api_id or a revoked token. Nothing else in the queue can
        # succeed either, so one job carries the reason and the run ends.
        fail(job, 'could not sign in to Telegram: %s' % str(exc)[:200])
        print('sign-in failed: %s' % exc)
        return 1

    deadline = time.time() + BUDGET_MIN * 60
    handled = 0
    try:
        while True:
            try:
                handle(app, job, FloodWait)
            except _Stop:
                break
            handled += 1
            if handled >= MAX_JOBS:
                print('stopping at %d jobs; the next run takes the rest' % MAX_JOBS)
                break
            if time.time() >= deadline:
                print('stopping after %dm; the next run takes the rest' % BUDGET_MIN)
                break
            job = claim_next()
            if job is None:
                print('queue is empty')
                break
            print('next job claimed')
    finally:
        try:
            app.stop()
        except Exception:                          # noqa: BLE001
            pass

    print('handled %d job(s) in one sign-in' % handled)
    # ZERO even when a file failed: every failure has already been reported
    # to the database, which is where the operator looks. A red run for a
    # file that was simply unreachable tells nobody anything new — and would
    # fire the crash backstop over a job that was already dealt with.
    return 0


if __name__ == '__main__':
    sys.exit(main())
