#!/usr/bin/env python3
"""The Android libraries the APK carries, as a gradle.lockfile for OSV-Scanner.

deps-scan.yml scanned pubspec.lock alone, so the Java and Kotlin half of the
APK was never looked at: smbj, sshj, commons-net, jcifs-ng, Bouncy Castle,
Media3, CameraX, and every Flutter plugin's own Android libraries, none of
them in any Dart lock. This project keeps no Gradle lock either, so the list
is read out of what Gradle resolves:

    ./gradlew -q :app:dependencies --configuration releaseRuntimeClasspath

and written in the lockfile format OSV-Scanner reads,

    group:artifact:version=releaseRuntimeClasspath

THE RESOLVED VERSION, which is the one in the APK: `a:b:1.0 -> 1.2` is 1.2.
Projects (`project :camera`) are this build's own code. A constraint (c) or a
line Gradle did not resolve (n) is not on the classpath. A FAILED line means
the list is not the APK's, so the run fails rather than scan half of it.

    python3 tool/gradle_lock.py deps.txt > scan/gradle.lockfile
"""

import re
import sys

CONFIG = 'releaseRuntimeClasspath'

# `+--- g:a:1.0`, `\--- g:a:1.0 -> 1.2 (*)`, `g:a:{strictly 1.0} -> 1.0`,
# `g:a -> 1.2` (the version came from a platform or a constraint).
_LINE = re.compile(
    r'^[\s|+\\-]*'
    r'(?P<group>[A-Za-z0-9_.\-]+):(?P<artifact>[A-Za-z0-9_.\-]+)'
    r'(?::(?P<declared>\{[^}]*\}|[^\s]+))?'
    r'(?:\s+->\s+(?P<resolved>[^\s]+))?'
    r'(?P<rest>.*)$')


def parse(text):
    """(sorted [(group, artifact, version)], [unresolved lines])."""
    found = set()
    failed = []
    for raw in text.splitlines():
        line = raw.rstrip()
        if not re.match(r'^[\s|]*[+\\]---', line):
            continue
        body = re.sub(r'^[\s|]*[+\\]---\s*', '', line)
        if body.startswith('project '):
            continue
        m = _LINE.match(body)
        if not m:
            continue
        rest = m.group('rest')
        if '(c)' in rest or '(n)' in rest:
            continue
        if 'FAILED' in rest or (m.group('declared') or '').endswith('FAILED'):
            failed.append(line.strip())
            continue
        version = m.group('resolved') or m.group('declared')
        if not version or version.startswith('{'):
            failed.append(line.strip())
            continue
        found.add((m.group('group'), m.group('artifact'), version))
    return sorted(found), failed


def lockfile(deps):
    out = ['# Written by tool/gradle_lock.py from Gradle\'s resolved '
           + CONFIG + ' (deps-scan.yml).']
    out += [f'{g}:{a}:{v}={CONFIG}' for g, a, v in deps]
    out.append('empty=')
    return '\n'.join(out) + '\n'


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    with open(argv[1], encoding='utf-8') as f:
        deps, failed = parse(f.read())
    if failed:
        print('Gradle could not resolve:', file=sys.stderr)
        for line in failed:
            print('  ' + line, file=sys.stderr)
        return 1
    if not deps:
        print('no libraries in the dependency report', file=sys.stderr)
        return 1
    sys.stdout.write(lockfile(deps))
    print(f'{len(deps)} Android libraries', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
