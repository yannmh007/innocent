#!/usr/bin/env python3
"""Ten stills per video, for the console's cover picker (migration 043).

Run by .github/workflows/transcode.yml with the answer to `frames_claim` in
/tmp/frames.json:

    {"jobs": [{"asset_id", "src_url", "duration_s",
               "frames": [{"key", "put"}, … ten]}],
     "done_url": "…/functions/v1/transcode"}

For each video: frame 0 at one second — the default thumbnail, the owner's
"00:01" — and frames 1–9 at 10 %, 20 % … 90 % of the running time, each
640 px on its long edge, PUT at its presigned URL in the public bucket, then
`frames_done` with the list. A video that yields no frame is reported as a
failure with the reason, so the console can say so instead of spinning.

WHY ffmpeg SEEKS THE URL INSTEAD OF DOWNLOADING THE FILE. `-ss` before `-i`
on an HTTP input is a range request to the nearest keyframe: ten frames of a
two-hour film cost a few megabytes, not two gigabytes, and the whole batch of
twenty videos fits in a couple of minutes of a runner.

HDR IS TONE-MAPPED, exactly as tool/transcode.sh does for the ladder. A
phone's HDR10 clip drawn as 8-bit without converting the curve is a grey,
washed-out still — the worst possible advertisement for it.

NOTHING HERE HOLDS A BUCKET KEY. Every URL arrives presigned for one object.
"""

import json
import os
import subprocess
import sys
import tempfile

JOBS = '/tmp/frames.json'
LONG_EDGE = 640

# The same curve conversion as transcode.sh, used only when the source says
# it is PQ or HLG and this ffmpeg has zscale.
TONEMAP = ('zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,'
           'tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,')


def frame_times(duration, count=10):
    """Seconds at which to take each frame.

    Frame 0 is at one second (or half-way through anything shorter than two
    seconds); the rest are evenly spread at i/count of the running time. An
    unknown duration still gets its default frame.
    """
    if not duration or duration <= 0:
        return [1.0]
    first = 1.0 if duration >= 2 else duration / 2
    out = [round(first, 2)]
    for i in range(1, count):
        out.append(round(duration * i / count, 2))
    return out


def scale_filter(long_edge=LONG_EDGE):
    """640 on the long edge, never upscaled, even dimensions for JPEG."""
    return ("scale='if(gte(iw,ih),min(%d,iw),-2)':'if(gte(iw,ih),-2,min(%d,ih))'"
            % (long_edge, long_edge))


def _run(cmd, timeout):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          timeout=timeout, check=False)


def probe(src):
    """(duration seconds or None, colour transfer or '')."""
    dur, transfer = None, ''
    try:
        p = _run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                  '-of', 'csv=p=0', src], 120)
        dur = float(p.stdout.decode().strip().splitlines()[0])
    except Exception:                                  # noqa: BLE001
        pass
    try:
        p = _run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                  '-show_entries', 'stream=color_transfer', '-of', 'csv=p=0', src], 120)
        transfer = p.stdout.decode().strip().splitlines()[0] if p.stdout else ''
    except Exception:                                  # noqa: BLE001
        pass
    return dur, transfer


def has_zscale():
    try:
        p = _run(['ffmpeg', '-hide_banner', '-filters'], 60)
        return b' zscale ' in p.stdout
    except Exception:                                  # noqa: BLE001
        return False


def grab(src, at, out, tonemap=''):
    """One still at `at` seconds. True if a non-empty JPEG was written."""
    cmd = ['ffmpeg', '-nostdin', '-y', '-hide_banner', '-loglevel', 'error',
           '-ss', '%.2f' % at, '-i', src, '-frames:v', '1', '-an', '-sn',
           '-vf', tonemap + scale_filter() + ',format=yuvj420p',
           '-q:v', '3', out]
    try:
        _run(cmd, 180)
    except subprocess.TimeoutExpired:
        return False
    return os.path.exists(out) and os.path.getsize(out) > 0


def put(path, url):
    p = _run(['curl', '-fsS', '--retry', '3', '--retry-delay', '3', '-H', 'Expect:',
              '-H', 'Content-Type: image/jpeg',
              # A day, not a year: "make the frames again" writes the same keys.
              '-H', 'Cache-Control: public, max-age=86400',
              '-T', path, url, '-o', '/dev/null'], 300)
    return p.returncode == 0


def report(done_url, token, asset_id, frames, note):
    body = json.dumps({'op': 'frames_done', 'token': token, 'asset_id': asset_id,
                       'frames': frames, 'note': note})
    with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as fh:
        fh.write(body)
        path = fh.name
    try:
        p = _run(['curl', '-fsS', '-X', 'POST', done_url, '-H',
                  'Content-Type: application/json', '--data-binary', '@' + path,
                  '-o', '/dev/null'], 120)
        return p.returncode == 0
    finally:
        os.unlink(path)


def one(job, work, zscale):
    """Frames for one video: (list of {at, key}, note)."""
    src = job['src_url']
    dur, transfer = probe(src)
    dur = dur or job.get('duration_s')
    tonemap = TONEMAP if transfer in ('smpte2084', 'arib-std-b67') and zscale else ''
    slots = job.get('frames') or []
    made = []
    for i, at in enumerate(frame_times(dur, len(slots) or 10)):
        if i >= len(slots):
            break
        out = os.path.join(work, '%s-%02d.jpg' % (job['asset_id'], i))
        ok = grab(src, at, out, tonemap)
        # Past the last keyframe of a file whose duration lies: one second back.
        if not ok and at > 1:
            at = max(0.0, at - 1)
            ok = grab(src, at, out, tonemap)
        if ok and put(out, slots[i]['put']):
            made.append({'at': round(at, 1), 'key': slots[i]['key']})
        if os.path.exists(out):
            os.unlink(out)
    if not made:
        return None, 'no frame could be read from this video'
    return made, '%d frames%s' % (len(made), ', HDR tone-mapped' if tonemap else '')


def main():
    try:
        with open(JOBS, 'r', encoding='utf-8') as fh:
            batch = json.load(fh)
    except Exception as exc:                           # noqa: BLE001
        print('no frames batch: %s' % exc)
        return 0
    jobs = batch.get('jobs') or []
    done_url = batch.get('done_url', '')
    token = os.environ.get('JOB_TOKEN', '')
    if not jobs:
        print('frames: none due')
        return 0
    zscale = has_zscale()
    ok = 0
    with tempfile.TemporaryDirectory() as work:
        for job in jobs:
            try:
                frames, note = one(job, work, zscale)
            except Exception as exc:                   # noqa: BLE001
                frames, note = None, 'frames failed: %s' % str(exc)[:150]
            report(done_url, token, job['asset_id'], frames, note)
            ok += 1 if frames else 0
            # Asset ids only: every URL in the batch is presigned, and a run
            # log on a public repository is public.
            print('frames: %s %s' % (job['asset_id'], note))
    print('frames: %d of %d videos' % (ok, len(jobs)))
    # Zero whatever happened: every failure has been reported to the database.
    return 0


if __name__ == '__main__':
    sys.exit(main())
