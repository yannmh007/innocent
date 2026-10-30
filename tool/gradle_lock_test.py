#!/usr/bin/env python3
"""tool/gradle_lock.py: Gradle's dependency report read as the APK's libraries.

WHY. OSV-Scanner only finds an advisory against a library it is told about.
A version read as the declared one when Gradle resolved another scans a
library the APK does not carry; a plugin's libraries skipped because they sit
under `project :plugin` leave half the APK unscanned; and a report that
failed to resolve, read as if it were whole, is a green run over nothing.

RUN:  python3 tool/gradle_lock_test.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tool'))
import gradle_lock as gl  # noqa: E402

fails = 0
checks = 0


def check(label, ok):
    global fails, checks
    checks += 1
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        fails += 1


REPORT = r"""
------------------------------------------------------------
Project ':app'
------------------------------------------------------------

releaseRuntimeClasspath - Runtime classpath of /release.
+--- com.hierynomus:smbj:0.11.5
|    +--- org.bouncycastle:bcprov-jdk18on:1.78.1 -> 1.81
|    \--- org.slf4j:slf4j-api:1.7.36 -> 2.0.16
+--- org.bouncycastle:bcpkix-jdk15to18:1.81
+--- project :flutter_secure_storage
|    \--- androidx.security:security-crypto:1.1.0-alpha06
+--- androidx.media3:media3-exoplayer:1.9.2
|    +--- androidx.media3:media3-common:1.9.2 (*)
|    \--- androidx.annotation:annotation:{strictly 1.9.1} -> 1.9.1
+--- androidx.media3:media3-common:1.9.2
+--- org.jetbrains.kotlin:kotlin-stdlib -> 2.1.0
+--- androidx.core:core:1.13.1 (c)
\--- androidx.lifecycle:lifecycle-runtime:2.8.7 (n)

(c) - A dependency constraint, not a dependency.
"""

deps, failed = gl.parse(REPORT)
have = {(g, a): v for g, a, v in deps}

check('nothing failed in a whole report', failed == [])
check('a direct library is read', have.get(('com.hierynomus', 'smbj')) == '0.11.5')
check('the resolved version, not the declared one (1.78.1 -> 1.81)',
      have.get(('org.bouncycastle', 'bcprov-jdk18on')) == '1.81')
check('a transitive library is read',
      have.get(('org.slf4j', 'slf4j-api')) == '2.0.16')
check('a plugin\'s own libraries are read, the plugin itself is not',
      have.get(('androidx.security', 'security-crypto')) == '1.1.0-alpha06'
      and not any(a == 'flutter_secure_storage' for _, a, _ in deps))
check('a strict version reads as what it resolved to',
      have.get(('androidx.annotation', 'annotation')) == '1.9.1')
check('a version from a platform (no declared one) is read',
      have.get(('org.jetbrains.kotlin', 'kotlin-stdlib')) == '2.1.0')
check('a library seen twice is listed once',
      sum(1 for g, a, _ in deps if a == 'media3-common') == 1)
check('a constraint (c) is not a library',
      ('androidx.core', 'core') not in have)
check('an unresolved line (n) is not a library',
      ('androidx.lifecycle', 'lifecycle-runtime') not in have)
check('the legend under the tree is not read as a library',
      not any(g.startswith('(') for g, _, _ in deps))

lock = gl.lockfile(deps)
lines = lock.splitlines()
check('every library line is group:artifact:version=configuration',
      all(l.endswith('=' + gl.CONFIG) and l.count(':') == 2
          for l in lines[1:-1]))
check('the lockfile ends with the empty= line Gradle writes',
      lines[-1] == 'empty=')
check('the lockfile is sorted', lines[1:-1] == sorted(lines[1:-1]))

broken, why = gl.parse(REPORT + '+--- com.example:gone:1.0 FAILED\n'
                       + '+--- com.example:also:{strictly 2.0} FAILED\n')
check('a FAILED line is reported, not dropped', len(why) == 2)

import tempfile  # noqa: E402
with tempfile.TemporaryDirectory() as d:
    p = os.path.join(d, 'deps.txt')
    with open(p, 'w') as f:
        f.write(REPORT + '\\--- com.example:gone:1.0 FAILED\n')
    import contextlib  # noqa: E402
    import io  # noqa: E402
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        rc = gl.main(['gradle_lock.py', p])
    check('the CLI fails on a report that did not resolve', rc == 1
          and 'com.example:gone' in err.getvalue())
    with open(p, 'w') as f:
        f.write('BUILD SUCCESSFUL\n')
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        rc = gl.main(['gradle_lock.py', p])
    check('the CLI fails on a report with no libraries in it', rc == 1)

print(f'\n{checks - fails} of {checks} checks passed')
sys.exit(1 if fails else 0)
