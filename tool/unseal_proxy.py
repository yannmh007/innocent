#!/usr/bin/env python3
"""A sealed object in R2, read by a runner's ffmpeg as the plain film it holds
(docs/MEDIA_ENCRYPTION.md §7) — the runner's twin of the phone's unseal
gateway (lib/features/video_hub/data/seal/unseal_gateway.dart).

WHY. ffmpeg seeks an HTTP input with range requests: ten stills of a two-hour
film cost a few megabytes, not two gigabytes (tool/frames.py). A sealed
object cannot be read that way — every byte is ciphertext — and downloading
and opening the whole of it to take ten pictures would throw that away. This
serves one sealed object on loopback as its plaintext: a range `[a, b]` is
answered from the whole sealed segments that hold it (one aligned range from
R2), each opened and checked before a byte of it is passed on. A segment
that does not open ends the answer — never a corrupt frame handed to ffmpeg.

ON LOOPBACK ONLY, for the life of one job; the DEK is in this process's
memory and nowhere else, and nothing is logged.

    with UnsealProxy(sealed_url, dek, dek_id, plain_size, sealed_size) as url:
        ffmpeg -ss 30 -i url …
"""
from __future__ import annotations

import http.server
import re
import threading
import urllib.request
from collections import OrderedDict

import media_seal as ms

_RANGE = re.compile(r'^bytes=(\d+)-(\d*)$')


class UnsealProxy:
    """Serves one sealed object's plaintext on 127.0.0.1 while in a `with`."""

    CACHE = 8  # opened segments kept: ffmpeg re-reads around a seek

    def __init__(self, sealed_url: str, dek: bytes, dek_id: str, plain_size: int, sealed_size: int):
        if ms.sealed_size(plain_size) != sealed_size:
            raise ms.SealError('sizes that do not agree')
        self.url = sealed_url
        self.dek, self.aad = dek, ms.aad_for(dek_id)
        self.plain, self.sealed = plain_size, sealed_size
        self.count = ms.segment_count(plain_size)
        self._opener = None
        self._lock = threading.Lock()
        self._cache: OrderedDict[int, bytes] = OrderedDict()
        self._server = None
        self.fetches = 0  # ranges asked of R2, for the tests

    # ── R2 ──────────────────────────────────────────────────────────────────
    def _get(self, start: int, end: int):
        """Sealed bytes [start, end) as a stream, from one range request."""
        self.fetches += 1
        req = urllib.request.Request(self.url, headers={'Range': 'bytes=%d-%d' % (start, end - 1)})
        resp = urllib.request.urlopen(req, timeout=60)
        if resp.status != 206 and not (resp.status == 200 and start == 0 and end == self.sealed):
            resp.close()
            raise ms.SealError('R2 answered %d to a range' % resp.status)
        return resp

    def _opener_now(self) -> ms.Opener:
        with self._lock:
            if self._opener is None:
                with self._get(0, ms.HEADER) as r:
                    header = r.read(ms.HEADER)
                self._opener = ms.Opener(self.dek, self.aad, header, self.plain)
            return self._opener

    def _seg_len(self, i: int) -> int:
        end = ms.sealed_start(i + 1) if i + 1 < self.count else self.sealed
        return end - ms.sealed_start(i)

    def segments(self, a: int, b: int):
        """Plaintext of segments a..b, in order, each opened before it is given."""
        op = self._opener_now()
        i = a
        while i <= b:
            with self._lock:
                hit = self._cache.get(i)
                if hit is not None:
                    self._cache.move_to_end(i)
            if hit is not None:
                yield i, hit
                i += 1
                continue
            # From here to b (or the next cached one), one range.
            j = i
            with self._lock:
                while j < b and (j + 1) not in self._cache:
                    j += 1
            end = ms.sealed_start(j + 1) if j + 1 < self.count else self.sealed
            with self._get(ms.sealed_start(i), end) as r:
                for k in range(i, j + 1):
                    n = self._seg_len(k)
                    buf = r.read(n)
                    while len(buf) < n:
                        more = r.read(n - len(buf))
                        if not more:
                            raise ms.SealError('R2 ended inside segment %d' % k)
                        buf += more
                    plain = op.open_segment(k, buf)
                    with self._lock:
                        self._cache[k] = plain
                        while len(self._cache) > self.CACHE:
                            self._cache.popitem(last=False)
                    yield k, plain
            i = j + 1

    # ── loopback ────────────────────────────────────────────────────────────
    def __enter__(self) -> str:
        proxy = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *args):  # nothing is logged
                pass

            def _headers(self, code, length, extra=None):
                self.send_response(code)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Accept-Ranges', 'bytes')
                self.send_header('Content-Length', str(length))
                for k, v in (extra or {}).items():
                    self.send_header(k, v)
                self.end_headers()

            def do_HEAD(self):
                self._headers(200, proxy.plain)

            def do_GET(self):
                total = proxy.plain
                rng = self.headers.get('Range')
                if rng:
                    m = _RANGE.match(rng.strip())
                    a = int(m.group(1)) if m else -1
                    b = (int(m.group(2)) if m and m.group(2) else total - 1) if m else -1
                    b = min(b, total - 1)
                    if not m or a > b or a >= total:
                        self._headers(416, 0, {'Content-Range': 'bytes */%d' % total})
                        return
                    self._headers(206, b - a + 1, {'Content-Range': 'bytes %d-%d/%d' % (a, b, total)})
                else:
                    a, b = 0, total - 1
                    self._headers(200, total)
                try:
                    for i, plain in proxy.segments(ms.segment_of(a), ms.segment_of(b)):
                        p0 = ms.plain_start(i)
                        lo, hi = max(a, p0) - p0, min(b + 1, p0 + len(plain)) - p0
                        self.wfile.write(plain[lo:hi])
                except (BrokenPipeError, ConnectionResetError):
                    return  # ffmpeg let go: a seek
                except Exception:  # noqa: BLE001 — never a corrupt frame: the answer ends short
                    self.close_connection = True

        self._server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self._server.daemon_threads = True
        threading.Thread(target=self._server.serve_forever, daemon=True).start()
        return 'http://127.0.0.1:%d/film' % self._server.server_address[1]

    def __exit__(self, *exc):
        if self._server:
            self._server.shutdown()
            self._server.server_close()
        self.dek = b''
        return False
