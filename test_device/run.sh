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
  adb shell cmd overlay enable com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
  adb shell cmd overlay enable com.android.internal.display.cutout.emulation.hole >/dev/null 2>&1 || true
  sleep 5
  log "overlays: $(adb shell cmd overlay list 2>/dev/null | grep -E 'threebutton|cutout' | tr -d '\r' | tr '\n' ' ')"
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

export PATH="$HOME/.maestro/bin:$PATH"
for flow in $FLOWS; do
  log "flow $flow"
  adb shell log -p i -t flutter "LAB phase $flow start" >/dev/null 2>&1 || true
  # The layout flows measure one orientation each; the player follows the
  # device by default, so turn the device.
  case "$flow" in
    layout_portrait)
      adb shell settings put system accelerometer_rotation 0
      adb shell settings put system user_rotation 0 ;;
    layout_landscape)
      adb shell settings put system accelerometer_rotation 0
      adb shell settings put system user_rotation 1
      sleep 3 ;;
  esac
  # The perf flows sit still for a minute; read the threads in the middle of
  # it, while the Video tab idles or the film plays.
  case "$flow" in perf_*) ( sleep 40; { echo "== during $flow"; threads; } >> "$OUT/threads.txt" ) & ;; esac
  ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/$flow.yaml" ) > "$OUT/maestro_$flow.txt" 2>&1
  log "flow $flow exit $?"
  # Maestro has put screenshots in different places across versions.
  find test_device/flows "$OUT/maestro_out" "$HOME/.maestro/tests" -name '*.png' -newer test_device/config.env \
    -exec cp {} "$OUT/shots/" \; 2>/dev/null || true
  maestro hierarchy > "$OUT/hierarchy_after_$flow.json" 2>/dev/null || true
done
adb shell dumpsys cpuinfo 2>/dev/null | head -40 > "$OUT/cpuinfo.txt" || true

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
