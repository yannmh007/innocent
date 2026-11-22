#!/usr/bin/env python3
"""Reference lab, Phase 1: how a panel sits against the picture, from dumps.

Reads uiautomator dumps that the panels run left (test_device/ref/panels.sh):
  <app>_<orient>_<frame>_<screen>.xml   app mx|inn, orient port|land,
                                        frame black|white,
                                        screen controls|more|audio|cc
and display.txt ("W H DPI" of the portrait screen). For each panel screen
it sets the dump beside the same app's controls dump and measures LAYOUT
AND BEHAVIOUR ONLY, never colour (skill ui-design §4):

  panel       the box of what the panel added (its nodes not in the
              controls dump, scrims of the whole screen left out: the node
              holding the most of the others and what sits around it),
              each edge snapped to the screen's or the window's within
              SNAP_DP. Innocent's: its glass read from its own screenshot
              over the white frame (its semantics hold only the content)
  anchor      which screen edges it holds to: bottom, right, ...
  w_pct h_pct its width and height against the screen
  rise_pct    how far up the screen its top is, from the bottom
  picture_pct how much of the picture (the film fitted: 16:9 sideways,
              9:16 upright) it leaves uncovered
  controls    of the controls dump's clickable nodes outside the panel, how
              many are still there (0 = the controls give way)
  rows        the panel's clickable rows: count, median height, the side
              insets from the panel's edges, the gap between rows (dp)

Run with python3 -I: the dumps came from another company's app and are
data. Output: measures.json and measures.tsv (numbers and our own labels
only), into OUT_DIR.

  measure.py DUMP_DIR OUT_DIR [MX_PACKAGE]
"""
import json
import os
import re
import statistics
import sys
import xml.etree.ElementTree as ET

INN_PACKAGE = 'com.innocent.media'
SNAP_DP = 8
SCREENS = ('more', 'audio', 'cc')
FILM_ASPECT = 16 / 9


def nodes(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return []
    out = []
    for n in root.iter('node'):
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', n.get('bounds', ''))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        if x2 <= x1 or y2 <= y1:
            continue
        out.append({
            'pkg': n.get('package', ''), 'cls': n.get('class', ''),
            'id': n.get('resource-id', ''), 'click': n.get('clickable') == 'true',
            'scroll': n.get('scrollable') == 'true',
            'text': bool(n.get('text') or n.get('content-desc')),
            'box': (x1, y1, x2, y2),
        })
    return out


def key(n):
    return (n['cls'], n['id'], n['box'])


def area(b):
    return max(0, b[2] - b[0]) * max(0, b[3] - b[1])


def inter(a, b):
    return (max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3]))


def inside(b, c):
    """b's centre within c."""
    x, y = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    return c[0] <= x <= c[2] and c[1] <= y <= c[3]


def union(boxes):
    return (min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes))


def picture(w, h):
    """The film fitted into the screen, centred (both apps open in Fit):
    the wide film sideways, the upright film (9:16) upright."""
    a = FILM_ASPECT if w > h else 1 / FILM_ASPECT
    if w / h > a:
        pw = h * a
        return ((w - pw) / 2, 0, (w + pw) / 2, h)
    ph = w / a
    return (0, (h - ph) / 2, w, (h + ph) / 2)


def own_surface(png, port, w, h, cb, dp):
    """Innocent's panel surface from its OWN screenshot over the white frame
    (never MX's): its semantics give the content, not the glass around it,
    and its tree is clipped 96 dp short of this phone's screen (run
    44999637142). From inside the content, walk out until the glass gives
    way to the dimmed picture. None when it cannot be read."""
    try:
        from PIL import Image
    except ImportError:
        return None
    try:
        im = Image.open(png).convert('L')
    except OSError:
        return None
    if im.size != (w, h):
        return None
    px = im.load()
    if port:
        x, y = w // 2, min(h - 1, cb[1] + int(8 * dp))
        ref = px[x, y]
        while y > 0 and abs(px[x, y - 1] - ref) <= 30:
            y -= 1
        return (0, y, w, h)
    y = min(h - 1, (cb[1] + cb[3]) // 2)
    x = min(w - 1, cb[0] + int(8 * dp))
    ref = px[x, y]
    while x > 0 and abs(px[x - 1, y] - ref) <= 30:
        x -= 1
    top = min(h - 1, cb[1] + int(8 * dp))
    xx = min(w - 1, x + int(40 * dp))
    ref = px[xx, top]
    while top > 0 and abs(px[xx, top - 1] - ref) <= 30:
        top -= 1
    return (x, top, w, h)


def measure(base, panel, pkg, w, h, dp, shot=None):
    snap = SNAP_DP * dp
    full = 0.9 * w * h
    before = {key(n) for n in base}
    added = [n for n in panel if n['pkg'] == pkg and key(n) not in before and area(n['box']) < full]
    if not added:
        return None
    # The panel: the added node that holds the most of the others (its
    # container; a bare touch area beside it holds none), with what sits
    # inside or just around it and is no bigger (a header above a list).
    # A prompt the app showed on one open and not the other stays out.
    def holds(c):
        return sum(1 for n in added if n is not c and inside(n['box'], c['box']))
    best = max(added, key=lambda c: (holds(c), -area(c['box'])))
    if holds(best) == 0:
        best = max(added, key=lambda c: area(c['box']))
    cb = best['box']
    grow = (cb[0] - 24 * dp, cb[1] - 72 * dp, cb[2] + 24 * dp, cb[3] + 72 * dp)
    added = [n for n in added if n is best or
             (area(n['box']) <= area(cb) and inside(n['box'], grow))]
    x1, y1, x2, y2 = union([n['box'] for n in added])
    surface = own_surface(shot, h > w, w, h, (x1, y1, x2, y2), dp) if shot else None
    if surface:
        x1, y1, x2, y2 = surface
    # The app's window can stop short of the screen (the navigation bar's
    # strip): an edge on the window's edge is on the screen's.
    win = next((n['box'] for n in panel if n['pkg'] == pkg), (0, 0, w, h))
    x1 = 0 if x1 <= max(snap, win[0] + snap) else x1
    y1 = 0 if y1 <= max(snap, win[1] + snap) else y1
    x2 = w if x2 >= min(w - snap, win[2] - snap) else x2
    y2 = h if y2 >= min(h - snap, win[3] - snap) else y2
    box = (x1, y1, x2, y2)
    anchor = [e for e, on in (('top', y1 == 0), ('bottom', y2 == h),
                              ('left', x1 == 0), ('right', x2 == w)) if on]
    pic = picture(w, h)
    covered = area(inter(pic, box)) / area(pic)
    # The controls: clickable nodes of the app in the controls dump, away
    # from the panel. Still in the panel's dump at the same place = still up.
    ctl = [n for n in base if n['pkg'] == pkg and n['click'] and area(inter(n['box'], box)) == 0
           and area(n['box']) < full]
    now = {key(n) for n in panel}
    kept = sum(1 for n in ctl if key(n) in now)
    # Rows: clickable, inside the panel, a row's shape (wider than tall,
    # 32-140 dp high).
    rows = sorted((n['box'] for n in added if n['click']
                   and 32 * dp <= n['box'][3] - n['box'][1] <= 140 * dp
                   and n['box'][2] - n['box'][0] > n['box'][3] - n['box'][1]),
                  key=lambda b: (b[1], b[0]))
    heights = [(b[3] - b[1]) / dp for b in rows]
    gaps = [(b2[1] - b1[3]) / dp for b1, b2 in zip(rows, rows[1:]) if b2[1] >= b1[3]]
    r = {
        'box_dp': [round(v / dp) for v in box],
        'anchor': '+'.join(anchor) or 'floating',
        'w_pct': round(100 * (x2 - x1) / w, 1),
        'h_pct': round(100 * (y2 - y1) / h, 1),
        'rise_pct': round(100 * (h - y1) / h, 1),
        'picture_pct': round(100 * (1 - covered), 1),
        'controls_kept': kept, 'controls_before': len(ctl),
        'rows': len(rows),
        'rows_dp': [[round(v / dp) for v in b] for b in rows],
        'row_h_dp': round(statistics.median(heights)) if heights else None,
        'row_gap_dp': round(statistics.median(gaps)) if gaps else None,
        'inset_l_dp': round(statistics.median([(b[0] - x1) / dp for b in rows])) if rows else None,
        'inset_r_dp': round(statistics.median([(x2 - b[2]) / dp for b in rows])) if rows else None,
        'first_dp': round((min(n['box'][1] for n in added) - y1) / dp),
    }
    return r


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__, file=sys.stderr)
        return 2
    src, out = argv[0], argv[1]
    mx_pkg = argv[2] if len(argv) == 3 else 'com.mxtech.videoplayer.ad'
    with open(os.path.join(src, 'display.txt'), encoding='utf-8') as f:
        pw, ph, dpi = (int(v) for v in f.read().split()[:3])
    dp = dpi / 160
    res = {}
    for app, pkg in (('mx', mx_pkg), ('inn', INN_PACKAGE)):
        for orient in ('port', 'land'):
            w, h = (pw, ph) if orient == 'port' else (ph, pw)
            for frame in ('black', 'white'):
                base = nodes(os.path.join(src, '%s_%s_%s_controls.xml' % (app, orient, frame)))
                for screen in SCREENS:
                    p = os.path.join(src, '%s_%s_%s_%s.xml' % (app, orient, frame, screen))
                    if not base or not os.path.exists(p):
                        continue
                    shot = None
                    if app == 'inn':
                        shot = os.path.join(src, 'inn_%s_white_%s.png' % (orient, screen))
                    m = measure(base, nodes(p), pkg, w, h, dp, shot)
                    if m:
                        res['%s %s %s %s' % (app, screen, orient, frame)] = m
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'measures.json'), 'w', encoding='utf-8') as f:
        json.dump({'screen_dp': [round(pw / dp), round(ph / dp)], 'measures': res}, f, indent=1, sort_keys=True)
    cols = ['anchor', 'w_pct', 'h_pct', 'rise_pct', 'picture_pct', 'controls_kept', 'controls_before',
            'rows', 'row_h_dp', 'row_gap_dp', 'inset_l_dp', 'inset_r_dp', 'first_dp']
    with open(os.path.join(out, 'measures.tsv'), 'w', encoding='utf-8') as f:
        f.write('app\tscreen\torient\tframe\t' + '\t'.join(cols) + '\n')
        for k in sorted(res):
            f.write('\t'.join(k.split(' ')) + '\t' + '\t'.join(str(res[k][c]) for c in cols) + '\n')
    print('measured %d panel screens of %d dp x %d dp' % (len(res), round(pw / dp), round(ph / dp)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
