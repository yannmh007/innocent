# Crash reporting

Added 12 Sep 2026 (PR #18). **Off in every build that does not explicitly ask
for it**, including the one CI produces today.

---

## Why

Innocent has no Play Store listing and no crash console. When it dies on
someone's phone there is currently one way to find out why: ask them to open
Settings → Diagnostics and read a text report out. That is what
`CrashBreadcrumbs` was built for, and it works — but it needs a cooperative
user who noticed, remembered, and got in touch.

Sentry closes that gap. It is also the **first thing in this app that sends
anything off the device**, in an app with a PIN-locked Private Folder, so the
whole design below is about what does *not* leave.

## How to turn it on

```bash
flutter build apk --release --dart-define=SENTRY_DSN=https://…@o0.ingest.sentry.io/0
```

That is the only switch. With no `SENTRY_DSN`:

- `SentryFlutter.init` is never called
- no network, no permissions, no background work
- `SentryReporting.capture()` returns immediately

Pinned by `test/sentry_reporting_test.dart`. Those four tests **pass with no
DSN and fail with one**, which is the proof that they test the gate rather
than something incidental:

```
$ flutter test test/sentry_reporting_test.dart                          → +4
$ flutter test --dart-define=SENTRY_DSN=https://… test/sentry_…         → -4
```

**The DSN is a build argument, never a committed constant.** This is a public
repository; a DSN in the tree lets anyone post events into the quota.

## What is sent, and what is removed

Everything passes through `redactSensitive()` in
`lib/core/services/diagnostics/crash_redaction.dart` — events, exception
messages, and breadcrumbs — before it leaves.

| Removed | Kept | Why kept |
|---|---|---|
| filenames, folder names | the storage root (`/storage/emulated`, `/data/user`) | shared vs app-private storage is usually the bug |
| | the file extension | `.mkv` failing where `.mp4` works is the bug |
| SAF document ids | the provider authority | a real class of SAF failure |
| URL paths and query strings | the scheme and host | "fails on this site" is the report; *which video* is not |

```
PathNotFoundException: Cannot open file, path =
  '/storage/emulated/0/Innocent/Private/holiday in phuket.mp4'
      ↓
PathNotFoundException: Cannot open file, path =
  '/storage/emulated/<redacted>.mp4'
```

Also off, deliberately:

- **`attachScreenshot`** — a screenshot of the Private Folder would defeat
  every line of the redactor in one attachment.
- **`attachViewHierarchy`** — same reason, with widget text in it.
- **`sendDefaultPii`** — no IP address, no device name, no username.
- **tracing** (`tracesSampleRate: 0`) — crashes only. Traces carry screen names
  and timings, cost bytes on mobile data, and answer a question this app is
  not asking.

**If scrubbing itself throws, the event is dropped rather than sent.** A lost
crash report is the cheaper of the two failures.

### What the redactor does NOT touch

Dart stack frames — `package:innocent/features/player/…`, `dart:async` — pass
through untouched. They contain nothing personal and they are the entire
reason to send a crash at all. Every pattern in the redactor is anchored to an
absolute Android filesystem root or a URI scheme, so no source location
matches one. There is a test for exactly this, because an over-eager path
pattern would eat stack traces and make the whole feature worthless.

## How it attaches to the existing error handling

It **chains**, and the order in `main.dart` is load-bearing.

`main.dart` deliberately owns `PlatformDispatcher.instance.onError` and
returns `true` from it, to keep the isolate alive after an unawaited failure.
Sentry's `OnErrorIntegration` stores whatever handler it finds, calls it, and
returns *its* result — so that decision survives. Verified by reading
`on_error_integration.dart` in the pinned version, not assumed.

But that only works if Sentry starts **after** `main.dart` installs its hooks:

```dart
PlatformDispatcher.instance.onError = (error, stack) { … return true; };

await SentryReporting.start();   // ← must be after
```

Start it earlier and the assignment overwrites Sentry's handler, and no async
error is ever reported — silently, with everything still appearing to work.

This is the same rule `CrashDiagnostics.installErrorHooks()` already follows,
and its doc comment explains the same trap.

## What this does not do

- **It does not replace `CrashBreadcrumbs`.** The on-disk trail still works,
  still rotates per run, and is still what Settings → Diagnostics reads. It
  answers "what was the app doing" for a user who reports a problem; Sentry
  answers "is this happening to anyone else" without them having to.
- **It does not report a native crash.** Neither does anything else in Dart.
  Android's exit-reason history, read on the next launch, is still the only
  source for those.
- **It adds no UI.** There is no opt-in toggle, because there is nothing to
  opt in to until a DSN exists. If reporting is ever switched on for real
  users, a toggle is the next thing to build, not an afterthought —
  `SentryReporting.isConfigured` exists so a settings screen can tell the
  difference between "off" and "not built with it".

## Cost

- `sentry_flutter` 9.30.0 needs Flutter ≥3.24.0 and Dart ≥3.5.0. This project
  is on 3.32.8 / 3.8.1 — eight minors past — so **no SDK move was required**.
  It resolves cleanly against the unmodified `pubspec.yaml`.
- Android side: `minSdk 21` against this app's 24, `compileSdk 36` matching,
  nothing that contends with the pinned AGP 8.7.0 / Gradle 8.10.2 / Kotlin
  2.1.0.
- `flutter analyze` is unchanged at **275** — the new code adds no findings.

## Changelog

| Date | Change |
|---|---|
| 2026-09-12 | Added, off by default. `crash_redaction.dart` (13 tests), `sentry_reporting.dart` (4 tests), one call in `main.dart`. |
