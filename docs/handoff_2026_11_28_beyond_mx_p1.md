# Handoff, 27 Nov 2026 (night): beyond MX — P1 built and half-measured, P2-P4 built

Follows docs/handoff_2026_11_27_beyond_mx.md (the plan, §1-§4 still hold).
Work branch `claude/extract-github-release-oteqr5`; nothing of this is on
main (live is 1.64.90+403). Read first: CLAUDE.md, this file, BACKLOG §0
(the newest entry), `.claude/rules/flutter-app.md`, skills `device-labs`,
`ui-design`, `release`.

## 0. The owner's answers (27 Nov, the five questions of the plan's §5)

1. P1, the film on Android's own SurfaceView: **A/B measured first, then
   decide** (pictures of the dialogs' glass, which loses its blur there).
2. P2, frame-rate matching: **seamless only** (no black moment).
3. P3, 120 Hz: **only while touching** (battery).
4. P4, MX's ♪ items: **all four** — Volume boost, Night sound, Stereo mode,
   Disable.
5. P5: **in-app online subtitles wanted** (the owner sets the OpenSubtitles
   key); **MX's subtitle gestures wanted** (measure MX's first).

## 1. What was found (with the proof)

| # | Finding | Proof |
|---|---|---|
| 1 | Every video frame makes Flutter draw the whole scene again | engine 3.32.8: shell.cc `OnPlatformViewMarkTextureFrameAvailable` → `ScheduleFrame(false)` → animator → `Rasterizer::DrawLastLayerTrees` (rasterizer.cc:218); no partial repaint on Vulkan (only Metal sets `supports_partial_repaint`); per frame `ImageExternalTextureVKImpeller::ProcessFrame` takes the image through JNI (acquireLatestImage, getHardwareBuffer, close) |
| 2 | The main thread pays per frame too | the main-Looper profiler (PlayerLab): texture 330 messages in 8 s (ImageReader callback 185, SurfaceProducer lambda 112, the 4 Hz ticker 32); SurfaceView 45 |
| 3 | MX draws its film on a SurfaceView of the film's size, composed by the display; it votes no frame rate and asks no display mode | reference lab 46020419675 (SCREENS=fps): `SurfaceView - com.mxtech…` rel -2, DEVICE, buffer 1280x720, Frame Rate column empty, no preferredRefreshRate/DisplayModeId; Innocent: one 1080x2316 Flutter surface |
| 4 | On the emulator, the film on a SurfaceView: Flutter 0 frames, app 6-8 % (texture 44-54 %) | device lab P1-E1 46019884853 (CPU-drawn emulator: shares only); layers film SV / window / Flutter see-through SV, all three DEVICE |
| 5 | ExoPlayer's loop wakes every 10 ms (dynamic scheduling off by default) | Media3 1.9.2 ExoPlayer.java: `dynamicSchedulingEnabled` default false |
| 6 | ♪ said "no audio tracks" on every catalogue film | ExoStreamEngine reported video tracks only — fixed |
| 7 | Settings → Audio → Loudness normalization never did anything | libmpv-android-video-build v1.1.11's libmpv.so has no dynaudnorm/acompressor/alimiter (strings of the .so, 27 Nov) — now DynamicsProcessing |
| 8 | Report a problem could not say 60 vs 120 Hz | `hz=` was in lab lines only — fixed (`· N Hz · gap 8.3`) |
| 9 | The owner's phone ran the player at 60 Hz on 20 Nov | 1.64.86's report: no 10 s window above 59.4 fps; the next report says it outright |

## 2. What is on the branch (not live)

- **P1 lab** (lab builds only): SmoothLab looks `sched`, `t`, `sv`,
  `svsched`, `…prof`, step `local` (a minute of the playing rung copied as
  one byte range, libmpv), `mpvsv`; PlayerLab.kt (`innocent/lab`).
- **P2/P3** (ships): DisplayVote.kt votes on Flutter's own SurfaceView — the
  film's exact rate, FIXED_SOURCE, seamless only, 0 on pause/close
  (ExoPlayer natively, libmpv from `container-fps`); the display's highest
  rate while touched and 1.5 s after (DisplayRate, app root Listener).
  Report a problem names the display's rates and what was asked.
- **P4** (ships): ♪ tracks on catalogue films; Synchronization on ExoPlayer
  (ExoAudio.DelayedSink: the audio clock moved); Stereo mode and Night sound
  (audio/AudioShape.kt on ExoPlayer's PCM, JVM-tested in tool/audiojvm, a
  Build step; libmpv: `audio-channels=mono`, `pan` for swap, Night and
  levelling by DynamicsProcessing on its session); Disable; Volume boost in
  ♪ (100 % to the swipe's ceiling). The look: MX | Innocent sheet sent to
  the owner (§5) — **the owner's approval is pending**.
- Tests: audio_menu_test (7), display_rate_test (4), cpu_probe_test (+1),
  tool/audiojvm (9); CI Build 46023679241 green to the APK step (see §4).

## 3. Tomorrow, 28 Nov (Test Lab resets 08:00 UTC; five tests)

1. **P0** (2 tests): `cloud.env` STREAM_SMOOTH="" with the jump checks as
   the fifty-first; dated comment "fifty-sixth: P0 … the day's tests 1-2".
   The code is 1.64.90's plus lab hooks and the branch's P2-P4 (say so).
2. **P1 A/B** (2 tests): in the same push or after P0 finishes —
   `.github/workflows/device-cloud.yml`: both `--timeout 360s` lines become
   `--timeout "$([ -n "${STREAM_SMOOTH:-}" ] && echo 600s || echo 360s)"`
   (the app closes a smoothness run at 585 s since 617f409d); STREAM_SMOOTH
   = the plan of device lab P1-E2 (config.env SMOOTH_PLAN) with longer
   windows: films 20 s, controls 12 s, prof 12 s. ONE window switch (a
   second stopped the film on the emulator).
3. Read: per look, app % and per thread, Flutter fps, raster p50, the
   `LAB main` lines; realme and OPPO each. Then the owner's decision with
   pictures of the dialogs (glass blur over the film vs tint).
4. If `sv` wins: production work — the film's SurfaceView placed and
   sized by the player (fit/zoom/pan/crop from Flutter's numbers), the
   screenshot by PixelCopy, the in-app PiP window on the texture (or its
   own view), the Display colour filters (fall back to the texture while a
   colour change is on), mirror/flip (texture), Night mode (picture) as a
   black 60 % layer; ExoPlayer then votes its own rate on its surface.

## 4. Open when this was written

- Device lab P1-E2 (the Test Lab plan on the emulator): pushed ce1f1dc3.
- Build 46023679241 (f20ecade, P4 Kotlin): Test and Analyze green, APK
  step running.
- P5 not started: (a) reference lab — MX's subtitle gestures (swipe on the
  line, drag, pinch) measured before building; (b) online subtitles: an edge
  function holding the key (skill edge-deploy), app sheet in CC → Online.
  OpenSubtitles: 5 downloads a day without an account, 20 with a free one,
  shared by every viewer through the server's one login — a per-viewer cap
  needs a table (skill architecture-review).

## 5. The owner's steps

1. ♪'s new look: the sheet `p4_audio_mx_vs_innocent.png` — yes, or what to
   change.
2. OpenSubtitles (for P5): make an account at opensubtitles.com → Profile →
   API consumers → New consumer → copy its API key; then Supabase →
   Project → Edge Functions → Secrets: add `OPENSUBTITLES_API_KEY`, and the
   account's `OPENSUBTITLES_USERNAME` and `OPENSUBTITLES_PASSWORD` (the
   free account's 20 a day). Never in chat.
3. After a release: Report a problem from the phone with a film playing
   and a menu flung (it now says the Hz).

## 6. The prompt for the next session

```
Innocent player — "MX ထက် ပိုကောင်းအောင်" session 2 (28 Nov 2026).
docs/handoff_2026_11_28_beyond_mx_p1.md ကို အရင်ဖတ်ပါ (CLAUDE.md, BACKLOG §0
newest entry, skill device-labs, ui-design, release)။ Work branch:
claude/extract-github-release-oteqr5 (fast-forward push)။
1. 08:00 UTC နောက်မှ Test Lab: P0 stream check ၁၆ ခု (realme, OPPO) ပြီးရင်
   P1 A/B (handoff §3 အတိုင်း timeout ပြင်ပြီး)။ cloud.env comment တွေနဲ့ ဒီနေ့
   test အရေအတွက် ရေတွက်ပါ။
2. P1 ဇယား (look အလိုက် app %, thread အလိုက်, fps, raster, LAB main) နဲ့
   dialog glass ပုံတွေ ပြပြီး ကျွန်တော့် ဆုံးဖြတ်ချက် ယူပါ။
3. ♪ ပုံကို ကျွန်တော် approve လုပ်ပြီးရင် P4 ကို phone မှာ စစ်ဖို့ ပြင်ပါ။
4. P5: reference lab မှာ MX subtitle gesture တိုင်းပြီး လုပ်ပါ၊ online subtitle
   ကို ကျွန်တော် secret ထည့်ပြီးရင် edge function နဲ့ လုပ်ပါ။
5. Release ကို "release" လို့ ပြောမှ။ အဆုံးမှာ မြန်မာလို report, ဇယား,
   ဖုန်းမှာ စမ်းရမယ့် အဆင့်, handoff နဲ့ prompt။
```
