# Player gestures — MX Player parity, research and design

Owner request (2026-10-04): MX-level gestures on phones and tablets, researched
first: MX Player's own gesture system, developer guidance on gestures, then
built into Innocent "at the highest level".

## 1. What MX Player does

Sources: MX Player's feature page (sites.google.com/site/mxvpen/features —
blocked from the build machine, quoted through search results), Google Play
listing, AndroidPolice / DroidViews / TechnoSlate write-ups, and the owner's
MX screenshots (docs PDF, pages 7 and 9).

| Gesture | MX behaviour |
|---|---|
| Tap | Show / hide the controls. |
| Double tap | Optional. Play / pause in the centre; with "FF/RW", left and right thirds seek back / forward. |
| One-finger horizontal swipe | Seek. The position follows the finger; the overlay reads `+00:15 [01:23:45]`, the frame under the finger updates. |
| One-finger vertical swipe, left half | Screen brightness (window brightness, not the system setting). |
| One-finger vertical swipe, right half | Volume. With the audio booster on, swiping past the top carries on into boost (MX: up to 200 %). |
| Two-finger vertical swipe | Playback speed up / down. |
| Pinch | Zoom the video. |
| Two-finger drag while zoomed | Pan ("Zoom and pan"). |
| Long press | Speed slider: drag left / right without lifting (owner's PDF p. 9). Newer builds also "hold for 2×". |
| Subtitle scroll | Horizontal swipe on the subtitle text: previous / next subtitle line (seeks to it). |
| Subtitle up / down | Vertical drag on the subtitle text: moves the subtitle. |
| Subtitle zoom | Pinch on the subtitle text: subtitle size. |
| Lock | Lock button disables every gesture; kids lock too. |

Each gesture has its own on / off switch in Settings → Player → Gestures.

## 2. Guidance this follows

* **Android gesture navigation** (developer.android.com, "Ensure compatibility
  with gesture navigation"): Back is an inward swipe from the left or right
  edge; Home / Recents are swipes from the bottom and apps "can't opt out" of
  those (mandatory system gesture insets). Exclusion rects are capped at
  200 dp of height and are for precise edge controls (a seek-bar thumb), not
  for whole-screen swipes. Conclusion: do not grab the edges — start player
  swipes only inside `MediaQuery.systemGestureInsets`, plus a top margin for
  the notification shade.
* **VLC for Android** (VideoTouchDelegate.kt, the most mature open-source
  implementation): a 24 dp safety margin on every side; a swipe counts as
  vertical only when it is clearly steeper than horizontal (|dy/dx| > 2);
  repeated double taps on the same side stack, the other side resets; volume
  and brightness move by a fixed fraction of the screen per distance.
* **YouTube for Android**: double-tap seek stacks (four taps on the left
  = −20 s), shows the running total at once, and a single tap after a
  double-tap keeps adding without waiting for another double tap.
* **Android ViewConfiguration**: touch slop and double-tap timeout / slop
  come from the platform (scaled to density); gestures are decided only
  after the finger has moved past the slop.
* **WCAG 2.2 SC 2.5.1 Pointer Gestures**: anything done with a path or
  multi-point gesture needs a single-pointer alternative. Every player
  gesture here has one (seek bar, ± buttons, volume keys, speed menu, zoom
  via aspect button, subtitle settings), and none is required.

## 3. Innocent before this work

Had: tap, double tap (thirds), one-finger seek / brightness / volume, pinch
zoom, long-press speed slider, per-gesture switches, indicators.

Missing or weaker than MX:

1. Swipes started inside the system-gesture zones fought Back / Home / the
   notification shade.
2. Direction decided by `dx > dy` at 16 px: a slightly diagonal brightness
   swipe became a seek.
3. Sensitivities were fractions of the screen: on a 1280 dp tablet the
   brightness range was 768 dp of finger travel, seek 90 s per 1280 dp; a
   one-minute clip was seekable by 90 s per width.
4. Double tap did not stack and showed no running total.
5. No two-finger speed, no pan while zoomed, no subtitle gestures.
6. Volume swipe stopped at 100 % even with the booster on.

## 4. Design

A pure state machine, `PlayerGestureEngine`, takes raw pointer events
(down / move / up / cancel with ids, positions and times) and emits intents.
It has no Flutter widgets in it, so every rule below is unit-tested with a
fake clock.

* **Start zones.** A pointer that goes down inside the system-gesture insets
  (or the top 24 dp) can still tap; it can never start a swipe.
* **Slop.** 18 dp (Flutter's kTouchSlop); pinch / two-finger slop 24 dp.
* **Direction lock.** Vertical only if |dy| > 1.5 |dx|, horizontal only if
  |dx| > 1.5 |dy|; in between, wait for more movement.
* **Physical scaling.** Brightness / volume: the full range takes
  `clamp(0.6 × height, 200, 480) dp`, the same feel on a phone in either
  orientation and on a tablet. Seek: 90 s per `min(width, 600) dp`, never
  more than the whole film per width for short clips.
* **Double tap.** Left / right thirds seek, centre plays / pauses. After a
  side double tap, every tap on that side within 0.6 s adds another step
  immediately; the other side or 0.6 s of quiet ends the run. The overlay
  shows the running total.
* **Two fingers.** Both fingers moving the same way vertically, with their
  spacing changing by less than 24 dp: speed, 0.1× per 24 dp, 0.25×–4×.
  Spacing changing first: pinch zoom, and the midpoint's movement pans the
  zoomed picture (clamped so no black edge is dragged in).
* **Subtitles.** When a subtitle is on screen and the gesture starts on its
  band: vertical drag moves it (`sub-pos`), horizontal swipe jumps to the
  previous / next line (`sub-seek`), pinch sizes it (`sub-scale`); all saved
  like the Subtitle settings.
* **Volume boost.** If the audio booster is enabled, swiping up at 100 %
  carries on to 200 % (libmpv gain); down returns through 100 %.
* **Haptics.** A tick at the limits (0 / 100 / 200 %), on each speed step,
  and on each stacked double tap.
* **Lock.** Locked: taps only bring up the unlock button; no gesture acts.

## 5. Verified on Android (device lab, 2026-10-05)

`test_device/flows/gestures*.yaml` on Android 14 emulators, lab build of this
branch; each line is what the engine recognised (`LAB gesture …` in
`lab_trace.txt`). 0 FATAL / ANR in every run.

| Touch | Phone (pixel_6) portrait / landscape | Tablet (pixel_c) landscape / portrait |
|---|---|---|
| Drag across 40 % of the width | seek 36 s / 55 s | seek 77 s / 54 s |
| Drag up 24 % on the right | volume +0.46 / +0.40 (into the booster: 119 %) | volume +0.45 / +0.64 (142 %) |
| Drag up 24 % on the left | brightness +0.46 / +0.40 | brightness +0.45 / +0.64 |
| Double tap right / left | double tap right 1 / left 1 | same |
| Four quick taps on the right (adb) | double tap right 1, 2, 3 ("30 s" arc) | same |
| Long press | long press → speed slider, end | same |
| Tap | tap → controls | same |

Found and fixed on the way: the volume plugin showed Android's own volume
panel over every volume swipe; the stacked-tap band was a pill in portrait;
the gestures help had no Material under it (yellow-underlined text).
Two-finger speed, pinch / pan and the subtitle gestures are beyond Maestro;
they are covered by `test/player_gesture_engine_test.dart` and
`test/player_gestures_widget_test.dart`.
