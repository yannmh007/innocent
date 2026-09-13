# Domain 1 — the Downloader: an audit

*12 September 2026. No code changed by this document.*

Covers the in-app browser, the read (probe) pipeline, the queue, the DNS
bypass proxy, and the foreground download service. Filenames and metadata are
audited separately in `docs/filename_audit.md`; the yt-dlp engine's
self-update in `docs/engine_update_audit.md`. Neither is repeated here.

Six categories, as asked: crash risk, silent failure, race conditions,
unclosed resources, invisible waits, and UX.

## Method

The repository history is one squashed commit, so per-line `git log` gives
nothing — **the comments are the history**, and this codebase's comments are
unusually complete. Several things that look wrong at a glance turn out to be
answers to a specific past failure, with the failure written down beside them.
Those are in §6, not in §3.

Three findings I started to write were withdrawn after checking:

* `initBlocking` looked like an unsynchronised double-checked init that would
  make two of three concurrent downloads report "engine unavailable". It is
  `@Synchronized` (`DownloadEngine.kt:1525`) and the class comment at `:37`
  says so explicitly.
* The browser's probe looked like it shared a process id with the screen's.
  There is a separate `BROWSER_PROBE_ID` (`:87–88`) with a comment saying
  exactly why. (A *different* sharing problem does exist — F6 — but not the
  one I first suspected.)
* The download history looked unbounded in SharedPreferences. It is capped at
  200 (`downloader_providers.dart:_max`) with a comment giving the reason.

Everything below was traced to source and, where behaviour was in question,
simulated. Every `file:line` was re-verified against the working tree.

## The short version

**The engine layer is in good shape and the edges are not.** Zero `!!` in
6,000 lines of Kotlin. Every `.first` in the parser is guarded. Dispose
hygiene on the Dart side is complete. The concurrency work — five purpose-built
executors, per-job progress clocks, tag-scoped file resolution — is careful and
documented.

What is weak is everything that surrounds a download rather than performs one:

* **Wi-Fi-only is enforced in one of the four places a download can start.**
  The quality sheet checks it. The quick-download preset, the playlist sheet
  and the browser pick do not. A user who switched it on to protect their data
  allowance queues a 40-item playlist over mobile without a word. The
  free-space check has the same hole, in the same three places.
* **A download started from the browser silently ignores every Extras
  setting** — subtitles, thumbnail, metadata, and the speed limit — while the
  comment directly above the call claims the opposite.
* **The DNS bypass proxy can die and keep saying it is running.** One
  exception out of `accept()` stops the loop; `port` stays non-zero, so
  `isRunning` is true, so aria2c keeps being pointed at a socket nobody is
  accepting on. Connections then *hang* rather than fail, which is the worse
  of the two.
* **The upstream socket in that proxy has no read timeout** while the client
  socket has 30 seconds. An upstream that connects and then goes silent — the
  precise behaviour of the interference this proxy exists to route around —
  parks a pool thread and two sockets for good.

---

## 1. The shape of the thing

| piece | where | what it owns |
|---|---|---|
| in-app browser | `BrowserActivity.kt` (4,138 lines) | a platform `WebView`, its own quality sheet, the pick that starts a download |
| engine | `DownloadEngine.kt` (3,883) | yt-dlp, aria2c, ffmpeg; five executors; probe, download, resolve, status, update |
| foreground service | `DownloadService.kt` (357) | the notification, WifiLock + partial WakeLock, shade buttons |
| DNS bypass | `DnsBypassProxy.kt` (316) | a loopback HTTP/CONNECT proxy that re-resolves tampered names over DoH |
| read pipeline | `probe_pipeline.dart` (204) | the one sequence that answers "what can this link be downloaded as" |
| queue | `downloader_providers.dart` (1,305) | specs, phases, persistence, history, the browser's event handlers |
| UI | `downloader_home_screen.dart` (3,938), `quality_sheet.dart` (956), `playlist_sheet.dart` (302) | |

**Five executors, on purpose** (`DownloadEngine.kt:92, 113, 133, 150, 159`).
The class comment at `:37` and `:146` explains: reads, downloads, updates,
status and metadata each get their own thread so a slow one cannot block a
fast one, and `initBlocking` is `@Synchronized` so they can all call it
without racing. `probeExec` is single-threaded deliberately — two yt-dlp reads
at once on a phone is not faster.

**One read pipeline, shared** (`probe_pipeline.dart`). The file's own comment
records why: the browser used to have its own reader in Kotlin, and the same
YouTube video gave a full sheet when pasted and a soundless one when found in
the browser. That is fixed and must stay fixed.

---

## 2. Where a download can start

This matters more than it looks, because the pre-flight checks live on only
one of the four paths.

| path | file:line | Wi-Fi-only | free space | Extras passed |
|---|---|---|---|---|
| quality sheet | `quality_sheet.dart:431` → `:269` | **✓** | **✓** | ✓ |
| quick preset | `downloader_home_screen.dart:1094` | ✗ | ✗ | ✓ |
| playlist | `playlist_sheet.dart:51` | ✗ | ✗ | ✓ |
| browser pick | `downloader_providers.dart:1052` | ✗ | ✗ | **✗** |

`_clearedToStart` (`quality_sheet.dart:269`) is a good function. Its own
comment says the right thing — *"the user can override — but neither happens
silently"* — and then it is called from exactly one of four callers.

---

## 3. Findings

Likelihood: မကြာခဏ (often) / ရံဖန်ရံခါ (sometimes) / ရှားပါး (rare).

### F1 — "Wi-Fi only" is enforced on one of four start paths
`quality_sheet.dart:279` · silent failure · **မကြာခဏ** · costs the user money · **moderate**

The setting exists (`downloader_providers.dart:491`), has a switch
(`downloader_home_screen.dart:3614`), and is honoured only when the download
was started from the quality sheet. The playlist sheet queues up to forty
items with no check at all; the browser pick — which is how most downloads
from these sites actually start — has none either.

For an audience on Myanmar mobile data this is the most expensive finding in
this document. It is not a crash and nothing looks broken; the bill arrives
later.

Fix: lift `_clearedToStart` out of `_QualitySheetState` into a function the
queue notifier can call, and put it in front of every `startDownload`. It is
already `async` and already takes its inputs as parameters, so the lift is
mechanical — the work is in the playlist case, where the question should be
asked once for forty items rather than forty times.

### F2 — the free-space check has the same hole
`quality_sheet.dart:284` · silent failure · **ရံဖန်ရံခါ** · failed download + a full card · **moderate**

Same three paths, same function. The playlist case is the one that matters:
forty items is exactly the shape of request that fills a phone. Without the
check the downloads run until the filesystem refuses, and what the user sees
is several rows failing for no stated reason with the card full.

Fixed by the same lift as F1.

### F3 — a browser download ignores every Extras setting
`downloader_providers.dart:1075` · silent failure + UX · **မကြာခဏ** · annoyance · **trivial**

```dart
/// … everything else is answered here, once: where files go, which cookies
/// apply, which extras are set. A second place answering those questions is
/// a second place to get them wrong …
```

The comment is right about the principle and the code below it does not do
it. The `startDownload` call passes `cookies` and `clients` and stops there —
no `subLangs`, no `embedThumbnail`, no `embedMetadata`, and **no
`rateLimit`**. `playlist_sheet.dart:95–99` passes all four; the quality sheet
passes all four; the browser passes none.

So a speed limit set to protect a shared connection is silently not applied to
the downloads most likely to be large. Four lines, copied from the sibling
call twelve lines away.

### F4 — the DNS bypass proxy can die and still report itself running
`DnsBypassProxy.kt:166` · silent failure · **ရှားပါး** · every download through it hangs · **easy**

```kotlin
private fun accept(socket: ServerSocket) {
    while (!socket.isClosed) {
        val client = try { socket.accept() } catch (_: Throwable) { return }
        pool.execute { serve(client) }
    }
}
```

`return` on **any** throwable — including a transient one such as EMFILE under
file-descriptor pressure, which is exactly what a phone running three
downloads and a WebView produces. The loop ends. But `stop()` is the only
thing that clears `port`, so `isRunning` (`:107`) still returns true, and
`DownloadEngine.kt:3565`-region code keeps handing
`--all-proxy=http://127.0.0.1:<port>` to aria2c.

The failure mode is worse than a refusal. The `ServerSocket` is still open and
bound with a backlog of 64, so the kernel completes the TCP handshake and then
nothing ever reads: **aria2c connects successfully and hangs**, rather than
erroring and falling back.

Fix: separate the expected close from the unexpected error —

```kotlin
catch (t: Throwable) {
    if (!socket.isClosed) stop()   // so isRunning goes false and callers know
    return
}
```

### F5 — the upstream socket has no read timeout
`DnsBypassProxy.kt:197, 213` · unclosed resources + invisible wait · **ရံဖန်ရံခါ** · leak · **trivial**

`client.soTimeout = 30000` is set at `:183`. `upstream` gets a **connect**
timeout (`:198`, `:214`) and no `soTimeout`, so `copy(b.getInputStream(), …)`
at `:290` blocks indefinitely when the far side accepts and then says nothing.

That is not a hypothetical: connect-then-silence is the signature of the
interference this proxy was written to route around. Each stuck tunnel holds a
`newCachedThreadPool` thread (unbounded), a client socket and an upstream
socket, none of which are ever released — `serve`'s `finally` cannot run while
the read is blocked.

Fix is one line, `upstream.soTimeout = 30000`, and it is symmetric with what
the client side already does — so it changes nothing for a healthy tunnel that
the existing client-side timeout does not already change.

### F6 — the screen's read and the browser's read share one process id
`downloader_engine_service.dart:644` · race · **ရံဖန်ရံခါ** · a read fails for no visible reason · **easy**

`BROWSER_PROBE_ID` (`DownloadEngine.kt:88`) covers the browser's **Kotlin**
fallback reader. It does not cover the path that actually runs: the browser
asks Dart (`downloader_providers.dart:1032` → `probe_pipeline.dart:175`),
Dart calls `probe()`, and that goes through the `"probe"` channel method to
`runProbe`, which uses **`PROBE_ID`** (`:2339`) — the same id the downloads
screen uses.

Both also queue on the single-threaded `probeExec` (`:92`). So:

1. Probe A (screen) is running under `PROBE_ID`.
2. Probe B (browser) is submitted; it waits in `probeExec`'s queue.
3. B's Dart-side 75-second timeout (`:623`) fires **while B is still queued**
   and calls `cancel('innocent-probe')` (`:644`).
4. `cancelJob` marks and kills `PROBE_ID` — which is **A's** process.

A dies with a cancellation it never asked for; B has still not run. Neither
user-visible message says anything true.

Fix: give the Dart-routed browser read its own id, the way the Kotlin one
already has — pass an id through `probe()` and thread it to `run(request, id)`.
The infrastructure for two ids is already there and already commented; it is
one method's worth of plumbing to use it.

### F7 — closing the browser leaves the read that answers it running
`BrowserActivity.kt:4126` · unclosed resources · **ရံဖန်ရံခါ** · battery · **easy**

```kotlin
// A read nobody is waiting for is a Python process burning battery on
// a phone whose owner has walked away.
DownloadEngine.cancelBrowserProbe()
```

The intent is exactly right. `cancelBrowserProbe` cancels `BROWSER_PROBE_ID`,
which — per F6 — is the *fallback* reader, not the one the browser normally
uses. The Dart-routed read keeps going under `PROBE_ID` for up to 75 seconds
after the browser is gone.

Fixing F6 fixes this too: once the Dart browser read has its own id, cancelling
it here is one more line.

### F8 — `WebView.destroy()` is called while the view is still attached
`BrowserActivity.kt:4132` · crash risk · **ရှားပါး** · crash · **trivial**

The WebView is added to `holder` (`:1743` region) and `onDestroy` calls
`stopLoading()`, `removeJavascriptInterface(...)`, `destroy()` — without
removing it from its parent first. Android's own documentation says `destroy()`
"should be called after this WebView has been removed from the view system".
The surrounding `try/catch (_: Throwable)` swallows a Java exception but not a
native abort in the WebView renderer, and it does not stop the native heap
being retained.

Fix: `(web?.parent as? ViewGroup)?.removeView(web)` immediately before
`destroy()`.

### F9 — the WebView keeps running while the browser is in the background
`BrowserActivity.kt:4108` · UX · **မကြာခဏ** · battery + data · easy — **uncertain whether deliberate**

`onPause` flushes cookies and nothing else. There is no `web?.onPause()` and
no `pauseTimers()`, so a page left behind keeps running its JavaScript, its
timers and — on these sites — its autoplaying video. On a metered connection
that is data spent on a page nobody is looking at.

**I could not find a comment or a code path saying background playback in the
browser is wanted**, and nothing in the app appears to depend on it. But the
absence of a comment is not proof of an oversight in this codebase, so this is
listed as a question rather than a defect: if browser audio is meant to
continue, this is correct as written and should get a comment saying so.

### F10 — the worst-case read is about three minutes with no cap
`probe_pipeline.dart:33` · invisible wait · **ရံဖန်ရံခါ** · annoyance · **moderate**

The budgets compose and nothing bounds the total:

```
ensureCurrent()           up to  40s   (engine_readiness.dart:72)
probe()                   up to  75s   (downloader_engine_service.dart:623)
alternateYouTubeRead()    up to  75s   (a second probe, same timeout)
                                ─────
                                 190s
```

The screen is honest about it — `_probeTimer` ticks a visible seconds counter
(`downloader_home_screen.dart:542`) and the comment explains why the clock
starts before the engine wait. So this is not silent. It is just very long, and
there is no point at which the app offers to stop trying, or says "this one is
taking unusually long".

The browser's case is worse, because the browser is blocked on its own latch
and the user is looking at a spinner over a web page rather than at a counter.

Worth noting the second probe only runs for YouTube links that returned a
single video format (`:90–93`), so the 190s tail is narrow. A ceiling on the
whole `read()` — say 120s — would cost nothing real and would bound it.

### F11 — the plain-HTTP proxy path corrupts non-ASCII header bytes
`DnsBypassProxy.kt:236` · silent failure · **ရှားပါး** · a corrupted request · **trivial**

`readHead` accumulates with `out.append(b.toChar())` — byte to char, i.e.
Latin-1 — and `:216` sends it with `head.toByteArray()`, i.e. **UTF-8**. Any
byte ≥ 0x80 in the request head is expanded from one byte to two on the way
out, silently changing the request.

HTTP headers are supposed to be ASCII and browsers percent-encode, so this is
rare. It also affects only the plain-`http` branch — the `CONNECT` tunnel at
`:190–206` is byte-transparent and every site here is https. Listed for
completeness; the fix is `ISO_8859_1` on the way out, or reading the head as
bytes throughout.

### F12 — `served` and `rescued` are non-atomic
`DnsBypassProxy.kt:203, 219` · race · **ရှားပါး** · cosmetic · **trivial**

`@Volatile var served: Int` incremented with `++` from many pool threads.
Volatile makes the read visible; it does not make the increment atomic. These
are diagnostic counters shown in the device report, so the cost is an
undercount in a trail. `AtomicInteger`, or leave it and note that the number is
approximate.

### F13 — `stop()` does not interrupt tunnels already open
`DnsBypassProxy.kt:152` · UX · **ရှားပါး** · annoyance · **moderate**

Turning the bypass off (`disable(ctx)`) closes the listening socket and clears
the cache. Connections already established keep flowing through the proxy
until they end on their own. Not harmful, but "off" does not mean off until
the last tunnel closes. Tracking live sockets to close them is more machinery
than the problem deserves; recording the behaviour is probably enough.

---

## 4. What the six categories actually look like here

**Crash risk — low.** Zero `!!` in `DownloadEngine.kt` and
`BrowserActivity.kt` combined. Every `.first` in the parse path is guarded by
an emptiness check immediately above it (`probe_parser.dart:63`, `:254`;
`media_probe.dart:304`, `:311`). The only crash-shaped finding is F8, and it is
one line.

**Silent failure — the weak spot.** F1, F2, F3, F4 and F11 are all of one
shape: something the app promises is not done, and nothing says so. F1 and F3
are the ones a user would actually notice, eventually, in the wrong way.

**Race conditions — mostly handled, one real gap.** The concurrency design is
deliberate and documented: `@Synchronized` init, per-job progress clocks,
`AtomicLong`/`AtomicInteger` where it matters, tag-scoped file resolution
against three parallel downloads. F6 is the one place two callers share a name
they should not.

**Unclosed resources — one real leak (F5), one battery leak (F7), one
question (F9).** Dart-side dispose hygiene is complete: every
`TextEditingController`, `FocusNode`, `Timer` and `StreamSubscription` in the
downloader has a matching cancel or dispose, including the two that live in a
`StateNotifier` rather than a widget (`downloader_providers.dart:1293`).

**Invisible waits — visible, but long.** F10. The seconds counter and the
"waiting for readiness" line mean the app is honest about waiting; it just
waits for a long time and never offers a way out.

**UX — F1 and F3 are UX failures as much as correctness ones**, because both
are settings that appear to work. Beyond those, the downloader's UX is
well-covered: "Finalizing…" instead of a frozen bar, shade buttons for
pause/cancel/resume, the queue surviving a restart as *paused* rather than
pretending to run, and every failure landing in the diagnostics trail.

---

## 5. What is needed, nice, and not needed

### Really needed

1. **F1 + F2 — one pre-flight in front of every start.** Lift
   `_clearedToStart`; call it from the quick preset, the playlist sheet and the
   browser pick. Ask once per playlist, not once per item.
2. **F3 — pass the four Extras on the browser path.** Four lines. The comment
   above it already claims this is done.
3. **F4 — the proxy must not lie about being up.** A hang is worse than an
   error, and this produces a hang.
4. **F5 — `upstream.soTimeout = 30000`.** One line, symmetric with the client.

### Nice to have

5. **F6 + F7 — a third probe id for the Dart-routed browser read**, and cancel
   it when the browser closes. The two-id pattern already exists.
6. **F8 — remove the WebView from its parent before destroying it.**
7. **F10 — a ceiling on `ProbePipeline.read`**, and a "still trying" line once
   past ~30 seconds.
8. **F11, F12** — small correctness tidies in the proxy.
9. **F9 — decide and write it down**: pause the WebView on background, or say
   in a comment why it must not be paused.

### Not needed

* **Making `probeExec` multi-threaded.** Two yt-dlp reads at once on a phone
  is slower, not faster, and the serialisation is what makes the single
  `PROBE_ID` nearly safe today.
* **A retry around F4's `accept()`.** Failing loudly and letting the download
  path fall back to a direct connection is better than a proxy that keeps
  trying to come back.
* **Bounding `DnsBypassProxy.pool`.** A cached pool reaps idle threads after
  60 seconds; with F5 fixed there is nothing to bound.
* **Replacing the platform WebView with a plugin.** The comment at
  `BrowserActivity.kt:44` gives the reason — no new dependency, no build risk,
  and it matches `SignInWebViewActivity` next door.

---

## 6. Do not touch

Things in this domain that look odd and are answers to a specific past
failure. Each has a comment in the source saying so; this list is a pointer,
not a replacement.

1. **Five separate executors** (`DownloadEngine.kt:92, 113, 133, 150, 159`) and
   `initBlocking` being `@Synchronized` (`:1525`). Comments at `:37` and
   `:146`.
2. **`probeExec` being single-threaded.** Deliberate serialisation.
3. **`BROWSER_PROBE_ID` separate from `PROBE_ID`** (`:87–88`) — "so cancelling
   one never kills the other". F6 is that this separation does not go far
   enough, *not* that it was a mistake.
4. **`cancelledIds.remove(PROBE_ID)` at the top of `runProbe`** (`:2406`). The
   comment records a downloader that "silently stopped producing anything"
   without it.
5. **`--downloader http,https:libaria2c.so`** scoped by protocol — aria2c
   cannot walk an HLS fragment list.
6. **Exactly one `--downloader-args` call.** `YoutubeDLRequest` keys options by
   name, so a second call replaces the first.
7. **Telling aria2c about the proxy separately** — youtube-dl #23730: the
   extraction succeeds through the proxy and the download goes direct and dies.
8. **HLS on yt-dlp's native fragment downloader rather than ffmpeg** — yt-dlp
   #11642; ffmpeg's progress never reaches the hook, which is why the bar sat
   at zero.
9. **`--file-allocation=none`**, **`--stream-piece-selector=geom`**,
   **`--max-connection-per-server=16`** — each has a measured reason beside it.
10. **The per-job `lastEmit` clock** rather than one shared field: with three
    downloads a shared clock meant two of three rows sat still.
11. **`onTaskRemoved` deliberately not calling `stopSelf`**
    (`DownloadService.kt:28`) — swiping the app away must not kill a download.
12. **The default player client going first again** (v0.99.6 note at `:2412`):
    the alternate clients are faster and answer with a much shorter format
    list.
13. **`WebViewFeature.isFeatureSupported(PROXY_OVERRIDE)` gating**
    (`BrowserActivity.kt:1191`) — the call throws on an ancient WebView.
14. **`DnsBypassProxy` asking the system resolver first** (`:256–264`). The
    proxy is transparent on a healthy network by design; a distant resolver's
    answer for a large site is a *worse* address, not a better one.
15. **`_probeGeneration`** (`downloader_home_screen.dart:531`) — a newer link
    takes over and the older read must not write to the screen.
16. **`unawaited(ProbePipeline.answerBrowser(...))`**
    (`downloader_providers.dart:1032`) — the browser is blocked on a latch, so
    replying immediately is the point, and an empty answer is still an answer.
17. **The queue restoring as `paused`, never `running`**
    (`downloader_providers.dart:1108`) — the process died with the app.

---

## Sources

* Source read this session: `DownloadEngine.kt`, `BrowserActivity.kt`,
  `DownloadService.kt`, `DnsBypassProxy.kt`, `probe_pipeline.dart`,
  `probe_parser.dart`, `media_probe.dart`, `downloader_providers.dart`,
  `downloader_engine_service.dart`, `quality_sheet.dart`,
  `playlist_sheet.dart`, `downloader_home_screen.dart`,
  `engine_readiness.dart`.
* `WebView.destroy()` attachment requirement — Android platform documentation.
* youtube-dl #23730 and yt-dlp #11642 are cited by the code itself; both are
  recorded here as the code's own references, not re-verified against the
  trackers this session.

## Changelog

* 2026-09-12 — first version. No code changed.
