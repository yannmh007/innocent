#!/usr/bin/env python3
"""Reference lab, Phase 1: side-by-side sheets and the decision table.

  compare.py DUMP_DIR MEASURES_JSON OUT_DIR

DUMP_DIR holds the panels run's screenshots (<app>_<orient>_<frame>_<screen>
.png); MEASURES_JSON is tool/ref/measure.py's. Writes into OUT_DIR:

  sheet_<screen>_<orient>.png   MX and Innocent side by side over the black
                                and the white frame, and Innocent's screen
                                with MX's panel box (cyan) and rows drawn
                                over its own (magenta); the picture yellow
  decision.md                   per panel and orientation: MX's figure,
                                Innocent's, and a first reading — "Innocent
                                ပိုသာ — မပြောင်း", "MX ပိုသာ — ယူ" or "owner
                                ဆုံးဖြတ်" — with the reason. The owner decides.

The sheets hold MX's screens: OUT_DIR is innocent-ref's run folder or the
session's scratchpad, never this public repository. Layout and behaviour
only; no colour is read from either app's screens (skill ui-design §4).
Run with python3 -I.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SCREENS = (('more', '⋮ (more)'), ('audio', '♪ (audio)'), ('cc', 'CC (subtitles)'))
NAMES = {'more': '⋮', 'audio': '♪', 'cc': 'CC'}
CYAN, MAGENTA, YELLOW, INK, PAPER = (0, 200, 255), (255, 60, 200), (255, 210, 0), (230, 230, 230), (24, 24, 26)


def font(size):
    for p in ('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
              '/usr/share/fonts/dejavu/DejaVuSans.ttf'):
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def shot(src, name, scale):
    p = os.path.join(src, name + '.png')
    if not os.path.exists(p):
        return None
    im = Image.open(p).convert('RGB')
    return im.resize((round(im.width * scale), round(im.height * scale)))


def box(draw, b, scale, colour, width):
    if b:
        draw.rectangle([v * scale for v in b], outline=colour, width=width)


def dash(draw, b, scale, colour):
    x1, y1, x2, y2 = (v * scale for v in b)
    step = 12
    for x in range(int(x1), int(x2), step * 2):
        draw.line([(x, y1), (min(x + step, x2), y1)], fill=colour, width=2)
        draw.line([(x, y2), (min(x + step, x2), y2)], fill=colour, width=2)
    for y in range(int(y1), int(y2), step * 2):
        draw.line([(x1, y), (x1, min(y + step, y2))], fill=colour, width=2)
        draw.line([(x2, y), (x2, min(y + step, y2))], fill=colour, width=2)


def picture(w, h):
    a = 16 / 9 if w > h else 9 / 16
    if w / h > a:
        pw = h * a
        return ((w - pw) / 2, 0, (w + pw) / 2, h)
    ph = w / a
    return (0, (h - ph) / 2, w, (h + ph) / 2)


def sheet(src, meas, dp, screen, orient, out):
    land = orient == 'land'
    scale = 0.33 if land else 0.36
    cells = []
    for frame in ('black', 'white'):
        for app in ('mx', 'inn'):
            cells.append((('MX 3.4.3' if app == 'mx' else 'Innocent') + ' · over ' + frame,
                          shot(src, '%s_%s_%s_%s' % (app, orient, frame, screen), scale)))
    over = shot(src, 'inn_%s_black_%s' % (orient, screen), scale)
    if over is not None:
        d = ImageDraw.Draw(over)
        sw, sh = over.width / scale, over.height / scale
        dash(d, picture(sw, sh), scale, YELLOW)
        mi = meas.get('inn %s %s black' % (screen, orient))
        mm = meas.get('mx %s %s black' % (screen, orient))
        if mi:
            box(d, [v * dp for v in mi['box_dp']], scale, MAGENTA, 4)
        if mm:
            box(d, [v * dp for v in mm['box_dp']], scale, CYAN, 4)
            for r in mm.get('rows_dp', []):
                box(d, [v * dp for v in r], scale, CYAN, 1)
    cells.append(('Innocent; boxes: MX cyan, ours magenta', over))
    real = [c for _, c in cells if c is not None]
    if not real:
        return None
    cw = max(c.width for c in real)
    ch = max(c.height for c in real)
    cols = 2 if land else 3
    label_h, pad = 34, 16
    rows = (len(cells) + cols - 1) // cols
    W = cols * cw + (cols + 1) * pad
    H = 60 + rows * (ch + label_h + pad) + pad
    img = Image.new('RGB', (W, H), PAPER)
    d = ImageDraw.Draw(img)
    d.text((pad, 16), '%s, %s — proportions and behaviour only' % (
        dict(SCREENS)[screen], 'sideways' if land else 'upright'), fill=INK, font=font(24))
    order = cells if land else [cells[0], cells[1], cells[4], cells[2], cells[3]]
    for i, (label, c) in enumerate(order):
        r, k = divmod(i, cols)
        x = pad + k * (cw + pad)
        y = 60 + r * (ch + label_h + pad)
        d.text((x, y), label, fill=INK, font=font(18))
        if c is not None:
            img.paste(c, (x, y + label_h))
        else:
            d.rectangle([x, y + label_h, x + cw, y + label_h + ch], outline=(90, 90, 90), width=2)
            d.text((x + 12, y + label_h + 12), 'not taken', fill=INK, font=font(18))
    p = os.path.join(out, 'sheet_%s_%s.png' % (screen, orient))
    img.save(p, optimize=True)
    return p


def reading(screen, orient, mx, inn):
    """(metric, MX, Innocent, verdict, why) rows: a first reading for the
    owner, who decides each one."""
    out = []
    if not mx or not inn:
        out.append(('—', 'n/a' if not mx else 'ok', 'n/a' if not inn else 'ok',
                    'owner ဆုံးဖြတ်', 'one side was not taken: run again before deciding'))
        return out
    port = orient == 'port'
    same = mx['anchor'] == inn['anchor']
    out.append(('anchor (ကပ်တဲ့ဘက်)', mx['anchor'], inn['anchor'],
                'တူ — မပြောင်း' if same else 'owner ဆုံးဖြတ်',
                'both rise from the same edge' if same else 'they come from different edges'))
    if port:
        d = mx['rise_pct'] - inn['rise_pct']
        if d > 3:
            v, why = 'Innocent ပိုသာ — မပြောင်း', 'MX rises higher over the picture; 55 % is the owner\'s choice (12 Nov)'
        elif d < -5:
            v, why = 'owner ဆုံးဖြတ်', 'MX stops lower and leaves more of the picture'
        else:
            v, why = 'တူသလောက် — မပြောင်း', 'within a few points'
        out.append(('height (screen %)', '%.0f %%' % mx['rise_pct'], '%.0f %%' % inn['rise_pct'], v, why))
    else:
        d = mx['w_pct'] - inn['w_pct']
        if abs(d) <= 5:
            v, why = 'တူသလောက် — မပြောင်း', 'within five points'
        elif d > 5:
            v, why = 'Innocent ပိုသာ — မပြောင်း', 'MX\'s panel is wider and covers more picture'
        else:
            v, why = 'owner ဆုံးဖြတ်', 'MX\'s is narrower: more picture, less room for Burmese'
        out.append(('width (screen %)', '%.0f %%' % mx['w_pct'], '%.0f %%' % inn['w_pct'], v, why))
    d = mx['picture_pct'] - inn['picture_pct']
    out.append(('picture left uncovered', '%.0f %%' % mx['picture_pct'], '%.0f %%' % inn['picture_pct'],
                'Innocent ပိုသာ — မပြောင်း' if d <= 3 else 'owner ဆုံးဖြတ်',
                'Innocent leaves as much or more (and its glass shows the rest as colour)' if d <= 3
                else 'MX leaves %.0f points more of the picture clear' % d))
    mk = '%d of %d' % (mx['controls_kept'], mx['controls_before'])
    ik = '%d of %d' % (inn['controls_kept'], inn['controls_before'])
    if inn['controls_kept'] == 0 and mx['controls_kept'] > 0:
        v, why = 'Innocent ပိုသာ — မပြောင်း', 'one layer at a time: nothing sharp shows through (11 Nov)'
    elif inn['controls_kept'] > 0 and mx['controls_kept'] == 0:
        v, why = 'MX ပိုသာ — ယူ', 'MX clears the controls away; Innocent leaves some up'
    else:
        v, why = 'တူ — မပြောင်း', 'both do the same'
    out.append(('controls left up', mk, ik, v, why))
    if mx['row_h_dp'] and inn['row_h_dp']:
        d = mx['row_h_dp'] - inn['row_h_dp']
        if d < -2 and inn['row_h_dp'] >= 48:
            v, why = 'Innocent ပိုသာ — မပြောင်း', 'Innocent\'s rows are the 48 dp touch size or more; Burmese needs the height'
        elif d > 4:
            v, why = 'owner ဆုံးဖြတ်', 'MX\'s rows are taller'
        else:
            v, why = 'တူသလောက် — မပြောင်း', 'within a few dp'
        out.append(('row height (dp)', str(mx['row_h_dp']), str(inn['row_h_dp']), v, why))
    if mx['inset_l_dp'] is not None and inn['inset_l_dp'] is not None:
        d = mx['inset_l_dp'] - inn['inset_l_dp']
        out.append(('side inset (dp)', str(mx['inset_l_dp']), str(inn['inset_l_dp']),
                    'တူသလောက် — မပြောင်း' if abs(d) <= 4 else 'owner ဆုံးဖြတ်',
                    'within 4 dp' if abs(d) <= 4 else 'a different margin inside the panel'))
    return out


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    src, mpath, out = argv
    with open(mpath, encoding='utf-8') as f:
        data = json.load(f)
    meas = data['measures']
    with open(os.path.join(src, 'display.txt'), encoding='utf-8') as f:
        dpi = int(f.read().split()[2])
    dp = dpi / 160
    os.makedirs(out, exist_ok=True)
    made = []
    lines = ['# Reference lab — decision table (owner decides each row)', '',
             'Screen %d x %d dp. Proportions and behaviour only; colour is never compared with MX. '
             'Over the black frame; the white frame gave %s.' % (
                 data['screen_dp'][0], data['screen_dp'][1], '{white}'), '']
    diffs = 0
    for screen, title in SCREENS:
        for orient in ('port', 'land'):
            p = sheet(src, meas, dp, screen, orient, out)
            if p:
                made.append(os.path.basename(p))
            mx = meas.get('mx %s %s black' % (screen, orient))
            inn = meas.get('inn %s %s black' % (screen, orient))
            for app in ('mx', 'inn'):
                a, b = meas.get('%s %s %s black' % (app, screen, orient)), meas.get('%s %s %s white' % (app, screen, orient))
                if a and b and (a['box_dp'] != b['box_dp']):
                    diffs += 1
            lines += ['## %s — %s' % (title, 'upright' if orient == 'port' else 'sideways'), '',
                      '| | MX 3.4.3 | Innocent | reading | why |', '|---|---|---|---|---|']
            for row in reading(screen, orient, mx, inn):
                lines.append('| %s |' % ' | '.join(row))
            lines.append('')
    lines[2] = lines[2].replace('{white}', 'the same boxes' if diffs == 0 else
                                '%d box(es) that moved — read those twice' % diffs)
    with open(os.path.join(out, 'decision.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print('sheets: %d; decision table: %d panel screens' % (len(made), len(SCREENS) * 2))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
