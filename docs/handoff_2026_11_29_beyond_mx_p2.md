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
3. P1 (the film on Android's SurfaceView): **the SurfaceView, the dialogs'
   glass a tint alone (as MX)** — after §3's table and the glass pictures
   (p1_dialog_glass.png: blurred on the texture | tint over the
   SurfaceView). Effects that need the picture in Flutter (Display's colour
   filters, mirror/flip) fall back to the texture while on.

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

libmpv on the realme (fifty-eighth, 46129966885; `local` = a minute of
Sintel's 720p copied to a file): libmpv plays on the phone (vo=gpu,
hwdec mediacodec, 1690x720 at 24 fps, 0 dropped) — the emulator's EGL
fault is the emulator's. Texture 46-52 % app (Flutter 24.7 fps, a "Thread"
— libmpv's render thread — 16-18 %); `mpvsv` (libmpv's GL output moved to
a SurfaceView, wid 1690x720) 41 % / 41 %, Flutter 0.1 fps, the main thread
0 messages — a smaller gain than ExoPlayer's (libmpv still renders by GL,
its thread 19 %). The controls over `mpvsv` drew 25 fps (82 %), unlike
ExoPlayer's 4.9: something still asks Flutter for a frame per video frame
(media_kit's texture?) — to read in the production work. mpv logged
`aimagereader acquireLatestImage failed: -30001` around the switch. For
libmpv the bigger gain would be `vo=mediacodec_embed` (the decoder
straight to the SurfaceView, no GL; Innocent draws its subtitles itself) —
not measured.

## 4. Open — the next session: P1 in production (the owner's choice)

The film on Android's SurfaceView by default, ExoPlayer first (catalogue
films; the measured win), the dialogs' glass a tint. The work (previous
handoff §3.4, plus what this session learned):
1. The window: the lab switches it see-through by recreating the
   Activity (a visible blink). Production: the player's window
   see-through from its start (FlutterActivity's transparent background
   mode) or a SurfaceView placed under Flutter without a recreate —
   measure the cost of a see-through window on the phones' home and
   library screens first (`t` looked free while a film played).
2. The film's SurfaceView placed and sized by the player: fit / zoom /
   pan / crop / 100 % from Flutter's numbers (video_geometry.dart), the
   cutout and rotation; the subtitles stay Flutter's.
3. Screenshot by PixelCopy of the SurfaceView; the in-app PiP window on
   the texture (or its own view); system PiP.
4. Display's colour filters, mirror/flip: back on the texture while on
   (the owner's word); Night mode (picture) as a black layer.
5. The dialogs (PlayerDialog/PlayerGlass): over the SurfaceView the tint
   only — raise the tint where the film reads through (check legibility
   with test/player_legibility_test.dart's frames).
6. ExoPlayer then votes its own frame rate on its surface (P2's
   DisplayVote is on Flutter's SurfaceView today).
7. libmpv: `mpvsv` worked on the phone but saved less (41 % against
   46-52 %); try `vo=mediacodec_embed` on the SurfaceView, and find why
   the controls over it draw 25 fps.
Each step: device lab first (ExoPlayer draws on the emulator; libmpv does
not), then Test Lab (count the day's five), then the release when the
owner says "release".

Also open:
- Online subtitles for catalogue films (ExoPlayer): the sheet says it is
  for the phone's own videos; a sidecar SRT on ExoPlayer (or the app's own
  SRT layer) would be needed.
- The reference lab's stuck run 46051981906 (bare `wait`): fixed in 5.

## 5. The owner's steps

1. Nothing is waiting on you now. With the next release (say "release"):
   on the phone, try ♪ (Volume boost, Night sound, Stereo mode, Disable,
   Audio delay) on a catalogue film and on a video of your own; CC →
   Online on a video of your own (search, tap a row, it loads); a swipe
   left on a subtitle line for the next line, right for the previous,
   drag it up and down; Report a problem with a film playing.
2. The OpenSubtitles account gives 20 downloads a day to all viewers
   together (each phone 5, each network 10 — migration 084).

## 6. The prompt for the next session

```
Innocent player — "MX ထက် ပိုကောင်းအောင်" session 3: P1 production
(film ကို SurfaceView ပေါ်၊ dialog glass = tint — 28 Nov ဆုံးဖြတ်ချက်)။
docs/handoff_2026_11_29_beyond_mx_p2.md ကို အရင်ဖတ်ပါ (CLAUDE.md, BACKLOG §0
newest entry, skill device-labs, ui-design, release)။ Work branch:
claude/extract-github-release-oteqr5 (fast-forward push)။
1. handoff §4 အတိုင်း ExoPlayer ကို SurfaceView ပေါ် production လုပ်ပါ
   (window, geometry, screenshot, PiP, effect fallback, dialog tint,
   frame-rate vote)။ device lab အရင်၊ ပြီးမှ Test Lab (cloud.env comment
   နဲ့ ဒီနေ့ test အရေအတွက် ရေတွက်ပါ)။
2. libmpv: mediacodec_embed ကို SurfaceView ပေါ် စမ်းပြီး တိုင်းပါ။
3. ပုံ (before/after) တွေ ပြပြီး ကျွန်တော့် ဆုံးဖြတ်ချက် ယူပါ။
4. Release ကို "release" လို့ ပြောမှ။ အဆုံးမှာ မြန်မာလို report, ဇယား,
   ဖုန်းမှာ စမ်းရမယ့် အဆင့်, handoff နဲ့ prompt။
```
