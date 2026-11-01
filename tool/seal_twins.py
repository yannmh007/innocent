#!/usr/bin/env python3
"""Sealed twins for a title's video objects (docs/MEDIA_ENCRYPTION.md §9 B).

Run on a GitHub runner (seed-open-films.yml, task "seal"). For each title id:

  1. ask the ingest function for a plan (op seal_plan): per video object not
     yet twinned, a DEK issued by the function, a GET for the plain object and
     a PUT for its twin at s/<32 hex>;
  2. download the plain object, seal it (tool/media_seal.py), open the whole
     twin again and compare it with the plain file byte for byte (SHA-256),
     and upload it;
  3. hand the function the twins to check and record (op seal_commit): it
     checks the wrap is its own, the sizes, the header, and that the first and
     last segments open, before it writes the media_keys row.

The function allows only open films (slug open-film-…); this script is only
ever given their ids. NOTHING SECRET IS PRINTED: presigned URLs and DEKs are
held in memory and never logged — this repository and its logs are public.

  SB_URL=… RUNNER_SECRET=… python3 tool/seal_twins.py <title id> [<title id> …]
"""
from __future__ import annotations

import base64
import hashlib
import http.client
import json
import os
import shutil
import sys
import tempfile
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import media_seal  # noqa: E402  (tool/media_seal.py, the reference)


def call(fn: str, secret: str, body: dict) -> dict:
    req = urllib.request.Request(
        fn, data=json.dumps(body).encode(), method="POST",
        headers={"Authorization": "Bearer " + secret, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def download(url: str, path: str) -> int:
    with urllib.request.urlopen(url, timeout=600) as r, open(path, "wb") as f:
        shutil.copyfileobj(r, f, 4 * 1024 * 1024)
    return os.path.getsize(path)


def upload(url: str, path: str) -> int:
    u = urllib.parse.urlsplit(url)
    conn = (http.client.HTTPSConnection if u.scheme == "https" else http.client.HTTPConnection)(
        u.netloc, timeout=600)
    try:
        size = os.path.getsize(path)
        conn.putrequest("PUT", u.path + ("?" + u.query if u.query else ""), skip_accept_encoding=True)
        conn.putheader("Content-Length", str(size))
        # Every sealed object is octet-stream: nothing about it says film.
        conn.putheader("Content-Type", "application/octet-stream")
        conn.endheaders()
        with open(path, "rb") as f:
            while True:
                b = f.read(4 * 1024 * 1024)
                if not b:
                    break
                conn.send(b)
        r = conn.getresponse()
        r.read()
        return r.status
    finally:
        conn.close()


def sha256_of(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(4 * 1024 * 1024), b""):
            h.update(b)
    return h.hexdigest()


class _Hasher:
    def __init__(self):
        self.h = hashlib.sha256()

    def write(self, b: bytes) -> int:
        self.h.update(b)
        return len(b)


def twin_one(item: dict, work: str) -> dict | None:
    plain_path = os.path.join(work, "plain.bin")
    sealed_path = os.path.join(work, "sealed.bin")
    try:
        name = item["plain_key"].rsplit("/", 1)[-1]
        size = int(item["plain_size"])
        got = download(item["get_url"], plain_path)
        if got != size:
            print(f"  {name}: downloaded {got} bytes, not {size}")
            return None
        dek = base64.b64decode(item["dek"])
        aad = media_seal.aad_for(item["dek_id"])
        with open(plain_path, "rb") as src, open(sealed_path, "wb") as dst:
            written = media_seal.seal_stream(src, dst, dek, aad, size)
        if written != media_seal.sealed_size(size) or os.path.getsize(sealed_path) != written:
            print(f"  {name}: sealed to {written} bytes, not {media_seal.sealed_size(size)}")
            return None
        # THE WHOLE TWIN OPENED AGAIN, and compared with the plain file: a
        # twin is recorded only once it is known to be the same film.
        hasher = _Hasher()
        with open(sealed_path, "rb") as src:
            media_seal.open_stream(src, hasher, dek, aad, written)
        if hasher.h.hexdigest() != sha256_of(plain_path):
            print(f"  {name}: the twin does not open to the same bytes")
            return None
        with open(sealed_path, "rb") as f:
            header = f.read(media_seal.HEADER)
        status = upload(item["put_url"], sealed_path)
        if status != 200:
            print(f"  {name}: upload HTTP {status}")
            return None
        print(f"  {name}: {size} -> {written} bytes, opened and matched, uploaded")
        return {
            "_del": item.get("del_url"),
            "dek_id": item["dek_id"], "wrapped": item["wrapped"], "plain_key": item["plain_key"],
            "sealed_key": item["sealed_key"], "plain_size": size,
            "header": base64.b64encode(header).decode(),
        }
    finally:
        for p in (plain_path, sealed_path):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass


def remove(url: str | None) -> bool:
    """Takes a twin away again (its presigned DELETE): one not recorded is
    not left in the bucket."""
    if not url:
        return False
    try:
        req = urllib.request.Request(url, method="DELETE")
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status in (200, 204)
    except Exception:  # noqa: BLE001 — the sweep takes what this misses
        return False


def main(argv: list[str]) -> int:
    sb, secret = os.environ.get("SB_URL", ""), os.environ.get("RUNNER_SECRET", "")
    if not sb or not secret or len(argv) < 2:
        print("usage: SB_URL=… RUNNER_SECRET=… seal_twins.py <title id> …")
        return 2
    fn = sb.rstrip("/") + "/functions/v1/ingest"
    failed = 0
    # Twins an earlier run left unrecorded (an hour old or more), first.
    try:
        sw = call(fn, secret, {"op": "seal_commit", "sweep": True})
        print(f"sweep: {sw.get('twins', '?')} twins, {sw.get('recorded', '?')} recorded, "
              f"{sw.get('removed', 0)} removed")
    except Exception as e:  # noqa: BLE001
        print(f"sweep: not done ({type(e).__name__})")
    for title_id in argv[1:]:
        print(f"=== {title_id}")
        plan = call(fn, secret, {"op": "seal_plan", "title_id": title_id})
        items = plan.get("items", [])
        print(f"  {len(items)} to seal, {plan.get('already', 0)} already twinned")
        made = []
        with tempfile.TemporaryDirectory() as work:
            for item in items:
                twin = twin_one(item, work)
                if twin:
                    made.append(twin)
                else:
                    failed += 1
        if made:
            dels = {m["plain_key"]: m.pop("_del") for m in made}
            res = call(fn, secret, {"op": "seal_commit", "title_id": title_id, "items": made})
            for r in res.get("results", []):
                name = str(r.get("plain_key", "")).rsplit("/", 1)[-1]
                if r.get("ok"):
                    print(f"  recorded {name}: ok")
                    continue
                gone = remove(dels.get(r.get("plain_key")))
                print(f"  recorded {name}: REFUSED {r.get('why')}; twin {'removed' if gone else 'left for the sweep'}")
                failed += 1
    print("done" if not failed else f"{failed} not sealed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
