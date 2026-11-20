#!/usr/bin/env python3
"""The seek bar's pictures, made for each film that has none
(docs/trickplay_plan.md; run by .github/workflows/trickplay.yml).

Reads the answer to `trick_claim` (docs/edge/transcode.ts) from the file named
on the command line:

    {"jobs": [{"asset_id", "src_url", "src_height", "key", "put_url"}],
     "scope": "open" | "all", "done_url": "…/functions/v1/transcode"}

For each film: its smallest plain rung fetched (src_url, presigned for one
object), tool/trickplay.py at the plan's setting (a picture every 4 s, 320 px
wide, JPEG q8), the pack PUT at put_url as application/octet-stream, then
`trick_done` with what was made — the function checks the object's size in
the bucket before it records anything. A film that yields no pack is
reported as a failure with the reason, so it waits a day instead of being
offered on every run.

NOTHING HERE HOLDS A BUCKET KEY, AND NO ADDRESS IS PRINTED: every URL arrives
presigned for one object; the log says film, pictures and sizes only.

ENV: RUNNER_SECRET (the transcode runner's secret, for trick_done).
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
INTERVAL_S = 4
WIDTH = 320
CODEC = 'jpeg'
QUALITY = 8


def _curl(args):
    p = subprocess.run(['curl', '-sS', '--fail', '--retry', '2'] + args, capture_output=True, text=True)
    if p.returncode != 0:
        # curl's own message names the URL: never printed.
        raise RuntimeError(f'curl exit {p.returncode}')
    return p.stdout


def done(url, secret, asset, pack=None, note=None):
    """`trick_done`, once: no --fail and no --retry — a refusal (409) is an
    answer to report, not a reason to stop the batch, and a retried report
    that had already been recorded would be refused as never claimed."""
    body = {'op': 'trick_done', 'token': secret, 'asset_id': asset}
    if pack is not None:
        body['pack'] = pack
    if note:
        body['note'] = note[:200]
    p = subprocess.run(['curl', '-sS', '--max-time', '60', '-w', '\n%{http_code}', '-X', 'POST', url,
                        '-H', 'Content-Type: application/json', '-d', json.dumps(body)],
                       capture_output=True, text=True)
    text, _, code = p.stdout.rpartition('\n')
    try:
        answer = json.loads(text) if text else {}
    except ValueError:
        answer = {}
    if not isinstance(answer, dict):
        answer = {}
    if p.returncode != 0 or not code.startswith('2'):
        answer.setdefault('error', f'HTTP {code or "none"}')
    return answer


def run_job(job, done_url, secret, work):
    asset = job['asset_id']
    src = os.path.join(work, 'src.mp4')
    out = os.path.join(work, 'pack.itp')
    for f in (src, out):
        if os.path.exists(f):
            os.remove(f)
    try:
        _curl(['--max-time', '1800', '-o', src, job['src_url']])
    except RuntimeError as e:
        done(done_url, secret, asset, note=f'the rung could not be read ({e})')
        return f'{asset}: the rung could not be read'
    p = subprocess.run([sys.executable, os.path.join(HERE, 'trickplay.py'), src, out,
                        '--interval', str(INTERVAL_S), '--width', str(WIDTH), '--codec', CODEC,
                        '--quality', str(QUALITY), '--report'], capture_output=True, text=True)
    if p.returncode != 0 or not os.path.exists(out):
        why = (p.stderr.strip().splitlines() or ['no pack'])[-1][:160]
        done(done_url, secret, asset, note=f'trickplay: {why}')
        return f'{asset}: no pack ({why})'
    r = json.loads(p.stdout.strip().splitlines()[-1])
    try:
        _curl(['--max-time', '600', '-X', 'PUT', '-T', out, '-H', 'Content-Type: application/octet-stream',
               job['put_url']])
    except RuntimeError as e:
        done(done_url, secret, asset, note=f'the pack could not be put ({e})')
        return f'{asset}: the pack could not be put'
    pack = {'key': job['key'], 'bytes': r['bytes'], 'interval_ms': int(INTERVAL_S * 1000),
            'width': r['width'], 'height': r['height'], 'count': r['count'], 'codec': CODEC}
    answer = done(done_url, secret, asset, pack=pack)
    took = 'recorded' if answer.get('key') else f"not recorded ({answer.get('error') or 'the function refused it'})"
    return (f"{asset}: {r['count']} pictures {r['width']}x{r['height']}, {r['bytes'] / 1e6:.2f} MB "
            f"(median {r['median_bytes'] / 1e3:.1f} KB), {r['seconds']} s — {took}")


def main(argv):
    if len(argv) != 2:
        print('usage: trickplay_job.py CLAIM.json', file=sys.stderr)
        return 2
    secret = os.environ.get('RUNNER_SECRET', '')
    with open(argv[1]) as fh:
        claim = json.load(fh)
    jobs = claim.get('jobs') or []
    print(f"trickplay: {len(jobs)} film(s), scope {claim.get('scope', '?')}")
    work = tempfile.mkdtemp(prefix='trick_job_')
    failed = 0
    for job in jobs:
        try:
            line = run_job(job, claim['done_url'], secret, work)
        except Exception as e:  # noqa: BLE001 - one film never ends the batch
            line = f"{job.get('asset_id')}: failed ({type(e).__name__})"
        failed += 0 if line.endswith('recorded') else 1
        print('trickplay: ' + line)
    return 1 if failed and failed == len(jobs) else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
