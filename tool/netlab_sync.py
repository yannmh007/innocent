#!/usr/bin/env python3
"""tool/netlab builds the app's network libraries at the app's versions.

WHY. tool/netlab compiles the Local Network core on a desktop JVM and tests
it against real Samba, vsftpd and OpenSSH, and since 30 Oct the ADB identity
too — "exactly the app's set, so what passes here is what ships". Nothing
held it to that: on 30 Oct the app moved to BouncyCastle 1.86 and netlab
still tested 1.81, so its green said nothing about the APK. This compares
every library the two build files share, the app's constraints included,
and fails on any difference.

RUN:  python3 tool/netlab_sync.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, 'android', 'app', 'build.gradle.kts')
LAB = os.path.join(ROOT, 'tool', 'netlab', 'build.gradle.kts')

_DEP = re.compile(r'(?:implementation|api)\("([\w.\-]+):([\w.\-]+):([\w.\-]+)"\)')


def coords(path):
    """{group:artifact: version} for every implementation(...) line, comments
    skipped. A constraint is an implementation(...) line inside constraints."""
    out = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            code = line.split('//', 1)[0]
            for g, a, v in _DEP.findall(code):
                out[f'{g}:{a}'] = v
    return out


def mismatches(app, lab):
    return sorted((k, app[k], lab[k]) for k in lab if k in app and app[k] != lab[k])


def main():
    app, lab = coords(APP), coords(LAB)
    shared = [k for k in lab if k in app]
    bad = mismatches(app, lab)
    for k, a, b in bad:
        print(f'FAIL {k}: the app ships {a}, tool/netlab tests {b}')
    if not shared:
        print('FAIL no library in common: the build files moved or this script is stale')
        return 1
    if bad:
        return 1
    print(f'=== {len(shared)} library(ies) at the app\'s version in tool/netlab ===')
    return 0


if __name__ == '__main__':
    sys.exit(main())
