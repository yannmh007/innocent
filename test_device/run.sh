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

export PATH="$HOME/.maestro/bin:$PATH"
for flow in $FLOWS; do
  log "flow $flow"
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
  ( cd "$OUT/shots" && maestro test --test-output-dir "$OUT/maestro_out" "$OLDPWD/test_device/flows/$flow.yaml" ) > "$OUT/maestro_$flow.txt" 2>&1
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
    # Run 37280515740: inside the player every accessibility node came back
    # as the whole screen, so its centre is the video, not the button. Then
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
