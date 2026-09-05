#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Catch `ref` used inside dispose() — it always throws, and it is silent.

WHAT HAPPENED (30 Aug 2026, found from a device crash log, fixed in v1.61.0).

`_PlayerScreenState.dispose()` called `ref.read(floatingPipProvider)` on its
34th line. Riverpod's ConsumerStatefulElement marks itself disposed inside
`unmount()`, and `unmount()` is what calls `State.dispose()` — so that read
does not merely risk throwing, it throws EVERY TIME. Everything after it never
ran:

  * playback was never stopped and libmpv was never destroyed
  * WidgetsBinding.removeObserver(this) never ran, so the finished screen
    stayed subscribed to app lifecycle events and threw on each one
  * `super.dispose()` never ran, so `State.mounted` stayed TRUE forever — which
    is why the `if (!mounted) return` guard did not help
  * the wakelock stayed held and the orientation lock was never lifted

Then a second video was opened on top of a libmpv nobody owned, and the process
aborted in native code. One line, and it cost the whole teardown.

Nothing reported it. The exception was caught by Flutter's error handler and
printed to a console nobody can read on a phone.

THE RULE: dispose() must not touch `ref`. Snapshot what it needs in
`deactivate()`, which runs BEFORE unmount, and store it in a field.

Exit code 1 if any violation is found.
"""
import os
import re
import sys

METHOD = re.compile(r'^\s*(?:void|Future<void>)\s+dispose\s*\(\s*\)')
REF_USE = re.compile(r'\bref\s*\.\s*(read|watch|listen|listenManual|invalidate|refresh)\b')
# `ref` named as a parameter or a local of another kind is not what we mean.
ALLOW = re.compile(r'//\s*ignore:\s*ref_in_dispose')


def scan_file(path):
    try:
        lines = open(path, encoding='utf-8').read().split('\n')
    except (OSError, UnicodeDecodeError):
        return []
    issues = []
    for i, line in enumerate(lines):
        if not METHOD.match(line):
            continue
        depth = 0
        started = False
        for j in range(i, len(lines)):
            depth += lines[j].count('{') - lines[j].count('}')
            if lines[j].count('{'):
                started = True
            if started and depth <= 0:
                break
            if j == i:
                continue
            if REF_USE.search(lines[j]) and not ALLOW.search(lines[j]):
                issues.append((j + 1, lines[j].strip()))
    return issues


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    lib = os.path.join(root, 'lib')
    total = 0
    for d, dirs, files in os.walk(lib):
        dirs[:] = [x for x in dirs if x not in ('.dart_tool', 'build')]
        for f in sorted(files):
            if not f.endswith('.dart'):
                continue
            path = os.path.join(d, f)
            for line_no, text in scan_file(path):
                rel = os.path.relpath(path, root)
                print('%s:%d  ref used inside dispose()' % (rel, line_no))
                print('    %s' % text[:110])
                print('    -> snapshot it in deactivate() and read the field here')
                total += 1
    print('=== %d ref-in-dispose issue(s) ===' % total)
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main())
