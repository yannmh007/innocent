# Handoff, 28 Nov 2026: beyond MX — session 2 (P0, P1 on phones, P4, P5)

Follows docs/handoff_2026_11_28_beyond_mx_p1.md (its §1-§4 still hold) and
the plan docs/handoff_2026_11_27_beyond_mx.md. Work branch
`claude/extract-github-release-oteqr5` (fast-forward pushes); live is still
1.64.90+403 — nothing of this session is in an APK on a phone yet. Read
first: CLAUDE.md, this file, BACKLOG §0 (the newest entry), skills
`device-labs`, `ui-design`, `release`, `.claude/rules/reference-lab.md`.

## 0. The owner's answers this session (28 Nov)

1. ♪'s look (MX | Innocent sheet): **approved**.
2. OpenSubtitles: account made, `OPENSUBTITLES_API_KEY`, `_USERNAME`,
   `_PASSWORD` set as Supabase Edge Function secrets.
3. P1 (the film on Android's SurfaceView): **PENDING** — see §3.

## 1. What was found (with the proof)

| # | Finding | Proof |
|---|---|---|
| 1 | libmpv draws no picture on the API 34 emulator: "Could not create EGL context for GLES 2.x", "Video: no video" — sound plays, the decoder runs (h264 640x360, mediacodec-copy). Not the local copy: the lab's own ffmpeg film too | device lab P1-E4 46044124212 (a lab build now writes libmpv's log: `mpv info [cplayer] …`); no API 34 trace ever read `vo=gpu` (git log -S), Test Lab's phones did (40094466469) |
| 2 | P1-E1's "libmpv local at 20 fps" was the loading spinner of a 32 s open | P1-E1 trail: first frame 32254 ms after the frames counted |
| 3 | API 30's emulator cannot run the smooth flow: the app does not read `lab_stream_url` from Android/data there | P1-E5 46048122459 |
| 4 | MX 3.4.3's subtitle gestures: a swipe along the line steps ONE line on the finger's lift, right to left the next, left to right the previous, from 50-70 dp; the band is the line's own box across the whole width; a drag moves the line after ~60 px and MX keeps the place; the line greyed while held; "↕ N" while dragging. Innocent stepped a line per 64 dp the other way round | reference lab SCREENS=subgest 46047544023, 46049383870, 46050792610; rule reference-lab.md |
| 5 | MX's subtitle pinch cannot be measured by sendevent: MX takes the two fingers as a tap | 46054727876 (sendevent needs pressure + BTN_TOOL_FINGER, display 0's panel, mapping 1) |
| 6 | P0 on the branch's code = the live one: realme and OPPO 16 PASS 1 SKIP; the slow jump (want≈281, ~7 s) is as on 1.64.88/89 (7203, 8287 ms) | Test Lab 46124465325 |

## 2. What is on the branch (not live) / what is live

- **LIVE (server)**: migration 084 `subtitle_budget` (+ take_subtitle_budget,
  give_back_subtitle_download; install 40 searches/h, 5 downloads/day;
  network 200/h, 10/day); edge function `subtitles-online` v1 = shim at
  485ae02c, verify_jwt false. Proved by Subtitles check 46117747259
  (.github/workflows/subtitles-check.yml): search 200, 40 rows, no link;
  download 200, 76 KB SubRip, 1089 cues, the account's remaining 19.
  Each check run spends one of the day's 20 downloads.
- **Branch (ships with the next release)**: CC → Online sheet
  (online_subtitles_sheet.dart, data/online_subtitles.dart: hash, cleaned
  name, refusals; test/online_subtitles_test.dart); the privacy text (3
  languages); subtitle gestures as MX (28aa9ece: engine, held grey box,
  help text; player_gesture_engine_test 25, subtitle_held_test); ♪'s items
  (P4, session 1) with the lab's `fn:audio` (f377b5c9, AudioShape counters
  in ExoStreamEngine.stats); the lab's `decoder` menu (bded2174).
- Branch Build 46118303872 (f377b5c9): checks, both JVM suites, Analyze,
  the whole suite, the APK — green.

## 3. P1 on the phones (Test Lab fifty-seventh, 46124628533)

Sintel on ExoPlayer, 20 s a look, app CPU (% of one core, CpuProbe),
Flutter's frames (fps), raster p50 (ms); `LAB main` = the main thread's
messages over the profiled 12 s.

| look | realme app % | realme fps | OPPO app % | OPPO fps |
|---|---|---|---|---|
| film on the texture (`now` ×2, `…prof`) | 51 / 61 / 61 | 23-25 | 52 / 49 / 53 | 24-25 |
| texture, ExoPlayer's dynamic scheduling (`sched`) | 63 | 25 | 54 | 24 |
| texture, the window see-through (`t`, `tprof`) | 71 / 61 | 23-25 | 65 / 51 | 23-24 |
| **film on a SurfaceView** (`sv` ×2, `svprof`, `svsched`) | **43 / 37 / 38 / 40** | **0** | **48 / 35 / 59 / 40** | **0** |
| controls up, texture | 79 | 24.9 (r50 6.9) | 76 | 25.7 (r50 6.0) |
| controls up, SurfaceView | 62 | 4.9 (r50 9.4, late 6.8 %) | 45 | 4.5 (r50 8.8, late 9.3 %) |
| decoder dialog (glass), texture | 89 | 25.0 | 69 | 25.0 |
| decoder dialog, SurfaceView | 38 | 0.3 | 37 | 0.3 |

- Medians, the film alone: realme 61 → 39 % (−22 points, −36 %), OPPO
  52 → 40-44 % (−10 to −12 points, −20 %). Flutter draws nothing while the
  film plays on the SurfaceView; the raster thread (10-17 %) is gone.
- `LAB main`: texture 341/343 messages in 12 s (ImageReader 288-289 of
  them, main 6 %), SurfaceView 49 (realme, main 2 %) / 126 (OPPO, main
  15 %, one sample with Dart messages).
- The emulator's worry did NOT hold on the phones: the controls over the
  SurfaceView draw only when they change (4.5-4.9 fps, the clock and the
  bar), raster p50 9 ms.
- A dialog over the texture costs a lot (89 / 69 %: its glass blurs a
  changing film 25 times a second); over the SurfaceView it is still
  (0.3 fps, 37-38 %) — but its glass has nothing to blur: the tint alone
  (pictures: p1_dialog_glass.png, simulated by composing the dialog drawn
  over nothing on the frame, as the display does).
- `sched` and `t` change nothing measurable: dynamic scheduling stays off.
- P4 `fn:audio` on both phones: Mono, Swap and Night shaped ~144 000
  frames in 3 s (48 kHz: all of it); Night's gain +1.4 / +0.3 dB (a quiet
  part lifted); the delay moved the clock (+300 ms: position +3311 ms in
  3 s; −300: +2410); Disable turned the track off; Boost 200 % = the
  LoudnessEnhancer at 602 mB (+6 dB); every item back off.
- P0 the same morning (46124465325): 16 PASS 1 SKIP on both phones.

## 4. Open

- The owner's decision on P1 (§3) — the production list if `sv` wins is in
  the previous handoff §3.4.
- libmpv's A/B (`local`, `mpvsv`) needs the phones: one Test Lab run.
- Online subtitles for catalogue films (ExoPlayer): the sheet says it is
  for the phone's own videos; a sidecar SRT on ExoPlayer (or the app's own
  SRT layer) would be needed.
- The reference lab's stuck run 46051981906 (bare `wait`): fixed in 5.

## 5. The owner's steps

(filled in at the end)

## 6. The prompt for the next session

(filled in at the end)
