#!/usr/bin/env bash
# The app's ADB reading code against libadb-android's own source, over a real
# socket, with a fake adbd. Needs a JDK (javac, keytool) and git. See README.md.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="${ADBLAB_DIR:-$(mktemp -d)}"
version="${LIBADB_VERSION:-3.1.1}" # the app's: android/app/build.gradle.kts
runs="${1:-150}"

if [ ! -d "$work/libadb" ]; then
  git -c advice.detachedHead=false clone -q --depth 1 --branch "$version" \
    https://github.com/MuntashirAkon/libadb-android.git "$work/libadb"
fi
src="$work/src"; rm -rf "$src" "$work/out"; mkdir -p "$src/io/github/muntashirakon/adb" "$src/com/innocent/media"
lib="$work/libadb/libadb/src/main/java/io/github/muntashirakon/adb"
# Everything the connection, stream and manager use; pairing and mDNS are
# stubbed (not under test), as are the few android.* calls.
for f in AbsAdbConnectionManager AdbConnection AdbStream AdbInputStream \
  AdbOutputStream AdbProtocol AndroidPubkey KeyPair LocalServices StringCompat \
  SslUtils PRNGFixes AdbAuthenticationFailedException AdbPairingRequiredException \
  ByteArrayNoThrowOutputStream; do
  cp "$lib/$f.java" "$src/io/github/muntashirakon/adb/"
done
cp -r "$here/stubs/." "$src/"
cp -r "$here/src/." "$src/"
cp "$root/android/app/src/main/java/com/innocent/media/AdbRead.java" "$src/com/innocent/media/"

javac -nowarn -d "$work/out" $(find "$src" -name '*.java') 2>&1 | grep -v '^Note:' || true
[ -f "$work/lab.p12" ] || keytool -genkeypair -alias lab -keyalg RSA -keysize 2048 \
  -keystore "$work/lab.p12" -storetype PKCS12 -storepass labpass -keypass labpass \
  -dname CN=lab -validity 3650 >/dev/null 2>&1
java -cp "$work/out" lab.WireLab "$work/lab.p12" "$runs" 2>/dev/null
