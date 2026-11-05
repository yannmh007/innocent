#!/usr/bin/env python3
"""The transcode runner's media seal, end to end (docs/MEDIA_ENCRYPTION.md §7).

tool/transcode.sh with tool/transcode_seal.py against a stand-in R2 and a
stand-in done endpoint, on a six-second film ffmpeg makes here: a master
BORN SEALED opened on the runner, every rung encoded, then sealed, opened
whole again and compared, uploaded as application/octet-stream to its own
key, and reported with its wrap and header — never its DEK, and no DEK in
the log. Both ways the function can ask: `twin` (the canary: the plain rung
too, and the twin opens to exactly it) and `sealed` (on: no plain rung ever
reaches R2, the rung's key IS its sealed object).

Skipped where ffmpeg is not installed (the ffmpeg half of frames_test does
the same).

  python3 tool/transcode_seal_test.py
"""

import base64, hashlib, http.server, json, os, subprocess, sys, threading, tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, 'tool'))
try:
    import media_seal
except BaseException as e:  # no `cryptography` here (pyo3 panics are BaseException)
    print("SKIP transcode seal: the `cryptography` package does not load here (%s). "
          "The transcode job installs cryptography==50.0.2." % type(e).__name__)
    sys.exit(0)

store, reports = {}, []

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = store[self.path.split('?')[0]]
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_PUT(self):
        n = int(self.headers['Content-Length']); store[self.path.split('?')[0]] = self.rfile.read(n)
        store[self.path.split('?')[0] + '#type'] = self.headers.get('Content-Type', '').encode()
        self.send_response(200); self.end_headers()
    def do_POST(self):
        n = int(self.headers['Content-Length']); reports.append(json.loads(self.rfile.read(n)))
        self.send_response(200); self.end_headers(); self.wfile.write(b'{}')

srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f'http://127.0.0.1:{srv.server_address[1]}'

def run(mode):
    store.clear(); reports.clear()
    work = tempfile.mkdtemp()
    film = os.path.join(work, 'film.mp4')
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24', '-f', 'lavfi',
                    '-i', 'sine=frequency=330', '-t', '6', '-c:v', 'libx264', '-preset', 'ultrafast', '-b:v', '6M',
                    '-c:a', 'aac', '-shortest', film], check=True)
    plain_master = open(film, 'rb').read()

    def issue():
        dek = os.urandom(32); dek_id = 'a1b2c3d4-0000-4000-8000-' + os.urandom(6).hex()
        return dek, dek_id

    # The master, born sealed.
    mdek, mid = issue()
    from io import BytesIO
    out = BytesIO()
    media_seal.seal_stream(BytesIO(plain_master), out, mdek, media_seal.aad_for(mid), len(plain_master))
    store['/media/s/master'] = out.getvalue()

    job = {'asset_id': 'asset-1', 'src_url': base + '/media/s/master', 'done_url': base + '/done',
           'src_seal': {'dek_id': mid, 'dek': base64.b64encode(mdek).decode(), 'plain_size': len(plain_master),
                        'sealed_size': len(out.getvalue())},
           'put': {}, 'seal': {}}
    for h in (240, 360, 480, 720):
        if mode == 'twin':
            job['put'][str(h)] = f'{base}/media/video/film-{h}p.mp4?X-Amz-Signature=x'
        d, i = issue()
        job['seal'][str(h)] = {'dek_id': i, 'dek': base64.b64encode(d).decode(), 'wrapped': 'W' + i,
                               'sealed_key': f's/{h:032x}', 'put_url': f'{base}/media/s/{h:032x}?X-Amz-Signature=x'}
    job_file = os.path.join(work, 'job.json')
    json.dump(job, open(job_file, 'w'))

    env = dict(os.environ, ASSET_ID='asset-1', SRC_URL=job['src_url'], DONE_URL=job['done_url'],
               PUT_BASE=json.dumps(job['put']), JOB_TOKEN='t', JOB_FILE=job_file)
    r = subprocess.run(['bash', os.path.join(REPO, 'tool/transcode.sh')], env=env, capture_output=True, text=True)
    log = r.stdout + r.stderr
    assert r.returncode == 0, log[-3000:]
    assert base64.b64encode(mdek).decode() not in log, 'a DEK was printed'
    for v in job['seal'].values():
        assert v['dek'] not in log, 'a rung DEK was printed'

    final = reports[-1]
    assert final['note'] == 'complete', final['note']
    rows = final['rows']
    pass
    assert rows, 'no rungs'
    for row in rows:
        s = row['sealed']
        sealed = store['/media/' + s['sealed_key']]
        assert store['/media/' + s['sealed_key'] + '#type'] == b'application/octet-stream'
        v = job['seal'][str(row['height'])]
        got = BytesIO()
        media_seal.open_stream(BytesIO(sealed), got, base64.b64decode(v['dek']), media_seal.aad_for(v['dek_id']), len(sealed))
        assert s['plain_size'] == len(got.getvalue()) and s['wrapped'] == v['wrapped'] and 'dek' not in s
        assert base64.b64decode(s['header']) == sealed[:40]
        if mode == 'twin':
            plain = store[f'/media/video/film-{row["height"]}p.mp4']
            assert hashlib.sha256(plain).digest() == hashlib.sha256(got.getvalue()).digest(), 'twin is not the plain rung'
            assert row['object_key'] == f'video/film-{row["height"]}p.mp4'
        else:
            assert row['object_key'] == s['sealed_key'], 'born sealed: the rung is its sealed object'
            assert not any(k.startswith('/media/video/') for k in store), 'a plain rung reached R2'
    print(mode, 'OK:', len(rows), 'rungs, every sealed rung opens to the encode; no DEK printed')


if __name__ == '__main__':
    import shutil
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
        print('transcode seal: skipped (no ffmpeg here)')
        sys.exit(0)
    for m in ('twin', 'sealed'):
        run(m)
    print('transcode seal: all checks passed (2 modes)')
