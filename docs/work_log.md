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
| Analyzer backlog | **1219 → 275.** Steps 1–3 of `analyzer_backlog.md` done. Steps 4–5 open. |
| Tests | **261 on `main`.** `flutter test` is a CI gate with no tolerance flags. Distribution is lopsided — see the entry for the audit series. |
| Flutter SDK | Pinned at 3.32.8. Six minors behind. `upgrade_plan.md` says target 3.38.10, staged. |
| Light mode | Does not exist. Made safe rather than real — `light_mode_audit.md`. |
| Audits | Seven landed (#19–#25). Their findings are now the backlog; see below. |

### Open, in the order I would do them

Reordered after the seven audits landed: their findings outrank the tidying
that was queued before them.

1. **Downloader pre-flight** — `audit_downloader.md` F1/F2/F3. *Done, this
   entry.*
2. **Private Folder: close the intruder camera** — `audit_private_folder.md`
   V1/V2. A successful selfie holds the front camera for the life of the
   process, so Android 12+ leaves the camera indicator lit on a vault app.
3. **Transfer stall watchdog** — `audit_transfer.md` T1/T2. Nothing bounds an
   active download; a stalled batch also holds the Turbo release shut, so the
   phone keeps no internet.
4. **Tests for the pure functions that have none** — `ProbeParser.parse`,
   `extractPath`, `_stripIdTag`, `sanitizeRelDir`. All pure, all zero-coverage,
   all trivially testable. See the note on test distribution below.
5. **A `tool/check.py` checker for settings nothing reads** —
   `audit_library_music_settings.md` L1. Ten prior instances are recorded in
   the tree's own comments and five are open.
6. **Localise the Settings tree** — 267 hardcoded strings while `my`/`th` are
   complete at 425 getters each.
7. **`docs/upgrade_plan.md` step 0** — the 9 `Navigator.of(_)` wildcard params
   (#17, open) and Sentry (#18, open). Both are landmine removal before the
   SDK moves, not after.
8. **`analyzer_backlog.md` steps 4–5**, then **Flutter 3.35 → 3.38**, staged.
9. **Audit Video Hub and the ADB stack** — the two large surfaces the five
   domain audits did not cover.

### Known and deliberately unfixed

- **The theme picker offers three choices that render identically.** Decided,
  not drifting: Light stays selectable and is badged "Coming soon".
  `light_mode_audit.md` §4.
- **`media_kit` is the real upgrade ceiling** — last release Dec 2025, only
  ever claimed Flutter 3.38.x. Not a constraint you can read off pubspec;
  every version declares `flutter: >=3.7.0`.
- **The swipe-kill state-restoration issue.** Raised repeatedly, never scoped.

---

## 2026-09-13 — Seven audits, then the first fix out of them (#19–#25, #26)

### The audits (#19–#25, all merged, no code changed)

`engine_update_audit.md`, `filename_audit.md`, and one per domain:
`audit_downloader.md`, `audit_player.md`, `audit_private_folder.md`,
`audit_transfer.md`, `audit_library_music_settings.md`.

Each carries a **"withdrawn after checking"** section, and those are the most
useful part to read first — they are the shapes that look wrong in this
codebase and are not. Between them: `initBlocking` is `@Synchronized`;
`BROWSER_PROBE_ID` already exists; the intruder selfie *is* implemented in
Camera2; `_copyWithProgress` does clean up its partial; `playerControllerProvider`
is watched conditionally by the PiP overlay; `_bytesServed +=` is not a race;
`userLocale` is a deliberate mirror, not a dead setting.

Each also carries a **do-not-touch list** naming the specific past failure the
odd-looking code answers.

**Two things measured across the tree that are worth keeping in view:**

- **Test distribution is inverted.** 110,311 lines of `lib/`, and the tests
  import 29 of its 302 files. The updater — the least risky area — holds
  roughly half of them. The downloader, transfer, library, music and the
  libmpv service have **zero**. The most testable code (pure functions over
  strings and JSON) is the code with no tests.
- **"A setting nothing reads" is this project's most repeated bug.** Ten
  instances are recorded in the tree's own comments, each found by somebody
  noticing. Five more are open. That is a missing check, not bad luck.

### The first fix (#26): the downloader pre-flight

`audit_downloader.md` F1/F2/F3. A download can start from four places and only
**one** of them asked the mobile-data and free-space questions. Someone who had
switched "Wi-Fi only" on could queue a forty-item playlist over mobile data
without a word — the most expensive finding in any of the seven, because
nothing looks broken and the bill arrives later.

The decision is now a pure function (`download_preflight.dart`) with no
context, no provider and no channel, so the browser path — which has no widget
tree in front of it — can ask the same question the sheets ask, and so it can
be tested without a device. 10 tests, both mutations checked.

**The browser path could not be fixed the same way as the other three**, and
that is the part worth remembering: the in-app browser is a native Activity in
front of Flutter and the downloads screen may never have been built, so there
is nowhere to draw a dialog. Ignoring the setting was the old behaviour.
Instead the row is registered and **held** — paused, with the reason on it —
and the Resume button every paused row already has *is* the "download anyway"
the dialog would have offered.

`heldReason` is a separate field from `line` on purpose: an ordinary pause
keeps the engine's last output in `line`, so reusing it would have printed a
yt-dlp progress line under every paused row.

**F3 came free and was the more embarrassing one.** The browser's
`startDownload` passed no extras at all — no subtitles, no thumbnail, no
metadata, and no **speed limit** — while two separate comments (the call site's
own, and `BrowserPick`'s) claimed that everything but the address, format and
title "stays with Dart, so there is one answer to those questions rather than
two that can drift apart". The playlist sheet twelve lines away passes all
four.

**And reading the diff back found a third home for F3.** `resume()`'s replay
path — the one taken when the engine has no record of a job — passed neither
the cookies, nor the player clients, nor any of the four extras. So a resumed
age-gated download arrived with no cookies and failed for a reason that looks
nothing like the cause. That mattered more after this change than before it: a
held row has no engine record, so `resume` always throws for it and the replay
is the *only* way that download ever runs. Fixed in the same PR.

Not done here, and deliberately: `BrowserPick` carries no size, so only the
metered arm can fire on that path. Adding a size means changing the Kotlin
payload, which is a different change.

---

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
