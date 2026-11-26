# Handoff, 26 Nov 2026: the player as MX's, and every screen size

> **UPDATE, 26 Nov (second session)** — read this block first; the rest
> below is the first session's handoff, still right except where this says.
> DONE (on the branch, not released): §3.1 legibility (controls on
> `BarShade` + `FilmInk`, the shortcut row on discs upright too, ⋮'s
> labels white — 6 of 1440 ⋮ labels still 3.6-4.5:1 by the strict pixel
> measure, 5.3-6.0 at their strokes); §3.3 (the owner's phone is 384x823 at
> 2.8125; the harness fixed; player_screen.dart's "MX GEOMETRY" dp are
> ~7 % large: re-measure in the lab); §2.1 (the owner took ♪'s
> Synchronization only: "Audio delay" row → `AudioSyncSheet`); every
> screen size (§4.1-§4.5: PLAYER_PHONES=all incl. new split screens, 4026
> pass; app screens on SCREEN_PHONES=tablet,…,tv, 888 drawn, no problem;
> fixed: the sleep keypad and the cut sheet in split screen, a D-pad that
> left a panel for the player's full-screen focus node, the focus ring
> two-tone). The owner: "desktop" = Chromebook / Android windows.
> SETTLED: §2.2 — with an .srt MX's subtitle shows (run 45805693393):
> sideways under ⋮ MX leaves it at the foot, centred, across its panel's
> last row, as Innocent does; the owner: keep it. §3.2 — the root reaches
> the whole screen on API 34 and on Android 16 (device lab A1 45805693479,
> the owner's navigation: ⋮ in the tree both ways, the bottom row bounded;
> every flow exit 0): the 96 dp gap is the API 30 lab image's. A TalkBack
> walk on the owner's phone would close it for good.
> THE OWNER'S WORD (26 Nov): TAKE MX's CONTROLS GEOMETRY. Start the next
> session there: `python3 -I tool/ref/controls.py
> /home/user/innocent-ref/runs/2026-11-26_45805693393` prints both apps'
> controls in dp. Sideways: Innocent's top bar 3.9 dp low; its shortcut row
> 12.3 dp low, slots 62.9 apart (MX 59.7), discs 44 (MX 42.7, chevron
> 25.6); the seek bar from 122 to 701 dp (MX 108-668: MX's times sit 65 dp
> in from both ends of the area left of the navigation bar); the bottom
> row's ⏮ ⏯ ⏭ 104 dp apart (MX 96) and centred on the whole screen (MX on
> the area left of the navigation bar: ⏯ at 387.6, Innocent's 406.9); lock
> at 76 (MX 92), screen mode 680 (687), PiP 720 (740). Upright MX: the
> row lock 26.7, ⏮ 138.7, ⏯ 192, ⏭ 245.3, mode 295.5, PiP 348.8 (53.3
> apart), seek bar 704.5 dp down, times 38.4 and 345.6; Innocent's
> upright row is not in the API 30 tree: read it off the screenshot or
> the device lab's API 36 dump (test_device/results/latest/
> ui_controls_port.xml, 1080x2400 at 2.625). The "MX GEOMETRY" block in
> player_screen.dart (_BottomControls) and shortcut_row.dart's _slot/_circle
> are where the numbers live. Then the lab again and MX | Innocent sheets.
> MX ON A TABLET (reference lab 45828625924, 1600x2560 at 320 dpi = 800x1280
> dp; MX's XAPK installs there with its xxxhdpi split; all 24 screens):
> every MX panel's container is 480 dp exactly (upright 480 tall = 37.5 %,
> sideways 480 wide), upright the full width with the content 32 dp in
> (`rv_menu` 32..768). With the phone's 384 (the short side) MX's rule reads
> as THE SHORT SIDE, AT MOST 480 DP. Innocent now: upright 596 (0.466 x the
> long side) with its content capped at 640 and centred, sideways 440 (the
> 280-440 clamp). THE OWNER (26 Nov): "MX as it is, all of it" — so
> `PlayerUi.panelExtent = min(shortestSide, 480)`, `sideWidth` the same
> (keep a 280 floor for split windows), and upright the sheet/panel full
> width with MX's inset (32 dp on a tablet; 24 on a phone) — this replaces
> ui-design §3b's "≤ 640" for the player's panels. Phones do not change.
> Then PLAYER_PHONES=all, the legibility test, the lab on the tablet again.
> ref.env is STILL AT THE TABLET (1600x2560, 320): set it back to 1080x2316
> at 450 in the same push as the next phone run.
> Device lab A2 45828625953 (API 34, the gate on this work): genres 37/37,
> jumps 15/15, gestures 27/27 and 19/19, audits 52 and 52 — as U5.
> Where each run stands: BACKLOG §0, the entry "26 Nov (later)".
>
> 26 NOV (NIGHT), THE OWNER: "⋮ as MX's 11 tiles and More", and "every
> shortcut as MX's — what it does and the screen it brings, exactly".
> The lab (SCREENS=shortcuts; runs 45857557804, 45862946745 over a white
> film, a screen 1.2 s after each tap) took MX's and Innocent's every
> shortcut. DONE on the branch: ⋮ = MX's ten tiles in MX's order (+ ♪ and
> CC first upright) and "More ›", which turns the panel to "← More": Tools
> (Kids Lock, Transfer, Network stream, Subtitle delay, Skip markers,
> Custom speed, Settings), Help (FAQ, Check for updates); the shortcuts
> in MX's order, MX's five shut (EQ, 1X, Screenshot, Background play,
> Rotation), open = the others then those five; Vertical flip off the row
> (MX has none); Loop Off → All → One; Night mode the picture at 40 %, grey
> (it was orange); "1X" opens MX's speed card (SpeedCard); A-B opens MX's
> bar (ABRepeatBar).
>
> | shortcut | MX 3.4.3 | Innocent now | left |
> |---|---|---|---|
> | Night Mode | picture 40 % grey, disc, toast | the same | — |
> | Customise Items | an overlay on the controls: which top-bar icons (HW, Playing Queue, Audio Track, Subtitles, Popup Window, Zoom), Cancel / APPLY | the same (`CustomiseTopBarCard`): queue, ♪, CC, decoder, PiP, screen mode; the bar shows what fits | — |
> | Shuffle, Mute, Background Play | disc; Background Play's toast | disc and a toast each | check Background Play's toast shows (not in the lab's 1.2 s screen) |
> | Loop | Off → All → One | the same | — |
> | Sleep Timer | right panel on the shade, keypad | the same (`PlayerShade`, no scrim) | — |
> | A-B Repeat | bar under the row, [A] → [B], × | the same | — |
> | Audio Effect / Equalizer | right panel on the shade, two tabs; EQ: switch, presets, five bands, Reverb | the same, on the shade (`showPlayerSheet`), Innocent's tokens, no box round the bands | — |
> | Speed | card: − [1.00x ✎] +, 0.25-4.0x, reset | the same | — |
> | Screenshot | toast "saved to …" at the foot | the same: every shortcut's toast at the foot, 2 s | — |
> | Screen Rotation | turns the screen | the same | — |
> | Mirror Mode | not on MX's row in HW | a toggle | — |
>
> Proof: whole suite, player_controls_test (+3: the speed card, the A-B
> bar, the remote in CC), player_layout_test PLAYER_PHONES=all with the
> new scenes (more_page, speed_tap, ab_bar). Not yet on the emulator: the
> next phone run of the lab (SCREENS=shortcuts) shows Innocent's new ones.
>
> 26 NOV (LATE NIGHT), THE OWNER: "the rest, all of it, every device and
> screen, exactly as MX". DONE on the branch (not released):
> - MX's CONTROLS GEOMETRY (controls.py, run 45805693393; the owner's
>   phone sideways / upright): the shortcut row's centre 50.7 / 54.8 dp
>   under the bar's top, slots 59.7, discs 42.7, chevron 25.6, 8.5 in;
>   ⏮ ⏯ ⏭ 96 / 53.3 dp apart, ⏯ at the middle of the screen less the
>   navigation strip; lock's centre 92.1 / 26.7; the times 65 / 17 dp in,
>   42.7 wide; the bottom row 3 dp over the inset. The A-B bar under the
>   row's new place.
> - THE TABLET REACH (MX's, lab 45828625924): `panelExtent` = min(short
>   side, 0.466 x long side, 480); upright panels and sheets the full
>   width, content `PlayerUi.pad` in (32 dp from 600).
> - Sleep Timer and Audio Effect / Equalizer on the shade (`PlayerShade`,
>   `showPlayerSheet`), no scrim; AE/EQ in Innocent's tokens.
> - Every shortcut's toast at the foot, centred, 2 s, 24 dp up (Android's
>   toast, as MX's: over the bottom row; lab 45886561831).
> - CUSTOMISE ITEMS AS MX's EDIT VIEW (lab 45886561831, MX's tree): the
>   controls stay over a dimmed film, the shortcut row goes, each optional
>   control in a dashed 40.5 dp box (`EditSlot`); `CustomiseTopBarCard`
>   2.6 dp under the bar, ≤ 568 wide, six 86 dp choices in MX's order —
>   decoder (HW), queue, ♪, CC (the top bar), PiP (Popup Window) and
>   screen mode (Zoom) (the bottom row's last two) — each checked while
>   shown; Cancel / Apply; kept in `StringSetting.playerTopBar`, MX's
>   default all but the queue. The bar carries what fits beside ←, ⋮ and
>   a 64 dp title, ♪, CC and the decoder first. The old page of shortcut
>   switches is gone (⋮'s lower part keeps those switches).
> - SLEEP TIMER AS MX's (its tree, same run): no close ×; MX's × is
>   `iv_clear`, at the time's end, and clears the entry; keys 32 dp, 74.6
>   across, 49.1 down; the title's middle 28 dp from the top.
> - Legibility: a panel row's value and a switch row's icon white (♪'s
>   "0 ms" read 2.35:1 over white, ⋮'s Video Display icon 2.6).
> - PROVED ON THE EMULATOR, reference lab 45885319037 (SCREENS=panels,
>   `controls.py`): Innocent - MX within 0.5 dp for the seek bar, both
>   times, lock, ⏮ ⏯ ⏭, screen mode, the row's pitch, both ways; the
>   panels 47 % / 48 %. Left then and fixed after it: the top bar
>   sideways 3.9 dp low (MX's bar is 48 high sideways, 56 upright), ←
>   56 wide (title 4 dp after it sideways, 16 upright), HW 48 wide (it
>   was 54), ⋮ 56 wide upright; the row 4 dp low sideways (46.8, not
>   50.7). Kept on purpose: ♪ and CC on Innocent's bar upright too, one
>   tap (MX's upright bar has HW only, at 800 dp too: the lab's decision
>   table read it "Innocent's better, keep"); they are ⋮'s first tiles as
>   well, as MX's. Next run (SCREENS=panels) shows the bar.
> Proof: flutter analyze clean; player_controls_test 44 (+2: the
> Customise card, the 320 dp top bar); player_layout_test PLAYER_PHONES=all
> my/en/th x1.0/x1.3 4554 pass (new scene `customise`); legibility my/en/th
> over five frames: controls 915, ♪ 255, subtitle 480 all pass, ⋮ 1099
> pass, 11 thin Burmese/Thai tile words over white 3.5-4.4 (as before:
> 5.3-6.0 at their strokes).


Written at the end of a long session (the reference lab, Phases 0-1, and the
owner's MX decisions of 22-26 Nov) so the next session can start cold. Read
this, BACKLOG §0 ("21 Nov: REFERENCE LAB ..."), skill `ui-design` (§1-§4)
and `.claude/rules/reference-lab.md` before touching anything. The prompt
the owner pastes is at the end (§8).

## 0. Read first

- **Branch.** Work on `claude/extract-github-release-oteqr5` (no history in
  common with a new session's branch, which starts at main): fetch it, work
  on top of it, push to it fast-forward; never force-push; never push main;
  no pull request. Every push: `git fetch origin <branch> && git merge
  --no-edit FETCH_HEAD`, `git checkout pubspec.lock`, then
  `python3 tool/check.py > log && git push ...` (gate on the exit code).
  At the end of this session the branch was at 96465a39.
- **What is live.** main cea53a4f = app 1.64.88 (22 Nov). NOTHING of the
  player work of 22-26 Nov is live: 6e2efe8a (padding 24), d0cdb039 (MX's
  reach, the shade, the subtitle over an upright panel), 7c9ed0fe (40 %
  see-through, the halo), 4bc44dde (black shade), 341aca04 (MX's kinds of
  control), c3669a9b (marks, header, tiles). A release only when the owner
  says "release" (skill `release`).
- **The owner's rules for MX** (21-26 Nov, still in force):
  - MX's APK, screenshots and dumps live only in the private repository
    `yannmh007/innocent-ref`. This public repository holds numbers and our
    own code only (invariant 16 fails anything else under `tool/ref/` or
    `test_device/ref/`). A public run never uploads an MX file.
  - `REF_REPO_TOKEN` only in the steps that talk to innocent-ref, never in
    an emulator or third-party-tool step; stop if innocent-ref is not
    private.
  - Never MX's icons, images, logo/brand or animations. Colours stay
    Innocent's and are tested against the film (≥ 3:1 icons and controls,
    ≥ 4.5:1 text over black, white, grey, busy and colourful frames), never
    against MX's.
  - 26 Nov, the owner: "Innocent's UI is not pro — make it as MX, all of
    it". Read as: MX's kinds of control, their order and place, the
    spacing and proportions, how panels reach, show the film and give way.
    Drawn with Innocent's own icons and colours. The owner decides each
    change from side-by-side pictures.
  - Lab films are our own ffmpeg films; no catalogue title, ever.

## 1. Where it stands (proved)

- Phase 0 (MX 3.4.3, arm64 only, on the x86_64 API 30 emulator with ARM
  translation): passed, run 44990303466.
- Phase 1: MX and Innocent's ⋮, ♪ and CC, upright and sideways, over a
  black and a white frame (24 screens a run). Last runs: 45775539414
  (after 341aca04) and **45781933354** (after c3669a9b), kept in
  innocent-ref `runs/2026-11-26_45781933354/`.
- Innocent now, as MX's: one reach for every panel and sheet (MX's square:
  the screen's short side, ≤ 46.6 % of the long side); content 24 dp in;
  a black shade (40 % of the film shows, as MX's, within 1-2 points) with
  no blur and no dim; the film's subtitle above an upright panel; CC in
  MX's order (open a file, the tracks as check boxes in a rectangle,
  online subtitles, "Settings ▾"); radio rings; outline marks; ringed
  44 dp tiles ~92 dp apart (MX 45 dp, 83); no title on ⋮; no line under a
  sheet's title; upright "← title" instead of a drag handle; titles where
  MX's are (CC's first row 78 dp down sideways, MX's 79).
- Tests at c3669a9b: whole suite 1875 pass; `player_layout_test` 1062
  (320/360/411 dp, my/en/th, 1.0/1.3); legibility CC 21/21, ♪ 7/7 on the
  five frames.

## 2. Open — waiting on the owner's word

1. **♪ against MX's.** MX's ♪ also has: Disable (no sound), "Use SW audio
   decoder", Open (an audio file), Stereo mode, Synchronization (audio
   delay). Innocent has the delay in Settings > Audio
   (`IntSetting.audioDelay`, `setAudioDelayMs`): a row in ♪ is cheap.
   Disable needs both engines: `setAudioTrack` takes a track (media_kit has
   `AudioTrack.no()`; the ExoPlayer ladder would disable the audio
   renderer). Ask which to bring in.
2. **Sideways, the film's subtitle crosses ⋮'s last (faded) tile row** —
   it is not lifted sideways (22 Nov, as MX). Ask.
3. **Release** of all of the above, when the owner says so.

## 3. Open — found, not fixed

1. **Legibility** (`LEGIBILITY_OUT=dir flutter test
   test/player_legibility_test.dart`): ⋮'s 12 sp tile labels read
   3.7-4.3:1 over a white frame (ဖြတ်ရန် မှတ်သား လွှဲပြောင်း အကြိုက်
   အချက်အလက် အချိုး အစား) and 4.1 over the colour frame; THE CONTROLS
   SIDEWAYS fail over white, busy and colour frames — title 2.2-2.5, clock,
   ♪/CC 2.0-2.6, HW 2.0-2.5, elapsed time 1.5-1.6:1 (their top and bottom
   gradients are too light). Upright controls over an upright film: not yet
   measured.
2. **Accessibility root 96 dp short** of the screen on the API 30 lab
   emulator (⋮ sideways missing from the tree; the upright bottom row at
   zero bounds). Check on API 34 (device-lab) and a real phone first.
3. **The harness's "owner's phone"** is 411×882 dp (2.625); the lab reads
   the owner's phone as 450 dpi, 384×823 dp. One of them is wrong: settle
   it (the app's telemetry, or the owner's Settings > Display size).
4. Smaller differences from MX left on purpose: Innocent's rows 48-52 dp
   (MX 45-47: Burmese is taller), Innocent's title lighter than MX's bold,
   Innocent's panel reads 47.9 % against MX's 46.6 % (likely the edge of
   the shade read a few dp out — check against a screenshot).

## 4. Next work A: every screen size

Innocent ships for Android only (`ios/` and `web/` are Flutter's unused
folders). "Desktop/PC" for this app means a Chromebook, Android's desktop
windowing (freeform, resizable windows, an external monitor) with mouse and
keyboard; "tablet" an 8-13" tablet and a foldable's inner screen; and the
TV. If the owner means a Windows/Mac/web app, that is a new project: ask.

What exists (docs/devices_2026_11.md, skill `ui-design` §3b): window size
classes (compact < 600, medium 600-840, expanded 840-1200, large 1200+),
`TabletConstrainedWidth`, two panes from 840 dp, `TvSafeArea`, D-pad,
keyboard and mouse; harness profiles `PLAYER_PHONES=large|all`
(800x1280 tablet, 701x841 fold, 900x1600 at 1.25 Chromebook, 540x960 TV)
and `SCREEN_PHONES=tablet,tablet_land,fold,fold_land,chromebook,tv` for
the app's other screens.

What the 22-26 Nov player changes mean on large screens (to check, not
assumed): the reach is `min(short side, 0.466 × long side)`; sideways the
width is clamped to 280-440 dp; upright the sheet is ≤ 640 dp wide,
centred. So: tablet upright ~596 dp tall; tablet sideways 440 dp of
1280 (34 %); fold sideways 392 of 841 (46.6 %); a 900x1600 window upright
~745 dp tall — a lot of shade for a few rows; TV 440 of 960.

Check, in order:
1. Every player panel and sheet on `PLAYER_PHONES=all`, both ways, my/en/th,
   1.0/1.3 (and 2.0 font scale on one phone): nothing cut, nothing
   overlapping, the ← and the check-box rectangle in place, the 640 dp cap
   upright, the shade reaching the window's edge.
2. Resizing: a window that changes size or turns under an open panel or
   sheet keeps its content (showPlayerSheet follows the window; PlayerPanel
   reads MediaQuery). Split screen (half-height and half-width windows).
3. TV and keyboard: D-pad walks the ←, the check boxes, "Settings ▾", the
   radios and the tiles, focus always visible on the shade (check the
   InkWell focus colour over a bright film); Back and Esc close a panel,
   then the player; media keys.
4. Mouse: hover shows the controls; a click outside a panel closes it.
5. The app's other screens on `SCREEN_PHONES=...` (photographs per
   docs/devices_2026_11.md) — confirm nothing regressed since 13 Nov.
6. MX on a tablet: rerun the reference lab with a tablet screen
   (`PROBE_SIZE`/`PROBE_DPI` in ref.env, e.g. 1600x2560 at 320 dpi) to see
   how MX's panels reach there, before deciding Innocent's tablet reach.
   First check that MX's XAPK installs at that density.
7. Real devices: device-lab (emulator, API 34) and Test Lab (real phones)
   per skill `device-labs`; a tablet model there if the account has one.

## 5. Next work B: MX parity for the rest of the player

### 5.0 The table (26 Nov, from the lab's screens and Innocent's code)

| # | MX 3.4.3 | in the lab? | Innocent | next |
|---|---|---|---|---|
| 1 | Top bar: ← title … (♪ CC sideways) HW ⋮; upright ← title … HW ⋮ | yes (controls) | ← title clock ♪ CC decoder ⋮, both ways | measure in dp (measure.py has no controls measure yet) |
| 2 | Shortcut row: EQ, 1X, screenshot, background play, rotate, ›; discs both ways | yes | the viewer's own set; discs both ways (26 Nov) | measure slot pitch and disc size (Innocent's 63/44 came off 2.625) |
| 3 | Seek bar, times at its ends | yes | elapsed, remaining | measure |
| 4 | Bottom row: lock │ ⏮ ⏯ ⏭ │ screen mode, PiP | yes | the same | measure |
| 5 | ⋮ tiles: 11 sideways (+♪ CC upright), the last "More ›" | yes | 16 tiles, no "More ›" | owner: MX's set and a second page? |
| 6 | ⋮ lower part: Video Display, Shortcuts switches, (below: not seen) | partly | the two switches, then every shortcut as check boxes | lab: scroll MX's ⋮ |
| 7 | ⋮ "More ›" → a second page | no | — | lab: open it |
| 8 | Each tile's screen (Playing Queue, Aspect Ratio, Display Settings, Bookmark, Cut, Favourite, Add To Playlist, Information, Share, Tutorial) | no | a sheet or dialog each | lab: open each by its place in the grid |
| 9 | ♪ Synchronization, Stereo mode, Open | no (♪ itself yes) | Audio delay (26 Nov) | lab: open Synchronization |
| 10 | CC "Settings ▾" open, and its sheets | no | delay / text style / position | lab: open ▾ and each |
| 11 | Gesture readouts: brightness, volume, seek, zoom, speed | no | an indicator each | lab: a held swipe, screen taken mid-way |
| 12 | Lock screen; screen-mode toast; HW dialog; 1X speed panel; EQ | no | lock overlay, toast, decoder dialog, speed, audio effects | lab |

Start with 1-4 (one controls measure, numbers only) and 6-7, then one
screen at a time.

The owner's next step: menus, layout, styles — all after MX (within §0's
limits). Start small, one screen at a time, each with side-by-side
pictures and the owner's word, as Phase 1 did.

1. List MX's player screens and Innocent's counterparts first (from the
   lab's trees and screenshots), in a table: the controls screen (top bar,
   bottom row, seek bar and times, the shortcut row and its chevron, lock,
   screen mode, PiP), ⋮'s lower part (MX: Video Display and Shortcuts
   switches), each of ⋮'s tiles' screens (Display settings, Aspect ratio,
   Playing queue, Bookmark, Information, Share, Tutorial, ...), CC's
   "Settings ▾" opened and its three sheets, ♪'s extra rows, the
   gesture readouts (brightness, volume, seek), the lock screen.
2. Extend the lab: `test_device/ref/probe.sh panels` opens more screens
   (MX's from its tree — dumpsys, not uiautomator; pause first; wait for
   the screen in the tree), named `<app>_<orient>_<frame>_<screen>`;
   `tool/ref/measure.py` grows a measure for the controls screen
   (positions and sizes of the bars and buttons) — numbers only.
3. For each screen: measure, pictures (`tool/ref/pair.py`), the owner's
   decision, the change, proof (§6), the lab again.
4. After the player: MX's other screens (folder and file lists, settings)
   only with the owner's go — list them and ask.

## 6. How to prove a change (each time)

1. Flutter (CI's 3.32.8) installs in ~2 min: see `.claude/rules/flutter-app.md`.
   `export PATH=/root/flutter/bin:$PATH`.
2. `flutter analyze` on the changed files; `flutter test
   test/player_controls_test.dart`; `LANGS=my,en,th SCALES=1.0,1.3 flutter
   test test/player_layout_test.dart` (+ `PLAYER_PHONES=all` for screen
   sizes); the legibility test; the whole suite (~5 min); `git checkout
   pubspec.lock`. `dart format` only files HEAD had formatted.
3. Before/after pictures: `PLAYER_SHOTS=<scratchpad dir>
   SCENES=more,subtitle_panel,subtitle_tracks,audio_sheet,loop_menu,display
   LANGS=my,en SCALES=1.0 flutter test test/player_layout_test.dart`, once
   on the old code (`git stash`) and once on the new.
4. The lab on the emulator: a dated note at the top of
   `test_device/ref/ref.env` (MODE=panels) and push — any change under
   `test_device/ref/` starts a ~30 min run (14 min of it rebuilding the
   lab APK when lib/ changed); don't touch ref.env for notes alone. Then
   `add_repo yannmh007/innocent-ref` (read), clone to
   /home/user/innocent-ref, sync with `git fetch -q --depth 1 origin main
   && git reset -q --hard FETCH_HEAD`, read `runs/<date>_<run id>/measure/`
   and make the sheets: `python3 -I tool/ref/pair.py
   /home/user/innocent-ref/runs/<date>_<run id> <scratchpad>/pairs`
   (refuses an output inside this repository). Check the figures against
   the screenshots before they go to the owner.
5. Send the pictures with SendUserFile; update BACKLOG §0, the ref.env
   note, skill `ui-design` §3-§4; commit; push through the check.py gate.

## 7. Lessons from this session

- A long foreground wait goes to the background past 600 s: wait in
  chunks of `timeout 590 tail -f /dev/null`, then read the run by id.
- measure.py's numbers were wrong three times (MX's moved subtitle, a list
  past the screen, ⋮'s tiles on the line read): the rule file has each.
- A shadow under a mark (`BoxShadow`) fills it: an idle box read as a
  black square on the emulator, which the test harness did not show.
- The owner judges from pictures of both apps side by side on the same
  frame; send those, not only numbers.

Second session (26 Nov):
- `git stash` while a flutter command has rewritten pubspec.lock: the pop
  refuses; `git checkout pubspec.lock` first, then `git stash pop`.
- `flutter analyze` with no path before a push (test_screens/ is only
  read there; Stream bench 45796876440 failed on it).
- The legibility test reads the drawn pixels: a halo darkens a thin
  stroke's own edge pixels as much as the ground beside it, so a stronger
  halo did not lift 12 sp Burmese (3.6 → 3.6); a darker ground does.
- A full-screen focus node (the player's remote listener) is a candidate
  for the D-pad's arrows unless it has `skipTraversal`.

## 8. The prompt for the next session (the owner pastes it)

```
Innocent player UI ဆက်လုပ်ပါ — "MX အတိုင်း" ပြင်ဆင်ခြင်းနဲ့ screen အရွယ်အစားတိုင်း စစ်ဆေးခြင်း။
ဒီ session မှာ ဒီ workstream တစ်ခုတည်းပဲ လုပ်ပါ။ ကျွန်တော့်ကို မြန်မာလို ပြန်ဖြေပါ။

၀။ စမစခင်
- docs/handoff_2026_11_26_mx_parity.md ကို အစအဆုံး အရင်ဖတ်ပါ။ ပြီးရင် BACKLOG §0 ("21 Nov: REFERENCE LAB")၊ skill ui-design၊ .claude/rules/reference-lab.md နဲ့ .claude/rules/flutter-app.md ကို ဖတ်ပါ။
- Work branch claude/extract-github-release-oteqr5 ကို fetch လုပ်ပြီး အဲ့ဒီအပေါ်မှာ ဆက်လုပ်ပါ။ Push တိုင်း fetch → merge → git checkout pubspec.lock → python3 tool/check.py ကို exit code နဲ့ gate ထားပြီးမှ push လုပ်ပါ (fast-forward သာ)။ Main ကို မ push ရ၊ PR မဖွင့်ရ၊ release မလုပ်ရ (ကျွန်တော် "release" လို့ ပြောမှ)။
- MX ပုံတွေ ကြည့်ဖို့ add_repo yannmh007/innocent-ref (read) လုပ်ပါ။

၁။ MX အတွက် စည်းကမ်းများ (မပြောင်းပါ)
- MX ရဲ့ APK၊ screenshot၊ dump မှန်သမျှ innocent-ref (private) ထဲမှာပဲ ထားပါ။ Public repo (innocent) ထဲမှာ ဂဏန်းနဲ့ ကိုယ်ပိုင် code ပဲ ရှိရပါမယ်။ Public run မှာ MX ဖိုင်ကို artifact အဖြစ် မတင်ရပါ။
- REF_REPO_TOKEN ကို innocent-ref နဲ့ ဆက်သွယ်တဲ့ step တွေမှာပဲ ထည့်ပါ။ Emulator ဒါမှမဟုတ် third-party tool run တဲ့ step မှာ မထည့်ရပါ။ innocent-ref က private မဟုတ်ရင် ရပ်ပါ။
- MX ရဲ့ control အမျိုးအစား၊ အစီအစဉ်၊ နေရာ၊ spacing/proportion၊ panel ရောက်ပုံ၊ ပြပုံ အကုန်ယူပါ ("အကုန်လုံး MX အတိုင်း")။ ဒါပေမဲ့ MX ရဲ့ icon၊ ပုံ၊ logo/brand၊ animation ကို မကူးရပါ။ အရောင်က Innocent ရဲ့ အရောင်ပဲ သုံးပြီး film ပေါ်မှာ စစ်ပါ (icon/control ≥3:1၊ စာ ≥4.5:1၊ frame ၅ မျိုး)။
- Lab မှာ ကိုယ်တိုင်လုပ်တဲ့ ffmpeg film ပဲ သုံးပါ၊ catalogue title မသုံးရပါ။

၂။ ပထမ — ဒီ session မှာ ကျန်ခဲ့တာတွေ (handoff §2–§3)
- §3 က ပြင်လို့ရတာတွေကို ပြင်ပြီး သက်သေပြပါ — sideways controls legibility (title/clock/♪/CC/HW/elapsed time 1.5–2.6:1)၊ ⋮ tile label 3.7–4.3:1၊ upright film ပေါ်က upright controls ကို တိုင်းဖို့၊ accessibility root 96 dp တိုနေတာ (API 34 နဲ့ real phone ပေါ်မှာ အရင်စစ်ပါ)၊ harness ရဲ့ phone size 411×882 နဲ့ 384×823 ဘယ်ဟာမှန်လဲ။
- §2 ဆုံးဖြတ်ချက်တွေ (♪ ထဲက Disable/SW decoder/Open/Stereo/Sync၊ sideways subtitle နဲ့ ⋮ နောက်ဆုံးအတန်း) ကို MX | Innocent ပုံနဲ့ ပြပြီး မေးပါ။

၃။ ဒုတိယ — screen အရွယ်အစားတိုင်း (handoff §4)
- Phone တင်မကဘဲ tablet၊ foldable၊ Chromebook/desktop window (resize, freeform, mouse/keyboard)၊ TV (D-pad) နဲ့ split screen တွေမှာ player ရဲ့ panel/sheet/menu တွေ အံဝင်ခွင်ကျ ရှိ/မရှိ စစ်ပါ။ ပြီးရင် app ရဲ့ ကျန် screen တွေကိုလည်း စစ်ပါ (PLAYER_PHONES=all, SCREEN_PHONES=tablet,tablet_land,fold,fold_land,chromebook,tv; device-lab; Test Lab)။
- MX က tablet ပေါ်မှာ panel ဘယ်လောက်ရောက်လဲ သိဖို့ reference lab ကို tablet screen နဲ့ run ပါ။ ပြီးမှ Innocent ရဲ့ tablet reach ကို ဆုံးဖြတ်ပါ။
- Windows/Mac/web app ကို ဆိုလိုတာ ဟုတ်/မဟုတ် မသေချာရင် အရင်မေးပါ။

၄။ တတိယ — ကျန်တဲ့ player တစ်ခုလုံးကို MX အတိုင်း (handoff §5)
- MX ရဲ့ player screen အားလုံးနဲ့ Innocent ရဲ့ သက်ဆိုင်ရာ screen တွေကို table အရင်လုပ်ပါ — controls screen (top bar၊ bottom row၊ seek bar၊ shortcut row၊ lock)၊ ⋮ အောက်ပိုင်း၊ ⋮ tile တစ်ခုချင်းရဲ့ screen၊ CC Settings ▾ နဲ့ sheet ၃ ခု၊ gesture readout တွေ။
- Lab ကို screen ပိုဖွင့်နိုင်အောင် ချဲ့ပါ။ Screen တစ်ခုချင်း တိုင်းပြီး MX | Innocent ပုံ ပြ၊ ဆုံးဖြတ်ချက်ယူ၊ ပြင်၊ သက်သေပြပါ။ Menu၊ layout၊ style အကုန် MX အတိုင်း သွားမှာပါ။
- Player ပြီးမှ MX ရဲ့ ကျန် screen တွေ (folder/file list၊ settings) ကို စာရင်းပြပြီး မေးပါ။

၅။ ပြောင်းလဲမှု တစ်ခုချင်းစီကို သက်သေပြပုံ (handoff §6)
- flutter analyze၊ player_controls_test၊ player_layout_test (my/en/th၊ 1.0/1.3၊ PLAYER_PHONES=all)၊ legibility test၊ test အားလုံး။
- Emulator ပေါ်မှာ reference lab ကို run ပြီး tool/ref/pair.py နဲ့ MX | Innocent ပုံထုတ်ပါ။ ဂဏန်းတွေကို screenshot နဲ့ တိုက်စစ်ပြီးမှ ပြပါ။
- ပုံတွေကို SendUserFile နဲ့ ပို့ပါ။ BACKLOG §0၊ ref.env note နဲ့ ui-design skill ကို update လုပ်ပါ။

၆။ ပြီးရင်
- Pass/fail ကို run id နဲ့တကွ၊ ကျွန်တော် လုပ်ရမယ့်အရာ၊ ဆုံးဖြတ်ပေးရမယ့်အရာတွေကို မြန်မာလို ပြောပါ။ ပုံတွေလည်း ပို့ပါ။
- Session ရှည်လာရင် ရပ်တဲ့နေရာကို BACKLOG §0 မှာ မှတ်ပြီး session အသစ် အကြံပေးပါ။
```
