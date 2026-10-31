#!/usr/bin/env python3
"""Every file CI downloads from outside: pinned, checked, and kept current.

WHY. A workflow that downloads a tool and runs it trusts whoever can change
that file. Pinned by SHA-256, a changed file is refused before it runs; but a
pin can also rot (the release deleted, the tag renamed), and then a job
falls back or fails on the day it is needed. So the pins are read out of the
workflows themselves (one place to change them), checked every week by
downloading each and comparing digests (deps-scan.yml, job `pins`), and the
next ffmpeg build to pin is found the same way.

The pins (read from the workflow files, never repeated here):
  osv-scanner   deps-scan.yml        release URL + `sha256sum -c` line
  maestro       device-lab.yml       MAESTRO_VERSION, MAESTRO_SHA256
  ffmpeg        transcode.yml and    FFMPEG_TAG, FFMPEG_ASSET, FFMPEG_SHA256
                device-lab.yml       (the two must agree)

RUN:
  python3 tool/pins.py list      the pins as the workflows have them
  python3 tool/pins.py check     download each and compare (CI, weekly)
  python3 tool/pins.py ffmpeg    newest BtbN build of our line and its digest,
                                 and how far back BtbN keeps them (GH_TOKEN)
"""

import hashlib
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WF = os.path.join(ROOT, '.github', 'workflows')

BTBN = 'BtbN/FFmpeg-Builds'
# Our line: FFmpeg 7.1, Linux x86-64, GPL (zscale for the HDR tone-mapping).
FFMPEG_ASSET = re.compile(r'^ffmpeg-n7\.1[^/]*-linux64-gpl-7\.1\.tar\.xz$')
FLOATING_FFMPEG = 'BtbN/FFmpeg-Builds/releases/download/latest/'


def _read(name):
    with open(os.path.join(WF, name), encoding='utf-8') as f:
        return f.read()


def _env(text, key):
    """Every value given to KEY as a step env (KEY: 'value')."""
    return re.findall(r'^\s*%s:\s*[\'"]([^\'"]*)[\'"]\s*$' % re.escape(key), text, re.M)


def read_pins(read=_read):
    """[(name, [urls to try], sha256 or None, problems)]."""
    pins = []

    deps = read('deps-scan.yml')
    urls = sorted(set(re.findall(
        r'https://github\.com/google/osv-scanner/releases/download/v[\d.]+/osv-scanner_linux_amd64',
        deps)))
    shas = sorted(set(re.findall(r'echo "([0-9a-f]{64})  /tmp/osv-scanner"', deps)))
    problems = []
    if len(urls) != 1 or len(shas) != 1:
        problems.append('deps-scan.yml: the OSV-Scanner jobs do not agree on one URL and one digest')
    pins.append(('osv-scanner', urls[:1], shas[0] if shas else None, problems))

    lab = read('device-lab.yml')
    ver = _env(lab, 'MAESTRO_VERSION')
    sha = _env(lab, 'MAESTRO_SHA256')
    problems = []
    if len(ver) != 1 or not ver[0] or len(sha) != 1 or not re.fullmatch(r'[0-9a-f]{64}', sha[0] or ''):
        problems.append('device-lab.yml: Maestro is not pinned (MAESTRO_VERSION and MAESTRO_SHA256)')
    base = 'https://github.com/mobile-dev-inc/maestro/releases/download'
    v = ver[0] if ver else ''
    pins.append(('maestro', [f'{base}/{t}/maestro.zip' for t in (f'cli-{v}', f'v{v}', v)] if v else [],
                 sha[0] if sha else None, problems))

    seen = {}
    problems = []
    for name in ('transcode.yml', 'device-lab.yml'):
        text = read(name)
        if FLOATING_FFMPEG in text:
            problems.append(f'{name}: ffmpeg from BtbN\'s floating `latest` build')
        trio = tuple((_env(text, k) or [''])[0]
                     for k in ('FFMPEG_TAG', 'FFMPEG_ASSET', 'FFMPEG_SHA256'))
        seen[name] = trio
    trios = set(seen.values())
    if len(trios) != 1:
        problems.append('transcode.yml and device-lab.yml pin different ffmpeg builds')
    tag, asset, digest = sorted(trios)[0]
    if not (tag and asset and re.fullmatch(r'[0-9a-f]{64}', digest or '')):
        problems.append('ffmpeg is not pinned (FFMPEG_TAG, FFMPEG_ASSET, FFMPEG_SHA256)')
    url = f'https://github.com/{BTBN}/releases/download/{tag}/{asset}' if tag and asset else None
    pins.append(('ffmpeg', [url] if url else [], digest or None, problems))
    return pins


def _sha256_of(url, opener=urllib.request.urlopen):
    h = hashlib.sha256()
    n = 0
    with opener(url, timeout=120) as r:
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            h.update(chunk)
            n += len(chunk)
    return h.hexdigest(), n


def check(pins, fetch=_sha256_of, out=print):
    """Download every pin and compare. Returns the number of failures."""
    bad = 0
    for name, urls, sha, problems in pins:
        for p in problems:
            out(f'FAIL {name}: {p}')
            bad += 1
        if problems or not urls or not sha:
            continue
        got = None
        for url in urls:
            try:
                got = fetch(url)
                break
            except Exception as e:  # 404, network: try the next spelling
                last = f'{type(e).__name__}: {e}'
        if got is None:
            out(f'FAIL {name}: no pinned file at {urls[0]} ({last})')
            bad += 1
        elif got[0] != sha:
            out(f'FAIL {name}: the file at {url} is not the pinned one (sha256 {got[0]})')
            bad += 1
        else:
            out(f'ok   {name}: {got[1]:,} bytes, sha256 matches')
    return bad


def newest_ffmpeg(releases):
    """From BtbN's releases (the API's JSON): the newest dated build of our
    line, as (tag, asset, sha256 or None, published), and the oldest dated
    build still kept, as its publish date."""
    dated = [r for r in releases if str(r.get('tag_name', '')).startswith('autobuild-')]
    dated.sort(key=lambda r: r.get('published_at') or '', reverse=True)
    pick = None
    for r in dated:
        for a in r.get('assets') or []:
            if FFMPEG_ASSET.match(a.get('name', '')):
                d = a.get('digest') or ''
                pick = (r['tag_name'], a['name'], d[7:] if d.startswith('sha256:') else None,
                        r.get('published_at'))
                break
        if pick:
            break
    oldest = dated[-1].get('published_at') if dated else None
    return pick, oldest, len(dated)


def _github(path):
    req = urllib.request.Request('https://api.github.com' + path, headers={
        'Accept': 'application/vnd.github+json',
        **({'Authorization': 'Bearer ' + os.environ['GH_TOKEN']} if os.environ.get('GH_TOKEN') else {}),
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main(argv):
    cmd = argv[1] if len(argv) > 1 else 'list'
    if cmd == 'list':
        for name, urls, sha, problems in read_pins():
            print(f'{name:12} {sha or "-":64}  {urls[0] if urls else "-"}')
            for p in problems:
                print(f'             ! {p}')
        return 0
    if cmd == 'check':
        bad = check(read_pins())
        print(f'=== {bad} pin(s) broken ===' if bad else '=== every pinned download is there and unchanged ===')
        return 1 if bad else 0
    if cmd == 'ffmpeg':
        releases = []
        for page in (1, 2, 3):
            batch = _github(f'/repos/{BTBN}/releases?per_page=100&page={page}')
            releases += batch
            if len(batch) < 100:
                break
        pick, oldest, count = newest_ffmpeg(releases)
        if not pick:
            print('no dated build of the 7.1 GPL linux64 line found')
            return 1
        tag, asset, digest, when = pick
        if not digest:
            digest, size = _sha256_of(f'https://github.com/{BTBN}/releases/download/{tag}/{asset}')
        print(f"FFMPEG_TAG: '{tag}'")
        print(f"FFMPEG_ASSET: '{asset}'")
        print(f"FFMPEG_SHA256: '{digest}'")
        print(f'published {when}; BtbN keeps {count} dated builds, the oldest from {oldest}')
        return 0
    print(__doc__.strip().splitlines()[0])
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
