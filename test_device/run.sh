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
#
# IT HAD NOT WORKED, AND SAID IT HAD (found 7 Nov 2026). The runner's eth0
# already holds a clsact qdisc, which owns handle ffff:: adding an ingress
# qdisc there is refused ("Exclusivity flag on, cannot modify") and a filter
# on parent ffff: is invalid on clsact ("RTNETLINK answers: Invalid
# argument") — and the line "dropped on eth0" was logged regardless. So the
# filter now goes on the device's ingress hook, which ingress and clsact
# both have, under a priority of its own (removed alone at the end), and
# SHAPED says whether it took: a flow that needs the line shaped reads it.
LOSS_DEV=""
SHAPED=0
OUR_INGRESS=0
if [ -n "${NET_LOSS:-}" ]; then
  LOSS_DEV=$(ip route | awk '/^default/ {print $5; exit}')
  if sudo modprobe ifb 2>/dev/null && { ip link show ifb0 >/dev/null 2>&1 || sudo ip link add ifb0 type ifb 2>/dev/null; }; then
    sudo ip link set ifb0 up
    if ! tc qdisc show dev "$LOSS_DEV" | grep -qE 'qdisc (ingress|clsact)'; then
      sudo tc qdisc add dev "$LOSS_DEV" handle ffff: ingress && OUR_INGRESS=1
    fi
    log "network: $LOSS_DEV has $(tc qdisc show dev "$LOSS_DEV" | grep -oE 'qdisc (ingress|clsact)' | head -1)"
    if sudo tc filter add dev "$LOSS_DEV" ingress pref 49 protocol ip u32 match u32 0 0 \
         action mirred egress redirect dev ifb0 \
       && sudo tc qdisc replace dev ifb0 root netem loss "$NET_LOSS"; then
      # SAY IT ONLY IF PACKETS PASS (run 42363479008: the filter was taken
      # and not one packet reached ifb0 — the runner's own filters on
      # clsact come first). Some traffic, then ifb0's own count.
      curl -s -o /dev/null --max-time 20 'https://speed.cloudflare.com/__down?bytes=200000' || true
      passed=$(tc -s qdisc show dev ifb0 | grep -oE 'Sent [0-9]+ bytes' | head -1 | grep -oE '[0-9]+' || echo 0)
      if [ "${passed:-0}" -gt 100000 ]; then
        SHAPED=1
        log "network: $NET_LOSS of incoming packets dropped on $LOSS_DEV (through ifb0: $passed bytes seen)"
      else
        log "network: the redirect into ifb0 was accepted but only ${passed:-0} bytes reached it — NO loss applies (ingress filters there: $(tc filter show dev "$LOSS_DEV" ingress 2>/dev/null | grep -oE 'pref [0-9]+ [a-z0-9]+' | sort -u | tr '\n' ' '))"
        sudo tc filter del dev "$LOSS_DEV" ingress pref 49 2>/dev/null || true
      fi
    else
      log "network: the ifb0 redirect could NOT be set — no loss, no rate cap; speed and delay only"
    fi
  else
    log "network: could not add loss (no ifb) — speed and delay only"
    LOSS_DEV=""
  fi
fi

# THE LAB LINE (flow weakline): see the flow and tool/netlab/line_relay.py.
# line_up starts the relay, shapes lo and redirects this user's HTTPS to the
# relay; line_rate RATE|off sets the cap; line_down undoes all of it and is
# safe to call twice. LINE_DELAY is each way (the round trip is twice it,
# plus the runner's own), LINE_LOSS is on what comes in.
LINE_PORT=47126
LINE_DELAY=${WEAK_DELAY:-60ms}
LINE_LOSS=${NET_LOSS:-0.5%}
LINE_UP=0
LINE_RULE=(OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(id -u)"
  -m comment --comment innocent-lab-line -j REDIRECT --to-ports "$LINE_PORT")
line_up() {
  sudo python3 tool/netlab/line_relay.py "$LINE_PORT" > "$OUT/relay.txt" 2>&1 &
  LINE_UP=1
  local i
  for i in $(seq 1 40); do
    ss -ltn "sport = :$LINE_PORT" 2>/dev/null | grep -q LISTEN && break
    sleep 0.25
  done
  ss -ltn "sport = :$LINE_PORT" 2>/dev/null | grep -q LISTEN || { log "line: the relay did not start"; return 1; }
  sudo ip link set dev lo mtu 1500 || return 1
  # One packet is one packet: without this, lo hands netem 64 KB at a time,
  # and one loss is forty packets lost.
  sudo ethtool -K lo tso off gso off gro off >/dev/null 2>&1 || log "line: lo offloads could not be turned off"
  sudo tc qdisc del dev lo root 2>/dev/null || true
  sudo tc qdisc add dev lo root handle 1: prio bands 5 || return 1
  sudo tc qdisc add dev lo parent 1:4 handle 40: netem delay "$LINE_DELAY" loss "$LINE_LOSS" limit 300 || return 1
  sudo tc qdisc add dev lo parent 1:5 handle 50: netem delay "$LINE_DELAY" limit 10000 || return 1
  # Toward the emulator: from 443 once the relay's answer is un-NATed, or
  # from the relay's port if it is seen before; away from it: to the relay.
  sudo tc filter add dev lo parent 1:0 protocol ip prio 1 u32 match ip sport 443 0xffff flowid 1:4 || return 1
  sudo tc filter add dev lo parent 1:0 protocol ip prio 2 u32 match ip sport "$LINE_PORT" 0xffff flowid 1:4 || return 1
  sudo tc filter add dev lo parent 1:0 protocol ip prio 3 u32 match ip dport "$LINE_PORT" 0xffff flowid 1:5 || return 1
  sudo iptables -t nat -A "${LINE_RULE[@]}" || return 1
  # Over IPv6 the redirect would not apply: refused, so v4 is used.
  sudo ip6tables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(id -u)" \
    -m comment --comment innocent-lab-line -j REJECT --reject-with tcp-reset 2>/dev/null || true
  log "line: this user's HTTPS through the relay on $LINE_PORT, shaped on lo (delay $LINE_DELAY each way, loss $LINE_LOSS)"
}
line_rate() {
  if [ "$1" = off ]; then
    sudo tc qdisc change dev lo parent 1:4 handle 40: netem delay "$LINE_DELAY" loss 100% limit 300
  else
    sudo tc qdisc change dev lo parent 1:4 handle 40: netem delay "$LINE_DELAY" loss "$LINE_LOSS" rate "$1" limit 300
  fi
}
# The whole line at once (flow ladderstart: a weak line and a plain one,
# pass by pass): delay each way, loss on what comes in, the cap.
line_shape() {
  sudo tc qdisc change dev lo parent 1:4 handle 40: netem delay "$1" loss "$2" rate "$3" limit 300
  sudo tc qdisc change dev lo parent 1:5 handle 50: netem delay "$1" limit 10000
}
line_down() {
  [ "$LINE_UP" = 1 ] || return 0
  LINE_UP=0
  while sudo iptables -t nat -D "${LINE_RULE[@]}" 2>/dev/null; do :; done
  while sudo ip6tables -D OUTPUT -p tcp --dport 443 -m owner --uid-owner "$(id -u)" \
    -m comment --comment innocent-lab-line -j REJECT --reject-with tcp-reset 2>/dev/null; do :; done
  # [y]: so the pattern does not match this pkill's own sudo.
  sudo pkill -TERM -f "line_rela[y].py $LINE_PORT" 2>/dev/null || true
  sudo tc qdisc del dev lo root 2>/dev/null || true
  sudo ethtool -K lo tso on gso on gro on >/dev/null 2>&1 || true
  sudo ip link set dev lo mtu 65536 2>/dev/null || true
  sleep 1
}
# THE LINE UP AND ITS CAP PROVED (flows weakline, weakjumps). 7 Nov 2026: the
# first A/B ran on a line nothing shaped. 600 KB under the collapse step's
# rate, timed, by this user — so through the relay, as the emulator's bytes
# go; a line more than half again faster than its cap is not the line these
# flows are for. Returns 1, the line down again, when it is not.
line_proved() {
  local flow=$1 probe_rate="900kbit" t0 t1 got kbps
  adb emu network speed full >/dev/null 2>&1 || true
  adb emu network delay none >/dev/null 2>&1 || true
  if ! line_up; then
    log "flow $flow: the lab line could not be set up — skipped, not run unshaped"
    line_down; return 1
  fi
  line_rate "$probe_rate"
  t0=$(date +%s%N)
  got=$(curl -s -o /dev/null -w '%{size_download}' --max-time 30 'https://speed.cloudflare.com/__down?bytes=600000' || echo 0)
  t1=$(date +%s%N)
  kbps=$(( got * 8 * 1000000 / ( (t1 - t0) / 1000 + 1 ) / 1000 ))
  log "$flow: the line under a $probe_rate cap measured $kbps kbps ($got bytes)"
  if [ "$got" -lt 100000 ] || [ "$kbps" -gt 1400 ]; then
    log "flow $flow: the cap did not hold ($kbps kbps, $got bytes, under $probe_rate) — skipped, not run unshaped"
    line_down; return 1
  fi
}

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
  adb shell am start -a com.google.intent.action.TEST_LOOP -t application/javascript \
    -d "file:///sdcard/Download/lab_loop.js" -n "$PKG/.MainActivity" >/dev/null 2>&1
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
# A cleared app asks for nothing the lab's flows cannot answer: run A
# (43675629684) lost a Back, and twelve minutes, to the media permission
# dialog of a fresh install.
lab_grants() {
  for perm in READ_MEDIA_VIDEO READ_MEDIA_AUDIO READ_MEDIA_IMAGES POST_NOTIFICATIONS; do
    adb shell pm grant "$PKG" "android.permission.$perm" >/dev/null 2>&1 || true
  done
}
# The lab's launch (Test Lab's game loop, scenario 3): the catalogue title
# named in lab_loop_title, through playMedia, the introduction skipped.
lab_loop_start() {
  adb shell am start -W -a com.google.intent.action.TEST_LOOP -t application/javascript \
    -d "file:///sdcard/Download/lab_loop.js" --ei scenario 3 -n "$PKG/.MainActivity" >/dev/null 2>&1
}

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
  # THE VAULT'S WAIT (1.64.79) — the cooling-off after wrong PINs counts time
  # since boot, so moving the phone's date forward must not end it. Part a
  # sets a PIN and earns the one-minute wait (ten misses); the date is then
  # moved two hours ahead (root: the google_apis image allows it); part b
  # opens the vault afresh and must still find the wait; once the minute has
  # passed on the real clock and the date is back, part c opens it with the
  # right PIN. Before 1.64.79 part b found no wait at all.
  case "$flow" in vault_lock)
    vault_part() {
      ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/$1.yaml" ) >> "$OUT/maestro_$flow.txt" 2>&1
    }
    vault_part vault_lock_a; ra=$?
    t0=$(date +%s)
    log "flow $flow: PIN set, ten misses (maestro exit $ra)"
    adb root >/dev/null 2>&1 || true
    adb wait-for-device
    adb shell settings put global auto_time 0 >/dev/null 2>&1 || true
    before=$(adb shell date +%s | tr -d '\r')
    adb shell date -u "$(date -u -d '+2 hours' +%m%d%H%M%Y.%S)" >/dev/null 2>&1 || true
    after=$(adb shell date +%s | tr -d '\r')
    log "vault: the phone's date moved $(( ${after:-0} - ${before:-0} )) s"
    vault_part vault_lock_b; rb=$?
    log "flow $flow: date moved, the wait still holds (maestro exit $rb)"
    # The minute, counted from the end of part a (after the tenth miss), and
    # a margin; then the date put back.
    left=$(( 75 - ($(date +%s) - t0) ))
    [ "$left" -gt 0 ] && sleep "$left"
    adb shell date -u "$(date -u +%m%d%H%M%Y.%S)" >/dev/null 2>&1 || true
    adb shell settings put global auto_time 1 >/dev/null 2>&1 || true
    vault_part vault_lock_c; rc=$?
    log "flow $flow: the wait over, the PIN opens it (maestro exit $rc)"
    adb unroot >/dev/null 2>&1 || true
    adb wait-for-device
    if [ "$ra$rb$rc" = 000 ]; then log "flow $flow exit 0"; else log "flow $flow exit 1"; fi
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
  # A LINE THAT COLLAPSES AND RECOVERS (flow weakline, 2026-11-07). The test
  # film from its start, played straight through, while the line steps
  # through WEAK_STEPS (rate:seconds ...; "off" is no line at all): a hard
  # cap, unlike `adb emu network speed`, which did not hold (run
  # 37967426588), with a 300-packet queue (about 2 s at 1.2 Mbit/s, the
  # buffering of a real mobile line, not the 100 s a default queue holds).
  # The verdict is the app's own trail between two markers: stalls, frozen
  # ms, longest, first frame. What a viewer feels when a line falls away
  # mid-film, which no other flow measured (docs/streaming_review_2026_11.md).
  #
  # THE LINE IS ON LOOPBACK (7 Nov 2026). It was netem on ifb0, fed from
  # eth0's ingress — and the runner's own clsact filters on eth0 take every
  # packet before ours: a 600 KB probe under a "900 kbit" cap came in at
  # 32 Mbit/s (run 42363479008), and the A/B runs before it were unshaped.
  # Now iptables sends this user's outgoing HTTPS (the emulator's: QEMU
  # opens each of its connections here) to tool/netlab/line_relay.py, which
  # opens the same connection as root and copies the bytes, TLS untouched;
  # what it sends back crosses lo, and netem on lo is the line — the way the
  # streamlong flows and stream-bench shape theirs. Only while this flow
  # runs (line_down; the workflow takes it down too if the run dies).
  case "$flow" in weakline)
    if [ -z "${CLIMB_TITLE:-}" ]; then log "flow weakline: no CLIMB_TITLE in config.env — skipped"; continue; fi
    # PROVE THE CAP FIRST (line_proved).
    line_proved weakline || continue
    # PASSES (8 Nov 2026, BACKLOG 5b). One play of the film says little about
    # its picture: runs F and G, one build on one line, spent 97 % at 360p
    # and 100 % at 480p — the first few readings decide it. So the film is
    # played once per word of WEAK_PASSES, each time from a cleared app (no
    # line remembered, the same unmeasured start), each word the rule the
    # master weighs rungs by (lab_peak: fragment or window; "-" leaves the
    # build's own). Interleaved, every variant meets the same runner and the
    # same hours of the line; the summary at the end is per variant.
    passes="${WEAK_PASSES:--}"
    steps="${WEAK_STEPS:-4mbit:40 900kbit:120 3mbit:100}"
    d="/sdcard/Android/data/$PKG/files"
    : > "$OUT/weakline.txt"
    : > "$OUT/weakline_ms.txt"
    : > "$OUT/weakline_passes.tsv"
    p=0
    for variant in $passes; do
      p=$((p + 1))
      adb shell am force-stop "$PKG"
      adb shell pm clear "$PKG" >/dev/null 2>&1 || true
      adb shell mkdir -p "$d" >/dev/null 2>&1
      adb shell "echo title:$CLIMB_TITLE > $d/lab_stream_url"
      if [ "$variant" != "-" ]; then adb shell "echo $variant > $d/lab_peak"; fi
      log "weakline pass $p ($variant): the test film from its start; the line in steps: $steps (delay $LINE_DELAY each way, loss $LINE_LOSS)"
      adb shell log -p i -t flutter "LAB weakline begin pass=$p peak=$variant" >/dev/null 2>&1 || true
      adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
      for step in $steps; do
        rate="${step%%:*}"; secs="${step##*:}"
        line_rate "$rate"
        adb shell log -p i -t flutter "LAB weakline line $rate for ${secs}s" >/dev/null 2>&1 || true
        log "weakline: line $rate for $secs s"
        sleep "$secs"
      done
      adb exec-out screencap -p > "$OUT/shots/9_weakline_end_$p.png"
      adb shell log -p i -t flutter "LAB weakline end pass=$p peak=$variant" >/dev/null 2>&1 || true
      sleep 2
      adb shell am force-stop "$PKG"
      wl="$OUT/weakline_$p.txt"
      awk -v b="LAB weakline begin pass=$p " -v e="LAB weakline end pass=$p " \
        'index($0,b){on=1} on{print} index($0,e){on=0}' "$OUT/logcat_raw.txt" \
        | grep -o 'LAB .*' | sed -E 's#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' > "$wl" || true
      cat "$wl" >> "$OUT/weakline.txt"
      # A stop under 250 ms is a BLIP (a frame or two, no spinner) and is
      # counted apart, as PlaybackQoe.visibleMs does: in runs 42358540751 and
      # 42360760676, 27 of 28 refills were 2-67 ms blips and counting them
      # with the one 2 s stop hid it (7 Nov 2026).
      grep -oE 'rebuffer end [0-9]+ ms' "$wl" | awk '{print $3}' > "$OUT/weakline_ms_$p.txt" || true
      cat "$OUT/weakline_ms_$p.txt" >> "$OUT/weakline_ms.txt"
      n=$(awk '$1>=250' "$OUT/weakline_ms_$p.txt" | wc -l | tr -d ' ')
      blips=$(awk '$1<250' "$OUT/weakline_ms_$p.txt" | wc -l | tr -d ' ')
      sum=$(awk '{s+=$1} END {print s+0}' "$OUT/weakline_ms_$p.txt")
      max=$(awk '$1>m{m=$1} END {print m+0}' "$OUT/weakline_ms_$p.txt")
      first=$(grep -oE 'first frame [0-9]+ ms' "$wl" | head -1 | grep -oE '[0-9]+' || true)
      first=${first:--}
      # The picture: how long each rung reached the screen (exo rung, the
      # decoder's input), from the first rung to the pass's last line.
      shares=$(awk '
        /^LAB +[0-9]+\.[0-9]+ / { t=$2+0; last=t }
        /^LAB +[0-9]+\.[0-9]+ exo rung [0-9]+p/ { r=$5; sub(/p$/,"",r); if (cur!="") tm[cur]+=t-at; cur=r; at=t }
        END { if (cur!="") tm[cur]+=last-at; tot=0; for (r in tm) tot+=tm[r];
              for (r in tm) printf "%d %d\n", r, (tot>0 ? 100*tm[r]/tot+0.5 : 0) }
      ' "$wl" | sort -nr | awk '{printf "%s%sp:%d%%", (NR>1?" ":""), $1, $2}')
      shares=${shares:--}
      log "weakline pass $p ($variant): first frame ${first} ms, stalls $n (>=250 ms), blips $blips, frozen ${sum} ms, longest ${max} ms, time ${shares}"
      grep -oE 'exo tracks .*peaks=[0-9,]+' "$wl" | head -1 | sed "s/^/weakline pass $p ($variant): /" | while read -r line; do log "$line"; done
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$variant" "$first" "$n" "$blips" "$sum" "$max" "$shares" >> "$OUT/weakline_passes.tsv"
      # And step by step: which part of the line each stop and rung belongs to.
      awk -v p="$p" '
        /LAB weakline line /   { i++; step[i]=$4; next }
        /rebuffer end [0-9]+ ms/ { for (k=1;k<=NF;k++) if ($k=="end") ms=$(k+1)+0
                                 if (ms>=250) { st[i]++; fr[i]+=ms; if (ms>lg[i]) lg[i]=ms } else bl[i]++ }
        /exo rung [0-9]+p/     { for (k=1;k<=NF;k++) if ($k=="rung") r=$(k+1); rg[i]=rg[i] (rg[i]==""?"":" ") r }
        END { for (j=1;j<=i;j++) printf "weakline pass %d step %d (%s): stalls %d, frozen %d ms, longest %d ms, blips %d, rungs %s\n",
                p, j, step[j], st[j], fr[j], lg[j], bl[j], (rg[j]==""?"-":rg[j]) }
      ' "$wl" | while read -r line; do log "$line"; done
      adb shell log -p i -t flutter "LAB weakline verdict pass=$p peak=$variant first=${first} stalls=$n blips=$blips frozen_ms=$sum longest_ms=$max time=${shares// /,}" >/dev/null 2>&1 || true
    done
    log "weakline: the line passed $(tc -s qdisc show dev lo | grep -A1 'netem 40:' | grep -oE 'Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+' | head -1)"
    line_down
    adb emu network speed "$NET_SPEED" >/dev/null 2>&1 || true
    adb emu network delay "$NET_DELAY" >/dev/null 2>&1 || true
    log "weakline: $(cat "$OUT/relay.txt" 2>/dev/null || echo 'relay: no counts')"
    # PER VARIANT: the passes' stops summed, and the share of time at each
    # rung as the mean over the passes with every pass's own in brackets —
    # the spread is the point: a variant is better only if its passes are.
    awk -F'\t' '
      { v=$2; np[v]++; st[v]+=$4; bl[v]+=$5; fr[v]+=$6; if ($7>lg[v]) lg[v]=$7
        if (!(v in seen)) { seen[v]=1; order[++nv]=v }
        split("", got); m=split($8, parts, " ")
        for (k=1;k<=m;k++) { split(parts[k], hs, ":"); h=hs[1]; sub(/p$/,"",h); s=hs[2]; sub(/%$/,"",s)
                             got[h]=s+0; heights[h]=1 }
        for (h in got) sh[v,h]+=got[h]
        hi=0; for (h in got) if (h+0>=480) hi+=got[h]; hl[v]=hl[v] (hl[v]==""?"":",") hi; hsum[v]+=hi }
      END { for (i=1;i<=nv;i++) { v=order[i]
              line=sprintf("weakline %s, %d passes: stalls %d, frozen %d ms, longest %d ms, blips %d; at 480p or better %d%% (%s)",
                           v, np[v], st[v], fr[v], lg[v], bl[v], hsum[v]/np[v]+0.5, hl[v])
              n=0; for (h in heights) hh[++n]=h+0
              for (a=1;a<=n;a++) for (b=a+1;b<=n;b++) if (hh[b]>hh[a]) { x=hh[a]; hh[a]=hh[b]; hh[b]=x }
              for (a=1;a<=n;a++) line=line sprintf("; %dp %d%%", hh[a], sh[v,hh[a]]/np[v]+0.5)
              print line } }
    ' "$OUT/weakline_passes.tsv" | while read -r line; do log "$line"; done
    # A CLIMB, THEN A STOP (BACKLOG item 2, 14 Nov 2026): each pass's climbs
    # (`exo rung` up), its stops >= 250 ms with what was in hand, and the
    # stops within 30 s of a climb — the failure item 2 was written for.
    python3 test_device/weakline_climbs.py "$OUT" | while read -r line; do log "$line"; done || true
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell rm -f "$d/lab_stream_url" "$d/lab_peak" >/dev/null 2>&1 || true
    rm -f "$OUT"/weakline_ms_*.txt
    log "flow $flow done"
    continue
    ;;
  esac
  # THE LADDER'S START, STEP BY STEP (19 Nov 2026, BACKLOG §0 "1.64.85's
  # first look" weak points 5 and 6). The test film from a resume point
  # (START_AT s, the owner's 579 s), after its page was looked at for
  # START_PAGE s (the grant asked ahead, the opening warmed), from a cleared
  # app each pass, on the line its word names: `weak:WORD` is the weakjumps
  # line (START_WEAK, LINE_DELAY each way, LINE_LOSS), `plain:WORD` a good
  # one (START_PLAIN, START_PLAIN_DELAY each way, no loss) — both through
  # the relay, the cap proved once. WORD goes to lab_start for a start rule
  # under A/B (`a`/`b`: the build's own, an A/A). The app marks each step
  # in ms from the ladder's registration (`LAB hls start +N ms: …`,
  # LadderStartTrail) and, 40 s of film in, makes the seek bar's drags
  # (START_DRAGS) and says how long their pictures trailed the finger
  # (`LAB drag …`). test_device/ladderstart_summary.py lays each pass's
  # steps beside the tap, the grant and the picture (logcat's own ms), and
  # sums per line and word: the first picture (median, p90), stops in the
  # first 30 s, the time at 480p or better, the drags.
  case "$flow" in ladderstart)
    if [ -z "${CLIMB_TITLE:-}" ]; then log "flow ladderstart: no CLIMB_TITLE in config.env — skipped"; continue; fi
    line_proved ladderstart || continue
    passes="${START_PASSES:-weak:a plain:a weak:b plain:b}"
    d="/sdcard/Android/data/$PKG/files"
    : > "$OUT/ladderstart.txt"
    : > "$OUT/ladderstart_passes.tsv"
    p=0
    for pass in $passes; do
      p=$((p + 1))
      lk="${pass%%:*}"; word="${pass#*:}"
      # WORD@KBPS: a remembered line to start from (lab_throughput), as a
      # phone that has played before has one; WORD alone, none.
      seed=""
      case "$word" in *@*) seed="${word##*@}"; word="${word%@*}" ;; esac
      case "$lk" in
        plain) line_shape "${START_PLAIN_DELAY:-30ms}" 0% "${START_PLAIN:-16mbit}"; how="${START_PLAIN:-16mbit}, ${START_PLAIN_DELAY:-30ms} each way, no loss" ;;
        *) lk=weak; line_shape "$LINE_DELAY" "$LINE_LOSS" "${START_WEAK:-4mbit}"; how="${START_WEAK:-4mbit}, $LINE_DELAY each way, loss $LINE_LOSS" ;;
      esac
      adb shell am force-stop "$PKG"
      adb shell pm clear "$PKG" >/dev/null 2>&1 || true
      adb shell mkdir -p "$d" >/dev/null 2>&1
      adb shell "echo title:$CLIMB_TITLE > $d/lab_stream_url"
      adb shell "echo ${START_AT:-579} > $d/lab_start_at"
      adb shell "echo ${START_PAGE:-4} > $d/lab_start_page"
      adb shell "echo $word > $d/lab_start"
      if [ -n "$seed" ]; then adb shell "echo $seed > $d/lab_throughput"; fi
      # The seek bar's drags only in a pass that names a preview word.
      case "$word" in *+*) if [ -n "${START_DRAGS:-}" ]; then adb shell "echo '$START_DRAGS' > $d/lab_drags"; fi ;; esac
      # START_DRAG_WAIT ms from the controls coming up to the finger (3000
      # unset; 0 a drag at once, the pack's header unread unless `hdr`).
      if [ -n "${START_DRAG_WAIT:-}" ]; then adb shell "echo ${START_DRAG_WAIT} > $d/lab_drag_wait"; fi
      log "ladderstart pass $p ($lk, $word): the test film at ${START_AT:-579} s after ${START_PAGE:-4} s on its page; line $how"
      adb shell log -p i -t flutter "LAB ladderstart begin pass=$p line=$lk start=$word" >/dev/null 2>&1 || true
      adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
      waited=0
      while [ "$waited" -lt "${START_PASS_S:-150}" ]; do
        sleep 5; waited=$((waited + 5))
        if awk -v b="LAB ladderstart begin pass=$p " 'index($0,b){on=1} on && /LAB ladderstart done/{f=1} END{exit !f}' "$OUT/logcat_raw.txt"; then
          break
        fi
      done
      adb exec-out screencap -p > "$OUT/shots/9_ladderstart_end_$p.png"
      adb shell log -p i -t flutter "LAB ladderstart end pass=$p line=$lk start=$word" >/dev/null 2>&1 || true
      sleep 2
      adb shell am force-stop "$PKG"
      ls="$OUT/ladderstart_$p.txt"
      # logcat's own time kept (ms): the steps are set beside each other by it.
      awk -v b="LAB ladderstart begin pass=$p " -v e="LAB ladderstart end pass=$p " \
        'index($0,b){on=1} on && /LAB /{print} index($0,e){on=0}' "$OUT/logcat_raw.txt" \
        | sed -E 's#^([0-9-]+ [0-9:.]+) [^:]*: (LAB .*)$#\1 \2#; s#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' > "$ls" || true
      cat "$ls" >> "$OUT/ladderstart.txt"
      printf '%s\t%s\t%s\n' "$p" "$lk" "$word${seed:+@$seed}" >> "$OUT/ladderstart_passes.tsv"
      log "ladderstart pass $p ($lk, $word): $(grep -c 'hls start +' "$ls") start marks, $(grep -c 'LAB drag [0-9]' "$ls") drags"
    done
    log "ladderstart: the line passed $(tc -s qdisc show dev lo | grep -A1 'netem 40:' | grep -oE 'Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+' | head -1)"
    line_down
    adb emu network speed "$NET_SPEED" >/dev/null 2>&1 || true
    adb emu network delay "$NET_DELAY" >/dev/null 2>&1 || true
    log "ladderstart: $(cat "$OUT/relay.txt" 2>/dev/null || echo 'relay: no counts')"
    python3 test_device/ladderstart_summary.py "$OUT" | tee "$OUT/ladderstart_summary.txt" | while read -r line; do log "$line"; done
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell rm -f "$d/lab_stream_url" "$d/lab_start_at" "$d/lab_start_page" "$d/lab_start" "$d/lab_drags" "$d/lab_drag_wait" "$d/lab_throughput" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # THE APP'S FIRST SECONDS ON THE CPU (19 Nov 2026, BACKLOG §0 weak point
  # 7: 60-74 % for ~20 s on the owner's phone, pool-thread 23 %, DartWorker
  # 13-19 %, before any playback). The app as the flows before left it
  # (perf_idle first: the introduction done, access granted, the library
  # on the phone), started cold COLD_STARTS times. For 24 s from each
  # launch: every thread's CPU every 2 s (top -H), the Java stacks at 3, 6,
  # 10 and 15 s (debuggerd -j, as root: which code a pool-N-thread-M runs),
  # and a 12 s cpu-clock profile by thread and library (simpleperf: a
  # DartWorker in libc and the kernel is dart:io's file work, in
  # libflutter.so the VM's own — collecting garbage, an isolate). The
  # app's own CpuProbe lines (`LAB cpu`) are in the trail beside them.
  # test_device/coldcpu_summary.py reads it all.
  # COLD_PLAN (19 Nov, run S2): one word a start, `STAMP:CHANGE` — STAMP to
  # lab_scan (`volume`: the library cache trusted only while nothing on
  # the volume changed, as 1.64.85; `videos`: while no VIDEO did), CHANGE
  # `photo` to put a new picture in MediaStore just before the start (a
  # screenshot: what a chat app's download does between two launches) or
  # `still`. The first start of a stamp scans whatever the change (the
  # other kind's stamp never matches): compare the starts after it.
  # Without COLD_PLAN: COLD_STARTS starts, no change, the build's stamp.
  case "$flow" in coldcpu)
    adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
    # adbd restarted: the trail's logcat with it, appended from now.
    kill "$LOGCAT" 2>/dev/null || true
    adb logcat -v time -T 1 >> "$OUT/logcat_raw.txt" 2>&1 &
    LOGCAT=$!
    # A LIBRARY THE SIZE OF A REAL ONE (COLD_LIBRARY copies of the test
    # library's clip, in a folder of their own): what a rescan costs grows
    # with it, and twelve videos hide it (S1: 60 % for 4 s, then nothing).
    if [ "${COLD_LIBRARY:-0}" -gt 0 ] && [ -f clip.mp4 ]; then
      rm -rf "$OUT/../coldlib" && mkdir -p "$OUT/../coldlib/ColdLib"
      for i in $(seq 1 "$COLD_LIBRARY"); do cp clip.mp4 "$OUT/../coldlib/ColdLib/cold_$i.mp4"; done
      adb push "$OUT/../coldlib/ColdLib" /sdcard/Movies/ >/dev/null 2>&1
      adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
      sleep 30
      rm -rf "$OUT/../coldlib"
      log "coldcpu: MediaStore lists $(adb shell content query --uri content://media/external/video/media --projection _id 2>/dev/null | grep -c Row) videos"
      # Read once, as a viewer's app has: the first start below is then a
      # start of an app that knows its library.
    fi
    : > "$OUT/coldcpu.txt"
    : > "$OUT/coldcpu_plan.tsv"
    plan="${COLD_PLAN:-}"
    [ -n "$plan" ] || plan=$(for _ in $(seq 1 "${COLD_STARTS:-3}"); do printf -- '-:still '; done)
    d="/sdcard/Android/data/$PKG/files"
    c=0
    for word in $plan; do
      c=$((c + 1))
      stamp="${word%%:*}"; change="${word#*:}"
      adb shell am force-stop "$PKG"
      if [ "$stamp" = - ]; then adb shell rm -f "$d/lab_scan" >/dev/null 2>&1 || true
      else adb shell "mkdir -p $d && echo $stamp > $d/lab_scan" >/dev/null 2>&1; fi
      if [ "$change" = photo ]; then
        adb shell mkdir -p /sdcard/Pictures/LabChat >/dev/null 2>&1
        adb shell screencap -p "/sdcard/Pictures/LabChat/chat_$c.png" >/dev/null 2>&1
        adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
          -d "file:///sdcard/Pictures/LabChat/chat_$c.png" >/dev/null 2>&1 || true
      fi
      sleep 4
      printf '%s\t%s\t%s\n' "$c" "$stamp" "$change" >> "$OUT/coldcpu_plan.tsv"
      adb shell log -p i -t flutter "LAB coldcpu begin start=$c stamp=$stamp change=$change" >/dev/null 2>&1 || true
      t0=$(date +%s)
      adb shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
      pid=""
      for _ in $(seq 1 20); do pid=$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r'); [ -n "$pid" ] && break; sleep 0.2; done
      if [ -z "$pid" ]; then log "coldcpu start $c: no process"; continue; fi
      adb shell top -H -b -d 2 -n 12 -m 40 -p "$pid" > "$OUT/coldcpu_top_$c.txt" 2>&1 &
      tp=$!
      ( adb shell "simpleperf record -e cpu-clock -f 500 -p $pid --duration 12 -o /data/local/tmp/cold_$c.data" > "$OUT/coldcpu_perf_rec_$c.txt" 2>&1 ) &
      sp=$!
      for at in 3 6 10 15; do
        now=$(( $(date +%s) - t0 ))
        [ "$now" -lt "$at" ] && sleep $(( at - now ))
        { echo "== start $c at ${at}s"; adb shell debuggerd -j "$pid" 2>&1; } >> "$OUT/coldcpu_stacks_$c.txt"
      done
      wait "$sp" 2>/dev/null || true
      adb shell "simpleperf report -i /data/local/tmp/cold_$c.data --sort comm,dso -n --percent-limit 0.5" > "$OUT/coldcpu_perf_$c.txt" 2>&1 || true
      adb shell "simpleperf report -i /data/local/tmp/cold_$c.data --sort comm,symbol -n --percent-limit 0.5" >> "$OUT/coldcpu_perf_$c.txt" 2>&1 || true
      adb shell rm -f "/data/local/tmp/cold_$c.data" >/dev/null 2>&1 || true
      wait "$tp" 2>/dev/null || true
      adb shell log -p i -t flutter "LAB coldcpu end start=$c" >/dev/null 2>&1 || true
      log "coldcpu start $c ($word): pid $pid, $(grep -c '^== start' "$OUT/coldcpu_stacks_$c.txt") stack dumps"
    done
    adb shell am force-stop "$PKG"
    adb shell rm -rf "$d/lab_scan" /sdcard/Pictures/LabChat >/dev/null 2>&1 || true
    adb unroot >/dev/null 2>&1; sleep 3; adb wait-for-device
    kill "$LOGCAT" 2>/dev/null || true
    adb logcat -v time -T 1 >> "$OUT/logcat_raw.txt" 2>&1 &
    LOGCAT=$!
    python3 test_device/coldcpu_summary.py "$OUT" | tee "$OUT/coldcpu.txt" | head -80 | while read -r line; do log "$line"; done
    # The raw dumps are long (every thread, four times a start): the summary
    # keeps the busy threads' stacks (coldcpu_busy_stacks.txt).
    rm -f "$OUT"/coldcpu_stacks_*.txt
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # JUMPS IN AUTO ON THE WEAK LINE (9 Nov 2026, BACKLOG 5c): the film far
  # from what is in hand each time, so the player waits for the Worker and
  # a segment before it plays. The film is played once per word of
  # JUMP_PASSES, from a cleared app each time, the word written to
  # lab_jump for a build's jump switch: since 11 Nov `on` / `off` for
  # StreamCacheServer.keepSpare (a second pool, so a jump finds a
  # connection open) (`lost`, a pool known lost to a cut, was A/B'd 14 Nov
  # in run L1 43560088068 and taken out; each jump's trail keeps the pools'
  # state); other words leave the build's own, so `a b` is an
  # A/A. (5c's switch, a first segment from a lower rung, was A/B'd in runs
  # 42616754742 and 42628158249 and taken out.) The app (lib/app.dart,
  # _labAutoJumps) warms up for 40 s of film, then jumps to each share of
  # JUMP_AT in turn and writes one line a jump: the longest the picture
  # stood still, and the rungs and stops for 20 s after.
  # test_device/weakjumps_summary.py sums them per variant and pairs each
  # jump with the same jump in the neighbouring pass. The trail has each
  # jump's wait in parts: `hls jump: answer … first byte … segment …;
  # conn new|kept …` and `exo picture after seek`; the jump's own first
  # read is on its `LAB autojump` line too (conn=, wait_ms=, answer_ms=).
  case "$flow" in weakjumps)
    if [ -z "${CLIMB_TITLE:-}" ]; then log "flow weakjumps: no CLIMB_TITLE in config.env — skipped"; continue; fi
    line_proved weakjumps || continue
    passes="${JUMP_PASSES:-on off}"
    jline="${JUMP_LINE:-4mbit}"
    jat="${JUMP_AT:-0.40 0.70 0.20 0.85 0.55 0.31 0.95}"
    d="/sdcard/Android/data/$PKG/files"
    line_rate "$jline"
    : > "$OUT/weakjumps.txt"
    : > "$OUT/weakjumps.tsv"
    p=0
    for variant in $passes; do
      p=$((p + 1))
      adb shell am force-stop "$PKG"
      adb shell pm clear "$PKG" >/dev/null 2>&1 || true
      adb shell mkdir -p "$d" >/dev/null 2>&1
      adb shell "echo title:$CLIMB_TITLE > $d/lab_stream_url"
      adb shell "echo $variant > $d/lab_jump"
      adb shell "echo $jat > $d/lab_autojumps"
      log "weakjumps pass $p ($variant): the test film, jumps to $jat on a $jline line (delay $LINE_DELAY each way, loss $LINE_LOSS)"
      adb shell log -p i -t flutter "LAB weakjumps begin pass=$p jump=$variant" >/dev/null 2>&1 || true
      adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
      # Until the app says it is done, at most JUMP_PASS_S.
      waited=0
      while [ "$waited" -lt "${JUMP_PASS_S:-360}" ]; do
        sleep 5; waited=$((waited + 5))
        if awk -v b="LAB weakjumps begin pass=$p " 'index($0,b){on=1} on && /LAB autojump (done|: )/{f=1} END{exit !f}' "$OUT/logcat_raw.txt"; then
          break
        fi
      done
      adb exec-out screencap -p > "$OUT/shots/9_weakjumps_end_$p.png"
      adb shell log -p i -t flutter "LAB weakjumps end pass=$p jump=$variant" >/dev/null 2>&1 || true
      sleep 2
      adb shell am force-stop "$PKG"
      wj="$OUT/weakjumps_$p.txt"
      awk -v b="LAB weakjumps begin pass=$p " -v e="LAB weakjumps end pass=$p " \
        'index($0,b){on=1} on{print} index($0,e){on=0}' "$OUT/logcat_raw.txt" \
        | grep -o 'LAB .*' | sed -E 's#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' > "$wj" || true
      cat "$wj" >> "$OUT/weakjumps.txt"
      # One row a jump: pass, variant, then the app's key=value fields.
      grep -oE 'LAB autojump [0-9]+/[0-9]+ .*' "$wj" | awk -v p="$p" -v v="$variant" '
        { split($3, ij, "/"); split("", kv)
          for (k=4; k<=NF; k++) { n=index($k, "="); if (n>0) kv[substr($k,1,n-1)]=substr($k,n+1) }
          printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", p, v, ij[1], kv["at"], kv["frozen_ms"],
            kv["ready_ms"], kv["before"], kv["first"], kv["low_ms"], kv["back_ms"], kv["stall_ms"], kv["mean"], kv["rule"],
            kv["want"]
          # The first read of the jump, from the proxy (since 11 Nov): its
          # connection and the answer of the Worker, in parts.
          printf "\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s", kv["conn"], kv["conn_ms"], kv["wait_ms"],
            kv["tcp_ms"], kv["tls_ms"], kv["answer_ms"], kv["seg_ms"], kv["cut"], kv["idle_ms"]
          # And each pool at the choice (since 14 Nov): open, lost-cut…
          printf "\t%s\t%s\n", kv["state"], kv["other"] }' >> "$OUT/weakjumps.tsv" || true
      n=$(grep -c 'LAB autojump [0-9]' "$wj" || true)
      log "weakjumps pass $p ($variant): $n jumps"
      grep -oE 'LAB autojump [0-9]+/[0-9]+ .*' "$wj" | sed "s/^LAB /weakjumps pass $p ($variant): /" | while read -r line; do log "$line"; done
    done
    log "weakjumps: the line passed $(tc -s qdisc show dev lo | grep -A1 'netem 40:' | grep -oE 'Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+' | head -1)"
    line_down
    adb emu network speed "$NET_SPEED" >/dev/null 2>&1 || true
    adb emu network delay "$NET_DELAY" >/dev/null 2>&1 || true
    log "weakjumps: $(cat "$OUT/relay.txt" 2>/dev/null || echo 'relay: no counts')"
    python3 test_device/weakjumps_summary.py "$OUT/weakjumps.tsv" | while read -r line; do log "$line"; done
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell rm -f "$d/lab_stream_url" "$d/lab_jump" "$d/lab_autojumps" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # AUTO CLIMBS BACK UP — a catalogue title (the free test film) played the
  # way a viewer's tap plays it: the real request-playback, Worker and R2,
  # the rung Auto picks, the proxy. It opens on a small copy (a low starting
  # estimate) and the trail should read "measured … kbps" and then "stepped
  # up a rung" once the line has shown it can carry more.
  case "$flow" in climb)
    if [ -z "${CLIMB_TITLE:-}" ]; then log "flow climb: no CLIMB_TITLE in config.env — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo title:$CLIMB_TITLE > $d/lab_stream_url"
    # A starting estimate below the 480p rung, so the film opens small and
    # the climb can be watched on the runner's real line (the emulator's
    # `network speed` cap did not hold in run 37967426588).
    adb shell "echo ${CLIMB_SEED_KBPS:-500} > $d/lab_throughput"
    log "climb: the test film, link estimate seeded at ${CLIMB_SEED_KBPS:-500} kbps, for ${CLIMB_S:-240} s"
    adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep $(( ${CLIMB_S:-240} / 2 ))
    adb exec-out screencap -p > "$OUT/shots/9_climb_mid.png"
    sleep $(( ${CLIMB_S:-240} / 2 ))
    adb exec-out screencap -p > "$OUT/shots/9_climb_end.png"
    log "climb: $(grep -c 'stepped up a rung' "$OUT/logcat_raw.txt" 2>/dev/null) step(s) up, $(grep -c 'stepped down a rung' "$OUT/logcat_raw.txt" 2>/dev/null) down"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_stream_url" "$d/lab_throughput" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # THE VIEWER'S JUMPS ON THE TEST FILM — Test Lab's checks (lib/app.dart,
  # _labJumpScript) on the emulator: a seek, a change of quality, a skip, a
  # swipe and back to Auto, each with where it landed, how long the picture
  # stood still ("frozen") and which engine played it. JUMPS_SPEED caps the
  # emulator's link (an `emu network speed` name, or full) for a run that
  # wants a slower line.
  case "$flow" in jumps)
    # The film: JUMPS_TITLE when set (another open film), else the test film.
    jt="${JUMPS_TITLE:-${CLIMB_TITLE:-}}"
    if [ -z "$jt" ]; then log "flow jumps: no CLIMB_TITLE in config.env — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo title:$jt > $d/lab_stream_url"
    adb shell "echo 1 > $d/lab_jumps"
    # JUMPS_JUMP: a word for the build's jump switch (lab_jump, as the
    # weakjumps flow writes it; `on` = StreamCacheServer.keepSpare), so the
    # release gate can run with a switch on before the build's default is.
    if [ -n "${JUMPS_JUMP:-}" ]; then adb shell "echo $JUMPS_JUMP > $d/lab_jump"; fi
    log "jumps: $jt, the viewer's jumps, ${JUMPS_S:-200} s, home after ${JUMPS_AWAY_AFTER:-100} s${JUMPS_JUMP:+, lab_jump=$JUMPS_JUMP}"
    adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    # The checks are over by about 75 s. Then away to the home screen and
    # back, as a viewer answering a message does: the app's own check
    # ("LAB check back") counts the frames drawn after it.
    sleep "${JUMPS_AWAY_AFTER:-100}"
    adb exec-out screencap -p > "$OUT/shots/9_jumps_mid.png"
    adb shell log -p i -t flutter "LAB away: home" >/dev/null 2>&1 || true
    adb shell input keyevent KEYCODE_HOME
    sleep 10
    adb shell log -p i -t flutter "LAB away: back" >/dev/null 2>&1 || true
    # As the launcher opens it (an `am start` delivers a new intent instead).
    adb shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 8
    adb exec-out screencap -p > "$OUT/shots/9_jumps_back.png"
    sleep $(( ${JUMPS_S:-200} - ${JUMPS_AWAY_AFTER:-100} - 18 ))
    adb exec-out screencap -p > "$OUT/shots/9_jumps_end.png"
    # This flow's own lines only: from its `LAB phase jumps start` on, so a
    # run that plays another flow first (weakjumps, 11 Nov) does not fill
    # the trail below with that flow's lines.
    awk '/LAB phase jumps start/{on=1} on' "$OUT/logcat_raw.txt" 2>/dev/null > "$OUT/jumps_raw.txt" || true
    grep -o 'LAB check.*' "$OUT/jumps_raw.txt" 2>/dev/null | sed 's/^/  /' | tee -a "$OUT/jumps.txt" || true
    grep -o 'LAB jump rule.*\|exo [a-z].*\|hls[: ].*\|open ladder.*\|ladder on ExoPlayer.*\|LAB away.*\|lifecycle .*\|quality .*\|renewal.*\|play through.*\|warm switch.*' "$OUT/jumps_raw.txt" 2>/dev/null | head -160 \
      | sed -E 's#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' >> "$OUT/jumps.txt" || true
    rm -f "$OUT/jumps_raw.txt"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_stream_url" "$d/lab_jumps" "$d/lab_jump" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # THE APP'S SCREENS, STILL AND SCROLLED (27 Nov 2026): the Video tab, the
  # catalogue's front, its poster grid and the Me tab in turn (flows
  # idle_*.yaml), a marker round each, so CpuProbe's 10 s lines between
  # belong to that screen — still (a line with frames is a screen drawing
  # on its own), then flung (b90/r90 and late frames). screens.txt.
  case "$flow" in idle_screens)
    for scr in local hub movies me; do
      adb shell log -p i -t flutter "LAB screen $scr start" >/dev/null 2>&1 || true
      ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/idle_$scr.yaml" ) >> "$OUT/maestro_$flow.txt" 2>&1 \
        || log "idle_$scr: maestro exit $?"
      adb shell log -p i -t flutter "LAB screen $scr end" >/dev/null 2>&1 || true
    done
    awk '/LAB phase idle_screens start/{on=1} on' "$OUT/logcat_raw.txt" 2>/dev/null \
      | grep -o 'LAB screen.*\|LAB cpu.*' > "$OUT/screens.txt" || true
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # THE PLAYER'S SMOOTHNESS (27 Nov 2026, the owner on 1.64.89: "⋮'s menu
  # stutters when scrolled"). The open film plays; the app itself opens
  # each menu, flings its list up and down and times every frame
  # (lib/features/player/presentation/lab/smooth_lab.dart: one `LAB frames
  # STATE/MENU/LOOK …` line a step — build and raster p50/p90/p99/worst,
  # the frames over 16.7 ms, the threads' CPU). SMOOTH_PLAN: its steps, or
  # empty for its default (every menu, 1.64.89's drawing beside the
  # build's own, playing and paused). gfxinfo's framestats and
  # SurfaceFlinger's record of the player's surface are kept too; the
  # emulator's GPU is the runner's CPU: before/after on one run, not a
  # phone's numbers.
  case "$flow" in smooth)
    jt="${JUMPS_TITLE:-${CLIMB_TITLE:-}}"
    if [ -z "$jt" ]; then log "flow smooth: no JUMPS_TITLE in config.env — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo title:$jt > $d/lab_stream_url"
    adb shell "echo '${SMOOTH_PLAN:-1}' > $d/lab_smooth"
    log "smooth: $jt, plan ${SMOOTH_PLAN:-default}"
    adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep 20
    adb shell dumpsys gfxinfo "$PKG" reset >/dev/null 2>&1 || true
    # Until the app says it is done, at most SMOOTH_S seconds.
    waited=20
    while [ "$waited" -lt "${SMOOTH_S:-420}" ]; do
      sleep 10; waited=$((waited + 10))
      if grep -q 'LAB smooth: done\|LAB smooth: stopped' "$OUT/logcat_raw.txt" 2>/dev/null; then break; fi
      if [ $((waited % 60)) -eq 0 ]; then adb exec-out screencap -p > "$OUT/shots/9_smooth_${waited}s.png"; fi
    done
    adb shell dumpsys gfxinfo "$PKG" framestats > "$OUT/smooth_gfxinfo.txt" 2>&1 || true
    layer=$(adb shell dumpsys SurfaceFlinger --list 2>/dev/null | tr -d '\r' | grep -m1 "SurfaceView.*$PKG" || true)
    if [ -n "$layer" ]; then
      { echo "layer: $layer"; adb shell dumpsys SurfaceFlinger --latency "'$layer'"; } > "$OUT/smooth_surfaceflinger.txt" 2>&1 || true
    fi
    awk '/LAB phase smooth start/{on=1} on' "$OUT/logcat_raw.txt" 2>/dev/null \
      | grep -o 'LAB frames.*\|LAB smooth.*\|LAB fn.*\|LAB cpu.*' | tee "$OUT/smooth.txt" | grep -c 'LAB frames' \
      | sed 's/^/  frames lines: /' || true
    # The Screenshot shortcut's picture, where a viewer looks for it.
    { echo "screenshots in MediaStore:"; adb shell content query --uri content://media/external/images/media \
        --projection _display_name:relative_path 2>/dev/null | grep -i 'Innocent' || echo "  none"; } >> "$OUT/smooth.txt"

    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_stream_url" "$d/lab_smooth" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # A MAN IN THE MIDDLE (2026-10-26). The emulator was started behind
  # mitmproxy (MITM=on in config.env, `-http-proxy` in device-lab.yml), so
  # every connection the app opens reaches the proxy, which answers with a
  # certificate of its own. The test film is opened twice:
  #   A  the proxy on the path only — a hostile Wi-Fi, a tapped line;
  #   B  its CA also in the phone's USER certificate store — where a profile
  #      a viewer is talked into installing, or a company's, would put it.
  # tool/netlab/mitm_watch.py writes what the proxy got: refused, accepted,
  # and for what it could read only the kind of path and the header NAMES.
  case "$flow" in mitm)
    EV="$OUT/mitm_events.jsonl"
    if [ "${MITM:-}" != on ] || [ ! -f "$HOME/.mitmproxy/mitmproxy-ca-cert.pem" ]; then
      log "flow mitm: the emulator is not behind the interceptor (MITM=on) — skipped"; continue
    fi
    CA="$HOME/.mitmproxy/mitmproxy-ca-cert.pem"
    H=$(openssl x509 -inform PEM -subject_hash_old -in "$CA" | head -1)
    # The proxy really reads what it is trusted for: the host asks Supabase
    # through it once without its certificate (refused) and once with it.
    echo '{"ev":"stage","stage":"control"}' >> "$EV"
    nc=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --proxy http://127.0.0.1:8080 \
      https://yqonvmuiezqvyqmexrft.supabase.co/rest/v1/ 2>&1 | tail -c 80)
    wc=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 --proxy http://127.0.0.1:8080 --cacert "$CA" \
      https://yqonvmuiezqvyqmexrft.supabase.co/rest/v1/ 2>&1 | tail -c 80)
    log "mitm control: curl without the proxy's CA: $nc | with it: $wc"
    d="/sdcard/Android/data/$PKG/files"
    open_film() { # $1 = stage
      adb shell am force-stop "$PKG"
      adb shell pm clear "$PKG" >/dev/null 2>&1 || true
      adb shell mkdir -p "$d" >/dev/null 2>&1
      adb shell "echo title:$CLIMB_TITLE > $d/lab_stream_url"
      echo "{\"ev\":\"stage\",\"stage\":\"$1\"}" >> "$EV"
      adb shell log -p i -t flutter "LAB mitm stage $1" >/dev/null 2>&1 || true
      log "mitm $1: the test film opened"
      adb shell am start -W -n "$PKG/.MainActivity" >/dev/null 2>&1
      sleep "${MITM_STAGE_S:-50}"
      adb exec-out screencap -p > "$OUT/shots/95_mitm_$1.png"
    }
    open_film A
    # B: as Settings → Install certificate → CA certificate files it.
    adb root >/dev/null 2>&1; sleep 3; adb wait-for-device
    adb push "$CA" "/data/local/tmp/$H.0" >/dev/null 2>&1
    adb shell "mkdir -p /data/misc/user/0/cacerts-added && cp /data/local/tmp/$H.0 /data/misc/user/0/cacerts-added/ \
      && chown system:system /data/misc/user/0/cacerts-added/$H.0 && chmod 644 /data/misc/user/0/cacerts-added/$H.0 \
      && restorecon -R /data/misc/user/0/cacerts-added" >/dev/null 2>&1
    log "mitm B: user store now holds $(adb shell ls /data/misc/user/0/cacerts-added 2>/dev/null | tr -d '\r' | wc -l) certificate(s)"
    open_film B
    adb shell "rm -f /data/misc/user/0/cacerts-added/$H.0"
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_stream_url" >/dev/null 2>&1 || true
    python3 test_device/mitm_summary.py "$EV" "$OUT/logcat_raw.txt" | tee "$OUT/mitm.txt"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # TEST LAB'S LAUNCH, ON THE EMULATOR. Test Lab starts a lab APK with the
  # game-loop intent (scenario 3 = a catalogue title) and on two real phones
  # the film never reached the screen (run 37967931084) while the launch-time
  # path above plays it. Same intent here, the title from lab_loop_title.
  # "OPEN WITH INNOCENT", cold and warm: a film handed over by another app
  # (a file manager, the gallery) — an intent with an address, which is what
  # Flutter's deep linking turned into "Route not found" before 1.64.60.
  # Cold: the app is not running (the lab film's name, so the lab build
  # steps past the introduction). Warm: the app is up and another film is
  # handed over. Each must reach a first frame.
  case "$flow" in openwith)
    film="lib_media/Movies/Perf Test/aaa_play_720p.mp4"
    # The media set is not on every run (run 38018583863 skipped this flow
    # for want of it): make a film, as the newvideo flow does.
    if [ ! -f "$film" ] && command -v ffmpeg >/dev/null 2>&1; then
      film=/tmp/lab_open.mp4
      ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=24 \
        -f lavfi -i sine=frequency=330 -t 90 -c:v libx264 -preset veryfast \
        -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart "$film"
    fi
    if [ ! -f "$film" ]; then log "flow openwith: no film — skipped"; continue; fi
    adb push "$film" /sdcard/Download/innocent_lab_play.mp4 >/dev/null 2>&1
    adb push "$film" /sdcard/Download/lab_open_2.mp4 >/dev/null 2>&1
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    adb shell pm grant "$PKG" android.permission.READ_MEDIA_VIDEO >/dev/null 2>&1 || true
    frames() { local n; n=$(grep -c 'first frame' "$OUT/logcat_raw.txt" 2>/dev/null); echo "${n:-0}"; }
    f0=$(frames)
    adb shell am start -W -a android.intent.action.VIEW -t video/mp4 \
      -d "file:///sdcard/Download/innocent_lab_play.mp4" -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep 30
    adb exec-out screencap -p > "$OUT/shots/9_openwith_cold.png"
    f1=$(frames)
    adb shell input keyevent 4
    sleep 4
    adb shell am start -W -a android.intent.action.VIEW -t video/mp4 \
      -d "file:///sdcard/Download/lab_open_2.mp4" -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep 20
    adb exec-out screencap -p > "$OUT/shots/9_openwith_warm.png"
    f2=$(frames)
    log "openwith: cold start $((f1 - f0)) first frame(s), warm $((f2 - f1)); $(grep -c 'route: no screen' "$OUT/logcat_raw.txt" 2>/dev/null) unknown route(s)"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell am force-stop "$PKG"
    adb shell rm -f /sdcard/Download/innocent_lab_play.mp4 /sdcard/Download/lab_open_2.mp4 >/dev/null 2>&1 || true
    rm -f /tmp/lab_open.mp4
    log "flow $flow done"
    continue
    ;;
  esac
  # THE LAST PLAYBACK'S SUMMARY, AND LIBMPV'S OPEN (14 Nov 2026). The owner's
  # last playback of both 14 Nov sessions sent no play_summary: queued in
  # memory as the player closed, its kept copy deleted at once, and the app
  # left soon after. A 1-rung open film (SUMMARY_TITLE: libmpv through the
  # proxy) is played from a cleared app through the catalogue path, closed
  # with Back, and the app force-stopped 2 s after — before any post. The
  # next start plays it again (its bytes held from the first play) and must
  # send the first summary from the phone's copy; closed and stopped the same
  # way, the third start sends the second. Each must reach `events` once,
  # `stashed: 1`, device_kind 'lab'; libmpv's open_ms the real wait, stalls 0
  # (32-43 ms and a stall before 63499b3c). The trail's `summary … sent`
  # lines are counted here; read the rows in the database (BACKLOG §0).
  # Run A (43675629684) showed what a fresh app needs: its permission dialog
  # took the first Back, and a plain start stops at the introduction (no
  # event, so nothing is sent) — every start here is the lab's launch.
  case "$flow" in summarykill)
    st="${SUMMARY_TITLE:-}"
    if [ -z "$st" ]; then log "flow summarykill: no SUMMARY_TITLE — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    lab_grants
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo title:$st > $d/lab_loop_title"
    for pass in 1 2 3; do
      adb shell log -p i -t flutter "LAB summarykill pass $pass" >/dev/null 2>&1 || true
      lab_loop_start
      sleep 40
      adb exec-out screencap -p > "$OUT/shots/9_summarykill_${pass}.png"
      adb shell input keyevent 4
      if [ "$pass" = 3 ]; then
        # The last pass leaves as a viewer does: Home, the pause's flush.
        sleep 2
        adb shell input keyevent 3
        sleep 8
      else
        sleep 2
      fi
      adb shell am force-stop "$PKG"
      log "summarykill: pass $pass closed, the app stopped $([ "$pass" = 3 ] && echo "10 s after (Home)" || echo "2 s after")"
      sleep 3
    done
    adb shell rm -f "$d/lab_loop_title" >/dev/null 2>&1 || true
    span="$OUT/summarykill_trail.txt"
    awk '/LAB phase summarykill start/{on=1} on' "$OUT/logcat_raw.txt" > "$span" 2>/dev/null
    log "summarykill: $(grep -c 'LAB title: opening' "$span") play(s), $(grep -c 'first frame' "$span") first frame(s), $(grep -cE 'summary [0-9a-f]+ sent' "$span") summary send(s), $(grep -c 'kept from an earlier run' "$span") of them kept from an earlier run"
    grep -aoE "LAB summarykill pass [0-9]|first frame [0-9]+ ms|rebuffer end [0-9]+ ms|summar(y|ies) [^\r]*" "$span" \
      | while read -r l; do log "summarykill: $l"; done
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  # ONE ENGINE, MANY OPENS (14 Nov 2026). After the double open the next
  # film's ExoPlayer open answered false at once and fell back to libmpv,
  # and the trail could not say why. The app is kept running; a ladder film
  # (REOPEN_LADDER) and a 1-rung one (SUMMARY_TITLE) are opened in turn
  # through the catalogue path, each closed with Back and the next opened
  # 0.3-2 s after, so a closing screen's stop meets the next screen's open.
  # Counted in steps.txt, in this flow's own span: every "exo … refused"
  # (now with its reason), every fall back to libmpv, the guards' "newer
  # video" lines, and players stacked (a newer screen took one over: run A's
  # first Back went to a permission dialog, the next play opened over it).
  case "$flow" in reopen)
    lt="${REOPEN_LADDER:-}"; st="${SUMMARY_TITLE:-}"
    if [ -z "$lt" ] || [ -z "$st" ]; then log "flow reopen: needs REOPEN_LADDER and SUMMARY_TITLE — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    lab_grants
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    i=0
    for t in "$lt" "$lt" "$st" "$lt" "$st" "$st" "$lt" "$lt"; do
      i=$((i + 1))
      adb shell "echo title:$t > $d/lab_loop_title"
      lab_loop_start
      sleep $(( 9 + i % 3 * 3 ))
      adb shell input keyevent 4
      case $((i % 3)) in 0) sleep 0.3 ;; 1) sleep 1 ;; *) sleep 2 ;; esac
    done
    sleep 15
    adb exec-out screencap -p > "$OUT/shots/9_reopen_end.png"
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_loop_title" >/dev/null 2>&1 || true
    span="$OUT/reopen_trail.txt"
    awk '/LAB phase reopen start/{on=1} on' "$OUT/logcat_raw.txt" > "$span" 2>/dev/null
    log "reopen: $(grep -c 'LAB title: opening' "$span") play(s), $(grep -c 'open ladder (exo)' "$span") ladder open(s), $(grep -c 'first frame' "$span") first frame(s), $(grep -cE 'summary [0-9a-f]+ sent' "$span") summary send(s)"
    log "reopen: $(grep -c 'ladder on ExoPlayer failed' "$span") fall back(s) to libmpv, $(grep -cE 'exo [a-z]+ refused' "$span") refusal(s), $(grep -cE 'newer video took over|a newer open has the engine' "$span") newer-video guard(s), $(grep -c 'a newer player screen took over' "$span") stacked player(s)"
    grep -aoE "exo [a-z]+ refused: [^\r]*|ladder on ExoPlayer failed[^\r]*|TEARDOWN: [^\r]*|stop: a newer[^\r]*|ladder let go[^\r]*|a newer player screen took over[^\r]*" "$span" \
      | sort | uniq -c | sort -rn | head -12 | while read -r l; do log "reopen: $l"; done
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    log "flow $flow done"
    continue
    ;;
  esac
  case "$flow" in titleloop)
    if [ -z "${CLIMB_TITLE:-}" ]; then log "flow titleloop: no CLIMB_TITLE — skipped"; continue; fi
    adb shell am force-stop "$PKG"
    adb shell pm clear "$PKG" >/dev/null 2>&1 || true
    d="/sdcard/Android/data/$PKG/files"
    adb shell mkdir -p "$d" >/dev/null 2>&1
    adb shell "echo title:$CLIMB_TITLE > $d/lab_loop_title"
    # WITH DATA, as Test Lab launches: its game loop carries a content://
    # address, and that address is what put the router on "Route not
    # found" there (run 37967931084). Launched without one, this flow
    # passed while every real phone failed.
    adb shell am start -W -a com.google.intent.action.TEST_LOOP -t application/javascript \
      -d "file:///sdcard/Download/lab_loop.js" --ei scenario 3 -n "$PKG/.MainActivity" >/dev/null 2>&1
    sleep 75
    adb exec-out screencap -p > "$OUT/shots/9_titleloop.png"
    log "titleloop: $(grep -c 'opening the player' "$OUT/logcat_raw.txt" 2>/dev/null) player open(s), $(grep -c 'first frame' "$OUT/logcat_raw.txt" 2>/dev/null) first frame(s) so far in the run"
    adb shell log -p i -t flutter "LAB phase $flow end" >/dev/null 2>&1 || true
    adb shell am force-stop "$PKG"
    adb shell rm -f "$d/lab_loop_title" >/dev/null 2>&1 || true
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
  # THE CUT, MEASURED: the file the flow made, its length and tracks, and
  # how PreciseTrimmer made it ("optimization=1" is the smart cut, exact to
  # the frame; "video=2" alone is a copy from the key frame before A).
  # The first frame's time says whether it starts at A: 0 for a smart cut;
  # a lossless cut from the key frame before A starts at 0 too, but is
  # longer than B - A by the gap, so the duration is the tell.
  case "$flow" in cut|cut_exact)
    adb shell "ls /sdcard/Innocent/Cuts/ 2>/dev/null" | tr -d '\r' | while read -r f; do
      [ -n "$f" ] || continue
      rm -f /tmp/lab_cut.mp4
      adb pull "/sdcard/Innocent/Cuts/$f" /tmp/lab_cut.mp4 >/dev/null 2>&1 || true
      if command -v ffprobe >/dev/null 2>&1 && [ -f /tmp/lab_cut.mp4 ]; then
        d=$(ffprobe -v error -show_entries format=duration -of csv=p=0 /tmp/lab_cut.mp4)
        st=$(ffprobe -v error -show_entries stream=codec_type,codec_name,profile -of csv=p=0 /tmp/lab_cut.mp4 | tr '\n' ' ')
        log "cut file: $f duration=${d}s streams: $st"
      else
        log "cut file: $f (not measured)"
      fi
    done
    adb logcat -d -s Innocent:I Innocent:W 2>/dev/null | grep "Cut:" | tail -4 | tr -d '\r' | while read -r l; do log "trimmer: ${l#*: }"; done
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
line_down
if [ -n "$LOSS_DEV" ]; then
  # Only what this run added: its filter, and the ingress qdisc if it made
  # one — never the runner's own clsact.
  sudo tc filter del dev "$LOSS_DEV" ingress pref 49 2>/dev/null || true
  [ "$OUR_INGRESS" = 1 ] && { sudo tc qdisc del dev "$LOSS_DEV" ingress 2>/dev/null || true; }
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
