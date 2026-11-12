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
2. **One layer at a time.** An open panel, sheet or dialog is frosted
   glass over a dimmed picture, and the controls under it hide: the film
   shows through as colour, nothing sharp does (11 Nov: the clock, ♪,
   "Default" and the seek bar showed through a translucent ⋮; 12 Nov the
   owner chose misted glass over moving the picture out of the way).
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
| scrim behind a panel/dialog | black 40 % (`PlayerUi.scrim`) |
| surface (panel, sheet, dialog) | **frosted glass**: the film blurred (σ 30) under `#1C1C1E` at 72 % (`PlayerGlass`, `PlayerUi.glassTint`), a white 12 % edge; opaque `#1C1C1E` on a low-RAM or 32-bit-only phone (`PlayerUi.probeGlass`) |
| raised (card, tile, chip on a surface) | white 12 % (`PlayerUi.raised`) |
| hairline | white 10 % |
| text | primary white 92 %, secondary 62 %, disabled 38 % |
| selected | accent text/icon; container accent 16 % |
| radius | sheet/panel 20, dialog 20, card/tile 14, pill full |
| spacing | 4 dp grid; panel padding 20 (16 under 360 dp); section gap 20 |
| rows | min 52 dp, icon 22 dp, gap 16 |
| touch | 48 dp, never under 40 in the player chrome |
| motion | 200 ms ease-out-cubic for panels; 150 ms fades |

Type (Roboto; Burmese falls back to Noto Sans Myanmar, nearly twice as tall
per line — never a fixed height around text, see .claude/rules/flutter-app.md):
panel title 18 sp w600 · section label 12.5 sp w600, secondary colour ·
row title 15 sp w500 · row value 13 sp secondary · tile label 12 sp w500,
two lines at most · caption 11 sp.

## 3. Components (all in player_ui.dart)
- **Panel** (`PlayerPanel`, in the player's own Stack): landscape a side
  panel from the right, up to 400 dp of content plus the navigation strip,
  46 % of the width; portrait a bottom sheet up to 60 % of the height with a
  drag handle, up to 55 % (at 72 % it rose over the whole picture: "it
  goes up too far", owner, 12 Nov). The picture never moves. Header: title + optional trailing (capped at half the row,
  never two flexibles — they split the row and the action sat in the
  middle). Body scrolls, with a fade at an edge that has more. Slides in in
  220 ms: a widget test needs several frames (`_settle`), not one long pump.
- **Section** (`PanelSection`): a small label, then its content; 18 dp apart.
- **Row** (`PanelRow`): icon, title (15 sp regular — Noto Sans Myanmar has
  no medium, a w500 Latin title beside it read bolder), value, chevron.
  For a list of choices `choice: true`: the check sits where the icon would,
  so every title starts at one edge. `PanelSwitchRow` for a setting: the
  row takes the tap, `PlayerSwitch` only shows it. `PanelCheckRow` for a
  check box with words.
- **Tile** (`PanelTile` in a `PanelGrid`): 48 dp tonal circle (raised
  fill, no outline), 22 dp icon, label up to three lines. Four columns.
- **Card** (`PanelCard`): raised, radius 14, for a checklist or a group.
- **Choice grid** (`PanelChoiceChip` in a `PanelGrid`): a small set of
  values (aspect ratios) all on screen at once instead of a long radio list.
- **Sheet** (`showPlayerSheet` + `PlayerSheetHeader`): upright a glass
  bottom sheet; **sideways a glass side panel from the right, the whole
  height**, like ⋮ (a bottom sheet held sideways had ~300 dp and cut its
  lists and sliders). `barrierColor: Colors.transparent` for a sheet that
  changes the picture (Display, subtitle delay) so the change can be seen.
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

## 4. MX parity — keep the structure, refine the look
Top bar `← title … ♪ CC HW ⋮`; shortcut row with its expand chevron;
bottom row `lock | ⏮ ⏯ ⏭ | screen-mode PiP`; ⋮ = "Video display" tiles +
the shortcuts checklist. Do not invent a new layout to look modern; make
this one precise.

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
