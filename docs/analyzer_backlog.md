# The analyzer backlog — what the 1219 issues actually are

`flutter analyze` reports **1219 issues and zero errors**. That number has sat
in every CI run and every PR description for months, which is exactly the
problem with it: a count nobody has broken down is a count nobody can act on,
and one that large reads as "this codebase is bad" when the truth is much more
boring.

This is the breakdown. Nothing here has been fixed — it is a map, so the work
can be done in the order that actually removes the most risk.

Snapshot taken on Flutter 3.32.8 (the version CI pins) at commit `397e1bb`.
Reproduce with:

```
flutter analyze --no-fatal-infos --no-fatal-warnings
```

The CI step tolerates infos and warnings on purpose — see `.github/workflows/
build.yml`. Errors are NOT tolerated, and there are none.

---

## The headline

**875 of the 1219 — 72% — are two mechanical things**, neither of which needs
a file-by-file review:

| | count | share |
|---|---:|---:|
| One pattern in the player controller (see below) | 514 | 42% |
| `prefer_const_constructors` and friends, all auto-fixable | 415 | 34% |
| Everything else | 290 | 24% |

Severity split: **565 warning, 654 info, 0 error.**

---

## By rule

| rule | count | severity |
|---|---:|---|
| `prefer_const_constructors` | 361 | info |
| `invalid_use_of_protected_member` | 257 | warning |
| `invalid_use_of_visible_for_testing_member` | 257 | warning |
| `deprecated_member_use` | 116 | info |
| `unawaited_futures` | 84 | info |
| `use_build_context_synchronously` | 20 | warning |
| `prefer_interpolation_to_compose_strings` | 20 | info |
| `unnecessary_import` | 16 | info |
| `annotate_overrides` | 14 | info |
| `unused_import` | 12 | warning |
| `prefer_const_literals_to_create_immutables` | 11 | info |
| `prefer_const_declarations` | 10 | info |
| `unused_field` | 9 | warning |
| `no_wildcard_variable_uses` | 9 | info |
| `unused_element` | 5 | warning |
| `unnecessary_const` | 3 | info |
| `curly_braces_in_flow_control_structures` | 3 | info |
| `dead_null_aware_expression` | 2 | warning |
| `unnecessary_brace_in_string_interps` | 2 | info |
| 8 more rules, one each | 8 | mixed |

## By area

| folder | count |
|---|---:|
| `lib/features/player` | **587** |
| `lib/features/local_browser` | 95 |
| `lib/features/music` | 87 |
| `lib/features/user_data` | 82 |
| `lib/features/me` | 75 |
| `lib/features/transfer` | 56 |
| `lib/features/settings` | 51 |
| `lib/features/private_folder` | 50 |
| `lib/features/video_hub` | 38 |
| `lib/core/services` | 35 |
| `lib/features/equalizer` | 29 |
| `lib/features/downloader` | 21 |
| everything else | 13 |

Five files hold 509 of them:

```
133  player_controller_gestures.dart
127  player_controller_playback.dart
 98  player_controller_modes.dart
 97  player_controller_controls.dart
 54  player_controller_tracks.dart
```

### Why the player looks so bad, and why it isn't

`PlayerController extends StateNotifier<PlayerState>` lives in
`player_provider.dart` and is split across six `part of` files as extensions.
An extension method is not "an instance member of a subclass", so **every
single read or write of `state` from those files trips two lints at once** —
`invalid_use_of_protected_member` and `invalid_use_of_visible_for_testing_
member`.

257 sites, two rules, **514 issues**. The two location sets are byte-identical;
it is the same code counted twice.

Nothing is actually wrong. The extensions are `part of` the same library as the
class, so no encapsulation is being broken — the lints simply cannot express
"extension on the class in its own library". Outside those `state` accesses,
the six files contain a grand total of **five** other issues (four
`unawaited_futures`, one `avoid_void_async`).

Two ways to clear it: an `// ignore_for_file:` pair at the top of each `part`,
or folding the extensions back into the class body. The first is two lines per
file and changes no behaviour.

---

## (a) Could be a real bug — 32

The only group worth reading line by line.

### `use_build_context_synchronously` — 20 (warning)

A `BuildContext` used after an `await`. If the user dismisses the sheet or
navigates away while the await is in flight, the element is deactivated and the
lookup throws *"Looking up a deactivated widget's ancestor"*.

The worst of them is `video_option_menu.dart:494–505`, where the await is a
**biometric prompt** — seconds long, and dismissable by the user by design:

```dart
if (await bio.canCheck()) {
  final ok = await bio.authenticate(
      reason: AppStrings.of(sheetContext).verifyToLock);
```

| file | count |
|---|---:|
| `local_browser/presentation/widgets/video_option_menu.dart` | 7 |
| `player/presentation/player_screen.dart` | 3 |
| `downloader/presentation/quality_sheet.dart` | 3 |
| `private_folder/presentation/private_folder_screen.dart` | 2 |
| `private_folder/presentation/add_files_picker.dart` | 2 |
| `player/presentation/widgets/bookmarks_sheet.dart` | 1 |
| `player/presentation/widgets/cut_sheet.dart` | 1 |
| `transfer/presentation/folder_send_picker.dart` | 1 |

The fix is a `if (!ctx.mounted) return;` after each await, which also documents
what should happen when the user walks away mid-flow — a question these call
sites currently do not answer.

### `no_wildcard_variable_uses` — 9 (info)

`showDialog(builder: (_) => ... Navigator.of(_).pop())`.

**This works today.** `pubspec.yaml` declares `sdk: '>=3.4.0'`, so the package's
language version predates wildcard variables and `_` still binds as an ordinary
parameter.

It stops working the day the SDK lower bound is raised to 3.7 or above: `_`
becomes a non-binding wildcard and `Navigator.of(_)` is an undefined name. That
is a **build break, not a silent misbehaviour** — which is the good outcome, but
it will land on whoever bumps the SDK, in nine places at once, and it will not
be obvious why.

Files: `user_data/presentation/history_screen.dart` (2),
`recycle_bin_screen.dart` (4), `watch_later_screen.dart` (2),
`player/presentation/player_screen.dart` (1). The fix is renaming `_` to `ctx`.

### `dead_null_aware_expression` (2) and `unnecessary_null_comparison` (1)

No runtime misbehaviour — but each one is a guard the author wrote that the
type system says can never fire, which usually means a type stopped being
nullable and the guard was left behind. Worth reading for what the author
*expected*:

* `core/services/file_transfer/download_isolate.dart:234` —
  `throw lastError ?? Exception('Download failed')`. The fallback is
  unreachable, so that message can never be seen.
* `core/services/video_player/media_kit_player_service.dart:511` —
  `_currentHwdec ?? "-"` in a log line.
* `features/downloader/presentation/quality_sheet.dart:885` — `sel != null &&
  ...` where `sel` cannot be null.

---

## (b) Harmless, but should be cleared — 772

| what | count | note |
|---|---:|---|
| the player `state` pattern | 514 | one decision, see above |
| `deprecated_member_use` | 116 | `withOpacity` ×107, `onPopInvoked` ×7, `WidgetState*` ×2 |
| `unawaited_futures` | 84 | the group most likely to hide a real bug |
| imports (`unused` 12, `unnecessary` 16, `duplicate` 1) | 29 | |
| dead declarations (`unused_field` 9, `unused_element` 5) | 14 | |
| `annotate_overrides` | 14 | missing `@override` |
| `deprecated_export_use` | 1 | `BytesBuilder` imported indirectly |

**`deprecated_member_use` is the same shape of risk as the wildcards**: 107
`withOpacity` calls compile today and will not on some future Flutter. Both are
paid for on an upgrade day, both are mechanical, and both are much cheaper to
do before the upgrade than during it.

**`unawaited_futures` deserves a manual pass rather than a bulk fix.** A
fire-and-forget `Future` swallows its errors; most of the 84 are deliberate,
but this is the only category where reading them one by one is likely to turn
up something that is actually broken. Concentrated in `private_folder` (19),
`downloader` (12), `player` (11), `core/services` (10).

**The dead declarations may be unfinished features rather than litter.**
`adb_connect_screen.dart` has an unreferenced `_pairMdns` and `_connectMdns`;
`equalizer_screen.dart` and `audio_effect_sheet.dart` both carry unused
`_bassBoostEnabled` / `_virtualizerEnabled` fields. Deleting them is correct
only if nobody meant to wire them up.

---

## (c) Style only — 415

`prefer_const_constructors` (361), `prefer_interpolation_to_compose_strings`
(20), `prefer_const_literals_to_create_immutables` (11),
`prefer_const_declarations` (10), `unnecessary_const` (3),
`curly_braces_in_flow_control_structures` (3),
`unnecessary_brace_in_string_interps` (2), and five single instances
(`non_constant_identifier_names`, `prefer_if_null_operators`,
`avoid_renaming_method_parameters`, `avoid_void_async`,
`unnecessary_nullable_for_final_variable_declarations`).

Essentially all of it is `dart fix --apply`. The const constructors save a
little rebuild work; none of it changes behaviour. Spread fairly evenly:
`music` 66, `user_data` 59, `me` 59, `local_browser` 55, `player` 37,
`transfer` 36.

---

## Suggested order

Highest risk removed per unit of effort, and each step is independently
reviewable:

1. **The player `state` pattern** — 514 gone in one commit, no behaviour
   change. 1219 → 705.
2. **`dart fix --apply`** for category (c) — 415 gone, mechanical. 705 → 290.
3. **`use_build_context_synchronously`, 20 by hand.** The only genuine crash
   risk in the list, and the only step that needs judgement.
4. **The upgrade landmines**: `no_wildcard_variable_uses` (9) and
   `withOpacity` (107), before the next SDK or Flutter bump rather than during
   it.
5. **`unawaited_futures`, 84 read individually** — the long tail, and where a
   real bug is most likely still hiding.

Steps 1 and 2 are together 76% of the number and close to zero risk. Doing them
first makes the remaining 290 small enough that the count means something
again, which is the point of the exercise.
