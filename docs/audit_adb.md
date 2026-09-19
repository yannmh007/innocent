# Domain 7 — the ADB stack: an audit

*13 September 2026. No code changed by this document.*

## Status — what has been fixed since

This section is the only part of this file that gets edited after the fact. The
findings below are left exactly as they were written, including the ones that
turned out to be wrong, because an audit you can quietly rewrite is not
evidence of anything.

| | fixed in | what changed |
|---|---|---|
| **A1** | 1.64.8+321 | `pullForPlayback` now calls `sanitizePath` |
| **A2** | 1.64.9+322 | proxy: per-process token, resolved-path prefix check, bounded pool, bounded line reader, socket timeout |
| **A3** | 1.64.8+321 | `QUICKBOOT_POWERON` and `LOCKED_BOOT_COMPLETED` dropped; receiver guard narrowed |
| **A4** | 1.64.8+321 | `adb_key.pk8` / `adb_cert.der` excluded from both backup channels |
| **A5** | 1.64.10+323 | the restore moved out of the broadcast into `AdbBootJobService`; the receiver returns at once, waits are constraints, failures retry with backoff, and the outcome is shown on the ADB screen |
| **A6** | 1.64.9+322 | `runWithDeadline` interrupts and counts an abandoned worker; `tryConnectBounded` returns a third outcome and the callers stop instead of racing the shared manager |
| **A7** | 1.64.9+322 | sweep goes a chunk at a time under one budget, and both it and the scan path stand down when a user-initiated operation is waiting |
| **A8** | 1.64.8+321 | `UserService.exec` destroys the child on the truncation path before `waitFor` |
| **A9** | 1.64.10+323 | the ADB screen names the permission on its own line and offers a Hand-it-back action, with the shell caveat stated |
| **A10** | 1.64.11+324 | routing uses `backendOrNull` and refuses to guess; the answer is cached and invalidated on `setBackend` |
| **A11** | 1.64.11+324 | the state callback takes no parameter, and the single-slot setter is gone — one mechanism |
| **A12** | 1.64.11+324 | `parseAdbDirLine` extracted from `listAdbDir`; 18 tests for it and `parseAdbScanLine` in `test/adb_parse_test.dart` |

Still open: the three device questions at the end. Every finding in this
audit that survived checking has now been fixed, except the Kotlin half of
**A12** — there is still no `android/app/src/test/`, so the Kotlin remains
untestable in principle.

Covers `AdbManager.kt` (1,135), `adb_connect_screen.dart` (1,089), `adb_service.dart`
(632), `AdbPairingService.kt` (371), `IadbClient.kt` (345), `AdbHttpProxy.kt` (183),
`UserService.kt` (101), `BootReceiver.kt` (51) and the manifest entries that wire
them — about 3,900 lines, never audited, with no tests.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## Why this one is different from the other six

Every other domain in this app fails toward *inconvenience*. This one holds a
shell as **uid 2000 (`shell`)** on the user's own phone, grants itself
**`WRITE_SECURE_SETTINGS`**, keeps a **private key** that adbd remembers, and
turns wireless debugging back on **after every reboot**. The blast radius of a
mistake here is the whole device, not the app.

That is not a criticism of the feature. It is a legitimate and well-known
technique — the app needs to read `Android/data`, Android 11 took that away
from apps, and on-device ADB is the only route left that needs neither root nor
a PC. The engineering around the *connection* is genuinely good: bounded
deadlines everywhere, a half-open-socket prover, a serialising lock with the
race it fixed written next to it, a keep-alive that backs off during a scan.
Someone fought this into shape against real devices.

The problems are all at the **edges** — where a string becomes a shell command,
where a port becomes reachable, where a broadcast arrives, and where a key
lands on disk.

## The short version

**Three findings are security findings, and one of them I verified by running
it.**

* **A1** — `pullForPlayback` strips only `"` from a filename before putting it
  inside `cat "…"`. `$(…)` and `` `…` `` both survive, and both execute. Sixty
  lines away in the same file, `sanitizePath` strips all three and is used on
  the *less* dangerous path. Filenames in `Android/data` are written by other
  apps.
* **A2** — `AdbHttpProxy` serves **any absolute path** over unauthenticated
  loopback HTTP, backed by the uid-2000 shell. It is not reachable today only
  because its one entry point has no Dart caller. That makes it a loaded gun
  with the trigger not yet connected, not a non-issue.
* **A3** — `BootReceiver` is exported and listens for **`QUICKBOOT_POWERON`**,
  which is not a protected broadcast. Any installed app can send it and make
  Innocent switch wireless debugging on.

**And a fourth Auto Backup instance.** `adb_key.pk8` — the RSA private key that
*is* this device's ADB identity — is written to `filesDir`, in the same
directory as the vault, and the backup rules exclude the vault's two
subdirectories and not this file. It goes to Google Drive.

The rest is liveness and resources: two thread-leak patterns, a 28,233-port
localhost sweep run while holding the global ADB lock, a `waitFor()` that
deadlocks on the truncation path its own comment describes, and a
`BroadcastReceiver` that holds `goAsync()` for up to 78 seconds.

The Dart half — `adb_connect_screen.dart` — is in good order and §2 says so.

---

## 1. Findings

### A1 — one file, two sanitisers, and the weaker one guards the shell

`android/app/src/main/kotlin/com/innocent/media/AdbManager.kt:750`

```kotlin
val safeSrc = srcPath.replace("\"", "")
…
val stream = mgr.openStream("exec:cat \"$safeSrc\"")
```

and, 106 lines later at `:856`:

```kotlin
private fun sanitizePath(srcPath: String): String =
    srcPath.replace("\"", "").replace("$", "").replace("`", "")
```

Both build a **double-quoted** shell argument. Inside double quotes the
metacharacters that still act are `"`, `$` and `` ` ``. `sanitizePath` removes
all three. `pullForPlayback` removes one.

**Verified rather than reasoned about:**

```
$ p='vid$(touch /tmp/injtest/pwned_dollar).mp4'
$ safe=$(printf '%s' "$p" | tr -d '"')      # pullForPlayback's rule
$ sh -c "cat \"$safe\""
$ ls pwned*
pwned_backtick  pwned_dollar                # both fired

$ safe=$(printf '%s' "$p" | tr -d '"$`')    # sanitizePath's rule
$ sh -c "cat \"$safe\""
triple-strip: no injection found            # across four shapes, incl. a trailing backslash
```

So the rule that is applied to `stat` and `dd` holds, and the rule applied to
`cat` does not.

**Where the path comes from is what makes this reachable.** It is not typed by
the user. It is a real filename discovered by
`AdbService._scanAndroidDataVideos`'s `find` over
`/storage/emulated/0/Android/data` and `/Android/obb` — directories whose
contents are written by **other applications**, each of which fully controls
the names of the files in its own folder. An app that creates

```
Android/data/com.example.app/files/Holiday$(…).mp4
```

has planted a command that runs as `shell` the moment a user opens that entry
in Innocent. `pullForPlayback` is called from **six** places —
`player_controller_playback.dart:79`, `player_screen.dart:1319`,
`private_folder_service.dart:1341`, `transfer_screen.dart:140`,
`bulk_actions.dart:276`, `adb_connect_screen.dart:502` — so every surface that
can open an `Android/data` video is a route to it.

What it buys the attacker is `uid=2000`, which on a phone where this feature is
set up also holds `WRITE_SECURE_SETTINGS`. `pm grant`, `settings put`,
`pm install`, reading every app's `Android/data` — all of it, from a filename.

**It needs a tap.** That is the honest limit, and it is a small one: the
attacker chooses the filename, so the file can be called whatever a person is
most likely to open.

`listAdbDir` (`adb_service.dart:366`) gets this right for a third context —
single quotes, with `' → '\''` — so the tree contains three quoting strategies,
two correct.

The fix is not a fourth denylist. It is to stop building shell strings from
paths at all where possible, and where it is not, to use the one function that
already exists and works.

| | |
|---|---|
| likelihood | **ရှားပါး** — needs a hostile app already installed, plus a tap |
| severity | **high** — arbitrary shell as uid 2000, from a filename |
| fix | **trivial** — call `sanitizePath`; then unify all three call sites |

### A2 — an unauthenticated file server on loopback, one line from being live

`android/app/src/main/kotlin/com/innocent/media/AdbHttpProxy.kt:105`

```kotlin
val srcPath = URLDecoder.decode(pathEnc, "UTF-8")
val size = AdbManager.fileSize(context, srcPath)
if (size <= 0L) { writeStatus(out, 404, "Not Found"); return }
…
AdbManager.streamRange(context, srcPath, start, len, out)
```

`?p=` is taken as an **absolute path with no restriction**: no allow-list, no
prefix check against `Android/data`, no token in the URL, no `Host` check, no
check of who is connecting. `fileSize` and `streamRange` run `stat` and `dd`
over the ADB connection — **as uid 2000**.

`127.0.0.1` is **not** an app-private address on Android. Any installed
application holding `INTERNET` — a normal permission, granted silently at
install, held by essentially every app — can connect to it. Finding the port
costs seconds; this repository contains a working localhost port sweep
(`AdbManager.findOpenLocalPorts`) that demonstrates the technique.

So while the proxy is up, any app on the phone can read anything the shell user
can read. The concrete prize is every other app's
`Android/data/<pkg>/` — which is precisely the thing Android 11's scoped
storage was introduced to take away from apps. `streamRange` will even
`reconnectFromSaved` on the way, so an attacker's request can *wake* the ADB
connection rather than needing to catch it live.

**It is not reachable today, and that is the finding.**

```
$ grep -rn "AdbService.instance.streamUrl" lib/
$
```

`AdbService.streamUrl` (`adb_service.dart:447`) has **no caller**.
`MainActivity`'s `"streamUrl"` handler is therefore never invoked,
`AdbManager.streamUrl` never runs, `AdbHttpProxy.ensureStarted` is never
called, and no socket is ever opened.

That is worse than ordinary dead code, for three reasons:

1. The Dart method exists, is documented as the fast path, and
   `pullForPlayback`'s own comment says *"the caller then falls back to
   pullForPlayback"* — so the wiring was designed and simply not finished.
2. Finishing it is **one line** in `player_controller_playback.dart`, and the
   change that finishes it will be called "make Android/data playback instant",
   which is not a change anyone sends to security review.
3. Because it never runs, nothing will ever surface it — no crash, no log, no
   test.

Two more holes to close in the same pass, both currently invisible for the same
reason:

* **No connection cap.** `ensureStarted` spawns a bare `thread` per `accept()`,
  with no pool and no limit. Ten thousand connections is ten thousand threads.
* **No header limit.** `while (true) { reader.readLine() … }` reads headers
  until a blank line. A peer that never sends one makes the thread read
  forever.
* **The server is never stopped.** `server` is assigned and never closed, so
  the exposure window is not "during playback" but "from the first stream until
  the process dies".

The right shape is the one the Transfer domain already uses: a token in the
URL, a path prefix check, a connection cap, and a header budget.

| | |
|---|---|
| likelihood | **ရှားပါး today** (unreachable) → **မကြာခဏ** the day it is wired |
| severity | **high** — a confused deputy that re-exports uid-2000 read access to every app |
| fix | **easy** — token + prefix check + caps, before the caller is written |

### A3 — an exported boot receiver listening for an unprotected action

`android/app/src/main/AndroidManifest.xml:353`

```xml
<receiver android:name=".BootReceiver" android:enabled="true" android:exported="true">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED" />
        <action android:name="android.intent.action.LOCKED_BOOT_COMPLETED" />
        <action android:name="android.intent.action.QUICKBOOT_POWERON" />
    </intent-filter>
</receiver>
```

`BOOT_COMPLETED` and `LOCKED_BOOT_COMPLETED` are **protected broadcasts**: only
the system can send them, so an exported receiver for those is normal and safe.

`android.intent.action.QUICKBOOT_POWERON` is **not**. It is an OEM extension
(HTC-origin, carried by several Chinese ROMs for fast-boot) and it is absent
from AOSP's protected-broadcast list. On stock Android, any installed
application can send it — and because the receiver is exported, it can send it
as an *explicit* intent straight at `com.innocent.media/.BootReceiver`, needing
no permission of its own.

`BootReceiver.onReceive` then does exactly what a real boot would:

```kotlin
if (!AdbManager.autoEnableOn(appContext)) return
if (!AdbManager.hasSecureSettings(appContext)) return
…
AdbManager.enableWirelessDebugging(appContext)
```

**So on a phone where the user has set auto-enable up, any app can turn on
wireless debugging at will**, and then — per A2 and the general shape of this
stack — has an ADB daemon listening on the LAN that it did not have a minute
ago.

Honest limits, and they matter: it does nothing unless the user has already
completed the opt-in flow *and* the app already holds `WRITE_SECURE_SETTINGS`;
Android shows a persistent notification once something connects; and an
attacker still has to pair. It is an escalation *assist*, not a full break.

`LOCKED_BOOT_COMPLETED` in the same filter is separately **dead**: the system
delivers it only to components marked `android:directBootAware="true"`, and
this one is not. Worse, if it *were* delivered, `AdbManager.autoEnableOn`
reads `getSharedPreferences` on a credential-encrypted context, which throws
before first unlock.

The fix is to delete two of the three actions. `BOOT_COMPLETED` alone is
protected, is delivered, and is the only one that ever does anything.

| | |
|---|---|
| likelihood | **ရှားပါး** — needs a hostile app and a set-up phone |
| severity | **moderate-high** — any app can enable ADB over Wi-Fi |
| fix | **trivial** — remove `QUICKBOOT_POWERON` and `LOCKED_BOOT_COMPLETED` |

### A4 — the ADB private key is uploaded to Google Drive

`android/app/src/main/kotlin/com/innocent/media/AdbManager.kt:55`, `:85`

```kotlin
val dir = context.filesDir
val keyFile  = File(dir, "adb_key.pk8")
val certFile = File(dir, "adb_cert.der")
…
keyFile.writeBytes(privateKey.encoded)
```

`filesDir` is `/data/data/com.innocent.media/files`. The backup rules exclude
exactly four things:

```xml
<exclude domain="file"      path="private_vault/" />
<exclude domain="file"      path="intruder_shots/" />
<exclude domain="sharedpref" path="FlutterSecureStorage" />
<exclude domain="sharedpref" path="FlutterSecureStorage.xml" />
```

`adb_key.pk8` sits **in the same directory as `private_vault/`**, one level up
from an excluded folder, and is not excluded. `backup_rules.xml` states the
rule plainly: *"Everything NOT listed here still backs up normally."* So an
unencrypted PKCS#8 RSA private key goes to the user's Google Drive on Auto
Backup, and to a new handset on device transfer.

What the key is worth is stated by the class itself:

> *"Holds a PERSISTENT RSA key + self-signed X509 certificate: once a device
> has paired with this key, the adbd keystore remembers it, so the key must
> stay the same across app restarts for 'pair once, reconnect forever' to
> work."*

It is the credential adbd trusts. Someone holding it, who can also reach the
phone's wireless-debugging port, gets a shell — no pairing code needed, because
the pairing already happened. That is a same-LAN attack, and the key alone is
not sufficient, so I will not call it critical. But an unencrypted private key
in a consumer cloud backup is not defensible on its own terms, and this
project's own written standard says so twice.

Two smaller members of the same class in the same feature:

* `adb_state` SharedPreferences holds `scanned_videos` — **a newline-joined
  list of the user's video filenames** inside `Android/data`
  (`AdbManager.saveScannedVideos`). Filenames, from an app that ships a vault.
  Backed up.
* `last_connect` and `auto_enable` in the same file. Harmless individually;
  `auto_enable` restoring as `true` on a new handset that has *not* granted
  `WRITE_SECURE_SETTINGS` is caught by `BootReceiver`'s second guard, so no bug
  — worth stating because it is the first thing a reader will worry about.

**This is the fourth instance of one bug class in this repository.**
`session_store.dart` (v1.55.16) and `device_identity.dart` (v1.63.5) both moved
to `FlutterSecureStorage` with Auto Backup named in the comment;
`docs/audit_video_hub.md` M6 found the age-consent keys as the third. The
pattern is now established well enough to deserve a checker rather than a
fourth manual find — see §5.

The fix here is one line in each XML file: `<exclude domain="file"
path="adb_key.pk8" />` and the same for `adb_cert.der`. Excluding rather than
moving is right: a key restored onto a new phone is *wrong* for the same reason
`device_identity` was — the new phone has not paired.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every backup, automatically |
| severity | **moderate-high** — an unencrypted private key leaves the device |
| fix | **trivial** — two lines per XML file |

### A5 — the boot receiver holds `goAsync()` for up to 78 seconds

`android/app/src/main/kotlin/com/innocent/media/BootReceiver.kt:29`

```kotlin
val pending = goAsync()
thread(start = true, isDaemon = true, name = "adb-boot") {
    try {
        Thread.sleep(45000)
        AdbManager.enableWirelessDebugging(appContext)
        Thread.sleep(8000)
        AdbManager.autoConnectAndRun(appContext, "id", 25000L)
    } catch (_: Throwable) {
    } finally {
        pending.finish()
    }
}
```

45 s + the enable + 8 s + a 25 s deadline = **up to 78 seconds** before
`finish()`.

`goAsync()` does not buy unlimited time. The `PendingResult` must be finished
inside the broadcast timeout — around ten seconds for a foreground broadcast,
sixty for a background one. Past it the system logs a timeout, may declare an
ANR, and is free to kill the process. And it is holding the process alive and
un-reclaimable *at boot*, which is the moment the device is under the most
memory pressure it will ever be under.

If the process is killed mid-sleep, nothing happens and **nobody is told**:
every branch is inside `catch (_: Throwable) {}` and there is no notification,
no log the user can see, and no state written. The next morning the user finds
Android/data videos missing from the library and no reason for it.

The three sleeps are also a guess at what they are waiting for. `Thread.sleep`
is standing in for "Wi-Fi is up" and "adbd is advertising" — both of which are
observable.

The shape this wants is a `WorkManager` job enqueued from `onReceive` (which
then returns in microseconds), with the Wi-Fi wait expressed as a
`NetworkType.CONNECTED` constraint and a retry policy for the connect. That
also survives the process being killed, which the current code does not.

| | |
|---|---|
| likelihood | **မကြာခဏ** — every boot, on a phone with the feature on |
| severity | **moderate** — the feature silently does not happen; a boot-time ANR risk |
| fix | **moderate** — `WorkManager`, and constraints instead of sleeps |

### A6 — two thread-leak patterns, and one of them corrupts the connection

**a. `runWithDeadline` (`AdbManager.kt:223`)**

```kotlin
if (!latch.await(ms, TimeUnit.MILLISECONDS)) {
    try { getInstance(context).disconnect() } catch (_: Throwable) {}
    latch.await(2, TimeUnit.SECONDS)
    throw java.io.IOException("timed out after ${ms}ms")
}
```

The comment is right about *why* the disconnect is there — it unwinds a stuck
native read. But if the second `await` also expires, the code throws anyway and
the worker thread is simply abandoned, still blocked on the socket, holding its
stack and its buffers for the life of the process. Each timeout can leak one.

**b. `tryConnectBounded` (`AdbManager.kt:540`) — the more interesting one**

```kotlin
val w = Thread { try { mgr.connect(host, port); … } catch (_) {} finally { latch.countDown() } }
w.isDaemon = true; w.start()
if (!latch.await(ms, TimeUnit.MILLISECONDS)) {
    try { mgr.disconnect() } catch (_: Throwable) {}
    return false
}
```

No second await at all: on timeout it disconnects and returns immediately,
leaving the worker inside `mgr.connect()`.

`mgr` is the **singleton** `AdbManager`. So the abandoned thread is still
mutating the shared connection manager while the caller moves on and the next
loop iteration calls `mgr.disconnect()` and then `mgr.connect()` on that same
object. `scanLocalPort` calls `tryConnectBounded` **once per open localhost
port**, so a sweep that finds ten candidates can have several concurrent
half-finished `connect()` calls racing one `disconnect()`.

`opLock` does not help: these are threads the ADB code started itself, below
the lock.

That is a strong candidate for the symptom the `opLock` comment describes:

> *"Serializes connect/pair/shell so a screen-open auto-reconnect can't race a
> user-initiated pair/connect on the shared singleton (which corrupted the
> connection and surfaced as 'Stream closed')."*

`opLock` fixed the races *it could see*. This one is inside the mechanism.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — any sweep with more than one open port |
| severity | **moderate** — leaked threads, and a plausible cause of a known symptom |
| fix | **easy** — join before returning; better, one manager per attempt, or a real connect timeout |

### A7 — a 28,233-port localhost sweep, run while holding the global ADB lock

`android/app/src/main/kotlin/com/innocent/media/AdbManager.kt:509`

```kotlin
val pool = java.util.concurrent.Executors.newFixedThreadPool(64)
val tasks = (32768..61000).map { port -> Callable<Unit> { … Socket().connect(…, 120) … } }
pool.invokeAll(tasks, 8, TimeUnit.SECONDS)
```

28,233 `Callable` objects materialised into a `List` before submission, 28,233
`Socket` objects, and a 64-thread pool — on a phone. The comment's premise is
sound (a refused loopback connect returns instantly) and the 8-second cap keeps
it bounded, so the sweep itself is defensible.

**What is not defensible is where it runs from.** `execRead` is
`synchronized(opLock)`, and `runShell`'s scan branch passes this as its
`firstConnect`:

```kotlin
if (reconnectFromSaved(context, mgr)) null
else if (isScan && scanLocalPort(context, mgr)) null      // ← the sweep
else if (isScan) mdnsConnect(context, 12000L)             // ← plus 12s more
```

So up to **20 seconds of sweep-then-mDNS runs holding the lock every other ADB
operation needs**. The user taps Connect on the ADB screen during a background
scan and the button does nothing until it finishes.

`reconnectFromSaved`'s own comment sets out the rule this breaks:

> *"Full rediscovery (localhost sweep + mDNS, which is slower) is reserved for
> the explicit connect path … so it never blocks anything interactive."*

The rule is right. `runShell` is the path that does not follow it.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — a scan started after the saved port went stale |
| severity | **moderate** — the whole ADB subsystem stalls for up to 20 s |
| fix | **easy** — do rediscovery outside `opLock`, or refuse it on the scan path as the comment intends |

### A8 — `UserService.exec` deadlocks on the truncation path its own comment describes

`android/app/src/main/kotlin/com/innocent/media/UserService.kt:78`

```kotlin
if (out.length > 700_000) {
    out.append("\n[truncated]\n")
    break
}
…
try { proc.waitFor() } catch (_: Throwable) {}
```

The 700 KB cap exists because *"Binder transactions are capped ~1 MB"* — a real
constraint, correctly identified. But breaking out of the read loop stops
draining the child's stdout, and `waitFor()` then waits for a process that
cannot exit because its pipe buffer is full and nobody is emptying it.
**Classic pipe deadlock, on the exact branch the comment was written for.**

This runs inside the iADB privileged server, on a binder thread. The client's
`iadbExec` never returns; `AdbService.iadbExec` has no timeout of its own
(`adb_service.dart:171`), so the Dart future never completes either — and
`shellRouted` awaits it. The user gets a spinner with no end and no error.

`iadb` is the **default backend on Android 11+** (`AdbManager.adbBackend`), and
the command that hits the cap is the ordinary `find` over `Android/data` on a
phone with a lot of app data — not an edge case.

Two lines: `proc.destroy()` before `waitFor()`, or drain the remainder into
`/dev/null` first.

| | |
|---|---|
| likelihood | **ရံဖန်ရံခါ** — a device with >700 KB of scan output, on the default backend |
| severity | **moderate-high** — a permanent hang with no error, on the default path |
| fix | **trivial** — `proc.destroy()` |

### A9 — `WRITE_SECURE_SETTINGS` is granted forever and the app never offers it back

`android/app/src/main/kotlin/com/innocent/media/AdbManager.kt:598`

```kotlin
val out = runShell(context, "pm grant $pkg android.permission.WRITE_SECURE_SETTINGS 2>&1")
```

The grant is opt-in, clearly explained on the ADB screen, and the technique is
standard. No objection to any of that.

The objection is the exit. `setAutoEnable(context, false)` writes a boolean
that stops `BootReceiver` acting. It does **not** revoke the permission, and

```
$ grep -rn "revoke" android/app/src/main/kotlin/
$
```

nothing anywhere does. So a user who turns the feature off leaves Innocent
holding a permission that lets it write **any** secure setting — location mode,
accessibility services, ADB itself — permanently, with no UI that mentions it
still exists and no way to hand it back short of uninstalling or finding
`adb shell pm revoke` on a PC, which is the exact thing this feature exists to
avoid needing.

The counter-argument is real and I will state it: `pm revoke` of a
`signature|privileged` permission needs the same shell that granted it, and if
the shell is gone the revoke cannot run — so a naive "Revoke" button would fail
for the users most likely to press it. That is an argument for wording, not for
silence.

What is missing is small: the ADB screen showing "Innocent holds
WRITE_SECURE_SETTINGS" as its own line rather than as an implementation detail
of the auto-enable toggle, a Revoke action that runs while the shell is up, and
one sentence saying what to do if it is not. A9 is a disclosure finding, not a
vulnerability.

| | |
|---|---|
| likelihood | — (structural) |
| severity | **moderate** — a powerful permission held silently and indefinitely |
| fix | **easy** — one status row and one action on a screen that already exists |

### A10 — the backend defaults disagree across the channel

`adb_service.dart:92` and `AdbManager.kt:adbBackend`:

```dart
Future<String> getBackend() async {
  try { return await _channel.invokeMethod<String>('getBackend') ?? 'builtin'; }
  catch (_) { return 'builtin'; }
}
```

```kotlin
fun adbBackend(context: Context): String {
    …
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "iadb" else "builtin"
}
```

Native's unset default on Android 11+ is `iadb`; Dart's fallback on a channel
failure is `builtin`. They only diverge when the channel throws, which is rare
— but when they do, `pullForPlayback` takes the built-in socket path while the
device is actually configured for the iADB process, and the failure looks like
"not connected" rather than like a routing mistake.

Smaller, same file: `shellRouted` calls `getBackend()` — a full platform-channel
round trip — **on every shell command**, including each of the two attempts in
the scan's fallback. Cache it and invalidate on `setBackend`.

| | |
|---|---|
| likelihood | **ရှားပါး** |
| severity | **low** — a confusing failure mode |
| fix | **trivial** — one default, expressed once |

### A11 — the iADB state callback always says "connected"

`adb_service.dart:76`

```dart
case 'onIadbState':
  // Native just signals "state changed"; re-query happens in each
  // listener (which calls the threaded iadbConnected/iadbStatus).
  _iadbStateListener?.call(true);
  for (final l in List<void Function(bool)>.of(_iadbStateListeners)) {
    l(true);
  }
```

The callback type is `void Function(bool connected)` and the value passed is
always `true` — including on a **disconnect**. The comment says listeners
re-query, and today's two listeners do. But the parameter's name is a promise
the code does not keep, and the next listener written against that signature
will believe it.

Either pass the real state (native knows it) or change the type to
`void Function()` so there is nothing to get wrong. The second is smaller and
matches what the comment says is true.

Same file, adjacent: `setIadbStateListener` overwrites a **single** slot while
`addIadbStateListener` appends to a list. Two screens calling the setter means
the first silently stops receiving. One mechanism would do.

| | |
|---|---|
| likelihood | — (latent) |
| severity | **low** — a parameter that lies |
| fix | **trivial** |

### A12 — the ADB stack has no tests

Nothing under `test/` imports anything from `lib/core/services/adb/`, and there
is no `android/app/src/test/` at all, so the Kotlin — where every finding above
except A10 and A11 lives — cannot be tested even in principle today.

One function is pure, is already extracted, and is the parser every scan result
passes through:

```dart
({String path, int sizeBytes}) parseAdbScanLine(String line)   // adb_service.dart:8
```

It is a plain string→record function with a documented tolerance rule, and it
has no tests. `AdbService.listAdbDir`'s three-field line splitter — which
carefully handles `|` inside a path and is the kind of code that decays — is
inline and therefore untestable without extracting it.

The same argument as #29: the untested code here is also the easiest to test.

| | |
|---|---|
| severity | **moderate** — structural |
| fix | **easy** for the Dart parsers; **moderate** to stand up `android/app/src/test/` |

---

## 2. Withdrawn after checking

Eleven things that look like findings and are not.

1. **`adb_connect_screen.dart` as a whole.** I went through all 1,089 lines
   looking for the pattern that produced M1 and M7 in the Video Hub audit — a
   busy flag not released, a `mounted` check missed after an await — and it is
   not there. Every async action sets `_busy` in a `try` and clears it in a
   `finally` guarded by `mounted`; `_loadAndAutoConnect` wraps its entire body
   for that reason and says so. This is the best-guarded screen in the app.
2. **`opLock`.** Correct, and the comment names the race it fixed. A6 is a race
   *below* it, not an argument against it.
3. **`isConnectionLive`.** A bounded `shell:true` probe before trusting
   `isConnected` — exactly the right answer to a half-open TCP socket, and the
   comment explains why `isConnected` alone lies.
4. **The keep-alive thread.** Bounded ping, skips during a scan, breaks out of
   its loop the moment the socket is gone so it stops taking `opLock`, restarted
   by the next successful round trip. Its own comment records that an earlier
   version was removed for hanging. Careful work.
5. **`sanitizePath`'s triple strip.** I tried to defeat it — `\"`, a trailing
   backslash, `$(…)`, backticks — and could not. It is adequate for the
   double-quoted context it is used in. A1 is that the *other* sanitiser is not.
6. **`listAdbDir`'s `' → '\''`.** The correct escape for a single-quoted shell
   argument.
7. **`pullForPlayback`'s completeness check.** `expected = fileSize(...)`, a
   `.part` file, a byte-count comparison, and a refusal to reuse a short copy —
   with a comment recording that truncated files used to be kept and rejected by
   media_kit as "unrecognised format". Right, and the same shape as the Transfer
   fix in #28.
8. **`pullForPlayback`'s stall watchdog.** 30 s of no bytes tears the connection
   down. Independently arrived at, and it matches what `docs/audit_transfer.md`
   T1 concluded for the other transport.
9. **`DownloadEngine`-style `runWithDeadline` on every round trip.** The
   comment — *"because operations hold opLock, one hung call would freeze the
   whole ADB subsystem (the 'spinner forever' bug)"* — is exactly the right
   analysis. A6a is a leak in the implementation, not a fault in the idea.
10. **`AdbService`'s fifteen `catch (_) {}` blocks.** Most are genuinely
    fire-and-forget (`stopPairingService`, `iadbDisconnect`) and returning a
    default is right. `setBackend` is the one that matters and it is listed under
    A10.
11. **`UserService` being self-contained.** The class doc insists it must not
    touch app singletons because it runs in another process with another
    classloader, and it does not. That constraint is easy to violate by accident
    and has not been.

---

## 3. What I could not settle from the client

1. **Is `QUICKBOOT_POWERON` protected on the ROMs this app's users actually
   run?** It is not in AOSP's list; some Chinese OEM ROMs add it. A3's severity
   depends on the answer for Xiaomi/MIUI, Oppo and Vivo specifically — the
   handsets this audience carries. Testable in five minutes with a second app
   on a real device.
2. **Does `pm grant` of `WRITE_SECURE_SETTINGS` survive an app update?** It
   should (grants are per-package, not per-version), but if it does not,
   `setupAutoEnable` needs re-running after every update and nothing prompts
   for that.
3. **What is the real broadcast timeout on those same ROMs?** A5 assumes the
   AOSP figures.

---

## 4. The six categories, in this domain

**Crash risk** — low in Dart, and the Kotlin catches almost everything. The
cost is paid elsewhere: A5 and A8 are hangs rather than crashes, which are
harder to report and harder to find.

**Silent failure** — A5 is the worst of them: the whole auto-enable feature can
fail to happen with every branch inside `catch (_: Throwable) {}`. A8 is a hang
with no error. A10 produces a wrong-looking error instead of the real one.

**Race conditions** — A6b, and it is below the lock that was added to fix races.
A7 is the inverse: not a race, but the lock held far too long.

**Unclosed resources** — the dominant category. Two thread-leak patterns (A6),
an HTTP server that is never stopped and has no connection cap (A2), a child
process never destroyed (A8). Set against that, `pullForPlayback` and the
keep-alive both clean up properly, and the cache is pruned.

**Invisible waits** — A8 is unbounded. A7 is up to 20 s of a frozen UI. A5 is
78 s of nothing at boot, and the user is never told whether it worked.

**UX** — mostly good. The ADB screen is honest about states, explains the
MIUI/OnePlus permission-monitoring trap by name, and offers a route to Developer
options and to About phone. A9 is the gap: the most consequential thing the
feature does is the one thing the screen does not show as its own state.

---

## 5. Fix order

**Now** — four items, none more than a few lines.

1. **A1** — call `sanitizePath` in `pullForPlayback`. One identifier.
2. **A3** — delete `QUICKBOOT_POWERON` and `LOCKED_BOOT_COMPLETED` from the
   manifest filter.
3. **A8** — `proc.destroy()` before `waitFor()`.
4. **A4** — exclude `adb_key.pk8` and `adb_cert.der` in both backup XML files.

**Before the streaming path is wired**

5. **A2** — a token in the URL, a path-prefix check, a connection cap and a
   header budget. Doing this *now*, while nothing calls it, costs an hour and
   is free of regression risk. Doing it after the one-line caller lands means
   shipping the hole first.

**Next**

6. **A6** — join the workers, or give each attempt its own manager.
7. **A7** — rediscovery outside `opLock`.
8. **A5** — `WorkManager` with a network constraint instead of three sleeps.
9. **A9** — show the permission as its own status row, with a Revoke that runs
   while the shell is up.

**Whenever**

10. A10, A11, A12.

**And one thing that is not a finding but follows from four of them.**
`session_store.dart`, `device_identity.dart`, `age_consent_store.dart` (Video
Hub M6) and now `adb_key.pk8` are the same bug found four times by four
separate reads. The rule is mechanical — *anything written to `filesDir` or to
a SharedPreferences file that is not `FlutterSecureStorage` is in the Google
Drive backup unless `backup_rules.xml` and `data_extraction_rules.xml` both say
otherwise* — and mechanical rules belong in `tool/check.py`, next to the nine
that are already there. That is the same argument #30 made about dead settings,
and it was right then for the same reason: four recurrences is not bad luck.

---

## 6. Do not touch

* **`runWithDeadline` wrapping every round trip.** Remove it and one hung
  socket freezes the entire ADB subsystem behind `opLock`. Fix the leak inside
  it; keep the pattern.
* **`isConnectionLive` before trusting `isConnected`.** It looks like a wasted
  round trip and it is the only thing standing between the UI and a confident
  "Connected ✓" over a dead socket.
* **The keep-alive's `scanInProgress` back-off.** The comment records that
  interleaving a ping between the scan's `stat` batches drops the scan on some
  devices. That is a device-specific fact nobody will rediscover from reading
  the code.
* **`exec:cat` rather than `shell:cat`.** The comment is right: `shell:` adds
  PTY translation that corrupts binary. This is the sort of line that gets
  "tidied" once.
* **The persistent key.** A4 is about where it is stored, not that it persists.
  Regenerating it would break "pair once, reconnect forever", which is the
  whole feature.

## Sources

* `android/app/src/main/res/xml/backup_rules.xml` and
  `data_extraction_rules.xml`, read in full for A4.
* `android/app/src/main/AndroidManifest.xml` §§ permissions, receivers,
  queries.
* `docs/audit_transfer.md` T1 — for the stall-watchdog comparison in §2.8.
* `docs/audit_video_hub.md` M6 — the third instance of the Auto Backup class.
* AOSP `frameworks/base/core/res/AndroidManifest.xml` protected-broadcast list
  — for A3. `QUICKBOOT_POWERON` is absent from it; §3.1 is the open question
  about OEM ROMs.
* Shell behaviour in A1 and §2.5 was verified by running it, not recalled.

## Changelog

* 13 Sep 2026 — first version. 12 findings, 11 withdrawn, 3 questions for a
  real device.
