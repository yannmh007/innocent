#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch English written straight into a screen.

The app speaks Burmese, Thai and English. A label typed into a widget as a
literal — Text('Close'), tooltip: 'More' — is English on every phone, and
1.64.65 found some four hundred of them across Settings, the player, Music
and Help. They were moved into AppStrings; this check keeps new ones out.

THE RULE. In lib/**/presentation/ and lib/core/ui/, a widget's visible or
spoken text (Text(, tooltip:, label:, title:, subtitle:, hintText:,
labelText:, semanticLabel:, message:) must not be a literal starting with a
capital letter and a word. Use AppStrings.

RATCHET. A few literals are left on purpose (Diagnostics is raw Android
records in English; the ADB screen's auto-reconnect section; brand names).
They are counted per file in ALLOWED and may only shrink: a file with more
than its allowance fails, and so does one with fewer until the allowance is
lowered to match.

Exit code 1 on a new literal.
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
PATTERN = re.compile(
    r"""(?:\bText\(\s*|\b(?:tooltip|label|title|subtitle|hintText|labelText|semanticLabel|message|semantics):\s*)"""
    r"""(?:const\s+)?'([A-Z][a-z][^'\n]*)'""")

# Names every language writes the same way.
BRANDS = {'Wi-Fi', 'Innocent', 'Google Drive', 'OneDrive', 'Dropbox'}

# file (relative to lib/) -> literals allowed to stay. May only shrink.
ALLOWED = {
    'features/settings/presentation/settings_diagnostics_screen.dart': 4,
    'features/settings/presentation/adb_connect_screen.dart': 6,
}


def scan(path):
    hits = []
    for i, line in enumerate(open(path, encoding='utf-8'), 1):
        t = line.strip()
        if t.startswith('//') or t.startswith('///'):
            continue
        for m in PATTERN.finditer(line):
            if m.group(1) not in BRANDS:
                hits.append((i, m.group(1)))
    return hits


def main():
    lib = os.path.join(ROOT, 'lib')
    problems = []
    for d, _, files in os.walk(lib):
        rel_d = os.path.relpath(d, lib)
        if not (('presentation' in rel_d.split(os.sep)) or rel_d.startswith(os.path.join('core', 'ui'))):
            continue
        for f in sorted(files):
            if not f.endswith('.dart'):
                continue
            rel = os.path.join(rel_d, f).replace(os.sep, '/')
            hits = scan(os.path.join(d, f))
            allowed = ALLOWED.get(rel, 0)
            if len(hits) > allowed:
                for i, v in hits:
                    problems.append('%s:%d: %r — put it in AppStrings' % (rel, i, v))
            elif len(hits) < allowed:
                problems.append('%s: %d literal(s) left, allowance %d — lower '
                                'it in ALLOWED' % (rel, len(hits), allowed))
    for p in problems:
        print(' - ' + p)
    print('=== %d hard-coded UI literal issue(s) ===' % len(problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
