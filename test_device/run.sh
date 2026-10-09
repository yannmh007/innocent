#!/usr/bin/env bash
# Runs on the emulator host (see .github/workflows/device-lab.yml): installs the
# release APK, applies the network profile, drives the app with Maestro, and
# writes what it saw and measured to ./out. Nothing here may print a signed
# URL — the results are committed to a public repository.
set -uo pipefail
source test_device/config.env
PKG=com.innocent.media
OUT=$PWD/out
mkdir -p "$OUT/shots"
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/steps.txt"; }

adb wait-for-device
log "device: $(adb shell getprop ro.product.model) / Android $(adb shell getprop ro.build.version.release) / ABIs $(adb shell getprop ro.product.cpu.abilist)"

log "install"
adb install -r -g app.apk > "$OUT/install.txt" 2>&1 || { log "INSTALL FAILED"; cat "$OUT/install.txt"; }

log "network: speed $NET_SPEED kbit/s, delay $NET_DELAY ms"
adb emu network speed "$NET_SPEED" || true
adb emu network delay "$NET_DELAY" || true

# LOSS, WHICH THE EMULATOR'S OWN SHAPING CANNOT ADD. Speed and delay alone
# leave a single TCP connection unhurt; on a real mobile line it is loss that
# holds one connection to a fraction of the meter. The emulator's traffic
# leaves through this host (QEMU re-originates each connection here), so
# dropping a share of the packets ARRIVING on the host's interface is loss on
# the very connections the app opened. Removed again at the end of the run.
LOSS_DEV=""
if [ -n "${NET_LOSS:-}" ]; then
  LOSS_DEV=$(ip route | awk '/^default/ {print $5; exit}')
  if sudo modprobe ifb 2>/dev/null && sudo ip link add ifb0 type ifb 2>/dev/null; then
    sudo ip link set ifb0 up
    sudo tc qdisc add dev "$LOSS_DEV" handle ffff: ingress
    sudo tc filter add dev "$LOSS_DEV" parent ffff: protocol ip u32 match u32 0 0 \
      action mirred egress redirect dev ifb0
    sudo tc qdisc add dev ifb0 root netem loss "$NET_LOSS"
    log "network: $NET_LOSS of incoming packets dropped on $LOSS_DEV"
  else
    log "network: could not add loss (no ifb) — speed and delay only"
    LOSS_DEV=""
  fi
fi

# Bytes received by the whole device, every two seconds, alongside the app's
# CPU and memory — the ground truth to hold the app's own speed figure to.
sampler() {
  while true; do
    rx=$(adb shell cat /proc/net/dev 2>/dev/null | awk -F'[: ]+' 'NR>2 && $2!="lo" {s+=$3} END{print s+0}')
    top=$(adb shell top -b -n 1 -o PID,%CPU,RES,ARGS 2>/dev/null | grep -m1 "$PKG" | awk '{print $2" "$3}')
    temp=$(adb shell dumpsys battery 2>/dev/null | awk '/temperature/ {print $2}')
    echo "$(date +%s) rx=$rx cpu_res=${top:-none} batt_temp=${temp:-?}"
    sleep 2
  done
}
sampler > "$OUT/samples.txt" 2>&1 &
SAMPLER=$!

# The whole run's log, streamed to the host as it happens: the device's ring
# buffer keeps about a minute of this app, which is how the first traced run
# came back empty.
adb logcat -G 16M >/dev/null 2>&1 || true
adb logcat -c || true
adb logcat -v time > "$OUT/logcat_raw.txt" 2>&1 &
LOGCAT=$!

# The emulator's own launcher sometimes ANRs while the image settles, and its
# dialog sits over the app and eats every tap. Hide system error dialogs and
# give the image a moment before measuring anything.
adb shell settings put global hide_error_dialogs 1 || true
# Android's one-time "Viewing full screen — swipe down to exit" card covers
# the whole player the first time it goes immersive.
adb shell settings put secure immersive_mode_confirmations confirmed || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
sleep 20
adb shell input keyevent KEYCODE_HOME

# A phone like the owner's: three-button navigation (a 48 dp bar, not the
# gesture handle) and a punch-hole camera, so the player's insets are the
# ones MX's screenshots were taken with.
if [ "${PHONE_LIKE_OWNER:-0}" = 1 ]; then
  # enable-exclusive, not enable: "enable" left the gestural overlay on as
  # well, and the bar came out 3-button in looks but gesture-sized (24 dp,
  # run 37216341225) where a real 3-button bar is 48 dp.
  adb shell cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
  adb shell cmd overlay enable-exclusive --category com.android.internal.display.cutout.emulation.hole >/dev/null 2>&1 || true
  sleep 5
  log "overlays: $(adb shell cmd overlay list 2>/dev/null | grep -E 'navbar|cutout' | grep -F '[x]' | tr -d '\r' | tr '\n' ' ')"
  log "nav bar: $(adb shell dumpsys window 2>/dev/null | grep -m3 -oE 'navigationBars[^,]*frame=[^ ]*' | tr '\n' ' ')"
fi

# A LIBRARY LIKE A REAL PHONE'S. The emulator starts with no videos, and an
# app with nothing to list does nothing — which is how a Video tab that kept a
# real phone at 69 % CPU looked idle here. When the workflow made one
# (LIBRARY > 0), push it and have MediaStore index it.
if [ -d lib_media ]; then
  log "library: pushing $(find lib_media -type f | wc -l) files"
  adb push lib_media/DCIM /sdcard/ >/dev/null 2>&1
  adb push lib_media/Download /sdcard/ >/dev/null 2>&1
  adb push lib_media/Movies /sdcard/ >/dev/null 2>&1
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  sleep 25
  log "library: MediaStore lists $(adb shell content query --uri content://media/external/video/media --projection _id 2>/dev/null | grep -c Row) videos"
fi

# Which thread of the app is using the CPU right now: two readings of top,
# five seconds apart, the second kept. Called at the end of each perf phase.
# Turn the screen and wait until it has turned. The setting is applied
# asynchronously: without the wait each flow ran in the orientation the
# previous one had asked for (run 37214751686).
rotate() {
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation "$1"
  adb shell wm user-rotation lock "$1" >/dev/null 2>&1 || true
  for _ in $(seq 1 20); do
    cur=$(adb shell dumpsys window 2>/dev/null | grep -m1 -oE 'mCurrentRotation=(ROTATION_)?[0-9]+' | grep -oE '[0-9]+$')
    case "$1:$cur" in 0:0|1:1|1:90) break ;; esac
    sleep 1
  done
  sleep 2
  log "rotation asked $1, now ${cur:-?}"
}

threads() {
  local pid
  pid=$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')
  [ -n "$pid" ] || { echo "(app not running)"; return; }
  # The first screen of `top` counts since the thread started; the second,
  # five seconds later, is the one that says what is happening now.
  adb shell top -H -b -n 2 -d 5 -m 25 -p "$pid" 2>/dev/null | tail -32
}

# Test Lab's playback measurement, rehearsed here: the same TEST_LOOP launch
# a lab APK answers there (src/lab/AndroidManifest.xml), with the same film
# path. Checks the script reaches the player before real-phone quota is spent.
if [ "${LOOP:-0}" = 1 ] && [ -f "lib_media/Movies/Perf Test/aaa_play_720p.mp4" ]; then
  log "game loop rehearsal"
  adb push "lib_media/Movies/Perf Test/aaa_play_720p.mp4" /sdcard/Download/innocent_lab_play.mp4 >/dev/null 2>&1
  adb shell am force-stop "$PKG"
  adb shell pm clear "$PKG" >/dev/null 2>&1 || true
  adb shell pm grant "$PKG" android.permission.READ_MEDIA_VIDEO >/dev/null 2>&1 || true
  adb shell am start -a com.google.intent.action.TEST_LOOP -t application/javascript -n "$PKG/.MainActivity" >/dev/null 2>&1
  sleep 25
  adb exec-out screencap -p > "$OUT/shots/50_loop_25s.png"
  sleep 150
  log "game loop rehearsal done"
fi

log "cold start"
adb shell am force-stop "$PKG"
adb shell am start -W -n "$PKG/.MainActivity" > "$OUT/cold_start.txt" 2>&1
grep -E "TotalTime|WaitTime|Status" "$OUT/cold_start.txt" | tee -a "$OUT/steps.txt"
sleep 10
adb exec-out screencap -p > "$OUT/shots/00_cold_start.png"

# THE STREAM A/B's FILM AND ITS LINE. A film the runner makes (about 6 Mbit/s
# of 720p — a mid-quality catalogue film), served with Range from 127.0.0.1
# and put behind netem on that one port: delay, loss and a rate cap, the way
# bench/stream-bench.yml does for the proxy alone. The emulator reaches it at
# 10.0.2.2. Only this server's packets are shaped; nothing else on the runner.
STREAM_PORT=47124
case " $FLOWS " in *" streamab_"*)
  if command -v ffmpeg >/dev/null 2>&1; then
    ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=24 \
      -f lavfi -i sine=frequency=330 -t 150 -c:v libx264 -preset veryfast \
      -b:v 6000k -maxrate 6000k -bufsize 12000k -pix_fmt yuv420p -c:a aac -b:a 96k \
      -movflags +faststart /tmp/stream_film.mp4
    log "stream film: $(du -h /tmp/stream_film.mp4 | cut -f1)"
    python3 tool/netlab/range_server.py /tmp/stream_film.mp4 "$STREAM_PORT" &
    RANGE_SERVER=$!
    sudo ip link set dev lo mtu 1500 >/dev/null 2>&1 || true
    if [ -n "${STREAM_NETEM:-}" ]; then
      sudo tc qdisc replace dev lo root handle 1: prio bands 5 2>/dev/null
      # shellcheck disable=SC2086
      sudo tc qdisc add dev lo parent 1:4 handle 40: netem $STREAM_NETEM limit 10000
      sudo tc filter add dev lo parent 1:0 protocol ip prio 1 u32 match ip sport "$STREAM_PORT" 0xffff flowid 1:4
      log "stream line: netem $STREAM_NETEM on port $STREAM_PORT"
    fi
  else
    log "stream A/B: no ffmpeg — skipped"
    FLOWS=$(for f in $FLOWS; do case "$f" in streamab_*) ;; *) echo -n "$f " ;; esac; done)
  fi ;;
esac

# THE LONG FILM (flows streamlong_PROFILE_LANES): two and a half hours of open
# films at the ladder's 1080p and 720p rungs, made before the emulator booted
# (tool/netlab/make_long_film.sh, into LONG_FILM_DIR). Each flow puts the line
# of one Myanmar profile in front of it — config.env PROFILE_<name>: the rung
# to play, one-way delay (both ways, so the round trip is twice it), loss on
# the film's packets and a rate cap — plays from a fresh install with N lanes,
# then jumps to the middle of the film (`lab_seek`) and plays on. The trail's
# first frame, rebuffer and stretch lines say how each went.
LONG_PORT=47125
shape_long() { # delay loss rate [queue, packets]
  sudo tc qdisc del dev lo root 2>/dev/null || true
  sudo tc qdisc add dev lo root handle 1: prio bands 5
  # shellcheck disable=SC2086
  sudo tc qdisc add dev lo parent 1:4 handle 40: netem delay "$1" loss "$2" rate "$3" limit "${4:-10000}"
  sudo tc qdisc add dev lo parent 1:5 handle 50: netem delay "$1" limit 10000
  sudo tc filter add dev lo parent 1:0 protocol ip prio 1 u32 match ip sport "$LONG_PORT" 0xffff flowid 1:4
  sudo tc filter add dev lo parent 1:0 protocol ip prio 2 u32 match ip dport "$LONG_PORT" 0xffff flowid 1:5
}
case " $FLOWS " in *" streamlong_"*)
  LONG_DIR=${LONG_FILM_DIR:-/mnt/lab_films}
  if [ -f "$LONG_DIR/long_1080.mp4" ] && command -v ffprobe >/dev/null 2>&1; then
    LONG_DUR=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$LONG_DIR/long_1080.mp4" | cut -d. -f1)
    python3 tool/netlab/range_server.py "$LONG_DIR" "$LONG_PORT" &
    LONG_SERVER=$!
    sudo ip link set dev lo mtu 1500 >/dev/null 2>&1 || true
    log "long film: $((LONG_DUR / 60)) min in $LONG_DIR, served on $LONG_PORT"
  else
    log "long film: none was made — streamlong flows skipped"
    FLOWS=$(for f in $FLOWS; do case "$f" in streamlong_*) ;; *) echo -n "$f " ;; esac; done)
  fi ;;
esac

export PATH="$HOME/.maestro/bin:$PATH"
for flow in $FLOWS; do
  log "flow $flow"
  # The Maestro file a flow runs: its own name, unless a case below says
  # otherwise. Unset, `set -u` stopped every plain flow before Maestro ran
  # (run 37877954034: adb_own and me_grid "exit 1" in a second).
  file=$flow
  adb shell log -p i -t flutter "LAB phase $flow start" >/dev/null 2>&1 || true
  # The layout flows measure one orientation each; the player follows the
  # device by default, so turn the device.
  case "$flow" in
    layout_portrait|screens_large|gestures|screen_modes) rotate 0 ;;
    layout_landscape|screens_large_land|gestures_land|screen_modes_land) rotate 1 ;;
  esac
  # The perf flows sit still for a minute; read the threads in the middle of
  # it, while the Video tab idles or the film plays.
  case "$flow" in perf_*) ( sleep 40; { echo "== during $flow"; threads; } >> "$OUT/threads.txt" ) & ;; esac
  # STREAM A/B — no Maestro: the app is told which film to open and how many
  # connections the proxy may use (lab-only files, see LabStream), and the
  # trail says how it went. `streamab_N` plays the lab film through the real
  # stream proxy with N lanes, from a fresh install, on the shaped line.
  case "$flow" in streamab_*)
    n="${flow#streamab_}"
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo $n > $d/lab_lanes"
    adb shell "echo http://10.0.2.2:${STREAM_PORT}/film.mp4 > $d/lab_stream_url"
    log "stream A/B: lanes=$n; files $(adb shell ls "$d" 2>&1 | tr '\r\n' '  ')"
    adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep 30
    adb exec-out screencap -p > "$OUT/shots/7${n}_streamab_${n}_30s.png"
    sleep "${STREAM_SECONDS:-60}"
    adb exec-out screencap -p > "$OUT/shots/7${n}_streamab_${n}_end.png"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_stream_url" "$d/lab_lanes" >/dev/null 2>&1 || true
    continue
    ;;
  esac
  # NEW VIDEO — does a video copied onto the phone appear in the open Video
  # tab by itself, and how fast? MX Player shows it within seconds. The tab is
  # opened (flows/new_video_open.yaml), a clip is pushed into a folder that
  # does not exist yet, then a second into the same folder, and the screen's
  # accessibility tree is read every second for the folder tile's label
  # ("Folder: LabNew, N videos"). Nothing touches the screen meanwhile.
  case "$flow" in newvideo)
    ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/new_video_open.yaml" ) > "$OUT/maestro_$flow.txt" 2>&1
    log "flow $flow: Video tab open (maestro exit $?)"
    if ! command -v ffmpeg >/dev/null 2>&1; then log "newvideo: no ffmpeg — skipped"; continue; fi
    ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=640x360:rate=24 -t 6 \
      -c:v libx264 -preset veryfast -pix_fmt yuv420p /tmp/lab_new.mp4
    wait_for() { # $1 = label text, $2 = seconds allowed
      local t0 n=0
      t0=$(date +%s)
      while [ $n -lt "$2" ]; do
        adb shell uiautomator dump /sdcard/ui_nv.xml >/dev/null 2>&1
        if adb exec-out cat /sdcard/ui_nv.xml 2>/dev/null | grep -q "$1"; then
          echo $(( $(date +%s) - t0 )); return 0
        fi
        sleep 1; n=$((n + 1))
      done
      echo "never"; return 1
    }
    push_new() { # $1 = file name in Movies/LabNew
      adb shell mkdir -p /sdcard/Movies/LabNew
      adb push /tmp/lab_new.mp4 "/sdcard/Movies/LabNew/$1" >/dev/null 2>&1
      adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
        -d "file:///sdcard/Movies/LabNew/$1" >/dev/null 2>&1 || true
    }
    push_new lab_new_1.mp4
    s1=$(wait_for "Folder: LabNew, 1 video" 45)
    log "newvideo: a new folder with one video appeared after ${s1} s"
    adb exec-out screencap -p > "$OUT/shots/91_newvideo_first.png"
    push_new lab_new_2.mp4
    s2=$(wait_for "Folder: LabNew, 2 videos" 45)
    log "newvideo: a second video in that folder showed after ${s2} s"
    adb exec-out screencap -p > "$OUT/shots/92_newvideo_second.png"
    adb shell log -p i -t flutter "LAB newvideo first=${s1}s second=${s2}s" >/dev/null 2>&1 || true
    adb shell rm -rf /sdcard/Movies/LabNew >/dev/null 2>&1 || true
    rm -f /tmp/lab_new.mp4
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  case "$flow" in streamlong_*)
    rest="${flow#streamlong_}"
    n="${rest##*_}"
    prof="${rest%_*}"
    var="PROFILE_$prof"
    queue=""
    read -r rung delay loss rate queue <<< "${!var:-}"
    if [ -z "${rate:-}" ]; then log "flow $flow: no $var in config.env — skipped"; continue; fi
    if [ ! -f "$LONG_DIR/long_${rung}.mp4" ]; then log "flow $flow: no long_${rung}.mp4 — skipped"; continue; fi
    shape_long "$delay" "$loss" "$rate" "${queue:-10000}"
    log "long film: $prof — $rung, round trip 2x$delay, loss $loss, rate $rate, queue ${queue:-10000} packets; lanes=$n"
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo $n > $d/lab_lanes"
    adb shell "echo http://10.0.2.2:${LONG_PORT}/long_${rung}.mp4 > $d/lab_stream_url"
    # Three seeks, twenty seconds apart: the middle, a quarter in, three
    # quarters in. One seek a line was one sample of a noisy thing.
    a=${LONG_SEEK_AFTER:-45}
    adb shell "echo $a:$((LONG_DUR / 2)),$((a + 20)):$((LONG_DUR / 4)),$((a + 40)):$((LONG_DUR * 3 / 4)) > $d/lab_seek"
    adb shell log -p i -t flutter "LAB long $prof file=$rung rtt=2x$delay loss=$loss rate=$rate queue=${queue:-10000} lanes=$n" >/dev/null 2>&1 || true
    adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep $(( ${LONG_SEEK_AFTER:-45} + 2 ))
    adb exec-out screencap -p > "$OUT/shots/8_${flow}_before_seek.png"
    sleep "${LONG_AFTER_SEEK:-45}"
    adb exec-out screencap -p > "$OUT/shots/8_${flow}_end.png"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    adb shell am force-stop "$PKG"
    # Left behind, the lab files open the film over whatever runs next.
    adb shell rm -f "$d/lab_stream_url" "$d/lab_lanes" "$d/lab_seek" >/dev/null 2>&1 || true
    continue
    ;;
  esac
  ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/$file.yaml" ) > "$OUT/maestro_$flow.txt" 2>&1
  log "flow $flow exit $?"
  # STACKED DOUBLE TAP. Maestro needs most of a second per tap, longer than
  # the 0.6 s a run of taps stays open, so it can only ever make a plain
  # double tap. Four taps from one adb shell come a few hundred ms apart,
  # as a thumb's do: the trace should read "double tap right 1, 2, 3".
  case "$flow" in gestures)
    sleep 5 # the controls the flow's last tap showed hide again
    wh=$(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r')
    w=${wh%x*}; h=${wh#*x}
    x=$((w * 85 / 100)); y=$((h / 2))
    t0=$(date +%s%N)
    # `cmd input` runs in system_server: no app_process start per tap, so
    # the taps come ~0.15 s apart rather than ~0.5 s.
    adb shell "cmd input tap $x $y; sleep 0.1; cmd input tap $x $y; sleep 0.1; cmd input tap $x $y; sleep 0.1; cmd input tap $x $y"
    t1=$(date +%s%N)
    adb exec-out screencap -p > "$OUT/shots/97_stacked_taps.png"
    log "stacked taps at $x,$y: 4 taps in $(( (t1 - t0) / 1000000 )) ms"
    ;;
  esac
  # MX'S SCREEN BUTTON, pressed from here: Maestro spends seconds per tap
  # and the controls hide 4 s after the last touch. Show the controls, read
  # the button's bounds from Android's accessibility dump (the same node
  # TalkBack and Maestro see), then press its centre five times: Stretch,
  # Crop, 100%, Custom, back to Fit. The trace must read "screen <mode>"
  # after each press; a "gesture tap" instead means the press missed.
  case "$flow" in screen_modes|screen_modes_land)
    sfx=port; [ "$flow" = screen_modes_land ] && sfx=land
    wh=$(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r')
    w=${wh%x*}; h=${wh#*x}
    [ "$sfx" = land ] && { t=$w; w=$h; h=$t; }
    bounds=""
    for attempt in 1 2 3; do
      adb shell "cmd input tap $((w / 2)) $((h * 30 / 100))"
      sleep 0.6
      adb shell uiautomator dump /sdcard/ui_mode.xml >/dev/null 2>&1
      bounds=$(adb exec-out cat /sdcard/ui_mode.xml 2>/dev/null \
        | grep -o 'resource-id="player-screen-mode"[^>]*bounds="[^"]*"' \
        | grep -o 'bounds="[^"]*"' | head -1)
      if [ -n "$bounds" ]; then
        # The whole dump with the controls up: what TalkBack is told, to set
        # against the app's own view of it ("LAB sem" in lab_trace.txt).
        adb exec-out cat /sdcard/ui_mode.xml > "$OUT/ui_controls_$sfx.xml" 2>/dev/null || true
        break
      fi
      sleep 4.5 # they were up and that tap hid them; let them settle hidden
    done
    log "$flow: screen button $bounds (screen ${w}x${h}, attempt $attempt)"
    # Run 37280515740: the button's id came back on a full-screen node (its
    # name and id had merged into the node above; fixed in the app, run
    # 37308309328), so its centre was the video. If that recurs,
    # press where the button is drawn, measured on the lab's screenshots
    # (portrait 830,2280 of 1080x2400; landscape 2150,954 of
    # 2400x1080, run 37281576125).
    full="bounds=\"[0,0][${w},${h}]\""
    shown=1; [ -z "$bounds" ] && shown=0
    if [ -z "$bounds" ] || [ "$bounds" = "$full" ]; then
      if [ "$sfx" = port ]; then bounds="[$((w * 768 / 1000 - 10)),$((h * 950 / 1000 - 10))][$((w * 768 / 1000 + 10)),$((h * 950 / 1000 + 10))]"
      else bounds="[$((w * 896 / 1000 - 10)),$((h * 883 / 1000 - 10))][$((w * 896 / 1000 + 10)),$((h * 883 / 1000 + 10))]"; fi
      log "$flow: pressing the drawn button instead, $bounds"
      if [ $shown = 0 ]; then # the last tap hid them: bring them back
        adb shell "cmd input tap $((w / 2)) $((h * 30 / 100))"
        sleep 0.6
      fi
    fi
    if [ -n "$bounds" ]; then
      set -- $(echo "$bounds" | grep -o '[0-9]\+')
      bx=$(( ($1 + $3) / 2 )); by=$(( ($2 + $4) / 2 ))
      for m in stretch crop original custom fit; do
        adb shell "cmd input tap $bx $by"
        sleep 0.5
        adb exec-out screencap -p > "$OUT/shots/7x_mode_${m}_${sfx}.png"
        sleep 0.7
      done
      log "$flow: pressed $bx,$by five times"
      # Again, the controls still up from the last press: is the first dump
      # wrong only because the app had just been asked for its semantics?
      adb shell uiautomator dump /sdcard/ui_mode2.xml >/dev/null 2>&1
      adb exec-out cat /sdcard/ui_mode2.xml > "$OUT/ui_controls2_$sfx.xml" 2>/dev/null || true
    fi
    ;;
  esac
  case "$flow" in
  # PICTURE-IN-PICTURE ON LEAVING. The film is playing; Home must put it in
  # a PiP window by itself (Android 12+ auto-enter), still playing.
  screen_modes_land)
    adb shell input keyevent KEYCODE_HOME
    sleep 3
    adb exec-out screencap -p > "$OUT/shots/98_pip_after_home.png"
    pinned=$(adb shell dumpsys activity activities 2>/dev/null \
      | grep -ciE "mode=pinned|windowingMode=pinned|pinned")
    log "after Home: activities mentioning pinned=$pinned"
    adb shell dumpsys activity activities 2>/dev/null \
      | grep -iE "pinned|mResumedActivity" | head -8 >> "$OUT/pip.txt" || true
    adb shell dumpsys media_session 2>/dev/null | head -60 >> "$OUT/pip.txt" || true
    sleep 4
    adb exec-out screencap -p > "$OUT/shots/99_pip_later.png"
    ;;
  esac
  # Maestro has put screenshots in different places across versions.
  find test_device/flows "$OUT/maestro_out" "$HOME/.maestro/tests" -name '*.png' -newer test_device/config.env \
    -exec cp {} "$OUT/shots/" \; 2>/dev/null || true
  maestro hierarchy > "$OUT/hierarchy_after_$flow.json" 2>/dev/null || true
  # The same screen as Android's own accessibility dump sees it (what
  # TalkBack and Switch Access get), to compare with Maestro's view.
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 \
    && adb exec-out cat /sdcard/ui.xml > "$OUT/ui_after_$flow.xml" 2>/dev/null || true
done
adb shell dumpsys cpuinfo 2>/dev/null | head -40 > "$OUT/cpuinfo.txt" || true

if [ -n "${LONG_SERVER:-}" ]; then
  kill "$LONG_SERVER" 2>/dev/null || true
  sudo tc qdisc del dev lo root 2>/dev/null || true
fi
if [ -n "${RANGE_SERVER:-}" ]; then
  kill "$RANGE_SERVER" 2>/dev/null || true
  sudo tc qdisc del dev lo root 2>/dev/null || true
  rm -f /tmp/stream_film.mp4
fi
if [ -n "$LOSS_DEV" ]; then
  sudo tc qdisc del dev "$LOSS_DEV" ingress 2>/dev/null || true
  sudo ip link del ifb0 2>/dev/null || true
fi
kill $SAMPLER $LOGCAT 2>/dev/null
adb shell dumpsys meminfo "$PKG" > "$OUT/meminfo.txt" 2>&1
adb shell dumpsys gfxinfo "$PKG" > "$OUT/gfxinfo.txt" 2>&1
adb shell dumpsys activity processes "$PKG" | grep -iE "anr|crash" > "$OUT/anr_crash.txt" 2>&1 || true
# Logs, with anything that looks like a link or a token cut out.
# Native crashes: the tombstone says which library and which instruction.
adb root >/dev/null 2>&1; sleep 2
mkdir -p "$OUT/tombstones"
for t in $(adb shell ls /data/tombstones 2>/dev/null | tr -d '\r' | grep tombstone | grep -v '\.pb$'); do
  adb shell cat "/data/tombstones/$t" 2>/dev/null | head -150 > "$OUT/tombstones/$t.txt"
done
# The app's own trail (lab builds echo PlaybackLog to logcat): what each
# download pass did, when the viewer started and stopped watching.
grep -o 'LAB .*' "$OUT/logcat_raw.txt" | sed -E 's#https?://[^ "]+#<url>#g' > "$OUT/lab_trace.txt" || true
sed -E 's#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' "$OUT/logcat_raw.txt" \
  | grep -iE "innocent|flutter|mpv|AndroidRuntime|FATAL|ANR|crash|exception| DEBUG|libc" > "$OUT/logcat.txt"
rm -f "$OUT/logcat_raw.txt"

# Screenshots at phone-half size: enough to read, small enough to commit.
rm -rf "$OUT/maestro_out"
find "$OUT" -name '*.png' -exec mogrify -resize 540x {} \; 2>/dev/null || true
# SCREENSHOTS NEVER GO INTO THE REPOSITORY IN THE CLEAR. They show the
# catalogue, which is adult material, and this repository is public — GitHub
# does not allow that content. Encrypted with LAB_RESULTS_KEY (an Actions
# secret) they are unreadable to anyone without it; with no key set they are
# not kept at all.
if [ -d "$OUT/shots" ]; then
  if [ -n "${LAB_RESULTS_KEY:-}" ]; then
    tar -czf - -C "$OUT" shots | openssl enc -aes-256-cbc -pbkdf2 -salt \
      -pass env:LAB_RESULTS_KEY -out "$OUT/shots.tar.gz.enc"
  else
    echo "screenshots not kept: LAB_RESULTS_KEY is not set" > "$OUT/shots_not_kept.txt"
  fi
  rm -rf "$OUT/shots"
fi
log "done"
