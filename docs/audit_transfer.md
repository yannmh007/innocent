# Domain 4 — Transfer: an audit

*13 September 2026. No code changed by this document.*

Covers the sender's HTTP server, the receiver, the download isolate, UDP
discovery, Turbo Link, and the transfer foreground service.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, UX.

## What this audit deliberately does not re-report

README §*v1.64.4+317 — Transfer audited against the published research* did
the security pass properly, and by the right method: taking the known failures
of this app class from published research on SHAREit, Xender and Zapya and
checking each one, rather than reading the code and forming opinions. It found
and fixed a real CVE-shaped hole (an unthrottled four-digit `/pair` PIN, now
per-IP lockout plus constant-time comparison), verified path traversal against
a real filesystem with 67 hostile inputs, and **documented the cleartext-HTTP
exposure rather than papering over it** (`docs/BACKLOG.md` §D).

Path traversal, exported components, filename injection, PIN brute-forcing and
cleartext are therefore out of scope here. Repeating them would be noise.

This audit looks at what that pass did not: liveness, resources, and what
happens when the other phone simply stops answering.

## The short version

**One finding, and it is the whole audit.**

Nothing in the receive path has a deadline on an *active* download, and
nothing detects a stall. The code has the vocabulary — three separate comments
distinguish "paused" from "stalled" — but no clock. A sender whose phone goes
to sleep, or whose app is killed mid-share, leaves a half-open TCP connection,
and the receiver's read blocks on it until the operating system gives up,
which on Android can be many minutes or never.

**That alone would be a frozen progress bar.** What makes it the headline is
what it defeats:

```dart
/// While Turbo is joined this phone has NO internet — every other feature in
/// the app fails. … people put the phone in their pocket and forget, and
/// "my internet broke after I used that app" is the kind of bug that never
/// gets reported, only uninstalled.
/// So: if nothing is transferring for three minutes, let go by ourselves.
```

The three-minute release is guarded by `state.batchRunning`. A stalled
download never clears it. **So the safety valve written specifically to stop
"my internet broke after I used that app" is held shut by exactly the failure
it was written for**, and the phone stays pinned to the sender's link, with no
internet, indefinitely.

Everything else in this domain is in good order, and §4 says what not to
disturb.

---

## 1. Findings

Likelihood: မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).

### T1 — nothing bounds an active download, and nothing watches for a stall
`download_isolate.dart:116–117`, `file_receiver_service.dart:966` · invisible wait · **ရံဖန်ရံခါ** · the transfer hangs and the phone loses internet · **moderate**

The engine's client is configured:

```dart
..connectionTimeout = const Duration(seconds: 15)
..idleTimeout = const Duration(seconds: 40)
```

Both are real and both are the wrong tool for this. `connectionTimeout` bounds
the TCP connect. `idleTimeout` bounds a **pooled, non-active** persistent
connection. Neither bounds a response body that has started arriving and then
stops.

Above it, `IsolateDownloader.run` (`:546`) returns a bare `Completer`'s future
with no `.timeout`, and the receiver's batch loop awaits it. So the chain from
socket to UI has no deadline at any level.

Nothing detects the stall either. The word appears three times in the
receiver — `:70` ("Shown differently from a stall on…"), `:291` ("one stream
stalls on loss"), `:1209` ("It is not a stall, and…") — always to distinguish
a stall from a pause, never to notice one.

**The realistic trigger is ordinary, not exotic:** the sending phone's screen
goes off and Android freezes the app, or the sender swipes it away, mid-share.
The TCP connection is not closed — the kernel is still there — so nothing
signals the receiver.

**And it holds the Turbo safety valve shut.** `_armTurboIdleTimer` (`:966`)
re-arms rather than releasing while `state.batchRunning` is true, and
`releaseTurboIfIdle` (`:982`) returns early on the same flag. A stalled batch
never clears it. The comment above that timer says precisely what this costs:
the user's phone has no internet, they will not connect it to the stall, and
that is the kind of bug that "never gets reported, only uninstalled".

**Fix, and it is one mechanism for both halves:** a bytes-received watchdog in
the engine — no progress for *N* seconds and the request is aborted. Everything
downstream already exists and already works: the `.part` sidecar survives, the
retry path is written, and the receiver knows how to resume. The watchdog turns
a permanent hang into the retry the code is already built for, and lets
`batchRunning` fall so Turbo can let go.

`N` should be generous — 60 seconds, say. These are phone Wi-Fi links and a
long pause is not the same as a dead one; the existing pause path (the sender
truncates the body deliberately, `file_transfer_service.dart:861`) already has
its own signalling and must not be caught by this.

### T2 — the download isolate can die without anyone noticing
`download_isolate.dart:491` · silent failure · **ရှားပါး** · same hang · **easy**

```dart
final iso = await Isolate.spawn(
  _downloadIsolateEntry,
  rp.sendPort,
  errorsAreFatal: false,
  debugName: 'innocent-transfer',
).timeout(const Duration(seconds: 8));
```

No `onExit` port and no `onError` port. The worker's own `try`/`catch`
(`:606–617`) is thorough — every error inside `engine.run` comes back as an
`'err'` message — so the only way to hang is for the isolate itself to *die*:
an out-of-memory kill during a large transfer on a low-RAM phone, which is the
realistic case for this app's devices.

When it does, `_jobDone` is never completed, `isAlive` still returns `true`
because `_toIsolate` is still non-null, and the batch loop is parked forever —
the same end state as T1, and it defeats the Turbo release the same way.

Fix: pass `onExit: rp.sendPort, onError: rp.sendPort` to `Isolate.spawn`, and
in `_onMessage` treat either as a terminal error for the current job. Roughly
six lines, and it also makes `isAlive` honest so the caller can fall back to
the in-process engine — a fallback that already exists and is already correct.

---

## 2. Withdrawn after checking

**`_bytesServed += data.length` from concurrent request handlers looked like a
lost-update race.** Dart's isolate is single-threaded and `+=` on an `int`
contains no await, so no handler can be preempted mid-statement. Not a race.
The same applies to `_servedPerPeer` and `_servedPerIndex`.

**`_streamFileRange` looked like it could leak a file handle** when a receiver
disconnects mid-download. It is an `async*` generator with
`finally { await raf.close(); }` (`file_transfer_service.dart:853`), and
cancelling the consumer runs the `finally`. The 512 KB `RandomAccessFile`
blocks over `File.openRead()`'s 64 KB are deliberate and the reason is written
down.

**The received-file history looked unbounded.** Capped at 200
(`received_history.dart:62`) with the reason in the docstring.

**The discovery socket looked like it might outlive the screen.**
`_closeSocketIfIdle` cancels both timers, releases the MulticastLock and
closes the socket once neither announcing nor listening is active, and
`transfer_screen.dart:70` calls `stopListening()` from `dispose` deliberately
without going through `ref`.

---

## 3. What the six categories look like here

**Crash risk — nothing found.** Every filesystem and socket call in the
receive path is guarded, and the failure branches are written with the same
care as the success ones.

**Silent failure — T2.**

**Race conditions — none found.** The one genuinely subtle ordering problem in
this domain was found and fixed by the earlier Zapya comparison: files added
after Start were served from a stale manifest, and the fix is append-only with
indices that never move, because a receiver already holds indices into that
list. Removing a file mid-share is now blocked rather than silently
repointing everything after it. That is the right call and it is documented.

**Unclosed resources — nothing found.** The HTTP server is closed with
`force: true` (`file_transfer_service.dart:1118`), file handles close in
`finally`, the isolate is given 120 ms to flush before a hard kill so a
`.part` is not truncated mid-write, the MulticastLock is paired, and the
foreground service is stopped on every exit path.

**Invisible waits — T1, and it is the finding.**

**UX — strong, and worth recording so it is not undone.** The `.part` sidecar
renamed only on a verified length; resume sessions persisted so a swipe-away
can be picked up on relaunch; a whole-batch free-space check that first
subtracts the files already present, because re-sharing a folder to a phone
that has most of it is the common case and counting bytes that will never be
written would refuse a batch that fits; a 64 MB margin on top; the headline
progress bar tracking the furthest-along receiver rather than a sum, because
with three phones pulling one file a sum reads 300% and means nothing.

---

## 4. What is needed, nice, and not needed

### Really needed

1. **T1 — a bytes-received watchdog.** It converts the one unbounded wait in
   this domain into the retry the code is already built for, and it is the
   only thing standing between a sleeping sender and a receiver with no
   internet.

### Nice to have

2. **T2 — `onExit` and `onError` on the isolate.** Six lines, and it makes the
   existing in-process fallback reachable.
3. **A visible "stalled" state** once the watchdog exists — the receiver
   already distinguishes paused from stalled in its comments, but has never
   been able to show the second one.

### Not needed

* **A connection cap on the sender's server.** `idleTimeout` is 60 s
  (`file_transfer_service.dart:1097`) and reaps what accumulates; dart:io has
  no direct cap, and counting in the handler would add a failure mode to
  prevent one that has not been seen.
* **HTTPS on the LAN.** Already reasoned through in §v1.64.4 and
  `docs/BACKLOG.md` §D: a self-signed certificate trains users to click
  through security warnings, and a real certificate for an IP address is not
  issuable. The PIN — now that guessing is throttled — and approval mode are
  the controls.
* **Running several files at once.** The docstring says why: one Wi-Fi link,
  so parallel jobs split the same airtime while multiplying seek load on the
  flash.
* **Re-checking free space on `refreshManifest`.** The refresh only updates
  the list; pulling goes back through the batch start, which checks.

---

## 5. Do not touch

1. **Append-only file indices, and the block on removing a file mid-share.** A
   receiver holds indices into that list; renumbering hands it the wrong bytes
   under the right name.
2. **`.part` sidecar, renamed only after the length verifies**
   (`file_receiver_service.dart:635–700`), and the note that a failed rename
   still leaves a complete file rather than losing it.
3. **The 120 ms grace before `Isolate.kill`** — so a `.part` is flushed, not
   truncated.
4. **Per-IP PIN lockout rather than global**, and clearing it on a correct
   PIN. A global counter is a denial of service wearing a security control's
   clothes; fumbling one's own PIN is the common case.
5. **Constant-time PIN comparison.** A plain `!=` returns as soon as two
   characters differ, which turns 10,000 guesses into about 40.
6. **Lockouts cleared when sharing stops** — per session, so the map cannot
   grow across sessions.
7. **The MulticastLock** (`transfer_discovery.dart:236`). Without it discovery
   works on some phones and not others, and it is the single most common cause
   of "it finds nothing on my Redmi".
8. **Priming the device id before the socket exists** (`:211`) — otherwise the
   first datagram can list our own broadcast as a nearby device.
9. **512 KB `RandomAccessFile` reads** instead of `File.openRead()`'s 64 KB
   default.
10. **Cutting the response short on pause** (`file_transfer_service.dart:861`)
    so the receiver fails its byte count, retries, and lands on the 503 —
    with its partial file intact. A watchdog added for T1 must not catch this.
11. **The free-space check subtracting files already present**, and its 64 MB
    margin.
12. **The Turbo idle release** (`file_receiver_service.dart:966`) and
    `releaseTurboIfIdle` on teardown. T1 is that these do not fire when they
    are needed most — not that they are wrong.
13. **`server.autoCompress = false`.** Compressing video wastes CPU on both
    ends for nothing.

---

## Sources

* Read this session: `file_transfer_service.dart`,
  `file_receiver_service.dart`, `download_isolate.dart`,
  `transfer_discovery.dart`, `received_history.dart`,
  `transfer_screen.dart`, `TransferService.kt`.
* README §v1.64.4+317, §v1.48.0+265, §v1.47.0+263, §v1.46.0+262 — the previous
  audits of this domain, and `docs/BACKLOG.md` §D for the cleartext decision.
* Dart's `HttpClient.idleTimeout` applying to pooled, non-active connections
  rather than to an in-flight response body is stated from the API's
  documented behaviour and was **not** re-verified experimentally this
  session. If it turns out to bound an active read, T1's severity drops to the
  isolate case alone.

## Changelog

* 2026-09-13 — first version. No code changed.
