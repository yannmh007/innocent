#!/usr/bin/env python3
"""tool/open_films.py: which open films may become test titles.

The licence gate is the reason this tool exists: a film enters only when
Blender's own site says CC BY or CC0. These cases are the ones that would
put a film in the catalogue that may not be there (No Derivatives, Non
Commercial, a licence left unset, a copy federated from another server), or
seed a file that is not the film whose licence was read (a short download,
another height, no sound).

    python3 tool/open_films_test.py
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import open_films as of  # noqa: E402

failed = 0
count = 0


def check(what: str, ok: bool) -> None:
    global failed, count
    count += 1
    if ok:
        print('ok   ' + what)
    else:
        failed += 1
        print('FAIL ' + what)


def video(lic, files=(), hls=(), nsfw=False, local=True, host='video.blender.org', **kw):
    v = {
        'uuid': 'f507dfdc-e73e-45a4-9778-d758cbe1ce96', 'shortUUID': 'abcDEF123456',
        'name': 'Cosmos Laundromat - First Cycle. Official Blender Foundation release.',
        'duration': 731, 'licence': {'id': lic, 'label': 'x'}, 'nsfw': nsfw,
        'isLocal': local, 'account': {'host': host},
        'files': [{'resolution': {'id': h}, 'fps': 24, 'size': s, 'fileDownloadUrl': f'https://v/{h}.mp4'} for h, s in files],
        'streamingPlaylists': [{'files': [{'resolution': {'id': h}, 'fps': 24, 'size': s,
                                           'fileDownloadUrl': f'https://v/hls-{h}.mp4'} for h, s in hls]}],
        'publishedAt': '2018-04-12T00:00:00Z',
    }
    v.update(kw)
    return v


# ── the licence ──────────────────────────────────────────────────────────
check('CC BY is allowed', of.allowed(video(1)))
check('CC0 is allowed', of.allowed(video(7)))
for lid, name in ((2, 'CC BY-SA'), (3, 'CC BY-ND'), (4, 'CC BY-NC'), (5, 'CC BY-NC-SA'), (6, 'CC BY-NC-ND')):
    check(f'{name} is refused', not of.allowed(video(lid)))
check('a licence left unset is refused', not of.allowed(video(None)))
check('no licence object at all is refused', not of.allowed({'name': 'x'}))
check('licences are named as the CC short names', of.licence_of(video(3))[1] == 'CC BY-ND')

# ── whose video it is ───────────────────────────────────────────────────
check('a video of video.blender.org is local', of.local(video(1)))
check('a copy federated from another server is not', not of.local(video(1, local=False, host='tube.example')))

# ── the file taken ──────────────────────────────────────────────────────
v = video(1, files=[(2160, 900), (1080, 300), (720, 200), (0, 5)])
best = of.best_file(v)
check('the best file at or under 1080p is taken, not the 4K one', best and best['height'] == 1080)
check('an audio-only file (resolution 0) is never a master',
      all(f['height'] > 0 for f in of.files_of(v)))
v = video(1, files=[], hls=[(804, 230), (720, 200)])
best = of.best_file(v)
check('a server that keeps only HLS still offers its files', best and best['url'].endswith('hls-804.mp4'))
check('nothing to download is no pick', of.best_file(video(1)) is None)
check('only a 4K file is no pick (the ladder tops at 1080p)',
      of.best_file(video(1, files=[(2160, 900)])) is None)

# ── a master checked against the site ───────────────────────────────────
pick = {'height': 804, 'duration_s': 731}
good = {'streams': [{'codec_type': 'video', 'codec_name': 'h264', 'height': 804},
                    {'codec_type': 'audio', 'codec_name': 'aac'}],
        'format': {'duration': '731.4'}}
check('the right file passes', of.check_probe(pick, good) == [])
short = dict(good, format={'duration': '400.0'})
check('a download cut short is refused', any('long' in b for b in of.check_probe(pick, short)))
other = {'streams': [{'codec_type': 'video', 'codec_name': 'h264', 'height': 720}, good['streams'][1]],
         'format': good['format']}
check('another height is refused', any('height' in b for b in of.check_probe(pick, other)))
mute = {'streams': [good['streams'][0]], 'format': good['format']}
check('a film with no sound is refused', 'no audio stream' in of.check_probe(pick, mute))
hevc = {'streams': [dict(good['streams'][0], codec_name='hevc'), good['streams'][1]], 'format': good['format']}
check('a codec the ladder does not expect is refused', any('h264' in b for b in of.check_probe(pick, hevc)))
cover = {'streams': [{'codec_type': 'video', 'codec_name': 'mjpeg', 'height': 600}], 'format': good['format']}
check('cover art is not taken for the video stream', of.check_probe(pick, cover) == ['no video stream'])

# ── names ────────────────────────────────────────────────────────────────
check('a title loses the site\'s suffix', of.clean_title('Spring - Blender Open Movie') == 'Spring')
check('the attribution names the licence and the Foundation',
      of.attribution(video(1)) == '(CC BY) Blender Foundation | studio.blender.org')

# ── an id is an id ──────────────────────────────────────────────────────
for bad in ('../../etc', 'x', 'a b c', 'f507dfdc/../x'):
    try:
        of.details(bad)
        ok = False
    except ValueError:
        ok = True
    check(f'{bad!r} is not taken for a video id', ok)

if failed:
    print(f'\n{failed} of {count} check(s) FAILED')
    sys.exit(1)
print(f'\n=== {count} check(s) on the open films\' licence gate passed ===')
