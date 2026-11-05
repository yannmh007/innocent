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
    have = os.path.getsize(src)
    if have != int(s['sealed_size']):
        print(f'master: {have} bytes, not the {s["sealed_size"]} its key row says')
        return 1
    dek = base64.b64decode(s['dek'])
    aad = media_seal.aad_for(s['dek_id'])
    out = src + '.open'
    with open(src, 'rb') as a, open(out, 'wb') as b:
        media_seal.open_stream(a, b, dek, aad, have)
    if os.path.getsize(out) != int(s['plain_size']):
        os.remove(out)
        print('master: opened to the wrong size')
        return 1
    os.replace(out, src)
    print(f'master: sealed, opened ({s["plain_size"]} bytes)')
    return 0


def seal_for(job: dict, height: str) -> dict | None:
    return (job.get('seal') or {}).get(str(height))


def seal_rung(job: dict, height: str, path: str) -> int:
    s = seal_for(job, height)
    if not s:
        print(f'{height}p: no seal asked for', file=sys.stderr)
        return 1
    size = os.path.getsize(path)
    dek = base64.b64decode(s['dek'])
    aad = media_seal.aad_for(s['dek_id'])
    sealed = path + '.sealed'
    try:
        with open(path, 'rb') as a, open(sealed, 'wb') as b:
            written = media_seal.seal_stream(a, b, dek, aad, size)
        if written != media_seal.sealed_size(size) or os.path.getsize(sealed) != written:
            print(f'{height}p: sealed to {written} bytes, not {media_seal.sealed_size(size)}', file=sys.stderr)
            return 1
        # THE WHOLE RUNG OPENED AGAIN, and compared with the plain one: a
        # sealed rung goes up only once it is known to be the same film.
        hasher = _Hasher()
        with open(sealed, 'rb') as a:
            media_seal.open_stream(a, hasher, dek, aad, written)
        if hasher.h.hexdigest() != sha256_of(path):
            print(f'{height}p: the sealed rung does not open to the same bytes', file=sys.stderr)
            return 1
        with open(sealed, 'rb') as a:
            header = a.read(media_seal.HEADER)
        status = upload(s['put_url'], sealed)
        if status != 200:
            print(f'{height}p: sealed upload HTTP {status}', file=sys.stderr)
            return 1
        print(f'{height}p sealed: {size} -> {written} bytes, opened and matched, uploaded', file=sys.stderr)
        print(json.dumps({
            'dek_id': s['dek_id'], 'wrapped': s['wrapped'], 'sealed_key': s['sealed_key'],
            'plain_size': size, 'header': base64.b64encode(header).decode(),
        }))
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
