#!/usr/bin/env python3
"""The fragment layout of every streaming copy of a title, and what a seek in
one of them reads — through the real Worker, as the phone reads it.

    layout_and_seek.py /tmp/p.json [ffmpeg-6.0-binary]

/tmp/p.json is request-playback's answer. Prints, per copy: its length, its
top-level boxes, its tracks (handler types), and each sidx — which track it
indexes, how many fragments, and whether its fragments add up to the end of
the file. FFmpeg's MP4 demuxer jumps straight to a fragment only when they
do ("frag_index.complete"); otherwise a seek READS ITS WAY THERE from the
start — on Test Lab's phones a seek to 40 % of Sintel read about 180 MB and
took 32 to 45 s on a fast line (run 39202304734).

Then a seek to 40 % of the 720p copy (or the largest under it), through a
local relay that logs every range: with the system ffmpeg, with mpv, and
with the FFmpeg 6.0 binary if given (the app's libmpv is built on 6.0). How
many bytes each read, and the first ranges, say whether it jumped.

Never prints a URL: each carries a live token and this log is public.
"""
import http.server, json, os, struct, subprocess, sys, threading, time, urllib.request, urllib.error

UA = {'User-Agent': 'innocent-playback-check/1'}


def get(url, a, b):
    req = urllib.request.Request(url, headers={**UA, 'Range': f'bytes={a}-{b}'})
    with urllib.request.urlopen(req, timeout=90) as r:
        cr = r.headers.get('Content-Range') or ''
        return r.read(), int(cr.split('/')[-1]) if '/' in cr else None


def boxes(buf, base=0, end=None):
    out, at, end = [], base, len(buf) if end is None else end
    while at + 8 <= end:
        size, kind = struct.unpack('>I4s', buf[at:at + 8])
        hdr = 8
        if size == 1:
            if at + 16 > end: break
            size = struct.unpack('>Q', buf[at + 8:at + 16])[0]; hdr = 16
        if size < 8: break
        out.append((kind.decode('latin1'), at, size, hdr))
        at += size
    return out


def handlers(buf, moov_at, moov_size):
    found = []
    for k, at, size, hdr in boxes(buf, moov_at + 8, min(len(buf), moov_at + moov_size)):
        if k != 'trak': continue
        for k2, at2, s2, h2 in boxes(buf, at + hdr, min(len(buf), at + size)):
            if k2 != 'mdia': continue
            for k3, at3, s3, h3 in boxes(buf, at2 + 8, min(len(buf), at2 + s2)):
                if k3 == 'hdlr':
                    found.append(buf[at3 + 16:at3 + 20].decode('latin1'))
    return found


def sidx(buf, at, size, total):
    p = at + 8
    ver = buf[p]; p += 4
    ref, scale = struct.unpack('>II', buf[p:p + 8]); p += 8
    if ver == 0:
        ept, first = struct.unpack('>II', buf[p:p + 8]); p += 8
    else:
        ept, first = struct.unpack('>QQ', buf[p:p + 16]); p += 16
    p += 2
    n = struct.unpack('>H', buf[p:p + 2])[0]; p += 2
    off = at + size + first
    dur = 0
    kinds = set()
    for _ in range(n):
        a, d, _s = struct.unpack('>III', buf[p:p + 12]); p += 12
        kinds.add(a >> 31)
        off += a & 0x7fffffff
        dur += d
    return {'track': ref, 'fragments': n, 'seconds': round(dur / scale, 1) if scale else None,
            'ends_at_eof': off == total, 'end_offset_minus_total': off - total,
            'refs_to_sidx': 1 in kinds}


class Relay(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    upstream = ''
    log = []
    def log_message(self, *a): pass
    def do_GET(self):
        rng = self.headers.get('Range')
        h = dict(UA)
        if rng: h['Range'] = rng
        try:
            r = urllib.request.urlopen(urllib.request.Request(self.upstream, headers=h), timeout=90)
        except urllib.error.HTTPError as e:
            r = e
        self.send_response(r.status if hasattr(r, 'status') else r.code)
        for k in ('Content-Range', 'Content-Length', 'Accept-Ranges', 'Content-Type'):
            v = r.headers.get(k)
            if v: self.send_header(k, v)
        self.end_headers()
        start = int(rng[6:].split('-')[0]) if rng and rng.startswith('bytes=') and rng[6:].split('-')[0] else 0
        sent = 0
        try:
            while True:
                chunk = r.read(64 * 1024)
                if not chunk: break
                self.wfile.write(chunk); sent += len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        Relay.log.append((start, sent))


def seek_test(name, cmd):
    # ONE FRAME at the moment, nothing more, so what was read is what the
    # seek cost — not a player's read-ahead.
    Relay.log = []
    t = time.time()
    p = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=300)
    took = time.time() - t
    total = sum(s for _, s in Relay.log)
    reads = ', '.join(f'{a / 1048576:.1f}+{n / 1048576:.1f}' for a, n in Relay.log[:10])
    print(f'  {name:<14} exit {p.returncode}  {len(Relay.log)} requests, '
          f'{total / 1048576:.1f} MB read, first frame in {took:.1f} s  | MB at+read: {reads}')


def main():
    d = json.load(open(sys.argv[1]))
    ff60 = sys.argv[2] if len(sys.argv) > 2 else None
    rungs = sorted([r for r in d.get('renditions') or [] if r.get('url')],
                   key=lambda r: r.get('height') or 0)
    print(f'{len(rungs)} copies')
    pick = None
    for r in rungs:
        head, total = get(r['url'], 0, 2 * 1024 * 1024 - 1)
        top = boxes(head)
        names = ' '.join(k for k, *_ in top[:8])
        moov = next(((at, s) for k, at, s, _ in top if k == 'moov'), None)
        hd = handlers(head, *moov) if moov else []
        sx = [sidx(head, at, s, total) for k, at, s, _ in top if k == 'sidx' and at + s <= len(head)]
        print(f"{r.get('height')}p {total / 1048576:.1f} MB  boxes: {names}  tracks: {hd}")
        for i, x in enumerate(sx):
            print(f'    sidx {i}: {x}')
        if (r.get('height') or 0) <= 720:
            pick = (r, total, sx)
    if not pick:
        return
    r, total, sx = pick
    secs = next((x['seconds'] for x in sx if x['seconds']), None) or 600
    at = int(secs * 0.4)
    Relay.upstream = r['url']
    srv = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Relay)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    local = f'http://127.0.0.1:{srv.server_address[1]}/film.mp4'
    print(f"seek to {at} s of {secs} s in the {r.get('height')}p copy ({total / 1048576:.1f} MB):")
    one = ['-nostdin', '-v', 'error', '-ss', str(at), '-i', local, '-map', '0:v:0', '-frames:v', '1', '-f', 'null', '-']
    seek_test('ffmpeg system', ['ffmpeg'] + one)
    if ff60 and os.path.exists(ff60):
        seek_test('ffmpeg 6.0', [ff60] + one)
    seek_test('mpv --start', ['mpv', '--no-config', '--vo=null', '--ao=null', f'--start={at}', '--frames=1',
                              '--demuxer-max-bytes=4MiB', '--cache-secs=1', '--demuxer-readahead-secs=1', local])
    srv.shutdown()


if __name__ == '__main__':
    main()
