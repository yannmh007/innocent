#!/usr/bin/env python3
"""tool/trickplay_job.py against a real ffmpeg and a fake R2 / edge function.

What must hold: each claimed film is read, packed at the plan's setting (4 s,
320 px, JPEG), PUT where the claim said as application/octet-stream, and
reported with the bytes that were PUT; a film whose rung cannot be read is
reported as a failure with the reason, and the batch goes on; no address is
printed.

Needs `ffmpeg` on PATH (the runner installs it).
RUN:  python3 tool/trickplay_job_test.py
"""
import http.server
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trickplay  # noqa: E402
import trickplay_job  # noqa: E402

failures = 0


def check(label, ok):
    global failures
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        failures += 1


if not shutil.which('ffmpeg'):
    print('SKIP: no ffmpeg on PATH')
    sys.exit(0)

work = tempfile.mkdtemp(prefix='trick_job_test_')
film = os.path.join(work, 'film.mp4')
subprocess.run(['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi', '-i',
                'testsrc2=size=426x240:rate=24', '-t', '20', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                film], check=True)
with open(film, 'rb') as fh:
    FILM = fh.read()

puts = {}
dones = []


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        if self.path.startswith('/src?sig='):
            self.send_response(200)
            self.send_header('Content-Length', str(len(FILM)))
            self.end_headers()
            self.wfile.write(FILM)
        else:
            self.send_response(404)
            self.end_headers()

    def do_PUT(self):
        n = int(self.headers.get('Content-Length') or 0)
        puts[self.path] = (self.headers.get('Content-Type'), self.rfile.read(n))
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        body = json.loads(self.rfile.read(n))
        dones.append(body)
        out = json.dumps({'ok': True, 'key': (body.get('pack') or {}).get('key')}).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(out)


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{srv.server_address[1]}'
claim = {
    'scope': 'open',
    'done_url': f'{base}/done',
    'jobs': [
        {'asset_id': 'a1', 'src_url': f'{base}/src?sig=secret-looking', 'src_height': 240,
         'key': 'open-film-x/video/a-trick.itp', 'put_url': f'{base}/put?sig=secret-looking'},
        {'asset_id': 'a2', 'src_url': f'{base}/gone?sig=secret-looking', 'src_height': 240,
         'key': 'open-film-y/video/b-trick.itp', 'put_url': f'{base}/put2?sig=secret-looking'},
    ],
}
path = os.path.join(work, 'claim.json')
with open(path, 'w') as fh:
    json.dump(claim, fh)
os.environ['RUNNER_SECRET'] = 'runner-secret-for-test'
buf = io.StringIO()
with redirect_stdout(buf):
    rc = trickplay_job.main(['trickplay_job.py', path])
log = buf.getvalue()
srv.shutdown()

check('one film of two made: the batch is not a failure', rc == 0)
put = puts.get('/put?sig=secret-looking')
check('the pack was PUT where the claim said, as application/octet-stream',
      put is not None and put[0] == 'application/octet-stream')
if put:
    iv, w, h, codec, offs = trickplay.read_header(put[1])
    check(f'at the plan\'s setting: every 4 s, 320 wide, JPEG (got {iv} ms, {w}x{h}, {codec})',
          (iv, w, h, codec) == (4000, 320, 180, 'jpeg'))
    check(f'a 20 s film is five pictures (got {len(offs) - 1})', len(offs) - 1 == 5)
d1 = next((d for d in dones if d.get('asset_id') == 'a1'), {})
pack = d1.get('pack') or {}
check('done carries the runner\'s token', d1.get('token') == 'runner-secret-for-test' and d1.get('op') == 'trick_done')
check('done reports the key the claim gave and the bytes that were PUT',
      pack.get('key') == 'open-film-x/video/a-trick.itp' and put is not None and pack.get('bytes') == len(put[1]))
check('and what is inside', (pack.get('interval_ms'), pack.get('width'), pack.get('height'),
                             pack.get('count'), pack.get('codec')) == (4000, 320, 180, 5, 'jpeg'))
d2 = next((d for d in dones if d.get('asset_id') == 'a2'), {})
check('a rung that cannot be read is a failure with its reason, no pack',
      'pack' not in d2 and 'could not be read' in (d2.get('note') or ''))
check('nothing was PUT for it', '/put2?sig=secret-looking' not in puts)
check('no address and no token in the log', 'sig=' not in log and '127.0.0.1' not in log
      and 'runner-secret' not in log)
check('the log says what was made', 'a1: 5 pictures 320x180' in log and 'recorded' in log)
shutil.rmtree(work, ignore_errors=True)
print(f'{failures} failure(s)')
sys.exit(1 if failures else 0)
