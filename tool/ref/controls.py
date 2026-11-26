#!/usr/bin/env python3
"""Reference lab: MX's and Innocent's controls screen, measured in dp.

Reads a run kept in the private innocent-ref (runs/<date>_<run id>/, a local
clone): the trees of the controls screen (`<app>_<orient>_<frame>_controls
.xml`, MX's from dumpsys with its view ids, Innocent's from uiautomator with
its TalkBack labels in English) and the screen's density (display.txt).
Prints, per orientation, each control's centre and size in dp for both apps
and the difference — numbers only, nothing of MX's is copied out.

  controls.py RUN_DIR [FRAME]        FRAME: white (default) or black

Run with python3 -I (the trees are another company's app's output, data
only). Every element is found by MX's view id or Innocent's label, never by
place, so a missing one prints as "-" rather than borrowing a neighbour's.
"""
import os
import re
import sys

NODE = re.compile(r'<node ([^>]*)')
ATTR = re.compile(r'([\w-]+)="([^"]*)"')

# (name, MX's view id or None, Innocent's label pattern or None)
ELEMENTS = [
    ('back', ':first-toolbar', r'^Back$'),
    ('audio', 'audio', r'^Audio track'),
    ('cc', 'caption', r'^Subtitle'),
    ('decoder', 'decoder', r'^(Default|HW\+?|SW)$'),
    ('more', ':after-decoder', r'^More'),
    ('title', None, r'^innocent_lab_play$'),
    ('shortcut 1', ':shortcut-0', r'^Speed'),
    ('shortcut 2', ':shortcut-1', r'^Screenshot'),
    ('shortcut pitch', ':pitch', ':pitch'),
    ('disc', 'screen_shortcut_background', None),
    ('elapsed', 'posText', r'^\d\d:\d\d$'),
    ('seek bar', 'progressBar', r'^Playback position'),
    ('remaining', 'durationText', r'^-\d\d:\d\d$'),
    ('lock', 'lock', r'^Lock controls'),
    ('previous', 'prev', r'^Previous video'),
    ('play', 'playpause', r'^(Play|Pause)$'),
    ('next', 'next', r'^Next video'),
    ('screen mode', 'zb_left', r'^(Fit to screen|Stretch|Crop|100%|Custom)'),
    ('pip', 'zb_right', r'^Picture-in-picture'),
]


def nodes(path):
    out = []
    try:
        text = open(path, encoding='utf-8', errors='replace').read()
    except OSError:
        return out
    for m in NODE.finditer(text):
        a = dict(ATTR.findall(m.group(1)))
        b = [int(v) for v in re.findall(r'-?\d+', a.get('bounds', ''))]
        if len(b) != 4 or b[2] <= b[0] or b[3] <= b[1]:
            continue
        a['box'] = b
        a['id'] = a.get('resource-id', '').split('/')[-1]
        a['label'] = (a.get('content-desc') or a.get('text') or '').replace('&#10;', ' ')
        out.append(a)
    return out


def mx_find(ns, key):
    if key == ':first-toolbar':
        bar = next((n for n in ns if n['id'] == 'toolbar'), None)
        if not bar:
            return None
        inside = [n for n in ns if n.get('clickable') == 'true'
                  and n['box'][1] >= bar['box'][1] and n['box'][3] <= bar['box'][3]]
        return min(inside, key=lambda n: n['box'][0]) if inside else None
    if key == ':after-decoder':
        dec = next((n for n in ns if n['id'] == 'decoder'), None)
        if not dec:
            return None
        right = [n for n in ns if n.get('clickable') == 'true'
                 and n['box'][1] == dec['box'][1] and n['box'][0] >= dec['box'][2]]
        return min(right, key=lambda n: n['box'][0]) if right else None
    if key.startswith(':shortcut-'):
        lst = next((n for n in ns if n['id'] == 'screen_shortcut_list'), None)
        if not lst:
            return None
        slots = sorted((n for n in ns if n.get('clickable') == 'true'
                        and n['box'][1] == lst['box'][1] and n['box'][3] == lst['box'][3]),
                       key=lambda n: n['box'][0])
        i = int(key.split('-')[1])
        return slots[i] if i < len(slots) else None
    return next((n for n in ns if n['id'] == key), None)


def inn_find(ns, pat, lowest=False):
    r = re.compile(pat)
    found = [n for n in ns if r.search(n['label'])]
    if not found:
        return None
    # The elapsed time's shape is the clock's too (HH:MM in the top bar):
    # the one lowest on the screen is the seek bar's.
    return max(found, key=lambda n: n['box'][1]) if lowest else found[0]


def geom(n, d):
    if n is None:
        return None
    x0, y0, x1, y1 = n['box']
    return ((x0 + x1) / 2 / d, (y0 + y1) / 2 / d, (x1 - x0) / d, (y1 - y0) / d)


def fmt(g):
    return '%6.1f %6.1f %5.1fx%-5.1f' % g if g else '%-25s' % '  -'


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    run = argv[0]
    frame = argv[1] if len(argv) > 1 else 'white'
    try:
        w, h, dpi = open(os.path.join(run, 'display.txt')).read().split()[:3]
        d = int(dpi) / 160.0
    except (OSError, ValueError):
        d = 450 / 160.0
    for orient in ('land', 'port'):
        mx = nodes(os.path.join(run, 'mx_%s_%s_controls.xml' % (orient, frame)))
        inn = nodes(os.path.join(run, 'inn_%s_%s_controls.xml' % (orient, frame)))
        if not mx and not inn:
            continue
        print('%s, %s frame (dp at %.4f; centre x, centre y, w x h)' % (
            'sideways' if orient == 'land' else 'upright', frame, d))
        print('%-15s %-25s %-25s %s' % ('', 'MX', 'Innocent', 'Innocent - MX (x, y)'))
        for name, mk, ik in ELEMENTS:
            if mk == ':pitch':
                a, b = mx_find(mx, ':shortcut-0'), mx_find(mx, ':shortcut-1')
                c, e = inn_find(inn, r'^Speed'), inn_find(inn, r'^Screenshot')
                pm = (geom(b, d)[0] - geom(a, d)[0]) if a and b else None
                pi = (geom(e, d)[0] - geom(c, d)[0]) if c and e else None
                print('%-15s %-25s %-25s %s' % (
                    name, '%6.1f' % pm if pm else '  -', '%6.1f' % pi if pi else '  -',
                    '%+.1f' % (pi - pm) if pm and pi else ''))
                continue
            gm = geom(mx_find(mx, mk), d) if mk else None
            gi = geom(inn_find(inn, ik, lowest=name == 'elapsed'), d) if ik else None
            diff = '%+6.1f %+6.1f' % (gi[0] - gm[0], gi[1] - gm[1]) if gm and gi else ''
            print('%-15s %s %s %s' % (name, fmt(gm), fmt(gi), diff))
        print()
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
