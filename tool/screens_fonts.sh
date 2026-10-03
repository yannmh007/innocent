#!/usr/bin/env bash
# Prepares the fonts test_screens/ draws with, into $1 (default
# build/screen_fonts), and prints the SCREEN_FONTS line to export.
#
#   Roboto + Material Icons — from the Flutter SDK's own cache, the fonts
#   Android draws Latin text and icons with.
#   Noto Sans Myanmar       — the font Android falls back to for Burmese,
#   from the @fontsource npm package (woff2), converted to TTF.
#
# Needs: flutter on PATH (any `flutter` command has filled its cache), npm,
# python3 with fonttools + brotli (pip install fonttools brotli).
set -euo pipefail
out="${1:-build/screen_fonts}"
mkdir -p "$out"
sdk="$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")"
mf="$sdk/bin/cache/artifacts/material_fonts"
for f in Roboto-Regular Roboto-Medium Roboto-Bold Roboto-Light Roboto-Black; do
  cp "$mf/$f.ttf" "$out/"
done
cp "$mf/MaterialIcons-Regular.otf" "$out/"
tmp="$(mktemp -d)"
( cd "$tmp" && npm pack @fontsource/noto-sans-myanmar --silent >/dev/null && tar xzf ./*.tgz )
python3 - "$tmp/package/files" "$out" <<'PY'
import sys
from fontTools.ttLib import TTFont
src, out = sys.argv[1], sys.argv[2]
for w in ('400', '700'):
    f = TTFont(f'{src}/noto-sans-myanmar-myanmar-{w}-normal.woff2')
    f.flavor = None
    f.save(f'{out}/NotoSansMyanmar-{w}.ttf')
PY
rm -rf "$tmp"
echo "export SCREEN_FONTS=$(readlink -f "$out")"
