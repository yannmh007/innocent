# Seamless quality switching — research and plan (October 2026)

The question: can a rung switch mid-film be as smooth as YouTube's — no
frozen picture, no black — on the player and ladder we already have?

## What the app does today

The ladder (`tool/transcode.sh`) is one CMAF file per rung: `ftyp`, a 1 KB
`moov`, one `sidx` per track, then a `moof`+`mdat` fragment per keyframe,
every 2 s, sound muxed in. The player is libmpv (media_kit,
`libmpv-android-video-build` v1.1.11, which builds **FFmpeg 6.0**). A switch
— a step down after a stall, a climb, a Quality menu choice — reopens the
film on the other rung's file at the same moment.

## What was measured

In a container with mpv 0.37 / FFmpeg 6.1.1, a 6-minute three-rung ladder
encoded with the production flags (469 / 1334 / 2636 kbps), served by a
Range server with a shared rate cap and an added round trip.

1. **HLS over the existing files, no re-encode.** Byte-range media playlists
   built from each rung's `sidx` (`#EXT-X-MAP` = `ftyp`+`moov`,
   `#EXT-X-BYTERANGE` per fragment) and a master playlist play from the
   start in mpv. No new files, no new uploads.
2. **Seeking in fragmented-MP4 HLS produces no frames.** `--start=12`,
   `ffmpeg -ss 12`, `ffprobe -read_intervals 12%`: zero frames, the demuxer
   walking segment after segment. The same with plain segment files, and the
   same with FFmpeg's own `-hls_segment_type fmp4` output, so it is not the
   playlists. MPEG-TS HLS seeks fine. This is FFmpeg trac
   [#7359](https://trac.ffmpeg.org/ticket/7359) — open since 2018; a 2022
   comment calls fMP4 seeking "completely broken" after the TS fix.
3. **A runtime variant switch in libmpv is a seek.** Setting `vid`/`aid` to
   the 720p variant's tracks (the mpv-documented way, mpv issue #15158) makes
   libmpv refresh-seek the demuxer; with (2) the demuxer reports EOF and the
   film ends. So "HLS inside libmpv" cannot switch rungs on this ladder.
4. **Today's reopen**, 240p → 720p at 12 s, 80 ms round trip: the picture
   froze for **1.8 s at 6 Mbit/s** and **3.0 s at 3.5 Mbit/s** (time-pos not
   advancing; three runs each, consistent).
5. **The same reopen onto a copy whose next seconds were already fetched:**
   frozen **0.09–0.15 s** (three runs). What is left is the demuxer opening
   and the decoder starting — on a phone more than on a desktop, but a blink.

## The options

| | what | switch | cost | verdict |
|---|---|---|---|---|
| C-mpv | HLS master in libmpv, switch `vid`/`aid` | blocked by FFmpeg #7359 on fMP4 | TS repackaging = a second copy of every rung, ~10 % larger | no |
| **C2** | **warm switch**: fetch the new rung's next 10 s from the moment it will open at, while the old plays, then reopen | 1.8–3 s → ~0.1–0.4 s | none on the server; ≤ 8 MB of the viewer's data per switch, all of it played | **done, 1.64.68** |
| C1 | Media3 / ExoPlayer for catalogue streams | none: the next segment comes from another rung | a second player engine: subtitles, gestures, PiP, audio tracks, stall diagnosis, Cut are all libmpv-bound today | later, behind a flag, if real-device numbers ask for it |

C1 notes for when it is taken up: ExoPlayer's HLS plays muxed fMP4 by byte
range, so the playlists from (1) work unchanged; DASH would need picture and
sound in separate files (a `-c copy` repackage). Media3's Cronet / HttpEngine
data source also brings HTTP/2 and HTTP/3 (QUIC), which helps lossy mobile
lines on its own.

## What 1.64.68 does (C2)

* `CmafIndex` (`lib/features/video_hub/domain/cmaf_index.dart`) turns a
  rung's `sidx` into a fragment table — offset, size, start time — and a
  moment into the byte range of "the fragment holding it and ten seconds
  on". Pure; checked byte for byte against a real ffmpeg rung (180 fragments).
* `StreamCacheServer.warmSwitch` fetches that range through the proxy's own
  address — the lanes, the store and the cache entry the reopen will read.
* The renewer (`playback.dart`) warms before answering a **climb** or a
  **menu choice**, and keeps the copy on screen registered meanwhile. A
  **step down** is made because the film has stopped, so it reopens at once
  as before.
* **A climb must earn it**: the better copy's bytes must arrive 1.25 times
  faster than they play, inside 12 s, or the climb is called off — the film
  stays where it is instead of reopening into a stall. After one called-off
  climb the next waits three minutes; after two, none in that film
  (`ClimbRule.abandonAllows`).
* A menu choice says so ("Switching quality — the film keeps playing
  meanwhile") and opens whatever has arrived after at most 8 s.
* `test_bench/stream_bench.dart` has a `switch cold` / `switch warm` row on
  the netem lines in CI.

## Next

1. Real phones: the playback log now carries `warm switch: … MB for … s of
   film in … ms` and `climb to …p called off`; read them from devices on
   1.64.68.
2. If switches or stalls still show up as a problem on real devices, start
   C1 as a prototype for catalogue streams only.
