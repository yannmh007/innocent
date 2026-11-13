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
- **Android 16/17**: at sw ≥ 600 dp an app targeting API 36 has its
  orientation, aspect-ratio and resizability restrictions ignored —
  `SystemChrome.setPreferredOrientations` included (Android 17: apps
  targeting 37, the temporary opt-out gone; not every app, as this said
  until 13 Nov — docs/target_sdk_36.md)
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

## Phase 2 item 1 — done (12 Nov, on the work branch)
1. `core/ui/list_detail.dart`: two panes from 840 dp of WINDOW (Material's
   expanded class; 839 is one pane, tested): the list pane 36 % of the
   width, 360–400 dp (at 320 the Video tab's title gave way to its four
   buttons), a white-10 % hairline, the page in the rest; left and right
   insets kept (a TV's margins). The open row: accent 16 %, radius 14,
   inset 8 dp. `DetailNavigator`: the pane's own navigator (a page opened
   from the page opens in the pane; Back — system, remote, predictive —
   closes it first through `NavigatorPopHandler`), its own semantics
   container (a navigator's ModalBarrier hid the list from TalkBack, as it
   once hid the rail), new for each page (no lingering inner page).
2. Settings: the list beside the open page (the first until one is
   chosen); the open row tapped again goes back to its page's top. A
   window narrowed to one pane opens the chosen page over the list; a
   widened one keeps a page opened over the list on top until Back.
3. The Video tab, folders view: the folders as rows (a grid choice is the
   videos'), beside them the open folder (`FolderDetailScreen(embedded)`:
   no back, no search of its own, the list's black). One search filters
   both; a folder left out by a search hands the pane to the first result
   and comes back when it clears. A selection of the videos is the pane's
   (its bars; Back and another folder clear it). Narrowed to one pane, the
   folder the person opened opens over the list — unless anything is over
   the tab (the player: a foldable folded mid-film).
4. Grids by width (`Responsive.gridColumns`): catalogue posters
   (`PosterMetrics.gridColumnsFor`: 3 on a phone, a poster ≤ 170 dp —
   4 upright, 5 on a TV, 7–8 sideways), Status Saver, Private Folder, the
   picker's images. The folder and video grids already sized by cell.
5. Found on the way (fixed): settings dialogs closed through the page's
   context; Back left the Video tab's query behind; a folder found by its
   name showed "No video matches"; a folder's search filtered the list
   behind it; the TV title 48 dp in; the downloader at full width; the
   Folders title on a 320 dp phone; a search that took the open folder
   away left its videos selected. Harness: `fold_land` (841x673) and
   `chromebook` (1280x720 @1.25) sizes; a TV is drawn with its margins.
6. Proof: `test/list_detail_test.dart` (8), `test/video_tab_two_pane_test.dart`
   (8, each fix's test seen to fail without it), `test/responsive_grid_test.dart`
   (3); whole suite 1723; the harness on tablet_land, fold_land,
   chromebook, tv, small, tiny in my/en and 1.3: no overflow.
7. 13 Nov: the 20 list and form screens Phase 1 had left at full width
   capped at 840 (`TabletConstrainedWidth`; list in BACKLOG §0), photographed
   with a week of user data (`test_screens/lists_screens_test.dart`). Watch
   insights, never photographed before: its week chart overflowed on every
   phone, its day labels were English shorthand, its total ignored the
   app's font — fixed.

## Phase 2 item 2 — targetSdk 36 readiness (13 Nov): docs/target_sdk_36.md
Not raised (the owner decides). What changes at 36 and Innocent's state,
each with its source; how to raise and prove it (`am compat enable
UNIVERSAL_RESIZABLE_BY_DEFAULT` on a debuggable build, Android 16 tablet
emulator). Done now: the player's sheets follow the window while open (they
chose their form once: a phone turned under one left a 300 dp bottom sheet
sideways; now one route, the content's state kept, pixel-identical at rest
in all 51 sheet photographs); tests that the film, its place and an open
menu survive turns and a tablet-window resize unlocked, and that an upright
sheet drags down to close; the two WebView activities keep their history
Back at 36 (`enableOnBackInvokedCallback="false"`). Left: hide the rotate
button where Android 16 ignores it; an API 36 lab job; a foldable that
starts folded stays a "phone" (DeviceProfile decides once).

## Phase 2 item 3 — TV, first part (13 Nov)
1. **The D-pad leaves a text field** (`DpadLeavesTextFields`, tv_focus.dart,
   once above the navigator in app.dart). Probed on Flutter 3.32.8: a
   focused single-line field kept ↓ ↑ ← → for its caret and focus never
   left it — on a TV the search field (it opens focused) held the remote
   for good (flutter#147772's family). Now ↑ ↓ move focus out of any
   single-line field; on a TV ← → too from the field's ends; a multi-line
   field keeps its arrows. `test/dpad_text_field_test.dart` (6).
2. **Back from a pane by D-pad** (Settings, the Video tab on two panes):
   with focus in the page or the folder's videos, Back goes to the list's
   open row first (Android TV: Back steps out of a pane, then out of the
   screen); by touch Back leaves at once, as before. Settings' pane holds
   it with a PopScope on its root page, which its NavigatorPopHandler
   counts (`routeBlocksPop`); the Video tab through the shell's tab Back.
   Tests in both files, D-pad and touch.
3. **Overscan audit, every screen** (190 TV photographs, the side margins
   measured for bright ink): fixed a film's page (its words 14 dp from the
   edge; the picture still bleeds), the saved posters, the catalogue's
   See all and search grids, the Status Saver, Private Folder and its
   picker (`SafeGridWidth`), and the shell's right side (the tabs' lists ran
   their ⋮ and sizes into it: the page now keeps clear of the right inset
   as the rail does of the left). Left in the margins, rightly: the film,
   full-screen photos. Phones and tablets pixel-identical but the two-pane
   hairline, now over the Video tab's own black.
Left in item 3: the 10-foot type scale (text is the phone's sp; on a TV
from a sofa the 11–12 sp captions are small — a TV text scale is the
question for the owner), focus rings on custom tiles (RemoteTappable is
there; GestureDetector tiles to sweep), frame-rate matching, MediaSession
voice commands.

## Phase 2 item 4 — mouse and keyboard (13 Nov, first part)
- Right-click: a video's row or tile opens its menu (as ⋮); a folder's
  row or tile selects it (as a long press). Test: "a mouse: right-click".
- The mouse wheel already zooms a photo (InteractiveViewer, probed: one
  notch 1.8×, paging locked while zoomed) — no change.
- Hover: every InkWell target has Material's hover; the tap targets built
  as a 48 dp GestureDetector around a smaller InkWell keep the InkWell's
  focus and hover. `RemoteTappable` (24 uses) draws no hover of its own —
  left, as each such tile has its own look.

## The owner's three choices, done (13 Nov)
- **targetSdk 36** (docs/target_sdk_36.md): raised; where Android ignores
  an orientation request (a TV; a tablet on Android 16) the player's
  rotate shortcut and its orientation settings are not offered
  (`DeviceProfile.orientationFixed`; the TV's rotate button did nothing
  before, too). `test/orientation_fixed_test.dart`.
- **A media session for every film** (`PlayerMediaSession.kt`): the only
  session was background play's, so in ordinary playback a TV's voice
  commands and Now Playing card never reached the film. Now one for as
  long as the player is open — no notification; its commands come back
  the way the notification's do (`onPlaybackAction`); pushed on a change
  of state or a jump, never on every tick; never for a Private Folder
  film. A media key with the app in front still reaches the activity
  first, so a headset behaves as before. Test: "a film has a media
  session…".
- **TV text at 1.2** (`TvSafeArea.textFactor`, on top of the TV's own
  setting): every screen photographed on a TV at it in Burmese and
  English — one overflow, the network help's steps (now they scroll); the
  player on a TV with its margins (the player harness now draws a TV as
  the app does): 472 layouts at 1.0 and 118 at 1.3, none overflowing.

## Phase 2 item 5 — leftovers (13 Nov)
- **The engine check has a test that drives it** ("a call to the engine
  hangs", `test/player_controls_test.dart`): a fake engine hangs on
  purpose (`SlowEngine`, engine_check.dart — the check ran only for
  `MediaKitPlayerService` before), and the test's clock runs the 750 ms
  looks: a film standing still is stuck at 3 s and said plainly, the card
  goes when the call answers; a film playing on is never called stuck and
  gets one new link at 15 s, never a second; paused waits 8 s. The loop
  now times itself by `Timer.tick` (the periods that passed, a late
  callback's included), which a test's clock moves and `DateTime.now()`
  did not.
- **Found by it, fixed: a stream that resumed during a hang was called
  stuck.** Waiting for data counts as paused; when the data came, the
  next look measured the film from when the call began to hang — more
  than 3 s — and a film that had played for under 400 ms of it was
  "stuck". Now a film meant to move again gets its own three seconds from
  that look. Both rules proved by breaking them (the test fails each way).

