#!/usr/bin/env python3
"""tool/frames.py against a real ffmpeg and a fake R2 / edge function.

What must hold: ten frames, the first at one second and the rest evenly
spread; 640 px on the long edge for landscape AND portrait, never upscaled;
every frame PUT where the claim said with an image/jpeg type; one report per
video naming exactly the keys it was given; a video that cannot be read is
reported as a failure, not dropped and not a crash.

Needs `ffmpeg` on PATH (the transcode runner installs it; locally, any static
build). `ffprobe` is optional — without it the job's own duration is used,
which is the path a probe failure takes on the runner.

RUN:  python3 tool/frames_test.py
"""

import http.server
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import threading

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import frames  # noqa: E402

failures = 0


def check(label, ok):
    global failures
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        failures += 1


# ── the pure parts ────────────────────────────────────────────────────────
t = frames.frame_times(100)
check('ten times for a 100 s video', len(t) == 10)
check('frame 0 is at one second — the default thumbnail', t[0] == 1.0)
check('the rest at 10 %, 20 % … 90 %', t[1:] == [10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0])
check('a 1.2 s clip takes its default half-way, not past the end', frames.frame_times(1.2)[0] == 0.6)
check('an unknown duration still gets a default frame', frames.frame_times(None) == [1.0])

if not shutil.which('ffmpeg'):
    print('SKIP the ffmpeg half: no ffmpeg on PATH')
    sys.exit(1 if failures else 0)


# ── a fake R2 and edge function ───────────────────────────────────────────
class Store(http.server.BaseHTTPRequestHandler):
    puts = {}
    types = {}
    reports = []

    def log_message(self, *a):
        pass

    def do_PUT(self):
        n = int(self.headers.get('Content-Length') or 0)
        Store.puts[self.path] = self.rfile.read(n)
        Store.types[self.path] = self.headers.get('Content-Type')
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get('Content-Length') or 0)
        Store.reports.append(json.loads(self.rfile.read(n)))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{}')


srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Store)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:%d' % srv.server_address[1]


def jpeg_size(data):
    """(width, height) from a baseline/progressive JPEG's SOF marker."""
    i = 2
    while i < len(data):
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i + 1]
        if marker in (0xC0, 0xC1, 0xC2):
            h, w = struct.unpack('>HH', data[i + 5:i + 9])
            return w, h
        i += 2 + struct.unpack('>H', data[i + 2:i + 4])[0]
    return None


work = tempfile.mkdtemp(prefix='frames-test-')
land = os.path.join(work, 'land.mp4')
port = os.path.join(work, 'port.mp4')
small = os.path.join(work, 'small.mp4')
bad = os.path.join(work, 'bad.mp4')
for path, size, dur in ((land, '1280x720', 20), (port, '720x1280', 12), (small, '320x180', 5)):
    subprocess.run(['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi',
                    '-i', 'testsrc=duration=%d:size=%s:rate=25' % (dur, size),
                    '-pix_fmt', 'yuv420p', '-g', '50', path], check=True)
with open(bad, 'wb') as fh:
    fh.write(b'not a video at all' * 100)


def job(asset, src, dur):
    return {
        'asset_id': asset, 'src_url': src, 'duration_s': dur,
        'frames': [{'key': 'f/thumb/%s-f%02d.jpg' % (asset, i),
                    'put': '%s/put/%s/%d' % (base, asset, i)} for i in range(10)],
    }


batch = {'jobs': [job('land', land, 20), job('port', port, 12), job('small', small, 5),
                  job('bad', bad, 30)],
         'done_url': base + '/done'}
frames.JOBS = os.path.join(work, 'frames.json')
with open(frames.JOBS, 'w') as fh:
    json.dump(batch, fh)
os.environ['JOB_TOKEN'] = 'tok'
rc = frames.main()
check('the run exits 0 even with an unreadable video in the batch', rc == 0)

by = {r['asset_id']: r for r in Store.reports}
check('one report per video', sorted(by) == ['bad', 'land', 'port', 'small'])
check('the token rides on every report', all(r['token'] == 'tok' for r in Store.reports))

land_r = by['land']
check('landscape: ten frames reported', len(land_r['frames'] or []) == 10)
check('frame 0 at one second, then 2 s, 4 s …',
      [f['at'] for f in land_r['frames']] == [1.0, 2.0, 4.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0, 18.0])
check('each under the key the claim gave it',
      [f['key'] for f in land_r['frames']] == ['f/thumb/land-f%02d.jpg' % i for i in range(10)])
sizes = {jpeg_size(Store.puts['/put/land/%d' % i]) for i in range(10)}
check('landscape frames are 640 wide (%s)' % sizes, sizes == {(640, 360)})
check('uploaded as image/jpeg', all(Store.types['/put/land/%d' % i] == 'image/jpeg' for i in range(10)))
check('the frames differ — they are not one still ten times',
      len({Store.puts['/put/land/%d' % i] for i in range(10)}) == 10)

psizes = {jpeg_size(Store.puts['/put/port/%d' % i]) for i in range(10)}
check('portrait frames are 640 TALL (%s)' % psizes, psizes == {(360, 640)})
ssizes = {jpeg_size(Store.puts['/put/small/%d' % i]) for i in range(10)}
check('a small video is never upscaled (%s)' % ssizes, ssizes == {(320, 180)})

check('an unreadable video is reported as a failure with a reason',
      by['bad']['frames'] is None and 'no frame' in by['bad']['note'])

srv.shutdown()
shutil.rmtree(work, ignore_errors=True)
if failures:
    print('%d frames check(s) failed' % failures)
    sys.exit(1)
print('frames: all checks passed')
