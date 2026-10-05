# Screen modes, picture-in-picture, background play, sleep timer

Owner request (2026-10-05): research MX Player and the guidance from
Android and experienced developers on background play, the PiP window and
the sleep timer, then bring Innocent to that level. In particular the zoom
button next to PiP: on the owner's MX it cycles five modes — Fit to screen,
Stretch, Crop, 100%, Custom — one per tap, and MX's Crop is a zoom, not a
cut. Innocent's was not.

## 1. Research

### MX Player's screen button

| Mode | What MX does |
|---|---|
| Fit to screen | The whole frame, as large as fits; black bars where the shapes differ. |
| Stretch | Fills the screen; the film's shape is ignored (distorts). |
| Crop | Enlarges the picture, shape kept, until no bar is left. The overflow is past the screen's edge, not removed — a zoom. |
| 100% | One video pixel on one screen pixel. |
| Custom | The user's own pinch zoom (and pan). Pinching from any mode makes it Custom. |

One button, one mode per tap, the mode's name shown over the video for a
moment. MX also has separate zoom controls (width/height linked or not) and
an aspect-ratio list (1:1, 4:3, 16:9, …) — Innocent's Display → Aspect
ratio already covers the latter. Sources: MX feature descriptions
(guidingtech, nokiapoweruser, xda threads on MX zoom), the owner's MX.

### Picture-in-picture (developer.android.com, "Add videos using PiP";
Android Excellence guideline "AEP-PiP")

* Android 12+: `setAutoEnterEnabled(true)` while the video plays, so the
  system enters PiP itself as the user swipes home — smooth with gesture
  navigation, where a manual `enterPictureInPictureMode()` from
  `onUserLeaveHint` arrives after the animation has started.
* `setSourceRectHint` = the video's bounds **in window pixels**, for the
  morph animation in and out; update it when the layout changes.
* `setSeamlessResizeEnabled(false)` is for non-video content only.
* Remote actions inside the window: up to
  `getMaxNumPictureInPictureActions()` (usually 3); YouTube and MX show
  back 10 s / play-pause / forward 10 s.
* AEP-PiP: PiP on app exit; playback continues without interruption or
  pausing during the transition; the transition is fluid and immediate.
* Keep playing in PiP (pause on `onStop`, not `onPause`); hide every
  control in PiP; pause on audio-focus loss.

### Background play (developer.android.com media guides; "The decalogue of
a pro media app", AppUnite)

* A `mediaPlayback` foreground service with a MediaStyle notification and
  an active MediaSession; audio focus; pause on `ACTION_AUDIO_BECOMING_NOISY`
  (headphones out); a partial wake lock while playing.
* Android 13+: the shade's and lock screen's media controls are built from
  the **session's PlaybackState actions** (play/pause, previous, next,
  custom actions), no longer from the notification's buttons; Android 12
  and older use the notification's actions. Both need setting.
* VLC (2024): set PiP actions explicitly; some systems otherwise reuse
  another app's.

### Sleep timer (YouTube, MX, Pocket Casts)

* MX: time entry plus "finish the last media" — stop at the end of the
  film rather than mid-scene. YouTube adds "end of video".
* Pocket Casts (2024): fade the sound out before stopping, evenly in
  **decibels** (a straight fall in amplitude sounds like nothing and then a
  drop); restore the volume after the pause.
* Must keep time with the screen off (wall-clock deadline, not counted
  ticks) and release the wake lock when it stops playback.

## 2. Innocent before this work

* **Screen button**: Fit → "Zoom" → Stretch → 100%. "Zoom" set libmpv's
  `panscan`, which fills libmpv's *window* — but with media_kit that window
  is the texture, already the film's own shape, so "Zoom" drew exactly what
  Fit drew. No Custom; pinch zoom and the modes were unrelated; 100% used
  Flutter's `BoxFit.none` on a texture sized in video pixels, i.e. 2–3×
  too large on a phone.
* **Subtitles (found on the way)**: media_kit starts libmpv with
  `sub-visibility=no` unless libass is on (it is not) and draws the text
  itself in a fixed style. Every `sub-*` property Innocent set — size,
  colour, outline, shadow, background, position, scale — was accepted and
  never drawn: the Subtitle settings and the subtitle gestures changed
  nothing on screen. And the text was drawn inside the zoomed video, so
  any zoom cut it off.
* **PiP**: solid (auto-pause handling, × detection, permission check), but
  auto-enter was armed only for the in-app floating window; the full-screen
  player used the late manual path. One action (play/pause). The source
  rect hint was sent in logical pixels where Android wants physical ones
  (on a 3× phone it pointed at the top-left third of the screen). Updating
  the play/pause icon re-sent the params with auto-enter off, disarming it.
* **Background play**: foreground service, MediaSession, MediaStyle, audio
  focus, noisy-receiver — in place. Notification: play/pause and stop only;
  no ±10 s anywhere, so Android 13+ showed play/pause, previous, next.
* **Sleep timer**: MX keypad + "play last media to the end", wall-clock
  deadline, releases the service when it fires. Stops abruptly.

## 3. What changed

* `video_geometry.dart` — the five modes as one rule: lay the texture out
  whole (filled for Stretch), then scale about the centre and pan. Crop =
  the scale that covers the screen; 100% = video width / devicePixelRatio
  over the fitted width; Custom = the pinch. A pinch from any mode starts
  from what is on screen and becomes Custom; cycling back to Custom
  restores its zoom and pan; a two-finger pan works in every zoomed mode
  and never pulls a bar into view. Mode names over the video, in
  English/Burmese/Thai. `panscan` is no longer used.
* Subtitles drawn by the player (`player_subtitles.dart`) outside the
  zoom, from a `SubtitleLook` that `MediaKitPlayerService` keeps in step
  with every `sub-*` property it sets — so every existing setting and
  gesture now takes effect, with no change to their code. Placed on the
  visible part of the picture, sized from the screen: the app's sizes
  (Small 14 … Extra large 28) are dp on a phone whose shorter side is
  360 dp, scaled with the shorter side (capped at 640). The first device
  run read them as libmpv's 720-line units and drew 10 dp text; fixed.
  Burmese through the system font.
* PiP: the full-screen player keeps auto-enter armed while playing
  (disarmed when paused, private, or "leave = stop/background"), with the
  source rect in window pixels; back 10 s / play-pause / forward 10 s in
  the window; the icon update keeps auto-enter armed.
* Background play: back 10 s / play-pause / forward 10 s / stop in the
  notification (first three in the compact view) and as session custom
  actions + rewind/fast-forward for Android 13+.
* Sleep timer: the last 10 s fade out evenly in decibels (to −40 dB), then
  pause and restore the volume; cancelling mid-fade restores it too.

## 4. Verification

* Unit tests: the five modes' arithmetic, pan clamping, subtitle placement
  (on the picture, on screen when zoomed, unscaled by zoom), libmpv
  property parsing.
* Harness renders: each mode on a sideways phone with a Burmese/English
  subtitle and the mode's name.
* Device lab (`screen_modes*.yaml`): the lab film now carries a soft
  subtitle track; the flows press the screen button through all five modes
  in both orientations, then Home to check PiP is entered by itself.

### Device-lab results (Android 14 phone, 2026-10-05)

* Home while playing → the task goes `mode=pinned` by itself (auto-enter),
  the subtitle keeps drawing inside the PiP window.
* Subtitles: Burmese + English lines drawn by the player at the picture's
  bottom in both orientations, at ~20 dp on a 411 dp phone.
* The screen-mode button had no accessible name (only a tooltip), so
  TalkBack announced nothing and the lab could not find it; it is named now.

* The screen button, pressed five times on the phone held upright (run
  37281576125): the trace reads `screen crop x3.95`, `screen original
  x1.19`, `screen custom x1.00`, `screen fit x1.00`, … — one mode per press,
  in MX's order, the mode remembered per film.
* Inside the player Android's accessibility dump gives every node the
  whole screen's bounds (`[0,0][1080,2400]`), so Maestro — which taps the
  centre of a node's bounds — pressed the video instead of the button. A
  finger is hit-tested by Flutter and is not affected; the lab now presses
  the button where it is drawn. TalkBack in the player is a follow-up.
* Sideways, with the controls up, the subtitle sat on the seek bar and the
  play button; it now moves above the controls while they are shown (as
  YouTube's captions do).
