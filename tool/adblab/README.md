# adblab — the app's ADB reading code against the ADB library's own code

The app talks to adbd through **libadb-android 3.1.1**. This lab compiles that
library's connection, stream and manager classes from source (the same tag
JitPack builds), puts the app's `AdbRead.java` beside them, and runs them over
a real local socket against `FakeAdbd` — a small adbd that speaks the wire
protocol (CNXN, OPEN, OKAY, WRTE, CLSE) with adbd's flow control.

```sh
tool/adblab/run.sh        # 150 runs per case; needs a JDK and git
```

No phone, no Android SDK. The few `android.*` / `androidx.*` names the library
touches, pairing and mDNS are stubbed (`stubs/`): none of them is under test.

## What it showed (11 Oct 2026), and why the app reads the way it does

A Samsung SM-S918B (Android 16) sent an engine log where every Android/data
scan ended in `IOException: Stream closed.` ~1.7 s in, the `echo ok` probe
timed out, and keep-alive called a working connection gone. Three faults in
how the library behaves, all reproduced here:

1. **No clean end of a stream.** When adbd closes a stream, a reader that has
   already taken every byte gets `IOException("Stream closed.")` (the output is
   lost); a reader with bytes still queued takes them, and its next read waits
   forever. Reading to the end — what the app did — failed in 148 of 150 `id`
   runs, 150 of 150 probes, and 33 of 50 scans here. `AdbRead` sends each
   command with a random end marker and stops at it; file ranges stop at their
   known length (with a stall guard). 100 % of runs pass; a shell that dies
   before its marker is reported as cut off, not returned as an answer.

2. **The manager lock is held while waiting, with no time limit.** `connect()`
   waits for the handshake (default timeout: forever) and `openStream()` for
   adbd's OKAY while holding the lock that `isConnected()` and `disconnect()`
   need. A port that accepts TCP but never speaks ADB froze `isConnected()`
   everywhere (30 s on the phone, until the other server gave up). Each
   connect attempt now gives the library its own budget.

3. **Disconnecting does not free a stuck worker** — it queues behind it. The
   waits are `Object.wait()`s, so the app now interrupts the worker first
   (freed in milliseconds), then disconnects.

`info` lines are the old behaviour, kept for comparison; `PASS`/`FAIL` lines
are what the app does now. Run it again after any change to `AdbRead.java`,
to the way `AdbManager.kt` reads streams, or to the library version.
