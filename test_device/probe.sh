#!/usr/bin/env bash
# What the stream door itself gives, measured from the runner, with no app in
# the way: the headers a download decides on, and how fast one connection is
# against three. Prints shapes and numbers only — never the signed URL.
set -uo pipefail
OUT=${OUT:-out}; mkdir -p "$OUT"
SB_KEY=sb_publishable_vTiAxBAhnZL_BqFcZD4m9A_Rb8Q8PHj   # ships in every APK
TITLE=${PROBE_TITLE:-Chester Koong}
{
  echo "probe: $TITLE"
  q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$TITLE")
  id=$(curl -sS "$SB_URL/rest/v1/titles?select=id&title=eq.$q&limit=1" -H "apikey: $SB_KEY" \
       | python3 -c "import json,sys;r=json.load(sys.stdin);print(r[0]['id'] if r else '')")
  [ -z "$id" ] && { echo "no such title"; exit 0; }
  curl -sS -o /tmp/grant.json -X POST "$SB_URL/functions/v1/request-playback" \
    -H "apikey: $SB_KEY" -H 'Content-Type: application/json' -d "{\"title_id\":\"$id\"}"
  url=$(python3 -c "import json;print(json.load(open('/tmp/grant.json')).get('url') or '')")
  python3 -c "import json;d=json.load(open('/tmp/grant.json'));print('via:',d.get('via'),'| rungs:',len(d.get('renditions') or []))"
  [ -z "$url" ] && { echo "no url"; exit 0; }
  host=$(python3 -c "import sys,urllib.parse;print(urllib.parse.urlparse(sys.argv[1]).hostname.split('.')[-2:])" "$url")
  echo "door host (last two labels): $host"

  echo "--- whole-object GET, headers only"
  curl -sS -D - -o /dev/null --max-time 5 "$url" 2>/dev/null \
    | grep -iE "^HTTP|content-length|accept-ranges|content-encoding|transfer-encoding|cf-cache|content-type" || true
  echo "--- ranged GET 0-1023, headers"
  curl -sS -D - -o /dev/null -H 'Range: bytes=0-1023' "$url" \
    | grep -iE "^HTTP|content-length|content-range" || true

  echo "--- one connection, 20 s"
  curl -sS -o /dev/null --max-time 20 -w 'bytes=%{size_download} speed=%{speed_download} B/s ttfb=%{time_starttransfer}s\n' "$url" || true

  echo "--- three connections on three ranges, 20 s"
  len=$(curl -sS -I "$url" | awk -F': ' 'tolower($1)=="content-length"{print $2+0}' | tail -1)
  third=$(( ${len:-300000000} / 3 ))
  for i in 0 1 2; do
    s=$((i*third)); e=$((s+third-1))
    curl -sS -o /dev/null --max-time 20 -H "Range: bytes=$s-$e" \
      -w "lane$i bytes=%{size_download} speed=%{speed_download} B/s\n" "$url" &
  done
  wait
} 2>&1 | sed -E 's#https?://[^ "]+#<url>#g' | tee "$OUT/probe.txt"
