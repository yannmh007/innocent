#!/usr/bin/env bash
# A feature-length lab film from open films, encoded the way the transcode
# ladder encodes a catalogue film — and how long that took.
#
#     make_long_film.sh DIR REPORT
#
# WHY. The stream A/B's two-and-a-half-minute test pattern never showed what a
# long film does: its index (`moov`) grows with the running time — a few MB
# for two hours, all of which the player reads before the first frame — and a
# seek into the middle lands a gigabyte in. Real pictures also encode nothing
# like a test pattern. So: the Blender Foundation's open films (Big Buck
# Bunny, Sintel, Tears of Steel; CC-BY, © Blender Foundation |
# www.blender.org), each encoded with tool/transcode.sh's settings for the
# 1080p and 720p rungs, then played over and over without re-encoding to
# at least two and a half hours. Lab only: nothing here is published.
#
# Writes DIR/long_1080.mp4, DIR/long_720.mp4, and the same two as
# fragmented MP4 to compare (long_1080frag.mp4, long_720frag.mp4); to REPORT: what was
# fetched, how fast it encoded (times real time — the ladder's cost for a
# film), how big each file and its index are, and how long ten cover frames
# took over HTTP (tool/frames.py's own grab, as the transcode runner does).
set -uo pipefail
DIR=$1
REPORT=$2
mkdir -p "$DIR/src"
say() { echo "$*" | tee -a "$REPORT"; }

# Each film from the first address that answers. Blender's own server.
fetch() {
  local out=$1; shift
  [ -s "$out" ] && { say "have $(basename "$out")"; return 0; }
  for url in "$@"; do
    if curl -fsSL --retry 3 --connect-timeout 20 -o "$out" "$url"; then
      say "fetched $(basename "$url") ($(du -h "$out" | cut -f1))"
      return 0
    fi
  done
  say "could not fetch $(basename "$out")"
  rm -f "$out"
  return 1
}
fetch "$DIR/src/bbb" \
  https://download.blender.org/demo/movies/BBB/bbb_sunflower_1080p_30fps_normal.mp4 \
  https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_1080p_h264.mov \
  https://download.blender.org/peach/bigbuckbunny_movies/big_buck_bunny_720p_h264.mov \
  https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_640x360.m4v
fetch "$DIR/src/sintel" \
  https://download.blender.org/durian/movies/sintel-2048-surround.mp4 \
  https://download.blender.org/durian/movies/sintel-1280-surround.mp4 \
  https://download.blender.org/durian/movies/Sintel.2010.1080p.mkv
fetch "$DIR/src/tos" \
  https://download.blender.org/demo/movies/ToS/tears_of_steel_1080p.mov \
  https://download.blender.org/demo/movies/ToS/ToS-4k-1920.mov \
  https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov

# tool/transcode.sh's rung settings: CRF 23 under a maxrate cap, veryfast,
# a keyframe every two seconds, AAC stereo, faststart. Letterboxed to one
# frame size so the films join without re-encoding. One decode feeds both
# rungs, as the ladder's cost is the encoding.
: > "$DIR/list_1080.txt"; : > "$DIR/list_720.txt"
total_s=0; enc_s=0
for f in bbb sintel tos; do
  [ -f "$DIR/src/$f" ] || continue
  d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$DIR/src/$f" | cut -d. -f1)
  t0=$(date +%s)
  fit() { echo "scale=$1:$2:force_original_aspect_ratio=decrease:flags=bicubic,pad=$1:$2:(ow-iw)/2:(oh-ih)/2,setsar=1,format=yuv420p"; }
  if ffmpeg -nostdin -y -hide_banner -loglevel error -i "$DIR/src/$f" \
      -filter_complex "[0:v]fps=24,split=2[a][b];[a]$(fit 1920 1080)[v1];[b]$(fit 1280 720)[v2]" \
      -map '[v1]' -map 0:a:0 -c:v libx264 -preset veryfast -crf 23 -maxrate 3800k -bufsize 7600k \
        -g 48 -keyint_min 48 -sc_threshold 0 -profile:v high \
        -c:a aac -b:a 128k -ac 2 -ar 48000 -movflags +faststart "$DIR/${f}_1080.mp4" \
      -map '[v2]' -map 0:a:0 -c:v libx264 -preset veryfast -crf 23 -maxrate 2000k -bufsize 4000k \
        -g 48 -keyint_min 48 -sc_threshold 0 -profile:v high \
        -c:a aac -b:a 128k -ac 2 -ar 48000 -movflags +faststart "$DIR/${f}_720.mp4"; then
    took=$(( $(date +%s) - t0 ))
    say "encoded $f: ${d}s of film in ${took}s for 1080p+720p ($(python3 -c "print(round($d/max(1,$took),2))")x real time)"
    total_s=$((total_s + d)); enc_s=$((enc_s + took))
    echo "file '$DIR/${f}_1080.mp4'" >> "$DIR/list_1080.txt"
    echo "file '$DIR/${f}_720.mp4'" >> "$DIR/list_720.txt"
  else
    say "encode of $f FAILED"
  fi
  rm -f "$DIR/src/$f"
done
[ "$total_s" -gt 0 ] || { say "no film could be made"; exit 1; }
say "all: ${total_s}s of film in ${enc_s}s ($(python3 -c "print(round($total_s/max(1,$enc_s),2))")x real time, 1080p+720p together)"

# Over and over, joined without re-encoding, to at least 150 minutes: a
# feature's length, a feature's index.
loops=$(( (9000 + total_s - 1) / total_s ))
say "joined $loops times over"
for h in 1080 720; do
  for _ in $(seq 1 "$loops"); do cat "$DIR/list_$h.txt"; done > "$DIR/loop_$h.txt"
  ffmpeg -nostdin -y -hide_banner -loglevel error -f concat -safe 0 -i "$DIR/loop_$h.txt" \
    -c copy -movflags +faststart "$DIR/long_$h.mp4" || say "join of ${h}p FAILED"
done
rm -f "$DIR"/bbb_*.mp4 "$DIR"/sintel_*.mp4 "$DIR"/tos_*.mp4

# The same films as FRAGMENTED MP4, exactly as tool/transcode.sh now writes
# the ladder (CMAF: six-second fragments cut at keyframes, a global sidx, no
# trailer), so the front of the file holds a few kilobytes of index instead
# of megabytes. The *frag profiles play these beside their faststart twins.
for h in 1080 720; do
  [ -f "$DIR/long_$h.mp4" ] || continue
  ffmpeg -nostdin -y -hide_banner -loglevel error -i "$DIR/long_$h.mp4" -c copy \
    -min_frag_duration 6000000 \
    -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx+cmaf+skip_trailer \
    "$DIR/long_${h}frag.mp4" \
    || say "fragmented remux of ${h}p FAILED"
done

# What the player has to read before anything else: the top-level boxes.
for h in 1080 720 1080frag 720frag; do
  f="$DIR/long_$h.mp4"
  [ -f "$f" ] || continue
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" | cut -d. -f1)
  kbps=$(ffprobe -v error -show_entries format=bit_rate -of csv=p=0 "$f")
  boxes=$(python3 - "$f" <<'PY'
import struct, sys
out, at = [], 0
with open(sys.argv[1], 'rb') as fh:
    while len(out) < 6:
        fh.seek(at)
        head = fh.read(16)
        if len(head) < 8:
            break
        size, kind = struct.unpack('>I4s', head[:8])
        if size == 1:
            size = struct.unpack('>Q', head[8:16])[0]
        out.append('%s %.2f MB at %.1f MB' % (kind.decode('latin1'), size / 1048576, at / 1048576))
        if size < 8:
            break
        at += size
print(' | '.join(out))
PY
)
  say "long_${h}.mp4: $(du -h "$f" | cut -f1), $((dur / 60)) min, $((kbps / 1000)) kbps; boxes: $boxes"
done

# Ten cover frames from the long film over HTTP, as the transcode runner takes
# them from R2 (tool/frames.py: seek before input, 640 px).
if [ -f "$DIR/long_1080.mp4" ]; then
  python3 tool/netlab/range_server.py "$DIR/long_1080.mp4" 47130 &
  rs=$!
  sleep 1
  python3 - "$DIR" <<'PY' | tee -a "$REPORT"
import os, sys, time
sys.path.insert(0, 'tool')
import frames
src = 'http://127.0.0.1:47130/film.mp4'
dur, _ = frames.probe(src)
t0 = time.time()
ok = 0
for i, at in enumerate(frames.frame_times(dur)):
    out = os.path.join(sys.argv[1], 'frame%d.jpg' % i)
    s = time.time()
    good = frames.grab(src, at, out)
    ok += good
    print('frame %d at %ds: %s in %.1fs' % (i, at, 'ok' if good else 'FAILED', time.time() - s))
print('cover frames: %d of 10 in %.1fs for a %d min film' % (ok, time.time() - t0, (dur or 0) / 60))
PY
  kill "$rs" 2>/dev/null || true
  rm -f "$DIR"/frame*.jpg
fi
df -h "$DIR" | tail -1 | tee -a "$REPORT"
