---
paths:
  - "test_device/ref/**"
  - "tool/ref/**"
  - ".github/workflows/reference-lab.yml"
---

# Reference lab (MX beside Innocent) — what the runs of 22 Nov 2026 taught

The plan and the owner's rules: BACKLOG §0 "Reference lab", skill
`ui-design` §4. MX's files, screens and dumps go to innocent-ref only; this
repository and a run's public log carry numbers and our own code.

- **MX's tree comes from `dumpsys activity top`, not uiautomator.**
  uiautomator times out (10 s, "could not get idle state") on MX's player,
  playing or paused. `dumpsys activity top` lists EVERY task, the
  launcher's first: read the hierarchy under `ACTIVITY <package>/`
  (ui.py hier). It shows no translations: a row slid into place reads
  where it was laid out (MX's shortcut row read as its top bar) — find
  toolbar buttons through the AndroidX ActionMenuView that holds them.
- **Open MX's player by name.** `-p` brings Android's chooser (MX has a
  PiP twin); take the first non-pop-up activity in query order. MX needs
  All files access (`appops set --uid … MANAGE_EXTERNAL_STORAGE allow`) or
  shows its own storage screen.
- **Let each app turn itself upright** (an upright 9:16 film).
  `wm set-fix-to-user-rotation` forcing MX upright squeezed its controls
  into a band — not what a phone shows. Sideways, holding the rotation is
  fine (MX turns a wide film sideways anyway). Read the screen's way from
  a screenshot's PNG size: the input's SurfaceOrientation read 0 sideways.
- **Pause before reading a tree.** Paused, both apps keep their controls
  up once shown; playing, Innocent's hide after 4 s, sooner than its tree
  is read. A tap on the picture HIDES controls that are up: check the tree
  before tapping. Wait for a panel in the tree before taking its screen
  (MX's ⋮ came seconds late under translation).
- **Innocent on the API 30 image decodes in software** (the lab sets the
  Development switch in its preferences): libmpv stalled on the goldfish
  H.264 decoder and the player gave up. Its accessibility root there
  stops 96 dp short of the screen (BACKLOG §0): ⋮ sideways is not in its
  tree. Its glass is read off its own white-frame screenshot.
- **A helper that fails behind `|| echo 0` hides its own absence.** An
  edit dropped ui.py's `added()` and every panel check read 0 for a whole
  run (44999637142). After editing ui.py, call each subcommand once on a
  saved tree before pushing.
- **A panel is its container, nothing around it.** The first Phase 1
  table read MX's upright panels as 55 % (they are 46.6 %) and its ♪
  sideways as 44 % (46.6 %): it took in MX's subtitle view, which MX moves
  up above an open panel, and a list running past the screen. measure.py
  now clips to the screen and takes the added node holding the most others
  wholly. Check a table's numbers against the trees before they go to the
  owner (22 Nov: one decision was taken on the wrong figure).
- **Read Innocent's shade where content cannot fool it.** Content only
  lowers the see-through (white words read the same over both frames,
  tile discs are darker), so the shade's level is the upper part of a
  line, not its median: run 45775539414 read ⋮ sideways as 10.9 % wide
  once its title went and its tiles reached the line. measure.py reads
  three lines and keeps the edge farthest out. After a layout change,
  check the panel figures against the screenshots before they go out.
- **MX shows no subtitle until its font cache is built.** Its player puts a
  "Building font cache…" prompt at its foot (FontCachePromptBasePromotionView
  in `dumpsys activity top`) and draws no subtitle meanwhile. Under ARM
  translation that outlasted a 25 s warm-up, and every force-stop started
  it again: run 45781933354 has no MX subtitle on any screen. probe.sh
  `warm_mx` waits for the prompt to go (up to 6 min, the film reopened if
  it ends); check its line in the summary before reading a subtitle's place.
  It never went in 6 min (run 45796876490). What works: MX's copy of the
  film carries a same-named .srt (probe.sh), and MX draws that without the
  cache (run 45805693393).
- **The controls screen in numbers: `python3 -I tool/ref/controls.py
  <run dir>`** — each control's centre and size in dp, MX's found by its
  view id (toolbar, audio, caption, decoder, screen_shortcut_list,
  progressBar, posText, lock, prev, playpause, next, zb_left, zb_right),
  Innocent's by its English TalkBack label; never by place. Innocent's
  upright bottom row and sideways ⋮ are missing on the API 30 image (its
  root stops 96 dp short there; API 34 and 36 reach the whole screen).
- **Innocent's ⋮ tiles read clickable="false" in uiautomator** (run
  45885319037; its switch rows read true): `ui.py tiles`/`grid` never see
  them. Find one by its English label: `ui.py labelled <dump> '^Audio
  track'`.
- **controls.py's "shortcut 1/2" pair MX's first slots with Innocent's
  "Speed" and "Screenshot"**: Innocent's open row starts with EQ, so x reads
  +59.7 (one slot) when the places are equal; the pitch row is the check.
- **The lab's dp are the owner's dp.** The emulator is 1080x2316 at 450 dpi
  (2.8125), as the owner's phone at its default zoom: 384x823 dp, a 48 dp
  navigation bar. Figures taken off the owner's own screenshots before
  26 Nov were divided by 2.625 and read ~7 % large (player_screen.dart's
  "MX GEOMETRY"); measure MX's controls here, not off those.
- **A bare `wait` in probe.sh waits for the logcat reader too** (started in
  setup_device, never ends): run 46051981906 sat to the job's 80-minute
  limit. Wait for the PIDs you started (`wait "$pid"`).
- **MX's subtitle gestures, measured (28 Nov 2026, SCREENS=subgest; runs
  46047544023, 46049383870, 46050792610):** one line a swipe, however
  long, on the finger's lift; right to left the next, left to right the
  previous; 70 dp stepped, 49 dp did not (fast or slow); the band is the
  line's own box across the whole width (60 px above the words stepped,
  130 px was the screen's seek); a drag moves the line after ~60 px and
  MX keeps the place for the next film, "↕ N" mid-screen while dragging;
  the line greyed (white ~33 %) while held. The pinch is not measured:
  sendevent on the API 30 image registered nothing (no tap opened ⋮ under
  any axis mapping). MX's tree gives the subtitle as `subtitleView` /
  `SubText` (ui.py `sub`); its media session gives no position there.

