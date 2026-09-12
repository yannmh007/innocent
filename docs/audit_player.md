# Domain 2 — the Player: an audit

*12 September 2026. No code changed by this document.*

Covers the video player screen, the libmpv/media_kit service, the player
controller and its five mixins, the floating PiP window, and the background
playback service. The Music player belongs to domain 5 and is not covered
here.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## The short version, and why this audit is short

**This domain has already been audited, hard, and it shows.** README
§*v1.55.16+289 — Audit: playback races* records ten fixes from a previous
pass, including the two engine races that mattered most, fixed with a surface
generation counter and a single-flight chain. Everything I went looking for in
the resource and race categories was already handled, usually with a comment
naming the failure it answers.

Measured rather than asserted:

* **Zero `!` null-assertions** in 17,000 lines of player Dart.
* **Zero `!!`** in the Kotlin.
* **Every one of the eleven `Timer?` fields** on the controller is cancelled in
  `dispose()` (`player_provider.dart:1131–1141`), including the ones declared
  in mixins that have no `dispose` of their own.
* `player_screen.dart`'s `dispose()` wraps each step in `_step()` so one
  throw cannot abandon the rest, and snapshots every provider it will need
  **before** teardown, because reading one during dispose throws.

So the findings below are small, and four of the five are about **subtitles** —
specifically, about subtitles in Burmese. That is where this domain is thin,
and for this app's users it is the part they will meet first.

**Four candidate findings were withdrawn after checking.** They are in §2,
because the checking is the useful part.

---

## 1. Findings

Likelihood: မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).

### P1 — the subtitle encoding list has nothing for this app's audience, and the Burmese problem is not an encoding problem anyway
`settings_subtitle_screen.dart:70–81` · UX · **မကြာခဏ** · annoyance · **trivial to add, moderate to actually solve**

The Character encoding picker offers exactly these:

```
Auto detect · UTF-8 · UTF-16 · ASCII · ISO-8859-1 · Windows-1252
EUC-KR · Shift_JIS · Big5 · GB18030
```

Three Western European, one Korean, one Japanese, two Chinese. Nothing for
Burmese, Thai, or Vietnamese. The list reads as though it were copied from a
player written for East Asia.

**But adding a Burmese entry would be theatre, and that is the real finding.**
The Burmese subtitle problem is **Zawgyi**, and Zawgyi is not a byte encoding:
it is UTF-8 with Myanmar codepoints assigned different meanings. A Zawgyi
`.srt` decodes as perfectly valid UTF-8, so `sub-codepage` — which chooses how
bytes become codepoints — has nothing to fix. Setting it to anything makes no
difference.

The two things that would actually work:

1. **Detect and convert on load.** Zawgyi/Unicode detection is a solved
   problem (Google's `myanmar-tools` is the reference implementation, and the
   conversion is a finite ruleset). Convert to a temp file and hand libmpv the
   converted copy. Real work, and the only thing that fixes an existing
   Zawgyi file.
2. **Ship or point at a Zawgyi font.** Cheaper, and renders Zawgyi text
   correctly without touching the file — but then Unicode subtitles break, so
   it has to be a per-file choice, not a global one.

Neither is a small change. Recording the problem precisely is worth more than
adding `Windows-1252 (Burmese)` to a list where it would do nothing.

### P2 — the subtitle font presets are Latin-only, and whether the escape hatch works is unverified
`subtitle_text_screen.dart:47–52`, `media_kit_player_service.dart:182` · UX · **မကြာခဏ** · possibly "subtitles are boxes" · **easy — but needs a device test first**

The baseline is `sub-font: sans-serif` (`:182`), and the Font picker offers:

```
Default · Sans-serif · Serif · Monospace · Custom (enter name)…
```

On Android, `sans-serif` is Roboto, which has **no Myanmar glyphs**. Whether a
Burmese subtitle then renders correctly depends entirely on whether libass's
fontconfig inside media_kit's Android build falls back to the system's
`NotoSansMyanmar`. **I could not verify that from here, and it is the single
most valuable thing to check on a real phone in this whole domain**: if
fallback works, this finding is cosmetic; if it does not, every Burmese
subtitle in the app is a row of tofu boxes.

The escape hatch exists and is good design — "Custom (enter name)" accepts a
family name *or* a full `.ttf`/`.otf` path (`:91`). But it asks a user to
already know that their subtitles are broken because of a font, and to know
the name `Noto Sans Myanmar` or the path
`/system/fonts/NotoSansMyanmar-Regular.ttf`. Nobody knows that.

Once the device test answers the question, the fix is one entry in `fontMap`.
If fallback turns out not to work, the honest fix is to bundle a Myanmar font
and set it as the default when the app's language is Burmese.

### P3 — sidecar subtitles must match the filename exactly
`player_controller_gestures.dart:352` · UX · **မကြာခဏ** · annoyance · **easy**

```dart
final candidate = p.join(dir, '$baseName.$ext');
if (await File(candidate).exists()) { … }
```

An exact-basename match, and nothing else. So none of these are found for
`Movie.mp4`:

```
Movie.en.srt      Movie.eng.srt      Movie.mm.srt
Movie (Burmese).srt      Movie.burmese.srt      Movie_MY.srt
```

MX Player and VLC both match by **prefix** — any file in the folder whose name
starts with the video's basename and ends in a subtitle extension — which
picks up all of the above. That is the whole fix: list the directory once and
filter, instead of probing a fixed set of exact names.

**And it interacts with `docs/filename_audit.md`.** A downloaded video is named
`<80 bytes of title> [ph64a3f2c1].mp4`. A subtitle obtained anywhere else is
named after the *real* title, so the basenames can never match — the `[id]`
tag alone guarantees it. **Sidecar auto-loading is therefore impossible, by
construction, for every video Innocent downloads.** Prefix matching would not
fix that either; matching on the title with the `[id]` tag stripped would
(the stripper already exists — `library_local_datasource.dart:451`).

### P4 — the speed-slider auto-hide timer is not held anywhere
`player_controller_gestures.dart:270` · race · **ရံဖန်ရံခါ** · annoyance · **trivial**

```dart
Timer(const Duration(seconds: 2), () {
  if (mounted) state = state.copyWith(speedSliderVisible: false);
});
```

The `mounted` guard is right and means this cannot write to a disposed
notifier. What it cannot do is be cancelled. Long-press, release, long-press
again within two seconds, and the **first** release's timer hides the slider
in the middle of the second gesture.

Every other timer in this controller is a field that gets cancelled. This one
is the exception; make it `_speedSliderHideTimer` and cancel it in
`onLongPressStart` and in `dispose()` with the other eleven.

### P5 — the error log lives inside a lazy `map`, so it counts subscribers
`media_kit_player_service.dart:370–384` · silent failure · **ရှားပါး** · a latent double-report · **trivial**

```dart
Stream<String?> get errorStream => _player.stream.error.map<String?>((e) {
  …
  PlaybackLog.add('mpv error: …');
  onPlaybackError?.call(e);
  return e;
});
```

The side effects are inside the `map` callback, which runs **once per
listener**. Today there is exactly one — `player_provider.dart:763` — so the
behaviour is correct. The moment a second surface subscribes (a diagnostics
screen, the floating window wanting its own error banner), every libmpv error
is written to the trail twice and `onPlaybackError` fires twice.

It also means the logging the comment describes as its purpose — *"the moment
right before a crash is the only moment that matters"* — exists only while a
listener is attached, which the doc comment above it does acknowledge ("if
anyone is listening"). In practice the one subscriber covers the whole
playback lifetime, so this is latent rather than live.

Fix: subscribe once inside the service and log there; let `errorStream` be a
plain pass-through.

---

## 2. Withdrawn after checking

Four things that looked wrong and are not. Recorded because the next person
will notice the same shapes.

**`playerControllerProvider` is `autoDispose`, and the floating PiP overlay
appeared to only `ref.read` it.** That would mean the provider disposing out
from under a live floating window — abandoning audio focus, resetting
brightness, and clearing the crash-resume marker while a video is still
playing in the little window. It also `ref.watch`es it at
`floating_pip_overlay.dart:248` and `:308`, and both sit **after**
`if (!pip.isActive) return const SizedBox.shrink()` at `:240`. So the watch is
conditional exactly as it should be: alive while the window is up, released
when it closes. Correct as written, and the conditionality is the clever part.

**The bare `Timer` at `player_controller_gestures.dart:270`** looked like a
write to a disposed notifier. It is guarded by `mounted`. (The cancellation
gap is real — P4 — but the crash is not.)

**`PlaybackService`'s partial WakeLock is acquired with no timeout.** That is
deliberate: the comment at `:152–154` says audio can legitimately play for
hours, and it is released in three places — `ACTION_STOP`, `onDestroy`, and
`onTaskRemoved`. A timeout would be the bug.

**`player_screen.dart`'s `dispose()` appeared to cancel `_overlayTimer` and
not `_bgDetachTimer`.** `_bgDetachTimer` is cancelled at `:890`, further down
the same method.

---

## 3. What the six categories look like here

**Crash risk — as low as I have seen.** Zero `!` in the player Dart, zero `!!`
in the Kotlin, and defensive converters (`_toInt`, `media_kit_player_service.dart:1593`)
for track properties that media_kit types differently between versions. The
`buildVideoWidget` guard at `:1580` is the pattern to copy: it explains that a
`LateInitializationError` mid-build trips the global `ErrorWidget` and blanks
the whole screen, and returns a black box instead.

**Silent failure — P5 only, and it is latent.** Everything else that can fail
lands in `PlaybackLog`, which survives to a crash report.

**Race conditions — handled, and the handling is the interesting part.** The
surface generation counter plus single-flight chain from the previous audit
means whole detach/reattach transitions cannot interleave, and a write still
in flight from a superseded transition abandons itself. The open path re-checks
`_currentUri != uri` after **every** await (`player_controller_playback.dart:620`,
`:631`, and throughout), so a second file opened mid-load cannot have the first
file's settings applied on top of it. P4 is the one uncancelled timer.

**Unclosed resources — nothing found.** Eleven timers, all cancelled. Ten
stream subscriptions, all collected in `_subs` and cancelled together.
`WidgetsBindingObserver` removed on the first line of dispose, before anything
that could throw, with a comment saying why. The media_kit service tracks its
three cached-value subscriptions specifically so a re-`initialize()` after
`dispose()` cannot leak them (`:71–80`).

**Invisible waits — actively designed against.** Three separate buffering
timers (`_bufferSpinnerTimer`, `_bufferSlowTimer`, `_bufferStallTimer`) give
three escalating levels of feedback rather than one spinner, and
`network-timeout` is 5 seconds with `reconnect=1` (`:179–181`).

**UX — P1, P2 and P3, all subtitles, all Burmese.** Away from subtitles the
player's UX detail is unusually good: brightness restored on exit because
otherwise the phone stays dim on the home screen; the sleep timer driven by
wall-clock rather than a decrementing counter so it cannot drift, and skipping
its per-second state write because a 90-minute timer was rebuilding the screen
5,400 times; portrait restored on exit because only the player may rotate.

---

## 4. What is needed, nice, and not needed

### Really needed

1. **Answer P2 on a device.** Play any video with a Burmese `.srt` and look.
   Everything else about subtitles in this app is downstream of whether
   fontconfig finds a Myanmar font. Ten minutes, and it decides whether P2 is
   cosmetic or the biggest UX defect in the player.

### Nice to have

2. **P3 — prefix matching for sidecars**, plus a `_stripIdTag` pass on the
   basename so downloaded videos can find a subtitle at all.
3. **P4 — hold the speed-slider timer in a field.**
4. **P1 — write the Zawgyi problem down where the next person will find it**,
   even before deciding to solve it. The wrong fix (a codepage entry) is very
   easy to reach for.
5. **P5 — subscribe once inside the service.**

### Not needed

* **Adding Burmese to the encoding list.** It would do nothing; see P1.
* **A shorter sleep-timer tick.** The per-second `Timer.periodic` no longer
  writes state when the controls are hidden; the tick itself is cheap and the
  wall-clock deadline means a coarser interval would only add latency at the
  end.
* **Re-auditing the detach/reattach paths.** They were done properly in
  v1.55.16+289 and the generation counter is the right mechanism.
* **A timeout on the playback WakeLock.** See §2.

---

## 5. Do not touch

1. **The surface generation counter and the single-flight transition chain**
   (`media_kit_player_service.dart:35`, `:1267`, `:1388`). `Timer.cancel()` does
   not abort a callback already part-way through its awaits — that sentence is
   the whole reason this machinery exists, and it is written in the file.
2. **`dispose()` stopping playback unless the floating window is taking over**
   (`player_screen.dart:843`). libmpv's threads belong to the process, not the
   isolate; playback that outlives the screen is playback nobody owns, and the
   symptom was every video ever opened singing at once.
3. **`_step()` around each teardown action** (`player_screen.dart:811` onward),
   and `removeObserver` running first, before anything that can throw.
4. **The `_…AtTeardown` snapshots** (`_controllerAtTeardown`,
   `_pipServiceAtTeardown`, `_floatingPipActiveAtTeardown`). Reading a provider
   inside `dispose()` throws and would skip the rest.
5. **The PiP callbacks NOT being cleared when handing off to the floating
   window** (`player_screen.dart:864`) — the overlay installs its own.
6. **`buildVideoWidget`'s `_initialized` guard** (`:1580`).
7. **The `ephemeral` flag being separate from `isPrivate`** — one means "do not
   write this URL down", the other also forces a pause on every background
   transition.
8. **The floating window holding the `FLAG_SECURE` claim itself**, not the
   player screen — sending a video to the little window pops that screen.
9. **`SecureScreenService` deferring the flag drop by 300 ms** while taking it
   immediately: a hand-off would otherwise touch zero holders with protected
   content on screen.
10. **The partial WakeLock with no timeout** in `PlaybackService` (`:152`).
11. **The sleep timer skipping its state write while controls are hidden**
    (`player_controller_tracks.dart:144` onward). The deadline is wall-clock,
    so skipped writes cannot cause drift.
12. **`hr-seek: absolute` with keyframe seeking for relative jumps**, and the
    temporary drop to `hr-seek: no` during an active scrub drag.
13. **`_toInt` / the defensive track converters** (`:1593`) — media_kit types
    these differently between versions.

---

## Sources

* Read this session: `player_screen.dart`, `media_kit_player_service.dart`,
  `player_provider.dart`, `player_controller_playback.dart`,
  `player_controller_gestures.dart`, `player_controller_tracks.dart`,
  `player_controller_controls.dart`, `player_controller_navigation.dart`,
  `floating_pip_overlay.dart`, `PlaybackService.kt`,
  `settings_subtitle_screen.dart`, `subtitle_text_screen.dart`,
  `subtitle_tune_panel.dart`.
* README §*v1.55.16+289 — Audit: playback races, and a signed URL that was
  being written down*, which is the previous audit of this domain.
* The Zawgyi/Unicode distinction in P1 is stated from the encoding's own
  definition; `myanmar-tools` is named as the reference implementation but was
  **not** evaluated this session.
* Whether libass in media_kit's Android build falls back to a system Myanmar
  font (P2) is **not verified** and is the one open question this audit
  leaves.

## Changelog

* 2026-09-12 — first version. No code changed.
