# What a seek costs, and what a minute of film costs — research (October 2026)

The question: the playback check measured a one-frame seek into Sintel's
720p copy at **7.8 MB for ffmpeg and 72.9 MB for mpv**. Does the app's player
really read tens of megabytes per jump, and how close is the stream path to
what YouTube, Netflix and ExoPlayer do?

## How it was measured

`test_bench/mpv_seek_bench.dart`: the real mpv (0.37, FFmpeg 6.1 — the app's
libmpv is FFmpeg 6.0) with **the app's own stream options**
(`MediaKitPlayerService.streamProfile`, the map `setStreamBufferProfile`
writes), reading through **the real `StreamCacheServer`**, from a "Worker"
that serves a film made with the ladder's own ffmpeg flags over one shared
line (a rate cap for every connection together, a round trip per response,
a small send buffer so a byte counted is a byte that crossed). For each
jump — a seek to 40 %, a +30 s skip, a 2-minute jump back, a seek to 75 % —
it records the time until mpv's picture moved again (`playback-restart`), the
requests mpv made to the proxy, and the requests and megabytes the proxy
took from the line; and twenty seconds of plain playback in between. In CI
(`stream-bench.yml`) the same bench runs under `tc netem` on the Myanmar
profiles (150–250 ms round trip, 0.5–2 % loss).

## Findings

1. **72.9 MB was the relay, not the player.** The check's relay read the
   Worker at full speed and counted what it pushed into a loopback socket;
   each of mpv's short requests left megabytes in kernel buffers. Measured
   with a paced server and a 64 KB send buffer, a seek costs mpv **0.6–1.3 MB
   until the picture** at 1.7 Mbit/s — about one 2-second fragment and its
   sound.

2. **The real cost was requests.** libavformat's MP4 demuxer reads a
   fragment's picture until it is a second ahead of its sound, reaches
   forward for the sound, then steps back a few hundred kilobytes
   (`mov_find_next_sample`: within one second, file order; beyond it,
   timestamp order). With a 1 MiB stream buffer mpv meets every step with a
   new request, and the proxy stopped its six lanes and started again from
   64 KB parts: **7.7 requests through the Worker per megabyte** of a
   1.7 Mbit film played straight through (a 2-hour 720p viewing: ~11,000
   Worker requests). After a seek, parts grew a quarter a round and needed
   ~93 requests and ~54 MB to reach 2 MB: **3.4 requests/MB** even for a
   6 Mbit film whose player made two requests in twenty seconds.
   DASH/HLS players fetch one 2–6 s segment per request (≈1 request/MB at
   these bitrates); YouTube's ranges are similar.

3. **What was tried on the file, and rejected.**
   * `-frag_interleave 8` (picture and sound interleaved inside each
     fragment): reads become strictly forward and a seek's picture comes in
     0.07–0.3 s — but FFmpeg's demuxer then **lands backward seeks in the
     wrong place** (−120 s from 284 s landed at 26 s; −10 s from 452 s at
     306 s) and a following seek waited 41 s. Not shippable.
   * 1-second fragments (`-frag_duration 1000000`, keyframes still every
     2 s): half the fragments start without a keyframe, and a seek whose
     keyframe is in a fragment not yet read waited **6–11 s**.
   * The ladder's layout (one keyframe-led fragment per 2 s) is the one
     FFmpeg seeks correctly; it stays.

4. **What was tried in mpv, and rejected.** A 2–4 MiB `stream-buffer-size`
   absorbs the steps (0.5 requests/MB) — but mpv also *reads through* any
   forward seek shorter than the buffer instead of asking for the target, so
   a +30 s skip went from 2.0 s to 3.4–3.6 s. A larger
   `demuxer-lavf-buffersize` made the demuxer seek hundreds of times.

5. **What was done, in the proxy** (`StreamCacheServer`):
   * **A step back is not a seek** (`handOver`): a request that starts inside
     the run the stretch on the line has delivered — or in a run held on the
     phone that reaches into it — is handed the stretch: its parts in
     flight, and the size its parts had grown to.
   * **After a seek, small parts only until the picture**
     (`seekSettledBytes`, 2 MB): then parts grow one at a time to 2 MB, as a
     stretch from the start does.
   * The `Future.then` handler that returned a bool where void was due (an
     uncaught error each time a kept part was let go) is fixed.

## Results (bench, 8 Mbit/s line, 80 ms round trip, six lanes)

| | before | after |
|---|---|---|
| 1.7 Mbit film, twenty seconds of play | 7.65 requests/MB | **0.89** |
| 5.9 Mbit film, twenty seconds of play (12 Mbit/s line) | 3.37 requests/MB | **0.45** |
| seek 40 % / skip +30 / back −120 / seek 75 %, picture | 1.1–2.2 s | 1.1–2.2 s (unchanged) |

Under netem: see the `mpv seek` tables in the stream bench's run summary.

## Next

* A player-side read order that never steps back needs either a demuxer
  that reads fMP4 in file order (ExoPlayer's does) or separate picture and
  sound files (DASH) — the C1 option in `streaming_abr_research.md`.
