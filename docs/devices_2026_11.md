# Every screen size: phone, foldable, tablet, Chromebook, TV (12 Nov 2026)

The owner's request: the app as premium on Android TV, tablets, foldables and
PC-like screens as it now is on phones; study the guidelines, comparable apps
and expert advice; plan; work systematically. This is the plan and the record.

## What a good app does on each (sources)
- **Large screens** — Google's adaptive quality tiers
  ([large-screen quality](https://developer.android.com/docs/quality-guidelines/large-screen-app-quality),
  [Tier 2](https://developer.android.com/docs/quality-guidelines/adaptive-app-quality/tier-2)):
  layouts by window size class (a rail on wide windows, multi-pane where it
  fits); bottom sheets, buttons and text fields **not full width**; 48 dp
  targets; visible focus; Tab and arrow keys; **Space plays and pauses, Esc
  leaves full screen, dialogs and Up Next**; right-click menus; hover states.
  Test sizes: 8" tablet 1024x640 dp, foldable 841x701, 13" Chromebook 1600x900.
- **Window size classes** ([source](https://developer.android.com/develop/ui/compose/layouts/adaptive/window-size-classes)):
  compact < 600 dp, medium 600–840, expanded 840–1200, large 1200–1600,
  extra-large ≥ 1600; by the window, never "is it a tablet".
- **Android 16/17**: at sw ≥ 600 dp an app targeting API 36 (17: every app)
  has its orientation, aspect-ratio and resizability restrictions ignored —
  `SystemChrome.setPreferredOrientations` included
  ([16](https://developer.android.com/about/versions/16/behavior-changes-16),
  [17](https://developer.android.com/about/versions/17/changes/ff-restrictions-ignored)).
  The player must work in any shape, unlocked.
- **TV** ([TV quality](https://developer.android.com/docs/quality-guidelines/tv-app-quality),
  [layouts](https://developer.android.com/design/ui/tv/guides/styles/layouts)):
  every function by the five-way D-pad; centre toggles play/pause, left and
  right seek, **the remote's media keys work**; Back goes home from the top;
  nothing in the **5 % overscan margins** (48 dp sides, 27 dp top and bottom
  of 960x540); video pauses when the app is left; PiP user-started only.
- Flutter: `MediaQuery.sizeOf` / `LayoutBuilder` by width, NavigationBar ↔
  NavigationRail; D-pad text entry has known focus bugs (flutter#147772).

## What already holds
Rail instead of the bottom bar at ≥ 600 dp or on TV (`shell_screen.dart`);
`DeviceProfile` (phone / tablet / TV, by sw and UI mode); a D-pad focus ring
over everything (`tv_focus.dart`); the player's remote keys (centre/Enter/
Space play-pause, ← → ±10 s, ↑ ↓ the controls); leanback launcher, TV
banner, touch not required, resizable, PiP; `TabletConstrainedWidth` on nine
screens; `test_screens/` draws every screen on tablet, foldable and TV too.

## What the photographs found (776 app screens + 80 player scenes)
1. **TV**: nothing keeps clear of the overscan margins (the top bar, the
   rail and the player's back arrow sit 0–16 dp from the edge).
2. **Remote media keys**: Play/Pause, Fast-forward, Rewind, Next, Previous
   on a TV remote or a Bluetooth keyboard do nothing in the player (TV-PP).
   No Esc, no keyboard shortcuts beyond Space and arrows; the mouse does not
   wake the controls, the pointer never hides, no right-click menu.
3. **~40 list and form screens run the full width** of a tablet or
   Chromebook (settings pages, transfer, downloads, pay, account, ADB,
   hidden files, network, backup, help…): a switch 1200 dp from its label.
4. **The player's upright sheets are full width** on a tablet: ⋮'s four
   columns 200 dp apart.
5. Phone-only harness for the player: now `PLAYER_PHONES=large|all`.

## Plan
**Phase 1 — this session**
1. TV safe area: on a TV the whole app sees the overscan margins as system
   insets (the picture itself still fills the screen).
2. Player input: media keys (play/pause, play, pause, ⏩ ⏪ ⏭ ⏮, stop), Esc,
   K/J/L, M (mute), comma/period (a frame), [ ] (speed), ? (the list of
   keys); the mouse shows the controls, hides the pointer with them, and a
   right-click opens ⋮.
3. Readable width (840 dp) on every list and form screen.
4. Player sheets upright: no wider than 640 dp, centred.
5. Prove: harness on all sizes, controls tests for the keys, lab.

**Phase 2 — next**
- Two panes where they fit (Settings: list + page on expanded; Video tab:
  folders + files); grids that add columns with width.
- targetSdk 36 readiness: the player unlocked (rotation and resize keep the
  film and its state), predictive back, edge-to-edge, Myanmar text.
- TV: a search field that the D-pad can enter (flutter#147772), a 10-foot
  type scale check, frame-rate matching, MediaSession voice commands.
- Hover states on custom tiles; Ctrl + scroll zoom in the picture viewer.

**Phase 3 — the owner decides**: a Windows/macOS app. The app is Android
only today (the `ios/`, `web/` folders are Flutter's templates); "PC" is
served by ChromeOS and Android's desktop windows, which Phase 1–2 cover.

## Phase 1 — done (12 Nov, session branch)
1. `core/ui/tv_safe_area.dart`: on a TV the app sees 5 % margins as insets
   (48/27 dp on 960x540); the film still fills the screen. Test:
   `test/tv_safe_area_test.dart`.
2. The player answers a remote's and a keyboard's keys wherever focus is:
   ⏯ (and K), ▶, ⏸/■, ⏩ ⏪ (and L J, held: repeats), ⏭ ⏮ (next/previous
   video), M (sound, with a toast), comma/full stop (a frame), [ ] (speed
   ±0.25, with a toast), ☰ (⋮), Esc (closes a menu, then leaves, honouring
   "double-tap Back"), ? (the list of keys). A mouse: moving it shows the
   controls, the pointer hides with them, a right-click opens ⋮. Tests in
   `player_controls_test.dart`.
3. 25 list and form screens capped at 840 dp, centred
   (`TabletConstrainedWidth`): every settings page, Transfer, Downloads,
   Pay, Account, Help, Statistics, Backup, Network, Data saver, a folder's
   files, Theme, ADB, Hidden files, Folder visibility.
4. The player's upright panels no wider than 640 dp, centred.
5. `PLAYER_PHONES=large|all` photographs the player on an 8" tablet
   (800x1280), a foldable (701x841), a Chromebook window (1600x900) and a
   TV (960x540): no overflow; the test_screens harness on tablet, foldable
   and TV: no overflow (776 photographs).
Whole suite 1696, tool/check.py clean.
