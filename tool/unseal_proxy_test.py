#!/usr/bin/env python3
"""tool/unseal_proxy.py: a sealed object read by range as its plaintext.

Every range exact (random, open-ended, whole, out of range), a seek far in
fetching only the segments it needs, a segment altered in R2 ending the
answer short rather than passing a corrupt byte — and, where ffmpeg is on
PATH, ffprobe and a seeked still through it, as tool/frames.py uses it.

  python3 tool/unseal_proxy_test.py
"""
import http.server
import io
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
try:
    import media_seal as ms  # noqa: E402
    from unseal_proxy import UnsealProxy  # noqa: E402
except BaseException as e:  # no `cryptography` here (pyo3 panics are BaseException)
    print("SKIP unseal proxy: the `cryptography` package does not load here (%s). "
          "The transcode job installs cryptography==50.0.2." % type(e).__name__)
    sys.exit(0)

checks = 0


def ok(cond, what):
    global checks
    checks += 1
    if not cond:
        print('FAIL ' + what)
        sys.exit(1)
    print('ok   ' + what)


def r2(body):
    """A stand-in for R2: one object, ranges answered 206."""
    class H(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *a):
            pass

        def do_GET(self):
            data = H.body
            m = re.match(r'bytes=(\d+)-(\d*)', self.headers.get('Range', ''))
            a = int(m.group(1)) if m else 0
            b = int(m.group(2)) if m and m.group(2) else len(data) - 1
            chunk = data[a:b + 1]
            self.send_response(206 if m else 200)
            if m:
                self.send_header('Content-Range', 'bytes %d-%d/%d' % (a, b, len(data)))
            self.send_header('Content-Length', str(len(chunk)))
            self.end_headers()
            try:
                self.wfile.write(chunk)
            except (BrokenPipeError, ConnectionResetError):
                pass
    H.body = body
    s = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
    s.daemon_threads = True
    threading.Thread(target=s.serve_forever, daemon=True).start()
    return s, 'http://127.0.0.1:%d/s/x' % s.server_address[1], H


def get(url, rng=None):
    req = urllib.request.Request(url, headers={'Range': rng} if rng else {})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, b''
    except Exception:  # noqa: BLE001 — a short answer
        return -1, b''


def seal(plain, dek_id='dek-proxy'):
    dek = os.urandom(32)
    out = io.BytesIO()
    ms.seal_stream(io.BytesIO(plain), out, dek, ms.aad_for(dek_id), len(plain))
    return dek, out.getvalue()


def main():
    rnd = random.Random(5)
    plain = bytes(rnd.getrandbits(8) for _ in range(ms.FIRST_PLAIN + 9 * ms.PLAIN_SEGMENT + 777))
    dek, sealed = seal(plain)
    server, url, H = r2(sealed)
    n = len(plain)
    with UnsealProxy(url, dek, 'dek-proxy', n, len(sealed)) as p:
        req = urllib.request.Request(p, method='HEAD')
        with urllib.request.urlopen(req) as r:
            ok(r.status == 200 and int(r.headers['Content-Length']) == n, 'HEAD: the film\'s own length')
        good = True
        for _ in range(60):
            a = rnd.randrange(n)
            b = min(n - 1, a + rnd.randrange(200000))
            code, body = get(p, 'bytes=%d-%d' % (a, b))
            good = good and code == 206 and body == plain[a:b + 1]
        ok(good, 'sixty ranges, each the film\'s own bytes')
        code, body = get(p, 'bytes=%d-' % (n - 5000))
        ok(code == 206 and body == plain[n - 5000:], 'an open range to the end')
        code, body = get(p)
        ok(code == 200 and body == plain, 'the whole film, no range')
        ok(get(p, 'bytes=%d-' % n)[0] == 416, 'past the end: 416')
    # A seek far in: only the segments that hold it.
    proxy = UnsealProxy(url, dek, 'dek-proxy', n, len(sealed))
    with proxy as p:
        at = ms.plain_start(8) + 10
        code, body = get(p, 'bytes=%d-%d' % (at, at + 100))
        ok(code == 206 and body == plain[at:at + 101], 'a seek far in')
        ok(proxy.fetches == 2, 'two ranges from R2: the header and the one segment (%d)' % proxy.fetches)
    # Altered in R2: the answer ends short; no altered byte is passed on.
    bad = bytearray(sealed)
    bad[ms.sealed_start(3) + 100] ^= 1
    H.body = bytes(bad)
    with UnsealProxy(url, dek, 'dek-proxy', n, len(sealed)) as p:
        code, body = get(p, 'bytes=0-%d' % (n - 1))
        ok(body != plain[:len(body)] or len(body) < n, 'an altered segment: the answer ends short')
        ok(len(body) <= ms.plain_start(3), 'and nothing from the altered segment on (%d bytes)' % len(body))
    H.body = sealed
    server.shutdown()

    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
        print('unseal proxy: ffmpeg half skipped (no ffmpeg here)')
    else:
        work = tempfile.mkdtemp()
        film = os.path.join(work, 'film.mp4')
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=640x360:rate=24',
                        '-t', '8', '-c:v', 'libx264', '-preset', 'ultrafast', '-movflags', '+faststart', film],
                       check=True)
        fplain = open(film, 'rb').read()
        fdek, fsealed = seal(fplain, 'dek-film')
        server, url, H = r2(fsealed)
        with UnsealProxy(url, fdek, 'dek-film', len(fplain), len(fsealed)) as p:
            dur = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of',
                                  'csv=p=0', p], capture_output=True, text=True).stdout.strip()
            ok(abs(float(dur or 0) - 8.0) < 0.2, 'ffprobe through it: %s s' % dur)
            jpg = os.path.join(work, 'still.jpg')
            r = subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '5', '-i', p, '-frames:v', '1', jpg])
            ok(r.returncode == 0 and os.path.getsize(jpg) > 1000, 'ffmpeg seeks in and takes a still')
        server.shutdown()
        shutil.rmtree(work, ignore_errors=True)
    print('unseal proxy: all checks passed (%d)' % checks)


if __name__ == '__main__':
    main()
