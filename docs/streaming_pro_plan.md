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

## Next

- Seek preview: a thumbnail strip per film (one sprite per 10 s, made in
  transcode), shown above the seek bar while dragging.
- Play tap to grant: `request-playback` makes about 8 database round trips in
  sequence. One RPC would cut most of the 3.4–6.2 s.
