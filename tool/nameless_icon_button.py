#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch an IconButton with no tooltip — a button nobody can name.

An icon-only button's name is its tooltip: TalkBack reads it, Voice Access
answers to it ("tap Back"), Switch Access and Android's Accessibility
Scanner list it, and so do UiAutomator, Maestro and Test Lab's Robo. One
without a tooltip is announced as "button" and nothing else. On 15 Oct 2026
there were 34 of them — every back arrow of the Movies screens, the
Private Folder's ⋮ menus, Transfer's Copy and Download — found by the
screens harness's accessibility pass (SCREEN_A11Y=1). (A tooltip reaches
Android as the button's name through InnocentBinding,
lib/core/ui/tooltip_label_binding.dart.)

THE RULE: every IconButton gets `tooltip:` — MaterialLocalizations for
the standard ones (backButtonTooltip, closeButtonTooltip, copyButtonLabel),
AppStrings for the rest. A button that is deliberately unnamed (hidden from
accessibility some other way) says so with
`// ignore: nameless_icon_button`.

Exit code 1 if any is found.
"""
import os
import re
import sys

OPEN = re.compile(r'(?<![A-Za-z0-9_.])IconButton(?:\.\w+)?\s*\(')
ALLOW = re.compile(r'//\s*ignore:\s*nameless_icon_button')


def _top_level(body):
    depth = 0
    out = []
    for ch in body:
        if ch in '([{':
            depth += 1
        elif ch in ')]}':
            depth -= 1
        elif depth == 0:
            out.append(ch)
    return ''.join(out)


def main(root):
    found = []
    for d, _, files in os.walk(os.path.join(root, 'lib')):
        for f in files:
            if not f.endswith('.dart'):
                continue
            p = os.path.join(d, f)
            s = open(p, encoding='utf-8').read()
            lines = s.split('\n')
            for m in OPEN.finditer(s):
                line_no = s[:m.start()].count('\n')
                line = lines[line_no]
                if line.lstrip().startswith('//') or '///' in line.split('IconButton')[0]:
                    continue
                prev = lines[line_no - 1] if line_no > 0 else ''
                if ALLOW.search(line) or ALLOW.search(prev):
                    continue
                i = m.end()
                depth = 1
                j = i
                while depth and j < len(s):
                    c = s[j]
                    if c in '([{':
                        depth += 1
                    elif c in ')]}':
                        depth -= 1
                    j += 1
                if re.search(r'(?<![A-Za-z0-9_])tooltip\s*:', _top_level(s[i:j - 1])):
                    continue
                found.append(f'{os.path.relpath(p, root)}:{line_no + 1}: {line.strip()}')
    for f in found:
        print(f'  {f}')
        print('    → give it a tooltip (its name for TalkBack, Voice Access and the labs)')
    print(f'=== {len(found)} issue(s) ===')
    return 1 if found else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
