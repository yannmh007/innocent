# The analyzer backlog — what the issues actually are

`flutter analyze` reports **295 issues and zero errors**, down from 1219.

That 1219 sat in every CI run and every PR description for months, which was
exactly the problem with it: a count nobody has broken down is a count nobody
can act on, and one that large reads as "this codebase is bad" when the truth
is much more boring. This is the breakdown, and the order to work it in.

**Steps 1 and 2 are done** — see the changelog at the bottom. Steps 3-5 are
not, and they are the ones that need a human reading each site.

Counts below are the CURRENT state unless a column says otherwise. Taken on
Flutter 3.32.8 (the version CI pins). Reproduce with:

```
flutter analyze --no-fatal-infos --no-fatal-warnings
```

The CI step tolerates infos and warnings on purpose — see `.github/workflows/
build.yml`. Errors are NOT tolerated, and there are none.

---

## The headline

**875 of the original 1219 — 72% — were two mechanical things**, neither of
which needed a file-by-file review:

| | count | status |
|---|---:|---|
| One pattern in the player controller (see below) | 514 | **cleared** (step 1) |
| `prefer_const_constructors` and friends, all auto-fixable | 415 | **410 cleared** (step 2) |
| Everything else | 290 | open |

Severity split is now **51 warning, 244 info, 0 error** — it was 565 / 654 / 0.
Step 1 took out 514 warnings and no infos; step 2 took out 410 infos and no
warnings. The two halves of the original 72% were cleanly separable, which is
why neither touched the other's column.

---

## By rule

Current, after steps 1 and 2. The two `invalid_use_of_*` rules that held 514
between them, and every `prefer_*` rule that held 402, are gone from the list.

| rule | count | severity |
|---|---:|---|
| `deprecated_member_use` | 116 | info |
| `unawaited_futures` | 84 | info |
| `use_build_context_synchronously` | 20 | warning |
| `unnecessary_import` | 16 | info |
| `annotate_overrides` | 14 | info |
| `unused_import` | 12 | warning |
| `unused_field` | 9 | warning |
| ~~`no_wildcard_variable_uses`~~ | ~~9~~ **0** | ~~info~~ **error** (PR #17) |
| `unused_element` | 5 | warning |
| `dead_null_aware_expression` | 2 | warning |
| 8 more rules, one each | 8 | mixed |

## By area

| folder | now | at 1219 |
|---|---:|---:|
| `lib/features/private_folder` | 48 | 50 |
| `lib/core/services` | 33 | 35 |
| `lib/features/local_browser` | 31 | 95 |
| `lib/features/video_hub` | 30 | 38 |
| `lib/features/player` | 28 | 587 |
| `lib/features/equalizer` | 24 | 29 |
| `lib/features/user_data` | 21 | 82 |
| `lib/features/transfer` | 18 | 56 |
| `lib/features/downloader` | 18 | 21 |
| `lib/features/settings` | 13 | 51 |
| `lib/features/music` | 13 | 87 |
| `lib/features/me` | 11 | 75 |
| everything else | 7 | 13 |

The ordering has completely inverted, and that is the useful part. `player`
was 48% of the backlog and is now 9% of a much smaller one. `music`, `me` and
`user_data` looked like problem areas and were almost entirely `const` noise.
What is left at the top — `private_folder`, `core/services` — was always the
real remainder; it was just buried under 924 mechanical findings.

### Why the player looked so bad, and why it wasn't

`PlayerController extends StateNotifier<PlayerState>` lives in
`player_provider.dart` and is split across six `part of` files as extensions.
An extension method is not "an instance member of a subclass", so **every
single read or write of `state` from those files trips two lints at once** —
`invalid_use_of_protected_member` and `invalid_use_of_visible_for_testing_
member`.

257 sites, two rules, **514 issues**. The two location sets were
byte-identical; it was the same code counted twice.

Nothing was actually wrong. The extensions are `part of` the same library as
the class, so no encapsulation is broken — the lints simply cannot express
"extension on the class in its own library". Outside those `state` accesses,
the six files contained a grand total of **five** other issues (four
`unawaited_futures`, one `avoid_void_async`), and those five are still there.

**Cleared with an `// ignore_for_file:` on each of the six `part` files**, with
a line above it saying why. The alternative — folding the extensions back into
the class body — would have moved thousands of lines of working player code to
satisfy a lint that is not describing a real problem, which is a much worse
trade than three comment lines per file. Zero code lines changed.

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

### ~~`no_wildcard_variable_uses` — 9 (info)~~ — cleared, PR #17

> Fixed 12 Sep 2026: the nine params are named, and the rule is promoted to
> `error` in `analysis_options.yaml` so CI refuses it coming back. Kept below
> because the reasoning is what justifies the promotion.

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

## (b) Harmless, but should be cleared — 258 left of 772

| what | count | note |
|---|---:|---|
| ~~the player `state` pattern~~ | ~~514~~ | **cleared, step 1** |
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

## (c) Style only — 5 left of 415

`prefer_const_constructors` (361), `prefer_interpolation_to_compose_strings`
(20), `prefer_const_literals_to_create_immutables` (11),
`prefer_const_declarations` (10), `unnecessary_const` (3),
`curly_braces_in_flow_control_structures` (3),
`unnecessary_brace_in_string_interps` (2), and five single instances
(`non_constant_identifier_names`, `prefer_if_null_operators`,
`avoid_renaming_method_parameters`, `avoid_void_async`,
`unnecessary_nullable_for_final_variable_declarations`).

Essentially all of it was `dart fix --apply`, and 410 of the 415 went that way
in step 2. The const constructors save a little rebuild work; none of it
changes behaviour.

**Five were deliberately left**, each for a stated reason — see the step 2
changelog entry below. Two of them (`avoid_void_async`,
`unnecessary_nullable_for_final_variable_declarations`) are the ones to be
careful with if anyone reaches for a blanket `dart fix --apply` later: both
change types or signatures, and both can make the code LESS correct than the
author wrote it.

---

## Suggested order

Highest risk removed per unit of effort, and each step is independently
reviewable:

1. ~~**The player `state` pattern** — 514 gone in one commit, no behaviour
   change. 1219 → 705.~~ **Done.** The prediction held exactly.
2. ~~**`dart fix --apply`** for category (c) — 415 gone, mechanical. 705 → 290.~~
   **Done.** 410 went; five were held back on purpose. 705 → 295.
3. **`use_build_context_synchronously`, 20 by hand.** The only genuine crash
   risk in the list, and the only step that needs judgement.
4. **The upgrade landmines**: ~~`no_wildcard_variable_uses` (9)~~ (done, PR #17) and
   `withOpacity` (107), before the next SDK or Flutter bump rather than during
   it.
5. **`unawaited_futures`, 84 read individually** — the long tail, and where a
   real bug is most likely still hiding.

Steps 1 and 2 were together 76% of the original number and close to zero risk.
Doing them first has made the remaining 295 small enough that the count means
something again, which was the point of the exercise. Every one of steps 3-5
now needs a person reading each site — there is no more mechanical work left.

---

## Changelog

**Step 1 — the player `state` pattern.** `// ignore_for_file:
invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member` on
each of the six `player_controller_*.dart` `part` files, with one line above
each saying why. 18 lines added, none removed, no code touched.

`flutter analyze`: **1219 → 705**, exactly as predicted. Warnings 565 → 51;
infos unchanged at 654 (both rules were warnings); errors still 0. The two
rules no longer appear anywhere in the output. `tool/check.py` 8/8 and all 206
tests still pass.

**Step 2 — the style rules.** `dart fix --apply` restricted with `--code=` to
nine rules, applied to 80 files. **705 → 295.** Infos 654 → 244; warnings
unchanged at 51; errors still 0.

`--code=` rather than a bare `dart fix --apply`, because a bare run also
rewrites `deprecated_member_use`, `unawaited_futures` and
`use_build_context_synchronously` — the three groups that are NOT mechanical
and need a person. The nine applied were `prefer_const_constructors`,
`prefer_const_declarations`, `prefer_const_literals_to_create_immutables`,
`unnecessary_const`, `prefer_interpolation_to_compose_strings`,
`unnecessary_brace_in_string_interps`,
`curly_braces_in_flow_control_structures`, `prefer_if_null_operators` and
`unnecessary_nullable_for_final_variable_declarations`.

**Five findings were held back, and the reasons are worth keeping:**

* `avoid_void_async` (1) — would turn `PlayerController.selectDecoder` from
  `void` into `Future<void>`. Every un-awaited call site then becomes an
  `unawaited_futures` candidate, so a "style" fix would have quietly created
  work in the category that most needs human attention.
* `non_constant_identifier_names` (1) — `_v0_to_v1` in
  `settings_migration_service.dart` is a deliberate convention: the file's own
  doc comment reads *"runs each `_v0_to_v1`, `_v1_to_v2`, ..."*. `dart fix`
  renames the code and not the prose, which desyncs them.
* `avoid_renaming_method_parameters` (1) — `dart fix` offers no fix for it.
* `unnecessary_nullable_for_final_variable_declarations` (1) — this one was
  applied, then REVERTED. In `status_saver_screen.dart` it changed
  `final AssetEntity? asset` to `final AssetEntity asset`, trusting
  `PhotoManager.editor.saveVideo`'s non-nullable signature. The next line is
  `if (asset != null)`, which the author wrote because those plugin methods do
  return null on a failed MediaStore save — the comment directly above says
  so. The fix made the code less defensive than the author deliberately wrote
  it, and turned a working guard into an `unnecessary_null_comparison`
  warning. Reverted; the nullable type stands.
* `prefer_interpolation_to_compose_strings` (1) — applied, then reverted at
  one site in `downloader_home_screen.dart`. `dart fix` produced an
  interpolation that OPENS on one line and CLOSES two lines later. The Dart is
  valid and `flutter analyze` is happy, but `tool/check.py`'s brace-balance
  guard counts 216 vs 217 and fails, which would have turned CI red. Reverted
  rather than hand-rewritten, so this commit stays exactly what `dart fix`
  produced and nothing more.

The last two are the general warning: a blanket `dart fix --apply` on this
repo will change types and will trip the repo's own structural guard. Restrict
it with `--code=` and read the diff.
