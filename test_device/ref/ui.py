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


def main(argv):
    if len(argv) == 4 and argv[0] == 'splits':
        splits(argv[1], int(argv[2]), argv[3])
    elif len(argv) == 3 and argv[0] == 'firstrun':
        firstrun(argv[1], int(argv[2]))
    elif len(argv) == 3 and argv[0] == 'count':
        count(argv[1], argv[2])
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
