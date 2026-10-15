#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch a raw showModalBottomSheet — its last row sits under the nav bar.

WHAT HAPPENED (Oct 2026, a real phone with three-button navigation).

The app draws edge to edge, so the window runs behind Android's
Back · Home · Recents bar. Flutter's modal bottom sheet wraps its content in
`SafeArea(bottom: false)` — even with `useSafeArea: true` — so a sheet's
last row (Cancel, Save, the last choice of a list) ended under the bar,
half covered. Of 49 sheets, 22 had no workaround of their own.

THE RULE: use showAppModalBottomSheet (lib/core/ui/app_sheet.dart), which
pads the content by the bar's height and leaves the sheet's colour running
to the screen edge. A place that must have the raw function says so with
`// ignore: avoid_raw_bottom_sheet`.

Exit code 1 if any is found.
"""
import os
import re
import sys

RAW = re.compile(r'(?<![A-Za-z0-9_])showModalBottomSheet\s*(<|\()')
ALLOW = re.compile(r'//\s*ignore:\s*avoid_raw_bottom_sheet')


def main(root):
    found = []
    for d, _, files in os.walk(os.path.join(root, 'lib')):
        for f in files:
            if not f.endswith('.dart'):
                continue
            p = os.path.join(d, f)
            lines = open(p, encoding='utf-8').read().split('\n')
            for i, line in enumerate(lines):
                code = line.split('//', 1)[0]
                if not RAW.search(code):
                    continue
                prev = lines[i - 1] if i > 0 else ''
                if ALLOW.search(line) or ALLOW.search(prev):
                    continue
                found.append(f'{os.path.relpath(p, root)}:{i + 1}: {line.strip()}')
    for f in found:
        print(f'  {f}')
        print('    → showAppModalBottomSheet (lib/core/ui/app_sheet.dart)')
    print(f'=== {len(found)} issue(s) ===')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
