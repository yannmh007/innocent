#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch a stock PopupMenuButton — it crashes when its button goes away.

WHAT HAPPENED (11 Oct 2026, found from a real phone's report, symbolized
against the release's own symbols).

"Something didn't load — this screen hit a snag" on the Me tab, and Reload
did nothing. The stack:

    State.context                          framework.dart:959
    PopupMenuButtonState._positionBuilder  popup_menu.dart:1573
    _PopupMenuRoute.buildPage              popup_menu.dart:1025

Flutter 3.32's PopupMenuButton gives its menu a callback into the button's
own State, called on every layout of the menu. When the button is removed
while the menu is open, the next layout asks a disposed State for its
context — a null-check failure in release — and the menu's page becomes
Flutter's error card, on top of whatever screen is showing. A ⋮ menu opened
on the Video tab, then Me tapped in the bottom bar, was enough.

THE RULE: use SafePopupMenuButton (lib/core/ui/safe_popup_menu.dart), which
gives the menu a position worked out once and nothing that points back at
the button. A test that needs the stock widget says so with
`// ignore: avoid_stock_popup_menu`.

Exit code 1 if any is found.
"""
import os
import re
import sys

STOCK = re.compile(r'(?<![A-Za-z0-9_])PopupMenuButton\s*(<|\()')
ALLOW = re.compile(r'//\s*ignore:\s*avoid_stock_popup_menu')


def main(root):
    found = []
    for base in ('lib',):
        for d, _, files in os.walk(os.path.join(root, base)):
            for f in files:
                if not f.endswith('.dart'):
                    continue
                p = os.path.join(d, f)
                lines = open(p, encoding='utf-8').read().split('\n')
                for i, line in enumerate(lines):
                    code = line.split('//', 1)[0]
                    if not STOCK.search(code):
                        continue
                    prev = lines[i - 1] if i > 0 else ''
                    if ALLOW.search(line) or ALLOW.search(prev):
                        continue
                    found.append(f'{os.path.relpath(p, root)}:{i + 1}: {line.strip()}')
    for f in found:
        print(f'  {f}')
        print('    → SafePopupMenuButton (lib/core/ui/safe_popup_menu.dart)')
    print(f'=== {len(found)} issue(s) ===')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
