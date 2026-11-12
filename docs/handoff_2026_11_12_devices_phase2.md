# Handoff: the player redesign and every screen size → Phase 2

Paste everything below the line into a new chat, as the first message.
(The owner's prompt, written by the 12 Nov 2026 session. The repository is
public: nothing here is secret.)

---

ဒီ chat မှာ Innocent app ရဲ့ "device မျိုးစုံ (TV, tablet, foldable,
Chromebook/PC)" အလုပ်ကို **Phase 2** ကနေ ဆက်လုပ်ပေးပါ။ အရင် session ရဲ့
ဆုံးဖြတ်ချက်တွေနဲ့ အခြေအနေ အပြည့်အစုံ အောက်မှာ ရှိပါတယ်။ ဖတ်ပြီးမှ စပါ။

## 0. Before anything
1. Read `CLAUDE.md`, `docs/BACKLOG.md` §0, `docs/devices_2026_11.md` (the
   study, the plan, Phase 1's record), the skill `ui-design`
   (`.claude/skills/ui-design/SKILL.md`) and `.claude/rules/flutter-app.md`.
2. Fetch the work branch `claude/extract-github-release-oteqr5`: it holds
   everything not yet live, this work included (head da33c1bd on 12 Nov, or
   later). Work on top of it; push to it fast-forward, with `[skip ci]` in
   the message when the push touches nothing a lab of yours needs (another
   session runs its own labs from that branch — a push to `test_device/`
   there restarts its device lab).
3. Install Flutter 3.32.8 as the rules say; `flutter pub get --offline`.

## 1. Where things stand (12 Nov 2026)
- **main = 1.64.83 (396)**, released 12 Nov: the player redesign (one UI
  kit, `lib/features/player/presentation/widgets/player_ui.dart`), the
  engine judged by the film's clock (no false "The player stopped
  responding" on a file that plays), and the bugs found on the way (after
  Next the screen acted on the first film; the real Playing queue; signed
  addresses scrubbed from errors; bookmark guards). Build 43186533253,
  app_releases moved 09:19 UTC.
- **On the work branch, NOT released** (from session branch
  `claude/focused-johnson-1915dp`, ported with `[skip ci]`):
  1. `9a4f531a` app screens audit: the downloader's tab font, `MxDialog`
     (information dialogs) on the new tokens, the Up next card.
  2. `a74047a6` **frosted glass** for every player menu (`PlayerGlass`:
     the film blurred σ30 under a 72 % `#1C1C1E` tint, a white 12 % edge,
     scrim 40 %; opaque `#1C1C1E` on Android Go / 32-bit-only phones via
     `PlayerUi.probeGlass`); the upright sheet stops at 55 %; **sideways
     every player sheet is a full-height side panel from the right**
     (`showPlayerSheet` → `_PlayerSideSheet`), like ⋮ and CC.
  3. `851dce81` **devices Phase 1**: `core/ui/tv_safe_area.dart` (TV
     overscan 5 % as insets); the player's remote and keyboard keys
     (`_keyAnywhere` in player_screen.dart: ⏯/K, ▶, ⏸/■, ⏩⏪/L J, ⏭⏮,
     M, `, .`, `[ ]`, ☰, Esc, `?` key list); mouse: hover shows the
     controls, the pointer hides with them, right-click opens ⋮; 25 list
     and form screens capped at 840 dp (`TabletConstrainedWidth`); upright
     player panels ≤ 640 dp, centred.
  - `d61b7a28` (the picture rising above the menu) was **superseded** by
    the glass (the owner chose glass over moving the picture); its code is
    gone.
- The work branch also carries **another session's unreleased streaming
  work** (5d keepSpare, the play_summary stash; its "1.64.83 candidate"
  b3e2bad1). Since 1.64.83 went out as the player release, **the next
  release is 1.64.84** and carries both. The owner decided (12 Nov): the
  UI work above ships with that next release, not separately.

## 2. The owner's decisions and standards (keep them)
- Premium and calm like MX Player, "never a toy a child has been poking
  at"; global-grade; thorough over fast; findings beyond the question are
  reported and fixed where safe.
- One layer at a time: the controls hide under any menu; menus are
  **frosted glass**; the picture never moves.
- Prove every UI change with photographs and send the owner before/after
  sheets (ImageMagick `montage`); iterate until right.
- Reply in Burmese, technical terms in English; numbered steps when the
  owner has something to do.

## 3. Tools you will need
- Player photographs: `PLAYER_SHOTS=<dir> flutter test
  test/player_layout_test.dart` with `SCENES=…`, `LANGS=my,en,th`,
  `SCALES=1.0,1.3`, and **`PLAYER_PHONES=large|all`** (8" tablet 800x1280,
  foldable 701x841, Chromebook window 900x1600 @1.25, TV 540x960). A
  panel animates in 220 ms: in a widget test pump several frames
  (`_settle`), never one long pump.
- App screens: `test_screens/` (107 screens). Fonts: copy the SDK's
  `bin/cache/artifacts/material_fonts/Roboto-*.ttf` and
  `MaterialIcons-Regular.otf` into `build/screen_fonts/`, and
  `test/fonts/NotoSansMyanmar.ttf` there as `NotoSansMyanmar-400.ttf` and
  `-700.ttf`; then `SCREEN_LOCALE=my|en SCREEN_PHONES=small,large,tiny,
  tablet,tablet_land,fold,tv flutter test test_screens --update-goldens`
  (pictures in `test_screens/out/`, a `PROBLEM` line per layout error).
- Labs: skill `device-labs`; the four player flows
  (`layout_portrait player_audit layout_landscape player_audit_land`)
  passed on the glass build (run 43223540264). `remote_nav.yaml` exists
  for D-pad navigation. Lab screenshots are sealed; read
  `ui_after_*.xml`, `maestro_*.txt`, `logcat.txt`.

## 4. Phase 2 — the plan (docs/devices_2026_11.md)
Do these in order; photograph and verify each; record in BACKLOG §0.
1. **Two panes on expanded widths (≥ 840 dp)**: Settings as list + page
   (the list keeps the selection; the page opens in the right pane);
   the Video tab as folders + that folder's files; grids that add columns
   with width (Movies/Hub rails already use the width). Phones unchanged.
2. **targetSdk 36 readiness** (Android 16 ignores orientation locks at
   sw ≥ 600 dp for apps targeting 36; Android 17 for every app):
   - the player works with `SystemChrome.setPreferredOrientations`
     ignored: a resize or rotation keeps the film, its position, the open
     panel's state; the controls lay out by the window, not by
     "landscape";
   - predictive back (`KEYCODE_BACK` no longer dispatched at 36): Back
     through `PopScope` still closes a panel first, then the film;
   - edge-to-edge cannot be opted out; `elegantTextHeight` is ignored —
     re-check Burmese line heights in the harness;
   - do NOT raise targetSdk yet unless the owner agrees: write what it
     would take and test the behaviour with the locks off.
3. **TV**:
   - the search field by D-pad (flutter#147772: TextField focus on TV);
     prove with the lab's `remote_nav` flow or a new one;
   - a 10-foot check: text and targets at 960x540 readable from a sofa
     (the Movies hub, detail, player controls); the focus ring on every
     custom widget;
   - frame-rate matching for film (24/25/30 fps) if the engines allow it;
   - MediaSession voice commands (play, pause, seek) — read
     `player_provider.dart`'s session first.
4. **Mouse and keyboard polish**: hover states on custom tiles (Material
   InkWell has them; check `RemoteTappable`/GestureDetector tiles); a
   right-click menu on list items where long-press opens one; Ctrl+scroll
   zoom in the picture viewer; Tab order on forms.
5. **Leftovers seen on the way**: the gestures help overlay keeps its own
   look; the Folders title is cut to "Folder မ…" on a 320 dp phone by
   its four actions; the downloader's Burmese paste hint sits a little
   high; a test that drives the 750 ms engine check with a fake wedged
   engine; Gesture/`GestureOverlay` mouse wheel (volume?) — decide.
6. Then the release (skill `release`) of the work branch as 1.64.84,
   coordinated with the other session's streaming work and its labs.

## 5. Mistakes made last time — do not repeat
- `dart format` on a list of files rewrote thousands of untouched lines;
  format only what you wrote (`.claude/rules/flutter-app.md`).
- A bare `TextStyle` as a ButtonStyle `textStyle` or a TabBar
  `labelStyle` drops the theme's Roboto and the Burmese fallback — start
  from `Theme.of(context).textTheme.labelLarge?.copyWith(...)`.
- `tool/security_invariants.py` matches
  `Positioned.fill(child: _accountMarkLayer` literally: keep that call
  shape in player_screen.dart.
- A regex edit across a YAML flow swallowed the whole file once; edit by
  exact anchors and look at the diff.
- In Maestro, `optional: true` goes inside the command's map, and
  `waitForAnimationToEnd` returns at once on a still screen (two taps in a
  row become a double tap); wait with `extendedWaitUntil` on a text that
  never comes.

## 6. What the owner still has to do (remind once)
- Update a phone to **1.64.83** and say whether ⋮, CC and the error card
  look right; and whether "stopped responding" ever shows on a file that
  plays.
- After 1.64.84: open ⋮ while a film plays and say if the film stutters
  under the glass (if it does: lower `PlayerUi.glassBlur` or widen the
  opaque fallback).
- The DNSSEC "Active" screenshot (BACKLOG §0).

Start by reading section 0's files, then tell me (in Burmese) your plan for
Phase 2 item 1 and the photographs you will take, and begin.
