# Streaming without stops: the ladder on ExoPlayer

Status: built in 1.64.72, on Android, for every catalogue film with two or
more rungs. Everything else is unchanged and still plays on libmpv.

## What was wrong

Measured on real phones (Test Lab run 39972176423, Sintel, 1.64.71):

| | OPPO | realme |
|---|---|---|
| Play tap to grant | 3.4 s | 6.2 s |
| Quality change, picture frozen | 4.2 s | 4–7 s |
| Seek inside the film | 1.0–1.8 s | — |

A quality change reopened the film on another rung, because libmpv cannot
switch rungs inside one stream on this ladder. FFmpeg's HLS demuxer produces
no frames after a seek in fragmented-MP4 playlists (ticket #7359), so the
picture stopped while the new copy opened. Auto had the same limit. It
stepped down only after the film had already stalled, then stopped again to
reopen.

## What YouTube does, and what this does

YouTube's Android app plays through ExoPlayer (Media3). The rung changes at
a segment boundary while the picture keeps moving. Auto weighs the measured
bandwidth against what is buffered, and drops a rung before the buffer runs
dry. A seek is answered from the segment that holds the frame.

The ladder already allowed all of this (`tool/transcode.sh`):

- every rung is one CMAF file: `ftyp`, a 1 KB `moov`, a `sidx`, then a
  `moof`+`mdat` every two seconds;
- every rung has a keyframe every two seconds on the same clock (`-g` fixed,
  `-sc_threshold 0`), so fragment N of every rung covers the same two seconds.

So no re-encode and no new files are needed. The phone writes the playlists
itself:

```
ExoPlayer ──HLS──▶ local proxy (127.0.0.1) ──bytes──▶ Worker ──▶ R2
           master.m3u8, <h>.m3u8            one request per 2 MB
           segments = byte ranges of        bind header, renewal,
           each rung's one file             sealed cache, measurement
```

- `lib/features/video_hub/domain/hls_ladder.dart` writes the playlists:
  - the master names every rung with the real codec, size and peak rate,
    once the rung's head has been read;
  - each media playlist lists the rung's init segment and every fragment, by
    byte range of its one file.
- `StreamCacheServer.hlsUrlFor` serves the playlists. It reads a segment and
  the next 2 MB in one request, so the Worker sees about 7 requests for
  14 MB, not 90. A jump cancels the read ahead. A head read (byte 0) reads
  no further. The heads of the rungs either side are read once the first
  playlist is served, so a change of rung waits for no index.
- `ExoStreamEngine.kt` plays it:
  - ExoPlayer's own adaptive choice, steered (`SteeredSelection`): a rung the
    viewer picked wins, and Auto stays under the data saver's 480p;
  - Auto's first rung is the one the app chose and warmed while the viewer
    looked at the film;
  - buffered film in a rung no longer wanted is dropped past the next two
    seconds, so a change shows in about two seconds rather than after a full
    buffer.
- Rungs are told apart by height. Every rung in the master has a RESOLUTION
  (the start rung's head is read before the master is written, else 16:9),
  and the engine also knows each height by its AVERAGE-BANDWIDTH. Without
  that, every height was unknown and a pick of 240p played the best rung
  (device-lab run 40079651806).
- Bandwidth comes from the proxy's own reads of the Worker
  (`StreamCacheServer.networkKbps`), not from loopback reads, which arrive at
  flash speed when cached. The engine keeps a quick and a slow average of
  them and uses the lower: a drop counts at once, a recovery only once it
  holds. The last reading alone kept 720p through a dip to 2.7 Mbit/s right
  after a seek, and the film stopped for 5.5 s.
- Buffer: start on 1 s of film, 2 s after a stall, up to 60 s ahead, and 30 s
  kept behind so a step back plays from memory. A finger on the seek bar
  turns on ExoPlayer's scrubbing mode.
- The player screen, gestures, PiP, the account code and the resume point
  see one `MediaKitPlayerService`. Its streams follow whichever engine is
  drawing.

## What stays on libmpv

Local files, the vault, music, network shares, downloads, an Original, and
any film with one rung. Also any phone the server sends back (see below).

## The ways back

1. **Automatic.** If ExoPlayer fails before its first picture, the start rung
   plays on libmpv at the same moment, as in 1.64.71. It stays on libmpv for
   the rest of that film.
2. **Remote.** Add `mpv_ladder` to `app_releases.player_flags`. The daily
   update check stores it, and every film then plays on libmpv, one rung at a
   time, with no new APK:

   ```sql
   update app_releases set player_flags = trim(player_flags || ' mpv_ladder') where id = 1;
   ```

## Costs

- Worker requests per film:
  - one length check per rung that is used;
  - one head read for each rung either side;
  - one request per 2 MB of film watched.
  The single-file path also reads in parts of at most 2 MB, so the total is
  close to before.
- The same bytes are cached on the phone under the same cache ids. A film
  watched on libmpv and then on ExoPlayer reuses what is already there.

## How it is checked

- `test/hls_ladder_test.dart` covers the playlists, against the head of a
  real ffmpeg rung (`test/fixtures/cmaf_head_720p.b64`).
- `test/stream_cache_hls_test.dart` checks that:
  - every segment comes back byte for byte;
  - the Worker gets few requests;
  - a jump is answered at once;
  - a replay comes from the phone;
  - the neighbouring rungs' heads are read in advance;
  - a released ladder returns 404.
- The device lab and Test Lab play Sintel only. They measure the time to the
  first picture, the frozen time during a quality change (target 0 s), and
  seek times. A release goes out only after real phones pass.

| Run | Where | Jumps | Frozen on a quality change | Rung picked shown |
|---|---|---|---|---|
| 39972176423 (1.64.71, libmpv) | OPPO | 5/5 | 4.2 s | after the reopen |
| 40076455852 | emulator | 5/5 | 0.2 s | never (no RESOLUTION) |
| 40079651806 | emulator | 4/5 | 0.17 s | stall on Auto (one reading) |
| 40092901280 | emulator | 5/5 | 0.24 s | 1.9 s |

## Since 1.64.73

- Far jumps (more than ten seconds) land on the nearest keyframe, at most
  a second off: one segment from its first byte, no decoding up to the
  frame. Near jumps (a double tap) stay exact.
- A ladder's rungs share one pool of connections, kept a minute.
- Seek-bar pictures: the smallest rung's init segment and the fragment for
  that moment, decoded on the phone from memory (`PreviewFrames.kt`), about
  75 KB the first time and nothing after; on the seek bar and above the
  time during a swipe. Not written to disk, not written into the cache.
- The volume boost above 100 % works on ExoPlayer (LoudnessEnhancer).
- Ten retries for a segment instead of three: a half-minute drop-out is
  waited for while the buffer plays.

## After 1.64.73

- Seek-bar pictures one at a time, the newest next
  (`ladder_preview_loader.dart`). On both real phones (Test Lab run
  40118247783) a swipe asked for seven, each queued behind the last, and the
  final one came 1.3–1.5 s late. Now the moments in between are skipped:
  the picture trails the finger by one fetch at most, and costs fewer
  Worker requests.
- The landing picture. A far jump draws the picture already taken for that
  moment over the old frame until its own frame is drawn
  (`ExoEngine.landing`), as YouTube holds its storyboard frame. It sits in
  the texture's own box, so it takes the film's fit, zoom and crop. It
  shows only if the frame takes longer than 120 ms, and never for longer
  than 4 s. Nothing is fetched for it.
- The grant runs beside the database. Edge logs, 24 October 2026:
  `request-playback` took 0.3–0.7 s when it ran in Singapore
  (ap-southeast-1, where the database is), and 2.2–3.5 s when it ran in
  Virginia, Oregon or Seoul. One call from Singapore itself was sent to
  Seoul. Its eight queries each crossed the distance. The app now asks
  for the region (`x-region`, `BackendConfig.functionRegion`). A call
  pinned to a region is not moved when that region is down, so a
  gateway's 5xx is asked once more, unpinned.

## After 1.64.74

- The owner's phone said "Could not switch quality" on Tears of Steel. In
  the device lab every line of its menu was taken (run 40184478393: 480,
  360, 240, Original, Auto, 15 of 15), so the refusal came from a state
  the tour did not reach. Two of the refusals are gone:
  - a reconnect or a climb under way is waited for, up to 8 s, and the
    choice then applied;
  - on the ladder, a rung or Auto is steered directly when the renewer
    cannot answer. ExoPlayer has every rung, and nothing needs renewing.
  The lab now tries every line of the menu on every run (LAB check
  tour->…).
- A phone line, not Starlink (run 40186513057). Sintel played on a link
  held to 4 Mbit/s down and 2 up, 80-200 ms, 0.5 % loss. All 17 checks
  passed:

  | Check | Picture still |
  |---|---|
  | Change of quality | 0.2-0.3 s |
  | Skip +30 | 0.7 s |
  | Seek | 1.1 s |
  | Swipe | 1.4 s |
  | Original | 2.8 s (a reopen on libmpv) |

  The landing picture was held 0.5 s. With nothing measured, the start
  is 720p on Wi-Fi and 480p on mobile data (`kMeteredStartHeight`). The
  emulator counts as Wi-Fi, and its 720p start stalled once, for 1.9 s,
  before Auto stepped down.
- The player's messages are a dark pill near the top, never over the seek
  bar (`player_toast.dart`). The quality button shows what Auto chose
  ("Auto · 480p"). There is no decoder button on a film ExoPlayer plays:
  the choice only ever reached libmpv.

## Next
- Play tap to grant, beside the database: about 0.3–0.7 s. Most of what is
  left is the phone's own round trip and the function's start. A single
  RPC for the eight queries would save tens of milliseconds, not seconds;
  not worth touching the security boundary for.
