#!/usr/bin/env python3
"""Phase 0 of the trick-play sprite (docs/trickplay_plan.md): what a pack
costs, measured on the open films' real frames, before any format is chosen.

For each published open film (slug `open-film-…`): the playback grant as the
app asks for it (request-playback, the publishable key, no account — free
titles only), its smallest rung through the Worker, then tool/trickplay.py at
each setting below. Prints one line a film and setting, then a table per
setting: pictures, median/p90 KB a picture, MB per film-hour, seconds of the
runner per film-hour. Uploads nothing, keeps no picture (the films are open;
the numbers are what matters), prints no address.

ENV: SB_URL (the project), SB_KEY (the publishable key, as the app carries).
"""
import json
import os
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
OPEN_FILMS = [
    '5c01507a-ef1d-46eb-8bb8-a9a2326be153:open-film-big-buck-bunny',
    '1ac9f7c8-4053-4728-9016-030285cfd107:open-film-big-buck-bunny-60fps',
    'b6fe803e-7a6b-4c5e-9fd4-b2bd8f24478f:open-film-caminandes-llamigos',
    '7fdd9b66-1cc6-4840-9dfe-3195f4b9f993:open-film-cosmos-laundromat',
    '40c64a2b-2657-49b9-8e36-1192e1830b0c:open-film-elephants-dream',
    'c8f469c1-34f3-4436-ad8b-9547489c5bed:open-film-glass-half',
    '76d94e20-a2a8-4751-824a-6f2494b31499:open-film-hero',
    '0839dacb-59ae-4c95-9279-4901b925965d:open-film-sintel',
    'ab8b0f1e-e23b-4141-94ba-67f1b29a7765:open-film-tears-of-steel',
]
SETTINGS = [
    # (interval s, width, codec, quality)
    (2, 224, 'jpeg', 5),
    (4, 160, 'jpeg', 5),
    (4, 224, 'jpeg', 5),
    (4, 224, 'jpeg', 8),
    (4, 224, 'webp', 60),
    (4, 320, 'jpeg', 5),
    (4, 320, 'jpeg', 8),
    (4, 288, 'jpeg', 8),
    (5, 224, 'jpeg', 5),
]


def _get(url, key, body=None):
    """JSON from [url] through curl, as test_device/probe.sh asks."""
    args = ['curl', '-sS', '--fail', '--max-time', '60', url, '-H', f'apikey: {key}']
    if body is not None:
        args += ['-X', 'POST', '-H', 'Content-Type: application/json', '-d', json.dumps(body)]
    out = subprocess.run(args, capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(f'curl exit {out.returncode}')
    return json.loads(out.stdout)


def main():
    sb, key = os.environ['SB_URL'].rstrip('/'), os.environ['SB_KEY']
    # The open films by id (their slugs from the database, 20 Nov 2026):
    # anon may not filter titles by slug or published (curl exit 22, run
    # 44668303774) — as probe.sh, only by id or name. OPEN_FILMS overrides.
    titles = [dict(zip(('id', 'slug'), x.split(':', 1)))
              for x in os.environ.get('OPEN_FILMS', ' '.join(OPEN_FILMS)).split()]
    rows = []
    work = tempfile.mkdtemp(prefix='trick_measure_')
    for t in titles:
        try:
            g = _get(f'{sb}/functions/v1/request-playback', key, {'title_id': t['id']})
        except Exception as e:  # noqa: BLE001 - a film that will not play is a line, not a stop
            print(f"{t['slug']}: no grant ({type(e).__name__})")
            continue
        rungs = [r for r in g.get('renditions') or [] if r.get('url') and not r.get('seal')]
        if not rungs:
            print(f"{t['slug']}: no plain rung")
            continue
        low = min(rungs, key=lambda r: r.get('height') or 9999)
        src = os.path.join(work, 'src.mp4')
        subprocess.run(['curl', '-sS', '--fail', '--max-time', '600', '-o', src, low['url']], check=True)
        mb = os.path.getsize(src) / 1e6
        for iv, w, codec, q in SETTINGS:
            out = os.path.join(work, 'p.itp')
            p = subprocess.run([sys.executable, os.path.join(HERE, 'trickplay.py'), src, out,
                                '--interval', str(iv), '--width', str(w), '--codec', codec,
                                '--quality', str(q), '--report'], capture_output=True, text=True)
            if p.returncode != 0:
                print(f"{t['slug']} {iv}s {w} {codec} q{q}: failed: {p.stderr.strip()[:200]}")
                continue
            r = json.loads(p.stdout.strip().splitlines()[-1])
            r.update(slug=t['slug'], setting=f'{iv}s {w}px {codec} q{q}', src_h=low.get('height'),
                     src_mb=round(mb, 1))
            rows.append(r)
            print(f"{t['slug']} ({low.get('height')}p, {mb:.1f} MB) {r['setting']}: {r['count']} pictures "
                  f"{r['width']}x{r['height']}, {r['bytes'] / 1e6:.2f} MB, median {r['median_bytes'] / 1e3:.1f} KB, "
                  f"p90 {r['p90_bytes'] / 1e3:.1f} KB, {r['mb_per_hour']} MB/h, {r['seconds']} s")
        os.remove(src)
    print()
    print('| setting | films | pictures | median KB | p90 KB | MB per film-hour | runner s per film-hour |')
    print('|---|---|---|---|---|---|---|')
    for iv, w, codec, q in SETTINGS:
        name = f'{iv}s {w}px {codec} q{q}'
        sel = [r for r in rows if r['setting'] == name]
        if not sel:
            continue
        film_s = sum(r['count'] * r['interval_s'] for r in sel)
        total = sum(r['bytes'] for r in sel)
        secs = sum(r['seconds'] for r in sel)
        med = statistics.median(r['median_bytes'] for r in sel) / 1e3
        p90 = max(r['p90_bytes'] for r in sel) / 1e3
        print(f"| {name} | {len(sel)} | {sum(r['count'] for r in sel)} | {med:.1f} | {p90:.1f} | "
              f"{total / 1e6 * 3600 / film_s:.2f} | {secs * 3600 / film_s:.0f} |")
    return 0 if rows else 1


if __name__ == '__main__':
    sys.exit(main())
