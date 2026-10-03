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

# The emulator's own launcher sometimes ANRs while the image settles, and its
# dialog sits over the app and eats every tap. Hide system error dialogs and
# give the image a moment before measuring anything.
adb shell settings put global hide_error_dialogs 1 || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
sleep 20
adb shell input keyevent KEYCODE_HOME

log "cold start"
adb shell am force-stop "$PKG"
adb shell am start -W -n "$PKG/.MainActivity" > "$OUT/cold_start.txt" 2>&1
grep -E "TotalTime|WaitTime|Status" "$OUT/cold_start.txt" | tee -a "$OUT/steps.txt"
sleep 10
adb exec-out screencap -p > "$OUT/shots/00_cold_start.png"

export PATH="$HOME/.maestro/bin:$PATH"
for flow in $FLOWS; do
  log "flow $flow"
  ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/$flow.yaml" ) > "$OUT/maestro_$flow.txt" 2>&1
  log "flow $flow exit $?"
  # Maestro has put screenshots in different places across versions.
  find test_device/flows "$OUT/maestro_out" "$HOME/.maestro/tests" -name '*.png' -newer test_device/config.env \
    -exec cp {} "$OUT/shots/" \; 2>/dev/null || true
  maestro hierarchy > "$OUT/hierarchy_after_$flow.json" 2>/dev/null || true
done

kill $SAMPLER 2>/dev/null
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
adb logcat -d -v time > "$OUT/logcat_raw.txt" 2>&1
sed -E 's#https?://[^ "]+#<url>#g; s#[A-Za-z0-9_-]{40,}#<token>#g' "$OUT/logcat_raw.txt" \
  | grep -iE "innocent|flutter|mpv|AndroidRuntime|FATAL|ANR|crash|exception| DEBUG|libc" > "$OUT/logcat.txt"
rm -f "$OUT/logcat_raw.txt"

# Screenshots at phone-half size: enough to read, small enough to commit.
rm -rf "$OUT/maestro_out"
find "$OUT" -name '*.png' -exec mogrify -resize 540x {} \; 2>/dev/null || true
log "done"
