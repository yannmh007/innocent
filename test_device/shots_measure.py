#!/usr/bin/env python3
"""What the screenshots of a smooth run show, as numbers (P1, 28 Nov 2026).

The device lab's screenshots are sealed (LAB_RESULTS_KEY: the repository
is public), so a session cannot look at them. This writes, for each
`9_p1_NN_NAME.png` (a plan's `shot:NAME`) and each picture the Screenshot
shortcut saved (`9_shortcut_*.png`), what proves the film's placement
without a picture:

  * the frame's size;
  * the box of the film: the rows and columns where more than 2 % of the
    pixels are not black (luma > 24) — Fit, Crop, 100 %, a zoom and a pan
    each give their own;
  * the mean luma inside it (Night mode reads ~0.4 of its neighbour, a
    brightness filter more);
  * for `mirror_back` and `paused_back`, how much more the shot before
    (`mirror`, `paused_mirror`) resembles it turned left to right than as
    it is (> 1: that one was mirrored; paused, the same frame).

    python3 test_device/shots_measure.py OUT/shots > OUT/smooth_shots.txt

Pillow is installed on the runner if missing (the analysis is lab-only).
"""
import glob
import os
import re
import subprocess
import sys


def _pil():
    try:
        from PIL import Image  # noqa: F401
    except ImportError:
        # The runner's Python is "externally managed" (PEP 668): P1-E7's
        # plain install did nothing.
        for extra in (['--user', '--break-system-packages'], ['--break-system-packages'], []):
            r = subprocess.run([sys.executable, '-m', 'pip', 'install', '-q', *extra, 'pillow'],
                               check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if r.returncode == 0:
                break
        import site
        try:
            sys.path.append(site.getusersitepackages())
        except Exception:
            pass
    from PIL import Image
    return Image


def _luma(img):
    return img.convert('L')


def _box(lum, thresh=24, share=0.02):
    w, h = lum.size
    px = lum.load()
    step = 2
    cols = []
    for x in range(0, w, step):
        n = sum(1 for y in range(0, h, step) if px[x, y] > thresh)
        cols.append(n / (h / step))
    rows = []
    for y in range(0, h, step):
        n = sum(1 for x in range(0, w, step) if px[x, y] > thresh)
        rows.append(n / (w / step))
    xs = [i * step for i, v in enumerate(cols) if v > share]
    ys = [i * step for i, v in enumerate(rows) if v > share]
    if not xs or not ys:
        return None
    return (xs[0], ys[0], xs[-1] + step, ys[-1] + step)


def _mean(lum, box):
    if box is None:
        return 0.0
    crop = lum.crop(box).resize((64, 64))
    data = list(crop.tobytes())
    return sum(data) / len(data)


def _diff(a, b):
    a = a.resize((96, 54)).convert('L')
    b = b.resize((96, 54)).convert('L')
    da = list(a.tobytes())
    db = list(b.tobytes())
    return sum(abs(x - y) for x, y in zip(da, db)) / len(da)


def main():
    if len(sys.argv) < 2:
        print('usage: shots_measure.py SHOTS_DIR')
        return 2
    d = sys.argv[1]
    Image = _pil()
    shots = sorted(glob.glob(os.path.join(d, '9_p1_*.png')))
    shots += sorted(glob.glob(os.path.join(d, '9_shortcut_*.png')))
    if not shots:
        print('shots: none')
        return 0
    prev = None
    for f in shots:
        name = os.path.basename(f)
        try:
            img = Image.open(f).convert('RGB')
        except Exception as e:  # a cut file
            print(f'{name}: unreadable ({type(e).__name__})')
            continue
        lum = _luma(img)
        box = _box(lum)
        mean = _mean(lum, box)
        line = f'{name}: {img.size[0]}x{img.size[1]}'
        if box is None:
            line += ' · all black'
        else:
            bw, bh = box[2] - box[0], box[3] - box[1]
            line += f' · film box {box[0]},{box[1]} {bw}x{bh} · luma {mean:.0f}'
        m = re.match(r'9_p1_\d+_(.*)\.png', name)
        tag = m.group(1) if m else ''
        if tag in ('mirror_back', 'paused_back') and prev is not None:
            plain = _diff(img, prev)
            flipped = _diff(img, prev.transpose(Image.FLIP_LEFT_RIGHT))
            ratio = plain / max(flipped, 0.01)
            line += f' · the last shot as this one turned: {ratio:.2f} (> 1 mirrored)'
        print(line)
        prev = img
    return 0


if __name__ == '__main__':
    sys.exit(main())
