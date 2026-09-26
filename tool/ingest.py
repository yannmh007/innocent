#!/usr/bin/env python3
"""Move one forwarded Telegram film into R2.

Run by .github/workflows/ingest.yml after a job has been claimed. Reads
/tmp/ingest.json — the claim response — and:

  1. signs in to Telegram AS THE BOT over MTProto,
  2. fetches the forwarded message and downloads its media,
  3. PUTs the file at the presigned URL the claim handed over,
  4. reports the real byte count back, which is what creates the catalogue
     row and queues the transcode.

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

WHAT THIS SCRIPT NEVER SEES: an R2 key. The destination is a presigned PUT
scoped to one object, minted by the edge function and expiring the same day.
"""

import json
import os
import subprocess
import sys
import tempfile

JOB_FILE = '/tmp/ingest.json'


def load_job():
    with open(JOB_FILE, 'r', encoding='utf-8') as fh:
        return json.load(fh)


def report(job, ok, note, size=None):
    """Tell the edge function how it went.

    ALWAYS CALLED, on success and on failure, because the alternative is a
    row that says 'running' until the seven-hour recovery in claim_ingest
    takes it back — during which the console shows a film as arriving that
    is not.

    LEAVES A MARKER so the workflow's own failure reporter knows to stand
    down. This script reports the reason it knows — "Telegram credentials are
    not set on this repository" — and then exits non-zero, which is honest:
    the job did fail. The `if: failure()` step then fired and reported a
    second time with the generic "runner failed - see the Ingest run in
    Actions", overwriting the one message that said what to actually do. Seen
    happening in run #12, in that order, in one log.
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
    body = json.dumps(payload)
    # curl rather than urllib so the body goes in a file and never onto a
    # command line, where it would be visible in the process list.
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
        fh.write(body)
        path = fh.name
    subprocess.run(
        ['curl', '-fsS', '-X', 'POST', job['done_url'],
         '-H', 'Content-Type: application/json', '-d', '@' + path],
        check=False,
    )
    os.unlink(path)
    # Best effort, and deliberately after the report: a marker written for a
    # report that never went out would silence the backstop.
    try:
        with open('/tmp/ingest.reported', 'w') as fh:
            fh.write('1')
    except OSError:
        pass


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


def main():
    job = load_job()
    api_id = os.environ.get('TG_API_ID', '')
    api_hash = os.environ.get('TG_API_HASH', '')
    bot_token = os.environ.get('TG_BOT_TOKEN', '')
    if not api_id or not api_hash or not bot_token:
        report(job, False, 'Telegram credentials are not set on this repository')
        print('TELEGRAM_API_ID / TELEGRAM_API_HASH / TELEGRAM_BOT_TOKEN missing')
        return 1

    chat_id = job.get('tg_chat_id')
    message_id = job.get('tg_message_id')
    if not chat_id or not message_id:
        report(job, False, 'the job has no chat or message to fetch')
        return 1

    # Imported here rather than at the top so a missing dependency is
    # reported to the console as a failed job instead of a stack trace in a
    # log nobody reads.
    try:
        from pyrogram import Client
    except Exception as exc:                       # noqa: BLE001
        report(job, False, 'telegram client unavailable: %s' % exc)
        return 1

    work = tempfile.mkdtemp(prefix='ingest-')
    target = os.path.join(work, 'payload.bin')
    try:
        # `in_memory=True` so no .session file is written to the runner's
        # disk. There is nothing to leak into an artifact and nothing to
        # clean up; a fresh login per run costs one round trip.
        with Client(
            'ingest',
            api_id=int(api_id),
            api_hash=api_hash,
            bot_token=bot_token,
            in_memory=True,
        ) as app:
            msg = app.get_messages(int(chat_id), int(message_id))
            if msg is None or getattr(msg, 'empty', False):
                report(job, False, 'the forwarded message is gone')
                return 1
            # download_media writes the media of whichever kind the message
            # holds — document, video or photo — which is why the message is
            # fetched rather than a file id decoded.
            got = app.download_media(msg, file_name=target)
            if not got or not os.path.exists(target):
                report(job, False, 'nothing was downloaded')
                return 1

        size = os.path.getsize(target)
        if size <= 0:
            report(job, False, 'downloaded zero bytes')
            return 1
        print('downloaded %d bytes' % size)

        # WHAT TELEGRAM SAID VERSUS WHAT ARRIVED. A mismatch is not fatal —
        # the bucket is the authority and the real size is reported below —
        # but it is worth printing, because a short download that uploaded
        # cleanly would otherwise become a truncated film nobody noticed
        # until somebody watched the end of it.
        claimed = job.get('bytes') or 0
        if claimed and abs(claimed - size) > 0:
            print('note: Telegram said %d bytes, got %d' % (claimed, size))

        put = put_to_r2(target, job['put_url'])
        print('uploaded %d bytes' % put)
        report(job, True, 'ok', put)
        return 0
    except Exception as exc:                       # noqa: BLE001
        # The message is truncated and never includes the presigned URL: a
        # note goes into the database and the database is read by a console.
        report(job, False, 'ingest failed: %s' % str(exc)[:200])
        print('failed: %s' % exc)
        return 1
    finally:
        try:
            if os.path.exists(target):
                os.unlink(target)
            os.rmdir(work)
        except OSError:
            pass


if __name__ == '__main__':
    sys.exit(main())
