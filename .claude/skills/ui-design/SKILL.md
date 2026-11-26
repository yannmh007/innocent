---
name: ui-design
description: "Innocent's UI standard: surfaces, colour, type for Burmese, spacing, panels, sheets, dialogs, and how to prove a screen with screenshots. Use before changing any screen, menu, sheet or dialog of the app, and when the owner says something looks cheap, childish or wrong."
---

# The Innocent UI standard

The owner's bar (12 Nov 2026): premium and calm like MX Player, never "a
toy a child has been poking at". Every rule below answers something seen
on a phone. The player's building blocks live in
`lib/features/player/presentation/widgets/player_ui.dart`; use them.

## 1. Principles
1. **The picture is the hero.** Chrome recedes: one accent (brand blue
   `#3D8DF0`, `AppColors.specPrimary`), greys for everything else.
2. **One layer at a time, and the film stays the film.** An open panel
   or sheet sits on THE SHADE (the owner, 22 Nov 2026, after the
   reference lab: "as MX — it disturbs the film less while it plays than
   the misted glass"; and: "MX's lets more of the film through"): no
   blur, no dim over the picture; the menu's black shade lets 40 %
   of the film through — as much as MX's (measured over a white and a
   black frame, grey levels only) — and thins out over 360 dp before its
   edge (`PlayerShade`). Its words and icons carry a dark halo
   (`PlayerUi.shadeInk`); titles stay white (blue read 1.3:1 over a bright
   film); a tile's icon sits on a dark disc in a thin white ring. The
   controls are MX's kinds (the owner, 26 Nov 2026: "as MX, all of it"):
   one choice of a list is a radio ring with a dot, the subtitle tracks
   are check boxes in a thin rectangle (marks are outlines, nothing fills
   them until chosen), ⋮ has no title, a sheet's title no line under it,
   CC's settings open below a "Settings ▾" row, and upright a ← before a
   panel's or sheet's title closes it (no drag handle).
   The controls under it hide (11 Nov: the clock, ♪,
   "Default" and the seek bar showed through a translucent ⋮). Upright,
   the film's subtitle goes over the open panel, as MX lifts its own. A
   dialog keeps frosted glass over a dimmed picture (12 Nov).
3. **Every menu looks like every other menu**: same surface, header, row,
   spacing. A new menu is built from player_ui.dart, not from scratch.
4. **It fits everywhere**: 320–411 dp, portrait and landscape, Burmese,
   Thai and English, font scale 1.0–1.3. Nothing cut, nothing overlapping;
   a long list scrolls inside its surface and shows that it does.
5. **Quiet shapes.** No thin outline rings around every icon, no rainbow
   colours, no shadows on black. Tonal fills, hairlines, generous space.

## 2. Tokens (dark; the player is always dark)
| | value |
|---|---|
| behind a panel or sheet | nothing: the picture is not dimmed (22 Nov) |
| panel, sheet | **the shade** (`PlayerShade`): black at 60 % within the menu (40 % of the film shows, as MX's), 20 % at 160 dp before its edge, 0 at 360 dp; no blur, edge or corners; words and icons with `PlayerUi.shadeInk` (black rim 1 + 3, a soft 10); tile discs black 30 %. Black, not `#1C1C1E`: the grey left words 15 % less contrast over a bright film |
| scrim behind a dialog | black 40 % (`PlayerUi.scrim`) |
| surface of a dialog or card | **frosted glass**: the film blurred (σ 30) under `#1C1C1E` at 72 % (`PlayerGlass`, `PlayerUi.glassTint`), a white 12 % edge; opaque `#1C1C1E` on a low-RAM or 32-bit-only phone (`PlayerUi.probeGlass`) |
| reach of a panel or sheet | MX's (`PlayerUi.panelExtent`): the screen's short side, at most 46.6 % of the long side — upright that tall, sideways that wide (≤ 440) plus the navigation strip |
| raised (card, tile, chip on a surface) | white 12 % (`PlayerUi.raised`) |
| hairline | white 10 % |
| text | primary white 92 %, secondary 62 %, disabled 38 % |
| selected | on the shade (26 Nov): a choice's radio ring white with an accent dot (idle ring white 70 %, an outline: 3.7:1 over the shade on a white film); a check box filled accent with a white ✓ (idle an outline, white 70 %); a row that is not a choice, a white ✓ at its end; a tile, accent icon on accent 16 % in an accent ring (idle ring white 55 %, `PlayerUi.tileRing`) |
| radius | sheet/panel 20, dialog 20, card/tile 14, pill full |
| spacing | 4 dp grid; panel padding 24 (20 under 360 dp: MX keeps panel content ~26 dp in, the owner chose it 22 Nov); section gap 20 |
| rows | min 52 dp, icon 22 dp, gap 16 |
| touch | 48 dp, never under 40 in the player chrome |
| motion | 200 ms ease-out-cubic for panels; 150 ms fades |

Type (Roboto; Burmese falls back to Noto Sans Myanmar, nearly twice as tall
per line — never a fixed height around text, see .claude/rules/flutter-app.md):
panel title 18 sp w600 · section label 12.5 sp w600, secondary colour ·
row title 15 sp w500 · row value 13 sp secondary · tile label 12 sp w500,
two lines at most · caption 11 sp.

## 3. Components (all in player_ui.dart)
- **Panel** (`PlayerPanel`, in the player's own Stack): MX's reach
  (`PlayerUi.panelExtent`, 22 Nov 2026: one square, the screen's short
  side — 384 dp, 46.6 % of the owner's screen, both ways); landscape a side
  panel from the right that wide plus the navigation strip; portrait a
  bottom sheet that tall with a drag handle (it was up to 55 %, and at 72 %
  it rose over the whole picture: "it goes up too far", owner, 12 Nov). On
  the shade. The picture never moves. ⋮ has no title, upright or sideways
  (26 Nov: "hide the word More"); its first tiles 34 dp down, as MX's. No
  drag handle; the title's middle 28 dp down, as MX's; upright a ← before
  it closes the panel (26 Nov). Header: title + optional trailing (capped at half the row,
  never two flexibles — they split the row and the action sat in the
  middle). Body scrolls, with a fade at an edge that has more. Slides in in
  220 ms: a widget test needs several frames (`_settle`), not one long pump.
- **Section** (`PanelSection`): a small label, then its content; 18 dp apart.
- **Row** (`PanelRow`): icon, title (15 sp regular — Noto Sans Myanmar has
  no medium, a w500 Latin title beside it read bolder), value, chevron.
  For a list of choices `choice: true`: a radio ring (`PanelRadio`) sits
  where the icon would, so every title starts at one edge. `PanelSwitchRow`
  for a setting: the row takes the tap, `PlayerSwitch` only shows it.
  `PanelCheckRow` for a check box with words.
- **Check box group** (`PanelCheckBox` of `PanelCheck`s): check boxes
  (`PanelCheckMark`) and their names in a thin rectangle (white 40 %,
  radius 6) — the subtitle tracks, as MX boxes them (26 Nov). The one on
  is the one showing; tapped again, none shows: no "Off" row.
- **Expanding row** (`PanelExpandRow`): icon, title and a caret; its rows
  open below it (CC's "Settings": delay, text style, position). Shut when
  the panel opens.
- **Tile** (`PanelTile` in a `PanelGrid`): 44 dp circle (black 30 % disc,
  a 1.2 dp white 55 % ring, as MX rings its tiles; MX's is 45), 22 dp icon,
  label 6 dp below, up to three lines; rows ~88 dp apart in English (MX's
  83; they were 110). Four columns.
- **Card** (`PanelCard`): raised, radius 14, for a checklist or a group.
- **Choice grid** (`PanelChoiceChip` in a `PanelGrid`): a small set of
  values (aspect ratios) all on screen at once instead of a long radio list.
- **Sheet** (`showPlayerSheet` + `PlayerSheetHeader`, no line under the
  title and no handle, upright a ← that closes it, 26 Nov): the panel's
  reach and shade; upright a bottom sheet (dragged down to close, by any
  part of it); **sideways a
  side panel from the right, the whole height**, like ⋮ (a bottom sheet held sideways had
  ~300 dp and cut its lists and sliders). The form follows the window
  while the sheet is open — a turn or a resize keeps the content's state
  (Android 16 ignores the player's orientation requests on tablets). `barrierColor: Colors.transparent` for a sheet that
  changes the picture (Display, subtitle delay) so the change can be seen.
  A sheet whose list always runs on takes `PanelScroll` (it fades at an
  edge with more, as ⋮ does). Rows that only inform (the gestures help)
  take focus, so a remote can walk and scroll them. No menu draws its own
  page (the gestures help was 87 % black with its own header and discs).
- **Dialog**: `PlayerDialog` inside the player's Stack, `PlayerRouteDialog`
  for showDialog; `PlayerDialogButton` — the main action filled, the other
  plain; max width 360–420.
- **Messages**: a passing message is the player toast
  (`PlayerToastController.current` reaches it from a sheet); an error is
  `PlayerErrorCard` — a card on the scrim, the engine's text through
  `scrubPlaybackError` (never a signed address on screen).
- **The controls under a layer**: `_chromeUp` in player_screen.dart hides
  the top bar, shortcut row and bottom row while a panel, a dialog, the
  error card or a route the player opened is up.

Never set `textStyle` in a ButtonStyle, or a bare `TextStyle` as a
TabBar's `labelStyle`: it replaces the theme's, Roboto and the Burmese
fallback with it (the harnesses drew such labels as boxes: the player's
header action, the downloader's tabs). Put the size on the Text, or start
from `Theme.of(context).textTheme.labelLarge?.copyWith(...)`.

**The rest of the app** uses the same tokens: `MxDialog` (core/ui, the
information dialogs, opened over the player too) is the panel surface
`#1C1C1E`, radius 20, labels 15 sp secondary, values 15 sp primary. Prove
an app screen with the screens harness (`test_screens/`, 107 screens):
`SCREEN_LOCALE=my|en flutter test test_screens --update-goldens`, and
`SCREEN_PHONES=tiny` for 320 dp; fonts in `build/screen_fonts` (the SDK's
Roboto and icons, test/fonts' Noto Sans Myanmar as NotoSansMyanmar-400/700).

## 3b. Every screen size (docs/devices_2026_11.md)
- By the window, not the device: compact < 600 dp, medium 600–840,
  expanded 840–1200, large 1200+. The shell's rail takes over at 600.
- A list or form page caps its width (`TabletConstrainedWidth`, 840; a
  reading page 640); hero, rails and grids use the width. A sheet or
  panel is never full width on a large screen (≤ 640).
- A screen that is a list of things to open shows two panes from 840 dp of
  window (`core/ui/list_detail.dart`: Settings, the Video tab's folders):
  `ListDetailPanes` (list 360–400 dp, white-10 % hairline, each pane its
  own top bar), the open row on `listDetailSelection` (accent 16 %, radius
  14, inset 8), a page that opens pages in a `DetailNavigator`. Below 840
  the phone's layout, untouched. A window that narrows keeps what the
  person opened; never push over the player.
- A grid adds columns with width (`Responsive.gridColumns`; posters
  `PosterMetrics.gridColumnsFor`): the phone's count is the minimum, a
  cell stays about a phone's size.
- TV: the overscan margins are insets (`TvSafeArea`): a body that draws
  words or tiles keeps clear of the side insets (a SafeArea, or
  `SafeGridWidth` for a grid; the shell's right side does it for the tabs),
  pictures may bleed; every function by the D-pad, focus always visible;
  the remote's media keys work; the D-pad leaves a text field
  (`DpadLeavesTextFields`); Back by D-pad from a pane goes to its list
  first. Prove it: `SCREEN_PHONES=tv` and measure the 48 dp side bands.
- Keyboard and mouse are first-class: Space/K, arrows/J/L, Esc, M, ?, a
  right-click menu, hover shows the controls and the pointer hides.
- Prove on `PLAYER_PHONES=all` and `SCREEN_PHONES=tablet,tablet_land,fold,
  fold_land,chromebook,tv` (`fold_land`, 841 dp, is the tightest two-pane
  width; a TV is drawn with its overscan margins).

## 4. MX parity — keep the structure, refine the look
Top bar `← title … ♪ CC HW ⋮`; shortcut row with its expand chevron;
bottom row `lock | ⏮ ⏯ ⏭ | screen-mode PiP`; ⋮ = "Video display" tiles +
the shortcuts checklist. Do not invent a new layout to look modern; make
this one precise.

**MX is a reference for proportions and behaviour, never for looks** (the
owner, 21 Nov 2026: Innocent aims at a global standard and takes nothing
from MX but its reasoning).
- Take from MX: how far a panel or sheet rises and where it anchors, its
  width and height against the screen, how much of the picture stays
  visible and how the controls give way, how it comes in and goes, the
  proportions of its spacing.
- Never take: its theme, colours, icons, images, animations or brand.
- Where Innocent's choice is better it stays (rows of 52 dp; ♪ and CC one
  tap away upright). Take MX's only where it answers something Innocent
  lacks, and the owner decides each one: on 22 Nov the owner took MX's
  reach (over the 55 % panel), its spacing (panel padding 24), its shade
  (over the frosted glass) and its subtitle lifted over an upright panel;
  on 26 Nov its kinds of control ("Innocent's UI is not pro, so make it
  as MX, all of it"): radio rings, the subtitle tracks as boxed check
  boxes, ringed tiles, no ⋮ title, no line under a sheet's title, CC's
  settings behind "Settings ▾", the ← upright, MX's spacing of titles and
  tiles (measured on the emulator, run 45775539414). Kinds of control and their places only —
  drawn with Innocent's own icons and colours, never MX's.
- Colour is tested against the film, not against MX: the player plays any
  video, so every icon, label and panel must read over a dark, a bright, a
  busy and a colourful frame — at least 3:1 for icons and controls, 4.5:1
  for text. Measuring MX: BACKLOG §0, "Reference lab".

## 5. Prove it (every UI change)
1. `test/player_layout_test.dart` with `PLAYER_SHOTS=<dir>`, the scenes the
   change touches, `LANGS=my,en,th SCALES=1.0,1.3`: no overflow anywhere.
2. Look at the photographs: 360 portrait and landscape, 320 at 1.3, in
   Burmese. Check: nothing shows through; nothing cut; edges aligned;
   one style. Before/after sheets (ImageMagick `montage`) to the owner.
3. Behaviour in `test/player_controls_test.dart`; on a device, the lab's
   `layout_portrait player_audit layout_landscape player_audit_land`.
4. Not right yet? Change it and photograph again. The owner judges from a
   phone: send the sheets, ask, iterate.
