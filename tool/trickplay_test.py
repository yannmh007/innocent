#!/usr/bin/env python3
"""tool/trickplay.py: the ITP1 pack the app's seek bar reads by range.

What must hold: the header says what is inside (count, interval, size,
codec) and every offset bounds one whole image file, in order, the last at
the file's end; picture i is the film at i * interval (a 12 s film every
2 s is six pictures); the height follows the film's shape, never squashed;
a pack cut short or of another version is refused, not misread. The app's
reader (lib/features/video_hub/domain/trickplay_pack.dart, when it lands)
reads exactly this layout; the format is the module's docstring.

Needs `ffmpeg` on PATH for the second half (the runner installs it).
RUN:  python3 tool/trickplay_test.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import trickplay  # noqa: E402

failures = 0


def check(label, ok):
    global failures
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        failures += 1


# ── the layout, without ffmpeg ───────────────────────────────────────────
pics = [b'\xff\xd8one\xff\xd9', b'\xff\xd8second\xff\xd9', b'\xff\xd8x\xff\xd9']
data = trickplay.pack(pics, 4000, 224, 126, 'jpeg')
iv, w, h, codec, offs = trickplay.read_header(data)
check('the header says what is inside', (iv, w, h, codec, len(offs)) == (4000, 224, 126, 'jpeg', 4))
check('each offset bounds its picture, in order',
      [data[offs[i]:offs[i + 1]] for i in range(3)] == pics)
check('the last offset is the end of the file', offs[-1] == len(data))
check('the first picture starts right after the header', offs[0] == 24 + 4 * 4)
for bad, why in ((data[:20], 'cut inside the header'),
                 (b'ITP2' + data[4:], 'another magic'),
                 (data[:4] + b'\x00\x02' + data[6:], 'another version')):
    try:
        trickplay.read_header(bad)
        check(f'refused: {why}', False)
    except ValueError:
        check(f'refused: {why}', True)
empty = trickplay.pack([], 4000, 224, 126, 'webp')
check('an empty pack is a header and one offset', trickplay.read_header(empty)[4] == [28])

# ── against a real ffmpeg ────────────────────────────────────────────────
if not shutil.which('ffmpeg'):
    print('SKIP the ffmpeg half: no ffmpeg on PATH')
else:
    work = tempfile.mkdtemp(prefix='trick_test_')
    try:
        film = os.path.join(work, 'film.mp4')
        subprocess.run(['ffmpeg', '-nostdin', '-y', '-loglevel', 'error', '-f', 'lavfi',
                        '-i', 'testsrc2=size=426x240:rate=24', '-t', '12', '-c:v', 'libx264',
                        '-pix_fmt', 'yuv420p', film], check=True)
        out = os.path.join(work, 'film.itp')
        rc = trickplay.main([film, out, '--interval', '2', '--width', '224'])
        check('made', rc == 0 and os.path.exists(out))
        with open(out, 'rb') as fh:
            got = fh.read()
        iv, w, h, codec, offs = trickplay.read_header(got)
        n = len(offs) - 1
        check(f'a 12 s film every 2 s is six pictures (got {n})', n == 6)
        check('2000 ms apart, 224 wide', (iv, w) == (2000, 224))
        check(f'its shape kept: 426x240 -> 224x126 (got {h})', h == 126)
        check('every picture is a whole JPEG',
              all(got[offs[i]:offs[i] + 2] == b'\xff\xd8' and got[offs[i + 1] - 2:offs[i + 1]] == b'\xff\xd9'
                  for i in range(n)))
        if subprocess.run(['ffmpeg', '-hide_banner', '-encoders'], capture_output=True,
                          text=True).stdout.find('libwebp') >= 0:
            outw = os.path.join(work, 'film_w.itp')
            rc = trickplay.main([film, outw, '--interval', '4', '--width', '160', '--codec', 'webp'])
            with open(outw, 'rb') as fh:
                gw = fh.read()
            iv, w, h, codec, offs = trickplay.read_header(gw)
            check(f'WebP: three pictures 160x90 (got {len(offs) - 1}, {w}x{h})',
                  rc == 0 and codec == 'webp' and len(offs) - 1 == 3 and (w, h) == (160, 90))
            check('every picture is a whole WebP', all(gw[offs[i]:offs[i] + 4] == b'RIFF' for i in range(3)))
        else:
            print('SKIP WebP: this ffmpeg has no libwebp')
    finally:
        shutil.rmtree(work, ignore_errors=True)

print(f'{failures} failure(s)')
sys.exit(1 if failures else 0)
