#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Run every structural check over the project.

    python3 tool/check.py                     # whole project, default feature
    python3 tool/check.py lib/features/x      # scope the feature-local checks

WHY THIS LIVES IN THE REPO: it used to live outside it, get rebuilt from
scratch every session, and be impossible for anyone else to run. A quality gate
that only one person can invoke is not a gate.

WHAT THIS IS NOT: a compiler. These checks read the source as text. They catch
whole classes of error that a build takes minutes to find - unbalanced braces,
missing imports, name collisions, malformed signatures, typo'd design tokens,
undefined private helpers, architecture violations - but they know NOTHING
about types. A method returning the wrong type, a missing @override, an
argument of the wrong class: only the analyzer sees those.

SO THE ORDER THAT ACTUALLY WORKS IS:

    1. FlutLab -> Analyzer tab      (types, overrides, arity - seconds)
    2. python3 tool/check.py        (structure, architecture - seconds)
    3. FlutLab -> Build             (the truth - minutes)

Step 1 before step 3 is the one people skip, and it is the one that would have
saved the failed build: the Analyzer already understands every object in the
project and reports the same errors the compiler will, without the wait.
"""
import shutil
import subprocess
import sys
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(ROOT, 'tool')

# (script, argument, what it protects against)
CHECKS = [
    ('verify.py', ROOT,
     'invisible chars, brace balance, malformed signatures, duplicate '
     'declarations, string-table parity, design-token typos, undefined '
     'private helpers, version consistency'),
    ('compile_risk.py', ROOT,
     'a type or provider used without importing it'),
    ('contract_conformance.py', ROOT,
     'an implementation drifting from the interface it claims to implement'),
    ('collision.py', None,
     'a new top-level name that already exists elsewhere in the tree'),
    ('check_args.py', None,
     'a named argument that the constructor does not declare'),
    ('security_invariants.py', ROOT,
     'the paywall architecture quietly coming apart, and a credential written '
     'into a public repository'),
    ('context_scope.py', ROOT,
     '`context` used in a class that has none — broke a build on 27 Aug 2026'),
    ('ref_in_dispose.py', ROOT,
     '`ref` used inside dispose() — always throws and silently abandons the '
     'rest of the teardown; crashed the app on 30 Aug 2026'),
    ('dead_settings.py', ROOT,
     'a setting the app stores and never reads — the single most repeated '
     'bug class in this project, ten instances recorded in the tree\'s own '
     'comments before anyone counted'),
    ('console_css.py', None,
     'two unrelated rules sharing one class name in the operator console — '
     '`.bar` meant both the toolbar and an upload progress track, so the '
     'toolbar rendered three pixels tall and its contents were clipped'),
    ('unread_contract.py', None,
     'a repository method built, implemented twice and called by nothing — '
     'the same bug class as dead_settings one level up. getById was the only '
     'thing that loaded a title\'s album and had zero callers, so the grid '
     'was empty in every build ever shipped'),
]


def main() -> int:
    feature = sys.argv[1] if len(sys.argv) > 1 else None
    failed = []

    for script, arg, purpose in CHECKS:
        path = os.path.join(TOOL, script)
        if not os.path.exists(path):
            print('SKIP  %-26s (not present)' % script)
            continue
        cmd = [sys.executable, path]
        if arg is not None:
            cmd.append(arg)
        elif feature:
            cmd.append(feature)

        result = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
        summary = ''
        for line in result.stdout.splitlines():
            if line.startswith('==='):
                summary = line.strip()
        status = 'PASS' if result.returncode == 0 else 'FAIL'
        print('%-5s %-26s %s' % (status, script, summary))
        if result.returncode != 0:
            failed.append((script, result.stdout, purpose))

    # ── the one check that is not Python ──────────────────────────────────
    #
    # The console rewrites the box order of every MP4 an operator uploads, so
    # the moov atom is at the front and playback can start without a second
    # round trip to the tail of the file. That rewrite patches the chunk
    # offset table by hand, and an error in it produces a file of exactly the
    # right length that plays as noise — with the operator's original already
    # deleted. It is the only code in this repository that can destroy data
    # silently, so it is tested, and the test is JavaScript because the code
    # is.
    #
    # SKIPPED LOUDLY, NEVER QUIETLY. If node is missing the line says so in
    # the same column as a failure, because a check that disappears without
    # comment is worse than one that was never written: the summary still
    # reads "all passed".
    JS_TESTS = [
        ('faststart_test.mjs',
         'the MP4 rewrite',
         'an MP4 rewrite that corrupts the video it was meant to speed up'),
        ('probe_boxes_test.mjs',
         'the MP4 box walker',
         'a start-up check that tells the operator to re-upload a film that '
         'was already correct, or to stop looking at one that is not — '
         'neither of which throws'),
        ('stream_token_test.mjs',
         'the playback token',
         'the Supabase function and the Worker disagreeing about how a '
         'token is built — which fails at deploy time as a 404 on every '
         'video, for everyone, with a response that deliberately does not '
         'say why'),
        ('sigv4_test.mjs',
         'the R2 signatures and the multipart XML',
         'a request R2 refuses with a bare 403 that names no parameter, no '
         'header and no reason — or a CompleteMultipartUpload that finishes '
         'an upload with its parts out of order. Both land after the '
         'operator has already spent an hour of mobile data'),
    ]
    node = shutil.which('node')
    for name, what, guards in JS_TESTS:
        js_test = os.path.join(TOOL, 'js', name)
        if not os.path.exists(js_test):
            continue
        if not node:
            print('SKIP  %-26s %s' % (name,
                  '=== node not installed — %s is UNTESTED ===' % what))
            continue
        r = subprocess.run([node, js_test], capture_output=True,
                           text=True, cwd=ROOT)
        ok = r.returncode == 0
        print('%-5s %-26s %s' % ('PASS' if ok else 'FAIL', name,
              '=== %d check(s) on %s ===' % (r.stdout.count('ok   '), what)))
        if not ok:
            failed.append((name, r.stdout + r.stderr, guards))

    print()
    if not failed:
        print('All structural checks passed.')
        print('Now run the FlutLab Analyzer, then Build. This tool does not '
              'know about types.')
        return 0

    for script, out, purpose in failed:
        print('-' * 68)
        print('%s  --  guards against: %s' % (script, purpose))
        for line in out.splitlines():
            # 'FAIL ' is the JavaScript test's prefix; without it a failing
            # MP4 rewrite would print a FAIL header and then nothing that
            # says which assertion broke.
            if (line.startswith(' -') or line.startswith('[info]')
                    or line.startswith('FAIL ')):
                print(line)
    return 1


if __name__ == '__main__':
    sys.exit(main())
