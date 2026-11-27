# BACKLOG — what is left, and why each item is where it is

2 Sep 2026, against **v1.64.4+317**. Ordered by (risk x likelihood) / cost, not
by how interesting the work is.

Nothing here is urgent. Several items are deliberately marked **do not do yet**,
with the condition that would change that. An item with no trigger is an item
that gets built too early.

---

## 0. OPEN AS OF 30 OCT 2026 — carry these forward

Written at the owner's request so nothing below is lost between sessions.
Newest first within each group; tick an item by deleting it in the commit that
does it.

### WHERE THINGS STAND — read first in a new session (20 Nov 2026)
- **26 Nov (late night): THE REST AS MX's (the owner: "every device and
  screen, exactly")** — on the branch, not released. Done: MX's controls
  geometry (row, discs, ⏮ ⏯ ⏭, lock, times); the tablet reach (480 dp,
  full width upright); Sleep and AE/EQ on the shade; toasts at the foot
  2 s; Customise Items as MX's top-bar card (`CustomiseTopBarCard`,
  `StringSetting.playerTopBar`). Details and proof: the handoff's update
  block ("26 NOV (LATE NIGHT)"). PROVED ON THE EMULATOR: reference lab
  45885319037 and 45892311848 (SCREENS=panels, controls.py): every
  control within 0.5 dp of MX's, both ways. Lab 45886561831
  (SCREENS=shortcuts) showed MX's Customise Items is an edit view, its
  Sleep × clears, its toasts 24 dp up: built after it (30c127f1) and
  proved beside MX's in run 45896496134. 27 Nov, THE OWNER: "CC as
  Innocent's" — ♪ and CC stay on the upright bar (MX's has HW only), and
  the small things done: the sleep keys at MX's size sideways (they were
  0.87: the title and time rows gave the room, the box and Stop/Start
  keep 48 dp); ⋮'s Burmese and Thai labels a weight up
  (`PlayerUi.tileLabelIn`): 11 words under 4.5:1 over white → 5, Thai
  none (13 sp made it worse). The Audio Effect tab stays as it is: its
  layout came from the owner's MX screenshots; the lab's MX is in HW,
  where its tab is a notice. Then the release (the owner's word).
- **26 Nov (night): ⋮ AND THE SHORTCUTS AS MX's (the owner: "11 tiles
  and More"; "every shortcut as MX's, exactly")** — on the branch, not
  released. The lab's SCREENS=shortcuts (runs 45857557804, 45862946745)
  took both apps' every shortcut; the table and what is left are in the
  handoff's update block. Done: ⋮'s ten tiles and "More ›" page; MX's
  order and five shut; Vertical flip off the row; Loop Off → All → One;
  Night mode grey 40 %; the speed card; the A-B bar. Left: Customise
  Items as MX's top-bar overlay; Sleep Timer and Audio Effect/EQ on the
  shade with Innocent's tokens; the controls geometry and the tablet
  reach (the owner took both). PROVED ON THE EMULATOR, reference lab
  45870615457 (adb1c24b): Innocent's open row in MX's order, the speed
  card, the A-B bar, Night mode grey, ⋮'s ten tiles and More, beside
  MX's. Fixed after it: Customise Items on the open row (second, as
  MX's); the film's subtitle lifted over the speed card (it lay across
  the card's numbers). What was "left" here is done: the entry above.
- **26 Nov (later): THE CONTROLS READ OVER ANY FILM; ♪'s AUDIO DELAY;
  THE OWNER'S PHONE IS 384x823 (work branch only, not released)** —
  session of docs/handoff_2026_11_26_mx_parity.md §2-§3. THE OWNER'S WORD
  (26 Nov, from MX | Innocent pictures): ♪ takes MX's Synchronization only
  (not Disable, Open, Stereo mode, SW decoder); the controls' new ground
  taken; the sideways subtitle under ⋮ waits for MX's own in the lab;
  "desktop" = Chromebook / Android windows (no Windows/Mac/web app).
  DONE: (1) `BarShade` under the top bar and bottom row — black 80 % at
  the edge, held at 50 % across the words, to nothing over 64 dp beyond —
  and `FilmInk` (the halo) on their words and icons; MX's gradients (as
  ours were, within a few grey levels: run 45781933354) fail over a white
  film. (2) The shortcut row on discs upright too: MX 3.4.3 has them both
  ways (they vanish over black; the Phase 45 audit read "none upright" off
  a dark film); upright over a white film the row was invisible (1.0:1).
  (3) ⋮'s tile labels white (92 % before). (4) ♪: a hairline, then "Audio
  delay" (Settings > Audio's value) opening `AudioSyncSheet` (− 50 ms +, a
  tap on the value resets; the film shows through), `PanelStepperRow`
  shared with the subtitle tune panel. (5) The legibility test measures an
  upright film too (`tall`), and words a FittedBox sets smaller (Thai's
  decoder label read 1.0 over black: the copy was laid unscaled).
  (6) test/support/player_harness.dart: the owner's phone 384x823 at
  2.8125, 48 dp nav (diagnostic reports name the model; at its default
  1080x2316 it is 450 dpi; the 4 Oct screenshots' 135 px bar is 48.0 dp at
  2.8125, 51.4 at 2.625), plus a 412 dp phone. player_screen.dart's "MX
  GEOMETRY" dp were divided by 2.625: ~7 % large, to measure again in the
  lab (§5 of the handoff). LEGIBILITY (my/en/th, five frames, before →
  after, same test): controls sideways 48 → 0 failing of 315, upright
  film 62 → 0 of 300, upright wide film 0; ⋮ 32 → 6 of 1440 (four
  Burmese and one Thai 12 sp label over pure white, 3.6-4.5:1; measured
  off the screenshot's bright pixels alone they read 5.3-6.0 — thin
  strokes' antialiasing; 12.5/13 sp or bolder only moved which labels
  fail); CC, ♪ all pass. Lowest control word 5.8:1 (hold 45 %: 5.1,
  62 %: 7.8). Tests: whole suite 2010 pass (62 skipped);
  player_controls_test 39 (a new one: ♪'s delay +50 ms reaches the
  engine, a tap resets); player_layout_test 1416 (4 phones, my/en/th,
  1.0/1.3) and PLAYER_PHONES=all 2832, no overflow. Lab: ref.env note,
  probe.sh waits for MX's font cache prompt (up to 6 min) so MX's subtitle
  shows. PROVED ON THE EMULATOR, reference lab 45796876490 (b3c64012):
  all 24 screens; Innocent's controls on their ground, the shortcut discs
  upright, ♪'s "Audio delay"; MX's font cache prompt still up after 6 min,
  so still no MX subtitle (the next run gives MX's films an .srt).
  EVERY SCREEN SIZE (handoff §4): player_layout_test gains split screens
  (PLAYER_PHONES=split: 384x411, 640x800, a 480x600 window); FOUND AND
  FIXED there: the sleep timer's keypad cut 104-113 px in an upright split
  window (it now gives way both ways), the cut sheet's point rows ran past
  a 280 dp side panel (the name now goes above). PLAYER_PHONES=all (11
  screens) 4026 pass. A REMOTE: in CC the D-pad went from the first track
  to the player's full-screen focus node (its centre was "nearest below"),
  never reaching the second track, Online or "Settings ▾" — the node is now
  `skipTraversal` (new test: walk, select opens ▾, Esc closes). The focus
  ring has a white inner line (blue alone 1.7:1 on the shade over a bright
  film). PanelRow's value sat mid-row beside an Expanded title (two
  flexibles): now at the end, ≤ 160 dp. App screens on SCREEN_PHONES=
  tablet,tablet_land,fold,fold_land,chromebook,tv in Burmese: 888 drawn,
  no problem (the fonts script needs `pip install fonttools brotli`).
  ACCESSIBILITY ROOT (handoff §3.2): on API 34 with the owner's three
  buttons and punch hole (device lab, PHONE_LIKE_OWNER=1) the root is the
  whole screen and the bottom row has its bounds (runs 37311495516,
  44940085085): the 96 dp gap is the reference lab's API 30 image. Device
  lab A1 (API 36) failed before the emulator on an apt 404 (45797540963;
  device-lab.yml now updates the index first): rerun. Stream bench
  45796876440 failed on test_screens (a removed parameter; fixed; rule in
  .claude/rules/flutter-app.md). LATER THE SAME DAY: reference lab
  45805693393 — with an .srt MX's subtitle shows; sideways under ⋮ MX
  leaves it at the foot, centred, across its last row, as Innocent does:
  THE OWNER: KEEP IT. Device lab A1 45805693479 (Android 16, the owner's
  navigation): every flow exit 0 (audits 55 and 52 checks), the
  accessibility root the whole screen, ⋮ in the tree both ways — the 96 dp
  gap is the API 30 lab image's (a TalkBack walk on the owner's phone
  would close it). tool/ref/controls.py measures the controls screen (dp,
  MX's view ids, Innocent's labels): THE OWNER TOOK MX's CONTROLS GEOMETRY
  (26 Nov) — the numbers and where they go: the handoff's update block.
  MX ON A TABLET, reference lab 45828625924 (800x1280 dp): MX's panels
  are 480 dp both ways (37.5 %), upright full width, content 32 dp in —
  MX's rule: the short side, at most 480. THE OWNER (26 Nov): MX's, all of
  it (Innocent now: upright 596 within a 640 cap, sideways 440). Device lab
  A2 45828625953 (API 34): genres 37/37, jumps 15/15, gestures 27/27 and
  19/19, audits 52 and 52 — the gate as U5. ref.env is still at the
  tablet: back to the phone with the next run. NEXT SESSION (the owner's
  word given for both): the controls geometry as MX's and the tablet reach
  as MX's (figures and places: the handoff's update block), then the
  handoff's §5.0 table.
- **26 Nov: THE PLAYER'S MENUS AS MX'S, ON THE WORK BRANCH ONLY (not
  released)** — next session: docs/handoff_2026_11_26_mx_parity.md (the
  state, what is open, every screen size, the rest of the player after
  MX, and the prompt to paste).
- **22 Nov: 1.64.88 IS OUT — the sign-in kept when the server ends a
  session while its token still lives; THE CONSOLE'S SIGN-OUT IS LOCAL
  (LIVE)**. RELEASED: main f82cbc4c (pushed 08:41:35 UTC after the
  realme passed and the libmpv jars came whole 3 of 3, md5 right), Build
  45003991782 green; GitHub release v1.64.88-401: arm64 95723768 B
  `2da3489c…aff4`, arm32 87702108 B `63076dc7…2880` (the assets'
  digests, = the release body); Static analysis 45003991758 and
  Dependency scan 45003991765 green; Semgrep on the tree against
  origin/main 0 findings; tree flutter test 1869 and check.py; Playback
  check 45006279752 green; app_releases id 1 moved 13:27:55 UTC after a
  rolled-back dry run (a worker restart held it from ~09:15; notes: fewer
  unexpected sign-outs, an Auth hiccup no longer signs out; an account
  with two-step stays signed in after signing in elsewhere); transport
  check 45027624325 (dispatched 13:28:00, after the row moved) green. Test Lab realme 45001500407: 16
  PASS, the home trip SKIP. Edge functions and Workers' code unchanged.
  THE OWNER TO CONFIRM ON THE PHONE: update, open the app once, sign out
  of the console and in again (Google + code), reopen the app without a
  tap — still signed in (a Google account chooser may come once); edge
  logs then show the console's `logout?scope=local`, the app's /user 403
  (if its token still lived), refresh 400 and id_token 200. The owner's test of 1.64.87 (21 Nov evening) still showed
  "Sign in". Edge logs: the console's Sign out was GLOBAL
  (`logout?scope=global` 18:15:32 UTC, supabase-js's default — it ends
  every session of the account, the app's too), then Google + MFA
  18:16:19; the app's /auth/v1/user answered 403 `session_not_found` from
  18:16:45 (its access token still had its hour), which 1.64.87 read as a
  refusal and never refreshed. No app auth request after 18:25:37.
  LIVE: main bc2ec2a3 (03:51 UTC 22 Nov, the owner's go) — the console's
  button and idle timeout sign out `scope: 'local'`; RUNBOOK: a lost
  phone is ended by a ban. Static analysis green, no Build (docs/ and
  .claude/ only), no Pages run; both Workers rebuilt 03:51-03:52. The
  checks that hold it (console_smoke clicks Sign out and reads the scope,
  console_build_test fails a signOut() without scope 'local') ship with
  1.64.88, since a push of tool/js starts the app Build. PROOF STILL TO
  SEE: the next console sign-out in edge_logs is `scope=local`.
  THE OWNER'S PHONE ON 1.64.87, 22 Nov 04:21 UTC (the token's hour long
  gone): refresh 400 (the session ended the evening before)
  → /user 401 → Google id_token 200 sixteen seconds later (the owner
  picked the Google account) → /user 200, subscriptions, bookmarks,
  premium_requests: signed in again as the same account. The expired
  shape works on a real phone; whether the chooser came by itself (the
  renewal) or after a tap on Sign in is the owner's answer.
  1.64.88 ON THE BRANCH (1572c0eb, 1bb4465c, f8437284): a 403
  `session_not_found`/`session_expired` counts as stale → refresh →
  refused → cleared → `unauthenticated` → the Google renewal (MFA
  accounts, same user); an Auth outage (5xx/429/offline, or a Keystore
  that cannot be read) is `network` for EVERY caller (the in-flight
  refresh hands each its own answer; before, a joined caller retried its
  stale token and the account cleared the session); the renewal forgets
  a refusal met inside itself; dispose cancels the pack header read.
  Review: SHIP (two rounds; its notes folded in). flutter test 1873;
  build.yml 44940097206 green; gate U5 44940085085 (genres 37/37, jumps
  15/15, gestures 27/27 and 19/19, audits 52/52 both ways); Test Lab
  OPPO 44940085103 16 PASS 1 SKIP (the home trip). The tree: main + 8
  files (scratchpad release_tree_88.sh: api_client and both tests whole,
  the fix commit's hunks of media_kit_player_service and
  api_account_repository — main's has no nonce — and the version
  1.64.88+401), plus the two console tests. THE OWNER'S CHOICE (22 Nov):
  release after the realme too (Test Lab quota resets 08:00 UTC).
  Known trade-off (review, not blocking): a deliberate global sign-out
  of an MFA account is undone on a phone whose Google account still
  allows the app (RUNBOOK: ban instead); a session time-box, if one is
  ever set, likewise.
- **21 Nov: REFERENCE LAB — 22 Nov: PHASE 0 AND PHASE 1 DONE; THE OWNER
  TOOK MX'S WAY: padding 24 dp, MX's reach, the shade for the glass, the
  subtitle over an upright panel (on the branch, not released)**. Purpose: see how MX Player's panels and menus sit against the
  picture (how far they rise, where they anchor, width and height, what of
  the picture stays visible, how they come in) next to Innocent's, and
  take MX's proportions only where they are better. Never its theme,
  colours or icons (the owner's rule, skill `ui-design` §4). With it, a
  legibility check of Innocent's own chrome over dark, bright, busy and
  colourful frames (needs no MX: player_layout_test over frames, here).
  - Shape: `.github/workflows/reference-lab.yml`, `test_device/ref/`,
    `tool/ref/` in this repo (our code only). The MX APK (the version the
    owner uses, uploaded by the owner) and every MX screenshot live only
    in the owner's PRIVATE repo `innocent-ref`, never in this public one:
    add a check.py guard (no .apk, no ref output). Both apps on the same
    emulator, sized like the owner's phone; a film made with ffmpeg
    (black, white, grey, busy; two audio and two subtitle tracks); MX's
    network cut by uid. Per screen: screencap + uiautomator dump → a dp
    table, side by side, MX's boxes drawn over ours. The report is a
    decision table (keep Innocent / take MX / the owner decides), not a
    diff to drive to zero. Start small: the panels that rise (⋮, ♪, CC),
    portrait and landscape; more only when the owner asks.
  - Phase 0, a probe: which ABIs the APK carries; does it run on the
    x86_64 Android 13 image, else 11/12 with ARM translation, else Test
    Lab (screens only, one of the five a day) — ask the owner then.
  - 22 Nov, DONE BY THE OWNER: the private repo `innocent-ref` (list_repos:
    private, the Claude app can reach it); the fine-grained token saved as
    the Actions secret `REF_REPO_TOKEN` (innocent-ref only, Contents read
    and write, 90 days — renew by about 20 Feb 2027). MX on the owner's
    phone: 3.4.3 from the Play Store. The owner asked Claude to fetch that
    version rather than upload it. The emulator to match the owner's
    phone: 1080×2316 at 450 dpi (≈384×823 dp, the default display; ask for
    a screenshot if Screen zoom was changed).
  - 22 Nov, MODE=fetch DONE (`reference-lab.yml`, `test_device/ref/
    fetch.sh`; runs 1-4 failed on the script, each fixed, ref.env says
    how; run 44986302924 green): innocent-ref's release `mx-3.4.3` holds
    `mx-3.4.3-arm64-v8a.xapk` (67788927 B), versionCode 2001003553. It
    verifies (v2, v3; CN=Kim Jae hyun, O=MX Technologies; the certificate
    pinned as MX_CERT), carries a VERIFIED GOOGLE PLAY SOURCE STAMP (the
    file Play delivers, unchanged; now required), and shares the signer
    of 1.85.8, the oldest APKPure lists. Checked from the session with
    get_release_by_tag. A rerun of fetch is a no-op (the release exists).
    security_invariants 16 fails on any app binary tracked here
    (.gitignore already drops *.apk, not .xapk/.apkm).
  - 22 Nov, PHASE 0 PASSED (MODE=probe; runs 44989031141, 44989696334,
    44990303466; ref.env says what each fixed): MX 3.4.3 (arm64-v8a only)
    INSTALLS AND RUNS on google_apis x86_64 API 30 under ARM translation
    ("Initialized NDK translation (aarch64)"), offline: player resumed,
    controls up, SIGILL 0, fatal 0, 779 packets of MX's refused by the uid
    cut. Needs: its player activity named (-p alone brings the chooser:
    it has a PiP twin), All files access (appops), and its tree from
    `dumpsys activity top` (uiautomator never finds its player idle).
    Screens and dumps: innocent-ref runs/2026-11-22_<run id>/.
  - 22 Nov, PHASE 1 DONE (MODE=panels; runs 44991688519 → 45002219382
    took all 24 screens; 45004133042 repeated every number; its sheets and
    decision.md: innocent-ref runs/2026-11-22_45004133042/compare/). ⋮, ♪, CC of both apps, upright and sideways, over
    black and white (same boxes both). Upright = an upright 9:16 film (each
    app turns itself; forcing MX upright from outside broke its layout);
    sideways = the wide film, rotation held by the lab. Innocent runs in
    software decoding there (libmpv stalled on goldfish H.264; the lab sets
    the Development switch). Screen 384×823 dp. MX | Innocent:
      CORRECTED 22 Nov (the first table took MX's subtitle, which MX
      moves up above its panel, and a list running past the screen into
      the panel; measure.py now takes the panel's container alone): ALL
      THREE MX PANELS ARE ONE 384×384 dp SQUARE — upright a bottom sheet
      46.6 % of the height, sideways a right panel 46.6 % of the width,
      full height; content ~26 dp in. Innocent: upright ⋮/CC 55 %, ♪ 24 %
      (as tall as its two tracks); sideways 46 %, full height; content
      20 dp in. Controls put away by both, everywhere.
      Upright, MX's ♪ and CC are INSIDE ⋮ (two taps; its top bar keeps only
      HW and ⋮) | Innocent's top bar, one tap. Rows 38 | 52 dp.
    THE OWNER'S DECISION (22 Nov: "the items to decide, as MX does"):
    the panel padding token 20 → 24 dp (20 under 360 dp), PlayerUi.pad,
    every panel and sheet alike (ui-design §2). The "♪ sideways 44 %" of
    the first report was the measuring error: MX's is 46.6 % like the
    others, no change. ASKED, NOT CHANGED: upright height, MX 46.6 % (a
    fixed square) against Innocent's 55 % cap, which the owner's 12 Nov
    choice protects. Kept (Innocent better): 52 dp rows, ♪/CC one tap.
    PROVED on the emulator, run 45010640345 (the lab build of 6e2efe8a):
    Innocent's content 24 dp in, upright and sideways (⋮ tiles from
    24.2 dp); its boxes and MX's unchanged; all 24 screens again.
    (Its stored decision.md reads Innocent's upright inset as 11 dp — the
    film's subtitle line, under the panel, taken for content; measure.py
    since leaves such a line out: 24.)
    ALSO ASKED (new, run 45010640345's trees): UPRIGHT, MX MOVES THE FILM'S
    SUBTITLE ABOVE AN OPEN PANEL (from 754-823 dp to 370-439, just over the
    panel's top) so it stays readable; sideways it leaves it at the bottom.
    Innocent leaves it where it was: upright under the glass, sideways
    centred and half under the panel.
  - 22 Nov (evening), THE OWNER: "as MX — it disturbs the film less while
    it plays than the clear background". Done on the branch (player_ui.dart,
    player_screen.dart; skill ui-design §1-§4 rewritten): (1) MX's reach
    for every panel and sheet, PlayerUi.panelExtent = the screen's short
    side, ≤ 46.6 % of the long side (upright 384 dp tall, sideways 384 dp
    wide + the navigation strip; it was ≤ 55 % / 46 %); (2) THE SHADE for
    the frosted glass: no blur, no 40 % dim over the picture; #1C1C1E from
    0 (56 dp before the edge) to 55 % at it, 84 % where the words start,
    92 % at the screen's edge — our stops, measured over the film, never
    MX's; dialogs keep the glass; (3) upright, the film's subtitle is laid
    above an open panel or sheet (PlayerUi.openSheets counts the sheets).
    Proof: flutter test 1873; player_layout_test 1062 without an overflow;
    the legibility test: every panel word passes over black, white, grey,
    busy and colour on the shade, but the selected track's accent label
    (3.2-3.7:1, as before) and its ✓ sideways over white (2.7-2.9:1).
    PROVED on the emulator, run 45019756405 (the lab build of d0cdb039):
    all 24 screens; Innocent upright 45-47 % | MX 46.6 %, sideways 46.8 %
    | 46.6 %, content 24-26 dp in | 24-26; the picture above an upright
    panel left white and sharp; the film's subtitle laid just above it
    (406-430 dp; the panel's top at 439, where MX puts its own 370-439).
  - 22 Nov (later), THE OWNER: "look again — MX's is more see-through,
    the film behind shows; ours is still heavier". Measured (grey levels
    of the same panel over the white and the black frame, run
    45019756405): MX lets 40 % of the film through within its panels and
    thins out from the picture's top (80 % at 160 dp before the edge);
    Innocent's shade let 9-15 % through. Now (player_ui.dart): 40 % within,
    20 % → 0 over 360 dp before the edge; words and icons with a dark halo;
    a choice a white ✓ and a heavier white title (blue read 1.3:1); tile
    icons on a dark disc. PROVED on the emulator, run 45035203039: the
    film shows through Innocent's shade as through MX's, 40 % within the
    panel and 70-88 % before it, within 1-3 points at every place measured
    (the lab also gives Innocent All files access now: run 45030566139's
    films were refused). Then: the shade black, not #1C1C1E (at the same
    see-through the grey left words 15 % less contrast); sideways the
    subtitle no longer keeps the controls' lift under an open menu (it sat
    across the panel's rows). LEGIBILITY (the test, owner's phone): every
    word and icon of CC and ♪ passes on all five frames; ⋮ all but four
    12 sp tile labels over a pure white film (3.7-4.3:1). PROVED, run
    45038350235 (the build of 4bc44dde): the film shows through as through
    MX's within 1-2 points everywhere, and the panel over a white frame is
    the same grey (102 of 255 both). Sideways the subtitle sits at the
    picture's foot and may touch a long panel's last row, as MX's would
    (MX does not move it sideways).
  - 26 NOV, THE OWNER: "English, Burmese in a rectangle — as MX, all of
    it; Innocent's UI is not pro, so make it as MX", and "hide the word
    More sideways". MX's KINDS OF CONTROL, drawn with Innocent's own icons
    and colours (skill ui-design §4): CC in MX's order — open a file, the
    subtitle tracks as check boxes in a thin rectangle (tapped again, none
    shows; no "Off" row), online subtitles, "Settings ▾" opening below
    itself to delay / text style / position; one choice of a list (♪
    tracks, speed, …) a radio ring with a dot; tiles ringed; ⋮ with no
    title upright or sideways; no line under a sheet's title. Tests: whole
    suite 1873 pass; player_layout_test 1062 (320/360/411 dp, my/en/th,
    1.0/1.3); legibility: CC 20/20 and ♪ 6/6 on all five frames, ⋮ as
    before (white 42/48, lowest 3.7; colour 46/48, 4.1). Not done: MX's
    ♪ "Disable" (no audio) — the engines' setAudioTrack needs a track; it
    wants an engine change. PROVED on the emulator, run 45775539414 (the
    build of 341aca04): CC, ♪ and ⋮ as MX's in kind and order, both ways.
    Left after it, and fixed the same day: the idle check box and radio
    read as black squares and discs (a dark halo filled them; MX's are
    outlines), the title sat 8 dp lower than MX's and the ♪ rows 35 dp
    lower (Innocent's header and list padding), upright MX has "← title"
    where Innocent had a drag handle, ⋮'s tile rows were 110 dp apart
    against MX's 83 (now 44 dp discs, ~88 dp). The lab's measure read ⋮
    sideways as 10.9 % wide that run: with no title its tiles reached the
    line the see-through was read along, and a median took the discs for
    the shade. measure.py now reads three lines and the shade's upper
    level: every Innocent panel 47.9 % on runs 45035203039, 45038350235
    and 45775539414, every other figure the same. PROVED, run
    45781933354 (the build of c3669a9b): titles where MX's are (CC's first
    row 78 dp down sideways, MX's 79), upright "← title" as MX's, idle
    marks outlines, ⋮'s tiles where MX's start, rows ~92 dp apart (MX 83;
    Innocent's rows stay 48-52 dp, MX's 45-47). Sideways the film's
    subtitle crosses ⋮'s last, faded tile row (it is not lifted sideways,
    22 Nov; MX's own was not showing in the run). ♪ beside MX's: MX also has
    Disable, "Use SW audio decoder", Open (an audio file), Stereo mode,
    Synchronization (audio delay: Innocent has it in Settings > Audio) —
    the owner to choose which to bring into ♪.
  - FOUND ON THE WAY (22 Nov, not fixed yet; each needs the owner's word):
    (1) INNOCENT'S ACCESSIBILITY ROOT IS 96 DP SHORT of the screen on the
    owner-like emulator (API 30, 3-button nav, punch hole): [0,0][1080,2045]
    upright, [0,0][2045,1080] sideways, while the app draws edge to edge —
    ⋮ sideways is missing from the tree and the bottom row upright (Lock,
    Previous, Play, Next, Fit, PiP) has zero bounds: TalkBack could not
    reach them. Check on API 34 (device-lab) and a real phone first.
    (2) LEGIBILITY (test/player_legibility_test.dart, LEGIBILITY_OUT=dir,
    owner's 384×823 dp, frames black/white/grey/busy/colour): every panel
    passes on every frame (the glass works) except the selected track's
    accent label (3.8:1 over black, 2.5-3.7 others; needs 4.5) and its ✓
    sideways over white (2.8:1). Controls upright pass (a wide film leaves
    them on black bars). Controls SIDEWAYS FAIL over white, busy and
    colour: title 2.2-2.5, clock 2.2-2.5, ♪/CC 2.0-2.6, HW 2.0-2.5,
    elapsed time 1.5-1.6:1 (the top and bottom gradients are too light).
    An upright film puts upright controls on the picture too: not yet
    measured. (3) test/support/player_harness.dart calls the owner's phone
    411×882 dp (2.625); BACKLOG's 22 Nov reading is 450 dpi, 384×823.
  - NEXT (26 Nov, the owner): a new session — docs/handoff_2026_11_26_mx_parity.md
    holds the state, the open items, the plan (every screen size; the rest
    of the player after MX) and the prompt. A rerun: ref.env MODE=panels
    (~30 min with the lab APK rebuilt).
- **1.64.87 IS OUT (21 Nov, the owner's "သေချာရင် Release လုပ်ပါ" after
  the sign-in question)**: main 01c05883 (pushed 16:25:37 UTC after the
  libmpv jar came whole 3 of 3, twice), Build 44924513260 green (Analyze,
  Test, both APKs, CDN, Release); GitHub release v1.64.87-400: arm64
  95723176 B `bcd300a5…2bbe`, arm32 87702316 B `488c8e7b…1af0` (the
  assets' digests); app_releases id 1 moved 16:57:39 UTC after a
  rolled-back dry run (CDN urls, both digests and sizes, mirrors = the
  GitHub release, notes_en / notes_mm: single-quality films and Original
  get the seek bar's pictures; the first drag sooner; nothing ahead with
  the data saver). Both Workers rebuilt (stream 16:26:02, console
  16:26:24; worker code unchanged — note: they also rebuilt at 07:08 for
  f4bc4fd3, which touched no docs/**: Workers Builds rebuild on any push
  to main). Static analysis on main 44924513301 green (main's red of 20
  Nov not raised again); Playback check on main 44924847586 green;
  transport check 44927401267 (dispatched 16:57:46, after the row moved)
  green — the APK on the CDN answers, its bytes and SHA-256 the row's.
  Ships:
  B1-B4, the sign-in renewal for MFA accounts, the trail fix, the Semgrep
  fixes, the Worker cache test. Left out: the lab hooks, the Google
  nonce, test_device/**. Edge functions unchanged (shims stay at
  a6d68c93). The tree: 39 files against f4bc4fd3; flutter test 1861 on
  it, 1865 on the branch; the gate U4 44913341833 and Test Lab
  44913341838 on the final code (e5774a33).
  FOR THE NEXT RELEASE (the reviews' non-blocking points, left out so the
  tested code is the shipped code): MediaKitPlayerService.dispose() does
  not cancel the header timer; a ladder film moved to its Original and
  back reads its pack's header again (16 KB); _renewRefused should
  forgetRefused() in its finally (a nested refused read leaves the flag
  for one more exchange at the next resume); a non-admin can enrol a TOTP
  factor through the auth API, and then a deletion on another phone
  would be renewed into a new account here (rare, deliberate) — closing
  it means MFA enrolment for admins only (the owner's call); the Android
  plugin's fallback sheet lists every account on the phone. THE OWNER TO
  CONFIRM ON THE PHONE: update, open the app once (it learns the account
  has MFA), sign out of the console and in again (Google + code), reopen
  the app — still signed in; the edge logs then show a Dart refresh 400
  and an id_token 200 a moment later.
- **21 Nov: "SIGNED OUT AFTER AN UPDATE" — NOT THE UPDATE (the owner's
  question before 1.64.87)**. Edge logs: on 14 Nov the console signed in
  with Google and completed MFA (TOTP verify 08:11:53 UTC); at 08:16:20 the
  phone app sent its STORED refresh token (so the update had kept the
  session) and the auth server refused it (400), then /auth/v1/user 401,
  and the app signed out. Supabase Auth deletes every session of an
  account below aal2 each time it completes MFA anywhere (mfa.go,
  InvalidateSessionsWithAALLessThan, every verify, no setting); the app's
  Google session is aal1. From then no app auth request until the owner's
  Google sign-in at 07:29 UTC today; auth.sessions holds only the console's
  aal2 session (14 Nov) and today's app session. FIX ON THE BRANCH
  (2e904fcb, a8999901 and the MFA-only commit): a refused GOOGLE session
  of an account with a verified MFA factor (remembered from the user's
  `factors`) is renewed once without a tap (attemptLightweightAuthentication
  + the button's id-token exchange); the same user id or none (another
  account: its session ended, `scope=local`); never a phone account, an
  account without MFA (deleted or signed out elsewhere: an exchange would
  sign up a new account), the viewer's own sign-out or deletion (flags
  cleared after the tokens), twice, or nested. Review: blocking finding
  (the ghost account after a deletion elsewhere) fixed by the MFA-only
  rule; admins (the MFA accounts) cannot delete theirs from the app. To
  see it work on the owner's phone: after updating, sign in to the console
  again (Google + code) and reopen the app — still signed in; the edge
  logs then show a Dart refresh 400 followed by an id_token 200.
- **21 Nov: TRICK-PLAY FOLLOWS TRANSCODE (LIVE) and 1.64.87's candidate
  (on the branch, at the release checkpoint)**.
  TASK A, LIVE (the owner's word; main f4bc4fd3, transcode.yml only): a
  Transcode run on main that recorded a rung dispatches trickplay.yml on
  main (rungs counted from what tool/transcode.sh printed, kept by tee;
  the script unchanged); Trick-play's concurrency queues, never cancels;
  the daily 03:37 schedule stays as the net. Main Build 44878780740 green
  (nothing published), Static analysis 44878780745. PROVED on Elephants
  Dream (open film): queue_transcode 07:08:45 UTC (dry run rolled back
  first), Transcode 44878856181 re-recorded the 240p rung (23,107,898 ->
  23,115,462 B: an older ffmpeg pin and script), Trick-play 44878915223
  dispatched 07:09:31, a NEW pack 07:10:07 (163 pictures, 678,794 B), the
  old one in r2_trash (purge 28 Nov); trickplay_for serves the new one;
  Playback check 44879184335 read it through the Worker (header = grant,
  offsets, a whole JPEG, 20 in one request, edge = direct). Queue to pack:
  82 s, where it was up to a day. NOTE: staleness is by the smallest
  rung's bytes, so a film re-made by the same script and pin (Hero, 6 Nov)
  keeps its pack — right, the file is the same.
  ON THE BRANCH FOR 1.64.87: B1 (c86b380d) a film played as one file —
  one rung (Elephants Dream, Hero) or its Original — reads its pack:
  StreamCacheServer.registerFilmPack (no cache entry, the install's
  header, the renewal, the playing copy's pool), armed per copy address
  (FilePacks: one film at a time); shown without the network-preview
  switch (the owner's choice); nothing ahead with the data saver. B2
  (c86b380d, 8904dfe6) the pack's header read 5 s after the first
  picture, on the ladder once 8 s are in hand (at most 30 s): device lab
  U1 44881023891 (hdr first) the first drag's first picture weak 1540 ->
  858 ms (12 of 12 pairs), plain 1221 -> 596 (4 of 4); U2 44887248209
  (trick first, the 8 s rule) weak 1464 -> 822 (12 of 12), A/A 156 ms;
  near_ms / stop_ms no different; +1 request, 16 KB a playback; the hdr
  passes' start stops all came BEFORE the read. B3 (the owner's choice):
  nothing ahead with the data saver, pack or not. B4 (d26fae6e) the
  actions on Node 24: checkout v5.1.0, setup-java v5.7.0, cache v5.1.0,
  setup-android v4.0.4 (each action.yml read at its SHA). PROVED: flutter
  test 1851 here, the new socket tests 3 of 3 under load; Build 44881033416
  and 44887255541 (Node 24 pins), Stream bench 44881023893 and
  44887248249, Static analysis green; TEST LAB 44887248300 (489b3b88 —
  lib/ and android/ final; the day's tests 1-2, started by the
  device-cloud.yml pin change): realme 16 PASS 1 SKIP, OPPO 16 PASS 1
  SKIP, no crash; the header read ahead at +5 s on both, the first drag
  1187 -> 674 ms (realme) and 1480 -> 408 (OPPO). U2's first attempt met
  Maven Central's 429 (re-run). THE GATE on the final code, device lab U3
  44896555838 (8228a952): attempt 1's genres and jumps met the emulator's
  lost network ("No internet connection", "the film never started" — the
  other flows passed); attempt 2: genres 37/37, jumps 15/15, gestures
  27/27 and 19/19, player audit 52 and 52, no crash. B1 ON ELEPHANTS
  DREAM (libmpv, one rung): every drag from the pack (24 of 24 a line),
  its own picture median 109 ms plain / 184 weak (p90 374 / 598), far
  drags 357 / 546 ms, ~10-15 KB a drag, no stop in the start's 30 s; the
  header read while playing took 1.2-2.2 s there (libmpv's own download
  fills the line) — well before any drag; with the pack unread (`near`,
  as 1.64.86) the film has no seek-bar pictures at all. Release tree
  (worktree at origin/main): diff with the branch only the exclusions
  and the version; check.py, analyze (no error or warning), flutter test
  1847 pass; the pinned Semgrep against origin/main 0 new ERROR; no red
  branch scan since 1.64.86. RELEASE REVIEW (reviewer): ship, nothing
  blocking. FOR THE NEXT RELEASE (non-blocking, left out so the tested
  code is the shipped code): MediaKitPlayerService.dispose() does not
  cancel the header timer (stop() does, and the screen always stops
  first); a ladder film moved to its Original and back reads its pack's
  header again (16 KB; pictures right).
- **1.64.86 IS OUT (20 Nov, the owner's "Release လုပ်ပါ")**: main a6d68c93
  (pushed 16:30 UTC after the libmpv jar came whole 3 of 3), Build
  44774072388 green (Analyze, Test, both APKs, CDN, Release); GitHub
  release v1.64.86-399 (16:55): arm64 95711908 B `4e95c499…899b`, arm32
  87694124 B `368423c1…bf52` (GitHub's asset digests); app_releases id 1
  moved 18:55:39 UTC after a rolled-back dry run (CDN urls, both digests
  and sizes, mirrors = the GitHub release, notes_en / notes_mm as shown to
  the owner, released_at now). Both Workers rebuilt from main (stream
  16:31:12, console 16:32:18). Playback check on main 44776762810, and
  44797438536 after the re-point. EDGE SHIMS RE-POINTED to a6d68c93
  (docs/edge identical to 8746f216): transcode v30, request-playback v45;
  function logs since: 200s only. Trick-play on main 44797433895: "0
  film(s), scope all"; its schedule `37 3 * * *` runs main's copy from now.
  Transport check on main 44797364068 (from 18:55:45, after the row
  moved): "every transport check passed" — the APK on the CDN HTTP 200,
  95711908 B, its bytes and SHA-256 the row's (the 32-bit one is not in
  that check: put by the same Build step, whose PUT fails the step on any
  error). Ships: the 19 Nov weak points 5-7,
  the 15 Nov items, the trick-play pack reader. Left out: the lab hooks,
  the Google nonce, test_device/**.
  STATIC ANALYSIS ON MAIN 44774072468 RED: six ERROR findings first met on
  the branch (four red branch runs, 20 Nov, never cleared) — five
  subprocess audits in the trick-play tools, one curl piped into python3
  in playback-check.yml. Fixed on the branch (4993cb65: argv lists marked,
  the pipe replaced; the pinned Semgrep here: 0 ERROR findings); they reach
  main with the next release, and later pushes to main do not raise them
  again (a push is compared with the commit before it). The release skill
  now says to clear red branch scans before the push.
- **THE LONG START IS THE WORKER — PROVED 20 Nov from its own logs (the
  owner's export of 14:00-14:02 UTC)**: at 14:00:33.511 the warm-up's probe
  of the 480p rung (`bytes=0-8191`) ended `canceled` (Play took the film
  over); from 14:00:34.225 to 14:01:17.776 every front read of that rung —
  75, `bytes=0-8191` and `0-65535` — answered 500, outcome `exception`:
  "This promise was created by a request that has since ended, so it can
  never settle. With the handle_cross_request_promise_resolution
  compatibility flag, a promise can only settle in the request that
  created it", at `mendFront (index.js:406)` — `strayIndexes`, which kept
  the first request's PENDING bucket read for every later request (19
  Oct). 720p and the other rungs answered 206 meanwhile; at 14:01:17 the
  rung's reads came back. The second long start the same (export of
  14:16-14:18): 91 such 500s, 14:16:09-14:17:17, the 480p rung only. 166
  in all, every one this message at mendFront. FIX ON THE BRANCH, NOT LIVE (a Worker deploy is
  a push of docs/worker to main — the owner's word first): the per-isolate
  caches keep the ANSWER (strayIndexes: an array, a failed read not kept;
  signingKey: the CryptoKey, the same pattern), never a promise;
  tool/js/worker_cache_test.mjs (15 checks, in check.py; the old Worker
  fails it); worker_gate and stream_token tests pass. THE OWNER'S GO TO
  DEPLOY: "Worker deploy လုပ်ပါ" (20 Nov) — after device lab T4
  44805958041 (START_PAGE 3, the race on purpose, 12 passes) has measured
  the Worker before it (its first attempt met Maven Central's 429 at the
  APK build; re-run). T4 BEFORE THE FIX (21 Nov 03:54-04:07 UTC, Play 3 s
  after the page, 12 passes): the race met in 4 of 12 — pass 9 a 19.9 s
  start (7 head reads cut, `480.m3u8 not served` 6 times), passes 6 and 7
  8.1 s and 6.1 s (2 cuts each), pass 3 one cut; first picture median
  plain 4265 ms (p90 12994), weak 4696 ms (p90 6928).
  THE WORKER FIX IS LIVE (21 Nov): main fbaf697d (docs/worker and this
  file only: no app Build), innocent-stream rebuilt 04:24:03 UTC (console
  04:24:31), its deployed code carries the fix (no pending promise kept);
  Playback check 44866137861 and transport check 44866140754 on main
  green. T5 44866328935 AFTER (T4's config, 04:35-04:48 UTC, the tap 0.6-
  2.1 s after the warm-up registered — the race window): 0 cuts in 12
  passes, no long start; first picture plain 4265 -> 3507 ms (p90 12994 ->
  4370), weak 4696 -> 4729 (p90 6928 -> 6313). THE WORKER'S LOGS AGREE
  (the owner's export, 04:35:01-04:48:01 UTC, 448 events): 0 exceptions,
  0 `can never settle`, 221 answers 206; 3 requests `canceled` — the
  warm-up's cuts that used to start the 500s — and nothing after them;
  the 480p rung's front reads (22 probes, 14 heads) all served. (The
  dashboard's filter offered no `exception` value for the window: none.) The test and check.py line reach main with the next release.
  Rule: .claude/rules/worker.md. To prove it after a
  deploy: device lab with START_PAGE 1-2 s (Play inside the warm-up's
  head read) before and after, and the Worker's logs for `can never
  settle`.
- **The owner's first 1.64.86 report, DZQXVZT2 (20 Nov 19:25 UTC, wifi
  metered, diagnostic_reports id 10)**: THE PACK WORKS ON THE PHONE —
  Sintel `preview pack: 222 pictures, header 818 ms`; every drag `pack N,
  fragment 0` (11 drags, 1-122 pictures each); a picture from memory 2-9
  ms, from the line 270-470 ms; a drag's first picture 1.1 s when the
  header and the picture went one after the other (no pictures ahead yet);
  runs ahead 6-21 pictures, 1 request, 0.4-1.3 s. A resume at 249 s: first
  frame 1846 ms. Two "pictures" of 3.3 s and 7.1 s came AFTER `player
  teardown done` (never shown) — the 7.1 s one behind a far jump whose new
  connection took 2.7 s (`exo picture after seek 4286 ms`, `conn new 2668
  ms`). The drag line counted its line cost from the first ANSWER and
  counted pictures after the film closed: fixed on the branch (the cost
  from the first ask; a picture after its film closed is not a drag's).
  The first start after the update read the library once (`stamp moved or
  old, scanned`), by design: the stamp's kind changed.
- **Work branch `claude/extract-github-release-oteqr5`** holds everything
  not yet live (main is a6d68c93, app 1.64.86; on the branch only: the lab
  hooks, the Google nonce, test_device/results, 4993cb65's scan fixes).
  A new session starts on main:
  fetch this branch and work on top of it, or the notes below are missing.
  Push to it (fast-forward), the owner's choice of 8 Nov: a session's own
  branch starts at main, has no history in common with this one, and
  would need a force-push.
- **20 Nov: the trick-play sprite, the owner's go-ahead ("Sprite လုပ်၊ plan
  သေချာချ"), then "Sprite ပဲ အရင်" for phases 2-3 (no release with it)** —
  the design and the order of work are docs/trickplay_plan.md. PHASES 0-3
  DONE; THE APP DOES NOT READ THE PACKS YET (phase 4).
  - Phase 0 (44668658121, 44671051967): chosen 4 s, 320 px, JPEG q8 —
    4.4 KB a picture, 4.28 MB per film-hour; 12-19 s of a runner a film-hour.
  - Phase 1 (29d57ea5, 8fcb3b69, reviewer's five findings fixed 27e9f91a):
    migration 083, transcode trick_claim / trick_done, request-playback's
    additive `trickplay` field, tool/trickplay_job.py, trickplay.yml.
  - Phase 2, LIVE 20 Nov: 083 applied (table asset_trickplay; claim / record
    / trickplay_for / trickplay_key, service role only; r2_refs names the
    current packs; r2_move_switch moves them). On live after the apply:
    TRICKPLAY, FILES, MEDIA KEYS and FRAMES TEST PASSED; r2_refs per kind
    unchanged (backups 17 = db_backups, streaming copies 26 = renditions);
    security advisors: the new table only under RLS-no-policy (INFO, as every
    service-only table), no new function callable by anon or authenticated.
    transcode v29 and request-playback v44, shims at 8746f216 (only the
    trick-play change differs from the live SHAs ea45f9b0 / 6a874828).
    Playback check 44710855254 on v44: grant 200, `trickplay: none` before
    the packs, every other step as before; function logs: 200s, no error.
    BOTH SHIMS POINT AT A BRANCH COMMIT: until the release brings
    docs/edge to main, a deploy of either function from main would drop the
    trick-play code (deploy from this branch, or from main after the release).
  - Phase 3, LIVE 20 Nov: Trick-play 44723609469 (scope open, 1 min of
    ffmpeg): NINE PACKS, all recorded — 1,201 pictures, 5.7 MB in all
    (0.18-1.02 MB a film, median 3.0-6.4 KB a picture; widths 320, heights
    134-180 by the film's shape). DB: nine rows `done`, each key the one its
    claim minted, trickplay_for serves each, r2_refs names each as in use,
    count = duration / 4 s. Playback check 44725839247 (Sintel, the playback
    check grew a pack step in 039325aa): the grant's `trickplay` field read
    through the real Worker — header = grant, offsets end at the object's
    size, a picture is a whole JPEG, a run of 20 is one request, edge and
    direct paths byte-identical.
  - Phase 4, ON THE BRANCH 20 Nov (8ec30178, labs 3e076d37): the app reads
    the pack. `PlaybackGrant.trickplay` (TrickplayInfo.fromJson: null for no
    field, codec other than jpeg, count/interval/bytes/size <= 0, no url, a
    sealed pack, a header that cannot fit); the pack registered with
    StreamCacheServer beside the ladder (HlsPackSource: the ladder's pool,
    StreamDoor's header, renewal on 403/404/410 with the same pack only) —
    `packRange` reads it with NO cache entry: nothing written to the phone;
    TrickplayPack (domain/trickplay_pack.dart): first read [0, max(16 KB,
    header)), header = grant or not used, a picture or a run one range, LRU
    2 MB, three failed reads and the fragments take over; ladderPreview /
    prefetchPreviewsAround (+-40 s in one request, none with the data saver)
    / nearestPreview / the jump's landing picture read it; trail `preview
    pack: N pictures, header X ms` and one `preview drag:` line a drag.
    Lab words `trick` / `near` (LabStream), drag costs, far drags
    (ladderstart_summary). Tests 1839 here (40 new). Trick-play cron daily
    (37 3 * * *) with SCOPE=all, the owner's word for this job only:
    branch run 44734070021 "0 film(s), scope all" (the live database before
    it: 9 assets with a ladder, all open films, all packed).
    PROVED (20 Nov): Build 44734076158 and, on the final code (b904977d,
    the release review's fixes), 44745251407 — Analyze, Test, both APKs;
    Stream bench 44734069861, 44740642743; Playback check 44737887377 (its
    pack step now in the run's summary). Device lab, the drags' A/B (8 a
    pass, two far into a part never seen): T1 44734069987 (near first, 16
    passes) and T2 44744740674 (trick first, 12, then the pack's A/A 8):
    TRICK SOONER IN EVERY PAIR, both lines, both orders, every drag size —
    its own picture after the finger stopped, median: plain 1050 -> 221 ms
    (T1) / 1558 -> 301 (T2), weak 1598 -> 278 / 1785 -> 340; far drags
    plain 1086 -> 386 / 1712 -> 492, weak 1933 -> 524 / 1404 -> 634; within
    10 s plain 963 -> 46 / 1336 -> 56, weak 1531 -> 93 / 1649 -> 161; a
    drag's line 213-283 KB -> 14-18 KB, requests 2-3 either way; first
    picture 0 ms both. A/A (T2, a vs b): within 10 s 51 ms plain, -16 ms
    weak (all drags); far drags 48-278 ms — against near-minus-trick 919-
    1323 ms. The header 0.6-1.4 s once a film (read with the pictures ahead
    when the controls come up). THE GATE on both (T2 = final code): genres
    37/37, jumps 15/15, gestures 27/27 and 19/19, player audit 52 and 52,
    no crash, no refusal. Test Lab 44734557188 (8ec30178): realme 15 PASS
    2 SKIP, OPPO 16 PASS 1 SKIP, no crash; the far seek-bar picture 1637 ->
    344 ms and 1617 -> 343 ms (from the pack: 1 request, 2.5 KB; header
    0.85 / 1.04 s on the first drag with no controls shown).
    RELEASE REVIEW (reviewer, 20 Nov): ship; fixed b904977d — a hung pack
    read ends (packAnswer 15 s, a read at most 20 s), the pack reader made
    again for another pack on the same ladder, `_leaveLadder` stops
    ExoPlayer when the newer open is libmpv, a non-finite number is no
    pack. DECIDED 21 Nov (the owner, B3): with the data saver on, nothing
    is taken ahead, pack or not (it was six fragments, ~450 KB, each time
    the controls came up).
  - FOUND 20 Nov (T2): TWO STARTS STOOD STILL 46.5 s and 72.8 s (pass 1
    trick, pass 8 near — not the pack): Play tapped 1.3-1.8 s after the
    warm-up registered the 480p rung, its head read still on the line; the
    player's head reads of the SAME rung then failed again and again (~1.5
    s each: three answers that were not a 206, `480.m3u8 not served (no
    index)` every 2 s, the pool's last read `failed`) while 720p's head on
    the same pool came at 6.7 s, until a NEW connection read it 43 s / 60 s
    later. Suspect: the stream Worker's `strayIndexes` (since 19 Oct) keeps
    ONE pending promise per key per isolate; the warm-up's request, cut when
    Play takes the film over, cancels the R2 read inside it, and every later
    request for that key's front (offset < HEAD_SCAN_BYTES) on that isolate
    awaits a promise from a cancelled request — the runtime's "hung" error
    (a 5xx) — until the isolate goes. The 19 Nov start (a resume on the
    WARMED rung) puts the player on the same key as the warm-up, so a quick
    tap meets it. Not proved: the Worker's logs at those minutes (14:00:36-
    14:01:16 and 14:16:13-14:17:20 UTC) would say. T3 44758587901 (`fix`
    against `base`, 24 passes, no drags): NO stall (one cut, recovered:
    4.9 s); fix again the faster start, plain 4889 -> 3429 ms, weak 7329 ->
    4398 ms median. So 2 long starts in the day's 60 passes, 0 in the 76
    before: a race of the tap against the warm-up. A fix is the Worker's
    (keep the RESULT per key, never a pending promise across requests) —
    the owner's call (no Worker change in this release without it).
  - NEXT, phase 4 (DONE above; kept for its notes): the app reader. Register
    the pack with StreamCacheServer like a rung — the Worker enforces bound
    tokens (/health bind=enforce), and a bound grant binds the pack's URL as
    it does the rungs', so the pack is read with the install's device header
    exactly as a rung is. Then phase 5 (labs `trick` vs `near`, gate, Test
    Lab), and the release only on the owner's word: the job's cron on main
    for new ladders ships with it; `all` (the catalogue) only on the owner's
    word.
- **19 Nov, on the branch for the next release: 1.64.85's weak points
  5-7** (the "first look" entry below; the streaming review §5, "Runs S1,
  S2, S3"). MEASURED FIRST, new lab flows `ladderstart` (a resume at
  579 s, every step of the start in ms — `LadderStartTrail`, one summary
  line in every build's trail — then seek-bar drags with each preview's
  parts) and `coldcpu` (cold starts as root: threads every 2 s, Java
  stacks, simpleperf; COLD_PLAN, COLD_LIBRARY). (5) THE FAR START: a
  resume never opened on the rung the app chose and warmed (`_openLadder`
  passed the start rung only from 0), so Auto took one from the meter
  whose index came after the start rung's playlist — S1 44534768953:
  first picture 4.2 s plain, 6.1 s weak; and the warm-up read the film's
  opening, not the resume point. FIXED (0a6ade35): a resume's first open
  starts on the warmed rung; its warm-up reads the resume point. A/B both
  orders, 12 passes a line each: S2 44549507157 plain 4629 -> 3045 ms, weak
  6541 -> 3834; S3 44565023092 plain 4433 -> 3354, weak 7676 -> 3505
  (median; 24 of 24 pairs; S1's A/A 0.1 s plain, 1.5 s weak); 480p+ in the
  first 30 s 40 -> 94 % / 24 -> 69 %; stops in it weak 5 -> 3, plain 1 -> 2
  (all under 0.6 s but two). The owner's three rules, on top of the fix:
  `one` +0.3 s, `hold` +0.04 s (under the A/A), `par` moot — taken out
  (0318ab39). (6) THE SEEK BAR'S PICTURES: a picture never seen is the
  Worker's answer ~0.5 s + bytes 0.16-0.33 s + decode ~0.45 s (emulator);
  now the pictures 10/20/30 s either side are taken when the controls come
  up, and the nearest one taken within 10 s is shown at once (eb2fda2e);
  two fetches on their way tried and taken out (a weak line's long drag
  later in both orders, S2/S3). A/B in device lab G1 44580628422 (9 drags
  a group, base -> near): a drag's first picture 0.7-1.3 s -> 0 ms; a
  picture within 10 s of where the finger stopped, short drags plain 945
  -> 431 ms, weak 1553 -> 597, long plain 1199 -> 1006, weak 1604 -> 1282;
  its own picture 0.2-0.6 s sooner in all four groups; the same fetches a
  drag, plus ~3.5 pictures each time the controls come up. A part never seen still
  waits ~1.2-1.4 s: only a picture made in advance removes that — THE
  OWNER'S CALL, below. (7) APP START CPU: the library cache was trusted
  only while MediaStore's VOLUME generation stood still, which every
  photo, song or chat download moves: each launch read 2000+ videos again
  (photo_manager's pool + Dart's file workers — ScanGate's own "before"
  numbers 25 % / 17 %, the owner's 23 % / 13-19 %). FIXED (84abb9ce): the
  stamp is the video table's (count and newest GENERATION_MODIFIED per
  volume). coldcpu in S2, 424 videos, a new picture before each start:
  the volume's stamp read the library again 3 of 3 starts (0.9-1.2 s
  each, the main thread 3 % against 1 % over the first 10 s), the videos'
  0 of 3 ("library all: cache trusted" in the trail). The emulator's
  fast CPU shows the mechanism, not the owner's 20 s: the next diagnostics
  report says (`library all: …` lines). Tests: 1799 here (resume start,
  warm at the resume point, the loader's nearest picture, the trail);
  branch Builds 44536161098, 44549512776 green (the Kotlin), Stream bench
  44534768955, 44549507240 green; on the final code (0318ab39) Build
  44580634917 green and THE GATE, device lab G1 44580628422: genres 37/37,
  the jumps on Big Buck Bunny 15 of 15, gestures 27/27 and 19/19, the
  player audit both ways (52 and 52 steps, exit 0), no refusal, no
  stacked player; its start passes (fix) plain 2671 ms, weak 3300 ms
  median to the picture. TEST LAB ON THE FINAL CODE (20 Nov) 44700090814:
  realme 15 PASS, OPPO 15 PASS, 2 SKIP each (tour->original: lines 7.7 and
  5.1 Mbit/s under the 10 Mbit/s copy; the home trip, by design), no crash,
  no ANR; first frame 2.6 s on both, a far seek-bar picture 1.6 s (no
  controls shown in that check, so nothing ahead — the sprite's case). A
  push at 07:16 UTC (44693769383) was refused TEST_QUOTA_EXCEEDED: the
  quota resets at midnight Pacific, 08:00 UTC in winter (device-labs fixed).
  THE BRANCH IS READY FOR THE OWNER'S RELEASE CALL: gate G1, the player
  audit both ways, Test Lab both phones, Builds and Stream bench green, 1799
  Flutter tests — the app as of 0318ab39 (lib/ and android/ unchanged
  since; what came after is the sprite's phase 0-1: docs, tools, a
  migration and two edge functions not applied or deployed).
  THE OWNER'S CALL (weak point 6): a trick-play sprite from the
  transcode — one 160x90 picture every 5 s (2 s matches the ladder's
  fragments), tiled 10x10 — about 0.5-1 MB a film-hour, a few sheets per
  film; R2 storage pennies a month for the catalogue; a Worker request
  per sheet, not per picture; a 30 s ffmpeg step on the 240p rung, a
  backfill job for the films already up; a key and an upload URL from the
  transcode's edge function, and the app reading it. Then every preview
  is a crop of a sheet on the phone (~10-20 ms) after one sheet's
  fetch, against 1.2-1.4 s now for a part never seen and ~67 KB each.
- **15 Nov, on the branch for the next release: the 14 Nov weak points
  1-4 and the double open's refusal** (69374520, 7e1bbbfc, 63499b3c,
  e4212f13, 091d4278). LIVE ALREADY: migrations 081 and 082 (below).
  (1) THE LAST SUMMARY: kept on the phone until its batch is taken
  (`SummaryOutbox`: SharedPreferences, at most 8, none older than 7 days —
  record_events takes an event's time back 7 days at most), tried twice
  more in the run, then sent at the next start with `stashed: 1`; every
  copy carries the playback's `meta.summary_id`; 1.64.81-1.64.85's single
  kept summary is adopted with an id made from its own time and session.
  `EventSender.flush` says whether the server took the batch and is never
  skipped: one that met a post on its way used to return and leave the rest
  to a 30 s timer a frozen app never runs. Viewer data behind it (1.64.84 /
  1.64.85, labs left out): 3 / 5 opens, 2 / 4 summaries — 1.64.84's two are
  one playback twice (the double open's two screens), so 2 of 3 and 1 of 5
  playbacks lost theirs; 1.64.84's 08:18:57 summary was lost although the
  app lived on (same session: the batch's post failed — dropped by design).
  Privacy text, three languages: "a record not yet sent is kept on this
  phone until it can be sent, 7 days at most", and "network type" out (never
  sent). (2) LIBMPV'S OPEN: media_kit's open() stops the file before it and
  says "not buffering" as it resets; real libmpv here, through a server
  answering in 700 ms: "not buffering" 10 ms, first byte 735 ms,
  video-params 766 ms (test/libmpv_first_picture_test.dart, Stream bench).
  `VideoPlayerService.firstPictureStream` (video-params; ExoPlayer's first
  rendered frame) or a moving position is the first frame on libmpv; READY
  stays the ladder's. (3) THE STALE START: a libmpv open forgets the
  position and length of the engine before it (the start check read the
  ladder film's 650 s; the 5 s resume save could have written it against
  the new film). (4) A scrub's end starts the jump clock (`sinceLastSeek`).
  THE REFUSAL: `ExoEngine` says in the trail why an engine call was refused
  (`exo open refused: no engine N` / `…: <Class>: <message>`, addresses left
  out; Kotlin's error carries the class); and two races closed —
  `stopPlayback` stopped a next film that began inside its awaited pause,
  and `_leaveLadder` iterated `_exoSubs` across awaits (a ladder bound
  meanwhile lost its listeners and its ExoPlayer was stopped). No other
  release of the engine exists (one service for the app; released only in
  its dispose), so the 14 Nov "answered false" is not explained by code
  alone: the `reopen` lab flow and the next phone trail will say. Tests: the
  branch's 1787 Flutter tests here (analyze: no error or warning), each
  fix's own test failing on the code without it (summary_outbox_test 3 of
  3, first_picture_test 2 of 3, player_service_state_test 3 of 4,
  exo_refusal_test 2 of 3, stop_race_test), the summary tests five times
  under CPU and disk load (29/29 each). PROVED SO FAR: device lab run A
  43675629684 (on 091d4278): genres, the jumps on Big Buck Bunny (15
  checks, as before), gestures both ways — all passed; `reopen` 7 plays, 7
  first frames, 4 ExoPlayer opens, no refusal and no fall back; the labs'
  first summaries ever reached `events` (device_kind lab): libmpv open_ms
  886 / 441 / 1275 with stalls 0 and frozen 0 (it read 32-43 and a stall),
  ladder 1252 / 1712, stalls 0. Test Lab 43675629659: realme and OPPO 16
  PASS and the one SKIP each as 43589024823 (the Test Lab path's home trip),
  no crash of the app (the OPPO's one FATAL is Google's Files app). Branch
  Build 43675638790 green (the Kotlin change), Stream bench 43673989316
  green (the whole suite with libmpv and ffmpeg installed: the real-libmpv
  test runs there), Static analysis green. NOT PROVED by run A:
  `summarykill` — a fresh app's permission dialog took the first Back (the
  launch waited 12 minutes) and a plain start stops at the introduction,
  logs no event and so sends nothing; mended (lab_grants, every start the
  lab's launch) and run again in run B. FOUND BY run A, fixed (abc60f3d):
  a player screen pushed over an open one — the first Back went to that
  dialog, the next play opened over it — left the one below mounted: every
  30 s it reported the new film's position against its own title (Big Buck
  Bunny "at 8 s of 653 s", in the live events), wrote it into its own
  resume point, never sent its summary, and closed later would have
  cleared the callbacks, PiP callbacks, wakelock, volume keys and full-screen
  UI of the one on top. Any play reaching the player over an open one does
  this ("open with"). Now `PlayerScreen._onTop`: the newcomer supersedes the
  screen below, which says its last with its own position and then touches
  nothing shared. The last watch point is written just after the tree
  change (Riverpod refuses a provider change during it in a debug build —
  found by the new test on the existing deactivate path), and a summary
  says where its playback ended (a playback under 30 s said 0). Tests:
  stacked_players_test (fails without: the first summary []), the branch's
  1788 here; branch Build 43682174225 and Stream bench 43682165005 green on
  10d54e03. THE KILL PATH PROVED (device lab run B 43682165030,
  `summarykill`): three plays of the 1-rung film, each closed and the app
  force-stopped 2 s after (the last through Home); in `events` one row
  each, the first two `stashed: 1`, each received at the NEXT start
  (06:01:21 made, 06:02:03 received; 06:02:08 / 06:02:49), the third at
  Home; open_ms 1423 / 1168 / 802, stalls 0, position_s 34-35 (where each
  ended). `reopen`: 8 plays, 8 first frames, 5 ExoPlayer opens, 7 summaries
  sent, no refusal, no fall back, no stacked player. THE PLAYER AUDIT on
  the branch's code: run B both stopped, run C sideways 52/52 and upright
  stopped, run D 44497996796 all four passed (twice each way) — 5 of 8.
  The three stops are one kind: a tap on a control (More, holding Next,
  Subtitle) landed on the video (`LAB gesture tap` at that moment) because
  the 4 s auto-hide took the controls between Maestro's steps, ~5 s apart
  on those runners; nothing on the branch touches the auto-hide (the
  device-labs skill says how to read it). GATE ON THE FINAL CODE: device
  lab run E 44501502064 (fd904b16): genres 37/37, the jumps on Big Buck
  Bunny 15 of 15, gestures 27/27 and 19/19 — as 1.64.85's gate; no
  refusal, no stacked player. TEST LAB ON THE FINAL CODE (19 Nov):
  44514004930 — realme 16 PASS and the home-trip SKIP, as before; OPPO 14
  PASS, 2 FAIL (seek frozen 6.2 s, tour->original ready 13.2 s) on a line
  measured median 2200 kbps (min 659) against its 25-27 Mbit/s of 15 and
  14 Nov, TCP handshakes 0.5-2.9 s: the line; the OPPO alone once more,
  44518397993: 15 PASS, 0 FAIL, 2 SKIP (the home trip; tour->original "line
  6085 kbps, the copy 9989 kbps", as 1.64.84's OPPO run), line median 5.3
  Mbit/s, no crash. THE BRANCH IS READY FOR THE OWNER'S RELEASE CALL: gate
  (run E), the player audit (run D), the kill path (run B), Test Lab both
  phones, branch Builds and Stream bench green, 1788 Flutter tests. On the way, 44505438819 lost its results twice over (its
  first attempt's build met Maven Central's 429 and committed an empty
  results directory; the re-run's phones finished but its commit conflicted
  with it): device-cloud.yml now lays a re-run's results over the branch as
  device-lab.yml does (e3ba2552).
- **081 and 082 are LIVE (14 Nov, the owner's go-ahead)**: lab builds send
  `device_kind` `lab` (`EventSender.deviceKind`; a release build 'phone'),
  the 1,954 lab events before it were marked (every install that only ever
  reported 1.64.78+391 — not every 1.64.78+391 event: one install that
  reports every version ran the 1.64.78 release on 30-31 Oct, 26 events,
  kept a viewer's); heat, Trending, co-watch and reach, the daily rollups
  (re-rolled: event_daily 476 -> 394 rows) and startup_latency /
  startup_by_title / stall_reasons leave `lab` out; event_geo's audience
  `lab`; `_refresh_cowatch` zeroes the reach of a title no viewer engages
  with any more (it only upserted). 082: a unique index on a
  play_summary's `meta.summary_id` — a copy sent again after a lost answer
  is skipped inside record_events. Reproduced first (a lab play moved the
  heat 7.6449 -> 8.6449, a lab open the day's start-up samples 39 -> 40; a
  second copy was kept), dry runs rolled back, then on live
  tool/sql/lab_events_test.sql, play_summary_once_test.sql and
  events_housekeeping_test.sql passed. Still counting the labs: the
  console's raw `kinds` tally (studio.ts `stats` reads `events` itself — an
  edge change, the owner's call). Reading viewer data by hand now:
  `device_kind is distinct from 'lab'`.
- **1.64.81 (394) is out, 8 Nov**: the Privacy text, the HLS read-ahead
  fix, the playback telemetry (`play_summary`, ladder `play_stall` with
  `ahead_ms`, `error` codes, `grant_ms`), the 7 Nov streaming fixes and
  5b's rung weight by the fastest 20 s. Details under "Next app release".
  On the branch only, by design: the Google sign-in nonce and the lab's
  hooks (tour skip, `rungKbps`, `ladderRungKbps`, `lab_peak`'s A/B, and
  since 9 Nov the jumps in Auto: `_labAutoJumps`, `LabStream.autoJumps` /
  `jumpVariant`, the Test Lab path's `INNOCENT_LAB_AUTOJUMPS` and its
  home-trip skip; since 11 Nov `LabStream.jumpRule` (`lab_jump` on/off →
  `keepSpare`), the Test Lab path's `keepSpare = true` and
  `_labAutoJumps(alternate:)` / `StreamCacheServer.spareForJumps`, and
  `_Ladder.pool`'s lab `connectionFactory` (`_labTimedConnect`, DNS / TCP /
  TLS apart in the trail)).
- **1.64.85 (398) is out, 14 Nov**: main c70f4e94, Build 43593640548
  (every step green: Test, both APKs, CDN, GitHub release, mirrors, the
  provenance attestation; Static analysis 43593640610, Dependency scan
  43593640530 and CodeQL green; no Pages deployment). GitHub release
  v1.64.85-398: arm64 95673736 bytes `d027101d…469f`, arm32 87650004
  bytes `51ee5652…2a1b` (the release body and GitHub's asset digests
  agree). `app_releases` id 1 moved at 13:15:53 UTC after a rolled-back dry
  run read it back as anon (as anon after: 1.64.85 398). Playback check
  43598774695 (Big Buck Bunny) passed on main; transport check 43598920099
  on main: every check passed, the CDN's APK against the row included.
  WHAT IT CARRIES: the scrub fix (a film no longer stays still after a
  seek-bar jump), one play at a time (`PlayTapGuard`), ExoPlayer's hold
  and each pool's state in the trail. PROVED before: device lab
  43589024808 (genres 37/37, jumps 15/15, gestures 27/27 and 19/19) and
  43591776802 (the player audit 58 steps upright, 52 sideways), Test Lab
  43589024823 (realme 16/16, OPPO 16/16, no crash), branch Builds
  43585867675 / 43577691274, the release tree's 1758 tests and check.py,
  a release review (ship; its two low findings on PlayTapGuard fixed
  first, 39fa7449). Left out by design: the lab hooks, the Google sign-in
  nonce, test_device's run.sh / config / cloud settings and results (the
  two lab readers weakline_climbs.py and weakjumps_summary.py went, as
  the device-labs skill names them).
- **1.64.84 (397) is out, 13 Nov**: main 333c7071, Build 43456848305
  (every step green, CDN and GitHub release included; Static analysis,
  Dependency scan and CodeQL green), Playback check 43462010173 passed on
  main. GitHub release v1.64.84-397: arm64 95671464 bytes
  `13658a77…d7a6`, arm32 87646148 bytes `d46052e2…413c` (the release
  body and GitHub's asset digests agree). `app_releases` id 1 moved at
  18:49 UTC after a rolled-back dry run read it back as anon; it waited
  three hours for the Supabase connector, which answered 502 in this
  session after a worker restart (connectors are read when a session's
  worker starts; the next restart brought it back).
  WHAT IT CARRIES: Phase 1–2 of every screen size (docs/devices_2026_11.md),
  targetSdk 36 (docs/target_sdk_36.md), a TV's media session (ended off
  screen), the glass menus, 5d's kept connection and the play_summary
  stash (dropped on sign-out), the engine check's resume fix, the gestures
  help sheet, the paste hint. PROVED: device lab gate 43425944894 (genres
  37 steps, jumps 15 of 15), the player audit on the phone 52/52 sideways
  (43447577014) and 55/55 upright (43453790923), Android 16 on a Pixel C
  (43420830536), Test Lab 43422832434 (realme 16/16, OPPO 15 and one skip
  on its line), branch Build 43425976389, the release tree's 1749 tests
  and check.py, a release review whose three findings were fixed
  (71eb5e98). Left out by design: the Google sign-in nonce and the lab's
  hooks (list below), test_device/results.
- **1.64.83 (396) is out, 12 Nov**: the player redesigned (skill
  `ui-design`, `widgets/player_ui.dart`) and the engine judged by the
  film's clock, and nothing else: released like 1.64.82 from main plus the
  session branch `claude/focused-johnson-1915dp`. On this branch too
  (6a6bade6), so the next release from here carries it — and is 1.64.84:
  the "1.64.83 candidate" of b3e2bad1 (5d's keepSpare, the play_summary
  stash) has not shipped. Details under "Player redesign".
- **1.64.82 (395) is out, 11 Nov**: the player audit
  (docs/player_ux_audit_2026_11.md), and nothing else: released from main
  1.64.81 plus the audit (session branch `claude/focused-johnson-1915dp`),
  so none of this branch's unreleased work went with it (5d's keepSpare,
  the play_summary stash, the lab hooks). The audit is on this branch too
  (822a7e8f) and the next release from here carries it. Details under
  "Next app release"; what the audit left open under "Player audit".
- **GitHub Pages came back and is off again (13–14 Nov)**: the 1.64.84
  record push (4b005001) redeployed the retired Pages console at 19:00
  UTC, 13 Nov (pages run 43487949804) — "Unpublish" had left the source
  branch set; transport check 43496849155 read it `HTTP 200`. 14 Nov the
  owner unpublished it again and set Pages' Source to "GitHub Actions" (no
  None was offered once unpublished); no workflow deploys Pages and
  `tool/workflow_yaml.py` fails on one that would. Transport check
  43546232032 (14 Nov, 02:36) green, the Pages page a 404 again. And a
  push no longer redeploys it: main's push 52088a48 (docs/ among it)
  started no "pages build and deployment" run, and transport check
  43550729017 on main read the page a 404 after it.
- **Synced to main 14 Nov, 02:49 UTC (52088a48) — docs, tool and notes, no
  app code** (main stays app 1.64.84): the stream Worker's `STUDIO_ORIGINS`
  = the console alone; transport_check.py's console checks and the
  retired-Pages 404; `tool/workflow_yaml.py` refusing a workflow that would
  publish Pages; studio.ts and console_origins.js caught up with what is
  live; CLAUDE.md, the release skill, the console rule, the console and
  studio READMEs, the security review, this file. Release tree = origin/main
  + the branch's copies of those 14 files (`git diff --cached --stat
  <branch>`: only lib/, the lab/nonce tests, test_device/results); check.py
  and the tool/js tests in it; reviewer twice (no fault; its findings —
  Pages republished, stale Pages text, `write-all`, a timestamp — fixed
  first). PROVED LIVE: the stream Worker rebuilt from it (its deployed code
  has the console alone, no github.io); Build 43548366901 green (Static
  analysis 43548366897 and CodeQL green), and it uploaded nothing — the
  GitHub release v1.64.84-397's assets unchanged since 13 Nov 16:14,
  digests as recorded; Playback check 43550726555 passed (Big Buck Bunny,
  given by id; with no id it takes the first free published title, and
  every free published title is an open film — 9 of 9, 14 Nov);
  transport check 43550729017 on main: every check passed, the console's
  preflights from studio and the Worker, a stranger's refused, the retired
  Pages console a 404; no Pages deployment.
- **Live already**: the stream Worker answering the console alone (14 Nov,
  52088a48); migrations 077–080; studio v55 (24a3365: answers only
  `console.innocentplayer.com`, and asks R2 for each bucket's CORS —
  `r2_cors` in its log and in "Check bucket access"); ingest v56,
  transcode v28, probe-media v27 (ea45f9b: console origin only; ingest and
  transcode answered 200 after); transport-check every 6 h; the backup
  drill (last 7 Nov, next ~14 Nov). 13 Nov: DNSSEC Active, the legacy
  Supabase keys off, the GitHub Pages console retired (security review
  P4), R2 CORS of both buckets = the console alone (seen: console allowed,
  Pages and a control refused).
- **The owner still has to** (15 Nov): say when the next release may go
  (it carries the 15 Nov entry above; skill `release`); choose whether the
  console's event-kind tally should leave the labs out (studio.ts, an edge
  change) and whether the stream Worker gets `Server-Timing` (deferred 14
  Nov). Earlier: update a phone to 1.64.85 (and with it: a
  drag on the seek bar held still for 5 s, then let go — the film moves
  on) and say if the
  player's glass menus are smooth over a playing film (⋮, CC — the blur's
  cost has no lab number), and if "stopped responding" ever shows again
  on a file that plays; on a tablet or a TV if one is at hand; sign in
  again on https://console.innocentplayer.com/studio/ (the Pages sign-out
  ended every session, 13 Nov). (Done 14 Nov: Pages unpublished again
  and its Source set to "GitHub Actions" — "Unpublish" alone had not held,
  the 1.64.84 record push redeployed it at 19:00 UTC, 13 Nov, run
  43487949804.) Optional: remove the
  stale Supabase redirect URL `…supabase.co/functions/v1/studio` (the
  console's first home).
  (Done 13 Nov: the Pages console retired — security review P4.) Done 13 Nov: DNSSEC
  Active; the legacy Supabase keys off. (The five open films were
  approved, checked 8 Nov.) The 12 and 13 Nov reminders have fired.
- **Streaming, 14 Nov afternoon: the morning's W1 / L1 checked again, nothing
  re-run** (a second session given the same task). `weakline_climbs.py` on
  W1's results: 8 climbs, 0 followed by a stop (passes 2-8 no stop; pass 1's
  14 stops at 240p with no climb before, the runner's line); W1's tombstone
  is `com.google.android.googlequicksearchbox` (the emulator's), not the
  app. `weakjumps_summary.py` on L1's table gives the review's numbers
  (paired stop p 0.19, answer 13 / 13 / 30 alike). Viewer data unchanged:
  still no event of any kind from 1.64.84 (the last viewer event 12 Nov,
  1.64.83); `play_summary` 4 rows in all (1.64.81: 2, 212 s, no stop, 20
  jumps 135 ms each; 1.64.82: 2, 50 s, one 2.2 s stop = 2.65 s frozen a
  minute, 5 jumps 49 ms each), all open films, one viewer — too few to
  judge. Branch Build 43572316738 on 4d4f9c38 green (structural checks,
  Analyze, Test, both APKs; it publishes nothing off main) — the first
  since 13 Nov, for the 14 Nov Dart change that ships with the next
  release (`_PoolUse`'s state in a jump's trail).
- **1.64.85's first look on the owner's phone (14 Nov, 13:51-13:54 UTC; a
  diagnostics report and the events)** — (1)-(4) FIXED ON THE BRANCH 15 Nov,
  (5)-(7) 19 Nov (the entries above): the fix works — four drags of
  1.4-5.8 s, each `exo held N ms (scrubbing)` ending in a jump or a Back,
  the film moving after; no double player. WEAK, for the next sessions:
  (1) THE LAST PLAYBACK'S SUMMARY IS LOST: the session's last film
  (ladder, opened 13:53:53, closed ~13:54:22) sent no `play_summary` and
  no progress (13:57 still none) — as on 1.64.84 (08:18:57). The summary
  waits in memory (`EventSender`, 30 s or the pause flush) and its kept
  copy is dropped as it is queued; leaving the app soon after loses it.
  The longest playback is often the last. (2) LIBMPV'S OPEN IS COUNTED AS
  A STALL: on the local-proxy path `first frame` fires at 32-35 ms, before
  a byte ("stream index 0.0 MB"), then the real start wait is a
  "rebuffer" of 881 / 986 ms — the summaries say open_ms 32 / 35 and
  stalls 1, frozen 881 / 986 ms; ExoPlayer's opens read 1393-2078 ms
  honestly. Frozen seconds a minute, the number to lower, is wrong for
  every libmpv playback. (3) A STALE START: a libmpv open after ExoPlayer
  films read "open began at 650s, not 491s - jumping there" — likely
  `_position` left by the ExoPlayer film (`_confirmStart` breaks on any
  position > 0); its needless seek sat inside that 881 ms. (4) A scrub's
  end on ExoPlayer re-buffers 25-106 ms with 61 s in hand and is counted
  a blip, not a jump. (5) A far ladder start took 2078 ms to a picture:
  the 480p, 360p and 720p indexes read one after another (141.8, 142.3,
  142.8) and Auto went to 720p at once on a line measured 2592 kbps
  (warmed: 480p). (6) Seek-bar pictures of parts not yet seen took
  478-1010 ms (seen ones 24-45 ms): the picture lags the finger. (7) App
  start: 60-74 % CPU for the first ~20 s (pool-thread 23 %, DartWorker
  13-19 %), before any playback. Also open from earlier: the ExoPlayer
  open that answered false after the double open; transport check
  43567299617 (06:38) cancelled mid-step after 7.5 min (13:16's passed).
- **1.64.84's viewer bug, fixed in 1.64.85 (14 Nov)**: after a jump by
  the seek bar the film could stay still while it "played", the pause
  button dead, until another drag — the owner met it on Sintel. Cause,
  proof and fix under "Next app release", with a second one found in the
  same reports (a double tap on a card opened two players). Both shipped
  in 1.64.85 the same afternoon.
- **The labs' plays are in the live `events` as viewers' (found 14 Nov;
  FIXED 14-15 Nov: the owner chose (a), migration 081 live and the app's
  `device_kind` `lab` on the branch — the entry above)**:
  lab builds (device lab and Test Lab, `INNOCENT_LAB=true`) report
  `app_version` `1.64.78+391` — the branch's own, bumped on main alone —
  and send their events to production like any phone. 7 days to 14 Nov:
  1,594 of 1,798 events, 170 fresh `viewer_key`s, 170 of 179 `play_open`;
  all on open films, no `play_summary` (a lab's play ends in a force-stop,
  so the per-playback numbers are clean). What it moves: the console's
  start-up latency (`startup_latency`: lab p50 3257 / p95 4625 ms on its
  weak line, viewers' 9 opens p50 1727 / p95 3008), its event counts, and
  Trending (`trending_titles` 7 of 7 open films; the home's Trending reads
  the same heat, 052). Harmless to viewers today — the published catalogue
  is the 9 open films — but the labs' ~25 plays a day will lead Trending
  (and feed co-watch) once other titles are published, and drown the
  first viewers' start-up numbers. Fix, the owner's choice: (a) lab builds
  mark their events (`device_kind = 'lab'`, lab-only) and a migration
  leaves `lab` and `1.64.78+391` out of the heat, co-watch, rollups and
  start-up functions (a live database change: skill `live-db-change`); or
  (b) lab builds send no events (app only; loses the labs' end-to-end look
  at the event path). Until then, leave `1.64.78+391` out when reading
  viewer data.
- **Streaming, 14 Nov: item 2 not seen, and 5d's follow-up decided — no
  rule from either** (review §5 "Runs W1 and L1"). Viewer data first:
  no `play_summary` from 1.64.84 yet (no event of any kind from it — the
  owner's phone has not updated); 1.64.81: 2 rows, 212 s played, no stop,
  20 jumps 2.7 s in all; 1.64.82: 2 rows (one session), 50 s played, one
  stop of 2.2 s (2.65 s frozen a minute played), 5 jumps 243 ms; all on
  open films, one viewer. Too few to judge anything. Item 2 (device lab
  W1 43555903291, 8 weakline passes of an A/A on the live build): 8
  climbs, none followed by a stop (`test_device/weakline_climbs.py`). 5d's
  follow-up, a pool known lost when a read on it ends cut (L1 43560088068,
  16 weakjumps passes, on / lost): nothing for it to choose, the answer
  and the stop no better; taken out. Kept: each pool's state in a jump's
  trail, which showed open pools keep their connection (101 of 102, idle
  up to 11 s) and lost ones never (0 of 10) — the server does not close
  idle ones. Test Lab 43560350582 on the build with the rule: realme and
  OPPO 15 of 15 each, lines 1.4 and 4 Mbit/s that day. Gate on the build
  with the rule taken out: device lab 43567588467, the jumps on Big Buck
  Bunny 15 of 15 (the build's own spare).
- **5d, a connection kept open for a jump (11 Nov; LIVE in 1.64.84, 13 Nov,
  on by default)**: `StreamCacheServer.keepSpare` (the release left the
  lab's `_labTimedConnect` out).
  Measured first (device lab M1, 42951731347): on the weak line a jump's
  answer was 885 ms on a new connection (DNS 25 + TCP 147 + TLS 189 + the
  Worker's wait 441) against 466 on a kept one, and 33 of 34 jumps that cut
  the read ahead in flight paid the handshake (a response cut before its
  end takes its connection with it). Now a ladder's segment reads take
  turns on two pools and a jump takes the one with no read on it: device
  lab S1/S2 (42957372146, 42982586873; 112 pairs, both orders) the answer,
  the jump's stop and the first picture each 0.30 s sooner (stop: 69
  pairs against 33, p 0.0002; the A/A spreads 0.31-0.35 s over 21-28);
  stops after 3 (0.61-0.73 s) against 0, picture after alike; no Worker
  request more. Gate: jumps on Big Buck Bunny 15 of 15 with it on (S2), and
  twice more on the build with it on by default (G1, G2). Test
  Lab with it on: OPPO 16 of 16 (42982587122), realme 16 of 16 on its rerun
  (42985879375; its first run's line read 64-303 kbps and the checks never
  began). On the phones' fast lines every jump found a connection open
  either way. Review §5 "Runs M1, S1, S2". Follow-ups: marking a pool lost
  when a read on it ends cut — tried 14 Nov (L1), nothing to act on, taken
  out (the pools' state stays in the trail); the Worker's own wait (~0.3 s,
  R2 most likely) needs a `Server-Timing` header to split (a Worker change,
  the owner's call).
- **play_summary was lost for a playback the app never came back to
  (found 11 Nov; the fix LIVE in 1.64.84, the kept summary also dropped on
  sign-out since the 13 Nov review)**: it was sent only as the player
  screen closed; an app sent to the background and closed from Recents
  never closed it (1.64.81's first viewer: 4 playbacks, 2 summaries; the
  labs' 79 force-stopped plays: none). Now kept on the phone when the app
  goes to the background mid-playback and sent at the next start with its
  own time, session and version (`stashed: 1`). Viewer data otherwise: 2
  `play_summary` rows since 1.64.81 (one viewer, open films, 212 s played,
  no stall, 20 jumps 2.7 s in all); `network_kind` is never sent (no
  plugin, by design), so "per network" needs the measured line in the
  summary instead.
- **5c tried and taken out (9 Nov)**: a jump's first segment from a rung
  that arrives in ~0.5 s did not pay. Device lab J and J2 (42616754742,
  42628158249; 224 jumps on the weak line, on/off alternating, both
  orders): the jump's own stop a median 0.18 s shorter, the first picture
  no sooner, a second stop right after the jump in 23 jumps against 5, a
  softer picture. Test Lab 42641532315: the phones' lines (realme
  ~15 Mbit/s, OPPO ~0.3) gave the rule nothing to act on. A jump's wait is
  the Worker's answer (0.3-0.9 s), the phone's restart (0.4-0.7 s), then
  half a segment's bytes (review §5). The player code is back as it was
  (cdc1319); the `weakjumps` flow and the jumps in Auto stay, to measure
  jumps. On that build: device lab J3 (42655210613) jumps 15 of 15, and
  an A/A of the flow came apart by 0.35 s over 28 pairs (5c's 0.18 s gain
  in the jump's stop is that flow's noise; its second stops are not);
  Test Lab 42655210615, the OPPO alone: 16 of 16 on 11.5-38.6 Mbit/s (the
  three failures before were its 0.3 Mbit/s line).
- **5b (8 Nov, live in 1.64.81)**: the master weighs a rung by its
  fastest 20 s (`PeakRule.window`), decided by 32 weakline passes in runs
  H, H2, H3 (review §5): 480p or better 89 % against 69 %, no stop;
  Test Lab 42461966293: 15 of 15 on both phones.
  `deep` (a deep buffer weighed against the whole line) tried, dropped.
  The weakline flow now plays `WEAK_PASSES` passes per run, alternating
  `lab_peak` variants: use it for every A/B (one pass says little).
- **Next streaming work**: what a jump still waits for on a weak line is
  the Worker's own answer (~0.45 s on a kept connection; its split from
  R2's needs `Server-Timing`, a Worker change — the owner's call) and the
  phone's restart; the spare is as good as two pools get (a jump finds its
  connection open in 9 of 10; the rest were taken by a cut just before,
  which only a third connection made after each cut would cover — a
  Worker request more per jump, not proposed). Item 2 is not seen on the
  live build; 5b's leftover (a fall to 240p where 360p fits) is a softer
  picture, not a stop. Not 5 as written: it doubles the Worker requests
  and would take 5d's spare away (review §5). The number to lower is still
  frozen seconds per minute played from `play_summary`, which needs
  viewers on 1.64.84 first. Method: `docs/streaming_review_2026_11.md` §5
  and skill `device-labs` (read the cap probe and each pass's line
  readings first; passes alternating per variant; read a jump's answer
  and the pools' state first; an A/A of 21-28 pairs spreads 0.31-0.35 s).
  With 5d on by default the gate passed 15 of 15 in G1 42995970597, G2
  42999722877, the 1.64.83-era candidate 43142688683 (+ Test Lab OPPO
  43142688768 16/16) and 1.64.84's 43425944894.

### Player redesign (12 Nov, 1.64.83) — skill `ui-design`
The owner's screenshots of 1.64.82: "Playback failed / The player stopped
responding" over a local file that kept playing; ⋮ and the subtitle panel
translucent with the controls showing through, outline rings — "a toy"
beside MX Player. Done:
- The false alarm: MpvLink calls a call stuck after 4 s; the screen now
  asks the film's clock (`domain/engine_check.dart`): moving → alive (the
  link renewed once a film after 15 s), still 3 s playing / 8 s paused or
  buffering → stuck. An error the film survives is a small warning card;
  only one that stopped it takes the screen. Never a signed address on it
  (`domain/error_text.dart`).
- One look for every menu (`player_ui.dart`: PlayerPanel, PanelRow,
  PanelTile, PanelSwitchRow, PanelChoiceChip, PlayerDialog,
  showPlayerSheet…); the controls hide under a panel, dialog, the error
  card and any sheet the player opens. CC lists the tracks itself.
- Found on the way and fixed: after Next the screen acted on the FIRST
  film (title, bookmarks, favourite, share, cut, info, Retry, seek
  previews); the Video display switch hid ⋮'s sixteen actions; Playing
  queue was a stub ("1 items", a dead drag handle) — now the folder; a
  deleted bookmark stayed listed; bookmarks stored a signed stream's
  address or a Private Folder film's name; the resume card blocked taps.
- Proof: device lab 43185129320 (all four player flows exit 0 on the final
  build; 43154335111 / 43176762134 before the review's fixes), Test Lab
  43180990404 (realme, Sintel 16/16, no engine verdict), 1690 tests,
  `player_layout_test` 1062 photographs, a reviewer pass (its findings
  fixed: one relink a film, the warning card, TalkBack live region).
  Build 43186533253: arm64 95641124 bytes `1560c80f…d4a8`, arm32 87609628
  bytes `beb69528…7733`, GitHub's digests agree; app_releases moved at
  09:19 UTC after a rolled-back dry run.
- Every other view, the same day (owner's request; session branch
  9a4f531a, on this branch, not yet released): the screens harness
  (`test_screens/`, 107 screens) in Burmese and English on both phones and
  in Burmese at 320 dp — no overflow anywhere; looked at one by one. Fixed:
  the downloader's tabs dropped the theme's font (a bare `labelStyle`); the
  information dialog (`MxDialog`) moved onto the player's tokens; the Up
  next card on the player's surface. And (owner's screenshot): upright,
  ⋮ rose over the whole picture. First the picture was lifted out of its
  way; the owner then chose misted glass instead: every player menu is
  frosted glass (`PlayerGlass`: the film blurred under a 72 % tint;
  opaque on Android Go and 32-bit-only phones), the picture stays put,
  the upright sheet stops at 55 %, and sideways every player sheet is a
  full-height side panel (they were bottom sheets with ~300 dp that cut
  their lists). Session branch a74047a6, on this branch; ships with the
  next release — worth a look on the realme/OPPO for smoothness under
  an open menu (the blur is redrawn every frame).
- **Every screen size** (owner, 12 Nov): `docs/devices_2026_11.md` — the
  study (large-screen tiers, TV quality, window size classes, Android
  16/17 ignoring orientation locks at ≥600 dp) and the plan. Phase 1 done
  (session branch 851dce81, on this branch, ships with the next release):
  TV overscan margins as insets; the player's remote and keyboard keys
  (media keys, K/J/L, M, Esc, ?), mouse hover and right-click; 25 list and
  form screens capped at 840 dp; upright player panels at 640.
  **Phase 2 item 1 done** (12 Nov, on this branch, ships with 1.64.84):
  two panes from 840 dp (`core/ui/list_detail.dart`) — Settings as the
  list beside the open page (a page opened from it opens in the pane, Back
  closes it first), the Video tab as the folders beside the open folder's
  videos (one search for both; a selection of the videos is the pane's);
  a window narrowed to one pane keeps what the person opened (never over
  the player); grids add columns with width (posters 3 on a phone, 7–8 on
  a tablet sideways; Status Saver, Private Folder, the picker); the
  downloader capped at 840. Found on the way, fixed: four settings dialogs
  closed through the page's context (in a pane they would have closed the
  page, the pane blank); Back closed the Video tab's search but left its
  query (the folders stayed filtered, nothing on screen to say why); a
  folder found by its name opened as "No video matches"; a folder's own
  search filtered the folder list behind it; on a TV the Video tab's title
  sat 48 dp in from its list; the Folders title cut on a 320 dp phone (the
  view mode goes into ⋮ there); a search that took the open folder away
  left its videos selected. Proof: 1723 tests (19 new), the screens
  harness on tablet, foldable at 841, Chromebook, TV and three phones in
  Burmese and English, 1.3 at the tightest — no overflow; sheets sent.
  Then (13 Nov) the 20 list and form screens Phase 1 had left at full
  width capped at 840 (History, Favourites, Watch later, Playlists and a
  playlist, Recycle bin, Watch insights, music's album / artist /
  playlist / folder, Stream cache, Delete account, Network stream, Cloud
  drive, Pop-up play, Subtitle and Language settings, the player's
  Customise, the equalizer, the age gate); a harness file for them with a
  week's history (`test_screens/lists_screens_test.dart`). It found Watch
  insights' week chart cut by 12 dp on every phone, its days in English
  shorthand ('6d'…'Yd', 'To') and its total drawn without the app's font
  (RichText): fixed (heights from the text size, dates and "Today" in
  three languages, Text.rich). **Phase 2 item 2 (13 Nov)**: targetSdk 36
  readiness written up (`docs/target_sdk_36.md`; not raised — the owner's
  call): the player's sheets now follow the window while open (one route,
  state kept; the old ones left a 300 dp bottom sheet sideways after a
  turn), the film and an open menu tested through turns and an unlocked
  tablet resize, the WebView screens keep their history Back at 36. Left
  there: the rotate button where Android 16 ignores it, an API 36 lab job,
  local network permission before targeting 37 (Transfer, Network).
  **Phase 2 item 3, TV (13 Nov, first part)**: the D-pad can leave a text
  field (Flutter 3.32's single-line fields kept every arrow — the search
  field held a remote for good); Back by D-pad from a pane goes to the
  list's open row before it leaves; a 190-photograph overscan audit fixed
  a film's page, the poster and media grids, the picker and the shell's
  right side. Item 4: right-click opens a video's menu and selects a
  folder; the wheel already zooms a photo. **The owner's three choices
  (13 Nov), done**: targetSdk raised to 36 (rotate shortcut and
  orientation settings hidden where Android ignores them: TV, Android 16
  tablets); a media session for every film on a TV (`PlayerMediaSession.kt`:
  a TV's voice commands and Now Playing card reach the player; after the
  release review, a TV's only, and ended while the film is off screen);
  TV text at 1.2. The API 36 device-lab run: done (43420830536, all
  flows passed on Android 16). Left: frame-rate matching.
- **Item 5 done (13 Nov)**: the engine check has a test that drives it
  (and found a resumed stream called stuck — fixed); the gestures help is a
  player sheet (a TV's Tutorial is the remote's keys); the paste bar's hint
  is centred (it sat high in every language: a dense field); the mouse
  wheel over the film is the volume. docs/devices_2026_11.md.

### Player audit (11 Nov) — `docs/player_ux_audit_2026_11.md`
The owner's request: every menu and button of the player, both ways round,
in every language, MX-level. Found and fixed (1.64.82): Back closed the
film over an open menu; no subtitles or audio choice in portrait; holding
Next never opened the repeat menu; Display Settings did nothing; "Track
auto/no" in the audio menu; a 4 s timer leaked per film; the last history
entry lost on close; a dozen layouts cut off in Burmese, sideways or at a
large font. Left open:
1. On purpose, the owner's call: Back while the screen is locked still
   leaves the film (Kids Lock swallows it); the error card shows libmpv's
   own sentence (host only since 1.64.83) under its title; "Online
   subtitles" shares a search link (no url_launcher in the app).
2. Toward MX, by what a viewer here would miss: chapters (libmpv's
   `chapter-list`; local MKVs have them, the catalogue does not); subtitle
   search and download in the app (OpenSubtitles, a key on the server);
   the track playing marked in the menus on the ladder engine (1.64.82
   reads it from libmpv only); cast.
3. How to check a player change: `test/player_layout_test.dart` (1,224
   layouts with LANGS=my,en,th SCALES=1.0,1.3; real fonts from test/fonts
   and the SDK; PLAYER_SHOTS=<dir> photographs them),
   `test/player_controls_test.dart`, and in the device lab
   `layout_portrait player_audit layout_landscape player_audit_land`. The
   controls hide 4 s after a tap and Maestro needs about a second a step:
   a flow acts on freshly shown controls, its two taps 0.8 s apart (closer
   is a double tap: play/pause). A build of main shows the first-run tour
   (layout_portrait skips it); run.sh's rotation line read "now 0" in run
   42993934736 while the screen was 2400x1080 — the UI dump's bounds are
   the truth.

### Streaming without stutter (7 Nov) — `docs/streaming_review_2026_11.md`
The owner's request: no stutter, nothing that annoys a viewer. Evidence:
live events (labs only, real viewers one or two) and the six newest lab
runs. Done on the branch (ships with the next release): ladder stalls,
tap-to-picture (`grant_ms`), failures (`error` codes) and one
`play_summary` per playback (migration 080 live; PlaybackQoe), blips
(< 250 ms) counted apart from stops, and the film in hand at each stop.
Also on the branch (7 Nov, review §5), proved step by step on one shaped
line (4 → 0.9 → 3 Mbit/s, 8 s with none, 0.5 % loss, 120 ms): from 3
stops / 5.9 s frozen (run B') to **none** (run E, 42373118426) by
(a) an unmeasured film opening at 480p on every connection; (b) the
ladder's first frame taken from ExoPlayer, not from libmpv's stop (the
"first picture in 0.2 s" of earlier labs was that artefact; open_ms
before and after this change are not comparable); (c) the start rung
leading the master playlist; (d) ExoPlayer's meter keeping the start rung
until a reading (works since run F, 42381638569: the guess must be made
where the selection is built). The line read during a read (fix 1) stays:
no stop in any run with it; its effect on picture quality is not shown
(A' 3 % at 480p, E 87 %, F with fix 1 3 %: early readings decide it).
Test Lab run 42376634865: all checks passed on both phones, honest first
frame 1.5 s / 3.1 s. **The lab line was never shaped
before 7 Nov** (the runner's bpf filter on eth0 took the ifb redirect's
packets): it now runs through `tool/netlab/line_relay.py` on loopback and
proves its cap first. Next, each proved by an emulator A/B on that line:
1. ~~resume after a stall on 5 s~~ tried, undone: it made blips a visible
   1.26 s stop;
2. ~~climb back only when the slow average clears the higher rung (720 →
   240 → 720 → stall)~~ not seen on the live build, so no rule (14 Nov):
   `test_device/weakline_climbs.py` counts a climb (`exo rung` up) then a
   stop >= 250 ms within 30 s. Device lab 43555903291 (1.64.84 + the lab
   hooks, an A/A of 8 weakline passes): 8 climbs, none followed by a stop;
   H/H2/H3 (32 passes): 61 climbs, one stop after one — 564 ms with 30 s
   in hand, the decoder at a rung change, not the line. Covered by the
   ProxyMeter's min(fast, slow) (a recovery believed once the slow average
   holds) and 5b. That run's pass 1 stopped 14 times (49.6 s), every stop
   with the buffer dry and no climb before it: the runner's line, which
   read 520 kbps under the 4 Mbit/s cap (passes 2-3: 2023-2596) and TCP
   handshakes of 0.5-5.2 s (the cap probe 495 kbps, against ~786);
3. ~~a jump on a slow line takes its first segment from the rung below~~
   (OPPO seek 5.9 s): see 5c, tried and taken out;
4. ~~a dead segment read noticed in 3–4 s~~ dropped down: 8 s with no
   line cost nothing with 26 s in hand (run C); it matters only with a
   nearly empty buffer;
5. two connections for a ladder's reads on a lossy line: one carries
   ~1.5–2 Mbit/s at 0.5 % loss and 120 ms whatever the cap (TCP's own
   limit), less than 720p's peak; costs Worker requests: each read in two
   halves doubles them (an hour of film at 2 MB a read: 720p 360, 480p
   196, 360p 124, 240p 66 requests; the Free plan's 100,000 a day ~510
   viewer-hours at 480p, ~255 with it), and both connections busy at a
   jump would undo 5d (review §5, 11 Nov);
5b. ~~picture quality on a weak line~~ done 8 Nov: a rung is weighed by
   its fastest 20 s, a rung not read by a read rung's ratio
   (`PeakRule.window`; runs H/H2/H3: 480p or better 89 % against 69 %,
   12 pairs of 14, no stop). Left: on a line that falls under the rung in
   hand, the step down lands on 240p where 360p's average fits (ExoPlayer
   defers it to 25 s in hand, then 360p's peak over 0.7 does not fit);
   weighing a deep buffer against the whole line made it worse (`deep`,
   720p in and out). A softer picture, not a stop: low priority;
5c. ~~a jump's first segment from a quick rung~~ tried 9 Nov and taken
   out (runs J, J2, Test Lab 42641532315; review §5): the segment is not
   the wait — the Worker's answer and the phone's restart are; the rule
   saved ~0.2 s and cost a second stop after 23 jumps of 112 against 5.
   The plan as it was written:
   a seek on a ~5 Mbit/s line froze 1.7 s on the realme (first segment
   720p): fix 3 below, for the first segment after a jump only. What the
   trail says (Test Lab 42376634865): the realme's jump fetched a 537,551 B
   720p segment in 1401 ms (answer 380 ms) at ~4.6 Mbit/s and stood 1699 ms;
   the OPPO's same segment at ~30 Mbit/s took 473 ms, frozen 402 ms. A jump
   needs one whole segment (1 s of film to play), so its size is the wait.
   Plan, read in Media3 1.9.2's AdaptiveTrackSelection: on a seek in Auto,
   `SteeredSelection.getSelectedIndex` returns the highest rung whose
   segment arrives in ~0.5 s at the meter's estimate (weight × 2 s /
   estimate), for the first chunk after the jump only; then back to the
   rung before the jump — ExoPlayer's own rule would hold the lower rung
   until 10 s are in hand (minDurationForQualityIncrease), a soft picture
   for 10 s after every jump. Lab: the jumps (`lab_jumps`, LAB check
   frozen=) on the weak line in passes, `lab_jump` on/off alternating;
   then Test Lab on both phones;
5d. a connection kept open for a jump: done 11 Nov, on by default
   (`keepSpare`; runs M1, S1, S2, Test Lab 42982587122 / 42985879375;
   review §5): a ladder's segment reads take turns on two pools, so a jump
   that cuts the read in flight finds the other's connection open — the
   answer, the jump's stop and the first picture 0.30 s sooner over 112
   pairs, no Worker request more. Its follow-up, a pool known lost when a
   read on it ends cut (a jump takes the open one), tried 14 Nov (run L1
   43560088068, 112 jumps, on / lost) and taken out: whenever a jump's
   pool was lost the other was busy or lost too, so the rule had nothing
   to choose (kept 50 against 51 of 56, the answer alike, the stop shorter
   under on in 27 pairs against 20). The pools' state stays in the trail:
   open pools kept their connection in 101 of 102 jumps, lost ones in 0 of
   10 — a read cut since, not the server, closes them;
6. labs to add: ten minutes on a weak line, a link expiring mid-film, a
   low-end and a 32-bit Test Lab phone, two runs per build.
After the release: frozen seconds per minute played, from `play_summary`,
per version and network — the number each step must lower.

### Architecture review, eleven layers (7 Nov) — `docs/architecture.md`
Checked live against a classic web-architecture picture the owner shared.
Most layers are sound (jobs, backups, search for Burmese, rate limits,
security). Found, most urgent first:
1. **Privacy dialog: rewritten, on the branch, ships with the next
   release** (7 Nov). It said "runs entirely offline… sends nothing"; now
   it says what is sent (usage records under the account or a random
   install id, searches included, 90 days then daily totals only; playback;
   reports a user sends), in en/my/th (`app_strings.dart` and the .arb
   files). The dialog scrolls now (test/privacy_dialog_test.dart fails in
   all three languages without it). The owner approved going ahead
   ("ဆက်လုပ်ပါ အကောင်းဆုံး"); the wording can still change before release.
2. **DONE 7 Nov: analytics rollup and 90-day prune run daily.** Migration
   078 `events_housekeeping()` (service role; index on occurred_at), called
   by the ingest house step, ingest **v54** (SHA 261638b). First run 03:46:
   event_daily 35 days, 366 rows, all 2,299 events counted; search_daily
   3 days. Nothing past 90 days yet (first on 22 Dec).
3. **DONE 7 Nov: transport-check on a schedule** (every 6 h asked; on main
   with the next main push, a9fbccb). GitHub e-mails the owner when a
   scheduled run fails: the owner's Actions e-mail is on, failed workflows
   only (screenshot 7 Nov), and the pushes and dispatches act as the
   owner's own account (get_me: yannmh007), so the e-mail reaches the owner.
   Watch: the first scheduled run on main is green.
4. **DONE 7 Nov: restore drill, weekly.** Migration 079 (verified_at,
   verify_error on db_backups; backup_verify_due, backup_verified), ingest
   **v55** (SHA 0dfe2a5): the newest backup is read back, hash-checked,
   unsealed, un-gzipped, parsed and counted per table, in the function;
   a failure goes to the owner on Telegram and is retried daily. First
   drill 03:52: backup #47 (sealed), 50 tables, passed. Still by hand: a
   full restore into an empty database.
   **Checked 12 Nov (items 2–4):** event_daily runs to 11 Nov (the daily
   rollup is alive); transport-check ran 12 times on its schedule since
   7 Nov, all green (latest 43174698705, 12 Nov 07:21); the drill last
   passed 7 Nov 03:52 on backup #47, no error since — within the week,
   backups #48–#52 waiting for the next weekly drill.
5. **DONE 13 Nov: DNSSEC Active.** The owner's screenshot (Cloudflare →
   DNS → Settings): "Success! innocentplayer.com is protected with DNSSEC",
   DS key tag 2371, algorithm 13, digest type 2. Enabled 7 Nov; the DS took
   under six days. Never press Disable DNSSEC or Cancel Setup. CAA: none, and none wanted (`docs/architecture.md`, layer 1).
6. When the catalogue reaches thousands of titles: `search_titles`' fuzzy
   half as `needle <% search_text` with `pg_trgm.word_similarity_threshold
   = 0.45` set on the function (EXPLAIN: Seq Scan today, Bitmap Index Scan
   so); and a short public Worker cache for landing and row RPCs when they
   load the database. Not before.

### Next app release (after 1.64.82)
- **A film that "plays" and does not move after a jump (found 14 Nov from
  the owner's report on 1.64.84; SHIPPED in 1.64.85, 14 Nov)**: a seek-bar drag opens a scrub (`beginScrub`), and on the ladder
  that puts ExoPlayer in scrubbing mode (playWhenReady true, playback
  suppressed). The bar is in the tree only while the controls are up
  (`_chromeUp`), and the auto-hide (4 s) did not wait for a finger: a thumb
  held still on the bar's picture lost its bar, onChangeEnd never came, the
  jump was not made and scrubbing mode stayed on — the film still, the
  pause button dead, until another drag closed it. Seen in the owner's two
  diagnostics reports (14 Nov 08:26 and 08:30 UTC): after a jump to the
  middle, every seek drew its frame in 89-189 ms and buffered ~200 ms,
  `wakelock playing=true`, yet the decoder thread (MediaCodec_loop) was
  idle for ~80 s while ExoPlayer's playback thread ran; no network
  error, no stall. Fixed four ways (test/player_scrub_test.dart: 4 tests,
  all four fail on 1.64.84's code): the auto-hide waits while a scrub is
  open; the seek bar ends its scrub in `dispose`; play / pause closes a
  scrub left open (on ExoPlayer the press then lets the film move, without
  toggling); a swipe-seek's end always closes its scrub (it refused any
  lock while its start let the rotation lock through). And the trail now
  says a hold: ExoPlayer sends `held` (its suppression, put down to
  scrubbing when that is on) and the app writes `exo held N ms (why) at
  Ns` for a hold of 1 s or more (ladder_landing_test). PROVED: Build
  43577691274 on 655956b1 green (Kotlin, Analyze, Test, both APKs);
  device lab gate 43580674281 jumps on Big Buck Bunny 15 of 15 (seek,
  swipe-120, far-jump, landing; no `exo held`, as no drag is in the flow).
  Its first run 43577875824 never began — "the film never started", seven
  segment reads stalled 8 s, the lab's own engine check timed out: the
  runner's line, as W1's pass 1 (the morning gate's same setup: 15 of 15).
- **One play at a time (found 14 Nov in the same reports; SHIPPED in
  1.64.85, 14 Nov)**: two taps on a Continue watching card 1.4 s apart
  (the grant took 1.85 s, nothing on screen yet) opened two players over
  each other: two `card_click`, two `play_start`, the second player's
  ExoPlayer open failed and it fell back to libmpv ("ladder on ExoPlayer
  failed: the start rung on libmpv"), and the playback's `play_summary`
  went out twice (both screens read the one controller). `playMedia` now
  refuses a second tap while the first is on its way (`PlayTapGuard`, at
  most 10 s, so a stuck play never blocks the next; a paywall's own retry
  goes past it). test/play_tap_guard_test.dart. Build 43585867675 on
  1ff7566e (both fixes, the whole branch) green: Analyze, Test, both APKs.
- **Open from the same reports — both addressed 15 Nov on the branch
  (refusals now say why; the summary kept until it has gone)**: (1) the next
  film after the double open (a different one, one tap) also fell back to
  libmpv at once — ExoPlayer's open answered false within the same tenth
  of a second; the trail cannot say why (logcat holds the engine's side):
  read it on a phone, or make the engine's refusal say its reason in the
  trail. (2) The stuck playback's own `play_summary` never arrived (closed
  08:18:57 UTC; 1 of the session's 4 playbacks reported, twice): the
  summary is queued in memory and its kept copy dropped at once
  (`reportSummary` → `dropStash`); a batch whose send fails is dropped by
  design. Keep the copy until a send is known to have gone.
- **Added on the branch 14 Nov, for the next release (no change in what
  the app does)**: each pool's state in a jump's trail — `_PoolUse.lost`
  (how its last read ended: cut, hung up, short, stalled, failed), `hls
  jump: … pool N, <state>, the other <state>, …`, and `state=` / `other=`
  in `jumpCostAfter`'s words. Ships as it is. No new lab hook: the
  `lost` rule (`poolLost`, the lab word, Test Lab's alternation of it) was
  taken out on the branch before anything else was built on it.
  `test_device/weakline_climbs.py` and the weakjumps summary's state
  columns are the lab's. Proof: stream_cache_hls_test 19 of 19 (the new
  hang-up test 6 of 6 under a loaded CPU and disk; its first form failed
  Stream bench 43560088035 and 2 of 5 here, fixed in ca13b326), the
  branch's 1753 Flutter tests here on the final code, Stream bench
  43567588464's Analyze and Unit tests green on it, the gate 43567588467
  (jumps 15 of 15).
- **1.64.82 is out** (11 Nov, main 72b20dd, build 42996818415; arm64
  95628676 bytes `dee484cc…de28`, arm32 87598952 bytes `907e8350…3929`;
  GitHub's asset digests agree; app_releases moved at 10:23 UTC after a
  rolled-back dry run, mirrors on the GitHub release). The player audit
  only, on main 1.64.81: 357dfb9a, then 72b20dd adding the lab's player
  flows. Proved before the push: the release tree's 1663 Flutter tests and
  check.py; its Build 42986335820; device lab 42986323922 (plain: genres,
  jumps 15/15); Test Lab 42986497192, the realme alone, 16/16 (one phone:
  this branch's Test Lab had two of the day's five); device lab 42996379027,
  the player flows in both orientations (Back closes ⋮ and the subtitle
  panel with the film still playing; audio and subtitles on the portrait
  top bar; holding Next opens the repeat menu). After it: Pages, Dependency
  scan and CodeQL green; Playback check 43024797061 passed on main. The CDN copy
  cannot be fetched from the sandbox (its host is blocked there); the
  Build's CDN step passed. **The next release from this branch keeps**
  `test_device/flows/player_audit*.yaml` and layout_portrait's tour skip
  (brought here with this record, `[skip ci]`, so the device lab did not
  start under this branch's own runs).
- **Added on the branch 11 Nov, for the next release**: 5d, a connection
  kept open for a jump (`StreamCacheServer.keepSpare`, on; a second pool
  per ladder, `_Ladder.spare`); a jump's answer in parts in the trail
  (`hls jump: … conn new|kept …, wait …`); `play_summary` kept on the phone
  when the app goes to the background mid-playback and sent at the next
  start (`PlaybackReporter.stashSummary` / `sendStashed`, EventSender
  `build` + `enqueue`). Leave out the 11 Nov lab hooks listed in §0
  (`jumpRule`, the Test Lab `keepSpare` line, `alternate` /
  `spareForJumps`, `_labTimedConnect`). Proof so far: device lab M1, S1,
  S2 and the gate (15 of 15), Test Lab 16 of 16 on both phones, the
  branch's 1671 Flutter tests here (the player audit's with them).
- **1.64.81 is out** (8 Nov, main 96d504c, build 42477027297; arm64
  95615240 bytes `44c1ef3d…128a`, arm32 87579964 bytes `66cd8824…5e35`;
  GitHub's asset digests agree; app_releases moved after a rolled-back dry
  run, mirrors on the GitHub release). Proved before the push: device lab
  42465757907 (plain: genres, jumps 15/15), Test Lab 42461966293 (15/15 on
  both phones), the branch's Build 42465763590, the release tree's 1288
  Flutter tests. After it: Playback check 42479026804 passed, Pages
  published, Static analysis green. Left out by design: the Google sign-in
  nonce and the lab hooks, as for 1.64.80. **GitHub's release downloads
  failed (504) for about two hours that day**: the lab and branch builds
  needed four tries, and the Dependency scan on main (42477027283) failed
  on the Gradle download, not on a finding (green on the third try); a release push is safest when a full download of the libmpv jar
  succeeds three times in a row (the CDN step publishes before the GitHub
  release, and a half-published version cannot be rebuilt the same).
- **1.64.80 is out** (6 Nov 14:20 UTC, main 0202f0a, build 42226206227,
  arm64 95609920 bytes `a519403d…8569`, arm32 87572232 bytes
  `a3dd686f…4ee0`; GitHub's digests agree; app_releases moved at 14:20,
  mirrors on the GitHub release). After the push: Playback check
  42226785108 passed, both Workers rebuilt from main (13:32), Pages
  published, the transcode and ingest runners on main claim with
  `seals: 1`. Static analysis on main went red once (42226206270): the two
  fake JWTs in `tool/js/service_key_test.mjs`, fixed on the branch
  (06c70cc); it reaches main with the next release, not before, since a
  change under tool/ rebuilds 1.64.80 for nothing.
- **Main red twice after the Claude-setup pushes (6 Nov), both fixed on
  main the same evening; 1.64.80 rebuilt, nothing uploaded.**
  (a) Static analysis 42258949696: `tool/claude_hooks_test.py` ran a hook
  by a path from a variable; now a literal command per hook. The fake
  JWTs (06c70cc) went with it. (b) Build 42255981825: one Flutter test,
  `stream_cache_hls_test` "asked a few times, not 90": 12 Worker reads
  where 8 do. A REAL BUG, timing-dependent: a film has one cache writer at
  a time, and a segment read that began while the last read's writer was
  still closing got none — its 2 MB reached the player but not the cache,
  so the next segments were read from the Worker again (bytes read twice,
  Worker requests spent). Reproduced here under CPU+disk load (4 runs in
  10); the read now waits for that close, alongside the Worker's answer,
  at most 1 s: 0 in 16. Also one metadata save per film at a time (two
  shared `meta.json.tmp`). Reaches phones with the next release.
- 1.64.80 carries Report on every title and the
  takedown address in About (P6), genres by code in the phone's language
  (TAX phase 3), the media seal's app half (the opener, the device key, the
  unseal gateway, sealed images) DORMANT — the build asks for no sealed
  copy (docs/MEDIA_ENCRYPTION.md §9 step A) — the key attestation code
  (sent only by a build that asks), and the deprecated-API renames
  (d709830). The console, its edge modules and the runners' sealing code
  reach main with it.
- **Left out of 1.64.80, by design**: the Google sign-in nonce (29b71b2,
  `api_account_repository.dart`, its test) and the lab's own hooks
  (`lib/app.dart` tour skip, `rungKbps`, `ladderRungKbps`).
- **Google sign-in nonce (29b71b2)** waits on the branch: no lab can sign in
  with Google. Before it ships, the owner signs in once with a build that
  carries it (a branch build's APK); if Google refuses the token, it stays out.
- **A release that asks for sealed copies** (§9 step C needs one as
  `min_supported`) waits for §8's gates: proxy CPU per MB and frozen time.
  R8 (attestation `app: ok`) can only be read from such a build.
- **The OPPO's Original on a borderline line** (Test Lab 41047246611): the
  10 Mbit/s Original stalled 8 s on a 4-14 Mbit/s line. The lab only skips
  it when the line is measured below the copy's bitrate; a line that swings
  around it fails. Not a regression; worth a look at how the Original's
  first fill sizes itself.

### Open test films, five more (6 Nov)
- **Approved** (all five `approved`, read 8 Nov); seeded 6 Nov 15:49 (seed run 42246218584, ingest
  v53): Cosmos Laundromat (12 min, 1920x804 2.39:1, dialogue), Caminandes:
  Llamigos (2.5 min, 1080p), Glass Half (3 min, 1080p, dialogue), Hero
  (4 min, 2D Grease Pencil, 1280x536 23.976 fps) and Big Buck Bunny (60 fps)
  (10.6 min, 1080p60, 5.1 sound). Free, C01, genre G001 (Open Movie), five
  stills each, the first as the poster. Not in the app until approved.
- **How they were chosen**: `tool/open_films.py find` (run 42240921914)
  read each candidate's licence from video.blender.org's API, from a
  runner. Only CC BY or CC0 is taken: Spring is CC BY-SA there, Coffee Run,
  Charge, Wing It and Caminandes 2 state no licence, Agent 327's file is CC
  BY-ND (studio.blender.org says so too). The seed reads the licence again,
  downloads, and checks the file is that film (H.264 at the height picked,
  sound, the length to 3 s; dry run 42243911348). Each synopsis carries the
  CC BY attribution and the source page.
- **The owner, in the console** (Review, "waiting for approval"): open each,
  play the preview, look at the stills and pick a cover, add a Burmese title
  or Animation if wanted, then Approve (or Send back with a note, to try
  that path). Cosmos Laundromat's story is a sheep who has lost the will to
  live: decide whether it belongs before approving it.
- **Then**: the transcode ladder (queued at seed; Cosmos running at 15:54),
  frames (done for all five), Playback check, and a device lab run on Big
  Buck Bunny (60 fps) and Cosmos Laundromat once approved. Note for the
  `genres` lab flow: it asserts Animation lists Sintel; five more animated
  titles in Animation may push Sintel off the first screen.
- **Found on the way, fixed**: migration 077 (live) — the service role could
  not read genres (the console's Genres section, every genre change, and a
  title made with genre words had failed since 31 Oct) nor asset_renditions
  (three silent reads). `tool/sql/service_role_grants_test.sql`,
  `tool/function_tables.py`.

### Verify what is live but not yet exercised
- **R8 — key attestation, real chains**: SEEN 6 Nov on the emulator
  (software, unknown root) and on Test Lab's realme (google-ec, TEE,
  verified, locked) and OPPO (google-rsa, TEE, verified, locked), key and
  challenge matching, revocation list read; only `app` failed, which is
  right for a debug-signed lab build. Left: the first RELEASE build that
  asks for sealed copies must read `ok: true` (`app: ok`) on a real phone,
  in the function log and in `devices.attest`, before anything is
  enforced. 1.64.80 asks for none, so it sends no chain.
- **R7 — the new Supabase keys, first real calls** (since 6 Nov): studio
  (the console), premium-request, delete-account, probe-media,
  backfill-dimensions, self-test. In the logs, each boot says `service:
  SUPABASE_SECRET_KEYS.default` and the calls are not 5xx. Also, in the
  gateway logs (edge_logs, `request.sb.jwt.apikey.payload.role`), no
  `service_role` or `anon` legacy JWT after 6 Nov 02:40 UTC, before the
  owner deactivates the legacy keys.
  **12 Nov, quiet:** the gateway's 325 requests in 24 h all carried a new
  key (94 publishable, 231 secret), none a legacy JWT as apikey; Bearer
  tokens were users' sessions only (`authenticated`, signed ES256 — the
  asymmetric signing key is in use); no 5xx. The two 401s were the
  transport check asking `/rest/v1/` with the publishable key on purpose
  ("Secret API key required": the schema stays unlisted). Every boot of
  ingest, transcode and request-playback says
  `SUPABASE_SECRET_KEYS.default`. Studio on the new key: five
  `reviewApprove` in admin_audit on 6 Nov 16:22. Not yet seen in a log:
  premium-request, delete-account, probe-media, backfill-dimensions,
  self-test (no calls since). Every app version seen in 30 days is
  1.64.69 or later, all on the publishable key (since 3 Oct). So the
  owner can deactivate the legacy keys (dashboard → Settings → API Keys →
  Legacy API keys; reversible).
  **DONE 13 Nov: the owner disabled the JWT-based API keys (~09:50 UTC).**
  Checked before: all nine functions pick the new key first
  (`prefer: 'new'`), no workflow, Worker or console holds a legacy key, no
  pg_cron / pg_net calls out of the database. After: ingest dispatched on
  main green (43404807961), transport check green (43404811682), the
  gateway since 09:50 all 200/204 but the transport check's deliberate
  `/rest/v1/` 401, no request with a legacy key. Undo, if ever needed: the
  same page, Re-enable.
- **Sealed payment fields (migration 054, premium-request v15)**: the first
  sealed request (1ccbfbc5) is in, phone sealed and masked, no plain numbers
  anywhere. Still to see: the console's Requests page opening it (the number
  in full, not "(sealed — the key does not open it)"), and a request WITH a
  transaction number, to exercise the HMAC index and the reused-number check.
  Reject 1ccbfbc5 if it was a test.
- **Opaque R2 keys (studio v43, R2_NAMING_KEY)**: after the release reaches
  Pages, make a test title from New with folder `test-naming`: keys must be
  `f/<20 hex>/<kind>/<32 hex>.<ext>`, the Files page must show "test-naming".
  Delete the test title after.

### Security — done 30 Oct, to see working
- **Database backup sealed** (7d3b3d9, ingest v38, migration 055): new backups
  are `….json.gz.sealed`; the sixteen older ones are sealed a few per runner
  tick (`house.resealed` in the tick's answer). Check after a day:
  `select count(*) from db_backups where deleted_at is null and object_key not
  like '%.sealed'` is 0, and Status → Download still gives a .json.gz that
  `tool/restore_backup.py --list` reads. The owner keeps a copy of
  PII_ENC_KEY outside Supabase (RUNBOOK part 4) — without it a lost project's
  off-site backups do not open.
- **B2 keeps deleted files as hidden versions** unless the bucket's Lifecycle
  is "Keep only the last version". Until the owner sets that, the plain
  backups deleted off-site (and every pruned one) are still in B2 as hidden
  versions. Owner, once: B2 → Buckets → the private bucket → Lifecycle
  Settings → Keep only the last version of the file.
- **Payment screenshots sealed** (migration 056): new receipts are
  `<user>/<request>.sealed`; the console's `proofs` opens them (data:
  pictures, a few MB per answer, `more` for the rest). Receipts filed before
  stay as images. A copy also goes to the owner's Telegram chat as before.
- **Telegram ingest file names**: with R2_NAMING_KEY, a forwarded file's key
  is `<folder>/<kind>/<32 hex>.<ext>` — the Telegram file name is no longer in
  it. Check with the next forwarded file.
- **studio.ts `requests` op** removed (unused; inbox goes through
  premium-request).
- **Google sign-in nonce** (29b71b2) and **Transfer** limits (55a89e3): in the
  app, ship with 1.64.78. The nonce needs one real Google sign-in on the
  owner's phone before release.

### Telegram ingest: ten at once (built 30 Oct, live with the next push to main)
- ingest.yml opens lanes 1..(waiting + busy), at most INGEST_LANES (repository
  variable, 10 when unset; 1 = the old one-at-a-time). Migration 057 (queue
  depth, a lock per title for an album's places) and ingest v40 (`depth`) are
  already live; the workflow takes effect only on main.
- First real test: forward 3-10 licensed films at once; watch that lanes sign
  in 20 s apart, no FLOOD_WAIT deferrals pile up, every file lands, and the
  console's folder shows them in Telegram order.
- **Next bottleneck: transcode is one film at a time** (`concurrency:
  transcode`). Ten films in at once are ten ladders in a row. Its claim is
  already per file; two or three lanes the same way would fit inside the 20
  jobs a free account runs. Decide after the first real batch.
- Telegram may throttle one bot's parallel downloads; a long FLOOD_WAIT
  defers the file (not a failure) and the next run takes it.

### Security, next
- **Review of 5 Nov 2026: `docs/security_review_2026_11.md`** — findings
  S1-S10, plan P1-P7. Carry these until each is done:
  - **S1/P1 — DEADLINE 31 Dec 2026**: every function on the new secret
    key since 6 Nov (39daef0; canary transcode v26, then ingest v49,
    request-playback v42, studio v50, probe-media v25,
    backfill-dimensions v28, self-test v30, premium-request v18,
    delete-account v7). Owner, no code: asymmetric JWT signing keys; then,
    after a quiet week in the gateway logs, deactivate the legacy anon and
    service_role keys; then delete the Edge secret `SB_SERVICE_KEY` (legacy
    JWT, no longer read).
  - **S2/P2**: ENC rollout A→F; every film and photo is still plain in R2.
  - **S3/P3**: key attestation BUILT 6 Nov, log mode (6a87482:
    key_attest.js, request-playback v43, migration 074, app key v2 in
    1.64.80, sent only by a build that asks for sealed copies). Next: R8 (real chains), then P3b (the stream token
    wrapped for the attested key, so a plain grant needs the phone too),
    then `require` for premium. The owner is told in Telegram when one
    install/account/network pulls far more than a person (migration 075,
    ingest v50, refuses nothing). A lower cap waits for that data: today
    it would be a guess (4 titles; busiest install 2 titles a day). Bytes
    per account need a Worker counter and a Cloudflare token to read it.
  - **S4/P4**: BUILT 6 Nov (docs/console, console_origins.js live in studio
    v51, ingest v52, transcode v27, probe-media v26; the stream Worker's
    origin on the branch; console_build_test.mjs 20 checks). ON MAIN 6 Nov
    (b6fc0d0: docs/console and the stream Worker's origin; docs only, no
    build; Playback check 42208213495 passed after). ON 6 Nov: the owner
    did the four steps (Worker `innocent-console` built from the repo,
    workers.dev off; the WAF rules were already limited to `stream.`;
    Supabase redirect URL added; signed in, Dashboard loads; Transport
    check 42211630577 section 9: headers live, no docs/ served). Retire the
    Pages copy after a week of use (from 13 Nov): docs/console/README.md
    "Afterwards".
  - **S5/P5 (owner)**: passkeys on GitHub, Cloudflare, Supabase and Google;
    Telegram 2-step; a fine-grained, expiring `GH_DISPATCH_TOKEN`; a `main`
    ruleset; secret scanning with push protection; Dependabot; CodeQL.
  - **S7/P6**: BUILT 6 Nov — takedown address innocentmail69@gmail.com in
    About, Report on every title (both in 1.64.80), migration 076 live (budget
    5/phone/day, owner told in Telegram by ingest v51). Left: a Reports page
    in the console; the owner keeps a rights record per title. Hiding the
    host from abuse reports is NOT a goal (§0).
  - **S8-S10/P7**: S8 closed 6 Nov (transport check section 8: `/rest/v1/`
    answers the publishable key 401; run 42177384203). S10 accepted with its
    reason (review P7). Owner: Data API → turn off auto-expose of new
    tables; Files → Scan (R2).
- **Telegram ingest FOLDERS still plain**: the folder segment is what the
  operator typed (`spider-man/video/…`). Making it `f/<20 hex>` like console
  uploads means every place that takes a folder as the key's first segment
  learns the two-segment form and the label table: enqueue_ingest's album
  inheritance and inbox move (033), bot_folder_stats / bot_folders_recent /
  bot_retry_folder / the /folder session match (033), attach_ingest_folder
  (024), review.js's grouping, and the bot's replies (labels, not hashes). One
  migration with a `key_folder(text)` helper used in all of them, and
  ingest.ts translating names both ways. Test with the bot end to end (a
  /folder session, an album with the caption on the third file, /retry).
- ~~**Old payment screenshots**~~: done 31 Oct. ingest v41 seals a receipt
  sent before sealing where it lies on the house tick (sealed copy, then the
  plain one deleted, then the request repointed); the one plain receipt is
  sealed, the bucket holds no plain file (`proof_reseal_test.mjs`).
### Categories and genres by code (TAX, the owner's request of 31 Oct)
- [x] Phase 1, the database (058, live 31 Oct): categories C00-C03, genres
  G001-G003 in their own table, titles carry `category_code` and
  `genre_codes`; the old text follows the codes by trigger, so every app in
  the field works unchanged (checked as anon); `taxonomy()` gives the words
  for every code in three languages; search finds a genre in Burmese and
  Thai. `tool/sql/taxonomy_test.sql` (codes never reused or changed, a
  genre in use not deleted, retire, merge).
- [x] Phase 2, the console (31 Oct): studio v46 (genre ops by code, 059's
  `genre_move` and `genre_usage`), the Genres section (add, rename,
  translate, move, offer, retire, merge, delete an unused one), category
  codes and Thai names, the editor choosing genres as chips. On main
  (`25d0fca`, docs only). Left: the ingest by code (it sends words, which
  the trigger maps). `tool/js/console_smoke.mjs` reached main with
  1.64.80.
- [x] Phase 3, the app (branch `e72b278`, released in 1.64.80):
  `rpc/taxonomy` once for tabs and names, a category asked by its code, genre
  filters by code, names in the phone's language, never a raw code on
  screen. 23 tests; full suite 1235 of 1235. Device lab on the live
  catalogue: run 41186616962 caught the filter sheet drawing "G001 G002
  G003" (it read the names before they had arrived; be7169a: the facets
  carry their names), run 41188669198 passed (names, Animation lists Sintel
  and not Tears of Steel, no code on any screen). Test Lab with the release.
- [ ] Phase 4, once no app that reads the old text is left: drop
  `titles.category` and `titles.genres` (and `categories.id` as the key).

### Media encryption (ENC, the owner's request of 31 Oct; spec docs/MEDIA_ENCRYPTION.md)

#### ENC checks with a date — LOOK AGAIN ON THE DAY (recorded 5 Nov)
Things that are live and believed right, but whose proof comes later. Each
says when, exactly what to run, and what counts as right. Tick it with the
evidence; if it is wrong, it becomes an open item below.

- [x] **DONE 12 Nov: all twelve purged at 17:17:45 UTC, no error; BBB still
  2 rung keys and 10 still keys.** They were due 12:42-12:43, but the
  ingest runner (which empties the bin on every run) had last run at 11:31
  and schedules run hours late, so ingest was dispatched on main by hand
  (run 43267844479, green). The "3 of 3 copies sealed" check waits for the
  next sealed lab run on BBB.
  **R1 — 12 Nov, after 12:43 UTC: the bin deletes the twelve replaced
  twins of Big Buck Bunny** (2 rungs, 10 stills, binned by run 42029250311).
  `select key, purged_at, purge_error from r2_trash where reason like
  'sealed copy replaced%'` → every row purged, no error. Then BBB still has
  exactly one key row per rung and per still (`media_keys` plain_key
  `video/open-film-big-buck-bunny/master-%p.mp4` → 2; `media_image_keys`
  plain_key `…/thumb/master-f0%.jpg` → 10), and the next sealed lab run
  on BBB still says "3 of 3 copies sealed".
- [ ] **R2 — after the owner's next Files → Scan: folder `s`.** Every
  `s/` object shows "sealed copy" with its title, except O14's orphan
  (the only one unused). Bin that one. `select count(*) from r2_inventory
  i where key like 's/%' and not exists (select 1 from r2_refs() r where
  r.key = i.key)` → 1 before, 0 after.
- [x] **CLOSED 12 Nov: the last day was clean.** Over the logs' 24 h
  (to 17:15 UTC): no "seal refused", "settle failed" or MEDIA_KEK message,
  no error-level function log, every function call 200 (ingest 14,
  request-playback 24, transcode 8); studio, probe-media and
  backfill-dimensions were not called in that window.
  **R3 — daily until 12 Nov: the pipelines' function logs.** No
  "seal refused", "settle failed", "MEDIA_KEK unreadable", and no 5xx from
  `transcode`, `ingest`, `studio`, `probe-media` or `backfill-dimensions`
  (`function_logs` / `function_edge_logs`). Live versions (5 Nov): transcode
  v25 (209f5e1), ingest v48 (1058fd5), studio v49 (6ecba09), probe-media v24
  and backfill-dimensions v27 (ac29482); migrations through 073.
- [ ] **R4 — at the start of every session: the switch is `off`.** (12 Nov: off.)
  `select seal_new from admin_settings` → `off`, unless a canary is running
  that session. A switch left on hands open films to the branch runner
  only.
- [ ] **R5 — after every migration that touches r2_refs, a claim, or a
  key table:** tool/sql/media_keys_test.sql, video_frames_test.sql and
  storage_test.sql, each in its rolled-back transaction on the live
  database, end on their PASSED message.
- [ ] **R6 — when ENC-4 reaches main:** every claim arrives with
  `seals: 1` / `can: [..., "seal"]` (O17), and the device lab and Test Lab
  settings are put back (O12).

#### ENC open items — NOT CERTAIN OR NOT FINISHED (recorded 5 Nov; keep until each is closed)
Each: what is known, why it is open, the next step, and when it is done.
Nothing here may be dropped silently: close it with its evidence, or move it.

- [ ] **O1 Proxy CPU per MB (§8 gate NOT met).** proxy_cpu_bench
  BENCH_MEDIA_SEAL=1: 75 ms/MB against 66-69 for the sealed cache alone
  (+7-10, desktop). The codec is 0.25 ms/MB of it, a plain loopback relay
  3-6 — most is the gateway→proxy loopback HTTP hop. Phones: main thread
  realme 7 % (plain 12), OPPO 11 % (plain 4) — lines differed. Next: a
  like-for-like phone run (O2); if the main thread is higher there, route
  the gateway into the proxy in-process (no loopback hop). Done: bench and
  phone within the plain figures, or the owner accepts the cost.
- [ ] **O2 Frozen time not shown like-for-like (§8 gate open).** OPPO sealed
  froze longer (seek 2.4 s vs 0.7, back to Auto 7.1 vs 1.1, far jump 2.0 vs
  0.8) on a line a third as fast; the realme froze less everywhere; device
  lab seek/far jump about +0.5-1 s over plain runs. Next: plain and sealed
  lab builds back to back on the same phone in the same hour (2 Test Lab
  runs each phone), and the same in the device lab. Done: sealed not longer
  than plain on the same line.
- [ ] **O3 Worker answers slow for sealed twins.** 400-850 ms even on a
  reused connection (run 41988997290), plain 250-900. Thought: R2 keeps the
  much-read plain copies hot, the new twins are cold. Not proven. Next: a
  probe from one runner timing plain and sealed objects of the same film,
  ten each, cold and repeated. Done: the cause named, with numbers.
- [ ] **O4 Many new connections.** 31 Worker answers on new connections in
  one lab session after the pool fix (each cut connection is gone). Next:
  count fetches against new connections in the trail; consider keeping a
  part nearly done instead of cutting (as the proxy's finish-below does).
  Done: new connections only where a cut made them unavoidable.
- [ ] **O5 Album photos not seen opening on a device.** The lab flow
  sealed_images reached the hub and Sintel's page (posters opened, none
  refused) but not the album cell ("1 of N" not found by its scroll). Next:
  loosen the flow (scroll, regex), and log every photo open in lab builds.
  Done: a photo and its next one opened in the viewer, in the trail.
- [ ] **O6 Downloads not measured sealed (§8 gate open).** Sealed downloads
  pass the unit tests only. Next: the downloads flow in the device lab on a
  sealed build, speed and CPU against a plain run. Done: not slower, not
  heavier.
- [ ] **O7 32-bit phone not tried (§8 gate open).** "opens ≥ 20× its
  bitrate" never run. Next: DEVICES32 in Test Lab with MEDIA_SEAL=1. Done:
  a 32-bit phone plays the sealed film.
- [ ] **O8 Corrupt segment only tested off-device (§8).** Next: a lab
  switch that flips a byte in the gateway's input once. Done: refetched once,
  then a clear error, no crash, on a device.
- [x] **O9 Seek-bar preview pictures — not R2 objects (corrected 5 Nov).**
  The phone takes them from the smallest rung through the gateway
  (media_kit_player_service ladderPreview); the lab's preview-far, -again
  and -next passed on every sealed run (e.g. 42013700193). What the
  pipelines DO make as images — the cover picker's ten stills
  (tool/frames.py) and thumbnails — are in ENC-4 §7.3.
- [ ] **O10 Image keys are in the database in the clear (decided, recorded).**
  A poster's or photo's DEK is in media_image_keys (no app role reads it),
  so a database dump together with the bucket opens the images; a film
  needs MEDIA_KEK as well. Accepted for images in the spec (§5). Revisit
  only if the owner wants images to need the KEK too.
- [ ] **O11 Lessons to turn into checks.** (a) A migration touching a view
  must be dry-run AS anon and AS authenticated (063's six minutes). (b)
  tool/check.py before every push (238d7a4 went out with ingest_test red).
  Next: a tool that runs a migration in a rolled-back transaction under
  each app role and compares the catalogue reads. Done: in tool/check.py or
  the runbook.
- [ ] **O12 Lab settings to put back.** test_device/config.env and
  cloud.env carry MEDIA_SEAL=1 and FLOWS="sealed_images jumps", and
  config.env JUMPS_TITLE=Big Buck Bunny (5 Nov, the pipeline's sealed
  rungs); main must never carry them. Put back when the seal labs end.
- [ ] **O13 Plain copies of the canary stay in R2** until ENC-5 removes
  them after the forced update; until then a plain URL still opens them.
- [ ] **O14 One orphan sealed still from the first canary (5 Nov).** Run
  42025083706's tenth still (`s/715c6125…`, Big Buck Bunny f00) was
  uploaded, then refused (409: the still already had a twin), before 069
  replaced stale twins and binned refusals. No row names it, so the next
  Files → Scan lists it in folder `s` as unused. Next: after the scan, bin
  it from the Files page (the only `s/` object with no key row). Done: in
  the bin, then purged.
- [ ] **O15 Pipelines settle twins; the twin job and the console do not
  yet.** 069/070 keep transcode's rungs and stills in step with their
  twins. A plain object rewritten by anything else (the console's upload
  into an existing key, a file manager move, a restore from Telegram)
  leaves its twin stale or misnamed. Next: §7.4 steps 3-5 call
  media_key_put / media_keys_settle, and the move rewrites `plain_key`.
  Done: every writer named in §7.3 does.
- [ ] **O16 Sealed downloads and replaced twins.** A replaced twin's
  sealed copy is purged after a week. A phone that downloaded the old
  sealed rung keeps its own copy and key, so offline play is unaffected;
  but nothing yet renews such a download's grant. Next: decide with O6
  (sealed downloads) whether an offline copy outlives its key row. Done:
  the rule written in §6 and tested.
- [ ] **O18 Off-site copy of a born-sealed master from Telegram.** The
  off-site job reads R2 when R2 has the file and the Telegram copy when it
  does not. For a master born sealed (`on`) and moved to Telegram, that
  copy is PLAIN, so the off-site bucket would get plain bytes. Next: when
  `on` nears, either seal it on the runner under the master's own key row
  (kept while the Telegram copy is the master's) or copy only from R2.
  Done: no plain byte in the off-site bucket for a sealed master.
- [ ] **O19 Telegram pipeline not yet run for real.** Built and tested
  against a fake Telegram and a rolled-back database (§7.4 step 3); no
  open film comes through Telegram, so the first real run is with the
  switch `on`. Next: before `on`, one forwarded test file with the switch
  at `on` for a minute (born sealed end to end: ingest, attach, play),
  then back to `off`. Done: that file plays sealed on a phone.
- [ ] **O20 Console sealing not yet run live.** Built and tested in
  Chromium against a fake studio and R2 (§7.4 step 4). The console with
  sealing is on main since 1.64.80 (Pages and console.innocentplayer.com),
  so the live canary can run: then,
  with the switch at `canary` for a minute, upload one photo into an open
  film's album from a phone (a twin: plain + sealed, the key row from
  media_upload_keys), check it in media_image_keys and in the app, and put
  the switch back. Also then: a 40 MB file with the switch `on` for a
  minute, killed mid-upload and resumed (sealResume once, only the missing
  parts sent), then deleted. Done: both on the live console, from a phone.
- [ ] **O21 Photos that are not JPEG keep their metadata.** jpeg_clean.js
  cleans JPEG (what phones send by default) and refuses a JPEG it cannot
  walk; PNG, WebP and HEIC go as they are, with a warning in the upload
  row. HEIC can carry GPS. Next: decide — convert HEIC/WebP to JPEG in the
  browser (re-encode), or strip their metadata blocks, or refuse them.
  Done: no photo format reaches the public bucket with a location.
- [ ] **O22 Sealing speed on a phone not measured.** WebCrypto seals each
  16 MiB part as 256 AES-GCM segments; on a desktop this is far faster
  than any uplink. Next: time a 500 MB sealed upload from the operator's
  phone against a plain one. Done: sealing adds under 10 % to the upload,
  or the part is sealed in a Worker thread.
- [ ] **O23 Pending upload keys and abandoned sealed objects.** A sealed
  single-PUT object whose `sealCommit` never came (the tab died after the
  PUT, before the commit) is in R2 with no key row; its pending key stays
  in media_upload_keys for eight days, then goes. The Files page lists the
  object as unused after a scan. Next: the bin's housekeeping bins `s/`
  objects named by an expired pending key. Done: none left after a week.
- [ ] **O24 The console's sealed preview not seen live.** Built and
  tested in Chromium against stand-ins (§7.4 step 8). Live it needs: the
  console from main (there since 1.64.80), and the streaming Worker answering the
  console's origin with CORS for ranges (it does today, for the speed test:
  `STUDIO_ORIGINS`, Content-Range exposed). Next: with a sealed film and a
  sealed photo in a draft (O20's canary), preview each from Review and from
  Files on the operator's phone. Done: both shown, nothing plain fetched.
- [ ] **O25 A module Service Worker on older browsers.** The console's
  sealed film preview needs a module Service Worker (Chromium 91+,
  Safari 15+, Firefox recent). A browser without one says so instead of
  playing. Next: note the browser the operator uses; if it lacks module
  workers, bundle the format into a classic worker. Done: the operator's
  browser plays a sealed preview.
- [ ] **O17 Old runners and the seals flag.** Main's runner (no sealing
  code) now gets only plain work (070). When ENC-4 reaches main, every
  runner sends `seals: 1`. Next: after that release, confirm from the
  function log that no claim arrives without it. Done: one week of claims
  all with seals.
- [x] ENC-0/1: the spec; seal v1 in Python, JS, Kotlin and Dart, each
  checked against Tink (`tool/media_seal_test.py`) and shared vectors.
- [x] ENC-2: migration 060 (`media_keys`, `devices.public_key`), live;
  request-playback v40 with the seal plan behind `SEAL_MODE` (off);
  `MEDIA_KEK_V1` set by the owner, check value `f3bfb0d1` (RUNBOOK 4d).
- [x] ENC-3, the app (branch, 1 Nov): Keystore device key, keyring, the
  unseal gateway in front of the stream proxy, downloads through it, no
  sealed URL ever played directly; 26 new tests, full suite green, branch
  build 41276775374 green. Behind `kAsksForSealed` (MEDIA_SEAL=1 for labs).
- [x] ENC-3 images (5 Nov): migrations 063-066 (media_image_keys; a
  poster's key in title_cards and the landing cards, a photo's beside its
  address in title_media; the helpers in a `private` schema no URL reaches),
  SealKeyring.openWhole, SealedFileImage, the poster cache and photo
  downloads keep sealed images whole, a build that asks reads title_cards.
  Twins of all 52 images of the four open films (run 42008144845, ingest
  v45). 063 first left title_media refusing the app roles for six minutes
  (a view checks a function's EXECUTE as its reader); no app request came
  in that window; 065 fixed it and every catalogue read was checked as
  anon and authenticated.
- [ ] ENC-3, left: proxy CPU per MB is +7-10 ms/MB on the bench (the
  loopback hop, §8); real phones decide whether the in-process route is
  needed. Seek-bar preview pictures are not sealed yet (ENC-4).
- [x] request-playback v41: `SEAL_MODE` ask/on/off, `ask` by default; the
  seal block carries the header (migration 061). Transport check 41278679967
  green; KEK check value `f3bfb0d1` again on fresh instances.
- [x] Canary copies (ENC-5 B, 1 Nov): ingest v44 seal_plan / seal_commit /
  sweep, tool/seal_twins.py, seed-open-films task `seal`. Nine twins
  recorded (run 41292286979). The first run (41286865663) found 060 had
  granted service_role nothing on media_keys - request-playback could not
  have read a key either; 062 grants SELECT and INSERT only.
- [ ] Canary in the labs: device lab jumps on a MEDIA_SEAL=1 build (run
  41293034978): sealed path throughout (5 of 5 copies, key held, gateway),
  15/16. The failure, skip+30 frozen 5.3 s: the jump joined a segment far
  down the cancelled read-ahead's fetch and waited 3.9 s for it; the
  gateway now joins only a segment about to arrive (§6). Run 41984466643:
  16/16, skip+30 frozen 1.0 s — but jumps answered in 0.55-2.2 s against
  0.25-0.9 s plain: no connection to the Worker was ever used twice (a
  finished fetch destroyed its socket, and each object had its own pool).
  Fixed (one pool, a finished fetch gives its connection back): run
  41988997290 16/16, skip+30 0.4 s, answers 0.34-1.4 s; run 42008905621
  16/16. Test Lab 42008905511 (sealed, both phones): realme 16/16, OPPO
  15/15 — real-phone gate passed; the OPPO froze longer on a slower line
  (§8), and its 7.1 s showed the gateway reading on after the proxy let go:
  it now cuts at once. Run 42013700193 (the cut, and flow sealed_images):
  jumps 16/16 for the fourth run running; the hub's and Sintel's posters
  opened as sealed images, none refused. The flow did not reach the album
  cell ("1 of N" not found by its scroll) — loosen it at the next run.
  Still to do: frozen time on a like-for-like line (plain and sealed builds
  back to back on one phone).
- [ ] ENC-4, the pipelines: ingest, console upload, transcode, probe,
  console preview (in progress 5 Nov; see the spec §7).
- [ ] ENC-5, rollout: canary on Sintel and Tears of Steel, `min_supported`,
  the migration job (skips the do-not-touch list), B2 Object Lock after.
### Quality
- ~~Two sealed stream-cache timing tests fail under the full parallel run.~~
  Done 31 Oct: the trickle bound is half the film, and the step-back case
  found a real fault — a flush into a reset connection could hold a
  stretch open for seconds after a seek; it now ends at the hang-up.
- `tool/js/console_smoke.mjs` failed twice on 1 Nov ("upload: the resume
  sent only what was missing (1,2,3)", then "(1,1,2,3)" — part 1 sent twice)
  with the console untouched; reruns pass. A timing assumption in the resume
  check, or a real double send of the first part after a resume — find it
  rather than rerun.
- Burmese Settings still shows Pop-up Play, Decoder, Development and
  Diagnostics in English — decide whether those stay technical terms.

---

## A. WAITING ON YOU — no code needed

| | why it is first |
|---|---|
| **Run migrations 001-011** | Eleven migrations and three edge functions have been written and NONE has been run. Everything below is built on assumptions until they are. `docs/RUNBOOK.md` |
| **Upload five titles** | The catalogue holds one test row. Five real ones exercise the whole pipeline and will find things no audit can |
| **Shrink the posters** | 3.31 MB each. A free viewer downloads every LOCKED photo in full just to see a blur of it. ~500 px wide JPEG gets it to ~80 KB |
| **Decide minSdk** | `minSdk = 24` promises Android 7, `abiFilters` ships arm64 only. 32-bit devices get "app not compatible" with no explanation. Either raise minSdk to 26/28 or add armeabi-v7a. **The current state is an inconsistent promise** |
| **Test on a cheap phone** | Every test so far has been on an S23 Ultra with 11 GB of RAM. Myanmar users are on 3-4 GB, Android 11-13. media_kit/mpv is memory-hungry and has never met such a device |

---

## B. READY TO BUILD, WITH A TRIGGER

### B1. Crash reporting  — trigger: **someone other than you installs the APK**
`crash_diagnostics.dart` catches everything and stores it on the device. Nothing
is ever sent. A user whose app crashes on launch uninstalls it and you never
learn why. Every serious app knows its crash-free rate; you do not know whether
yours is 1% or 30%.

Not now: there is one install, and it is yours. Reporting to yourself what you
already saw adds a migration, an RLS policy, a privacy setting and three
locales - and the uploader would run **inside the crash handler**, which is the
most dangerous place in the app to add code.

### B2. Event log — trigger: **real viewers**
Algorithms can be written later; events cannot be recreated later. The design is
already corrected for the 500 MB free-tier cap: session summaries, not raw
impressions, plus daily rollups. `docs/movies_data_model_v2.md` §3.

Not now: zero users means zero data is being lost. **I overstated this as
urgent - it is not.**

### B3. Admin panel — trigger: **the SQL workflow becomes tedious in practice**
Edge function serving HTML, so the service key never reaches the browser.
Passcode in a secret, HMAC session token, per-IP rate limit, audit log.
Would replace most of RUNBOOK Part 3 with taps, and could mint presigned PUT
URLs so uploads bypass the R2 dashboard's 300 MB cap.

### B4. Reels masonry — trigger: **`backfill-dimensions` has run over real clips**
Pinterest-style masonry computes tile height as `columnWidth / ratio`. With no
ratios every tile falls back to one default, which IS the uniform grid it was
meant to replace. `docs/album_mosaic_plan.md` §8-11.

### B5. Slug-derived metadata — trigger: **typing metadata gets annoying**
`spider-man-2026` already contains the title and the year. Deriving them costs
one SQL function, no API, no terms, no six-month cache limit, no dependency -
and works for content TMDB has never heard of.

---

## C. DELIBERATELY NOT DOING

### C1. Splitting the 3,900-line screens
`downloader_home_screen.dart` (3,925) and `player_screen.dart` (3,617). Both
have zero tests, and nothing here can compile Dart - the checkers do not see
types. **This is the riskiest work available**, for a change no user can see.

Do it in pieces, when a feature lands in one of those files anyway.

### C2. The other 211 silent catches
326 `catch (_)` in total; 115 carry an explanation and many are correct
("clipboard access can be denied; the paste bar still works"). Editing 211 sites
blind is more likely to break something than to reveal anything.

Do it one path at a time, when a user reports that path failing.

### C3. Dependency upgrades
`go_router ^14`, `device_info_plus ^10`, `share_plus ^10`, `permission_handler
^11`, `flutter_lints ^4` are each a major behind. Upgrading blind, in a build
that cannot be compiled locally, is the same risk that ruled out
`cached_network_image`. One at a time, when something specific is needed.

### C4. TMDB metadata
Would remove poster uploads and most typing. Costs: attribution in-app, a
six-month cache limit that conflicts with storing synopses permanently, and a
dependency whose terms include a sole-discretion content clause. And it only
helps for titles TMDB catalogues - not local, original or adult content.
Decide only when you know what the catalogue actually holds. `docs/album_mosaic_plan.md`

---

## D. TRANSFER — audited 2 Sep 2026 against the published research

Checked each known failure in this app class against Innocent.

| known issue | Innocent |
|---|---|
| Path traversal on the receiver | ✅ **Tested, not guessed.** 67 hostile inputs (`../`, `....//`, absolute, UNC, NUL, unicode) run through ports of `sanitizeRelDir` and `_safeName` against a real filesystem. **0 escapes** |
| Improperly exported components (Trend Micro, SHAREit RCE 2021) | ✅ `FileProvider` is `exported="false"` with `grantUriPermissions`. Every exported component is justified; the iADB service is gated behind `INTERACT_ACROSS_USERS_FULL` |
| Upload filename injection | ✅ Separators and control characters stripped; the `.`/`..` survivor found by a 30,000-case fuzz is handled |
| **PIN enumeration (CVE-2018-19429, Xender)** | 🔴 **WAS present - fixed in v1.64.4.** Per-IP lockout after 5 failures with doubling backoff, plus a constant-time compare |
| **Cleartext HTTP (CVE-2018-19430/19431)** | ⚠️ **Present, and inherent.** Files and the token cross the LAN in plain HTTP. Every app in this category shares it, because browser-based receive cannot use a self-signed certificate without a full-page warning |

### The cleartext limitation, stated honestly

An attacker on the same Wi-Fi can sniff a transfer and read the token. There is
no cheap fix: HTTPS on a LAN means either a self-signed certificate (a browser
warning that trains users to click through security warnings) or a real
certificate for an IP address (not issuable).

What actually reduces it, in order:
1. **Turn the PIN on** - now that guessing is throttled, it is a real control;
2. **Turn approval on** - it is off by default, matching Zapya/SHAREit, but on
   an untrusted network it is the difference between "anyone nearby may pair"
   and "I tapped Accept";
3. Prefer Turbo (Wi-Fi Direct) over a shared access point on public networks.

**A defensible next step:** make approval default to ON when the phone is on a
network it has not seen before. Not built - it needs a "known network" store,
and the current default is a deliberate speed choice.

---

## E. FILE PICKER — audited 2 Sep 2026

Read end to end, then the risky paths tested rather than reasoned about.

| checked | result |
|---|---|
| Symlink escape / loops | ✅ `dir.list(followLinks: false)` |
| Jank on large folders | ✅ every file `stat()`ed once, in parallel batches of 48. An earlier version called `statSync()` inside the sort comparator AND again per row |
| Unbounded caches | ✅ directory cache capped at 24 entries |
| Cancel vs failure | ✅ distinguished, with the reasoning recorded: reporting a cancel as a failure pushes someone toward deleting an original they still need |
| `Android/data` handling | ✅ routed through ADB, with a connect hint when unavailable |
| **Disk full mid-import** | 🔴 **WAS present - fixed in v1.64.5** |

**The gap.** Vaulting COPIES into app-internal storage. Selecting 20 GB with
5 GB free started anyway, copied until the disk filled, then failed every
remaining file one at a time - leaving a half-vaulted set on a full device.
Worse than an ordinary error, because someone who believes a file is hidden may
delete the original.

The Transfer receiver has refused up front since a Wi-Fi batch once filled a
disk on its last file. The vault had the identical exposure and no guard.
v1.64.5 applies the same control - same native channel, same 64 MB headroom,
same "proceed when the platform will not say".

`freeSpaceBytes()` is new on `PrivateFolderService` rather than borrowed: the
vault writes to app-internal storage and the receiver to public external.
Usually the same volume, not required to be, and a check against the wrong
volume is worse than none.

### Still open here

* **No upfront estimate.** Selecting 300 files shows a progress sheet but never
  says "this will take about twenty minutes". Cancel exists, so this is a
  comfort issue rather than a correctness one.
* **`rawFiles.skip(i).take(batch)`** is O(n²/batch) because `skip` on a List
  walks from the start each time. At 10,000 files that is roughly a million
  extra element traversals - a few milliseconds, measurable but not felt.
  `sublist` would fix it. Left alone: the file is 2,257 lines with no tests,
  and a few milliseconds does not justify touching it.

---

## HOW THIS LIST WAS ORDERED

Everything in section A costs no code and tells you something no audit can.
Everything in B is written or specified but waits on a condition. Everything in
C would cost more than it returns today.

The recurring mistake in this project has been building ahead of evidence -
`title_assets` before there were assets, masonry before there were clips, an
event log before there were users. Each item above carries the trigger that
makes it worth doing, so the next session starts from a condition rather than
from enthusiasm.
