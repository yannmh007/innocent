#!/usr/bin/env python3
"""Open test films from Blender's own video site, with their licence checked.

The catalogue's test films are Blender open movies. This finds them on
video.blender.org, the Blender Foundation's PeerTube server, which states
each video's licence in its API. No film enters unless that licence is
plain Attribution (CC BY) or a public-domain dedication (CC0): a film marked
No Derivatives (Agent 327's file is CC BY-ND), Non Commercial or Share Alike,
or with no licence at all, is refused, because the app transcodes it into a
ladder and cuts stills from it.

    python3 tool/open_films.py find "Spring" "Coffee Run" ...
        Prints, for each name, what the site has: the video's id, length,
        licence, and the files it offers (height, fps, size).

    python3 tool/open_films.py pick <uuid>
        Prints one JSON line for a film the seed job may use: its title,
        year, length, licence, the attribution line, and the download URL of
        its best file at or under 1080p. Exits 3 when the licence refuses it,
        4 when no file can be downloaded.

    python3 tool/open_films.py check <pick.json> <ffprobe.json>
        After the download: is the file the film the licence was read for
        (H.264 at the height picked, with sound, the site's length to three
        seconds)? Exits 1 and says why when not.

Standard library only: it runs on a bare GitHub runner.
"""
from __future__ import annotations

import json
import re
import sys
import urllib.parse
import urllib.request

SITE = 'https://video.blender.org'
UA = 'innocent-open-films/1 (+https://github.com/yannmh007/innocent)'

# PeerTube's licence ids (server/initializers/constants.ts VIDEO_LICENCES).
LICENCES = {
    1: 'CC BY',
    2: 'CC BY-SA',
    3: 'CC BY-ND',
    4: 'CC BY-NC',
    5: 'CC BY-NC-SA',
    6: 'CC BY-NC-ND',
    7: 'CC0',
}
# What a test film may carry: attribution only, or no condition at all.
ALLOWED = {1, 7}

# The tallest file the seed takes. The ladder's top rung is 1080p; a 4K
# master would only make the runner's download and the bucket larger.
MAX_HEIGHT = 1080


def get(path: str, timeout: int = 30):
    req = urllib.request.Request(SITE + path, headers={'User-Agent': UA, 'Accept': 'application/json'})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


def licence_of(video: dict) -> tuple[int | None, str]:
    lic = video.get('licence') or {}
    lid = lic.get('id')
    return lid, LICENCES.get(lid, lic.get('label') or 'none')


def allowed(video: dict) -> bool:
    lid, _ = licence_of(video)
    return lid in ALLOWED


def local(video: dict) -> bool:
    """Published by video.blender.org itself, not a copy federated from elsewhere."""
    acc = video.get('account') or {}
    host = acc.get('host') or (video.get('channel') or {}).get('host')
    return video.get('isLocal', True) is not False and host in (None, 'video.blender.org')


def files_of(video: dict) -> list[dict]:
    """Every downloadable file: the plain web videos, then the HLS playlist's
    fragmented MP4s (a server that keeps only HLS still offers those)."""
    out = []
    for f in video.get('files') or []:
        out.append(f)
    for pl in video.get('streamingPlaylists') or []:
        for f in pl.get('files') or []:
            out.append(f)
    files = []
    for f in out:
        res = f.get('resolution') or {}
        h = res.get('id') if isinstance(res, dict) else res
        url = f.get('fileDownloadUrl') or f.get('fileUrl')
        if not url or not isinstance(h, int) or h <= 0:
            continue  # audio-only (0) or no address
        files.append({'height': h, 'fps': f.get('fps'), 'size': f.get('size') or 0, 'url': url})
    # Tallest first; for one height, the plain web video before the HLS copy.
    files.sort(key=lambda x: -x['height'])
    return files


def best_file(video: dict, max_height: int = MAX_HEIGHT) -> dict | None:
    for f in files_of(video):
        if f['height'] <= max_height:
            return f
    return None


def year_of(video: dict) -> int | None:
    for k in ('originallyPublishedAt', 'publishedAt'):
        v = video.get(k)
        if isinstance(v, str) and re.match(r'^\d{4}-', v):
            return int(v[:4])
    return None


def clean_title(name: str) -> str:
    """'Spring - Blender Open Movie' -> 'Spring'."""
    t = re.sub(r'\s*[-–|:]\s*(Blender\s+)?(Open\s+Movie|Studio|Foundation|Animation Studio)\b.*$', '', name, flags=re.I)
    t = re.sub(r'\s*\((?:\d{3,4}p|4k|uhd|hd)\)\s*$', '', t, flags=re.I)
    return t.strip() or name.strip()


def attribution(video: dict) -> str:
    lid, lab = licence_of(video)
    return f'({lab}) Blender Foundation | studio.blender.org'


def search(name: str, count: int = 8) -> list[dict]:
    q = urllib.parse.urlencode({'search': name, 'count': count, 'searchTarget': 'local'})
    return [v for v in (get('/api/v1/search/videos?' + q).get('data') or []) if local(v)]


def details(uuid: str) -> dict:
    if not re.fullmatch(r'[0-9a-fA-F-]{8,40}|[0-9A-Za-z]{10,24}', uuid):
        raise ValueError('not a video id')
    return get('/api/v1/videos/' + uuid)


def cmd_find(names: list[str]) -> int:
    for name in names:
        print(f'== {name}')
        try:
            found = search(name)
        except Exception as e:  # noqa: BLE001 - say what failed, carry on
            print(f'   search failed: {e}')
            continue
        if not found:
            print('   nothing on video.blender.org')
        for v in found:
            try:
                d = details(v['uuid'])
            except Exception as e:  # noqa: BLE001
                print(f"   {v.get('name')!r} {v.get('uuid')}: details failed: {e}")
                continue
            lid, lab = licence_of(d)
            mins = (d.get('duration') or 0) / 60
            fl = ', '.join(f"{f['height']}p{f.get('fps') or ''} {f['size'] / 1e6:.0f}MB" for f in files_of(d)) or 'no files'
            gate = 'OK ' if lid in ALLOWED else 'NO '
            print(f"   {gate}{d.get('name')!r} uuid={d.get('uuid')} year={year_of(d)} "
                  f"{mins:.1f} min licence={lab} download={d.get('downloadEnabled')} nsfw={d.get('nsfw')} | {fl}")
    return 0


def cmd_pick(uuid: str) -> int:
    d = details(uuid)
    lid, lab = licence_of(d)
    if lid not in ALLOWED:
        print(json.dumps({'uuid': uuid, 'refused': f'licence {lab}'}))
        return 3
    if d.get('nsfw'):
        print(json.dumps({'uuid': uuid, 'refused': 'marked sensitive'}))
        return 3
    f = best_file(d)
    if not f:
        print(json.dumps({'uuid': uuid, 'refused': 'no downloadable file'}))
        return 4
    print(json.dumps({
        'uuid': d.get('uuid'),
        'title': clean_title(d.get('name') or ''),
        'year': year_of(d),
        'duration_s': d.get('duration'),
        'licence': lab,
        'attribution': attribution(d),
        'page': f"{SITE}/w/{d.get('shortUUID') or d.get('uuid')}",
        'height': f['height'],
        'fps': f.get('fps'),
        'size': f['size'],
        'url': f['url'],
    }))
    return 0


def check_probe(pick: dict, probe: dict) -> list[str]:
    """What is wrong with a downloaded master, against what the site said.

    `probe` is ffprobe's JSON (-show_streams -show_format). An empty list
    means the file is the film the licence was read for: H.264 video of the
    height picked, an audio track, and the length the site gives to within
    three seconds (a short or truncated download fails here, not in a
    viewer's player)."""
    bad = []
    streams = probe.get('streams') or []
    video = [s for s in streams if s.get('codec_type') == 'video' and s.get('codec_name') not in ('mjpeg', 'png')]
    audio = [s for s in streams if s.get('codec_type') == 'audio']
    if not video:
        return ['no video stream']
    v = video[0]
    if v.get('codec_name') != 'h264':
        bad.append(f"video is {v.get('codec_name')}, not h264")
    h = int(v.get('height') or 0)
    if h != int(pick.get('height') or -1):
        bad.append(f"height {h}, the site said {pick.get('height')}")
    if not audio:
        bad.append('no audio stream')
    try:
        dur = float((probe.get('format') or {}).get('duration') or 0)
    except ValueError:
        dur = 0.0
    want = float(pick.get('duration_s') or 0)
    if want and abs(dur - want) > 3:
        bad.append(f'{dur:.0f} s long, the site said {want:.0f} s')
    return bad


def cmd_check(pick_path: str, probe_path: str) -> int:
    pick = json.load(open(pick_path))
    probe = json.load(open(probe_path))
    bad = check_probe(pick, probe)
    for b in bad:
        print('  BAD ' + b)
    if not bad:
        print('  master checked: the film the licence was read for')
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[0] == 'find':
        return cmd_find(argv[1:])
    if len(argv) == 2 and argv[0] == 'pick':
        return cmd_pick(argv[1])
    if len(argv) == 3 and argv[0] == 'check':
        return cmd_check(argv[1], argv[2])
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
