# Work log

What has been done, why, and what is deliberately still open. Written so a
session that starts cold can orient without re-deriving anything.

Newest first. Each entry names the PR, what changed, and — more usefully — the
things that were *found and not done*, because those are what the next person
would otherwise rediscover the hard way.

---

## Where things stand right now

| Area | State |
|---|---|
| Updater | Steps 1–7 shipped and phone-tested. §8 of `updater_plan.md` is the next one. |
| Analyzer backlog | **1219 → 266** with #17. Steps 1–3 done, and the wildcard half of 4. Steps 4–5 open. |
| Tests | **251 on `main`** (#16 merged). 268 with #17 + #18. `flutter test` is a CI gate with no tolerance flags. |
| Flutter SDK | Pinned at 3.32.8. Six minors behind. `upgrade_plan.md` says target 3.38.10, staged. |
| Light mode | Does not exist. Made safe and badged "Coming soon" — `light_mode_audit.md`. |
| Crash reporting | Wired, **off** until a build passes a DSN — `crash_reporting.md`. |

### Open, in the order I would do them

**Step 0 of `upgrade_plan.md` is done** — both halves, #17 and #18.

1. **Flutter 3.35.7** — `upgrade_plan.md` step 1. The first SDK step, and the
   one that needs a real phone: `targetSdk` goes 35 → 36 by inheritance, which
   opts the app into Android 16's non-optional edge-to-edge. NDK stays at 27,
   which is what this repo already pins — that is why 3.35 is its own step.
2. **`analyzer_backlog.md` step 4** — 107 `withOpacity`. (The 9 wildcards that
   used to be in this line are done.)
3. **`analyzer_backlog.md` step 5** — 84 `unawaited_futures`. Needs a person
   per site; not mechanical.
4. **Flutter 3.38.10** — `upgrade_plan.md` step 2. Brings NDK 28.2 and the
   JDK 17 floor; both need the CI file edited in the same commit.
5. **`media_kit_video` 1.3.1, then 2.0.1** — follow `media_kit_upgrade.md`
   exactly. Budget `screen_brightness` → 2.1.11 in the same commit; it is not
   optional, it is a resolver requirement.

### Known and deliberately unfixed

- **The theme picker offers three choices that render identically.** Decided,
  not drifting: Light stays selectable and is badged "Coming soon".
  `light_mode_audit.md` §4.
- **`media_kit` is the real upgrade ceiling** — last release Dec 2025, only
  ever claimed Flutter 3.38.x. Not a constraint you can read off pubspec;
  every version declares `flutter: >=3.7.0`.
- **The swipe-kill state-restoration issue.** Raised repeatedly, never scoped.

---

## 2026-09-12 — Crash reporting, off by default (#18)

`sentry_flutter` 9.30.0, which needed no SDK move — the project is eight
minors past its floor. **The SDK is never initialised without
`--dart-define=SENTRY_DSN=…`,** which CI does not pass, so the APK CI builds
is unchanged. Four tests pin that, and they *invert* with a DSN compiled in,
which is the proof they test the gate and not something incidental.

Everything that does leave passes through `crash_redaction.dart` (13 tests).
The breadcrumb messages this app writes are all structural — **the leak was
always going to be exceptions**, because a `FileSystemException` carries the
path it failed on and that path is the name of somebody's video.

Three things worth carrying forward:

- **Order in `main.dart` is load-bearing and the failure is silent.** Sentry
  must start AFTER `PlatformDispatcher.onError` is assigned. Before it, the
  assignment overwrites Sentry's handler and no async error is ever reported
  while everything still looks fine. Sentry chains and preserves the app's
  `return true` — verified by reading `on_error_integration.dart`, not assumed.
- **The redactor must not eat stack frames.** An over-eager path pattern would
  make the whole feature worthless; there is a test asserting a three-frame
  trace survives byte-identical.
- `attachScreenshot` / `attachViewHierarchy` are off. Either would defeat the
  redactor in one attachment.

`docs/crash_reporting.md` has the privacy design and the switch.

## 2026-09-12 — The 9 wildcard params, and a CI gate (#17)

275 → 266. The nine `Navigator.of(_)` reads compiled only because pubspec
declares `sdk: '>=3.4.0'`; Dart 3.7 made `_` non-binding, so they were one
housekeeping-looking line away from nine compile errors. Measured both ways:
raising the bound gave 9 errors before, 0 after.

**A dead end worth not repeating.** I wrote `tool/wildcard_params.py` in the
style of `context_scope.py` first. It produced 25 false positives on the fixed
tree — it flagged `catch (_)` and cannot scope a Dart callback with a regex.
Deleted. The right mechanism was already one line away in
`analysis_options.yaml`:

    no_wildcard_variable_uses: error

`error` is the one severity CI's `--no-fatal-infos --no-fatal-warnings` does
not suppress, and it uses the analyzer's own implementation, so there is
nothing to tune. Verified in both directions with CI's exact command.

Also: only ONE of `player_screen.dart`'s five `builder: (_)` reads its
parameter. `_` is correct where a value is ignored; do not sweep them all.

## 2026-09-12 — Light mode made safe and honestly labelled (#16)

**#15 and #16 were combined into #16** once the product question was answered;
#15 was closed as absorbed, not abandoned. Its four AppBar fixes are in here.

`AppTheme.light => dark`, one line, plus the "Coming soon" badge on the Light
card, `theme_legibility_test.dart` (12 cases),
`theme_picker_badge_test.dart` (3) and `test/support/contrast.dart`.

**The finding is bigger than the change.** 72 of 76 Scaffolds hardcode a dark
background and nothing outside `app_theme.dart` reads a light colour, so
selecting Light never produced a light app — it produced ~388 unstyled `Text`
widgets at 1.19:1 on surfaces that stayed dark. Plus the mirror case
(`adb_connect_screen`: no background, hardcoded `Colors.white54`, 1.04:1 on the
inherited `#FAFAFA`), which is why moving only the theme's foregrounds would
have fixed one direction and broken the other.

Full measurements, per-file counts and the roadmap to a real light mode:
`docs/light_mode_audit.md`.

### The AppBar half (originally #15)

The user-reported symptom of the above: the Downloader AppBar at 1.19:1. Fixed
four bars (`downloader_home`, `customise_items`, `folder_send_picker`,
`transfer_screen`); **six others hardcode a dark background but already set
their own foreground and were left alone** on purpose. `appbar_contrast_test.dart`
pins all four.

Two things worth remembering:

- `foregroundColor` alone is **not** enough. `AppTheme.dark.appBarTheme.titleTextStyle`
  carries its own `#E0E0E0` and outranks it, so a one-line fix would have left
  dark-mode users with white icons above a grey title.
- The first version of that test claimed in its own comment to catch a
  regression it did not. Mutation testing caught the lie; a consistency
  assertion was added.

## 2026-09-12 — BuildContext across async gaps, and a real bug (#14)

20 `use_build_context_synchronously` sites by hand (295 → 275) — no `dart fix`,
because the right answer differed per site: 6 pre-captures, 4 `context.mounted`
(where `build`'s parameter shadows `State.context`), 10 plain guards.

Two decisions were the user's, and are recorded in the code: a sheet whose
screen dies across its `pause()` await **stays paused** rather than resuming
under a screen the user left; `_enterPip` **bails entirely** rather than
leaving a floating video with no player behind it.

Also fixed a genuine crash in the same PR: `add_files_picker.dart` called
`setState` inside `if (!mounted)`. Swept `lib/` — it was the only one.

**Trap for next time:** `quality_sheet.dart`'s pop needed `if (mounted) …`, not
`if (!mounted) return`. An early return there would have turned a lint fix into
a silently dropped download.

## 2026-09-11 — Flutter/Dart upgrade survey (#13)

`docs/upgrade_plan.md`. No code. The headline is counter-intuitive: the SDK is
the *cheap* part (Flutter 3.41 needs zero Gradle/AGP/Kotlin change), and one
package — `media_kit` — is the ceiling.

**The single most useful thing in it:** Flutter's own Gradle/AGP/JDK floors are
not in the release notes in any diffable form. Read them out of
`DependencyVersionChecker.kt` at each release tag; the doc has the command.

## 2026-09-11 — Player logic tests (#12)

22 tests, nothing in `lib/`. Position clamping, resume-point auto-save, decoder
switch, surface detach/reattach ordering. Extracted verbatim from the shipped
code, which means **they can drift** — that limitation is stated in the file.

## 2026-09-11 — dart fix style lints (#11)

705 → 295, 80 files, `--code=` restricted rather than a blanket run. Five
findings held back; two mattered enough to record: `dart fix` made
`status_saver_screen.dart` *less* defensive by removing a deliberate nullable,
and a string interpolation it produced tripped `tool/check.py`'s brace guard.

**Do not run a bare `dart fix --apply` on this repo.**

## 2026-09-11 — Player part-file lints (#10)

1219 → 705 with 18 lines. `PlayerController` is split into `part` extensions,
and an extension is not an instance member, so every `state` access tripped
`invalid_use_of_protected_member`. 514 of the 1219 were that one false
positive.

## 2026-09-11 — .gitignore + analyzer backlog (#9)

`docs/analyzer_backlog.md`, and ignore rules for what `flutter pub get`
generates. `pubspec.lock` is **committed** deliberately — there is a comment in
`.gitignore` saying so, because it looks like an omission.

## Earlier — updater steps 1–7

`docs/updater_plan.md` is authoritative. The parts worth knowing without
reading it:

- **`priority` never blocks. `min_supported` alone blocks.** The doc's §2 was
  corrected to match the code, not the other way round: a stray `priority=5`
  typed into the SQL editor must not be able to lock anyone out.
- Four hard safety guards on the blocking screen, each with a test: fail-open
  on a failed or malformed fetch, never block above the latest real release,
  and the blocking screen must still reach the download/install flow.
- `Intent.filterEquals` ignores extras — which is why the update notification
  uses a distinct request code from the download one.
