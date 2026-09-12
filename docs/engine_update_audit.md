# The yt-dlp engine auto-update system — an audit

Read on 12 Sep 2026 against `main` @ `99cd351`. **No code was changed.**

Every line number below was read, not recalled. Where something could not be
verified it says so rather than guessing.

---

## The short version

The coordination is good — better than most of the apps compared in §3. One
coordinator, four triggers, reads that wait instead of racing, and an updater
that stands aside for a link being read. That part was clearly built from
scars and should be left alone (§5).

Three things are wrong, and they are all the same *kind* of thing: **a value
or a setting that only works if someone remembers.**

| | Severity |
|---|---|
| **The floor is a hand-maintained constant, and it is already 2.4 months stale** | the one the user asked about — §2 |
| **The auto-update toggle does not apply at app launch** | found while reading; §4 |
| **Three of the four triggers ignore metered connections** | found while reading; §4 |

---

## 1. What the system actually does

### 1a. The pieces

| File | Role |
|---|---|
| `lib/core/services/downloader/engine_readiness.dart` (204 lines) | the coordinator — decides *when* |
| `DownloadEngine.kt` `runUpdate` / `updateInBackground` (~1732–1878) | does the update reflectively |
| `EngineUpdateJobService.kt` (98 lines) | the weekly background job |
| `downloader_engine_service.dart` | the MethodChannel bridge |

### 1b. The four triggers

Named in the class comment of `engine_readiness.dart` and all four verified in
code:

| # | Trigger | Entry point | Notes |
|---|---|---|---|
| 1 | **App launch** | `EngineReadiness.start()` ← `app.dart:67` | fire-and-forget; also (re)registers the job |
| 2 | **Before any read** | `ensureCurrent()` ← `downloader_home_screen.dart:559`, `1080` | the read *waits* |
| 3 | **After any failure** | `noteFailure()` ← `downloader_home_screen.dart:951` | staleness is the likeliest cause of a failure |
| 4 | **Weekly, app closed** | `EngineUpdateJobService` | `JobScheduler`, not an alarm |

Trigger 1 is skipped while onboarding is showing and runs when onboarding
finishes (`app.dart:59` vs `:167`) — deliberate, and correct: a first-run
download should not compete with the setup screen.

### 1c. The constants, and what each is for

```dart
static const String   floor           = '2026.07.01';          // engine_readiness.dart:60
static const Duration routineInterval = Duration(days: 7);     // :63
static const Duration failureInterval = Duration(hours: 4);    // :66
static const Duration readWait        = Duration(seconds: 40); // :72
```
```kotlin
private const val UPDATE_ATTEMPTS = 3          // DownloadEngine.kt:80
private const val UPDATE_WAIT_MS  = 30_000L    // :81
private const val INTERVAL_MS = 7L*24*60*60*1000  // EngineUpdateJobService.kt
```

- **`floor`** — a *date*, compared with `version.compareTo(floor) < 0`. The
  comment says why a date beats a version comparison: the bundled copy is
  frozen, so the real question is "is this older than the app running it".
  README:5459 records the decision.
- **`routineInterval` 7d / `failureInterval` 4h** — two separate SharedPreferences
  keys (`engine_last_check_v1`, `engine_last_fail_v1`), so a burst of failures
  cannot exhaust the routine budget and vice versa.
- **`readWait` 40s** — the cap on how long a *read* waits for an update.
  `ensureCurrent` returns after this even if the update is still running.
- **`UPDATE_WAIT_MS` 30s** — the cap on how long an *update* waits for reads to
  finish. Note these are deliberately different numbers, and 40 > 30 so a read
  waiting on an update that is itself waiting on reads still terminates first.

### 1d. Staleness overrides everything

```dart
if (!_autoUpdateEnabled) return false;
if (isStale) return true;                       // ← before any schedule
if (afterFailure) return _isDue(_kLastFailKey, failureInterval);
return _isDue(_kLastCheckKey, routineInterval);
```

"A weekly rhythm cannot repair something broken on first launch" — so a
below-floor engine updates immediately, on any trigger, metered or not.

### 1e. `_inFlight` coalescing

```dart
final Future<void>? running = _inFlight;
if (running != null) return running.timeout(readWait, onTimeout: () {});
```

Ten callers produce one update. Note the timeout is applied to *both* the
joined future and the fresh one, so a late joiner never waits longer than a
first caller. `_inFlight` is cleared in `whenComplete`, before the timeout
wrapper — so a timed-out caller does not leave the slot occupied.

### 1f. `probesInFlight` — the updater stands aside

```kotlin
while (probesInFlight.get() > 0 && waited < UPDATE_WAIT_MS) { Thread.sleep(500); waited += 500 }
if (probesInFlight.get() > 0) { ... "deferred" to true ...; return }
```

An `AtomicInteger` (`DownloadEngine.kt:166`) incremented around every probe
(`:559`/`:564`). The binary is never swapped while a link is being read.

**A deferral is not recorded as a check** — `_run` returns before `_mark`,
with the comment *"It stood aside for a read in progress; not a check, so not
recorded."* That is right, and easy to get wrong: recording it would let a
busy phone starve the update by "succeeding" every week without doing
anything.

### 1g. Reflection, and three retries

`runUpdate` finds `updateYoutubeDL` by name, sorts overloads by arity, prefers
the 1-arg form (library default channel), falls back to 2-arg with a
`resolveChannel()` that tries four different shapes of `STABLE`. Wrapped in
`UPDATE_ATTEMPTS = 3` with a 1.5s × (round−1) backoff, because the observed
real failure was `unexpected end of stream on com.android.okhttp.Address` — a
pooled-connection reset, which usually succeeds on a retry.

Every step appends to a `trace` StringBuilder that is returned to Dart,
because *"when this fails on a user's phone the only thing we get back is a
screenshot"*.

`updateInBackground` (`:1861`) is the same idea, simplified: no probe wait, no
retries, no trace, returns a bare `Boolean` — it takes its own `Context`
because the weekly job can run in a process with no Flutter engine attached.

---

## 2. Weakness 1 — the floor is hand-maintained

### The rule it breaks

The comment on `floor` says **"Raise it with every release."** That is a
standing instruction to a human, and this project's own record is that such
instructions are the thing that fails silently. `docs/work_log.md` and the
README are full of the same lesson in other places.

### It has already happened

| | |
|---|---|
| `floor` | **`2026.07.01`** |
| Today | **2026-09-12** |
| Drift | **2.4 months** |

The consequence is precise, and it is not "the app is broken": an engine at
`2026.07.15` is **not** stale by this test, so it is only replaced on the
7-day routine or after a failure. What the floor is *supposed* to guarantee —
"never run an engine older than the app" — is exactly what has quietly
stopped being true. It degrades from a guarantee into a slow schedule, and it
does so without any signal.

### Three ways to fix it

#### Option A — CI stamps it at build time

Generate the constant from the build date, the way the version is already
handled:

```
--dart-define=ENGINE_FLOOR=$(date -u -d '-14 days' +%Y.%m.%d)
```

| | |
|---|---|
| **For** | Impossible to forget. No new runtime behaviour, no network, no failure mode — it is the same comparison against a better number. Small: one workflow line and one `String.fromEnvironment`. |
| **Against** | A local `flutter build` without the define gets an empty floor, so it needs a sane fallback (keep the constant as the default). Couples the floor to *build* date, not *release* date — a branch built months later gets a floor from that later date, which is harmless but slightly wrong. |

Closest to how this repo already does things: the Sentry DSN in #18 uses the
same `--dart-define` shape.

#### Option B — relative to the bundled binary's own date

Read the version the library ships with once, and treat "more than N months
newer than that" as the line:

```dart
bool get isStale => _monthsBetween(_bundledVersion, _status.version) > 2;
```

| | |
|---|---|
| **For** | No constant at all. Self-correcting: bumping `youtubedl-android` moves the baseline automatically. |
| **Against** | Needs the bundled version *before* any update overwrites it, and the library does not obviously expose that separately from "the current binary" — this would need verifying against the library, and I could not confirm it from the source I read. Also answers the wrong question: it measures distance from the bundle, not from *now*. A user who installs a two-year-old APK and updates once is judged current forever. |

Weakest of the three, and the reason is worth stating: it re-derives "old" from
a moving reference instead of from the calendar.

#### Option C — ask the network what "current" means

Fetch the latest yt-dlp release tag (GitHub API or the existing remote config,
which this app already has — `remoteConfigProvider`) and compare against that.

| | |
|---|---|
| **For** | Actually correct, not approximately correct. Would also make "you are 3 releases behind" showable to the user. The app already fetches a remote config, so the mechanism exists. |
| **Against** | A network call before deciding whether to make a network call. Needs its own failure path — and it must **fail open** (assume current, do not block), or a GitHub outage becomes an app that refuses to download. Adds a dependency on an external service to a decision that currently needs none. More moving parts than the problem justifies. |

### Recommendation

**Option A**, and it is not close. It removes the human step, adds no failure
mode, and costs about six lines. Option C is what you would build if the floor
needed to be *accurate*; it only needs to stop rotting.

Worth adding either way: put the floor and the engine version somewhere a
person will see them (§4), so a stale floor is visible rather than silent.

---

## 3. How other apps handle it

Researched 12 Sep 2026. Sources are linked; where a claim could not be
verified from a primary source it is marked as such rather than asserted.

### Seal (JunkFood02/Seal)

The closest comparison — an Android yt-dlp front end on the same
`youtubedl-android` library.

- **When**: auto-update is **on by default and checks on every launch**
  (maintainer, v1.9.0). Innocent's launch trigger is the same idea, but
  Innocent additionally rate-limits it to weekly unless stale or after a
  failure — Seal appears to check every time.
- **Manual + version visible**: the yt-dlp version is shown in Settings and
  **tapping it runs the update**. This is the single clearest thing Innocent
  lacks (§4).
- **During**: not verified in detail from a primary source.
- **Failure**: the maintainer notes yt-dlp's own *"Confirm you are on the
  latest version using yt-dlp -U"* text appears in errors **whether or not you
  are current**, which is a good warning against surfacing engine text
  verbatim to users.

### youtubedl-android (the library Innocent uses)

- **Bundles yt-dlp and Python 3.8 at build time.** This is the root of the
  fresh-install problem: every new install reverts to whatever was current
  when the *library* was released, not when the app was.
- `updateYoutubeDL(context, channel)` with **STABLE / NIGHTLY** (a MASTER
  channel appears in examples). Innocent resolves STABLE reflectively rather
  than importing the type — see §5.
- The sample app demonstrates the update call; its UI specifics were not
  verifiable from the README.

### NewPipe

Structurally different and instructive: **no binary at all.** Its extractor is
a compiled-in library, so "updating the engine" is "updating the app". Because
YouTube changes break it *instantly*, the whole release process is built
around fast hotfix releases rather than around updating a component.

The relevant lesson is the inverse of Innocent's: NewPipe cannot have a stale
engine and a current app, but it also cannot fix an extractor without shipping
an APK. Innocent's design — updatable engine, stable shell — is the better
trade for a self-distributed app with no store.

### yt-dlp itself

`yt-dlp -U`, plus stable / nightly / master channels. The documentation is
explicit that third-party packages *"may not be up-to-date"* and that this
matters. I could **not** confirm `--update-to` semantics or nightly publish
frequency from the page I read, so nothing here depends on those.

### Termux / pip

`python3 -m pip install -U "yt-dlp[default]"` — entirely manual and entirely
the user's problem. Not a model for a consumer app; included only because it
is the baseline the others improve on.

### What the comparison actually shows

| Question | Seal | NewPipe | Innocent |
|---|---|---|---|
| Shown during update | not verified | n/a | ✅ `downloaderUpdating` in the probing card |
| Failure handling | error text passed through | hotfix release | ✅ retries ×3, trace string, retry-after-update |
| Fresh install with stale bundle | update on every launch | n/a | ✅ floor forces immediate update *(if the floor is current — §2)* |
| Manual trigger | ✅ tap the version | n/a | ⚠️ only from the failure card |
| Version visible | ✅ Settings | n/a | ⚠️ only in the copied diagnostics report |
| Metered decision | not verified | n/a | ⚠️ weekly job only (§4) |

**Innocent is ahead on the hard parts and behind on the visible ones.** The
coordination — waiting rather than racing, deferring rather than clobbering,
separate failure and routine budgets — is more careful than anything found in
the comparison. What it lacks is the two-line stuff: showing the version and
letting someone press a button.

---

## 4. What Innocent is missing

### Really needed

**1. The auto-update toggle does not apply at app launch.** *(bug, not a gap)*

`_autoUpdateEnabled` defaults to `true` (`engine_readiness.dart:84`) and
`configure()` is called from exactly two places, both in
`downloader_home_screen.dart` (`:554`, `:1080`). `start()` is called from
`app.dart:67` — **before either**. So on every cold launch, trigger 1 runs
with auto-update forced on, whatever the user chose. The setting only takes
effect after the Downloader screen has been opened once in that process.

A user who turns it off to save data still pays for an update on every cold
start. Cheap to fix: read the preference in `start()`, or call `configure()`
from `app.dart` before `start()`.

**2. Triggers 1–3 ignore metered connections.**

`EngineUpdateJobService` requires `NETWORK_TYPE_UNMETERED`, with a comment
saying *"nobody's data allowance pays for a maintenance download they did not
ask for."* That reasoning applies just as well to a launch-triggered update —
but triggers 1, 2 and 3 never consult it, even though the app already knows:
`deviceStatus` returns `unmetered` (`DownloadEngine.kt:3811`) and the download
path already honours a `wifiOnly` setting.

The stale case should still override — README:5459 says so explicitly, and two
megabytes beats an app that does nothing. But a *routine* weekly check that
happens to fire on mobile data has no such excuse.

**3. Make the floor self-maintaining.** §2, Option A.

### Nice to have

**4. Show the engine version, and let the user update it.** Seal puts both in
Settings; Innocent has the version only inside a diagnostics report you have
to copy to the clipboard, and the only update button lives on the failure
card. `EngineReadiness.lastCheckedLabel()` already exists and is already
wired into that report (`downloader_home_screen.dart:3416`) — the data is
there, it just is not shown anywhere a person would look.

**5. Surface "last checked" and "floor" together.** A stale floor is currently
invisible. If the diagnostics line said `engine 2026.07.14 · floor 2026.07.01
· checked 3d ago`, §2 would have been noticed by whoever read it.

**6. Report update outcomes to the weekly job's future self.** `updateInBackground`
returns a `Boolean` that `EngineUpdateJobService` discards
(`onStartJob` ignores the return), and nothing records that the weekly attempt
happened. A run of silent weekly failures is currently indistinguishable from
the job never running. `jobFinished(params, false)` also never asks for a
retry — deliberate, per the comment, but it means a transient failure waits a
full week.

### Not needed

**7. A nightly channel.** yt-dlp offers it; Seal exposes it. For an app whose
users are not debugging extractors, stable plus a 4-hour post-failure retry
covers the real case, and nightly adds a class of breakage nobody here can
diagnose.

**8. Update progress (bytes/percent).** The library's `updateYoutubeDL` is a
blocking call with no progress callback surfaced in what I read. The probing
card already names the phase, which is the part that matters — a percentage
would be nice and is not worth reflecting into a library API for.

**9. WorkManager.** The job service comment already rejects it, correctly:
JobScheduler is in the platform and does everything needed. Adding a library
to a build the docs describe as "already delicate" is not an improvement.

---

## 5. Do not touch

Things that look odd and are load-bearing. Each has a reason recorded in the
code; the reasons are summarised here so a future reader does not "simplify"
them.

| Thing | Why it is like that |
|---|---|
| **Four separate executors** (`probeExec`, `dlExec`, `updateExec`, `statusExec`, `metaExec`) | The updater used to share `probeExec`. A link pasted during an update queued behind a multi-megabyte download with up to three retries — 30+ seconds of "Reading link…" with nothing wrong. It produced the classic bug report *"sharing a link never works, pasting the same link always does"*. Reading a link is the one thing a person waits for; nothing may queue in front of it. |
| **`refreshVersion` outside the update lock** | Reads the version after the swap without holding anything that would block a probe. Called from `runUpdate`, `updateInBackground` and `:1602`. |
| **`probesInFlight` wait, and the "deferred" reply** | Never swap the binary mid-read. Equally important: bailing out *immediately* was the old behaviour, and it let an eight-month-old extractor survive for weeks on a busy phone. Wait, then defer — and **do not record a deferral as a check**, or a busy phone starves the update while appearing healthy. |
| **`readWait` 40s > `UPDATE_WAIT_MS` 30s** | Not arbitrary. The read's cap must exceed the update's, or a read can time out while the update it is waiting for is still politely waiting for that same read. |
| **Two SharedPreferences keys, not one** | `engine_last_check_v1` and `engine_last_fail_v1` are separate so failure-triggered checks cannot consume the routine budget. |
| **Reflection for `updateYoutubeDL` and `resolveChannel`** | `UpdateChannel`'s shape is not pinned by the library's docs; the code tries a static field, an enum constant, a nested object and more. Replacing this with a direct call couples the build to an unversioned detail of a third-party library. |
| **3 attempts with backoff** | Answers a specific observed failure — `unexpected end of stream on com.android.okhttp.Address`, a pooled-connection reset that usually succeeds on retry. Not defensive padding. |
| **The `trace` StringBuilder** | The only diagnostic that survives to a user's screenshot. "Update failed" alone is unactionable. |
| **`updateInBackground` being a separate, simpler path** | The weekly job can run in a process with no Flutter engine, so it cannot reply over a MethodChannel and takes its own `Context`. |
| **`start()` skipped during onboarding** | Correct: a first-run download should not compete with setup. It runs when onboarding completes (`app.dart:167`). |
| **JobScheduler, not AlarmManager** | An alarm wakes the device for work with no deadline. Recorded in the job service comment. |

---

## Sources

- [JunkFood02/Seal — discussion #673](https://github.com/JunkFood02/Seal/discussions/673)
- [yausername/youtubedl-android](https://github.com/yausername/youtubedl-android)
- [yt-dlp — Installation wiki](https://github.com/yt-dlp/yt-dlp/wiki/Installation)
- [TeamNewPipe/NewPipeExtractor](https://github.com/TeamNewPipe/NewPipeExtractor)
- [NewPipe 0.28.1 release notes](https://newpipe.net/blog/pinned/announcement/newpipe-0.28.1-released/)
- [Seal on GIGAZINE (settings walkthrough)](https://gigazine.net/gsc_news/en/20260223-seal/)

## Changelog

| Date | Change |
|---|---|
| 2026-09-12 | Audit written against `main` @ `99cd351`. No code changed. |
