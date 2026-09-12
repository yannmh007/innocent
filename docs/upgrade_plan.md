# The upgrade route — Flutter, Dart and the package tree

Surveyed 11 Sep 2026 against `main` at `596ab26`. **No code was changed to
produce this document.** Every number below was measured, not recalled; the
command that produces each one is given so the next reader can re-run it
rather than trust it.

Companion documents: [`media_kit_upgrade.md`](media_kit_upgrade.md) owns the
player-package decision and this document defers to it (and closes one
question it left open, in §3). [`analyzer_backlog.md`](analyzer_backlog.md)
owns the lint backlog; the two overlap at exactly one place, §4.

---

## The short version

The project is **six minor versions behind** Flutter stable. The instinct is
to read that as six versions of debt. It isn't, and the reason is the whole
point of this survey:

- **The Flutter SDK is the cheap part.** Reaching Flutter 3.41 costs *zero*
  changes to Gradle, AGP, Kotlin or the JDK. The pins this repo already
  carries clear every floor up to and including 3.44.
- **The expensive part is one package: `media_kit`.** The newest release of
  the player stack shipped 2 December 2025, and the only Flutter version it
  has ever claimed to support is **3.38.x**. Flutter 3.41, 3.44 and 3.47 were
  all released afterwards with no response from the package.
- **So the ceiling is 3.38, and it is not set by Flutter.** Jumping to 3.47
  would mean running the app's core subsystem three Flutter releases past
  anything its author has tested.

**Recommendation: stage it, and stop at 3.38.10. Do not jump to 3.47.**
Sentry needs no upgrade at all and can go in today.

---

## 1. Where the project actually is

| | Version | Evidence |
|---|---|---|
| Flutter | **3.32.8** (stable, 25 Jul 2025) | `flutter --version` |
| Dart | **3.8.1** | same |
| **Language version** | **3.4** | `pubspec.yaml` → `sdk: '>=3.4.0 <4.0.0'` |
| Latest Flutter stable | **3.47.3** (Dart 3.13.3, 9 Sep 2026) | `releases_linux.json` |

The Dart **language version** is not the Dart SDK version. It comes from the
lower bound of `environment.sdk`, and it is what decides which language
semantics your files get. Keep that distinction in hand — §4 turns on it.

The stable line between here and the top:

| Flutter | Dart | Released |
|---|---|---|
| **3.32.8** | 3.8.1 | 2025-07-25 ← **here** |
| 3.35.7 | 3.9.2 | 2025-10-23 |
| 3.38.10 | 3.10.9 | 2026-02-11 |
| 3.41.9 | 3.11.5 | 2026-04-30 |
| 3.44.9 | 3.12.2 | 2026-08-06 |
| 3.47.3 | 3.13.3 | 2026-09-09 |

CI pins `3.32.8` deliberately — `.github/workflows/build.yml` carries a long
comment explaining that unpinned `channel: stable` resolved to 3.47.2 and died
on the Gradle floor. That comment is correct and §5 quantifies it.

---

## 2. `flutter pub outdated` — and which way the constraints point

```
flutter pub outdated          # 28 dependencies constrained below a resolvable version
flutter pub upgrade --major-versions --dry-run
```

### 2a. What is reachable *today*, with no SDK move at all

A `--major-versions` upgrade on the current Flutter would move **11 direct
dependencies across a major boundary** right now:

| Package | Now | Reachable today | App-code surface |
|---|---|---|---|
| `flutter_riverpod` | 2.6.1 | **3.3.2** | 56 `StateNotifierProvider`, 897 `ref.read`/`watch` |
| `go_router` | 14.8.1 | **17.0.0** | 11 `GoRoute`, 33 nav calls |
| `mobile_scanner` | 5.2.3 | **7.4.1** | 1 site |
| `screen_brightness` | 0.2.2+1 | **2.1.11** | 3 sites, 1 file |
| `permission_handler` | 11.4.0 | **13.0.2** | 16 sites |
| `share_plus` | 10.1.4 | **12.0.2** | 10 `Share.share` |
| `file_picker` | 8.3.7 | **11.0.3** | 8 sites |
| `device_info_plus` | 10.1.2 | **12.4.0** | 2 sites |
| `network_info_plus` | 5.0.3 | **7.0.0** | 1 site |
| `flutter_secure_storage` | 9.2.4 | **10.3.2** | 5 sites |
| `flutter_volume_controller` | 1.3.4 | **2.0.1** | 2 sites, 1 file |
| `media_kit_video` | 1.2.5 | **2.0.1** | see §3 |
| `flutter_lints` | 4.0.0 | **6.0.0** | lint config only |

**This is the survey's least expected result.** The package debt is larger
than the SDK debt and mostly independent of it. Thirteen major-version bumps
are sitting there on the current Flutter, and the largest single migration in
the project — Riverpod 2 → 3 — needs no Flutter change whatsoever.

### 2b. What the *current SDK* is genuinely holding back

These are the packages whose latest release names a Flutter floor above
3.32.8. Read this as the unlock schedule:

| Unlocks at | Packages |
|---|---|
| **Flutter 3.35** | `shared_preferences` 2.5.5, `flutter_volume_controller` 2.0.2, `cupertino_icons` 1.0.9, `intl` 0.20.3 |
| **Flutter 3.38.1** | `file_picker` 12.3.0, `device_info_plus` 13.2.0, `local_auth` 3.0.2, `share_plus` 13.3.0, `network_info_plus` 8.2.1, `package_info_plus` 10.2.1, `path_provider` 2.1.6 |
| **Flutter 3.44** | `go_router` 18.0.1, `wakelock_plus` 1.8.0, `sqflite` 2.4.4, `flutter_riverpod` 3.4.3 |
| **Flutter 3.47** | *— nothing —* |

**Nothing in this dependency tree requires Flutter 3.47.** Not one package.
Whatever the argument for 3.47 is, "the packages need it" is not it.

### 2c. One constraint knot worth knowing about

`flutter_secure_storage` 11.1.0 declares `flutter >=3.19.0` — it *looks*
reachable today. It isn't, and the reason is not the SDK:

```
flutter_secure_storage 11 → flutter_secure_storage_windows 4.2.2 → win32 ^6.0.1
network_info_plus 5.0.3                                          → win32 >=4.0.0 <6.0.0
```

An Android-only app is blocked from a security package by **`win32`**, a
Windows-only transitive dependency it never ships. The release of
`network_info_plus` that lifts the `win32` cap needs Flutter 3.38.1 — so this
knot unties itself at 3.38 and cannot be untied before it. Verified:

```
$ flutter pub add flutter_secure_storage:^11.1.0      # on 3.32.8
   ... version solving failed.
```

This is the reason to distrust a declared `flutter:` constraint as a
readiness signal, which is exactly the trap §3 is about.

---

## 3. `media_kit` — the real ceiling

### 3a. The declared constraints are worthless here

| Version | Declared `flutter:` | Published |
|---|---|---|
| `media_kit` 1.2.6 | *(none at all)* | 2025-12-13 |
| `media_kit_video` 1.2.4 | `>=3.7.0` | 2023-10-19 |
| `media_kit_video` 1.2.5 | `>=3.7.0` | 2024-08-22 |
| `media_kit_video` 1.3.0 | `>=3.7.0` | 2025-03-24 |
| `media_kit_video` 1.3.1 | `>=3.7.0` | 2025-10-05 |
| `media_kit_video` 2.0.0 | `>=3.7.0` | 2025-11-14 |
| `media_kit_video` 2.0.1 | `>=3.7.0` | 2025-12-02 |
| `media_kit_libs_video` 1.0.7 | `>=3.7.0` | 2025-10-05 |
| `media_kit_libs_android_video` 1.3.8 | `>=3.3.0` | 2025-10-05 |

Every version of `media_kit_video` ever published declares `flutter >=3.7.0`
— a floor from February 2023 that has never moved, through a native rendering
rewrite and a major version. `media_kit` itself declares no Flutter
constraint at all.

**These numbers carry no information.** A resolver will cheerfully install
this stack on Flutter 3.47 and report no conflict. That is not support; it is
an unmaintained field in a pubspec.

> This closes the question [`media_kit_upgrade.md`](media_kit_upgrade.md)
> left open under *"Trap 1: The Flutter floor is probably higher than our
> pubspec says"*. The answer is that the declared floor is `>=3.7.0` on every
> version — so the doc was right to distrust it, and right for a stronger
> reason than it knew: the constraint is not merely stale, it is constant.

### 3b. The changelog is the only real signal

```
## 2.0.1  — fix: flutter 3.38.x crash
## 2.0.0  — feat: flutter 3.38.x support
           BREAKING: remove screen_brightness and volume_controller deps
```

The newest release of the player stack exists **to support Flutter 3.38.x**,
and its patch exists to fix a 3.38.x crash. That is the high-water mark.

What has happened since `media_kit_video` 2.0.1 shipped on 2 Dec 2025:

| Flutter | Released | media_kit response |
|---|---|---|
| 3.38.4 | 2025-12-04 | supported (2.0.0/2.0.1, two days earlier) |
| 3.41.0 | 2026-02-11 | **none** |
| 3.44.0 | 2026-05-18 | **none** |
| 3.47.0 | 2026-08-12 | **none** |

Nine months, three Flutter minors, no release and no prerelease across any of
the five `media_kit_*` packages.

**This is the finding that sets the target.** For every other package in this
project, "behind" means missing features. For the package that renders every
frame of video this app exists to play, "three untested Flutter releases
ahead" means the surface lifecycle, the texture path and the PiP handoff are
all running on a combination nobody has exercised. The app already carries a
hand-built workaround for exactly one such mismatch — the `vo=null` /
`force-window=no` screen-off stack documented in `media_kit_upgrade.md`.
Acquiring a second one by choice is not an upgrade.

### 3c. A `media_kit_video` bump forces `screen_brightness` — now a fact

`media_kit_upgrade.md` flagged this as a maybe ("*`screen_brightness` **may**
be dragged to a new major*"). It is a certainty:

```
$ # media_kit_video: ^1.3.1, nothing else changed
$ flutter pub get
Because media_kit_video ^1.3.0 depends on screen_brightness_platform_interface ^2.0.0,
screen_brightness ^0.2.2+1 is incompatible with media_kit_video ^1.3.0.
version solving failed.
* Try upgrading your constraint on screen_brightness: flutter pub add screen_brightness:^2.1.11
```

`1.3.0` and `1.3.1` depend on `screen_brightness_platform_interface ^2.0.0`
and `volume_controller ^3.0.2`. The app's `screen_brightness: ^0.2.2+1`
cannot coexist with either. **Two major versions, unavoidable, in the same
commit as the player bump.**

The good news, and it is worth stating because "two major versions" sounds
worse than it is: `lib/core/services/brightness/brightness_service.dart` uses
exactly three symbols — `.current`, `setScreenBrightness()`,
`resetScreenBrightness()` — and **all three still exist in 2.1.11** as
deprecated aliases for `.application`, `setApplicationScreenBrightness()` and
`resetApplicationScreenBrightness()`. The jump costs **zero lines to compile**
and three lines to clean up, in one file.

`media_kit_video` 2.0.0 drops both dependencies entirely, so past that point
the app owns brightness and volume outright — which it already does, via its
own direct `screen_brightness` and `flutter_volume_controller` pins.

---

## 4. What breaks when Flutter goes up

Four separate things, and they are triggered by four different knobs. Keeping
them apart is most of the value of this section.

### 4a. The 9 wildcards — a compile error, and Flutter does not cause it

All nine are the same shape: `Navigator.of(_)` inside a `builder: (_) {…}`.

```
lib/features/player/presentation/player_screen.dart:1241
lib/features/user_data/presentation/history_screen.dart:84, 89
lib/features/user_data/presentation/recycle_bin_screen.dart:67, 72, 223, 230
lib/features/user_data/presentation/watch_later_screen.dart:56, 61
```

Dart 3.7 made `_` a non-binding wildcard. Under the project's **language
version 3.4**, `_` still binds, so the code compiles and the analyzer only
emits an info. Raise the language version and the same nine lines become
errors. Measured, by raising only `environment.sdk` and changing nothing else:

```
$ sed -i "s/sdk: '>=3.4.0 <4.0.0'/sdk: '>=3.7.0 <4.0.0'/" pubspec.yaml
$ flutter analyze          # still Flutter 3.32.8
  error • Undefined name '_' • player_screen.dart:1241:43 • undefined_identifier
  ... 9 errors
```

**The trigger is `pubspec.yaml`, not the Flutter SDK.** You can upgrade
Flutter all the way to 3.47 with `sdk: '>=3.4.0'` untouched and these nine
lines keep compiling. They only bite when someone raises the lower bound —
which is a one-line edit that looks like housekeeping and is not.

Fix: name the parameter (`builder: (ctx) => … Navigator.of(ctx) …`). Nine
lines, four files, no behaviour change. **Do this before anything else** —
it is free, it is independent of every other step, and it removes a landmine
from a line that a future contributor will otherwise edit innocently.

### 4b. Deprecations — 117 sites, none fatal yet

| API | Count | Replacement |
|---|---|---|
| `withOpacity` | **107** | `withValues(alpha: …)` |
| `onPopInvoked` | **7** | `onPopInvokedWithResult` |
| `MaterialState` / `MaterialStateProperty` | 2 | `WidgetState` / `WidgetStateProperty` |
| `BytesBuilder` indirect import | 1 | `import 'dart:typed_data'` |

All 117 still compile on every Flutter version in the table — they are
`deprecated_member_use`, not removals. They are also the entirety of
`analyzer_backlog.md` step 4, so the two documents agree on one list.

`withOpacity` is worth its own note: it is not a rename. `withOpacity(0.5)`
and `withValues(alpha: 0.5)` differ in precision handling, so a blanket
`sed` is a visual change across 107 sites in a dark-themed media UI. `dart fix
--apply --code=deprecated_member_use` handles it correctly; a regex does not.

**A search that came back empty is also a result.** These were checked and
this codebase has none of them: `WillPopScope`, `textScaleFactor`,
`describeEnum`, `RawKeyEvent`/`RawKeyboard`, `Color.value`, the removed
`ColorScheme.background`/`surfaceVariant` members, and
`WidgetsBinding.instance.window`. The apparent `window.` and `.green`/`.blue`
hits are comments and `Colors.green` — false positives, all 20 of them.

### 4c. `targetSdk` 35 → 36, at the very first step

`android/app/build.gradle.kts` sets `targetSdk = flutter.targetSdkVersion`,
so the target level is inherited from the SDK and moves without anyone
editing it:

| Flutter | compileSdk | targetSdk | minSdk | NDK |
|---|---|---|---|---|
| **3.32.8** | 35 | **35** | 21 | 26.3.11579264 |
| 3.35.7 | 36 | **36** | 24 | 27.0.12077973 |
| 3.38.10 → 3.47.3 | 36 | **36** | 24 | **28.2.13676358** |

Two consequences, both arriving without a diff to look at:

1. **`targetSdk` 35 → 36 at Flutter 3.35** opts the app into Android 16
   behaviour — most significantly, edge-to-edge display that an app can no
   longer opt out of. For a full-screen video player with PiP, a floating
   window and custom inset handling, that is the single largest *behavioural*
   risk in this whole document, and it lands on the first step.

   **The app is already prepared for it**, which is why this is a caution and
   not a blocker: `lib/main.dart:171` already calls
   `SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`, there are
   68 `SafeArea` usages, `styles.xml` already sets
   `windowLayoutInDisplayCutoutMode=shortEdges`, and
   `video_hub_screen.dart:115` already carries a comment about Android 15
   enforcing edge-to-edge. Verify on a phone with a gesture bar and a notch;
   do not assume, but do not fear it either.

2. **NDK 27 → 28.2 at Flutter 3.38.** The repo pins
   `ndkVersion = "27.0.12077973"` in `build.gradle.kts` *and* installs exactly
   that one in CI (`sdkmanager "ndk;27.0.12077973"`). Those two lines must
   move together and in the same commit, or the build fails with an error
   naming neither file — a failure mode the workflow's own comments already
   warn about for `compileSdk`.

### 4d. Gradle / AGP / Kotlin — where the hard wall actually is

From `DependencyVersionChecker.kt` at each release tag. Below `error`, the
build **refuses**; below `warn` it builds and complains.

Repo pins: **Gradle 8.10.2**, **AGP 8.7.0**, **Kotlin 2.1.0**, CI **JDK 17**.

| Flutter | Gradle error&nbsp;< | AGP error&nbsp;< | KGP error&nbsp;< | Java error&nbsp;< | Verdict |
|---|---|---|---|---|---|
| 3.32.8 | 7.0.2 | 7.0.0 | 1.7.0 | 11 | ✅ here |
| 3.35.7 | 8.3.0 | 8.1.1 | 1.8.10 | 11 | ✅ **clears, no change** |
| 3.38.10 | 8.3.0 | 8.1.1 | 1.8.10 | 17 | ✅ **clears, no change** |
| 3.41.9 | 8.3.0 | 8.1.1 | 1.8.10 | 17 | ✅ **clears, no change** |
| 3.44.9 | 8.7.0 | 8.6.0 | 2.0.0 | 17 | ⚠️ clears all three, but all three warn |
| **3.47.3** | **8.14.0** | **8.11.1** | **2.2.20** | 17 | ❌ **three hard errors at once** |

Read the 3.47 row carefully — it is the whole argument against jumping.
Gradle 8.10.2, AGP 8.7.0 and Kotlin 2.1.0 all fail simultaneously. That is
not a version bump; it is a Gradle upgrade, an AGP upgrade and a Kotlin
upgrade landing in one commit, under a player package that has not been
released for the target. This is precisely the failure the CI comment
records.

Note also that **Java 11 stops being tolerated at 3.38** (`errorJavaVersion`
goes 11 → 17). CI already uses JDK 17 so CI is fine, but local builds on a
JDK 11 machine will start failing there. The app's own
`sourceCompatibility = VERSION_11` is the *bytecode target* and is unrelated —
it does not need to move.

---

## 5. Which version to target

### Not 3.47. The case against jumping

1. **No package in the tree needs it** (§2b).
2. **`media_kit` is three untested Flutter releases behind it** (§3b) — and
   it renders every frame the app exists to show.
3. **It breaks Gradle, AGP and Kotlin simultaneously** (§4d), so a failure
   during the attempt has four plausible causes and no way to bisect them.

A jump to 3.47 puts an unmaintained native rendering path and a three-part
Android toolchain migration into one change. When it misbehaves — and with a
player, "misbehaves" means a black frame on one phone model, not a stack
trace — nothing will say which half did it.

### Target: **Flutter 3.38.10**, reached in two steps

**3.38 is the highest version `media_kit` has ever claimed to support.** That
is the ceiling, and it happens to be a good place to stop: it clears the
`win32` knot (§2c), unlocks the largest batch of package gates (§2b), and
needs **zero** Gradle/AGP/Kotlin changes (§4d).

| Step | Does | Why it is its own step |
|---|---|---|
| **0** | Name the 9 wildcard params (§4a). Add Sentry (§6). | Free, independent, and Sentry is the instrumentation the later steps should be observed through |
| **1** | → **Flutter 3.35.7** | Isolates the **targetSdk 35 → 36 / Android-16 edge-to-edge** change (§4c) with NDK still at 27 — the one this repo already pins. One behavioural variable, alone. |
| **2** | → **Flutter 3.38.10** | Brings **NDK 28.2** and the **JDK 17 floor**. Both toolchain, both need the CI file edited in the same commit. |
| **3** | `media_kit_video` → 1.3.1, then 2.0.1 | Follow `media_kit_upgrade.md` exactly — it is the authority and its staging (bump, verify screen-off *with* the workaround, only then neuter it) exists because this subsystem has already burned four attempts. Budget `screen_brightness` → 2.1.11 in the same commit (§3c). |
| **4** | Package majors, one PR each | Riverpod 3, go_router, share_plus, etc. Each is independent of the SDK (§2a) — do not bundle them into the SDK steps. |
| **—** | **Hold at 3.38** | Until `media_kit` ships for 3.41+, or the project decides to migrate off it. Revisit when a `media_kit_video` release names a Flutter above 3.38.x. |

Steps 1 and 2 are each *"change one line in `.github/workflows/build.yml`, run
CI, install the APK, test playback."* That is the point of splitting them.

### Two notes on the staging

**The 107 `withOpacity` sites are not on the critical path.** They compile at
every version in the table. Clear them whenever — ideally as their own
`dart fix` PR like #11, not inside an SDK step where a visual regression would
be attributed to the SDK.

**Riverpod 3 is the biggest single migration and it is not an SDK task.** 56
providers and ~900 `ref` calls. It is much less alarming than it sounds:
Riverpod 3 **keeps** `StateNotifierProvider`, moving it to
`package:flutter_riverpod/legacy.dart` — so the mechanical part is an import
change, not a rewrite. The real work is the behavioural breaks: providers now
filter updates with `==` (this codebase defines `operator ==` in only 5
classes, all in `video_hub`, none in the player — so mostly a no-op),
`AsyncValue.valueOrNull` is removed in favour of `.value` (8 sites, every one
already written with a `?? const […]` fallback), and `ref`/notifier methods
now throw after disposal (the player disposes often — this is where to look
first if something goes wrong). Do it on its own, against the current Flutter,
with the player tests from #12 as the net.

---

## 6. Sentry — available today, no upgrade required

> **Done 12 Sep 2026 (PR #18).** Added off-by-default: the SDK is only
> initialised when a build passes `--dart-define=SENTRY_DSN=…`, and
> everything that does leave is scrubbed. `docs/crash_reporting.md` has the
> privacy design; the caveat this section raises below is answered there.

**`sentry_flutter` needs Flutter ≥3.24.0 and Dart ≥3.5.0. The project is on
3.32.8 / 3.8.1. It is already past the requirement by eight minor versions.**

Verified by resolving it for real, against the current `pubspec.yaml` with
nothing else changed:

```
$ # sentry_flutter: ^9.30.0 added to pubspec.yaml
$ flutter pub get
Changed 4 dependencies!          # sentry 9.30.0, sentry_flutter 9.30.0
```

It resolves to the newest release (9.30.0, published 10 Sep 2026 — one day
before this survey) with no conflict anywhere in the tree. The Android side
clears too: `minSdkVersion 21` against the app's 24, `compileSdkVersion 36`
matching the app's 36, Java 8 bytecode target, and nothing that contends with
the pinned AGP 8.7.0 / Gradle 8.10.2 / Kotlin 2.1.0.

**So the answer to "at which stage does Sentry become possible" is: stage
zero.** There is no gate. It is listed as step 0 above rather than merely
"possible now" because of the ordering argument — an upgrade is exactly when
you want crash reporting already in place and already proven on the *old*
toolchain. Adding it during or after step 1 means its first-ever run is on a
changed SDK, and a Sentry misconfiguration and an edge-to-edge regression
would arrive in the same build looking like one problem.

One caveat that is a product decision, not a technical one, and belongs with
whoever owns it: Sentry ships crash data off the device to a third party.
This app has a Private Folder with a PIN, biometric unlock and
keystore-backed storage — a posture that deserves a deliberate answer on what
gets captured, whether `beforeSend` scrubs file paths and media filenames, and
whether the Private Folder feature is excluded from breadcrumbs entirely.
Worth settling before the DSN goes in, not after.

---

## How to re-run this survey

```bash
flutter --version
flutter pub outdated
flutter pub upgrade --major-versions --dry-run
flutter analyze | grep -oE '• [a-z_]+$' | sort | uniq -c | sort -rn

# The Flutter ↔ Android toolchain floors (§4d), per release tag:
curl -sfL https://raw.githubusercontent.com/flutter/flutter/<tag>/packages/\
flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt \
  | grep -E 'val (warn|error)(Gradle|AGP|KGP|Java)Version'

# The SDK levels a release imposes (§4c):
curl -sfL https://raw.githubusercontent.com/flutter/flutter/<tag>/packages/\
flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt \
  | grep -E 'val (target|compile|min)SdkVersion|val ndkVersion'
```

The two `curl` commands are the ones worth keeping. Flutter's Gradle/AGP/JDK
floors are not in the release notes in any form you can diff, and reading them
out of the tag is the difference between "3.47 needs a newer Gradle" and the
exact table in §4d.

---

## Changelog

| Date | Flutter | Change |
|---|---|---|
| 2026-09-11 | 3.32.8 | Survey written against `main` @ `596ab26`. No code changed. |
