# Handoff, 27 Nov 2026 (evening): beyond MX — the next sessions' plan

Written after 1.64.90 shipped (the player's menus smooth: BACKLOG §0,
"THE PLAYER'S SMOOTHNESS — FOUND, FIXED, MEASURED", and the 1.64.90 record).
The owner's word for what follows: "as MX, or better than MX; study other
apps too, research and confirm before doing". This file is the research,
the analysis, the order of work and the prompt to paste (§7).

Read first: CLAUDE.md, BACKLOG §0 (the newest entries), this file,
`.claude/rules/flutter-app.md`, skills `ui-design`, `device-labs`,
docs/handoff_2026_11_26_mx_parity.md §5.0 (the MX table) and §6 (how to
prove a change).

## 0. Where things stand (27 Nov)

- Live: 1.64.90+403 (main 956e2518). The player is MX's in layout (26-27
  Nov) and its menus scroll at 49-50 fps with 2-4 % late frames on the
  realme and the OPPO (1.64.89: 13-17 fps, 58-78 % late).
- The tools exist and work: CpuProbe's frame times (`b90 … r90 … · late N`
  in every 10 s line, and in Report a problem); SmoothLab (lab builds:
  `STREAM_SMOOTH` in cloud.env, flow `smooth` and `idle_screens` on the
  emulator; `fn:` steps tap every button on a real phone); the reference
  lab (`.github/workflows/reference-lab.yml`, test_device/ref/: MX 3.4.3 —
  the owner's version — beside Innocent on one emulator, screens dumped and
  measured in dp by tool/ref/*.py).
- Not run on 1.64.90's exact code: Test Lab's sixteen stream checks (the
  day's five tests went to the smoothness runs). Run them first (§3 P0).

## 1. What the research found (27 Nov; sources at the end)

The web is half open from here: play.google.com, sites.google.com,
apkmirror.com and videolan.org answer nothing to this sandbox (the
researcher's fetches: ENOTFOUND). So MX's own listing, changelog and
reviews were NOT read — the reference lab, which runs MX itself, is the
ground truth for MX, and a GitHub runner can fetch those pages if needed
(CLAUDE.md: "reach the rest from a GitHub runner").

**MX Player (old third-party reviews, to be confirmed in the lab):**
gestures for brightness, volume, zoom and seek with an adjustable seek
speed; subtitle gestures (scroll to jump line to line, drag up/down to
move the subtitle, pinch to resize); a subtitle Synchronize panel; HW, HW+,
SW decoders and a custom codec pack. Everything else (audio boost over
100 %, night mode, frame step, kids lock, SMB, Chromecast) was not
verifiable here.

**Just (Video) Player** (ExoPlayer, open source, ~12 MB; its README):
auto-PiP when leaving the app; frame-rate matching (TV); volume boost;
long-press to lock touch; decoder priority (device or app) and tunneled
playback for 4K/HDR; Dolby Vision profile 7 played as HDR HEVC; skip
silence; default audio-track preferences; works with system equalizers;
no ads, no tracking. **Nova Video Player** (open source, ffmpeg): a media
library with TMDb scraping and Trakt scrobbling. **mpv-android**: libass
styling and two subtitles at once, no subtitle download, settings in
engine terms. **VLC**: open source, no ads, many network protocols, a
media library (not fetched: its feature page was out of reach).

**The platform (official docs, read):**
- Frame-rate matching: `Surface.setFrameRate(fps,
  FRAME_RATE_COMPATIBILITY_FIXED_SOURCE, strategy)` once, with the exact
  rate (23.976, not 24); `CHANGE_FRAME_RATE_ALWAYS` for a film,
  `ONLY_IF_SEAMLESS` for a short clip; `setFrameRate(0)` on pause/end; a
  non-seamless switch needs the user's "match content frame rate" and
  shows ~1-2 s of black. Media3 has
  `ExoPlayer.setVideoChangeFrameRateStrategy` and calls setFrameRate on
  ITS output surface — but Innocent's video goes through Flutter's
  SurfaceProducer (an ImageReader), so that call reaches a surface no
  display shows: the vote must go on Flutter's own SurfaceView, from the
  app. Innocent calls setFrameRate nowhere today (neither engine).
- 120 Hz for the app's UI: Flutter does not ask for it
  (flutter/flutter#35162); a plugin sets `preferredDisplayModeId`
  (flutter_displaymode; "no effect on LTPO panels"). The owner's phone is
  120 Hz capable; whether Innocent runs at 60 or 120 there is unknown —
  CpuProbe's lines now carry `hz=` in LAB frames and the display rate is
  read from Flutter's view: ask the owner for a Report a problem.
- Audio on ExoPlayer: alternate HLS audio renditions are `Tracks.Group`s
  (select with `TrackSelectionOverride`); there is NO audio-delay API in
  Media3 (a custom AudioProcessor/AudioSink would be needed); volume boost
  and night mode have no Media3 processor — Android's `LoudnessEnhancer` /
  `DynamicsProcessing` on the audio session do it; `ChannelMixingAudioProcessor`
  mixes channels (mono, swap). libmpv has `audio-delay` (Innocent uses it).
- Audio offload (`AudioOffloadPreferences`): long screen-off playback;
  some devices misreport support.

## 2. The analysis: where Innocent stands against MX and the best of the rest

| Area | MX 3.4.3 | Innocent 1.64.90 | Better-than-MX move |
|---|---|---|---|
| Layout of the controls and menus | the reference | matched within 0.5 dp (26 Nov lab) | keep; tablets/TV already fitted |
| Menu smoothness | native views | 49-50 fps, 2-4 % late (phones) | 120 Hz on capable phones (P3) |
| CPU / battery while a film plays | 26 % (owner's meter, 4 Oct, 720p) | realme 50-73 %, OPPO 46-65 % app CPU (Test Lab, Sintel HLS); Flutter re-composites every video frame (raster 9-14 %) | P1: find and cut it, measured |
| The film's own smoothness (24 fps on 60/120 Hz) | unknown (lab) | no frame-rate vote: 3:2 judder on 60 Hz | P2: setFrameRate on Flutter's surface |
| ♪ on a catalogue (HLS) film | n/a | "no audio tracks"; audio delay libmpv-only | P4: Tracks.Group list; delay on ExoPlayer |
| Audio boost / night / mono | (unverified) | Audio Effect sheet (system EQ) | P4: LoudnessEnhancer, DynamicsProcessing, ChannelMixing |
| Subtitles | gestures, sync, styles | sync, styles, position, two tracks (libmpv); online = a browser search | P5: MX's subtitle gestures; in-app online subtitles |
| PiP | yes | custom in-app window + system PiP | P7: auto-PiP on leaving, seamless resize |
| Ads, privacy | ads (free) | none | keep; say so in the store text |

## 3. The order of work (each step: numbers before, the change, numbers after)

**P0 — first, every session after a release (30 min).** Test Lab's stream
checks on the live code (cloud.env: `STREAM_SMOOTH=""`, the jump checks
back, realme and OPPO: 2 of the day's 5; count cloud.env's dated comments
since 08:00 UTC). The owner's Report a problem from the phone: read its
CpuProbe lines (hz, b90/r90, late) and BACKLOG what they say.

**P1 — the battery while a film plays (beat MX's 26 %).** Measure first,
per thread, on both phones, Sintel (HLS, ExoPlayer) and a local file
(libmpv), the controls hidden and up, 60 s each (SmoothLab steps
`play:film:now:60`, `play:controls:now:…` — add a local-file variant).
Then ask: what does the raster thread do per video frame (Impeller
composites the whole scene at the film's rate even with nothing over it)?
Can the scene be cheaper when nothing is over the film (no BarShade, no
layers)? Would a platform view (the film on Android's own SurfaceView, as
MX draws it) cut the copy and the composite — what does it cost the
controls over it (Flutter 3.32's hybrid composition modes)? Read the
engine/media_kit code before choosing; an A/B in one Test Lab run. MX's
own CPU cannot be measured on the emulator (it runs arm64 under
translation there): the owner's phone meter, both apps, the same film,
one minute each (§6 owner steps).

**P2 — the film's smoothness: frame-rate matching.** setFrameRate on
Flutter's SurfaceView (a small Kotlin call through the existing channel)
with the film's exact rate when it plays, 0 on pause and close; Media3's
strategy OFF so it does not vote on the ImageReader. Measure with
`dumpsys SurfaceFlinger` (the layer's vote and the display mode) in the
device lab, then the owner's eyes on a 24 fps film. MX's behaviour first,
in the reference lab (does MX vote?).

**P3 — 120 Hz where it helps.** Whether the owner's phone runs Innocent
at 60 (the report's `hz`); if so, a high-refresh vote while a menu or a
list is touched and 60 (or the film's rate) otherwise — battery measured.
Test Lab's phones are 60 Hz: the owner's phone is the proof.

**P4 — audio on catalogue films.** ♪ lists the HLS audio renditions
(ExoEngine → Tracks.Group) and switches them; the audio delay on ExoPlayer
(a custom AudioProcessor that holds back or drops PCM by the delay —
research Media3's AudioProcessor/AudioSink first, prove A/V offset with a
clap test film); boost/night/mono via the audio session (LoudnessEnhancer,
DynamicsProcessing, ChannelMixingAudioProcessor) — MX's ♪ items the owner
already chose (Synchronization only, 26 Nov): ask before adding more.

**P5 — subtitles beyond MX.** Measure MX's subtitle gestures in the lab
(scroll a line, drag the position, pinch the size); in-app online
subtitles (OpenSubtitles' API needs a key: the owner sets it as a secret,
an edge function holds it — never in the app); a thick outline (stroke >
4 dp) is drawn as a path every frame: cap or draw it another way.

**P6 — the rest of MX's screens, one at a time** (docs/handoff_2026_11_26_
mx_parity.md §5.0 rows 8-12: each ⋮ tile's own screen, CC's Settings ▾
sheets, the gesture readouts, the lock screen, the HW dialog, the EQ) —
reference lab pictures side by side, the owner's word on each.

**P7 — PiP and the session.** Auto-PiP on leaving (Android 12+
`setAutoEnterEnabled`), seamless resize, the notification's controls —
check what 1.64.90 does on both phones first.

**P8 — later, if the owner wants:** HDR on SDR screens and Dolby Vision
profile 7 (Just Player plays it as HEVC), tunneled playback for 4K, a
media library with scraped posters (Nova), a store listing that says "no
ads" (MX's free app has them).

**Small leftovers from the smoothness session:** the locked album tiles
blur (σ 14, ImageFiltered) every frame of a scroll — a pre-blurred small
decode instead; the gesture HUD's blurred text shadows; ♪'s "no audio
tracks" on a catalogue film (P4).

## 4. How to prove (unchanged, and what this session added)

docs/handoff_2026_11_26_mx_parity.md §6, plus: a change to anything drawn
over the film or in a list runs test/player_smoothness_test.dart and a
SmoothLab pass (`base` beside `now` in one run per phone); a change to a
button runs test/player_functions_test.dart; the legibility test for any
ink; the layout matrix for any size. Test Lab quota: five a day, reset
08:00 UTC — plan the day's runs before the first push.

## 5. Questions for the owner (ask at the start)

1. P1's platform-view route changes how the film is drawn: worth a
   measured A/B before deciding?
2. P2: a 1-2 s black moment when the phone switches rate for a film (only
   when "match content frame rate" is on): acceptable, or seamless only?
3. P3: 120 Hz only while touching a menu/list (battery) or always?
4. P4: which of MX's other ♪ items (Disable, SW audio decoder, Stereo
   mode, boost) to bring in — the owner took only Synchronization on 26 Nov.
5. P5: in-app online subtitles need an OpenSubtitles API key (the owner's
   account, a secret on the server): wanted?

## 6. What the owner can do on the phone (for P0/P1)

1. Update to 1.64.90 (Me → update, or the notice), open a film, use ⋮ and
   the More page; then Settings → Report a problem → send.
2. For MX's CPU beside Innocent's: the same local film in each app, one
   minute, the phone's CPU/GPU meter (as on 4 Oct) — a screenshot of each.

## 7. The prompt to paste (next session)

```
Innocent player — "MX ထက် ပိုကောင်းအောင်" session (27 Nov 2026 handoff).

1.64.90 ထွက်ပြီးပါပြီ (⋮ menu scroll ချောမွေ့ပြီ)။ နောက်တစ်ဆင့်အနေနဲ့
player ကို MX Player နည်းတူ (သို့) MX ထက် ပိုသာအောင် လုပ်ချင်ပါတယ်။
အရင် research/analysis လုပ်ထားတာနဲ့ plan က
docs/handoff_2026_11_27_beyond_mx.md မှာ ရှိပါတယ်။

လုပ်စေချင်တာ:
1. CLAUDE.md, docs/handoff_2026_11_27_beyond_mx.md (အပြည့်), BACKLOG §0
   (1.64.90 record နဲ့ smoothness entry), .claude/rules/flutter-app.md,
   docs/handoff_2026_11_26_mx_parity.md §5.0 နဲ့ §6, skill ui-design,
   device-labs, release ကို အရင်ဖတ်ပါ။ Work branch:
   claude/extract-github-release-oteqr5 (session branch က main ကနေ
   စရင် BACKLOG §0 အတိုင်း work branch ကို fast-forward push)။
2. P0 ကို အရင်လုပ်ပါ: 1.64.90 code ပေါ်မှာ Test Lab stream check ၁၆ ခု
   (realme, OPPO — cloud.env comment တွေနဲ့ ဒီနေ့ test အရေအတွက်
   ရေတွက်ပါ၊ တစ်ရက် ၅ ခု၊ 08:00 UTC reset)။ ကျွန်တော့် Report a
   problem ရောက်နေရင် CpuProbe line (hz, b90/r90, late) ကို ဖတ်ပြီး
   ကျွန်တော့် ဖုန်း 60 Hz လား 120 Hz လား ပြောပါ။
3. handoff §5 ထဲက မေးခွန်း ၅ ခုကို အရင် ကျွန်တော့်ကို မေးပါ (တစ်ခုချင်း
   ဘာကြောင့်ဆိုတာ နံပါတ်နဲ့)။
4. P1 (film ဖွင့်ထားစဉ် CPU/battery — MX ရဲ့ 26% ကို ကျော်ဖို့):
   thread အလိုက် အရင်တိုင်းပါ (ExoPlayer HLS + libmpv local file,
   controls ဖွင့်/ပိတ်)၊ raster thread က video frame တိုင်း ဘာလုပ်လဲ
   engine/media_kit code ဖတ်ပြီး သက်သေပြပါ၊ ဖြေရှင်းနည်း ၂-၃ မျိုးကို
   Test Lab run တစ်ခုထဲမှာ A/B နဲ့ တိုင်းပြီးမှ ရွေးပါ။
5. P2 (frame-rate matching: 24 fps film ကို judder မရှိ) နဲ့ P3 (120 Hz)
   ကို reference lab မှာ MX ဘယ်လို လုပ်လဲ အရင်ကြည့်ပြီး လုပ်ပါ။
6. P4 (catalogue film မှာ ♪ audio track list, audio delay on ExoPlayer,
   boost/night/mono) နဲ့ P5 (subtitle gesture, online subtitle) ကို
   ကျွန်တော့် အဖြေအတိုင်း လုပ်ပါ။
7. ဘယ်ပြောင်းလဲမှုမဆို: မပြင်ခင်/ပြင်ပြီး နံပါတ်ဇယား (fps, late %,
   CPU % thread အလိုက်, battery)၊ test/player_smoothness_test.dart,
   player_functions_test.dart, legibility, layout matrix (PLAYER_PHONES=all LANGS=my,en,th
   SCALES=1.0,1.3)၊ whole suite၊ flutter analyze (path မပါ)၊ check.py —
   အကုန် green ဖြစ်ရမယ်။ ပုံစံ ပြောင်းရင် MX | Innocent ပုံ ဘေးချင်းယှဉ်
   ပြပြီး ကျွန်တော့် ခွင့်ပြုချက် ယူပါ။
8. တွေ့သမျှ အားနည်းချက်ကို ပြင်ပါ၊ ဘာကြောင့်လဲ နံပါတ်နဲ့ ပြပါ။
9. Release ကို ကျွန်တော် "release" လို့ ပြောမှ လုပ်ပါ။ အဆုံးမှာ
   မြန်မာလို report၊ before/after ဇယား၊ ဖုန်းမှာ စမ်းရမယ့် အဆင့်တွေ၊
   နောက် session အတွက် handoff နဲ့ prompt ရေးပေးပါ။
```

## Sources (27 Nov 2026)

- Android, frame rate: https://developer.android.com/media/optimize/performance/frame-rate
- Media3 ExoPlayer (setVideoChangeFrameRateStrategy):
  https://developer.android.com/reference/androidx/media3/exoplayer/ExoPlayer
- Media3 track selection, audio offload:
  https://developer.android.com/media/media3/exoplayer/track-selection
- Media3 DefaultAudioSink:
  https://developer.android.com/reference/androidx/media3/exoplayer/audio/DefaultAudioSink
- ChannelMixingAudioProcessor:
  https://developer.android.com/reference/androidx/media3/common/audio/ChannelMixingAudioProcessor
- Flutter high refresh rate: https://github.com/flutter/flutter/issues/35162 ,
  https://pub.dev/packages/flutter_displaymode
- Flutter performance (saveLayer): https://docs.flutter.dev/perf/best-practices
- Just (Video) Player: https://github.com/moneytoo/Player
- Nova Video Player: https://github.com/nova-video-player/aos-AVP
- MX Player (older reviews, unconfirmed for 3.4.3):
  https://www.guidingtech.com/mx-player-tips-tricks ,
  https://mobile.softpedia.com/android/MX-Player-Android-Review-2770.html
- VLC / mpv-android / MX comparison (secondary):
  https://apkpure.net/articles/vlc-vs-mx-player-vs-mpv-android
