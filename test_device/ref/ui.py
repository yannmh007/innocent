#!/usr/bin/env python3
"""Reference lab helpers that read what an app left on the emulator.

Run with `python3 -I` from the checkout: every file it reads (an XAPK's
manifest.json, a uiautomator dump) came from another company's app and is
data, never code. It prints only numbers and coordinates, so a public run's
log carries nothing of that app's (its words stay in innocent-ref).

  ui.py splits MANIFEST DPI ABILIST   the XAPK's APKs to install, one a line:
                                      base, the ABI split the device runs
                                      (its first in ABILIST), the density
                                      split nearest DPI, English, and any
                                      feature split
  ui.py firstrun DUMP SKIP            "x y" of a first-run button to tap
                                      (Allow, Agree, OK, ...), the SKIP-th in
                                      order; nothing when there is none
  ui.py count DUMP PACKAGE            "nodes clickable seekbars" of PACKAGE
  ui.py hier TOP WINDOWS PACKAGE      a uiautomator-like dump from Android's
                                      own `dumpsys activity top` (the view
                                      tree) and `dumpsys window windows`
                                      (PACKAGE's popup and dialog frames):
                                      uiautomator never finds MX's player
                                      idle (run 44990303466)
  ui.py added BASE PANEL PACKAGE      how many nodes the panel's tree adds
  ui.py tiles BASE PANEL PACKAGE      "x y" of the panel's own buttons, top
                                      row first, left to right
  ui.py topbar DUMP PACKAGE W H DPI   "x y" of the top bar's last four
                                      buttons, rightmost first: ⋮, HW, CC, ♪
"""
import json
import re
import sys
import xml.etree.ElementTree as ET

DENSITIES = {'ldpi': 120, 'mdpi': 160, 'tvdpi': 213, 'hdpi': 240,
             'xhdpi': 320, 'xxhdpi': 480, 'xxxhdpi': 640}


def splits(manifest, dpi, abilist):
    with open(manifest, encoding='utf-8') as f:
        m = json.load(f)
    entries = [(str(s.get('id', '')), str(s.get('file', ''))) for s in m.get('split_apks') or []]
    safe = re.compile(r'^[A-Za-z0-9._-]+\.apk$')
    entries = [(i, f) for i, f in entries if safe.match(f)]
    out = [f for i, f in entries if i == 'base']
    abis = [a.strip().replace('-', '_') for a in abilist.split(',') if a.strip()]
    abi_splits = {i[len('config.'):]: f for i, f in entries if i[len('config.'):] in
                  ('arm64_v8a', 'armeabi_v7a', 'x86_64', 'x86')}
    for a in abis:
        if a in abi_splits:
            out.append(abi_splits[a])
            break
    dens = sorted(((DENSITIES[i[len('config.'):]], f) for i, f in entries
                   if i[len('config.'):] in DENSITIES))
    if dens:
        above = [f for d, f in dens if d >= dpi]
        out.append(above[0] if above else dens[-1][1])
    out += [f for i, f in entries if i == 'config.en']
    # A feature split (an id that is not a config.*) is part of the app.
    out += [f for i, f in entries if i != 'base' and not i.startswith('config.')]
    print('\n'.join(out))


def nodes(dump):
    try:
        return list(ET.parse(dump).getroot().iter('node'))
    except (ET.ParseError, OSError):
        return []


def centre(n):
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', n.get('bounds', ''))
    if not m:
        return None
    x1, y1, x2, y2 = map(int, m.groups())
    if x2 <= x1 or y2 <= y1:
        return None
    return (x1 + x2) // 2, (y1 + y2) // 2


# In order: the system's permission dialog, then a consent or notice, then a
# language list's English (its Done comes next round). Nothing that signs in,
# buys or installs is on the list.
FIRST_RUN = [
    ('allow', 'while using the app'),
    ('agree', 'i agree', 'agree and continue', 'accept', 'accept all',
     'accept and continue', 'continue', 'got it', 'ok', 'okay', 'start',
     'next', 'done', 'confirm', 'yes', 'skip', 'close', 'not now', 'later',
     'maybe later', 'no thanks', 'dismiss', 'just once'),
    ('english',),
]


def norm(s):
    return re.sub(r'[^a-z ]', '', (s or '').lower().replace('&', 'and')).strip()


def firstrun(dump, skip):
    found = []
    all_nodes = nodes(dump)
    for rank, words in enumerate(FIRST_RUN):
        for n in all_nodes:
            if n.get('enabled') == 'false':
                continue
            label = norm(n.get('text')) or norm(n.get('content-desc'))
            if not label and n.get('clickable') == 'true':
                kids = [norm(k.get('text')) for k in n.iter('node') if norm(k.get('text'))]
                label = kids[0] if len(kids) == 1 else ''
            if label in words:
                c = centre(n)
                if c:
                    found.append((rank, words.index(label), c))
    found.sort()
    seen, order = set(), []
    for f in found:
        if f[2] not in seen:
            seen.add(f[2])
            order.append(f[2])
    if skip < len(order):
        print('%d %d' % order[skip])


def count(dump, package):
    mine = [n for n in nodes(dump) if n.get('package') == package]
    clickable = sum(1 for n in mine if n.get('clickable') == 'true')
    seek = sum(1 for n in mine if 'SeekBar' in (n.get('class') or ''))
    print('%d %d %d' % (len(mine), clickable, seek))


VIEW = re.compile(r'^(\s*)([\w.$]+)\{[0-9a-f]+ (\S{9}) (\S{8}) (-?\d+),(-?\d+)-(-?\d+),(-?\d+)'
                  r'(?: #[0-9a-f]+)?(?: (\S+))?\}')


def hier(top, windows, package):
    """The top activity's views with absolute bounds, plus PACKAGE's other
    windows as one node each. Scroll offsets and translations are not in
    the dump: a scrolled list's rows read where they were laid out."""
    out = ['<?xml version="1.0" encoding="UTF-8"?>', '<hierarchy rotation="0">']
    with open(top, encoding='utf-8', errors='replace') as f:
        lines = f.read().splitlines()
    # `dumpsys activity top` lists every task's top activity, the launcher's
    # first (run 44991688519): the hierarchy is the one under PACKAGE's.
    start = None
    act = next((i for i, l in enumerate(lines)
                if l.strip().startswith('ACTIVITY %s/' % package)), None)
    if act is not None:
        start = next((i for i in range(act, len(lines)) if lines[i].strip() == 'View Hierarchy:'), None)
    if start is not None:
        base = None
        stack = []   # (indent, abs_x, abs_y, visible)
        for l in lines[start + 1:]:
            ind = len(l) - len(l.lstrip(' '))
            if base is None:
                base = ind      # the DecorView line
                stack = [(ind, 0, 0, True)]
                continue
            if ind <= base:
                break
            m = VIEW.match(l)
            if not m:
                continue
            while stack and stack[-1][0] >= ind:
                stack.pop()
            px, py, pvis = (stack[-1][1], stack[-1][2], stack[-1][3]) if stack else (0, 0, True)
            cls, f1 = m.group(2), m.group(3)
            x1, y1, x2, y2 = (int(m.group(i)) for i in range(5, 9))
            ax, ay = px + x1, py + y1
            vis = pvis and f1[0] == 'V'
            stack.append((ind, ax, ay, vis))
            if not vis or x2 <= x1 or y2 <= y1:
                continue
            rid = m.group(9) or ''
            out.append('<node class="%s" package="%s" resource-id="%s" clickable="%s" '
                       'scrollable="false" enabled="%s" bounds="[%d,%d][%d,%d]"/>' % (
                           cls, package, rid.replace('"', ''), 'true' if f1[6] == 'C' else 'false',
                           'true' if f1[2] == 'E' else 'false', ax, ay, ax + x2 - x1, ay + y2 - y1))
    # Popups and dialogs of PACKAGE: their frames.
    try:
        with open(windows, encoding='utf-8', errors='replace') as f:
            text = f.read()
    except OSError:
        text = ''
    for block in re.split(r'\n\s*Window #\d+ ', text)[1:]:
        if ('package=%s ' % package) not in block or 'ty=BASE_APPLICATION' in block:
            continue
        if 'mHasSurface=true' not in block:
            continue
        ty = re.search(r'ty=(\w+)', block)
        fr = re.search(r'(?:mFrame|frame)=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', block)
        if fr:
            out.append('<node class="window.%s" package="%s" resource-id="" clickable="false" '
                       'scrollable="false" enabled="true" bounds="[%s,%s][%s,%s]"/>' % (
                           ty.group(1) if ty else 'other', package, *fr.groups()))
    out.append('</hierarchy>')
    print('\n'.join(out))


def topbar(dump, package, w, h, dpi):
    dp = dpi / 160
    ns = [n for n in nodes(dump) if n.get('package') == package]

    def box(n):
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', n.get('bounds', ''))
        return tuple(map(int, m.groups())) if m else None

    # An AndroidX toolbar's menu: its buttons are what sits inside it. (A
    # row of shortcuts below a toolbar is drawn moved down by a translation
    # the view dump does not show, so by place alone it read as the top
    # row: run 44994060537.)
    menus = [box(n) for n in ns if (n.get('class') or '').endswith('ActionMenuView') and box(n)]
    if menus:
        mb = menus[0]
        inmenu = []
        for n in ns:
            c, b = centre(n), box(n)
            # The menu's own buttons fill its height.
            if n.get('clickable') == 'true' and c and b and b != mb \
                    and mb[0] <= c[0] <= mb[2] and mb[1] <= c[1] <= mb[3] \
                    and b[3] - b[1] >= 0.8 * (mb[3] - mb[1]):
                inmenu.append(b)
        # A button, not something clickable inside a button.
        outer = [b for b in inmenu if not any(o != b and o[0] <= b[0] and o[1] <= b[1]
                                              and o[2] >= b[2] and o[3] >= b[3] for o in inmenu)]
        row = sorted({((b[0] + b[2]) // 2, (b[1] + b[3]) // 2) for b in outer}, key=lambda c: -c[0])
        if len(row) >= 2:
            for c in row[:4]:
                print('%d %d' % c)
            return
    cands = []
    for n in ns:
        if n.get('clickable') != 'true':
            continue
        c, b = centre(n), box(n)
        if not c or not b or c[1] > 0.25 * h or c[0] < 0.45 * w:
            continue
        # A button, not a bar: under 140 dp each way.
        if b[2] - b[0] > 140 * dp or b[3] - b[1] > 140 * dp:
            continue
        cands.append(c)
    if not cands:
        return
    # The top bar is the topmost row of buttons on the right.
    y0 = min(c[1] for c in cands)
    row = sorted({c for c in cands if c[1] - y0 <= 24 * dp}, key=lambda c: -c[0])
    for c in row[:4]:
        print('%d %d' % c)


def added(base, panel, package):
    """How many nodes of PACKAGE the panel's tree has that the controls'
    had not (a whole-screen scrim left out): a panel opened, or not."""
    print(len(_added(base, panel, package)))


def _added(base, panel, package):
    def key(n):
        return (n.get('class'), n.get('resource-id'), n.get('bounds'))
    before = {key(n) for n in nodes(base)}
    out = []
    for n in nodes(panel):
        if n.get('package') != package or key(n) in before:
            continue
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', n.get('bounds', ''))
        if not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        if x2 <= x1 or y2 <= y1 or (x1 <= 0 and y1 <= 0 and x2 >= 1000 and y2 >= 1000):
            continue
        out.append(n)
    return out


def tiles(base, panel, package):
    """The panel's own buttons, top row first, left to right: "x y" each."""
    cs = sorted({centre(n) for n in _added(base, panel, package)
                 if n.get('clickable') == 'true' and centre(n)}, key=lambda c: (c[1] // 40, c[0]))
    for c in cs:
        print('%d %d' % c)


def labelled(dump, pattern):
    """The centre of the first node whose TalkBack label (content-desc, or
    its text) matches PATTERN, case aside: "x y". Innocent's ⋮ tiles read
    clickable="false" in uiautomator (run 45885319037), so tiles() and
    grid() never see them; their English labels find them."""
    r = re.compile(pattern, re.I)
    for n in nodes(dump):
        label = (n.get('content-desc') or n.get('text') or '').replace('\n', ' ')
        c = centre(n)
        if c and r.search(label):
            print('%d %d' % c)
            return


def grid(base, panel, package, dpi):
    """The panel's tiles alone, top row first, left to right: "x y" each.
    A tile is a clickable new node about as tall as it is wide and under
    140 dp: not a switch's row, which runs the panel's width (tapping the
    last of tiles() could turn the Shortcuts switch off)."""
    dp = dpi / 160
    found = {}
    for n in _added(base, panel, package):
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', n.get('bounds', ''))
        if n.get('clickable') != 'true' or not m:
            continue
        x1, y1, x2, y2 = map(int, m.groups())
        w, h = x2 - x1, y2 - y1
        if w < 140 * dp and h < 140 * dp and 0.5 < w / max(h, 1) < 2:
            found[((x1 + x2) // 2, (y1 + y2) // 2)] = (w // 8, h // 8)
    # The tiles are all one size; a switch's own knob, also square, is not.
    sizes = list(found.values())
    common = max(set(sizes), key=sizes.count) if sizes else None
    for c in sorted((c for c, sz in found.items() if sz == common), key=lambda c: (c[1] // 40, c[0])):
        print('%d %d' % c)


def shortcuts(dump, package, dpi):
    """The shortcut row's slots, left to right: "x y kind label" each, kind
    "chevron" for the expand/collapse one, else "item". MX's row is its
    screen_shortcut_list: the slots are the clickable nodes that fill its
    height, the chevron the one whose disc is small (under 32 dp). Innocent's
    chevron is labelled Expand or Collapse, its slots the clickable nodes on
    the chevron's line with their TalkBack labels."""
    dp = dpi / 160
    ns = [n for n in nodes(dump) if n.get('package') == package]

    def box(n):
        m = re.match(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', n.get('bounds', ''))
        return tuple(map(int, m.groups())) if m else None

    def label(n):
        t = (n.get('content-desc') or n.get('text') or '').replace('\n', ' ')
        return re.sub(r'[^A-Za-z0-9]+', '_', t).strip('_')[:28] or '-'

    out = []
    lst = next((box(n) for n in ns if (n.get('resource-id') or '').endswith('screen_shortcut_list')), None)
    if lst:
        discs = [box(n) for n in ns if (n.get('resource-id') or '').endswith('screen_shortcut_background')]
        for n in ns:
            b = box(n)
            if n.get('clickable') != 'true' or not b or b == lst:
                continue
            if abs(b[1] - lst[1]) > 3 or abs(b[3] - lst[3]) > 3 or b[2] - b[0] > 140 * dp:
                continue
            small = any(d and b[0] <= d[0] and d[2] <= b[2] and d[2] - d[0] < 32 * dp for d in discs)
            out.append((b, 'chevron' if small else 'item', '-'))
    else:
        chev = next((n for n in ns if re.match(r'^(Expand|Collapse)$', n.get('content-desc') or '')), None)
        # Expanded, the chevron can lie past the end of the row (and of the
        # accessibility root on API 30): the row is then found by one of
        # its shortcuts' names.
        anchor = chev if chev is not None and box(chev) and box(chev)[2] > box(chev)[0] else next(
            (n for n in ns if re.search(r'(Speed|Screenshot|Background Play|Night Mode|Shuffle|Mute)',
                                        n.get('content-desc') or '') and n.get('clickable') == 'true'
             and box(n) and box(n)[2] > box(n)[0]), None)
        if anchor is None:
            return
        cb = box(anchor)
        for n in ns:
            b = box(n)
            if n.get('clickable') != 'true' or not b or abs(b[1] - cb[1]) > 3 * dp:
                continue
            if b[2] - b[0] > 140 * dp or b[3] - b[1] > 1.5 * (cb[3] - cb[1]) + 2:
                continue
            if b[2] <= b[0]:
                continue
            out.append((b, 'chevron' if n is chev else 'item', label(n)))
    for b, kind, lab in sorted(out, key=lambda t: t[0][0]):
        print('%d %d %s %s' % ((b[0] + b[2]) // 2, (b[1] + b[3]) // 2, kind, lab))


def main(argv):
    if len(argv) == 4 and argv[0] == 'splits':
        splits(argv[1], int(argv[2]), argv[3])
    elif len(argv) == 3 and argv[0] == 'firstrun':
        firstrun(argv[1], int(argv[2]))
    elif len(argv) == 3 and argv[0] == 'count':
        count(argv[1], argv[2])
    elif len(argv) == 4 and argv[0] == 'hier':
        hier(argv[1], argv[2], argv[3])
    elif len(argv) == 4 and argv[0] == 'added':
        added(argv[1], argv[2], argv[3])
    elif len(argv) == 4 and argv[0] == 'tiles':
        tiles(argv[1], argv[2], argv[3])
    elif len(argv) == 3 and argv[0] == 'labelled':
        labelled(argv[1], argv[2])
    elif len(argv) == 5 and argv[0] == 'grid':
        grid(argv[1], argv[2], argv[3], int(argv[4]))
    elif len(argv) == 4 and argv[0] == 'shortcuts':
        shortcuts(argv[1], argv[2], int(argv[3]))
    elif len(argv) == 6 and argv[0] == 'topbar':
        topbar(argv[1], argv[2], int(argv[3]), int(argv[4]), int(argv[5]))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
