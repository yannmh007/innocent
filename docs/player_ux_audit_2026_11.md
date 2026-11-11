# The player, screen by screen — UI/UX and behaviour audit (11 Nov 2026)

The owner's request: go through the video player the way a viewer meets it —
every menu, both orientations, every language — find what is broken, cramped
or wrong, fix what is safe, and bring it toward a complete, MX-level player.
This document is the record: how the player was examined, what was found,
what was fixed (each with the test that holds it), and what is left.

## 1. How it was examined

**The real PlayerScreen in a widget test, photographed.**
`test/support/player_harness.dart` pumps the actual `PlayerScreen` (inside a
GoRouter, as in the app) on `test/support/fake_player_service.dart` — an
engine with no libmpv or ExoPlayer that "plays" a 1:29:22 film with two audio
and two subtitle tracks, and sends media_kit's `auto` / `no` pseudo-tracks the
way the real one does. The phone's own services answer nothing.

`test/player_layout_test.dart` drives it into 34 states (the controls, the
expanded shortcut row, ⋮ and every item in it, the subtitle panel, the track
lists, the decoder, sleep-timer, resume and custom-speed dialogs, the lock
and Kids Lock, an error, A-B repeat, the gesture indicators …) on three
phones — a 360 × 800 dp 720p budget phone (this app's commonest), the
owner's 411 × 882 (with a 30 dp camera cutout), and a 320 × 640 (a small
phone, or a large "display size") — in portrait and landscape, in English,
Burmese and Thai, at font scale 1.0 and 1.3. That is 1,224 layouts. Any
overflow fails the test; with real fonts it writes a PNG of each:

```bash
PLAYER_SHOTS=<out dir> FONT_DIR=<dir> flutter test test/player_layout_test.dart
```

`FONT_DIR` holds Roboto (Regular/Medium/Bold) and MaterialIcons from the
Flutter SDK (`bin/cache/artifacts/material_fonts/`) plus NotoSansMyanmar.ttf
and NotoSansThai.ttf (github.com/google/fonts, ofl/). Narrow with
`SCENES=more,sleep`, `LANGS=my,th`, `SCALES=1.3`. Without the fonts the
glyphs are the test font's boxes and the photographs are only rough.

Why Noto Sans Myanmar matters: Flutter on Android takes Burmese from the
system's "elegant" Noto Sans Myanmar, whose lines are nearly twice as tall as
Latin ones at the same size. Most of the layout faults below are boxes sized
for Latin text.

**What the buttons do.** `test/player_controls_test.dart` taps, holds and
presses Back on the same screen, in both orientations.

## 2. Found and fixed

Each with the test that holds it. The tests for B1–B6, B8 and L1 were run on
the code before the fix and failed there (B6 also by reverting the fix).

### Wrong behaviour

| # | What the viewer met | Fix | Test |
|---|---|---|---|
| B1 | **Back with ⋮, the subtitle panel or a player dialog open closed the film.** They are drawn inside the player, not routes, so Back went to the exit path. | Back closes the open panel or dialog first (`_handleBackRequest`). | controls: *Back closes an open menu…* |
| B2 | **In portrait there was no way to choose subtitles or another audio track.** ♪ and CC were landscape-only "because ⋮ has them" — it never did. The owner's MX screenshots (Oct) show them in both orientations. | ♪ and CC on the top bar in both orientations; a narrow portrait bar drops the clock to keep the title readable; the decoder label never wider than 44 dp. | controls: *the audio and subtitle buttons are on the top bar* |
| B3 | **Holding Next never opened the repeat menu.** Its tooltip ("hold for loop options") took the long press for itself. | No tooltip on Next; name and both actions through Semantics. | controls: *a long press on Next opens the repeat menu* |
| B4 | **Every film watched left a timer waking the phone every 4 s**, for the app's life, holding its dead controller. The decode watch's cancel had been pasted into the background-play code instead of `dispose()` (24 Sep). | Cancelled in `dispose()`; removed from the background-play path, where it switched the decode watch and the silent-file check off whenever Background play was on. | every harness test (no timer may outlive the screen) |
| B5 | **The history entry for where the viewer stopped was never written.** The final save runs from `dispose()`, and read `state` after its first await. | Everything it needs is read before the await. | every harness test (the error is gone) |
| B6 | **The audio menu listed "Track auto" and "Track no"**, and the "more than one track" dot on ♪ and CC was lit for every file: media_kit's pseudo-tracks reached the menus. | Only real tracks reach the state; the subtitle dot means "there is a subtitle". | controls: *the audio menu lists the film's tracks…* |
| B7 | **Display Settings did nothing.** Its four sliders moved numbers nothing read, and were back at 0 on reopening. | `video_adjust.dart`: a colour matrix over the video (as Night mode), libmpv and ExoPlayer alike, composed with Night mode into one filter, kept while the player is open; Reset greys out when untouched. | `video_adjust_test.dart`; controls: *Display Settings changes the picture* |
| B8 | **"Lock screen on rotation" locked one rotation late**: it read MediaQuery before the rebuild (the old shape) and had no starting orientation. | The window's own size; the start seeded on first build. | controls: *"Lock screen on rotation" locks on the turn…* |
| B9 | **The rotate button's first tap did nothing visible** on a phone held upright (Auto → Portrait). | From Auto it pins the orientation the screen is not in, then the other, then Auto. | geometry: `nextRotationMode` |
| B10 | **Speeds read four ways**: 1.25 showed "1.3X" on the shortcut and the speed badge (0.75 "0.8X"), "2.00x" in the toast; and the 1X shortcut, from a speed off its cycle (1.75), went to 0.5. | `domain/speed_format.dart` everywhere; the shortcut steps up. | geometry: *speeds* |
| B11 | **Two English audio tracks both read "eng"** (the film and its commentary). | Title · language by its own name · codec and channels ("Commentary · English · AAC 2.0"); subtitles the same way; `language_names.dart`. | `track_names_test.dart` |
| B12 | The menus marked nothing (subtitles: "None") while libmpv was showing a track it chose itself. | `MediaKitPlayerService.currentTrackId` read when a menu opens. | (engine only; device check) |
| B13 | Audio, subtitle, decoder and aspect confirmations came as the app's snackbar, over the seek bar for four seconds. | The player's own toast, under the top bar. | — |

### Layout (all found by the harness)

| # | Where | Fix |
|---|---|---|
| L1 | 360 dp and under: **Next and the screen-mode button shared a touch area** (14 dp on 360; on 320 the icons touched). | `transportLayout`: the gaps close first, then the row goes side by side; Play stays centred wherever it can. |
| L2 | Font size 1.3: **the remaining time broke over two lines** ("-1:16:4 / 8"). | Time labels as wide as their longest text at the phone's font size. |
| L3 | ⋮ in Burmese: **every two-line label had its second line cut off.** | Rows as tall as their tallest label (never under MX's 84 dp); no squeezed line height. |
| L4 | Sideways: **the track lists showed two tracks**; the rest, and "Load external", were off the screen. | Lists give way inside a sheet up to 85 % of the screen (`tallSheetConstraints`). |
| L5 | The subtitle panel: options cut off sideways at a large font; header text past the edge on 320 dp. | Options scroll; the header's texts share the row. |
| L6 | Sleep timer, 320 dp tall: **STOP and START off the screen.** | The keypad shrinks before the buttons do. |
| L7 | The expanded shortcut row: **Burmese labels shrunk to ~6 sp** (no spaces, so one "word"); the viewer's own shortcuts moved to the far end. | Burmese and Thai wrap between syllables, the row grows; the viewer's shortcuts first. |
| L8 | The error banner, speed badge, A-B badge and speed slider ignored the cutout; the A-B badge sat on the portrait seek bar. | All placed from the controls' insets. |
| L9 | Display Settings, Skip markers, Bookmarks, the repeat menu: **cut off sideways** (or with many bookmarks). | Scroll inside a taller sheet. |
| L10 | Cut sheet "not set" (Burmese, 320 dp), the aspect list, the resume dialog's buttons, the error banner's buttons, the custom-speed dialog: past the edge at 320 dp or font 1.3. | Text gives way; buttons wrap (`OverflowBar`); the dialog scrolls. |
| L11 | The subtitle track list opened over the subtitle panel, both on screen. | The panel closes first, as for its other rows. |
| L12 | Bookmark delete button named "Close" for TalkBack. | "Delete". |

## 3. Left as it is, on purpose

* **Back while the screen is locked still leaves the film.** Kids Lock
  swallows Back; the ordinary lock blocks touches only. MX's behaviour could
  not be confirmed (searched); immersive mode already needs a second swipe.
  Change only on the owner's word.
* **The error banner shows libmpv's own sentence** under the translated
  title. For a catalogue film it names the loopback proxy, never the signed
  URL, and the screen is FLAG_SECURE; it is what a support question needs.
* **"Online subtitles" shares a search link** instead of opening it: there is
  no `url_launcher` in the app; adding a dependency is a separate decision.

## 4. Toward a complete player — what MX has that this does not

Ranked by what a viewer here would miss:

1. **Chapters** (MKV/MP4 chapter marks on the seek bar, next/previous
   chapter). libmpv exposes `chapter-list`; the catalogue's HLS films have
   none, local files often do.
2. **A subtitle search and download in the app** (OpenSubtitles API, needs
   an account and a key — server side, through an edge function).
3. **The current track when nothing was chosen, on the ladder engine**
   (ExoPlayer): B12 covers libmpv only.
4. **Cast** (Chromecast / DLNA): large; only if asked.

Everything else in MX's feature list (decoders, gestures, A-B, sleep timer,
equaliser, booster, PiP, background play, kids lock, screen modes, bookmarks,
seek previews, resume, up next, speed 0.25–4×) is here; this audit was about
whether it works and fits, not whether it exists.

## 5. Changelog
- 11 Nov 2026: written with the fixes above.
