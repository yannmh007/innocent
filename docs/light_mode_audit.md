# Light mode — what is actually there, and what it would take

Measured 12 Sep 2026 against `main` at `9c1b2b7`. Every number below came from
running something, and the command is given so it can be re-run rather than
believed.

---

## The finding in one line

**Innocent has no light mode.** It has a light *theme object* that no surface
in the app ever honours, and selecting it does not make the app light — it
makes the app unreadable.

This was found while fixing a user report that the Downloader's AppBar looked
"faded" ([#15](https://github.com/yannmh007/innocent/pull/15)). That AppBar was
one of four. The four were the visible corner of ~388.

---

## 1. The app paints itself dark, in every theme

```bash
grep -rn -A4 "Scaffold(" lib/ | grep -cE \
  "backgroundColor: (AppColors\.(dark|black|spec)|Colors\.black|VH\.)"
```

| | count |
|---|---:|
| `Scaffold(` in `lib/` | 76 |
| …hardcoding a dark background | **72** |

The four that do not still end up dark: `local_screen` and `player_screen` use
`specScaffold` / `playerBackground`, both `#000000`; the shell's outer Scaffold
only frames a child screen that paints itself; `adb_connect_screen` sets no
background at all, which turns out to be its own bug (§3).

And nothing outside `app_theme.dart` reads a light colour at all:

```bash
$ grep -rn "AppColors.light\(Background\|Surface\|OnSurface\)" lib/ \
    | grep -v core/theme/
# (no matches)
```

So the light theme's surface colours were never reachable. Only its
**foreground** colours were — through every widget that did not name its own.

---

## 2. Failure mode A — dark surface, theme foreground

A screen sets `backgroundColor: AppColors.darkBackground` and drops in a `Text`
with no colour. The colour comes from the theme:

| theme | unstyled `Text` resolves to | on `#0F0F0F` |
|---|---|---|
| `AppTheme.dark` | `#E0E0E0` | 14.5:1 ✓ |
| `AppTheme.light` | **`#212121`** | **1.19:1** ✗ |

Worse on the darker surfaces the app also uses — `darkSurface` scored
**1.08:1** and true black **1.30:1**.

### How many sites

```bash
# files that paint a dark surface, counting Text( with no color: nearby
python3 tool-less scan — see the PR body for the exact script
```

| | count |
|---|---:|
| Files painting a dark surface | 83 |
| Unstyled `Text(` on those surfaces | **~388** |

The worst offenders, which is also the order a real light mode would have to
tackle them:

| file | unstyled `Text` |
|---|---:|
| `transfer/transfer_screen.dart` | 44 |
| `downloader/downloader_home_screen.dart` | 34 |
| `private_folder/private_folder_screen.dart` | 30 |
| `settings/settings_general_screen.dart` | 17 |
| `downloader/quality_sheet.dart` | 14 |
| `private_folder/add_files_picker.dart` | 12 |
| `player/player_screen.dart` | 12 |
| `video_hub/account/premium_request_screen.dart` | 10 |
| `video_hub/account/account_screen.dart` | 10 |
| `music/music_player_screen.dart` | 10 |
| *…73 more files* | ~195 |

The count is approximate — it is a static scan, so a `Text` whose colour
arrives from an enclosing `DefaultTextStyle` is counted as unstyled. Treat it
as the right order of magnitude, not a work item list.

---

## 3. Failure mode B — the same bug, mirrored

Easy to miss, and it is why "just make the light theme's text white" is not the
fix either.

A screen that sets **no** background inherits `scaffoldBackgroundColor`. Under
the old light theme that was `#FAFAFA`. Those screens then hardcode
`Colors.white54`-style foregrounds, because their author correctly assumed the
app is dark:

`lib/features/settings/presentation/adb_connect_screen.dart` — no Scaffold
background, and `Colors.white54` text at lines 623, 718, 907. White on
`#FAFAFA` measures **1.04:1**.

So the two directions are:

| | background | foreground | result |
|---|---|---|---|
| **A** | hardcoded dark | from the theme | dark on dark |
| **B** | from the theme | hardcoded white | white on white |

Any fix that only moves the theme's foregrounds fixes A and worsens B. The fix
has to move the theme's **surfaces** as well — which is what returning the dark
theme does.

---

## 4. What was changed

`lib/core/theme/app_theme.dart`:

```dart
static ThemeData get light => dark;
```

One line, with a comment carrying the reasoning. It fixes both directions
simultaneously because it makes the theme agree with what the app was already
doing.

**What it costs, stated plainly:** the Adaptive / Light / Dark picker in
Me → App theme now renders identically whichever is chosen. That is a
regression in *honesty of the UI*, and an improvement in *legibility of the
app*. Before this change, choosing Light produced ~388 invisible strings; it
never produced a light app.

**The UI still offers three choices.** Deciding whether to relabel it, hide
Light, or leave it as a placeholder for the real thing is a product call and
was deliberately left alone — see §6.

---

## 5. What now guards it

`test/theme_legibility_test.dart` — 12 cases, and they assert on WCAG contrast
ratios rather than on specific colours, so they survive a legitimate change of
shade while still catching an unreadable one. Helpers in
`test/support/contrast.dart`.

Three groups:

1. **Unstyled text on a hardcoded dark surface** — every theme × the four dark
   surfaces the app actually uses. Covers failure mode A.
2. **The background a bare Scaffold inherits** — must stay dark enough for the
   hardcoded white text the app is full of. Covers failure mode B, which is the
   one a future "let's make light mode real" attempt would otherwise reintroduce.
3. **The AppBar contract** — `appBarTheme.foregroundColor` and
   `titleTextStyle.color` must be declared and legible. This is the theme-level
   default behind [#15](https://github.com/yannmh007/innocent/pull/15);
   `test/appbar_contrast_test.dart` pins the four individual bars.

Verified by mutation: restoring the original `AppTheme.light` fails **6 of the
12**, with these messages —

```
unstyled body text is illegible in light theme on darkBackground          — 1.19:1
unstyled body text is illegible in light theme on darkSurface             — 1.08:1
unstyled body text is illegible in light theme on specScaffold            — 1.30:1
unstyled body text is illegible in light theme on playerBackground        — 1.30:1
hardcoded white text is illegible in light theme on the inherited
                                          scaffold background             — 1.04:1
light declares no appBarTheme.foregroundColor
```

---

## 6. To build a real light mode

Not scoped here, and genuinely large. The order matters, because doing it in
any other sequence produces a half-light app that looks broken rather than
unfinished:

1. **Decide the product question first.** Does Innocent want a light mode? It
   is a dark-first media player; a light mode is a real design project, not a
   theme entry. If the answer is no, the better change is to the picker, not
   the theme.
2. **Introduce semantic colours.** `AppColors.darkBackground` used at 72 call
   sites is the blocker — those sites are naming a *colour*, not a *role*.
   They need to name `surface`, `surfaceElevated`, `onSurface` and resolve
   through `Theme.of(context)`.
3. **Then the 388 unstyled `Text` sites stop mattering**, because the theme
   they fall through to would finally match the surface under them.
4. **Delete `static ThemeData get light => dark;` last**, and expect
   `test/theme_legibility_test.dart` to start failing. Those failures are the
   remaining checklist, not an obstacle.

Steps 2 and 3 are the bulk. Nothing before step 1 is worth starting.

---

## Changelog

| Date | Change |
|---|---|
| 2026-09-12 | Audit written. `AppTheme.light => dark`; `theme_legibility_test.dart` and `support/contrast.dart` added. Measured against `main` @ `9c1b2b7`. |
