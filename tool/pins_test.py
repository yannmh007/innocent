#!/usr/bin/env python3
"""tool/pins.py: the pins read out of the workflows, checked, and renewed.

WHY. A pin that is read wrong checks nothing: a regex that misses the digest
reports "not pinned" forever, or one that reads the wrong job's digest
passes a file nobody runs. And the two places that run ffmpeg must run the
same build, or the lab proves a different binary from the one that makes
the films.

RUN:  python3 tool/pins_test.py
"""

import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'tool'))
import pins  # noqa: E402

fails = 0
checks = 0


def check(label, ok):
    global fails, checks
    checks += 1
    print(('ok   ' if ok else 'FAIL ') + label)
    if not ok:
        fails += 1


OSV = 'c799274b682e0437c802d4714a136ad09b39c65547c460049ba5358d28afa576'
MAE = 'a6044a84542f522f434c5dc3d609e60c7446d423f3ed1b2ae513f5c48663ec5e'
FF = '1' * 64

DEPS = f"""
      - run: |
          curl -sSfL -o /tmp/osv-scanner \\
            https://github.com/google/osv-scanner/releases/download/v2.2.2/osv-scanner_linux_amd64
          echo "{OSV}  /tmp/osv-scanner" \\
            | sha256sum -c -
"""
LAB = f"""
        env:
          MAESTRO_VERSION: '2.12.0'
          MAESTRO_SHA256: '{MAE}'
        env:
          FFMPEG_TAG: 'autobuild-2026-10-30-12-55'
          FFMPEG_ASSET: 'ffmpeg-n7.1.2-3-gabc-linux64-gpl-7.1.tar.xz'
          FFMPEG_SHA256: '{FF}'
"""
TRANSCODE = LAB.split('        env:\n', 2)[2]
TRANSCODE = '        env:\n' + TRANSCODE


def reader(files):
    return lambda name: files[name]


good = {'deps-scan.yml': DEPS + DEPS, 'device-lab.yml': LAB, 'transcode.yml': TRANSCODE}
p = {name: (urls, sha, probs) for name, urls, sha, probs in pins.read_pins(reader(good))}

check('OSV-Scanner: the URL and digest are read, two jobs agreeing is fine',
      p['osv-scanner'][1] == OSV and p['osv-scanner'][0][0].endswith('/v2.2.2/osv-scanner_linux_amd64')
      and not p['osv-scanner'][2])
check('Maestro: the digest, and the three spellings of its tag to try',
      p['maestro'][1] == MAE and len(p['maestro'][0]) == 3
      and p['maestro'][0][0].endswith('/cli-2.12.0/maestro.zip') and not p['maestro'][2])
check('ffmpeg: the dated build\'s URL and digest',
      p['ffmpeg'][1] == FF and not p['ffmpeg'][2]
      and p['ffmpeg'][0][0] == 'https://github.com/BtbN/FFmpeg-Builds/releases/download/'
      'autobuild-2026-10-30-12-55/ffmpeg-n7.1.2-3-gabc-linux64-gpl-7.1.tar.xz')

floating = dict(good, **{'transcode.yml': TRANSCODE.replace(
    'env:', 'run: curl https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/x\n        env:')})
probs = dict((n, pr) for n, _, _, pr in pins.read_pins(reader(floating)))['ffmpeg']
check('a floating `latest` ffmpeg is a problem', any('floating' in x for x in probs))

apart = dict(good, **{'transcode.yml': TRANSCODE.replace(FF, '2' * 64)})
probs = dict((n, pr) for n, _, _, pr in pins.read_pins(reader(apart)))['ffmpeg']
check('the lab and the transcode job pinning different builds is a problem',
      any('different' in x for x in probs))

unpinned = dict(good, **{'device-lab.yml': LAB.replace(f"MAESTRO_SHA256: '{MAE}'", "MAESTRO_SHA256: ''")})
probs = dict((n, pr) for n, _, _, pr in pins.read_pins(reader(unpinned)))['maestro']
check('an empty Maestro digest is "not pinned"', any('not pinned' in x for x in probs))

two_osv = dict(good, **{'deps-scan.yml': DEPS + DEPS.replace(OSV, '3' * 64)})
probs = dict((n, pr) for n, _, _, pr in pins.read_pins(reader(two_osv)))['osv-scanner']
check('two OSV jobs with different digests is a problem', bool(probs))

# check(): the digest decides; a missing file and a changed file both fail.
lines = []
def fetch_ok(url):
    if '/cli-' in url:
        raise OSError('404')  # the first spelling is gone; the next is tried
    return {OSV: OSV, MAE: MAE, FF: FF}[
        OSV if 'osv' in url else MAE if 'maestro' in url else FF], 10
bad = pins.check(pins.read_pins(reader(good)), fetch=fetch_ok, out=lines.append)
check('every pin matching passes, a renamed tag spelling included', bad == 0 and len(lines) == 3)

lines = []
bad = pins.check(pins.read_pins(reader(good)), fetch=lambda u: ('0' * 64, 10), out=lines.append)
check('a changed file fails, once per pin', bad == 3 and all('not the pinned one' in l for l in lines))

lines = []
def gone(u):
    raise OSError('404')
bad = pins.check(pins.read_pins(reader(good)), fetch=gone, out=lines.append)
check('a vanished release fails', bad == 3 and all('no pinned file' in l for l in lines))

# newest_ffmpeg(): the newest dated build of our line; `latest` and other
# lines skipped; the digest the API gives is used.
releases = [
    {'tag_name': 'latest', 'published_at': '2026-10-30T13:00:00Z',
     'assets': [{'name': 'ffmpeg-n7.1-latest-linux64-gpl-7.1.tar.xz', 'digest': 'sha256:' + 'a' * 64}]},
    {'tag_name': 'autobuild-2026-10-30-12-55', 'published_at': '2026-10-30T12:55:00Z',
     'assets': [{'name': 'ffmpeg-n8.0-1-gxyz-linux64-gpl-8.0.tar.xz'},
                {'name': 'ffmpeg-n7.1.2-3-gabc-linux64-gpl-7.1.tar.xz', 'digest': 'sha256:' + 'b' * 64},
                {'name': 'ffmpeg-n7.1.2-3-gabc-linux64-lgpl-7.1.tar.xz'}]},
    {'tag_name': 'autobuild-2026-10-01-12-55', 'published_at': '2026-10-01T12:55:00Z',
     'assets': [{'name': 'ffmpeg-n7.1.1-9-gdef-linux64-gpl-7.1.tar.xz', 'digest': 'sha256:' + 'c' * 64}]},
]
pick, oldest, count = pins.newest_ffmpeg(releases)
check('the newest dated build of the 7.1 GPL linux64 line',
      pick == ('autobuild-2026-10-30-12-55', 'ffmpeg-n7.1.2-3-gabc-linux64-gpl-7.1.tar.xz',
               'b' * 64, '2026-10-30T12:55:00Z'))
check('how far back the dated builds go', oldest == '2026-10-01T12:55:00Z' and count == 2)

# The real workflows parse (whatever they pin today).
real = pins.read_pins()
check('the real workflows: OSV-Scanner and Maestro pinned and readable',
      all(not pr and sha for n, _, sha, pr in real if n in ('osv-scanner', 'maestro')))

print(f'\n{checks - fails} of {checks} checks passed')
if not fails:
    print(f'=== {checks} check(s) on the pinned downloads, read from the workflows ===')
sys.exit(1 if fails else 0)
