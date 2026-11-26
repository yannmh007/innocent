#!/usr/bin/env python3
"""Reference lab: MX and Innocent's screenshots of one run side by side.

For the owner's eyes only. It reads a run kept in the private innocent-ref
(runs/<date>_<run id>/, a local clone) and writes PNG sheets to OUT_DIR,
which must be outside this repository (the session's scratchpad): the
sheets hold MX's screens, and invariant 16 fails a picture under tool/ref
or test_device/ref. Send them with SendUserFile; never commit them here,
never upload them from a public run.

  sideways: one sheet per frame, a row per panel, MX left, Innocent right
  upright:  one sheet per frame, pairs across (MX | Innocent) per panel

Run with python3 -I (the screenshots are another company's app's output,
data only). Needs Pillow and DejaVuSans for the labels.

  pair.py RUN_DIR OUT_DIR [SCREEN ...]     SCREEN: cc audio more (default)
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'


def font(n):
    try:
        return ImageFont.truetype(FONT, n)
    except OSError:
        return ImageFont.load_default()


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    run, out = argv[0], argv[1]
    screens = argv[2:] or ['cc', 'audio', 'more']
    here = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if os.path.abspath(out).startswith(here + os.sep):
        print('OUT_DIR is inside the public repository: use the scratchpad', file=sys.stderr)
        return 2
    os.makedirs(out, exist_ok=True)
    made = 0
    for orient in ('land', 'port'):
        for frame in ('white', 'black'):
            rows = []
            for sc in screens:
                m = os.path.join(run, 'mx_%s_%s_%s.png' % (orient, frame, sc))
                i = os.path.join(run, 'inn_%s_%s_%s.png' % (orient, frame, sc))
                if os.path.exists(m) and os.path.exists(i):
                    rows.append((sc, Image.open(m).convert('RGB'), Image.open(i).convert('RGB')))
            if not rows:
                continue
            k = 0.42 if orient == 'land' else 0.36
            rows = [(s, a.resize((int(a.width * k), int(a.height * k))),
                     b.resize((int(b.width * k), int(b.height * k)))) for s, a, b in rows]
            cw = max(r[1].width for r in rows)
            pad, lh = 12, 24
            if orient == 'land':
                img = Image.new('RGB', (2 * cw + 3 * pad, 40 + sum(r[1].height + lh + pad for r in rows)),
                                (24, 24, 26))
                d = ImageDraw.Draw(img)
                d.text((pad, 10), 'sideways, %s frame - left MX | right Innocent' % frame,
                       fill=(230, 230, 230), font=font(16))
                y = 40
                for s, a, b in rows:
                    d.text((pad, y + 3), s, fill=(210, 210, 210), font=font(13))
                    img.paste(a, (pad, y + lh))
                    img.paste(b, (2 * pad + cw, y + lh))
                    y += a.height + lh + pad
            else:
                ch = max(r[1].height for r in rows)
                img = Image.new('RGB', (len(rows) * 2 * (cw + pad) + pad, 40 + lh + ch + pad), (24, 24, 26))
                d = ImageDraw.Draw(img)
                d.text((pad, 10), 'upright, %s frame - each pair: MX | Innocent' % frame,
                       fill=(230, 230, 230), font=font(16))
                x = pad
                for s, a, b in rows:
                    d.text((x, 40), '%s: MX' % s, fill=(210, 210, 210), font=font(13))
                    img.paste(a, (x, 40 + lh))
                    x += cw + pad
                    d.text((x, 40), '%s: Innocent' % s, fill=(210, 210, 210), font=font(13))
                    img.paste(b, (x, 40 + lh))
                    x += cw + pad
            p = os.path.join(out, 'pair_%s_%s.png' % (orient, frame))
            img.save(p, optimize=True)
            print(p, img.size)
            made += 1
    if not made:
        print('no pair of screenshots found in %s' % run, file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
