#!/usr/bin/env bash
# Reference lab, MODE=probe — does MX Player run on the lab's emulator?
# .github/workflows/reference-lab.yml says why each step is where it is.
#
#   probe.sh pull   needs GH_TOKEN: innocent-ref is private; download the
#                   XAPK kept by MODE=fetch
#   probe.sh check  no token: the file is the one kept (size, SHA-256) and
#                   every APK in it is signed by MX_CERT, the base stamped by
#                   Google Play
#   probe.sh film   no token: the measuring film (ours, made with ffmpeg)
#   probe.sh run    no token, inside the emulator step: install, cut MX's
#                   network by uid, open the film, pass the first-run
#                   screens, show the controls, one screenshot and one dump
#   probe.sh panels no token, inside the emulator step (MODE=panels):
#                   MX and Innocent's lab build, their ⋮, ♪ and CC panels
#                   upright and sideways over a black and a white frame,
#                   each a screenshot and its tree (tool/ref/measure.py)
#   probe.sh keep   needs GH_TOKEN: innocent-ref is private; push what run
#                   or panels left to runs/<date>_<run id>/
#
# THE PUBLIC LOG AND SUMMARY CARRY NUMBERS ONLY (and Android's own facts:
# its version, ABIs, an INSTALL_* status). MX's words, screens, dumps and
# log lines go to $OUT, which only `keep` sends, to the private repository.
set -euo pipefail

SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"
say() { printf '%s\n' "$*"; printf -- '- %s\n' "$*" >> "$SUM"; }
T="${RUNNER_TEMP:-/tmp}"
W="$T/mx"            # the XAPK and its APKs
OUT="$T/ref_out"     # what goes to innocent-ref, and nowhere else
FILM="$T/film/ref_measure.mp4"      # black first
FILM_W="$T/film/ref_measure_w.mp4"  # white first
FILM_P="$T/film/ref_measure_p.mp4"  # upright (720x1280), black first
FILM_PW="$T/film/ref_measure_pw.mp4" # upright, white first
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI() { python3 -I "$HERE/ui.py" "$@"; }
note() { printf '%s\n' "$*" >> "$OUT/probe.txt"; }
TAG="mx-$MX_VERSION"

private() {
  [ -n "${GH_TOKEN:-}" ] || { say "innocent-ref: the secret REF_REPO_TOKEN is not set"; exit 1; }
  local priv
  priv=$(gh api "repos/$REF_REPO" --jq .private 2>/dev/null) \
    || { say "innocent-ref: no access (the token, the repository it names, or its expiry)"; exit 1; }
  [ "$priv" = true ] || { say "innocent-ref is NOT private: nothing of MX's may go there or come from it"; exit 1; }
}

pull() {
  private
  rm -rf "$W"; mkdir -p "$W"
  gh release download "$TAG" --repo "$REF_REPO" -p "$MX_ASSET" -D "$W" >/dev/null 2>&1 \
    || { say "innocent-ref: the release $TAG has no $MX_ASSET"; exit 1; }
  say "innocent-ref: private; $MX_ASSET downloaded ($(stat -c %s "$W/$MX_ASSET") B)"
}

BT=""
certs() { "${BT}apksigner" verify --verbose --print-certs "$1" 2>/dev/null || true; }
digest() { certs "$1" | sed -n -E 's/^(Signer #1|V[0-9.]+ Signer:) certificate SHA-256 digest: //p' | head -1; }
PLAY_STAMP_SHA256=3257d599a49d2c961a471ca9843f59d341a405884583fc087df4237b733bbd6d
stamp() { certs "$1" | awk '/^Verified for SourceStamp: true/ {ok=1}
                            ok && /^Source Stamp Signer: certificate SHA-256 digest: / {print $NF; exit}'; }

check() {
  BT=$(ls -d "${ANDROID_HOME:?}"/build-tools/*/ | sort -V | tail -1)
  local f="$W/$MX_ASSET" size sha
  size=$(stat -c %s "$f"); sha=$(sha256sum "$f" | cut -d' ' -f1)
  [ "$size" = "$MX_SIZE" ] && [ "$sha" = "$MX_SHA256" ] \
    || { say "NOT THE FILE KEPT: $size B, SHA-256 differs from ref.env: not installed"; exit 1; }
  mkdir -p "$W/x"
  unzip -q -o "$f" 'manifest.json' '*.apk' -d "$W/x"
  local n=0 a base
  for a in "$W"/x/*.apk; do
    [ "$(digest "$a")" = "$MX_CERT" ] || { say "AN APK IS NOT SIGNED BY MX_CERT: not installed"; exit 1; }
    n=$((n + 1))
  done
  base="$W/x/$MX_PACKAGE.apk"; [ -f "$base" ] || base="$W/x/base.apk"
  [ "$(stamp "$base")" = "$PLAY_STAMP_SHA256" ] || { say "NO VERIFIED GOOGLE PLAY STAMP on the base APK: not installed"; exit 1; }
  local so pairip
  so=$(for a in "$W"/x/*.apk; do unzip -Z1 "$a"; done | grep -cE '^lib/[^/]+/[^/]+\.so$' || true)
  pairip=$(for a in "$W"/x/*.apk; do unzip -Z1 "$a"; done | grep -c 'libpairipcore' || true)
  say "the file kept (size and SHA-256), $n APKs, each signed by MX_CERT, the base Play-stamped"
  say "native libraries: $so; Play's install-source guard (pairip) present: $pairip"
}

film() {
  mkdir -p "$(dirname "$FILM")"
  local d="$T/film" i a b
  # Two subtitle tracks, a line every 4 s (ours: numbers and plain words).
  for i in 0 1; do
    : > "$d/sub$i.srt"
    for n in $(seq 0 34); do
      a=$((n * 4)); b=$((n * 4 + 3))
      { echo "$((n + 1))"
        printf '00:%02d:%02d,200 --> 00:%02d:%02d,800\n' $((a / 60)) $((a % 60)) $((b / 60)) $((b % 60))
        if [ "$i" = 0 ]; then echo "Reference line $((n + 1)), track one"
        else echo "စာတန်း $((n + 1)) — အပိုင်း နှစ်"; fi
        echo; } >> "$d/sub$i.srt"
    done
  done
  # 140 s at 1280x720: black 0-40, white 40-80, grey 80-100, busy (a fine
  # black-and-white texture) 100-120, colourful 120-140. Two audio tracks.
  # And the same film white first (FILM_W): each panel is taken over black
  # and over white within the first 40 s of a fresh open. And both again
  # upright, 720x1280 (FILM_P, FILM_PW): each app turns itself upright for
  # an upright film, as a phone's own video does. Turning MX upright from
  # outside (wm set-fix-to-user-rotation) squeezed its controls into a band
  # across the middle (run 44991688519): not how it looks on a phone.
  local first second out size
  for out in "$FILM" "$FILM_W" "$FILM_P" "$FILM_PW"; do
    case "$out" in "$FILM"|"$FILM_P") first=black; second=white ;; *) first=white; second=black ;; esac
    case "$out" in "$FILM"|"$FILM_W") size=1280x720 ;; *) size=720x1280 ;; esac
    ffmpeg -loglevel error -y \
      -t 40 -f lavfi -i "color=c=$first:s=$size:r=24" \
      -t 40 -f lavfi -i "color=c=$second:s=$size:r=24" \
      -t 20 -f lavfi -i "color=c=0x808080:s=$size:r=24" \
      -t 20 -f lavfi -i "cellauto=s=$size:r=24:rule=30:start_full=1:random_fill_ratio=0.5" \
      -t 20 -f lavfi -i "testsrc2=s=$size:r=24" \
      -t 140 -f lavfi -i "sine=frequency=440:sample_rate=48000" \
      -t 140 -f lavfi -i "sine=frequency=660:sample_rate=48000" \
      -i "$d/sub0.srt" -i "$d/sub1.srt" \
      -filter_complex "[0:v][1:v][2:v][3:v][4:v]concat=n=5:v=1:a=0,format=yuv420p[v]" \
      -map "[v]" -map 5:a -map 6:a -map 7:s -map 8:s \
      -c:v libx264 -preset veryfast -crf 30 -g 48 -c:a aac -b:a 64k -c:s mov_text \
      -metadata:s:a:0 language=eng -metadata:s:a:0 title="Tone 440" \
      -metadata:s:a:1 language=mya -metadata:s:a:1 title="Tone 660" \
      -metadata:s:s:0 language=eng -metadata:s:s:0 title="English" \
      -metadata:s:s:1 language=mya -metadata:s:s:1 title="Burmese" \
      -disposition:a:0 default -disposition:s:0 default -movflags +faststart "$out"
  done
  local streams
  streams=$(ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$FILM" | sort | uniq -c | awk '{printf "%s %s, ", $1, $2}')
  say "the measuring film: $(ffprobe -v error -show_entries format=duration -of csv=p=0 "$FILM" | cut -d. -f1) s, ${streams%, }"
}

# The device's UI as uiautomator sees it, into $1; false when it could not.
dump() {
  adb shell rm -f /sdcard/ref_ui.xml >/dev/null 2>&1 || true
  adb shell uiautomator dump /sdcard/ref_ui.xml >/dev/null 2>&1 || true
  adb exec-out cat /sdcard/ref_ui.xml > "$1" 2>/dev/null || true
  grep -q '<hierarchy' "$1" 2>/dev/null
}

ABIS=""; ROOT=0; LOGCAT=""; MX_UID=""; MX_COMP=""

# The emulator made like the owner's phone, root, the log streaming to $OUT.
setup_device() {
  adb wait-for-device
  local bridge
  ABIS=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
  bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')
  say "device: Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $(adb shell getprop ro.build.version.sdk | tr -d '\r')), ABIs $ABIS, native bridge ${bridge:-none}"
  adb root >/dev/null 2>&1 || true
  adb wait-for-device
  ROOT=0; [ "$(adb shell id -u | tr -d '\r')" = 0 ] && ROOT=1

  # A phone like the owner's: 1080x2316 at 450 dpi (about 384x823 dp),
  # three-button navigation and a punch-hole camera (run.sh PHONE_LIKE_OWNER).
  adb shell settings put global hide_error_dialogs 1 >/dev/null 2>&1 || true
  adb shell settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1 || true
  sleep 15
  adb shell cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.threebutton >/dev/null 2>&1 || true
  adb shell cmd overlay enable-exclusive --category com.android.internal.display.cutout.emulation.hole >/dev/null 2>&1 || true
  local phys; phys=$(adb shell wm size | sed -n 's/^Physical size: //p' | tr -d '\r')
  [ "$phys" = "$PROBE_SIZE" ] || adb shell wm size "$PROBE_SIZE" || true
  adb shell wm density "$PROBE_DPI" >/dev/null || true
  sleep 5
  adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true
  adb shell input keyevent KEYCODE_HOME || true
  local nav hole
  nav=$(adb shell cmd overlay list 2>/dev/null | grep -F '[x]' | grep -c 'navbar.threebutton' || true)
  hole=$(adb shell cmd overlay list 2>/dev/null | grep -F '[x]' | grep -c 'cutout.emulation.hole' || true)
  say "screen: physical $phys, now $(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r') at $(adb shell wm density | tail -1 | awk '{print $NF}' | tr -d '\r') dpi; three-button nav $nav, punch hole $hole; root $ROOT"

  adb logcat -G 16M >/dev/null 2>&1 || true
  adb logcat -c || true
  adb logcat -v time > "$OUT/logcat_raw.txt" 2>&1 &
  LOGCAT=$!
}

# MX installed from the splits manifest.json names for this device, its
# permissions given, its uid cut off the network. False if any of it failed.
install_mx() {
  UI splits "$W/x/manifest.json" "$PROBE_DPI" "$ABIS" > "$W/install.list"
  local files=() f
  while IFS= read -r f; do [ -n "$f" ] && files+=("$W/x/$f"); done < "$W/install.list"
  note "install: $(tr '\n' ' ' < "$W/install.list")"
  local status
  adb install-multiple -r -g "${files[@]}" > "$OUT/install.txt" 2>&1 || true
  if ! grep -q '^Success' "$OUT/install.txt"; then
    adb install-multiple -r -g --abi arm64-v8a "${files[@]}" >> "$OUT/install.txt" 2>&1 || true
  fi
  status=$(grep -oE '^Success|INSTALL_[A-Z_]+' "$OUT/install.txt" | tail -1 || true)
  say "install: ${status:-no answer} (${#files[@]} APKs: base, ABI, density, language)"
  if [ "$status" != Success ]; then
    say "PROBE: MX does not install on this image"
    return 1
  fi
  local abi; abi=$(adb shell dumpsys package "$MX_PACKAGE" | sed -n 's/.*primaryCpuAbi=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r')
  say "installed with primary ABI ${abi:-unknown}"

  # Permissions (granted by -g; named again for the record), and no network
  # for MX's uid: no ads, no tracking, nothing sent about the lab.
  local p
  for p in android.permission.READ_MEDIA_VIDEO android.permission.POST_NOTIFICATIONS \
           android.permission.READ_EXTERNAL_STORAGE android.permission.WRITE_EXTERNAL_STORAGE; do
    adb shell pm grant "$MX_PACKAGE" "$p" >/dev/null 2>&1 || true
  done
  # "All files access": with READ_EXTERNAL_STORAGE alone MX showed its own
  # storage screen on Android 11 and left (run 44989696334).
  adb shell appops set --uid "$MX_PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 \
    || adb shell appops set "$MX_PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
  adb shell dumpsys package "$MX_PACKAGE" > "$OUT/package.txt" 2>/dev/null || true
  adb shell appops get "$MX_PACKAGE" > "$OUT/appops.txt" 2>/dev/null || true
  say "permissions: $(grep -cE 'permission\.[A-Z_]+: granted=true' "$OUT/package.txt" || true) granted; all files access $(grep -c 'MANAGE_EXTERNAL_STORAGE: allow' "$OUT/appops.txt" || true)"
  local cut=0 t
  MX_UID=$(adb shell pm list packages -U "$MX_PACKAGE" | sed -n "s/^package:$MX_PACKAGE uid:\([0-9]*\).*/\1/p" | head -1 | tr -d '\r')
  if [ "$ROOT" = 1 ] && [ -n "$MX_UID" ]; then
    for t in iptables ip6tables; do
      adb shell "$t -I OUTPUT 1 -m owner --uid-owner $MX_UID -j REJECT" >/dev/null 2>&1 \
        || adb shell "$t -I OUTPUT 1 -m owner --uid-owner $MX_UID -j DROP" >/dev/null 2>&1 \
        && cut=$((cut + 1))
    done
  fi
  say "network: MX's uid cut on $cut of 2 tables (IPv4, IPv6)"
  [ "$cut" = 2 ] || { say "PROBE: stopped before MX ran, its network is not cut"; return 1; }
}

# MX answers a video with two activities, its player and its pop-up player,
# so "-p" alone brought Android's "Open with" chooser and MX never ran (run
# 44989031141); by name, the PiP one sorts first (run 44989696334). The
# player: the first in Android's order that is not a pop-up. Its name goes
# to innocent-ref only.
resolve_mx() {
  adb shell cmd package query-activities --brief -a android.intent.action.VIEW \
    -d "file://$1" -t video/mp4 > "$OUT/resolve.txt" 2>&1 || true
  local comps
  comps=$(grep -oE "$MX_PACKAGE/[A-Za-z0-9_.\$]+" "$OUT/resolve.txt" | awk '!seen[$0]++' || true)
  MX_COMP=$(printf '%s\n' "$comps" | grep -viE 'pop|pip|float' | head -1 || true)
  say "MX answers the film with $(printf '%s\n' "$comps" | grep -c . || true) activities; opening the one that is not the pop-up ($([ -n "$MX_COMP" ] && echo found || echo none))"
  [ -n "$MX_COMP" ]
}

# The screen and its tree, at once: $1 mx|inn, $2 the name. MX's tree from
# Android's own dumpsys (its view tree and its popup windows' frames),
# Innocent's from uiautomator (Flutter's semantics; it idles).
grab() {
  adb exec-out screencap -p > "$OUT/$2.png" 2>/dev/null || true
  if [ "$1" = mx ]; then
    mkdir -p "$OUT/raw"
    adb shell dumpsys activity top > "$OUT/raw/$2.top.txt" 2>/dev/null || true
    adb shell dumpsys window windows > "$OUT/raw/$2.win.txt" 2>/dev/null || true
    UI hier "$OUT/raw/$2.top.txt" "$OUT/raw/$2.win.txt" "$MX_PACKAGE" > "$OUT/$2.xml" || true
  else
    dump "$OUT/$2.xml" || echo '<hierarchy/>' > "$OUT/$2.xml"
  fi
}

run() {
  rm -rf "$OUT"; mkdir -p "$OUT"
  setup_device
  install_mx || { kill "$LOGCAT" 2>/dev/null || true; return 0; }
  local root=$ROOT uid=$MX_UID

  # THE FILM, opened in MX by the intent a file manager sends.
  adb push "$FILM" /sdcard/Movies/ref_measure.mp4 >/dev/null
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  resolve_mx /sdcard/Movies/ref_measure.mp4 || { kill "$LOGCAT" 2>/dev/null || true; say "PROBE: no MX player activity for a video"; return 0; }
  adb shell am start -W -a android.intent.action.VIEW -t video/mp4 \
    -d file:///sdcard/Movies/ref_measure.mp4 -n "$MX_COMP" > "$OUT/launch.txt" 2>&1 || true
  local lst ltime
  lst=$(sed -n 's/^Status: //p' "$OUT/launch.txt" | tr -d '\r' | head -1)
  ltime=$(sed -n 's/^TotalTime: //p' "$OUT/launch.txt" | tr -d '\r' | head -1)
  say "launch: ${lst:-no status}, ${ltime:-?} ms to the first activity"

  # FIRST RUN: a consent, a language, a permission — tapped through. The same
  # screen twice in a row means the last tap did nothing: try the next button.
  local r skip=0 last="" h xy taps=0
  for r in $(seq 1 10); do
    sleep 3
    dump "$OUT/ui_firstrun_$r.xml" || continue
    h=$(sha1sum < "$OUT/ui_firstrun_$r.xml" | cut -c1-12)
    if [ "$h" = "$last" ]; then skip=$((skip + 1)); else skip=0; fi
    last=$h
    xy=$(UI firstrun "$OUT/ui_firstrun_$r.xml" "$skip")
    [ -n "$xy" ] || break
    note "first run, round $r: tapped $xy (choice $skip)"
    # shellcheck disable=SC2086
    adb shell input tap $xy
    taps=$((taps + 1))
  done
  say "first run: $taps tap(s) on its screens"

  # THE CONTROLS: let any shown at the start hide, then tap the picture and
  # take the screen at once (they hide again after a few seconds). The tree
  # from dumpsys: uiautomator never found MX's player idle (run 44990303466).
  sleep 7
  local wh w hh shot=0 c0 c1 c2
  wh=$(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r'); w=${wh%x*}; hh=${wh#*x}
  adb shell input tap $((w / 2)) $((hh * 45 / 100))
  grab mx shot_controls
  mv "$OUT/shot_controls.xml" "$OUT/ui_controls.xml" 2>/dev/null || true
  [ -s "$OUT/shot_controls.png" ] && shot=1
  read -r c0 c1 c2 < <(UI count "$OUT/ui_controls.xml" "$MX_PACKAGE" || echo "0 0 0")
  local orient; orient=$(adb shell dumpsys input | grep -m1 -oE 'SurfaceOrientation: [0-9]' | awk '{print $2}' | tr -d '\r')
  say "controls: $c0 of MX's views on screen, $c1 clickable, $c2 seek bar(s); orientation ${orient:-?}; screenshot $shot"

  adb shell dumpsys activity activities > "$OUT/activities.txt" 2>/dev/null || true
  adb shell dumpsys media_session > "$OUT/media_session.txt" 2>/dev/null || true
  local resumed playing
  resumed=$(grep -E 'mResumedActivity|topResumedActivity' "$OUT/activities.txt" | grep -c "$MX_PACKAGE" || true)
  playing=$(awk -v p="package=$MX_PACKAGE" 'index($0, p) {m=40} m-- > 0 && /state=PlaybackState \{state=3/ {n++} END {print n+0}' "$OUT/media_session.txt")

  # Did anything die? The translator's own crash shows in a backtrace.
  sleep 3
  local alive=0 blocked
  adb shell pidof "$MX_PACKAGE" >/dev/null 2>&1 && alive=1
  blocked=$(adb shell "iptables -L OUTPUT -v -n -x" 2>/dev/null | tr -d '\r' \
    | awk -v u="$uid" '$0 ~ ("owner UID match " u "( |$)") {print $1; exit}')
  adb shell "ls /data/tombstones" > "$OUT/tombstones.txt" 2>/dev/null || true
  kill "$LOGCAT" 2>/dev/null || true
  local L="$OUT/logcat_raw.txt" sigill fsig fexc ndkbt anr died
  sigill=$(grep -c 'SIGILL' "$L" || true)
  fsig=$(grep -c 'Fatal signal' "$L" || true)
  fexc=$(grep -c 'FATAL EXCEPTION' "$L" || true)
  ndkbt=$(grep 'libndk_translation' "$L" | grep -cE '#[0-9]+ pc|backtrace' || true)
  anr=$(grep -c "ANR in $MX_PACKAGE" "$L" || true)
  died=$(grep -E "Process $MX_PACKAGE .*has died" "$L" | grep -vc 'Force stopping' || true)
  say "MX resumed $resumed, its media session playing $playing, alive at the end $alive"
  say "crashes: SIGILL $sigill, fatal signal $fsig, fatal exception $fexc, translator in a backtrace $ndkbt, ANR $anr, MX process died $died; packets MX tried and was refused: ${blocked:-?}"
  if [ "$alive" = 1 ] && [ "$resumed" -gt 0 ] && [ "$c0" -gt 0 ] && [ "$sigill" = 0 ] && [ "$fsig" = 0 ]; then
    say "PROBE: MX RUNS on this image (installed, opened the film, controls shown, no crash)"
  elif [ "$resumed" = 0 ] && [ "$sigill" = 0 ] && [ "$fsig" = 0 ]; then
    say "PROBE: MX was not in front at the end, with no crash (see the screen in innocent-ref)"
  else
    say "PROBE: MX does NOT run cleanly on this image (see the numbers above; the screens and logs are in innocent-ref)"
  fi
  gzip -9 "$L"
}

INN_PACKAGE=com.innocent.media
INN_APK="${INN_APK:-$T/inn/lab.apk}"
pkg_of() { if [ "$1" = mx ]; then echo "$MX_PACKAGE"; else echo "$INN_PACKAGE"; fi; }

# Innocent's x86_64 lab build (device-lab.yml's): our own app, beside MX.
install_inn() {
  adb install -r -g "$INN_APK" > "$OUT/install_inn.txt" 2>&1 || true
  local st p
  st=$(grep -oE '^Success|INSTALL_[A-Z_]+' "$OUT/install_inn.txt" | tail -1 || true)
  say "Innocent (the x86_64 lab build of this commit): install ${st:-no answer}"
  [ "$st" = Success ] || return 1
  for p in READ_EXTERNAL_STORAGE READ_MEDIA_VIDEO POST_NOTIFICATIONS; do
    adb shell pm grant "$INN_PACKAGE" "android.permission.$p" >/dev/null 2>&1 || true
  done
  # "All files access", which the app declares: with READ_EXTERNAL_STORAGE
  # alone Android 11 refused it the lab's films ("Permission denied", every
  # open of run 45030566139; two in 45019756405).
  adb shell appops set --uid "$INN_PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 \
    || adb shell appops set "$INN_PACKAGE" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1 || true
}

# A film handed over as a file manager does: $1 mx|inn, $2 its path.
open_film() {
  local comp="$MX_COMP"
  [ "$1" = mx ] || comp="$INN_PACKAGE/.MainActivity"
  adb shell am start -W -a android.intent.action.VIEW -t video/mp4 -d "file://$2" -n "$comp" >/dev/null 2>&1 || true
}

# A quick tree for a check: MX's from dumpsys (its view tree only),
# Innocent's from uiautomator.
quick_tree() {
  mkdir -p "$OUT/raw"
  if [ "$1" = mx ]; then
    adb shell dumpsys activity top > "$OUT/raw/quick.top.txt" 2>/dev/null || true
    UI hier "$OUT/raw/quick.top.txt" /dev/null "$MX_PACKAGE" > "$2" || true
  else
    dump "$2" || echo '<hierarchy/>' > "$2"
  fi
}

# The controls up, checked in the tree rather than assumed: a tap on the
# picture shows them when hidden and HIDES them when up (run 44991688519:
# MX's were still up twelve seconds after the open, and the lab's tap put
# them away). Leaves the top bar's buttons in BTNS, rightmost first (⋮, HW,
# CC, ♪ where the app has them there); false if never up.
BTNS=()
ensure_controls() {
  local i
  for i in 1 2 3 4; do
    quick_tree "$1" "$OUT/raw/quick.xml"
    mapfile -t BTNS < <(UI topbar "$OUT/raw/quick.xml" "$(pkg_of "$1")" "$2" "$3" "$PROBE_DPI")
    # Up: at least ⋮ and HW (upright, MX keeps only those two in its top
    # bar, run 44997097342).
    [ "${#BTNS[@]}" -ge 2 ] && return 0
    adb shell input tap $(($2 / 2)) $(($3 / 2))
    sleep 0.7
  done
  return 1
}

# Innocent decodes in software here: on this image libmpv's hardware decoder
# (the emulator's goldfish H.264) stalled and the player gave up ("Playback
# failed", run 44991688519). The lab sets the app's own Development switch
# (Settings, Development, disable hardware acceleration) in its preferences.
inn_software_decoding() {
  local f=/data/data/$INN_PACKAGE/shared_prefs/FlutterSharedPreferences.xml x="$OUT/raw/inn_prefs.xml" uid
  mkdir -p "$OUT/raw"
  adb shell am force-stop "$INN_PACKAGE"
  adb shell "cat $f" > "$x" 2>/dev/null || true
  grep -q '<map' "$x" || printf "<?xml version='1.0' encoding='utf-8' standalone='yes' ?>\n<map>\n</map>\n" > "$x"
  grep -q 'pref_player_devDisableHwAccel' "$x" \
    || sed -i 's#</map>#    <boolean name="flutter.pref_player_devDisableHwAccel" value="true" />\n</map>#' "$x"
  sed -i 's#\(name="flutter.pref_player_devDisableHwAccel" value="\)false"#\1true"#' "$x"
  uid=$(adb shell stat -c %u "/data/data/$INN_PACKAGE" | tr -d '\r')
  adb push "$x" /data/local/tmp/inn_prefs.xml >/dev/null
  adb shell "mkdir -p /data/data/$INN_PACKAGE/shared_prefs && cp /data/local/tmp/inn_prefs.xml $f && chown $uid:$uid /data/data/$INN_PACKAGE/shared_prefs $f && chmod 660 $f && restorecon -R /data/data/$INN_PACKAGE/shared_prefs" >/dev/null 2>&1 || true
  adb shell "cat $f" > "$x.after" 2>/dev/null || true
  say "Innocent: software decoding set for the lab ($(grep -c 'devDisableHwAccel" value="true' "$x.after" || true) of 1)"
}

# MX builds a font cache for its subtitles once ("Building font cache...",
# a prompt at the foot of its player: FontCachePromptBasePromotionView in
# its tree). In run 45781933354 the prompt was up on every MX screen after
# a 25 s warm-up, so no MX screen showed MX's own subtitle; the owner wants
# to see where MX puts it sideways under an open ⋮ (26 Nov). Wait for the
# prompt to go, with the film playing (reopened if it ends). Run 45796876490
# waited 6 min and it never went: 90 s now, and the films carry an .srt.
warm_mx() {
  local t0=$SECONDS top
  open_film mx /sdcard/Movies/ref_land_black.mp4
  sleep 20
  while [ $((SECONDS - t0)) -lt 90 ]; do
    top=$(adb shell dumpsys activity top 2>/dev/null || true)
    if ! printf '%s\n' "$top" | grep -q "ACTIVITY $MX_COMP "; then
      open_film mx /sdcard/Movies/ref_land_black.mp4
      sleep 10
      continue
    fi
    if ! printf '%s\n' "$top" | grep -q 'FontCachePromptBasePromotionView'; then
      say "MX's font cache prompt gone after $((SECONDS - t0)) s"
      grab mx warm_mx
      adb shell am force-stop "$MX_PACKAGE"
      return 0
    fi
    sleep 10
  done
  say "MX's font cache prompt still up after $((SECONDS - t0)) s"
  grab mx warm_mx
  adb shell am force-stop "$MX_PACKAGE"
}

# PHASE 1: the panels that rise (⋮, ♪, CC) of both apps, upright and
# sideways, over a black and a white frame. Each screen from a fresh open of
# its own copy of the film (neither app resumes or asks), so the frame is
# the film's first 40 s. Upright: an upright film (720x1280), each app
# turning itself as it does for a phone's own video. Sideways: the wide film
# with the lab holding the screen sideways. The top bar's buttons are found
# by place (the last four, rightmost first: ⋮, HW, CC, ♪; both apps keep
# that order, ui-design §4), never by MX's names; the controls are checked
# up in the tree before each tap.
panels() {
  rm -rf "$OUT"; mkdir -p "$OUT/raw"
  setup_device
  install_mx || { kill "$LOGCAT" 2>/dev/null || true; return 0; }
  install_inn || { kill "$LOGCAT" 2>/dev/null || true; return 0; }
  local pw=${PROBE_SIZE%x*} ph=${PROBE_SIZE#*x}
  echo "$pw $ph $PROBE_DPI" > "$OUT/display.txt"

  local o f sc dir src
  adb push "$FILM" /sdcard/Movies/ref_land_black.mp4 >/dev/null
  adb push "$FILM_W" /sdcard/Movies/ref_land_white.mp4 >/dev/null
  adb push "$FILM_P" /sdcard/Movies/ref_port_black.mp4 >/dev/null
  adb push "$FILM_PW" /sdcard/Movies/ref_port_white.mp4 >/dev/null
  adb shell "mkdir -p /sdcard/Movies/ref_warm && cp /sdcard/Movies/ref_land_black.mp4 /sdcard/Movies/ref_warm/innocent_lab_play.mp4"
  # MX's copy also gets the English track as a sidecar .srt (MX opens a
  # file's same-named .srt by itself): MX draws no embedded subtitle until
  # its font cache is built, and on this image the cache never finished
  # (run 45796876490: its prompt still up after 6 min). An .srt may reach
  # MX's own text renderer instead. Innocent's copy keeps the film alone.
  adb push "$T/film/sub0.srt" /sdcard/Movies/ref_sub.srt >/dev/null
  for o in port land; do for f in black white; do for sc in controls more audio cc; do
    dir=/sdcard/Movies/ref_${o}_${f}_${sc}; src=/sdcard/Movies/ref_${o}_${f}.mp4
    adb shell "mkdir -p $dir && cp $src $dir/innocent_lab_play.mp4 && cp $src $dir/ref_$sc.mp4 && cp /sdcard/Movies/ref_sub.srt $dir/ref_$sc.srt"
  done; done; done
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  resolve_mx /sdcard/Movies/ref_land_black.mp4 || { kill "$LOGCAT" 2>/dev/null || true; say "PANELS: no MX player activity"; return 0; }
  adb shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
  adb shell settings put system user_rotation 0 >/dev/null 2>&1 || true

  # One open of each first: MX's one-time font cache for subtitles, the
  # Innocent lab build's start (which writes its preferences); a screen of
  # each for the record.
  warm_mx
  open_film inn /sdcard/Movies/ref_warm/innocent_lab_play.mp4; sleep 20; grab inn warm_inn
  inn_software_decoding

  local total=0
  if [ "${SCREENS:-panels}" = fps ]; then
    fps_votes
  elif [ "${SCREENS:-panels}" = shortcuts ]; then
    shortcut_screens
  else
    panel_screens
  fi

  local blocked L="$OUT/logcat_raw.txt"
  blocked=$(adb shell "iptables -L OUTPUT -v -n -x" 2>/dev/null | tr -d '\r' \
    | awk -v u="$MX_UID" '$0 ~ ("owner UID match " u "( |$)") {print $1; exit}')
  kill "$LOGCAT" 2>/dev/null || true
  say "crashes: SIGILL $(grep -c 'SIGILL' "$L" || true), fatal signal $(grep -c 'Fatal signal' "$L" || true), fatal exception $(grep -c 'FATAL EXCEPTION' "$L" || true); Innocent playback failed $(grep -c 'engine stuck' "$L" || true); packets MX tried and was refused: ${blocked:-?}"
  [ "${SCREENS:-panels}" = panels ] && say "PANELS: $total of 24 panel screens taken (2 apps x 2 orientations x 2 frames x 3 panels)"
  gzip -9 "$L"
}

# SCREENS=fps (27 Nov 2026, docs/handoff_2026_11_27_beyond_mx.md P2/P3):
# does MX tell Android the film's frame rate (Surface.setFrameRate, a vote
# SurfaceFlinger keeps per layer) or ask the window for a display mode or
# refresh rate (preferredDisplayModeId / preferredRefreshRate)? The 24 fps
# measuring film playing sideways in each app, 12 s in: SurfaceFlinger's
# whole dump and the window's attributes to innocent-ref (MX's dumps stay
# private); the summary says only the votes' values, per app.
fps_votes() {
  local app pkg d w votes
  for app in mx inn; do
    pkg=$(pkg_of "$app")
    adb shell am force-stop "$pkg" >/dev/null 2>&1 || true
    open_film "$app" /sdcard/Movies/ref_land_black.mp4
    sleep 12
    d="$OUT/raw/fps_${app}_sf.txt"; w="$OUT/raw/fps_${app}_window.txt"
    adb shell dumpsys SurfaceFlinger 2>/dev/null | tr -d '\r' > "$d" || true
    adb shell dumpsys window windows 2>/dev/null | tr -d '\r' > "$w" || true
    grab "$app" "fps_$app"
    # The votes: SurfaceFlinger's per-layer frame rate (named
    # frameRate=/FrameRate in API 30-36 dumps), values only.
    votes=$(grep -ioE 'frame ?rate[=: ]+\{?[0-9.]+[^,}]*' "$d" | grep -vE '[=: ]0(\.0+)?( |$)' | sort | uniq -c | tr '\n' ';' || true)
    say "FPS $app: layer votes ${votes:-none}; window asks $(grep -oE 'preferred(RefreshRate|DisplayModeId|MinDisplayRefreshRate|MaxDisplayRefreshRate)=[0-9.]+' "$w" | grep -vE '=0(\.0)?$' | sort -u | tr '\n' ' ' || true)"
    say "FPS $app: display $(grep -m1 -oE '(activeMode|mActiveMode|refresh-rate)[^,]*' "$d" || echo '?')"
    adb shell am force-stop "$pkg" >/dev/null 2>&1 || true
  done
}

# PHASE 2 (26 Nov 2026, the owner: "every shortcut as MX's — what it does
# and the screen it brings, exactly; ⋮ as MX's 11 tiles and More"):
# SCREENS=shortcuts. Sideways over the black frame, for each app: the
# expanded row; then each shortcut tapped from a fresh open of its own copy
# of the film (neither app resumes). What it opened (a panel, a page: new
# nodes in the tree) is taken and closed with Back; a toggle (nothing new
# in the tree: a toast, a state) is taken, tapped again and taken again
# (_2: the other state, put back). Pass 2 swipes the expanded row to its
# end for the shortcuts past the screen's edge (some come twice). Then ⋮:
# its first page, its lower part, and MX's last tile ("More ›"). MX's tree
# has no words: its shortcuts are told apart on the screenshots.
SLOTS=()
ITEMS=()
sc_fresh() {  # $1 app, $2 copy: open it, paused, the controls up (BTNS)
  local dir=/sdcard/Movies/ref_sc_$2
  adb shell am force-stop "$(pkg_of "$1")"
  if [ "$1" = mx ]; then open_film mx "$dir/ref_sc$2.mp4"; sleep 6
  else open_film inn "$dir/innocent_lab_play.mp4"; sleep 9; fi
  adb shell input keyevent KEYCODE_MEDIA_PAUSE
  sleep 1
  ensure_controls "$1" "$SW" "$SH"
}
sc_ready() {  # $1 app, $2 copy, $3 pass: the row expanded (ITEMS), at its end in pass 2
  local line cx cy x y
  sc_fresh "$1" "$2" || return 1
  mapfile -t SLOTS < <(UI shortcuts "$OUT/raw/quick.xml" "$(pkg_of "$1")" "$PROBE_DPI")
  line=$(printf '%s\n' "${SLOTS[@]}" | grep ' chevron ' | head -1 || true)
  # More than six on the row: it is open already (Innocent keeps it open
  # from the last film, run 45857557804); else open it.
  if [ "$(printf '%s\n' "${SLOTS[@]}" | grep -c ' item ' || true)" -le 6 ]; then
    [ -n "$line" ] || return 1
    read -r cx cy _ <<< "$line"
    adb shell input tap "$cx" "$cy"
    sleep 1.5
    quick_tree "$1" "$OUT/raw/quick.xml"
  fi
  mapfile -t ITEMS < <(UI shortcuts "$OUT/raw/quick.xml" "$(pkg_of "$1")" "$PROBE_DPI" | grep ' item ' || true)
  if [ "$3" = 2 ] && [ "${#ITEMS[@]}" -gt 0 ]; then
    # A slow drag, not a fling: a fast swipe across MX's open row closed it
    # (run 45857557804).
    read -r x y _ <<< "${ITEMS[0]}"
    adb shell input swipe $((SW * 80 / 100)) "$y" $((SW * 20 / 100)) "$y" 1500
    sleep 1
    adb shell input swipe $((SW * 80 / 100)) "$y" $((SW * 20 / 100)) "$y" 1500
    sleep 1.5
    quick_tree "$1" "$OUT/raw/quick.xml"
    mapfile -t ITEMS < <(UI shortcuts "$OUT/raw/quick.xml" "$(pkg_of "$1")" "$PROBE_DPI" | grep ' item ' || true)
  fi
  [ "${#ITEMS[@]}" -gt 0 ]
}
sc_more() {  # $1 app: ⋮ open (from BTNS); true when its panel came
  local ax ay bx by k n
  if [ "$1" = inn ] && [ "${#BTNS[@]}" = 3 ]; then
    read -r ax ay <<< "${BTNS[0]}"; read -r bx by <<< "${BTNS[1]}"
    BTNS=("$((2 * ax - bx)) $ay" "${BTNS[@]}")
  fi
  [ -n "${BTNS[0]:-}" ] || return 1
  cp "$OUT/raw/quick.xml" "$OUT/raw/before.xml"
  # shellcheck disable=SC2086
  adb shell input tap ${BTNS[0]}
  for k in 1 2 3 4 5 6; do
    sleep 1
    quick_tree "$1" "$OUT/raw/quick.xml"
    n=$(UI added "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$(pkg_of "$1")" || echo 0)
    [ "${n:-0}" -ge 3 ] && return 0
  done
  return 1
}
shortcut_screens() {
  local app i pass k n idx got name x y kind lab added dir src tiles
  local TILES=()
  SW=$ph; SH=$pw
  # The white-first film: a shade, a dimming (Night Mode) and a toast show
  # over white, where over black they did not (run 45857557804).
  src=/sdcard/Movies/ref_land_white.mp4
  for i in $(seq 0 27); do
    dir=/sdcard/Movies/ref_sc_$i
    adb shell "mkdir -p $dir && cp $src $dir/innocent_lab_play.mp4 && cp $src $dir/ref_sc$i.mp4 && cp /sdcard/Movies/ref_sub.srt $dir/ref_sc$i.srt"
  done
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  adb shell wm set-fix-to-user-rotation enabled >/dev/null 2>&1 || true
  adb shell settings put system user_rotation 1 >/dev/null 2>&1 || true
  sleep 2
  for app in mx inn; do
    idx=0; got=0
    for pass in 1 2; do
      if ! sc_ready "$app" "$idx" "$pass"; then
        note "$app pass $pass: the row never opened"; grab "$app" "${app}_land_norow_$pass"; continue
      fi
      n=${#ITEMS[@]}
      grab "$app" "${app}_land_expanded_$pass"
      note "$app pass $pass: $n shortcuts on screen ($(printf '%s ' "${ITEMS[@]##* }"))"
      # From the last to the first: a toggle left on moves out of the open
      # row's first part (MX's Loop, run 45857557804) and shifts the ones
      # after it, never the ones before. Pass 2 (the row dragged to its
      # end): only the last three, past the edge in pass 1.
      local ks
      if [ "$pass" = 1 ]; then ks=$(seq $((n - 1)) -1 0); else ks=$(seq $((n - 1)) -1 $((n > 3 ? n - 3 : 0))); fi
      for k in $ks; do
        idx=$((idx + 1))
        [ "$idx" -le 27 ] || break
        sc_ready "$app" "$idx" "$pass" || { note "$app pass $pass slot $k: the row never opened"; continue; }
        [ "$k" -lt "${#ITEMS[@]}" ] || { note "$app pass $pass slot $k: not on screen this time"; continue; }
        read -r x y kind lab <<< "${ITEMS[$k]}"
        name="${app}_land_sc${pass}_$(printf %02d "$k")"
        [ "$app" = inn ] && name="${name}_${lab}"
        cp "$OUT/raw/quick.xml" "$OUT/raw/before.xml"
        adb shell input tap "$x" "$y"
        # A toast lasts 2-3.5 s: the screen at once, the tree after.
        sleep 1.2
        adb exec-out screencap -p > "$OUT/${name}_t.png" 2>/dev/null || true
        sleep 1.3
        quick_tree "$app" "$OUT/raw/quick.xml"
        added=$(UI added "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$(pkg_of "$app")" || echo 0)
        grab "$app" "$name"
        got=$((got + 1))
        if [ "${added:-0}" -ge 3 ]; then
          note "$name: opened something ($added new nodes); Back"
          adb shell input keyevent KEYCODE_BACK
          sleep 1
        else
          note "$name: nothing new in the tree (a toggle?); tapped again"
          adb shell input tap "$x" "$y"
          sleep 2
          grab "$app" "${name}_2"
        fi
      done
    done
    # ⋮: its first page and MX's last tile ("More ›"), then its lower part.
    idx=$((idx + 1))
    if sc_fresh "$app" "$idx" && sc_more "$app"; then
      grab "$app" "${app}_land_more"
      mapfile -t TILES < <(UI grid "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$(pkg_of "$app")" "$PROBE_DPI")
      tiles=${#TILES[@]}
      note "$app ⋮: $tiles buttons in the panel"
      if [ "$app" = mx ] && [ "$tiles" -gt 0 ]; then
        # The last tile of the grid (ui.py grid: tiles only, never the
        # switches' rows below them).
        # shellcheck disable=SC2086
        adb shell input tap ${TILES[$((tiles - 1))]}
        sleep 3
        grab mx mx_land_more2
        adb shell input swipe $((SW * 80 / 100)) $((SH * 85 / 100)) $((SW * 80 / 100)) $((SH * 15 / 100)) 800
        sleep 1.5
        grab mx mx_land_more2_low
      fi
    else
      note "$app ⋮: never opened"
    fi
    idx=$((idx + 1))
    if sc_fresh "$app" "$idx" && sc_more "$app"; then
      adb shell input swipe $((SW * 80 / 100)) $((SH * 85 / 100)) $((SW * 80 / 100)) $((SH * 15 / 100)) 500
      sleep 1.5
      grab "$app" "${app}_land_more_low"
    fi
    adb shell am force-stop "$(pkg_of "$app")"
    say "$app: $got shortcut screens taken; ⋮ $([ -f "$OUT/${app}_land_more.png" ] && echo taken || echo missing)"
  done
  adb shell wm set-fix-to-user-rotation disabled >/dev/null 2>&1 || true
  adb shell settings put system user_rotation 0 >/dev/null 2>&1 || true
}

# The panels of both apps (⋮, ♪, CC), upright and sideways, over black and
# white: SCREENS=panels (the default).
panel_screens() {
  local app w h idx n k rot tries got orient b0 b1 b2 b3 b4 b5 b6 b7 ax ay bx by xy
  local TILES=()
  for app in mx inn; do
    for o in port land; do
      if [ "$o" = port ]; then
        w=$pw; h=$ph
        adb shell wm set-fix-to-user-rotation disabled >/dev/null 2>&1 || true
        adb shell settings put system user_rotation 0 >/dev/null 2>&1 || true
      else
        w=$ph; h=$pw
        adb shell wm set-fix-to-user-rotation enabled >/dev/null 2>&1 || true
        adb shell settings put system user_rotation 1 >/dev/null 2>&1 || true
      fi
      sleep 2
      for f in black white; do
        got=0
        for sc in controls more audio cc; do
          dir=/sdcard/Movies/ref_${o}_${f}_${sc}
          for tries in 1 2; do
            adb shell am force-stop "$(pkg_of "$app")"
            if [ "$app" = mx ]; then open_film mx "$dir/ref_$sc.mp4"; else open_film inn "$dir/innocent_lab_play.mp4"; fi
            # Innocent's lab build pushes the player ~3 s after a cold start.
            if [ "$app" = mx ]; then sleep 6; else sleep 9; fi
            # Paused, both keep their controls up once shown (Innocent's
            # Phase 42, after MX): no race with the auto-hide while a tree
            # is read (Innocent's took longer than its 4 s, run 44994060537).
            adb shell input keyevent KEYCODE_MEDIA_PAUSE
            sleep 1
            # Which way the screen is, from a screenshot's own size (the
            # input's SurfaceOrientation read 0 sideways, run 44997097342).
            rot=$(adb exec-out screencap -p 2>/dev/null | head -c 24 | od -An -tu1 -j16 -N8 | tr -s ' ' | sed 's/^ //')
            read -r b0 b1 b2 b3 b4 b5 b6 b7 <<< "${rot:-0 0 0 0 0 0 0 0}"
            w=$(( (b0 << 24) + (b1 << 16) + (b2 << 8) + b3 )); h=$(( (b4 << 24) + (b5 << 16) + (b6 << 8) + b7 ))
            [ "$w" -gt 0 ] && [ "$h" -gt 0 ] || { if [ "$o" = port ]; then w=$pw; h=$ph; else w=$ph; h=$pw; fi; }
            if { [ "$o" = port ] && [ "$w" -gt "$h" ]; } || { [ "$o" = land ] && [ "$w" -lt "$h" ]; }; then
              note "$app $o $f $sc: the app turned itself the other way (${w}x${h})"
              grab "$app" "${app}_${o}_${f}_${sc}_turned"
              break
            fi
            if ! ensure_controls "$app" "$w" "$h"; then
              note "$app $o $f $sc: the controls never came up (try $tries)"
              [ "$tries" = 2 ] && grab "$app" "${app}_${o}_${f}_${sc}_nocontrols"
              continue
            fi
            # Innocent sideways: its ⋮ lies past the end of its own
            # accessibility root, which stops 96 dp short of the screen on
            # this phone (run 44999637142), so the tree has three buttons.
            # It sits one step right of HW, as the row is spaced.
            if [ "$app" = inn ] && [ "${#BTNS[@]}" = 3 ]; then
              read -r ax ay <<< "${BTNS[0]}"; read -r bx by <<< "${BTNS[1]}"
              BTNS=("$((2 * ax - bx)) $ay" "${BTNS[@]}")
              note "$app $o $f $sc: ⋮ is not in the tree; tapped one step right of HW"
            fi
            if [ "$sc" = controls ]; then
              grab "$app" "${app}_${o}_${f}_controls"
              break
            fi
            case "$sc" in more) idx=0 ;; cc) idx=2 ;; audio) idx=3 ;; esac
            cp "$OUT/raw/quick.xml" "$OUT/raw/before.xml"
            if [ -z "${BTNS[$idx]:-}" ]; then
              # MX upright keeps only HW and ⋮ in its top bar; ♪ and CC are
              # the first two buttons of its ⋮ panel (run 44999637142).
              # Innocent's ♪ and CC are on its bar both ways; if a narrow
              # bar ever leaves them to ⋮, its tiles read clickable="false"
              # in uiautomator (run 45885319037): found by their labels.
              if [ -n "${BTNS[0]:-}" ]; then
                # shellcheck disable=SC2086
                adb shell input tap ${BTNS[0]}
                for k in 1 2 3 4 5 6; do
                  sleep 1
                  quick_tree "$app" "$OUT/raw/quick.xml"
                  [ "$(UI added "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$(pkg_of "$app")" || echo 0)" -ge 3 ] && break
                done
                if [ "$app" = mx ]; then
                  mapfile -t TILES < <(UI tiles "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$MX_PACKAGE")
                else
                  TILES=("$(UI labelled "$OUT/raw/quick.xml" '^Audio track' || true)"
                         "$(UI labelled "$OUT/raw/quick.xml" '^Subtitle' || true)")
                fi
                if [ "$sc" = audio ]; then xy=${TILES[0]:-}; else xy=${TILES[1]:-}; fi
                [ -n "$xy" ] || { note "$app $o $f $sc: not in the top bar, and ⋮ held no button for it"; break; }
                note "$app $o $f $sc: not in the top bar; opened from ⋮"
                cp "$OUT/raw/quick.xml" "$OUT/raw/before.xml"
                # shellcheck disable=SC2086
                adb shell input tap $xy
              else
                note "$app $o $f $sc: not in the top bar (it has ${#BTNS[@]} buttons)"
                grab "$app" "${app}_${o}_${f}_${sc}_notinbar"
                break
              fi
            else
              # shellcheck disable=SC2086
              adb shell input tap ${BTNS[$idx]}
            fi
            # The panel can take seconds to come under translation (run
            # 44994060537: MX's ⋮ came after the screen was taken).
            n=0
            for k in 1 2 3 4 5 6; do
              sleep 1
              quick_tree "$app" "$OUT/raw/quick.xml"
              n=$(UI added "$OUT/raw/before.xml" "$OUT/raw/quick.xml" "$(pkg_of "$app")" || echo 0)
              [ "${n:-0}" -ge 3 ] && break
            done
            sleep 1
            grab "$app" "${app}_${o}_${f}_${sc}"
            n=$(UI added "$OUT/raw/before.xml" "$OUT/${app}_${o}_${f}_${sc}.xml" "$(pkg_of "$app")" || echo 0)
            note "$app $o $f $sc: the panel added $n nodes (try $tries)"
            [ "${n:-0}" -ge 3 ] && { got=$((got + 1)); break; }
          done
        done
        orient=$(adb shell dumpsys input | grep -m1 -oE 'SurfaceOrientation: [0-9]' | awk '{print $2}' | tr -d '\r')
        adb shell am force-stop "$(pkg_of "$app")"
        total=$((total + got))
        say "$app $o over $f: controls $([ -f "$OUT/${app}_${o}_${f}_controls.xml" ] && echo taken || echo missing), panels taken $got of 3; orientation ${orient:-?}"
      done
    done
  done
  adb shell wm set-fix-to-user-rotation disabled >/dev/null 2>&1 || true
  adb shell settings put system user_rotation 0 >/dev/null 2>&1 || true

}

keep() {
  private
  [ -d "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null)" ] || { say "nothing to keep"; return 0; }
  echo "run ${GITHUB_RUN_ID:-local} of ${GITHUB_SHA:-?} (yannmh007/innocent reference-lab.yml, MODE=$MODE)" > "$OUT/RUN.txt"
  local dir="runs/$(date -u +%Y-%m-%d)_${GITHUB_RUN_ID:-local}" R="$T/ref_repo" branch i
  branch=$(gh api "repos/$REF_REPO" --jq .default_branch)
  rm -rf "$R"; mkdir -p "$R"; cd "$R"
  git init -q
  git remote add origin "https://github.com/$REF_REPO.git"
  git config --local "http.https://github.com/.extraheader" \
    "AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
  git config user.name "reference-lab"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  for i in 1 2 3 4; do
    git fetch -q --depth 1 origin "$branch"
    git checkout -q -f -B "$branch" FETCH_HEAD
    rm -rf "$dir"; mkdir -p "$dir"; cp -r "$OUT/." "$dir/"
    git add -A "$dir"
    git commit -q -m "reference lab: $MODE, run ${GITHUB_RUN_ID:-local}" || break
    if git push -q origin "HEAD:$branch"; then
      say "kept in innocent-ref: $dir ($(ls "$OUT" | wc -l) files, $(du -sh "$OUT" | cut -f1))"
      git config --local --unset-all "http.https://github.com/.extraheader" || true
      return 0
    fi
    sleep $((i * 5))
  done
  git config --local --unset-all "http.https://github.com/.extraheader" || true
  say "could not push to innocent-ref"; exit 1
}

case "${1:-}" in
  pull)  pull ;;
  check) check ;;
  film)  film ;;
  run)    run ;;
  panels) panels ;;
  keep)   keep ;;
  *) echo "usage: probe.sh pull|check|film|run|panels|keep" >&2; exit 2 ;;
esac
