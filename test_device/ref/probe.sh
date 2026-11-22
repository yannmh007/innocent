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
#   probe.sh keep   needs GH_TOKEN: innocent-ref is private; push what run
#                   left to runs/<date>_<run id>/
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
FILM="$T/film/ref_measure.mp4"
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
  ffmpeg -loglevel error -y \
    -t 40 -f lavfi -i "color=c=black:s=1280x720:r=24" \
    -t 40 -f lavfi -i "color=c=white:s=1280x720:r=24" \
    -t 20 -f lavfi -i "color=c=0x808080:s=1280x720:r=24" \
    -t 20 -f lavfi -i "cellauto=s=1280x720:r=24:rule=30:start_full=1:random_fill_ratio=0.5" \
    -t 20 -f lavfi -i "testsrc2=s=1280x720:r=24" \
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
    -disposition:a:0 default -disposition:s:0 default -movflags +faststart "$FILM"
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

run() {
  rm -rf "$OUT"; mkdir -p "$OUT"
  adb wait-for-device
  local abis bridge
  abis=$(adb shell getprop ro.product.cpu.abilist | tr -d '\r')
  bridge=$(adb shell getprop ro.dalvik.vm.native.bridge | tr -d '\r')
  say "device: Android $(adb shell getprop ro.build.version.release | tr -d '\r') (API $(adb shell getprop ro.build.version.sdk | tr -d '\r')), ABIs $abis, native bridge ${bridge:-none}"
  adb root >/dev/null 2>&1 || true
  adb wait-for-device
  local root=0; [ "$(adb shell id -u | tr -d '\r')" = 0 ] && root=1

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
  say "screen: physical $phys, now $(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r') at $(adb shell wm density | tail -1 | awk '{print $NF}' | tr -d '\r') dpi; three-button nav $nav, punch hole $hole; root $root"

  adb logcat -G 16M >/dev/null 2>&1 || true
  adb logcat -c || true
  adb logcat -v time > "$OUT/logcat_raw.txt" 2>&1 &
  local LOGCAT=$!

  # INSTALL: the splits manifest.json names for this device.
  UI splits "$W/x/manifest.json" "$PROBE_DPI" "$abis" > "$W/install.list"
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
    kill "$LOGCAT" 2>/dev/null || true
    say "PROBE: MX does not install on this image"
    return 0
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
  local uid cut=0 t
  uid=$(adb shell pm list packages -U "$MX_PACKAGE" | sed -n "s/^package:$MX_PACKAGE uid:\([0-9]*\).*/\1/p" | head -1 | tr -d '\r')
  if [ "$root" = 1 ] && [ -n "$uid" ]; then
    for t in iptables ip6tables; do
      adb shell "$t -I OUTPUT 1 -m owner --uid-owner $uid -j REJECT" >/dev/null 2>&1 \
        || adb shell "$t -I OUTPUT 1 -m owner --uid-owner $uid -j DROP" >/dev/null 2>&1 \
        && cut=$((cut + 1))
    done
  fi
  say "network: MX's uid cut on $cut of 2 tables (IPv4, IPv6)"
  [ "$cut" = 2 ] || { kill "$LOGCAT" 2>/dev/null || true; say "PROBE: stopped before MX ran, its network is not cut"; return 0; }

  # THE FILM, opened in MX by the intent a file manager sends.
  adb push "$FILM" /sdcard/Movies/ref_measure.mp4 >/dev/null
  adb shell content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1 || true
  # MX answers a video with two activities, its player and its pop-up
  # player, so "-p" alone brought Android's "Open with" chooser and MX never
  # ran (run 44989031141). The player is named: the one that is not the
  # pop-up (the names go to innocent-ref only).
  adb shell cmd package query-activities --brief -a android.intent.action.VIEW \
    -d file:///sdcard/Movies/ref_measure.mp4 -t video/mp4 > "$OUT/resolve.txt" 2>&1 || true
  local comps comp
  # In Android's order; not the pop-up (run 44989696334 took the PiP one,
  # which sorts first by name).
  comps=$(grep -oE "$MX_PACKAGE/[A-Za-z0-9_.\$]+" "$OUT/resolve.txt" | awk '!seen[$0]++' || true)
  comp=$(printf '%s\n' "$comps" | grep -viE 'pop|pip|float' | head -1 || true)
  say "MX answers the film with $(printf '%s\n' "$comps" | grep -c . || true) activities; opening the one that is not the pop-up ($([ -n "$comp" ] && echo found || echo none))"
  [ -n "$comp" ] || { kill "$LOGCAT" 2>/dev/null || true; say "PROBE: no MX player activity for a video"; return 0; }
  adb shell am start -W -a android.intent.action.VIEW -t video/mp4 \
    -d file:///sdcard/Movies/ref_measure.mp4 -n "$comp" > "$OUT/launch.txt" 2>&1 || true
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
  # take the screen at once (they hide again after a few seconds).
  sleep 7
  local wh w hh shot=0 c0 c1 c2
  wh=$(adb shell wm size | tail -1 | awk '{print $NF}' | tr -d '\r'); w=${wh%x*}; hh=${wh#*x}
  adb shell input tap $((w / 2)) $((hh * 45 / 100))
  adb exec-out screencap -p > "$OUT/shot_controls.png" 2>/dev/null && [ -s "$OUT/shot_controls.png" ] && shot=1
  if ! dump "$OUT/ui_controls.xml"; then
    # A screen that never settles: paused, the controls up again, once more.
    adb shell input keyevent KEYCODE_MEDIA_PAUSE
    sleep 1
    adb shell input tap $((w / 2)) $((hh * 45 / 100))
    adb exec-out screencap -p > "$OUT/shot_controls.png" 2>/dev/null || true
    dump "$OUT/ui_controls.xml" || true
  fi
  read -r c0 c1 c2 < <(UI count "$OUT/ui_controls.xml" "$MX_PACKAGE" || echo "0 0 0")
  local orient; orient=$(adb shell dumpsys input | grep -m1 -oE 'SurfaceOrientation: [0-9]' | awk '{print $2}' | tr -d '\r')
  say "controls: $c0 of MX's nodes on screen, $c1 clickable, $c2 seek bar(s); orientation ${orient:-?}; screenshot $shot"

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
  run)   run ;;
  keep)  keep ;;
  *) echo "usage: probe.sh pull|check|film|run|keep" >&2; exit 2 ;;
esac
