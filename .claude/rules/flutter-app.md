---
paths:
  - "lib/**"
  - "test/**"
  - "android/**"
---

# The app

- **Every user-facing string in three languages**: a key in each of `_en`,
  `_my`, `_th` in `lib/core/localization/app_strings.dart`, read through
  `AppStrings`. `tool/check.py` (ui_literals, verify) fails a bare literal
  or a missing key.
- **A screen, menu, sheet or dialog changes: skill `ui-design` first.**
  The player's menus are built from `widgets/player_ui.dart`; a new one
  that draws its own surface, rows or buttons is how "a toy" happened.
- **Flutter is 3.32.8** (CI). Not there: `RadioGroup` (use `RadioListTile`
  with `groupValue`). Use `withValues(alpha:)`, not `withOpacity`. Lints are
  strict: `prefer_const` and friends.
- **Flutter is not preinstalled, but installs here in ~2 min** (the CI
  version, from storage.googleapis.com, which the sandbox reaches):
  `cd /root && curl -sSO https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.32.8-stable.tar.xz && tar -xf flutter_linux_3.32.8-stable.tar.xz && rm flutter_linux_3.32.8-stable.tar.xz && git config --global --add safe.directory /root/flutter`.
  Then `~/flutter/bin/flutter analyze` and `flutter test` (whole suite
  ~4.5 min) run locally; `git checkout pubspec.lock` after. CI (`build.yml`
  dispatched on the branch, publishes nothing off main) stays the record.
- **A test that fails only in CI is timing, not luck:** rerun it here with
  the CPU and disk loaded (busy loops plus a `dd … conv=fsync` loop) and
  count the event with a temporary print. That found the lost read-ahead
  of 6 Nov (stream_cache_hls_test: a read starting while the last one's
  writer was closing got no writer).
  Do it BEFORE the first push for a new test that waits on sockets or
  timers: the lost-pool test (14 Nov) passed here idle, failed Stream
  bench 43560088035, and failed 2 of 5 here under that load (the other
  rung's index read reordered the pools; it now waits for the Worker to
  go quiet).
- **A box sized for Latin text cuts Burmese.** Android draws Burmese in the
  tall Noto Sans Myanmar: a line is nearly twice a Latin one. No fixed
  height (or `height:` under 1.5) around text that can be Burmese or Thai;
  let the row grow or measure it (`TextPainter`), and let text in a Row be
  `Flexible`. A sheet whose content can grow: `isScrollControlled: true`,
  `constraints: tallSheetConstraints(context)`, a scrolling body (sideways
  the default sheet is ~200 dp). Why: the 11 Nov player audit found a dozen
  such cuts (docs/player_ux_audit_2026_11.md). Check a player change with
  `test/player_layout_test.dart` (real fonts: `FONT_DIR`, see the doc) —
  320/360/411 dp, both orientations, `LANGS=my,en,th`, `SCALES=1.0,1.3`.
- **`flutter analyze` with no path before a push.** CI's Analyze (Stream
  bench, the Build) reads the whole project, `test_screens/` too, which
  neither `flutter test` nor `flutter analyze lib/` reach: a parameter
  removed from ShortcutRow broke test_screens/player_row_screens_test.dart
  and failed Stream bench 45796876440 (26 Nov 2026). Errors only matter;
  the ~180 infos are known.
- **A widget's helpers that do not need `context` go outside the class.**
  tool/context_scope.py (in check.py) read `context` in SpeedCard's build
  as "the enclosing class has none" when an expression-bodied method
  (`double _snap(double v) => …`) came before build, and the push gate
  stopped (26 Nov 2026). A top-level function passes.
- **A row's overflow is found with the real fonts, not the test font.**
  player_controls_test draws every glyph a full em wide (its Quality pill
  measured 189 dp, not ~108), so a width check there fails for nothing and
  a real overflow can pass: the 1.64.89 review found ⋮ running off the
  upright top bar on 360/412 dp phones with the Quality pill, which no
  test had shown. Put a layout case in test/player_layout_test.dart (real
  fonts, every phone, my/en/th, 1.0/1.3) and assert the control's rect is
  on screen — `findsOneWidget` passes for a widget drawn off screen.
- **`dart format` only the files you changed.** Formatting a directory
  rewrote eighteen untouched player widgets (12 Nov): noise in the diff and
  the release review. Name the files. And not a changed file that HEAD
  never formatted: `media_kit_player_service.dart` and `player_provider.dart`
  are not (14 Nov: formatting them rewrote ~500 untouched lines). Check
  first — `git show HEAD:f > /tmp/x.dart; dart format -o none
  --set-exit-if-changed /tmp/x.dart` — and if it would change, format only
  your new files and lay out your own lines by hand.
- **A dialog closes through ITS context.** `showDialog(builder: (_) => …
  Navigator.of(context).pop())` pops the navigator the PAGE is in: on the
  root one that happened to be the dialog; in a pane's own navigator
  (Settings on a wide window, list_detail.dart) it closed the page and the
  pane went blank (`_history.isNotEmpty`, 12 Nov). Name the builder's
  context (`dialogContext`) and pop with it.
- **Whatever opens a session must close it on every path.** A seek-bar
  drag or a swipe opens a scrub (`beginScrub`), which on the ladder puts
  ExoPlayer in scrubbing mode — playWhenReady true, playback suppressed.
  The bar sits in `if (_chromeUp(state))`, so the auto-hide took it out of
  the tree under a still thumb, its onChangeEnd never came, and the owner's
  Sintel "played" without moving, play/pause dead (14 Nov,
  test/player_scrub_test.dart). A widget that opens one ends it in
  `dispose`; a timer that removes UI checks it first; a guard on the end
  (a lock) never refuses what the start let through.
- **A Tooltip takes the long press.** A GestureDetector(onLongPress) around a
  tooltip'd IconButton never fires (Next's repeat menu, 11 Nov): drop the
  tooltip and name the button with `Semantics(label:, onLongPress:)`.
- **Lab-only code stays behind `INNOCENT_LAB`** and is never shipped
  (skill `release` lists it). `MEDIA_SEAL` is a dart-define; the release
  build leaves it unset.
- **What the app tells users about data matches what it does.** It sends
  usage events (`record_events`), playback requests, account data when
  signed in, crash reports when SENTRY_DSN is set. A change to any data
  flow checks the Privacy text (`privacyBody`, three languages) in the same
  change. Why: on 7 Nov it still said "runs entirely offline, sends
  nothing".
- **"No events" is not "no problem" until the path that sends them is
  read.** Ladder (ExoPlayer) stalls were never sent (`_measureStall`
  returned early off libmpv), so `play_stall` went quiet after 24 Oct and
  looked like smoothness (7 Nov). Playback telemetry must cover both
  engines; `play_summary` (PlaybackQoe) is the per-playback truth, and a
  new playback event kind needs its row in `event_kinds` (migration 080).
- **"Signed out after an update" is not the update until the auth logs
  say so.** The session lives in the Keystore (SessionStore) and an update
  keeps it. Supabase Auth DELETES every session of an account below aal2
  each time that account completes MFA anywhere (the auth server's
  mfa.go, InvalidateSessionsWithAALLessThan; no setting turns it off): the
  owner's console sign-in is Google + MFA, so it ends the phone app's
  Google session (aal1), and the app's next refresh is refused (400). Why:
  14 Nov 2026, MFA 08:11:53 UTC, the app's refresh refused 08:16:20, the
  owner asked to sign in again "after the update" (found 21 Nov from
  edge_logs: `/auth/v1/token grant_type=refresh_token` 400 from Dart). How:
  read edge_logs for the account's `/auth/v1/*` around the moment (a
  refresh attempt means the stored session survived); the app now renews
  a refused Google session of an account WITH MFA once without a tap, the
  same user or none (ApiAccountRepository._renewRefused,
  test/google_session_renewal_test.dart), never one the viewer ended, and
  never an account without MFA: its refusal can be a deletion elsewhere,
  and an ID-token exchange then signs up a new account (the release
  review's blocking finding, 21 Nov). A SESSION CAN DIE WHILE ITS TOKEN
  LIVES: within the access token's hour, /auth/v1/user answers 403
  `session_not_found`, not 401, and the refresh is never asked unless that
  403 counts as stale (ApiClient._isStaleToken). 1.64.87 handled only the
  expired-token shape of 14 Nov, and the owner's test the same evening
  (MFA 18:16:19 UTC, /user 403 from 18:16:45) still showed "Sign in". Test
  every shape the server answers, not the one the logs showed first. And
  read the WHOLE /auth/v1 trail, not only the cause you expect: that
  evening the console's Sign out had gone first, `logout?scope=global`
  (18:15:32) — supabase-js signs out every session by default, idle
  timeout included. The console now signs out `scope: 'local'`
  (docs/studio/shell.js, checked by console_smoke.mjs). An Auth outage
  during a refresh is a retry, never a sign-out (ApiClient._send throws
  `network` while the tokens are kept), for EVERY caller: a request that
  joins a refresh in flight gets that refresh's answer, not "a token is
  still stored" (the release review's finding, 21 Nov: two requests at a
  start, the second signed the user out). Test two callers at once.
- No owner name, location or personal contact in the app (the takedown
  address is the one public contact).
