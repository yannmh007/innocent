#!/usr/bin/env python3
"""The transcode runner's media seal (docs/MEDIA_ENCRYPTION.md §7).

The transcode function decides, when it hands out a job, what the switch
(admin_settings.seal_new) makes of it; this only does what the job says.

  transcode_seal.py open-master JOB SRC
      A sealed master (`src_seal` in the job: born sealed, or in the canary
      the master's twin) opened in place on the runner's disk, its size
      checked against the key row. Nothing to do for a plain master.

  transcode_seal.py has-seal JOB HEIGHT
      Prints 1 when the job asks for this rung sealed, else 0.

  transcode_seal.py seal-rung JOB HEIGHT FILE
      FILE (a finished rung, its CMAF layout already checked) sealed under
      the DEK the function issued for it, opened whole again and compared
      with FILE byte for byte (SHA-256), and uploaded to its `s/<32 hex>`
      key as application/octet-stream. Prints the JSON the rung's row
      carries as `sealed`: dek_id, the wrap (handed back untouched),
      sealed_key, plain_size, header. Never the DEK.

NOTHING SECRET IS PRINTED: the job's DEKs and presigned URLs stay in the job
file on the runner's disk, for this job only; the repository and its logs
are public.
"""
from __future__ import annotations

import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import media_seal  # noqa: E402  (the reference format)
from seal_twins import _Hasher, sha256_of, upload  # noqa: E402


def _job(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def open_master(job: dict, src: str) -> int:
    s = job.get('src_seal')
    if not s:
        print('master: plain')
        return 0
    out = src + '.open'
    try:
        open_checked(src, out, s)
    except (NotSealed, media_seal.SealError) as e:
        print(f'master: {e}')
        return 1
    os.replace(out, src)
    print(f'master: sealed, opened ({s["plain_size"]} bytes)')
    return 0


def seal_for(job: dict, height: str) -> dict | None:
    return (job.get('seal') or {}).get(str(height))


class NotSealed(Exception):
    """A file that did not seal to exactly what it is. Never uploaded."""


def seal_checked(path: str, s: dict) -> tuple[str, dict]:
    """FILE sealed under the issued DEK `s` (dek_id, dek, wrapped, sealed_key)
    beside it, then THE WHOLE SEALED FILE OPENED AGAIN and compared with
    FILE (SHA-256): a sealed object goes up only once it is known to be the
    same bytes. Answers (sealed path, what its key row carries — never the
    DEK). The caller uploads and removes the sealed file."""
    size = os.path.getsize(path)
    dek = base64.b64decode(s['dek'])
    aad = media_seal.aad_for(s['dek_id'])
    sealed = path + '.sealed'
    try:
        with open(path, 'rb') as a, open(sealed, 'wb') as b:
            written = media_seal.seal_stream(a, b, dek, aad, size)
        if written != media_seal.sealed_size(size) or os.path.getsize(sealed) != written:
            raise NotSealed(f'sealed to {written} bytes, not {media_seal.sealed_size(size)}')
        hasher = _Hasher()
        with open(sealed, 'rb') as a:
            media_seal.open_stream(a, hasher, dek, aad, written)
        if hasher.h.hexdigest() != sha256_of(path):
            raise NotSealed('the sealed file does not open to the same bytes')
        with open(sealed, 'rb') as a:
            header = a.read(media_seal.HEADER)
    except BaseException:
        try:
            os.remove(sealed)
        except FileNotFoundError:
            pass
        raise
    return sealed, {
        'dek_id': s['dek_id'], 'wrapped': s['wrapped'], 'sealed_key': s['sealed_key'],
        'plain_size': size, 'header': base64.b64encode(header).decode(),
    }


def open_checked(src: str, dst: str, s: dict) -> int:
    """A sealed file SRC opened to DST with `s` (dek_id, dek, plain_size,
    sealed_size), both sizes checked. Answers the plain size; a segment that
    does not open raises, and DST is removed."""
    have = os.path.getsize(src)
    if have != int(s['sealed_size']):
        raise NotSealed(f'{have} sealed bytes, not the {s["sealed_size"]} its key row says')
    try:
        with open(src, 'rb') as a, open(dst, 'wb') as b:
            media_seal.open_stream(a, b, base64.b64decode(s['dek']), media_seal.aad_for(s['dek_id']), have)
        n = os.path.getsize(dst)
        if n != int(s['plain_size']):
            raise NotSealed(f'opened to {n} bytes, not {s["plain_size"]}')
        return n
    except BaseException:
        try:
            os.remove(dst)
        except FileNotFoundError:
            pass
        raise


def seal_rung(job: dict, height: str, path: str) -> int:
    s = seal_for(job, height)
    if not s:
        print(f'{height}p: no seal asked for', file=sys.stderr)
        return 1
    size = os.path.getsize(path)
    try:
        sealed, info = seal_checked(path, s)
    except (NotSealed, media_seal.SealError) as e:
        print(f'{height}p: {e}', file=sys.stderr)
        return 1
    try:
        status = upload(s['put_url'], sealed)
        if status != 200:
            print(f'{height}p: sealed upload HTTP {status}', file=sys.stderr)
            return 1
        written = os.path.getsize(sealed)
        print(f'{height}p sealed: {size} -> {written} bytes, opened and matched, uploaded', file=sys.stderr)
        print(json.dumps(info))
        return 0
    finally:
        try:
            os.remove(sealed)
        except FileNotFoundError:
            pass


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[1] == 'open-master':
        return open_master(_job(argv[2]), argv[3])
    if len(argv) >= 4 and argv[1] == 'has-seal':
        print(1 if seal_for(_job(argv[2]), argv[3]) else 0)
        return 0
    if len(argv) >= 5 and argv[1] == 'seal-rung':
        return seal_rung(_job(argv[2]), argv[3], argv[4])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
