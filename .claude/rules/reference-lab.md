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
