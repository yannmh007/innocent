#!/usr/bin/env bash
#
# Build a streaming ladder from one uploaded master, and report each rung as
# soon as it exists.
#
# WHY THIS FILE EXISTS. The operator uploads whatever their camera produced —
# 4K, 60fps, 60 megabits a second — and should not have to think about any of
# that. A viewer on a mobile connection cannot receive 60 Mbps continuously
# and no player setting changes that arithmetic. The only thing that does is
# having a smaller copy of the same video, which is what this makes.
#
# WHY IT RUNS ON A GITHUB RUNNER. The operator works from a phone. There is
# no server in this project and adding one means a bill, a machine to patch
# and an SSH key to lose. GitHub Actions on standard runners is free and
# unmetered for public repositories, which this is, and a runner is four
# cores of x86 with ffmpeg one apt-get away. It is the only free compute this
# project already has a relationship with.
#
# WHY RUNGS ARE ENCODED LOWEST FIRST AND REPORTED ONE AT A TIME. A feature
# film takes a couple of hours to encode fully and a runner is killed at six.
# Reporting the whole ladder at the end means a timeout produces nothing; the
# database says "running" forever and the operator has a file nobody can
# watch. Lowest first means the video is streamable at 360p within minutes of
# the upload, and every rung after that is an improvement on something that
# already works.
#
# WHY VBV AND NOT PLAIN CRF. A quality-targeted encode produces whatever
# bitrate the content needs, and on high-motion footage — which is exactly
# what a phone camera shoots — that can be several times the average. The
# whole point here is a CEILING a connection can carry, so every rung is
# CRF-driven for quality with `maxrate`/`bufsize` capping the peaks. Files
# come out small when the content is easy and never exceed their rung when it
# is not.
set -euo pipefail

SRC_URL="${SRC_URL:?presigned GET for the master}"
PUT_BASE="${PUT_BASE:?json map of height -> presigned PUT}"
DONE_URL="${DONE_URL:?where to report}"
JOB_TOKEN="${JOB_TOKEN:?opaque job token}"
ASSET_ID="${ASSET_ID:?}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
src="$work/master"

echo "::group::Fetch the master"
curl -fsSL --retry 3 --retry-delay 5 -o "$src" "$SRC_URL"
ls -lh "$src"
echo "::endgroup::"

# ── what are we working with ───────────────────────────────────────────────
# THE REPORTER IS DEFINED BEFORE ANYTHING CAN FAIL, because a job that dies
# before it exists leaves the row saying "running" for ever, and the operator
# has no way to tell a dead runner from a slow one.
results="$work/rows.json"
echo '[]' > "$results"

report() {
  # Reported after every rung rather than once at the end, so a job that is
  # killed still leaves a ladder somebody can watch.
  curl -fsS -X POST "$DONE_URL" \
    -H 'Content-Type: application/json' \
    -d "$(python3 - "$results" <<'PY'
import json, os, sys
rows = json.load(open(sys.argv[1]))
print(json.dumps({
  'op': 'done',
  'token': os.environ['JOB_TOKEN'],
  'asset_id': os.environ['ASSET_ID'],
  'rows': rows,
  'note': os.environ.get('NOTE', ''),
}))
PY
)" >/dev/null || echo "report failed (continuing)"
}


probe() { ffprobe -v error -select_streams v:0 -show_entries "$1" -of csv=p=0 "$src" | head -1; }
SRC_H="$(probe stream=height)"
SRC_W="$(probe stream=width)"
FPS_RAW="$(probe stream=r_frame_rate)"
DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$src" | head -1)"
PIXFMT="$(probe stream=pix_fmt)"
TRANSFER="$(probe stream=color_transfer)"

# A SOURCE WITH NO VIDEO STREAM IS NOT A LADDER, and left unguarded it is a
# crash: every rung test below compares a height against an empty string,
# bash calls that an error, and the job dies with a message about integer
# expressions that says nothing about the file. An audio-only upload, or one
# ffprobe cannot read at all, is reported as a failure the operator can act
# on instead.
if ! [ "${SRC_H:-0}" -gt 0 ] 2>/dev/null; then
  echo "no video stream in this file (height='${SRC_H:-}')"
  NOTE="no video stream - nothing to encode" report
  exit 0
fi

FPS="$(python3 -c "
n,_,d = '''$FPS_RAW'''.partition('/')
try: print(round(float(n)/float(d or 1), 3))
except Exception: print(30)
")"
DUR_I="${DUR%%.*}"; DUR_I="${DUR_I:-0}"
echo "source ${SRC_W}x${SRC_H} @ ${FPS}fps, ${DUR_I}s, $PIXFMT, transfer=$TRANSFER"

# ── HDR, which is not an edge case on a modern phone ───────────────────────
#
# Phone cameras record HDR10 in 10-bit by default now. Handing that to an
# 8-bit encode without converting the transfer curve produces a picture that
# is washed out and dark — technically valid, visibly wrong, and the kind of
# fault that gets blamed on "the app" forever. `zscale` does the conversion
# properly; it is not in every ffmpeg build, so its absence falls back to a
# plain 8-bit conversion rather than failing the job.
TONEMAP=""
case "$TRANSFER" in
  smpte2084|arib-std-b67)
    if ffmpeg -hide_banner -filters 2>/dev/null | grep -q ' zscale '; then
      TONEMAP="zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,"
      echo "HDR source: tone-mapping to bt709"
    else
      echo "HDR source but no zscale in this ffmpeg — 8-bit conversion only"
    fi
    ;;
esac

# ── the ladder ─────────────────────────────────────────────────────────────
#
# Targets in kbps for VIDEO at up to 30fps. A 60fps source carries twice the
# frames and needs roughly a third more bits to look the same, so the targets
# are scaled rather than the frame rate being thrown away: 60fps is something
# the operator chose on purpose and something a viewer notices immediately.
#
# 360p exists because it is the rung that works on a bad connection in a bus,
# and a viewer who can watch at all will stay. 2160p exists because a viewer
# on wifi paid for a 4K phone.
LADDER_H=(360 480 720 1080 1440 2160)
LADDER_K=(600 1000 2000 3800 7000 12000)

# A long film's top rung costs hours of CPU for an audience that mostly
# cannot receive it. Above forty minutes the ladder stops at 1080p — the
# original is still in the bucket and still served to anyone whose connection
# measures high enough for it.
MAX_H=2160
if [ "$DUR_I" -gt 2400 ]; then MAX_H=1080; fi

FPSMUL=100
if python3 -c "import sys; sys.exit(0 if float('$FPS') > 40 else 1)"; then FPSMUL=135; fi

# ── A RUNG MUST BE MEANINGFULLY SMALLER THAN THE FILE IT COMES FROM ──────
#
# Found in the real data rather than reasoned about: a 96 MB ten-minute film
# at 1.3 megabits produced a ladder of 157 MB. Every rung was DEARER to store
# than it was worth, and the top one — 720p at 1.04 Mbps against a 1.3 Mbps
# original — was a re-encode of an already-light file, so it cost storage,
# cost encoder time, and looked WORSE than the thing it was made from.
#
# The ladder exists to make a heavy file streamable. A file that is already
# streamable does not need one, and eighty per cent is where "smaller" stops
# being worth a second copy: below that a rung genuinely helps a weak
# connection, above it the original is the better answer in every respect.
SRC_BYTES="$(stat -c%s "$src")"
SRC_KBPS="$(python3 -c "print(max(1, round($SRC_BYTES*8/max(1,$DUR_I)/1000)))")"
echo "source is ${SRC_KBPS} kbps"
CEILING=$(( SRC_KBPS * 80 / 100 ))

for i in "${!LADDER_H[@]}"; do
  h="${LADDER_H[$i]}"
  k="${LADDER_K[$i]}"

  # NEVER UPSCALE. A 480p master re-encoded to 1080p is a bigger file of the
  # same picture, which is the exact opposite of the job.
  [ "$h" -gt "$SRC_H" ] && continue
  [ "$h" -gt "$MAX_H" ] && continue

  k=$(( k * FPSMUL / 100 ))

  # Not worth making: this rung asks for as much as the original, or more.
  if [ "$k" -ge "$CEILING" ]; then
    echo "${h}p at ${k}k is not smaller than the source (${SRC_KBPS}k) - skipped"
    continue
  fi

  url="$(python3 -c "import json,os; print(json.loads(os.environ['PUT_BASE']).get('$h',''))")"
  if [ -z "$url" ]; then echo "no upload url for ${h}p — skipped"; continue; fi

  out="$work/${h}.mp4"
  echo "::group::Encode ${h}p at ${k}k"
  # -crf 23 with a maxrate cap: quality-driven where the content is easy,
  # hard-limited where it is not. `-g` two seconds keeps seeking responsive
  # and is what a segmenter would want if this ever becomes HLS.
  gop="$(python3 -c "print(max(24, round(float('$FPS')*2)))")"
  ffmpeg -nostdin -y -hide_banner -loglevel warning -stats -i "$src" \
    -vf "${TONEMAP}scale=-2:${h}:flags=bicubic,format=yuv420p" \
    -c:v libx264 -preset veryfast -crf 23 \
    -maxrate "${k}k" -bufsize "$(( k * 2 ))k" \
    -g "$gop" -keyint_min "$gop" -sc_threshold 0 \
    -profile:v high -pix_fmt yuv420p \
    -c:a aac -b:a 128k -ac 2 -ar 48000 \
    -movflags +faststart \
    "$out"
  echo "::endgroup::"

  bytes="$(stat -c%s "$out")"
  real_k="$(python3 -c "print(max(1, round($bytes*8/max(1,$DUR_I)/1000)))")"
  echo "${h}p -> $(( bytes / 1024 / 1024 )) MB, ${real_k} kbps"

  echo "::group::Upload ${h}p"
  curl -fsS --retry 3 --retry-delay 5 -H 'Expect:' \
    -H 'Content-Type: video/mp4' -T "$out" "$url" >/dev/null
  echo "::endgroup::"

  PUT_URL="$url" python3 - "$results" "$h" "$real_k" "$bytes" "$FPS" <<'PY'
import json, os, sys, urllib.parse
path, h, k, b, fps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
u = urllib.parse.urlsplit(os.environ['PUT_URL'])
key = urllib.parse.unquote('/'.join(u.path.lstrip('/').split('/')[1:]))
rows = json.load(open(path))
rows = [r for r in rows if r['height'] != h]
rows.append({'height': h, 'kbps': k, 'object_key': key, 'bytes': b, 'fps': fps})
rows.sort(key=lambda r: r['kbps'])
json.dump(rows, open(path, 'w'))
PY
  NOTE="${h}p done" report
  rm -f "$out"
done

# A file that needed no rung at all is FINISHED, not failed. The app plays
# the original, which was always the right answer for it — but the row has to
# say so, or the console shows a permanent error for a video that is fine.
if [ "$(python3 -c "import json;print(len(json.load(open('$results'))))")" = "0" ]; then
  NOTE="already light - no rung would be smaller" report
else
  NOTE="complete" report
fi
echo "ladder:"; cat "$results"
