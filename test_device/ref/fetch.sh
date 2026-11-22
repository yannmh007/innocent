#!/usr/bin/env bash
# Reference lab, MODE=fetch — .github/workflows/reference-lab.yml says why
# each check is here. MX Player at MX_VERSION from APKPure (EFF's apkeep),
# kept as the release mx-<version> of the PRIVATE repository REF_REPO, and
# only if it is MX's own signed build.
#
#   fetch.sh reach   needs GH_TOKEN: the repository is reachable and private;
#                    writes kept=1 to GITHUB_OUTPUT when the release exists
#   fetch.sh get     no token: list, download, unpack, check
#   fetch.sh keep    needs GH_TOKEN: create the release from what get checked
#
# In: MX_PACKAGE MX_VERSION REF_REPO APKEEP, MX_CERT (optional: the signer's
# SHA-256 or SHA-1 from a second source). State between the steps lives in
# $RUNNER_TEMP/mx. Nothing of MX's is written into the repository checkout.
set -euo pipefail

SUM="${GITHUB_STEP_SUMMARY:-/dev/null}"
say() { printf '%s\n' "$*"; printf -- '- %s\n' "$*" >> "$SUM"; }
W="${RUNNER_TEMP:-/tmp}/mx"
TAG="mx-$MX_VERSION"

reach() {
  [ -n "${GH_TOKEN:-}" ] || { say "innocent-ref: the secret REF_REPO_TOKEN is not set"; exit 1; }
  local priv
  priv=$(gh api "repos/$REF_REPO" --jq .private 2>/dev/null) \
    || { say "innocent-ref: no access (the token, the repository it names, or its expiry)"; exit 1; }
  [ "$priv" = true ] || { say "innocent-ref is NOT private: nothing of MX's may go there"; exit 1; }
  say "innocent-ref: ok, private"
  if gh release view "$TAG" --repo "$REF_REPO" >/dev/null 2>&1; then
    say "$TAG is already kept in innocent-ref: nothing to fetch"
    echo "kept=1" >> "${GITHUB_OUTPUT:-/dev/null}"
  fi
}

BT=""
tools() {
  BT=$(ls -d "${ANDROID_HOME:?}"/build-tools/*/ | sort -V | tail -1)
  [ -x "${BT}aapt2" ] && [ -x "${BT}apksigner" ] || { say "no aapt2/apksigner in $BT"; exit 1; }
}

# One download: $1 a name, $2 the version, $3 the ABI asked of APKPure.
download() {
  mkdir -p "$W/$1/x"
  "$APKEEP" -a "$MX_PACKAGE@$2" -d apk-pure -o "acknowledge_dangers=true,arch=$3" "$W/$1" 2>&1 \
    | tr '\r' '\n' | grep -E 'Downloading|downloaded|Skipping|error' | tail -3 || true
  local f
  f=$(find "$W/$1" -maxdepth 1 -type f \( -name '*.apk' -o -name '*.xapk' \) | head -1)
  # apkeep's own reason is drawn on a progress bar, which a runner hides.
  [ -n "$f" ] || { rm -rf "${W:?}/$1"; return 1; }
  echo "$f" > "$W/$1.file"
  case "$f" in
    *.xapk) unzip -q -o "$f" '*.apk' -d "$W/$1/x" ;;
    *)      cp "$f" "$W/$1/x/" ;;
  esac
}

# The base APK of a download: the package's own file in an XAPK, base.apk,
# or the only APK.
base_of() {
  local d="$W/$1/x"
  for c in "$d/$MX_PACKAGE.apk" "$d/base.apk"; do [ -f "$c" ] && { echo "$c"; return; }; done
  ls -S "$d"/*.apk | head -1
}
# Google Play's source-stamp certificate (SHA-256): Play stamps the APKs it
# delivers, over their signatures, so a verified stamp by this certificate
# says the file is one Play handed out, unchanged. Read in run 44985917683
# from MX 3.4.3 as APKPure serves it, with "Verified for SourceStamp: true".
PLAY_STAMP_SHA256=3257d599a49d2c961a471ca9843f59d341a405884583fc087df4237b733bbd6d

# These print nothing on failure (never exit): the checks below say why.
# apksigner names the signer "Signer #1" or, with build-tools 37 on a v3
# APK, "V3.0 Signer:" (run 44985917683); either is read.
certs()  { "${BT}apksigner" verify --verbose --print-certs "$1" 2>/dev/null || true; }
digest() { certs "$1" | sed -n -E "s/^(Signer #1|V[0-9.]+ Signer:) certificate $2 digest: //p" | head -1; }
signer() { certs "$1" | sed -n -E 's/^(Signer #1|V[0-9.]+ Signer:) certificate DN: //p' | head -1; }
stamp()  { certs "$1" | awk '/^Verified for SourceStamp: true/ {ok=1}
                             ok && /^Source Stamp Signer: certificate SHA-256 digest: / {print $NF; exit}'; }
abis()   { for a in "$W/$1"/x/*.apk; do unzip -Z1 "$a" 2>/dev/null | sed -n 's#^lib/\([^/]*\)/.*#\1#p'; done | sort -u | tr '\n' ' '; }
badge()  { { "${BT}aapt2" dump badging "$1" 2>/dev/null || true; } | sed -n '1p' | sed -n "s/.* $2='\([^']*\)'.*/\1/p"; }

get() {
  tools
  rm -rf "$W"; mkdir -p "$W"
  "$APKEEP" -l -a "$MX_PACKAGE" -d apk-pure > "$W/versions.txt" 2>&1 || true
  { sed -n 's/^| //p' "$W/versions.txt" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -E '^[0-9][0-9A-Za-z._-]*$' || true; } \
    | sort -uV > "$W/vers"
  local n; n=$(wc -l < "$W/vers")
  [ "$n" -gt 0 ] || { say "APKPure lists no version of $MX_PACKAGE ($(head -c 200 "$W/versions.txt" | tr '\n' ' '))"; exit 1; }
  say "APKPure lists $n version(s) of $MX_PACKAGE, $(head -1 "$W/vers") to $(tail -1 "$W/vers")"
  grep -qxF "$MX_VERSION" "$W/vers" \
    || { say "NOT FOUND: $MX_VERSION is not among them; the newest are $(tail -6 "$W/vers" | tr '\n' ' ')"; exit 1; }

  # The build phones get (arm64-v8a) must come; an x86_64 build, which the
  # lab's emulator would run natively, only if APKPure has one (run
  # 44985066077: none for 3.4.3). The anchor: the oldest of the first three
  # listed releases that downloads.
  download arm64 "$MX_VERSION" arm64-v8a \
    || { say "download failed: $MX_PACKAGE $MX_VERSION for arm64-v8a"; exit 1; }
  local sets="arm64"
  if download x86_64 "$MX_VERSION" x86_64; then sets="arm64 x86_64"
  else say "APKPure has no x86_64 build of $MX_VERSION"; fi
  local oldest="" v
  for v in $(head -3 "$W/vers"); do
    [ "$v" = "$MX_VERSION" ] && break
    if download anchor "$v" arm64-v8a; then oldest="$v"; break; fi
  done

  # It is the app and the version asked for.
  local b pkg ver code
  b=$(base_of arm64)
  pkg=$({ "${BT}aapt2" dump badging "$b" 2>/dev/null || true; } | sed -n "1s/^package: name='\([^']*\)'.*/\1/p")
  ver=$(badge "$b" versionName); code=$(badge "$b" versionCode)
  [ "$pkg" = "$MX_PACKAGE" ] && [ "$ver" = "$MX_VERSION" ] \
    || { say "WRONG FILE: the base APK says package '$pkg' version '$ver'"; exit 1; }

  # Every APK verifies, and all are signed by one certificate.
  local cert cert1 dn set a c
  cert=$(digest "$b" SHA-256); cert1=$(digest "$b" SHA-1); dn=$(signer "$b")
  if [ -z "$cert" ]; then
    say "THE BASE APK DOES NOT VERIFY (apksigner): $(basename "$b")"
    # Why, in apksigner's words (certificate facts and errors; nothing secret).
    echo "--- the download: $(basename "$(cat "$W/arm64.file")"), $(du -h "$(cat "$W/arm64.file")" | cut -f1)"
    ls -l "$W/arm64/x" | tail -n +2 | awk '{print "    " $5, $9}'
    echo "--- $("${BT}apksigner" --version 2>&1 | head -1) on $(java -version 2>&1 | head -1)"
    "${BT}apksigner" verify --verbose --print-certs "$b" 2>&1 | grep -v -i 'WARNING: META-INF' | head -30 || true
    exit 1
  fi
  for set in $sets; do
    for a in "$W/$set"/x/*.apk; do
      c=$(digest "$a" SHA-256)
      [ "$c" = "$cert" ] || { say "A DIFFERENT OR BROKEN SIGNATURE: $(basename "$a") in the $set download"; exit 1; }
    done
  done

  # Google Play's stamp on the base APK: the file is the one Play delivers.
  local st; st=$(stamp "$b")
  [ "$st" = "$PLAY_STAMP_SHA256" ] \
    || { say "NO VERIFIED GOOGLE PLAY SOURCE STAMP on the base APK (got '${st:-none}'): not kept"; exit 1; }

  # Anchored: the oldest release APKPure lists, and/or a second source.
  local anchored="" old="none older listed"
  if [ -d "$W/anchor" ]; then
    c=$(digest "$(base_of anchor)" SHA-256)
    [ "$c" = "$cert" ] || { say "SIGNER DIFFERS FROM $oldest, the oldest release listed: not MX's build, not kept"; exit 1; }
    anchored=1; old="yes, $oldest"
  fi
  local second="not given"
  if [ -n "${MX_CERT:-}" ]; then
    { [ "$MX_CERT" = "$cert" ] || [ "$MX_CERT" = "$cert1" ]; } \
      || { say "SIGNER DIFFERS FROM MX_CERT (the second source): not kept"; exit 1; }
    anchored=1; second="yes"
  fi
  [ -n "$anchored" ] || { say "NO ANCHOR: no older release listed and no MX_CERT; not kept"; exit 1; }

  local same="no x86_64 build" x86="none on APKPure"
  if [ -f "$W/x86_64.file" ]; then
    x86=$(abis x86_64); same="no"
    cmp -s "$(cat "$W/x86_64.file")" "$(cat "$W/arm64.file")" && same="yes: APKPure has one build for both"
  fi
  cat > "$W/notes.md" <<EOF
MX Player $MX_VERSION ($MX_PACKAGE, versionCode $code), kept for the reference lab of yannmh007/innocent.
Research only: it runs in the lab's throwaway emulator. Never install it on a phone.

- Source: APKPure, through EFF's apkeep 1.1.0 (run ${GITHUB_RUN_ID:-local})
- Signed by: $dn
- Signer SHA-256: $cert
- Google Play source stamp: verified, Google's stamp certificate (the file Play delivers, unchanged)
- Same signer as the oldest release APKPure lists: $old
- Same signer as the second source (MX_CERT): $second
- The x86_64 download, native code for: $x86
- The arm64-v8a download, native code for: $(abis arm64)
- The two downloads are the same file: $same
EOF
  sed -n '4,$p' "$W/notes.md" | sed 's/^- //' | while IFS= read -r l; do say "$l"; done
  echo "$same" > "$W/same"
}

keep() {
  local out="$W/out" f ext
  mkdir -p "$out"
  f=$(cat "$W/arm64.file"); ext="${f##*.}"
  if [ "$(cut -c1-3 "$W/same")" = yes ]; then
    cp "$f" "$out/mx-$MX_VERSION.$ext"
  else
    cp "$f" "$out/mx-$MX_VERSION-arm64-v8a.$ext"
    if [ -f "$W/x86_64.file" ]; then
      f=$(cat "$W/x86_64.file"); cp "$f" "$out/mx-$MX_VERSION-x86_64.${f##*.}"
    fi
  fi
  gh release create "$TAG" --repo "$REF_REPO" --title "MX Player $MX_VERSION" \
    --notes-file "$W/notes.md" "$out"/* >/dev/null
  say "kept: the release $TAG of innocent-ref, $(ls "$out" | tr '\n' ' ')($(du -sh "$out" | cut -f1))"
}

case "${1:-}" in
  reach) reach ;;
  get)   get ;;
  keep)  keep ;;
  *) echo "usage: fetch.sh reach|get|keep" >&2; exit 2 ;;
esac
