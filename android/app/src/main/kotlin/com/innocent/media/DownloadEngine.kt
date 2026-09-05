package com.innocent.media

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.StatFs
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Handler
import android.os.Looper
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * v0.99 Downloader: the ONLY class in Innocent that touches yt-dlp.
 *
 * Design notes that matter:
 *
 *  • INIT IS LAZY. YoutubeDL.init() unpacks a Python 3.8 runtime (plus ffmpeg
 *    and aria2c) out of the extracted native libs into app storage — tens of MB
 *    and several seconds on first run. Doing that in Application.onCreate would
 *    add that cost to EVERY cold start of Innocent, including for users who
 *    never open the downloader. So nothing happens until the Downloader screen
 *    asks, and [initBlocking] is @Synchronized + idempotent so concurrent
 *    callers wait rather than racing.
 *
 *  • v0.99.1 — A PERSISTENT CACHE DIR IS PASSED ON EVERY CALL. This is the
 *    single biggest speed fix in the whole feature. yt-dlp caches the
 *    deciphered YouTube player JavaScript (the signature / "n parameter"
 *    functions) under its cache dir. On Android there is no writable HOME, so
 *    the default location silently fails and the cache is effectively off —
 *    meaning every link re-downloads the ~2 MB player script and re-runs the JS
 *    challenge through Python. That is most of the "Reading link…" wait, and it
 *    was being paid on every paste instead of once.
 *
 *  • FFMPEG, ARIA2C AND THE UPDATER ARE REACHED REFLECTIVELY. Their class
 *    packages and the UpdateChannel shape are not pinned by the library's
 *    public docs. Referencing them directly would make a wrong guess a COMPILE
 *    error; reaching them by name makes it a recoverable runtime status we can
 *    show in the UI and degrade around. The core YoutubeDL class is imported
 *    normally — without it there is no feature at all, and its package is
 *    documented.
 *
 *  • UP TO [MAX_PARALLEL_DOWNLOADS] AT A TIME, by construction: [dlExec] is a
 *    fixed pool, so submitting is the queue and the pool size is the limit.
 *    This was one for a long time and the reasoning is preserved at the field
 *    -- it was changed because a queued row that never moves reads as a lost
 *    download, not as a queue. Probes get their own thread so pasting stays
 *    responsive.
 *
 *  • PROGRESS IS THROTTLED TO ~1/SEC. yt-dlp emits progress lines many times a
 *    second; forwarding each one over the method channel and into a
 *    notification is exactly the mistake that made the transfer notification
 *    stutter. Terminal events are never throttled.
 */
internal object DownloadEngine {

    private const val METHOD_CHANNEL = "mx_clone/downloader"
    private const val EVENT_CHANNEL = "mx_clone/downloader/events"
    private const val BROWSER_CHANNEL = "mx_clone/downloader/browser"

    /** Fixed process ids so the UI can cancel a probe/resolve by name. */
    private const val PHOTO_USER_AGENT =
        "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 " +
            "(KHTML, like Gecko) Chrome/122.0.0.0 Mobile Safari/537.36"

    private const val UPDATE_ATTEMPTS = 3
    private const val UPDATE_WAIT_MS = 30_000L
    private const val MAX_DOWNLOAD_ATTEMPTS = 4
    private const val RETRY_BACKOFF_MS = 3000L

    private const val PROBE_ID = "innocent-probe"

    /** Separate from PROBE_ID so cancelling one never kills the other. */
    private const val BROWSER_PROBE_ID = "innocent-browser-probe"
    private const val RESOLVE_ID = "innocent-resolve"

    private val main = Handler(Looper.getMainLooper())
    private val probeExec = Executors.newSingleThreadExecutor()

    /**
     * How many downloads may run at once.
     *
     * ONE AT A TIME WAS A DEFENSIBLE CHOICE THAT READ AS A BROKEN APP. The
     * bandwidth argument in the class comment is sound -- two yt-dlp processes
     * on a mobile connection largely divide the same pipe -- but it missed what
     * the person sees. The entire point of downloading from inside the browser
     * is to start one video and carry on looking for the next, and the next one
     * said "Queued" and then sat still for as long as the first one took. A
     * stationary row does not read as a working queue; it reads as a download
     * that was thrown away.
     *
     * Three rather than unlimited, because each job is a Python process with an
     * ffmpeg or aria2c child and the phones this is built for have four cores
     * and little spare memory. Three is enough that nobody watches a row do
     * nothing, and few enough that nothing thrashes.
     */
    private const val MAX_PARALLEL_DOWNLOADS = 3

    private val dlExec = Executors.newFixedThreadPool(MAX_PARALLEL_DOWNLOADS)

    /**
     * The updater gets its OWN thread, and this is not a detail.
     *
     * It used to share [probeExec] with reading links, which meant a link
     * pasted while the weekly update happened to be running sat in a queue
     * behind a multi-megabyte binary download — up to three attempts with
     * pauses between them. On screen that is "Reading link…" spinning for
     * thirty seconds or more with nothing wrong.
     *
     * It showed up as the strangest possible bug report: sharing a link from
     * another app never worked, while copying the same link and pasting it a
     * few seconds later always did. The difference was never the link. Opening
     * the screen starts the update check, and the share path reads the link in
     * the same instant, whereas pasting happens after the check has finished.
     *
     * Reading a link is the one thing a person is actually waiting for, so
     * nothing is allowed to queue in front of it.
     */
    private val updateExec = Executors.newSingleThreadExecutor()

    /**
     * Readiness checks get their own lane as well.
     *
     * `ensureReady` unpacks a Python runtime on first run and then spawns a
     * process to read the version — tens of seconds after a fresh install. It
     * used to sit on [probeExec], so the very first read of a link queued
     * behind all of it. That is invisible when someone opens the screen and
     * then goes off to copy a URL, and glaring when a shared link is read the
     * instant the screen appears: the same "sharing never works, pasting
     * always does" shape as the updater bug, from a second cause.
     *
     * Safe to run in parallel because [initBlocking] is @Synchronized and
     * idempotent — whoever arrives first does the work and the other waits for
     * exactly as long as it needs to, rather than for everything else too.
     */
    private val statusExec = Executors.newSingleThreadExecutor()

    /**
     * Reading a downloaded file's duration off its header (see probeDurations)
     * gets its OWN thread, kept off probeExec so a batch of reads never sits in
     * front of a link the person just pasted. One thread is enough — each read
     * is a header parse of milliseconds, and serialising them avoids holding
     * many MediaMetadataRetrievers open at once on a low-memory phone.
     */
    private val metaExec = Executors.newSingleThreadExecutor()

    /**
     * Number of probes running or queued. The updater checks this and steps
     * aside: yt-dlp's own binary being replaced underneath a running
     * extraction is not something to find out about the hard way.
     */
    private val probesInFlight = java.util.concurrent.atomic.AtomicInteger(0)

    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var sink: EventChannel.EventSink? = null

    /**
     * A channel of its own for choices made in the in-app browser.
     *
     * NOT the download event stream, deliberately. That stream is a progress
     * contract and DownloadEvent._phaseOf maps any phase it does not recognise
     * to `error` — so a pick sent down it would arrive looking like a download
     * that had already failed. Two different kinds of message deserve two
     * channels; sharing one to save a few lines would corrupt both.
     */
    /**
     * The Activity to launch our own screens from, when we have one.
     *
     * WHY THIS EXISTS, and it is a correction of my own mistake: I first tried
     * to stop the browser getting its own card in Recents by giving it
     * `android:taskAffinity=""` to match MainActivity. That is backwards.
     * An EMPTY affinity means the activity belongs to NO task, so
     * FLAG_ACTIVITY_NEW_TASK gives it a brand new one every single time —
     * guaranteeing the duplicate it was meant to prevent.
     *
     * The actual fix is to stop asking for a new task at all: launched from
     * the Activity that is already on screen, our screens stack on top of it
     * in the one task, and back walks down that stack the way anyone would
     * expect. The application context is kept as a fallback for the case where
     * nothing is on screen, where a new task IS the only option.
     *
     * Weak so a finished Activity can still be collected.
     */
    private var activityRef: java.lang.ref.WeakReference<Activity>? = null

    private var browserChannel: EventChannel? = null
    private var browserSink: EventChannel.EventSink? = null
    private var appContext: Context? = null

    private var initTried = false
    private var initOk = false
    private var ytdlpVersion: String? = null
    private var initError: String? = null
    private var ffmpegError: String? = null
    private var aria2cError: String? = null

    /** Set once init succeeds; passed to every yt-dlp invocation. */
    private var cacheDir: File? = null

    /**
     * `quickjs:/abs/path/to/libqjs.so`, or null when the binary is missing.
     *
     * THE SINGLE BIGGEST FINDING OF THIS FEATURE, and it had been hiding in
     * plain sight in our own diagnostics for weeks.
     *
     * From yt-dlp 2025.11.12 onward, YouTube extraction REQUIRES an external
     * JavaScript runtime to solve the player challenge. Without one, yt-dlp
     * prints a warning, drops every format whose URL needs descrambling, and
     * eventually reports "Sign in to confirm you're not a bot" -- which is
     * precisely the wall we spent three versions attacking from the session
     * side. The bot wall was never the disease; it was the symptom.
     *
     * youtubedl-android already ships QuickJS as `libqjs.so` (it is in the
     * nativeLibs list our own status screen prints). But yt-dlp only finds a
     * runtime automatically when the executable is literally named `qjs`, so
     * a file called `libqjs.so` is invisible to it no matter where it sits.
     * The path has to be handed over explicitly. This is the same thing
     * YTDLnis does, and it is why YTDLnis works on YouTube and we did not.
     */
    private var jsRuntime: String? = null

    /** Why no JS runtime is available, for the diagnostics report. */
    private var jsRuntimeError: String? = null

    /**
     * Set if the engine ever refuses --js-runtimes, after which we stop
     * sending it. Sibling of [clientsRejected] and there for the same reason:
     * an argument that goes on every single call is an argument that can take
     * the entire feature down if one engine build disagrees about it, and a
     * downloader that reads nothing is a worse outcome than a downloader that
     * reads YouTube badly.
     */
    private var jsRuntimeRejected = false

    /**
     * When a site last answered 429, or 0.
     *
     * A rate limit is the one failure where TRYING HARDER IS THE WRONG MOVE.
     * Our ladder is built to escalate — default clients, then alternates, then
     * fetch the challenge solver — and every rung is another burst of requests
     * at a server that has just said it is receiving too many. On a mobile
     * network where thousands of people share one address, which is the normal
     * case for the people this app is for, that is how a brief limit becomes a
     * long one.
     */
    private var rateLimitedAt = 0L

    /**
     * Set once a read fails in a way that smells of a broken IPv6 route.
     *
     * WHY THIS EXISTS: with a VPN switched on, NOTHING worked — no download
     * options for YouTube or TikTok, on a phone where both work fine without
     * one. That is not a site problem and not a rate limit; it is the shape of
     * a network that advertises IPv6 and cannot carry it. Most Android VPN
     * apps route IPv4 and either drop IPv6 or hand back addresses with no path
     * behind them, so every request tries the AAAA record first, waits, and
     * fails — for every host, which is exactly the "everything is broken"
     * report we got.
     *
     * The people this app is for use a VPN as a matter of course, so this is
     * not an edge case for them; it is Tuesday. Learned at runtime rather than
     * configured, because nobody should have to know what IPv6 is to download
     * a video, and forgotten on next launch because the network they are on
     * tomorrow is not the one they are on now.
     */
    private var forceIpv4 = false

    /** True if a site asked us to slow down within the last ten minutes. */
    private fun recentlyRateLimited(): Boolean =
        rateLimitedAt != 0L &&
            System.currentTimeMillis() - rateLimitedAt < 10 * 60 * 1000L

    /** Absolute path to libffmpeg.so, passed explicitly rather than hoped for. */
    private var ffmpegLocation: String? = null

    /**
     * The last stderr yt-dlp produced, trimmed.
     *
     * We used to pass --no-warnings on every single call, which suppressed the
     * one line that would have named this bug on day one:
     *
     *   WARNING: [youtube] No supported JavaScript runtime could be found.
     *
     * A downloader that hides the extractor's own explanation of why it failed
     * is a downloader that can only be debugged by guessing. Same lesson as
     * the cancel that never reached the log: never filter the report.
     */
    private var lastWarning: String? = null

    /**
     * Every distinct warning line seen this session, oldest first.
     *
     * [lastWarning] is deliberately left alone -- blamesJs and the unsupported
     * -client learning both want THIS run's output, not a history. But the
     * report wants the history, because a probe makes up to three runs and the
     * useful sentence is rarely the one from the last of them. Whole lines
     * only: a warning cut off mid-word is a warning nobody can act on.
     */
    private val sessionWarnings = java.util.Collections.synchronizedSet(
        linkedSetOf<String>()
    )

    /**
     * Everything needed to re-run a download.
     *
     * yt-dlp has no pause: the only way to stop it is to kill the process. What
     * makes pause/resume work anyway is that the partially written `.part` file
     * survives, and re-running the same command continues from where it stopped
     * (`--continue` is yt-dlp's default). So "pause" is kill + remember, and
     * "resume" is run the remembered command again. The same mechanism is what
     * makes a dropped connection recoverable.
     */
    private data class Job(
        val id: String,
        val url: String,
        val selector: String,
        val dir: String,
        val title: String,
        val audioOnly: Boolean,
        val toMp3: Boolean,
        val merge: Boolean,
        val cookies: String?,
        val clients: String?,
        /** Comma-separated subtitle languages, or null for none. */
        val subLangs: String? = null,
        val embedThumbnail: Boolean = false,
        val embedMetadata: Boolean = false,
        /** e.g. "1M" — yt-dlp's --limit-rate syntax. */
        val rateLimit: String? = null
    )

    private val jobs: MutableMap<String, Job> =
        Collections.synchronizedMap(LinkedHashMap<String, Job>())

    /**
     * The raw `-J` JSON from the most recent probes, keyed by URL.
     *
     * This exists to stop the site being read TWICE for one download. Without
     * it, `startDownload` hands yt-dlp the page URL again and the whole
     * extraction runs a second time — which is not merely slow: it is a second
     * chance to be refused. That is an observed failure, not a theory. A
     * TikTok link would resolve fine, show its quality list, and then fail on
     * download with "Unable to extract webpage video data", because the
     * extractor that had just succeeded was asked to do it all again a few
     * seconds later and TikTok said no the second time.
     *
     * Feeding the download the info we already hold (`--load-info-json`) skips
     * extraction entirely: faster to start, and immune to that second refusal.
     * Capped, and the file is written only when a download actually begins.
     */
    private val probeJson: MutableMap<String, String> =
        Collections.synchronizedMap(LinkedHashMap<String, String>())

    private const val MAX_PROBE_JSON = 8
    private const val MAX_JOBS = 24
    private val pausedIds: MutableSet<String> =
        Collections.synchronizedSet(LinkedHashSet<String>())

    /**
     * Set once a player-client argument is rejected by this yt-dlp build, so we
     * stop paying a wasted process spawn for it on every later link.
     */
    @Volatile
    private var clientsRejected = false

    /**
     * The title each running job was announced with.
     *
     * Kept only so a paused notification can be redrawn without inventing a
     * name for something the person is already looking at. Cleared with the
     * job, because a map that only grows is a leak with a good excuse.
     */
    private val jobTitles: MutableMap<String, String> =
        java.util.concurrent.ConcurrentHashMap()

    private val activeIds: MutableSet<String> =
        Collections.synchronizedSet(LinkedHashSet<String>())
    private val cancelledIds: MutableSet<String> =
        Collections.synchronizedSet(LinkedHashSet<String>())

    fun register(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext

        browserChannel = EventChannel(messenger, BROWSER_CHANNEL)
        browserChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                browserSink = events
            }

            override fun onCancel(arguments: Any?) {
                browserSink = null
            }
        })

        eventChannel = EventChannel(messenger, EVENT_CHANNEL)
        eventChannel?.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })

        methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
        // WAKE THE ENGINE NOW, on the readiness lane, so it happens WHILE
        // Flutter is still starting rather than after someone has asked for
        // something. See the file header on the four executors: this is the
        // lane that exists precisely so readiness never sits in front of a
        // person's read.
        //
        // Deliberately fire-and-forget. If it finishes first, the first read
        // is instant; if it does not, the read blocks on the same lock it
        // always did and has lost nothing. There is no path where this is
        // slower and no result anyone is waiting on.
        prewarm(context)

        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                // The cookies a site's CDN checks, as a ready-made header.
                //
                // yt-dlp is handed --cookies on every call, so a DOWNLOAD
                // carries the session that was used to extract the address.
                // The player fetches through our own loopback server, which
                // was sending the extractor's headers and NOTHING ELSE — no
                // cookies at all. That is the entire difference between a
                // TikTok file that downloads and the same file refusing to
                // play, and the device report shows it exactly: check 403,
                // five headers, on both the saved address and a freshly
                // resolved one.
                //
                // Reuses resolveCookies so there is ONE definition of which
                // cookies belong to which host. A second implementation of
                // that rule is a second chance to get it wrong.
                "cookieHeader" -> probeExec.execute {
                    val target = call.argument<String>("url")
                    val supplied = call.argument<String>("cookies")
                    reply(result) { result.success(cookieHeaderFor(supplied, target)) }
                }
                "ensureReady" -> statusExec.execute {
                    val ctx = appContext
                    if (ctx != null) {
                        initBlocking(ctx)
                        // After the lock is released, never inside it.
                        refreshVersion(ctx)
                    }
                    reply(result) { result.success(statusMap()) }
                }

                // Dart answering a `probeRequest` the browser sent. Replies
                // immediately: the browser is blocked on a latch, not on this.
                "browserFormats" -> {
                    val id = call.argument<Int>("reqId") ?: -1
                    @Suppress("UNCHECKED_CAST")
                    val rows = (call.argument<List<Any?>>("rows") ?: emptyList<Any?>())
                        .mapNotNull { it as? Map<String, Any?> }
                    if (id > 0) deliverBrowserFormats(id, rows)
                    reply(result) { result.success(true) }
                }

                // Off the main thread: two DNS lookups and an HTTPS round
                // trip per host. statusExec is the lane for questions about the
                // device, which is exactly what this is.
                // A settings screen, opened by name. Reports whether it
                // actually launched rather than assuming, because the private
                // DNS screen has moved between versions and a silent no-op
                // reads as a broken button.
                "openSettings" -> {
                    val action = call.argument<String>("action") ?: ""
                    val opened = try {
                        val host = activityRef?.get()
                        if (host != null && action.isNotEmpty()) {
                            host.startActivity(android.content.Intent(action))
                            true
                        } else {
                            false
                        }
                    } catch (_: Throwable) {
                        false
                    }
                    reply(result) { result.success(opened) }
                }

                // Turning the bypass on or off, and saying what it is doing.
                // Deliberately explicit rather than automatic: something that
                // changes how every connection is made should be a decision
                // somebody made, not a thing they discover.
                "dnsBypass" -> {
                    val on = call.argument<Boolean>("enabled") ?: false
                    val opened = if (on) DnsBypassProxy.start() else 0
                    if (!on) DnsBypassProxy.stop()
                    reply(result) {
                        result.success(
                            mapOf(
                                "running" to DnsBypassProxy.isRunning,
                                "port" to opened,
                                "served" to DnsBypassProxy.served,
                                "rescued" to DnsBypassProxy.rescued
                            )
                        )
                    }
                }

                "networkCheck" -> statusExec.execute {
                    val hosts = call.argument<List<String>>("hosts") ?: emptyList()
                    val answer = try {
                        networkCheck(hosts)
                    } catch (t: Throwable) {
                        mapOf("error" to (t.message ?: "network check failed"))
                    }
                    reply(result) { result.success(answer) }
                }

                // The library reads a video's length from MediaStore, which
                // comes back 0 for a file it indexed before the metadata was
                // ready — every fresh download then read "00:00". This reads the
                // real length straight off the file header for the paths the UI
                // still has at zero. Returns a path→milliseconds map (only the
                // ones it could read); the UI fills those in and caches them.
                "probeDurations" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    metaExec.execute {
                        val answer = try {
                            probeDurations(paths)
                        } catch (_: Throwable) {
                            emptyMap<String, Long>()
                        }
                        reply(result) { result.success(answer) }
                    }
                }

                "updateEngine" -> updateExec.execute { runUpdate(result) }

                "probe" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("ARGS", "url is required", null)
                    } else {
                        val cookies = call.argument<String>("cookies")
                        val clients = call.argument<String>("clients")
                        val force = call.argument<Boolean>("forceClients") ?: false
                        val flat = call.argument<Boolean>("flatPlaylist") ?: false
                        probesInFlight.incrementAndGet()
                        probeExec.execute {
                            try {
                                runProbe(url, cookies, clients, force, flat, result)
                            } finally {
                                probesInFlight.decrementAndGet()
                            }
                        }
                    }
                }

                "resolveStream" -> {
                    val url = call.argument<String>("url")
                    val selector = call.argument<String>("selector") ?: "best"
                    if (url.isNullOrBlank()) {
                        result.error("ARGS", "url is required", null)
                    } else {
                        val cookies = call.argument<String>("cookies")
                        val clients = call.argument<String>("clients")
                        probeExec.execute {
                            runResolve(url, selector, cookies, clients, result)
                        }
                    }
                }

                "startDownload" -> {
                    val id = call.argument<String>("id")
                    val url = call.argument<String>("url")
                    val selector = call.argument<String>("selector")
                    val dir = call.argument<String>("dir")
                    if (id.isNullOrBlank() || url.isNullOrBlank() ||
                        selector.isNullOrBlank() || dir.isNullOrBlank()
                    ) {
                        result.error("ARGS", "id, url, selector and dir are required", null)
                    } else {
                        val title = call.argument<String>("title") ?: ""
                        val audioOnly = call.argument<Boolean>("audioOnly") ?: false
                        val toMp3 = call.argument<Boolean>("toMp3") ?: false
                        val merge = call.argument<Boolean>("merge") ?: false
                        val cookies = call.argument<String>("cookies")
                        val clients = call.argument<String>("clients")
                        val job = Job(
                            id, url, selector, dir, title,
                            audioOnly, toMp3, merge, cookies, clients,
                            subLangs = call.argument<String>("subLangs"),
                            embedThumbnail = call.argument<Boolean>("embedThumbnail") ?: false,
                            embedMetadata = call.argument<Boolean>("embedMetadata") ?: false,
                            rateLimit = call.argument<String>("rateLimit")
                        )
                        synchronized(jobs) {
                            if (jobs.size >= MAX_JOBS && jobs.isNotEmpty()) {
                                jobs.remove(jobs.keys.first())
                            }
                            jobs[id] = job
                        }
                        pausedIds.remove(id)
                        activeIds.add(id)
                        emit(mapOf("id" to id, "phase" to "queued", "title" to title))
                        result.success(true)
                        dlExec.execute { runDownload(job) }
                    }
                }

                "cancel" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrBlank()) {
                        result.error("ARGS", "id is required", null)
                    } else {
                        cancelJob(id)
                        result.success(true)
                    }
                }

                "pause" -> {
                    val id = call.argument<String>("id")
                    if (id.isNullOrBlank()) {
                        result.error("ARGS", "id is required", null)
                    } else {
                        pauseJob(id)
                        result.success(true)
                    }
                }

                "resume" -> {
                    val id = call.argument<String>("id")
                    val job = if (id == null) null else jobs[id]
                    if (job == null) {
                        result.error("ARGS", "unknown job", null)
                    } else {
                        pausedIds.remove(job.id)
                        activeIds.add(job.id)
                        emit(mapOf("id" to job.id, "phase" to "queued", "title" to job.title))
                        result.success(true)
                        dlExec.execute { runDownload(job) }
                    }
                }

                "downloadPhotos" -> {
                    val id = call.argument<String>("id")
                    val dir = call.argument<String>("dir")
                    val raw = call.argument<List<Any?>>("urls")
                    if (id.isNullOrBlank() || dir.isNullOrBlank() || raw == null || raw.isEmpty()) {
                        result.error("ARGS", "id, dir and urls are required", null)
                    } else {
                        // Each entry is the candidate mirror list for ONE image.
                        val groups = raw.mapNotNull { entry ->
                            (entry as? List<*>)
                                ?.mapNotNull { it as? String }
                                ?.filter { it.startsWith("http") }
                                ?.takeIf { it.isNotEmpty() }
                        }
                        if (groups.isEmpty()) {
                            result.error("ARGS", "no usable urls", null)
                        } else {
                            val title = call.argument<String>("title") ?: ""
                            pausedIds.remove(id)
                            activeIds.add(id)
                            emit(mapOf("id" to id, "phase" to "queued", "title" to title))
                            result.success(true)
                            dlExec.execute { runPhotoDownload(id, groups, dir, title) }
                        }
                    }
                }

                "browse" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("ARGS", "url is required", null)
                    } else {
                        // ALL of them, forwarded as a map. The first version
                        // named two parameters and quietly dropped the other
                        // four, so four labels fell back to their English
                        // defaults on a Burmese phone — invisible in every
                        // check because nothing was missing, only unsent.
                        result.success(
                            startBrowser(
                                url,
                                call.argument<String>("title") ?: "",
                                mapOf(
                                    BrowserActivity.EXTRA_LABEL_DOWNLOAD to
                                        call.argument<String>("labelDownload"),
                                    BrowserActivity.EXTRA_LABEL_HINT to
                                        call.argument<String>("labelHint"),
                                    BrowserActivity.EXTRA_LABEL_WORKING to
                                        call.argument<String>("labelWorking"),
                                    BrowserActivity.EXTRA_LABEL_PICK to
                                        call.argument<String>("labelPick"),
                                    BrowserActivity.EXTRA_LABEL_STARTED to
                                        call.argument<String>("labelStarted"),
                                    BrowserActivity.EXTRA_LABEL_NOSOUND to
                                        call.argument<String>("labelNoSound"),
                                    BrowserActivity.EXTRA_LABEL_STREAMS to
                                        call.argument<String>("labelStreams"),
                                    BrowserActivity.EXTRA_LABEL_UNREADABLE to
                                        call.argument<String>("labelUnreadable"),
                                    BrowserActivity.EXTRA_LABEL_RETRY to
                                        call.argument<String>("labelRetry"),
                                    BrowserActivity.EXTRA_LABEL_SENDSCREEN to
                                        call.argument<String>("labelSendScreen"),
                                    // NOT A LABEL. Carried the same way because
                                    // it has the same lifetime: the browser is
                                    // launched by Dart, Dart knows the current
                                    // player-client setting, and telling it at
                                    // launch is one answer rather than two.
                                    BrowserActivity.EXTRA_CLIENTS to
                                        call.argument<String>("clients"),
                                    BrowserActivity.EXTRA_LABEL_BLOCKED to
                                        call.argument<String>("labelBlocked"),
                                    BrowserActivity.EXTRA_LABEL_VPNHINT to
                                        call.argument<String>("labelVpnHint"),
                                    BrowserActivity.EXTRA_LABEL_DNSHINT to
                                        call.argument<String>("labelDnsHint"),
                                    BrowserActivity.EXTRA_LABEL_OPENSETTINGS to
                                        call.argument<String>("labelOpenSettings"),
                                    BrowserActivity.EXTRA_LABEL_MORE to
                                        call.argument<String>("labelMore"),
                                    BrowserActivity.EXTRA_LABEL_DNSFOUND to
                                        call.argument<String>("labelDnsFound"),
                                    BrowserActivity.EXTRA_LABEL_DEEPER to
                                        call.argument<String>("labelDeeper"),
                                    BrowserActivity.EXTRA_LABEL_BYPASS to
                                        call.argument<String>("labelBypass"),
                                    BrowserActivity.EXTRA_LABEL_BYPASSHINT to
                                        call.argument<String>("labelBypassHint"),
                                    BrowserActivity.EXTRA_LABEL_VPNGONE to
                                        call.argument<String>("labelVpnGone"),
                                    BrowserActivity.EXTRA_LABEL_YTWALL to
                                        call.argument<String>("labelYtWall"),
                                    BrowserActivity.EXTRA_LABEL_YTEMBED to
                                        call.argument<String>("labelYtEmbed"),
                                    BrowserActivity.EXTRA_LABEL_YTSIGNIN to
                                        call.argument<String>("labelYtSignIn")
                                )
                            )
                        )
                    }
                }
                "signIn" -> {
                    val url = call.argument<String>("url")
                    if (url.isNullOrBlank()) {
                        result.error("ARGS", "url is required", null)
                    } else {
                        val label = call.argument<String>("label") ?: ""
                        val origins = call.argument<List<String>>("cookieUrls")
                            ?.filterNotNull()
                            ?.filter { it.startsWith("http") }
                            ?: listOf(url)
                        val auto = call.argument<Boolean>("autoClose") ?: false
                        result.success(startSignIn(url, label, origins, auto))
                    }
                }

                // Path of the cookie jar the sign-in screen writes, or null
                // when nothing has been captured yet. Polled when Innocent
                // comes back to the foreground.
                "cookieJar" -> {
                    val ctx = appContext
                    result.success(
                        if (ctx != null && CookieJar.exists(ctx)) {
                            CookieJar.file(ctx).absolutePath
                        } else {
                            null
                        }
                    )
                }

                // The no-account, no-window, no-tap session. Called before
                // anything has failed rather than after.
                "guestSession" -> {
                    val ctx = appContext
                    val url = call.argument<String>("url")
                    val origins = call.argument<List<String>>("cookieUrls")
                        ?.filterNotNull()
                        ?.filter { it.startsWith("http") }
                        ?: emptyList()
                    if (ctx == null || url.isNullOrBlank() || origins.isEmpty()) {
                        result.success(false)
                    } else {
                        GuestSessionHarvester.harvest(ctx, url, origins) { ok ->
                            reply(result) { result.success(ok) }
                        }
                    }
                }

                "clearCookieJar" -> {
                    val ctx = appContext
                    result.success(if (ctx == null) false else CookieJar.clear(ctx))
                }

                // Everything the app needs to decide whether a download should
                // start right now: is there a connection, is it the kind the
                // user is willing to spend, and is there room for the file.
                "deviceStatus" -> {
                    val dir = call.argument<String>("dir")
                    result.success(deviceStatus(dir))
                }

                // Opens this app's own notification settings. No permission
                // request, no Activity result — just the screen where it can be
                // switched back on.
                "openNotificationSettings" -> {
                    val ctx = appContext
                    var ok = false
                    if (ctx != null) {
                        ok = try {
                            val intent = Intent(
                                "android.settings.APP_NOTIFICATION_SETTINGS"
                            ).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                putExtra("android.provider.extra.APP_PACKAGE", ctx.packageName)
                            }
                            ctx.startActivity(intent)
                            true
                        } catch (_: Throwable) {
                            openExternal(null)
                        }
                    }
                    result.success(ok)
                }

                // Registers the weekly background update. Idempotent — the
                // scheduler replaces any existing job with the same id.
                "scheduleUpdates" -> {
                    val ctx = appContext
                    result.success(
                        if (ctx == null) false else EngineUpdateJobService.schedule(ctx)
                    )
                }

                // Deletes a saved file AND tells the media index about it.
                // Deleting the bytes alone leaves a ghost in the gallery that
                // plays nothing, which reads as a broken app rather than a
                // deleted file.
                "deleteFile" -> {
                    val path = call.argument<String>("path")
                    val ctx = appContext
                    var ok = false
                    if (!path.isNullOrBlank()) {
                        ok = try {
                            val file = File(path)
                            val gone = if (file.exists()) file.delete() else true
                            if (gone && ctx != null) {
                                MediaScannerConnection.scanFile(
                                    ctx, arrayOf(path), null, null
                                )
                            }
                            gone
                        } catch (_: Throwable) {
                            false
                        }
                    }
                    result.success(ok)
                }

                "openExternal" -> result.success(openExternal(call.argument<String>("url")))

                else -> result.notImplemented()
            }
        }
    }

    /**
     * Pause and cancel, callable from anywhere in the process.
     *
     * Extracted out of the channel handler because the notification's buttons
     * need exactly the same behaviour, and a second implementation of "mark
     * before killing" is a second chance to get it subtly wrong.
     */
    fun pauseJob(id: String) {
        // Mark BEFORE killing: destroyProcessById makes the running execute()
        // throw, and the catch has to be able to tell a pause from a failure.
        pausedIds.add(id)
        try {
            YoutubeDL.getInstance().destroyProcessById(id)
        } catch (_: Throwable) {
        }
        // A job still queued was never started, so nothing will throw for it.
        if (!activeIds.contains(id)) {
            emit(mapOf("id" to id, "phase" to "paused"))
        }
        // And the shade should stop offering to pause something already paused.
        appContext?.let { DownloadService.markPaused(it, jobTitles[id] ?: "Download", id) }
    }

    /**
     * Asks the Dart side to start this job again.
     *
     * ROUTED OVER THE BROWSER CHANNEL, NOT THE DOWNLOAD ONE — and that is a
     * deliberate choice rather than a convenience. The download event stream
     * turns any phase it does not recognise into `error`, so inventing a
     * `resumeRequested` phase there would mark the very job we are trying to
     * revive as failed. The browser channel already carries arbitrary shapes
     * and ignores the ones it does not know, which is exactly the property
     * this needs.
     *
     * Dart owns resuming because Dart owns the spec — the address, the
     * selector, the folder. Native has the process; it does not have the job.
     */
    fun requestResume(id: String) {
        main.post {
            try {
                browserSink?.success(mapOf("resumeRequest" to id))
            } catch (_: Throwable) {
            }
        }
    }

    fun cancelJob(id: String) {
        cancelledIds.add(id)
        jobTitles.remove(id)
        try {
            YoutubeDL.getInstance().destroyProcessById(id)
        } catch (_: Throwable) {
        }
    }

    /** Reply on the platform thread — MethodChannel.Result is not thread-safe. */
    private fun reply(result: MethodChannel.Result, block: () -> Unit) {
        main.post {
            try {
                block()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Everything the browser needs to hand a download to Dart.
     *
     * Dart owns the queue, the history, the notifications and the save
     * directory, and it stays that way: the browser contributes a URL, a
     * chosen format and a title, and Dart does what it always does with them.
     * Enqueuing from here instead would mean a second path to keep working.
     */
    /** Remembers the Activity so our own screens can stack on top of it. */
    fun attachActivity(activity: Activity) {
        activityRef = java.lang.ref.WeakReference(activity)
    }

    /** Forgets it again; the Activity must not be held past its life. */
    fun detachActivity() {
        activityRef = null
    }

    /**
     * A line from the browser for the trail, and nothing else.
     *
     * WHY: the browser's fallback to the downloads screen is SILENT. The
     * device log for six adult sites in a row shows the browser opening and
     * then a share arriving — meaning `choicesFrom` returned nothing every
     * time — with no record anywhere of whether the read came back empty, came
     * back without a formats array, or threw. Six identical mysteries and not
     * one clue. Every other puzzle in this project fell the moment the thing
     * was made to explain itself; this is the last silent path left.
     */
    fun sendBrowserNote(message: String) {
        if (message.isBlank()) return
        main.post {
            try {
                browserSink?.success(mapOf("note" to message))
            } catch (_: Throwable) {
            }
        }
    }

    fun sendBrowserPick(
        url: String,
        selector: String,
        title: String,
        merge: Boolean,
        rawFormats: Int = 0,
        offered: Int = 0,
        sourceUrl: String = ""
    ) {
        main.post {
            try {
                browserSink?.success(
                    mapOf(
                        "url" to url,
                        "selector" to selector,
                        "title" to title,
                        "merge" to merge,
                        // The same raw-versus-kept pair that settled the 360p
                        // mystery on the Dart side. A short quality list looks
                        // identical whether the site is stingy or our filter
                        // is greedy; two numbers tell them apart at a glance.
                        "rawFormats" to rawFormats,
                        "offered" to offered,
                        // The PAGE, not the media address — see
                        // DownloadSpec.sourceUrl. Without this a finished
                        // download can never be traced back to where it came
                        // from, which is the whole point of a history list.
                        "sourceUrl" to sourceUrl
                    )
                )
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * Reads a URL for the in-app browser and hands back the raw JSON.
     *
     * Runs on probeExec like every other read, for the reason the executor
     * comment gives: a read is the thing a person is watching, and it must not
     * queue behind a background chore. Called from the browser's own thread,
     * which blocks on the result — that is fine there, because the browser
     * shows a spinner and the page stays interactive.
     */
    fun probeForBrowser(url: String, clients: String? = null): String? {
        val ctx = appContext ?: return null
        if (!initBlocking(ctx)) return null
        val jar = if (CookieJar.exists(ctx)) {
            CookieJar.file(ctx).absolutePath
        } else {
            null
        }

        fun once(remoteEjs: Boolean, tiktokApi: Boolean): String? = try {
            val request = YoutubeDLRequest(url)
            baseOptions(
                request,
                url,
                jar,
                // PASSED AT LAST. This was `null`, which was harmless while the
                // browser only handed over sniffed MEDIA addresses -- a plain
                // file needs no player client. The moment v1.27.0 started
                // handing over the PAGE address for YouTube and the rest, a
                // read with no `player_client` became a read yt-dlp answers as
                // its default client, which needs a PO token, which is the bot
                // wall. The fix for YouTube in the browser is what broke it.
                clients,
                playlist = PlaylistMode.SINGLE,
                remoteEjs = remoteEjs,
                tiktokApi = tiktokApi
            )
            request.addOption("-J")
            run(request, BROWSER_PROBE_ID)
        } catch (t: Throwable) {
            lastBrowserError = t.message ?: t.toString()
            null
        }

        lastBrowserError = null
        val first = once(remoteEjs = false, tiktokApi = false)
        if (!first.isNullOrBlank()) return first

        // TIKTOK'S PAGE REFUSING ITS EMBEDDED DATA IS A NORMAL FIRST ANSWER,
        // not a failure -- the Dart ladder has answered it with the API host
        // since v1.12.0 and the browser never did, so the browser simply could
        // not read TikTok at all once it began asking for the page.
        // BLANK IS NOT AN ERROR, AND THAT IS WHY THIS NEVER RAN. The device
        // trail showed `read started · page address · www.tiktok.com` and then
        // nineteen seconds later `returned nothing (engine gave no output)` --
        // no exception, so `lastBrowserError` stayed null, so the one rung that
        // exists for exactly this site was skipped. A read that produced
        // nothing has told us nothing; on TikTok the API host is worth asking
        // regardless of HOW the first attempt declined to answer.
        if (isTikTok(url) && (lastBrowserError == null || wantsTikTokApi(lastBrowserError))) {
            val viaApi = once(remoteEjs = false, tiktokApi = true)
            if (!viaApi.isNullOrBlank()) return viaApi
        }

        // LAST, AND ONLY WHEN THE ENGINE BLAMED THE JS SIDE. Fetching the
        // challenge scripts costs a GitHub round trip that an ordinary dead
        // link cannot possibly benefit from.
        if (jsRuntime != null && blamesJs()) {
            val viaEjs = once(remoteEjs = true, tiktokApi = false)
            if (!viaEjs.isNullOrBlank()) return viaEjs
        }
        return null
    }

    /** Why the last browser read failed, so the ladder can decide what next. */
    @Volatile
    private var lastBrowserError: String? = null

    // ----------------------------------------------------- the Dart round trip
    //
    // ONE PARSER, ONE LADDER.
    //
    // The browser had grown its own reader and its own escalation, and the
    // result was exactly what the rule about two copies predicts: the same
    // YouTube video gave a full sheet when pasted and a thin, silent one when
    // found in the browser, because the Kotlin reader drops audio-only formats
    // and never pairs a video-only rendition with a soundtrack. That is not a
    // bug to fix twice; it is a second reader to stop having.
    //
    // So the browser now ASKS DART. Dart owns the ladder, the guest session,
    // the self-heal, the ffmpeg question and `probe_parser` -- everything that
    // makes the pasted sheet what it is -- and hands back rows ready to draw.
    // The Kotlin reader survives only as the answer to "Flutter is not awake
    // yet", which is a real case on a cold start and a bad reason to have
    // nothing to show.

    private val browserAsks = java.util.concurrent.atomic.AtomicInteger(0)

    /** Answers keyed by request id, filled by Dart, taken by the browser. */
    private val browserAnswers =
        java.util.concurrent.ConcurrentHashMap<Int, List<Map<String, Any?>>>()

    private val browserWaits =
        java.util.concurrent.ConcurrentHashMap<Int, java.util.concurrent.CountDownLatch>()

    /**
     * Asks the Dart side to read [url] and hand back drawable rows.
     *
     * Blocking, because the caller is the browser's own worker thread and it
     * has a spinner up. [timeoutMs] is generous: this covers a five-rung
     * ladder, a guest-session harvest and a second read, which on a slow phone
     * and a slow site is genuinely most of a minute. Returning null means "ask
     * the way we used to" -- never "give up".
     */
    fun askDartForFormats(url: String, timeoutMs: Long = 75000): List<Map<String, Any?>>? {
        val sink = browserSink ?: return null
        val id = browserAsks.incrementAndGet()
        val latch = java.util.concurrent.CountDownLatch(1)
        browserWaits[id] = latch
        main.post {
            try {
                sink.success(mapOf("probeRequest" to url, "reqId" to id))
            } catch (_: Throwable) {
                latch.countDown()
            }
        }
        return try {
            val answered = latch.await(timeoutMs, java.util.concurrent.TimeUnit.MILLISECONDS)
            val rows = browserAnswers.remove(id)
            browserWaits.remove(id)
            if (answered && rows != null && rows.isNotEmpty()) rows else null
        } catch (_: Throwable) {
            browserWaits.remove(id)
            browserAnswers.remove(id)
            null
        }
    }

    /** Dart's reply. Called on the platform thread from the method channel. */
    private fun deliverBrowserFormats(id: Int, rows: List<Map<String, Any?>>) {
        browserAnswers[id] = rows
        browserWaits.remove(id)?.countDown()
    }

    // ------------------------------------------------------ the network doctor
    //
    // WHY THIS EXISTS, AND WHY IT IS A TEST RATHER THAN ADVICE.
    //
    // This phone is caught between two opposite requirements: a router that
    // blocks the adult sites, so those need a VPN — and YouTube, which refuses
    // a VPN address because a shared exit is exactly what its bot check looks
    // for. Toggling back and forth is not a workaround, it is a tax.
    //
    // But almost every consumer and ISP block of this kind is done at the
    // RESOLVER: the name is answered with nothing, or with a lie. Android has
    // shipped encrypted DNS as a system setting since version 9, and that
    // setting removes the resolver from the equation entirely — which would
    // let the VPN stay off, and then everything works at once.
    //
    // "Would" is not good enough to tell somebody, because a router can also
    // block the encrypted port, and because some blocks are done on the
    // address instead. So this MEASURES it: ask the system resolver, ask an
    // encrypted resolver over plain HTTPS, and compare. A name that resolves
    // one way and not the other is a resolver block, and that is a fact rather
    // than a suggestion.

    /** Reads the answers a DoH resolver gives, over ordinary HTTPS. */
    private fun dohLookup(host: String): List<String> {
        var conn: java.net.HttpURLConnection? = null
        return try {
            val url = java.net.URL(
                "https://cloudflare-dns.com/dns-query?name=" +
                    java.net.URLEncoder.encode(host, "UTF-8") + "&type=A"
            )
            conn = (url.openConnection() as java.net.HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 6000
                readTimeout = 6000
                setRequestProperty("Accept", "application/dns-json")
            }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val answers = org.json.JSONObject(body).optJSONArray("Answer")
                ?: return emptyList()
            val out = ArrayList<String>()
            for (i in 0 until answers.length()) {
                val a = answers.optJSONObject(i) ?: continue
                // Type 1 is an A record. A CNAME in the chain is not an address
                // and comparing one against a resolved address proves nothing.
                if (a.optInt("type", 0) != 1) continue
                val data = a.optString("data", "")
                if (data.isNotEmpty()) out.add(data)
            }
            out
        } catch (_: Throwable) {
            emptyList()
        } finally {
            try {
                conn?.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /**
     * True for an address a public site can never legitimately live at.
     *
     * THE SIGNATURE OF A SINKHOLE, and the device trail is full of it. A
     * resolver that wants to block a name does not usually refuse to answer —
     * it answers with somewhere that goes nowhere: the loopback, the
     * unspecified address, or a private range. The phone then connects,
     * instantly gets nothing, and the browser reports ERR_CONNECTION_REFUSED,
     * which reads like the far end refusing rather than the name being
     * poisoned. Four adult sites in one session, all with that error, on a
     * connection where YouTube was working perfectly.
     */
    private fun nonRoutable(ip: String): Boolean {
        val a = ip.trim()
        if (a == "0.0.0.0" || a == "::" || a == "::1") return true
        if (a.startsWith("127.")) return true
        if (a.startsWith("10.")) return true
        if (a.startsWith("192.168.")) return true
        if (a.startsWith("169.254.")) return true
        val parts = a.split(".")
        if (parts.size == 4 && parts[0] == "172") {
            val second = parts[1].toIntOrNull() ?: return false
            if (second in 16..31) return true
        }
        return false
    }

    /** The three the proxy needs — shared, never duplicated. */
    fun systemAddresses(host: String): List<String> = systemLookup(host)

    fun dohAddresses(host: String): List<String> = dohLookup(host)

    fun isNonRoutable(ip: String): Boolean = nonRoutable(ip)

    /**
     * Can we actually REACH this site once we know where it is?
     *
     * THE QUESTION THAT DECIDES WHETHER THE BYPASS IS WORTH OFFERING. A
     * poisoned name is only half a diagnosis: if the router ALSO rejects the
     * connection once it sees which site is being asked for — which it can, by
     * reading the name out of the TLS greeting — then resolving the name
     * ourselves changes nothing and a VPN really is the only way in.
     *
     * So this opens a real connection to the address the encrypted resolver
     * gave, announces the real hostname the way any browser would, and waits
     * for the handshake. Completing it proves the route is open and the block
     * was only ever the answer to a question. Being cut off proves the
     * opposite. Either way it is measured rather than hoped for, and the
     * person is told which.
     */
    fun tlsReachable(host: String, ip: String): Boolean {
        var socket: javax.net.ssl.SSLSocket? = null
        return try {
            val plain = java.net.Socket()
            plain.connect(java.net.InetSocketAddress(ip, 443), 6000)
            val factory = javax.net.ssl.SSLSocketFactory.getDefault()
                as javax.net.ssl.SSLSocketFactory
            socket = factory.createSocket(plain, ip, 443, true) as javax.net.ssl.SSLSocket
            socket.soTimeout = 6000
            // THE NAME MUST TRAVEL WITH THE HANDSHAKE. Without it the far end
            // has no idea which of the thousand sites on that address is
            // wanted, and a router doing name-based blocking would have
            // nothing to object to — so a test without this would pass on a
            // network where the real thing fails.
            val params = socket.sslParameters
            params.serverNames = listOf(javax.net.ssl.SNIHostName(host))
            socket.sslParameters = params
            socket.startHandshake()
            true
        } catch (_: Throwable) {
            false
        } finally {
            try {
                socket?.close()
            } catch (_: Throwable) {
            }
        }
    }

    /** What the phone's own resolver says. */
    private fun systemLookup(host: String): List<String> = try {
        java.net.InetAddress.getAllByName(host).mapNotNull { it.hostAddress }
    } catch (_: Throwable) {
        emptyList()
    }

    /**
     * Is encrypted DNS already switched on, and to what?
     *
     * Read from the live connection rather than from the setting, because the
     * setting can say `opportunistic` while the network silently refuses it —
     * and what matters is whether it is actually in force right now.
     */
    private fun privateDnsState(ctx: Context): Pair<String, String?> {
        try {
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? android.net.ConnectivityManager
                val net = cm?.activeNetwork
                val lp = if (net != null) cm.getLinkProperties(net) else null
                if (lp != null) {
                    val name = lp.privateDnsServerName
                    if (lp.isPrivateDnsActive) {
                        return Pair(if (name.isNullOrBlank()) "on" else "on", name)
                    }
                    return Pair("off", null)
                }
            }
        } catch (_: Throwable) {
        }
        return Pair("unknown", null)
    }

    /**
     * Asks both resolvers about each host and says which are being blocked.
     *
     * Verdicts, deliberately few and deliberately honest:
     *   • `ok`        — both resolvers agree the name exists.
     *   • `dns`       — the encrypted resolver has an address and the system
     *                   one does not, or hands back a completely different set.
     *                   That is a resolver block, and Private DNS removes it.
     *   • `deeper`    — both resolve identically, so any block is happening
     *                   further along than the name. A VPN is the answer there
     *                   and saying otherwise would waste somebody's evening.
     *   • `unknown`   — the encrypted resolver could not be reached either, so
     *                   there is nothing to compare against. Never guess here.
     */
    /**
     * The last answer this device gave, whoever asked for it.
     *
     * KEPT HERE SO THERE IS ONE SOURCE. The browser runs its own check on a
     * page that will not load and the downloads screen runs one on a failed
     * read; without this the report would show `dns unknown` while a perfectly
     * good measurement sat in whichever half of the app happened to take it —
     * which is exactly what the device trail showed.
     */
    @Volatile
    var lastNetworkAnswer: Map<String, Any?>? = null
        private set

    fun networkCheck(hosts: List<String>): Map<String, Any?> {
        val ctx = appContext ?: return mapOf("error" to "no context")
        val dns = privateDnsState(ctx)
        val rows = ArrayList<Map<String, Any?>>()
        for (host in hosts.take(6)) {
            val doh = dohLookup(host)
            val sys = systemLookup(host)
            val verdict = when {
                doh.isEmpty() -> "unknown"
                sys.isEmpty() -> "dns"
                sys.any { doh.contains(it) } -> "ok"
                // A NAME POISONED RATHER THAN REFUSED. Named separately from
                // the general disagreement because it is the most confident
                // diagnosis available: a public site does not live on the
                // loopback, so an answer that says it does can only have come
                // from something rewriting the reply.
                sys.all { nonRoutable(it) } -> "sinkhole"
                // DISJOINT BUT BOTH REAL IS NOT EVIDENCE OF ANYTHING, and
                // calling it one was wrong. The device trail proved it: this
                // check reported `youtube.com=dns` on a network where YouTube
                // was demonstrably reachable, because a site of that size is
                // served from enormous anycast pools and two resolvers in two
                // different places routinely hand back completely different
                // addresses for it. The very next host in the same check,
                // `www.youtube.com`, came back `ok` — same site, same second.
                //
                // So a disagreement between two public answers is reported as
                // a disagreement and nothing more. What remains as EVIDENCE is
                // the pair that cannot be innocent: an address that goes
                // nowhere, and a name the system cannot resolve at all while
                // an encrypted resolver can.
                else -> "differs"
            }
            // ONLY WORTH THE SECONDS WHEN THE ANSWER CHANGES SOMETHING.
            // A name that resolves normally has nothing to bypass, and a name
            // nobody could resolve has nowhere to try.
            val bypassable = if (verdict == "sinkhole" || verdict == "dns") {
                doh.firstOrNull()?.let { tlsReachable(host, it) } ?: false
            } else {
                false
            }
            rows.add(
                mapOf(
                    "host" to host,
                    "verdict" to verdict,
                    "bypassable" to bypassable,
                    "system" to sys.take(3),
                    "doh" to doh.take(3)
                )
            )
        }
        val answer = mapOf(
            "privateDns" to dns.first,
            "privateDnsHost" to dns.second,
            "hosts" to rows
        )
        lastNetworkAnswer = answer
        return answer
    }

    /** A one-word summary of the last measurement, for the report. */
    private fun lastDnsVerdict(): String? {
        @Suppress("UNCHECKED_CAST")
        val rows = lastNetworkAnswer?.get("hosts") as? List<Map<String, Any?>>
            ?: return null
        if (rows.isEmpty()) return null
        val verdicts = rows.mapNotNull { it["verdict"] as? String }
        return when {
            verdicts.contains("sinkhole") || verdicts.contains("dns") -> {
                @Suppress("UNCHECKED_CAST")
                val any = rows.any { it["bypassable"] == true }
                val what = if (verdicts.contains("sinkhole")) {
                    "NAME POISONED"
                } else {
                    "NAME BLOCKED"
                }
                what + " on this network" +
                    (if (any) " · bypassable without a VPN" else " · route also blocked")
            }
            verdicts.all { it == "unknown" } -> "check inconclusive"
            // Said out loud rather than folded into "normally", because a
            // reader who sees only the summary should still know the two
            // resolvers disagreed — it is just not, on its own, a block.
            verdicts.contains("differs") -> "names resolve, resolvers disagree"
            else -> "names resolve normally"
        }
    }

    /**
     * Stops a browser read that the person walked away from.
     *
     * BOTH KINDS OF WAITING END HERE. Killing the extractor process was never
     * the whole job once the browser started asking Dart: a thread blocked on
     * a latch would sit there for the full seventy-five seconds after the
     * screen had gone, holding a reference to a dead Activity for no reason
     * anyone could observe. Releasing the latches makes closing the browser
     * mean closing the browser.
     */
    fun cancelBrowserProbe() {
        try {
            YoutubeDL.getInstance().destroyProcessById(BROWSER_PROBE_ID)
        } catch (_: Throwable) {
        }
        try {
            val waiting = browserWaits.keys.toList()
            for (id in waiting) {
                browserWaits.remove(id)?.countDown()
                browserAnswers.remove(id)
            }
        } catch (_: Throwable) {
        }
    }

    private fun emit(payload: Map<String, Any?>) {
        main.post {
            try {
                sink?.success(payload)
            } catch (_: Throwable) {
            }
        }
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "ok" to initOk,
        "version" to ytdlpVersion,
        "error" to initError,
        "ffmpeg" to (ffmpegError == null),
        "ffmpegError" to ffmpegError,
        "aria2c" to (aria2cError == null),
        "aria2cError" to aria2cError,
        "active" to activeIds.size,
        // Ground truth for "is the merger actually missing, or did we just fail
        // to find its class?". If libffmpeg is listed here but ffmpeg is off,
        // the module shipped fine and the fault is ours, not the build's — and
        // that is a completely different thing to go and fix.
        "nativeLibs" to nativeLibNames(),
        "cookieHosts" to cookieHosts(),
        // Named, not just present/absent. "js ok" versus "js MISSING" is the
        // single most useful line this report can carry now, because a missing
        // runtime looks exactly like a site being difficult.
        "jsRuntime" to (jsRuntime != null),
        "jsRuntimeError" to jsRuntimeError,
        // The history, not just the last line — see [sessionWarnings].
        "lastWarning" to synchronized(sessionWarnings) {
            if (sessionWarnings.isEmpty()) lastWarning
            else sessionWarnings.joinToString("\n")
        },
        "deadClients" to synchronized(unsupportedClients) {
            unsupportedClients.joinToString(",")
        }
    )

    private fun nativeLibNames(): List<String> = try {
        val dir = appContext?.applicationInfo?.nativeLibraryDir
        if (dir == null) emptyList()
        else File(dir).listFiles()
            ?.map { it.name }
            ?.filter { it.startsWith("lib") }
            ?.sorted()
            ?: emptyList()
    } catch (_: Throwable) {
        emptyList()
    }

    @Synchronized
    private fun initBlocking(ctx: Context): Boolean {
        if (initTried) return initOk
        initTried = true
        try {
            YoutubeDL.getInstance().init(ctx)
            initOk = true
            initError = null
        } catch (t: Throwable) {
            initOk = false
            initError = t.message ?: t.toString()
            return false
        }
        cacheDir = try {
            File(ctx.cacheDir, "yt-dlp").apply { if (!exists()) mkdirs() }
        } catch (_: Throwable) {
            null
        }
        // Widened after a report of only one quality being offered: if the
        // merger never initialises, every resolution that arrives as separate
        // video and audio is unusable and the sheet collapses to whatever
        // single combined stream the site happens to publish.
        ffmpegError = initOptional(
            listOf(
                "com.yausername.ffmpeg.FFmpeg",
                "com.yausername.youtubedl_android.FFmpeg",
                "io.github.junkfood02.youtubedl_android.ffmpeg.FFmpeg",
                "com.junkfood.ffmpeg.FFmpeg",
                "com.yausername.ffmpeg.FFmpegKt"
            ),
            ctx
        )
        aria2cError = initOptional(
            listOf(
                "com.yausername.aria2c.Aria2c",
                "com.yausername.youtubedl_android.Aria2c",
                "io.github.junkfood02.youtubedl_android.aria2c.Aria2c",
                "com.junkfood.aria2c.Aria2c"
            ),
            ctx
        )
        locateNativeTools(ctx)
        return true
    }

    /**
     * Starts unpacking the engine before anyone asks for it.
     *
     * Costs nothing when it is not needed: initBlocking returns immediately
     * once initialisation has happened, and the version read is skipped when
     * one is already known. Swallows everything, because a warm-up that can
     * crash the app is worse than a cold start.
     */
    /**
     * Brings the bypass back before anything asks a question of the network.
     *
     * ON THE LAUNCH PATH ON PURPOSE. If this waited for a page to fail, every
     * cold start would begin with a blocked site and a rediscovery — which is
     * precisely the fuss the person asked to be rid of. Costs one preferences
     * read when it is off, and nothing at all afterwards.
     */
    private fun restoreNetworkChoices(ctx: Context) {
        try {
            DnsBypassProxy.restore(ctx)
        } catch (_: Throwable) {
        }
    }

    private fun prewarm(ctx: Context) {
        // The bypass first, and OUTSIDE the executor: everything below is
        // about the engine, and the network choice has to be in place before
        // the first read rather than racing it.
        restoreNetworkChoices(ctx)
        try {
            statusExec.execute {
                try {
                    initBlocking(ctx)
                    if (ytdlpVersion == null) refreshVersion(ctx)
                } catch (_: Throwable) {
                    // Reported properly when something actually asks.
                }
            }
        } catch (_: Throwable) {
            // A rejected execution is not worth a crash at startup.
        }
    }

    /**
     * Finds the QuickJS and ffmpeg binaries inside the extracted native lib
     * directory and remembers their absolute paths.
     *
     * These are real command-line executables that happen to be named lib*.so
     * so the installer will unpack them (which is also why this module needs
     * `useLegacyPackaging = true` -- see the gradle comment). Because their
     * names are not what the tools they serve expect to find, nothing
     * auto-detects them; every path has to be passed explicitly.
     */
    private fun locateNativeTools(ctx: Context) {
        val dir = try {
            ctx.applicationInfo?.nativeLibraryDir
        } catch (_: Throwable) {
            null
        }
        if (dir == null) {
            jsRuntimeError = "no native library dir"
            return
        }
        val qjs = File(dir, "libqjs.so")
        if (qjs.exists()) {
            // "quickjs:<path>" -- the prefix names the runtime FAMILY and the
            // path points at the executable, which is required here precisely
            // because the file is not called `qjs`.
            jsRuntime = "quickjs:" + qjs.absolutePath
            jsRuntimeError = null
        } else {
            jsRuntime = null
            jsRuntimeError = "libqjs.so not in " + dir
        }
        val ff = File(dir, "libffmpeg.so")
        ffmpegLocation = if (ff.exists()) ff.absolutePath else null
    }

    /**
     * Reads the version OUTSIDE the init lock.
     *
     * This used to be the last statement of [initBlocking], inside the
     * @Synchronized block — and that is why moving readiness checks onto their
     * own thread changed nothing at all. Reading the version spawns a Python
     * process and takes seconds, and a probe calling initBlocking waited on
     * the same monitor for every one of them. Two threads sharing a lock are
     * not two lanes.
     *
     * Nothing needs the version in order to extract anything, so it is no
     * longer in the path of the one thing a person is waiting for.
     */
    private fun refreshVersion(ctx: Context) {
        if (!initOk) return
        ytdlpVersion = readVersion(ctx)
    }

    /**
     * Calls `X.getInstance().init(context)` on the first of [candidates] that
     * exists. Returns null on success or a reason on failure. The `init` method
     * is located by name+arity rather than exact parameter type so a declared
     * Application/Context difference can't break it.
     */
    private fun initOptional(candidates: List<String>, ctx: Context): String? {
        var lastError: String? = null
        for (name in candidates) {
            val cls = try {
                Class.forName(name)
            } catch (_: Throwable) {
                lastError = "class not found"
                continue
            }
            try {
                val instance = cls.getMethod("getInstance").invoke(null)
                val initMethod = cls.methods.firstOrNull {
                    it.name == "init" && it.parameterTypes.size == 1
                } ?: return "no single-argument init()"
                initMethod.invoke(instance, ctx)
                return null
            } catch (t: Throwable) {
                lastError = t.cause?.message ?: t.message ?: t.toString()
            }
        }
        return lastError ?: "unavailable"
    }

    /**
     * Version string. Prefers the library's own `versionName(context)` when it
     * exists (cheap) and falls back to running `--version` (a process spawn).
     */
    private fun readVersion(ctx: Context): String? {
        try {
            val instance = YoutubeDL.getInstance()
            val method = instance.javaClass.methods.firstOrNull {
                (it.name == "versionName" || it.name == "version") &&
                    it.parameterTypes.size == 1
            }
            val value = method?.invoke(instance, ctx) as? String
            if (!value.isNullOrBlank()) return value.trim()
        } catch (_: Throwable) {
        }
        return try {
            val request = YoutubeDLRequest(listOf<String>())
            request.addOption("--version")
            run(request, "innocent-version").trim().ifEmpty { null }
        } catch (_: Throwable) {
            null
        }
    }

    /**
     * Downloads a newer yt-dlp binary over the bundled one.
     *
     * This is the ONLY real answer to YouTube's "Sign in to confirm you're not
     * a bot" wall: the check is a moving target, the fix ships in yt-dlp within
     * days, and the copy bundled inside the library is frozen at whatever was
     * current when the library was released. Updating swaps in a current
     * extractor without rebuilding or reinstalling Innocent.
     *
     * Done reflectively because UpdateChannel is a nested/open class whose
     * exact shape isn't pinned by the docs: find the two-argument
     * updateYoutubeDL, read the STABLE constant off whatever type its second
     * parameter is, and call it.
     */
    private fun runUpdate(result: MethodChannel.Result) {
        val ctx = appContext
        if (ctx == null || !initBlocking(ctx)) {
            reply(result) {
                result.success(
                    mapOf("ok" to false, "error" to (initError ?: "engine unavailable"))
                )
            }
            return
        }

        // Never replace the binary while a link is being READ — but waiting is
        // the right response, not giving up. Bailing out meant that on a phone
        // where something was usually in flight the engine simply never
        // updated, which is how an eight-month-old extractor survived for
        // weeks. Wait up to half a minute, then proceed anyway.
        var waited = 0L
        while (probesInFlight.get() > 0 && waited < UPDATE_WAIT_MS) {
            try {
                Thread.sleep(500L)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
            waited += 500L
        }
        if (probesInFlight.get() > 0) {
            reply(result) {
                result.success(
                    mapOf("ok" to false, "error" to "busy reading a link", "deferred" to true)
                )
            }
            return
        }

        val before = ytdlpVersion
        // Every step is recorded. When this fails on a user's phone the only
        // thing we get back is a screenshot, so the message has to say which
        // step broke — "update failed" on its own is unactionable.
        val trace = StringBuilder()
        try {
            val instance = YoutubeDL.getInstance()
            val overloads = instance.javaClass.methods
                .filter { it.name == "updateYoutubeDL" }
                .sortedBy { it.parameterTypes.size }
            if (overloads.isEmpty()) {
                throw IllegalStateException(
                    "updateYoutubeDL missing on " + instance.javaClass.name
                )
            }
            trace.append("overloads=").append(overloads.size).append("; ")

            var status: Any? = null
            var lastError: Throwable? = null
            // The reported failure was "unexpected end of stream on
            // com.android.okhttp.Address" — the library's own updater losing a
            // pooled connection partway through, not anything about the call
            // itself (the reflection found and invoked the method fine). That
            // is the classic keep-alive reset, and it usually succeeds on a
            // second try, so the whole invocation is retried rather than
            // reported after one attempt.
            for (round in 1..UPDATE_ATTEMPTS) {
            if (status != null) break
            if (round > 1) {
                trace.append("retry ").append(round).append("; ")
                try {
                    Thread.sleep(1500L * (round - 1))
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
            for (method in overloads) {
                try {
                    status = when (method.parameterTypes.size) {
                        // Preferred: the one-argument form uses the library's
                        // own default channel, so nothing has to be guessed
                        // about the UpdateChannel type at all.
                        1 -> method.invoke(instance, ctx)
                        2 -> method.invoke(instance, ctx, resolveChannel(method.parameterTypes[1]))
                        else -> continue
                    }
                    trace.append("used ").append(method.parameterTypes.size).append("-arg; ")
                    break
                } catch (t: Throwable) {
                    val cause = t.cause ?: t
                    lastError = cause
                    trace.append(method.parameterTypes.size).append("-arg failed: ")
                        .append(cause.javaClass.simpleName).append(": ")
                        .append(cause.message ?: "").append("; ")
                }
            }
            }
            if (status == null && lastError != null) throw lastError

            refreshVersion(ctx)
            reply(result) {
                result.success(
                    mapOf(
                        "ok" to true,
                        "status" to (status?.toString() ?: "DONE"),
                        "before" to before,
                        "version" to ytdlpVersion,
                        "detail" to trace.toString()
                    )
                )
            }
        } catch (t: Throwable) {
            val cause = t.cause ?: t
            val message = cause.message ?: cause.toString()
            reply(result) {
                result.success(
                    mapOf(
                        "ok" to false,
                        "error" to message,
                        "before" to before,
                        "detail" to trace.toString()
                    )
                )
            }
        }
    }

    /**
     * Updates the engine from a background job.
     *
     * The scheduled weekly job can run in a process started for it alone, so
     * this takes its own context and returns a plain boolean rather than
     * replying over a channel that may not exist.
     */
    fun updateInBackground(ctx: Context): Boolean {
        return try {
            if (!initBlocking(ctx)) return false
            val instance = YoutubeDL.getInstance()
            val method = instance.javaClass.methods
                .filter { it.name == "updateYoutubeDL" }
                .minByOrNull { it.parameterTypes.size } ?: return false
            when (method.parameterTypes.size) {
                1 -> method.invoke(instance, ctx)
                2 -> method.invoke(instance, ctx, resolveChannel(method.parameterTypes[1]))
                else -> return false
            }
            refreshVersion(ctx)
            true
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Finds the STABLE constant of whatever type the updater's second argument
     * is. Kotlin can express that constant in at least four different ways
     * depending on how the library declares UpdateChannel, and which one is in
     * use is not something the public docs pin down, so all four are tried.
     */
    private fun resolveChannel(type: Class<*>): Any? {
        // 1. A plain static field: `@JvmField val STABLE`.
        try {
            type.fields.firstOrNull { it.name.equals("STABLE", ignoreCase = true) }
                ?.let { return it.get(null) }
        } catch (_: Throwable) {
        }
        // 2. An enum constant.
        try {
            type.enumConstants?.firstOrNull {
                it.toString().contains("STABLE", ignoreCase = true)
            }?.let { return it }
        } catch (_: Throwable) {
        }
        // 3. A nested `object STABLE`, which compiles to its own class with a
        //    static INSTANCE.
        try {
            return Class.forName(type.name + "\$STABLE")
                .getField("INSTANCE").get(null)
        } catch (_: Throwable) {
        }
        // 4. A companion-object property, reached through its getter.
        try {
            val companion = type.getField("Companion").get(null)
            companion?.javaClass?.methods
                ?.firstOrNull { it.name == "getSTABLE" && it.parameterTypes.isEmpty() }
                ?.let { return it.invoke(companion) }
        } catch (_: Throwable) {
        }
        // 5. Anything static of the right type — better than handing over null.
        try {
            type.fields.firstOrNull { type.isAssignableFrom(it.type) }
                ?.let { return it.get(null) }
        } catch (_: Throwable) {
        }
        return null
    }

    /**
     * Runs a request and returns stdout. Always uses the documented
     * three-argument form so it never depends on default-argument overloads.
     */
    private fun run(
        request: YoutubeDLRequest,
        processId: String,
        onLine: ((Float, Long, String) -> Unit)? = null
    ): String {
        val response = YoutubeDL.getInstance().execute(request, processId) { p, eta, line ->
            onLine?.invoke(p, eta, line)
        }
        noteWarning(response)
        learnUnsupported(lastWarning)
        collectWarnings(lastWarning)
        return response.out
    }

    /**
     * Keeps the most recent stderr so the diagnostics report can show it.
     *
     * Read reflectively for the same reason the optional modules are: the
     * accessor's exact name on YoutubeDLResponse is not something we should
     * turn into a compile error if the library renames it.
     */
    private fun noteWarning(response: Any?) {
        if (response == null) return
        val text = try {
            val m = response.javaClass.methods.firstOrNull {
                (it.name == "getErr" || it.name == "getErrorMessage") &&
                    it.parameterTypes.isEmpty()
            }
            m?.invoke(response) as? String
        } catch (_: Throwable) {
            null
        } ?: return
        val trimmed = text.trim()
        lastWarning = if (trimmed.isEmpty()) {
            null
        } else if (trimmed.length > 400) {
            trimmed.takeLast(400)
        } else {
            trimmed
        }
    }

    /**
     * Options every invocation gets.
     *
     * [clients] is the YouTube player-client list, used ONLY on a retry: an
     * unknown client name can make some yt-dlp versions hard-fail, so the first
     * attempt stays on the default. It is surfaced as an editable setting so it
     * can be adapted when YouTube shifts again, without a new build.
     */
    /** How a link that names a collection should be treated. */
    private enum class PlaylistMode {
        /** One video, even if the link carries a list. The old behaviour. */
        SINGLE,

        /** List the entries without resolving each one — fast, for the picker. */
        FLAT,

        /** Resolve this entry properly (a single item chosen from a list). */
        ITEM
    }

    private fun baseOptions(
        request: YoutubeDLRequest,
        url: String?,
        cookies: String?,
        clients: String?,
        retries: Int = 2,
        playlist: PlaylistMode = PlaylistMode.SINGLE,
        remoteEjs: Boolean = false,
        tiktokApi: Boolean = false
    ) {
        // --no-warnings USED TO BE HERE and it cost this project weeks.
        //
        // yt-dlp writes warnings to stderr and its JSON to stdout, so keeping
        // warnings on cannot corrupt anything we parse -- the library hands
        // back the two streams separately. What it buys is the extractor
        // telling us, in its own words, why it produced what it produced. The
        // missing JS runtime announced itself in a warning on every single
        // YouTube read we ever made, and we were throwing it away unread.
        when (playlist) {
            // Deliberately exclusive: --no-playlist and --yes-playlist are
            // different option keys, and passing both would leave which one
            // wins up to argument order.
            PlaylistMode.SINGLE -> request.addOption("--no-playlist")
            PlaylistMode.FLAT -> {
                request.addOption("--yes-playlist")
                // Titles and ids only. Resolving fifty videos to show a list
                // the user may close is minutes of work for nothing.
                request.addOption("--flat-playlist")
            }
            PlaylistMode.ITEM -> request.addOption("--no-playlist")
        }
        request.addOption("--no-colors")
        // 25s, raised from 15. A VPN adds a hop and often a slow one, and a
        // timeout tuned for a direct connection turns a working-but-slow link
        // into a failure with no explanation.
        request.addOption("--socket-timeout", "25")

        // See [forceIpv4]. Costs nothing on a healthy network: every site this
        // app touches is reachable over IPv4.
        if (forceIpv4) request.addOption("--force-ipv4")
        // Reading a link should fail fast so the user can act; a download in
        // flight should fight for it, because giving up on a flaky connection
        // means starting the transfer over.
        request.addOption("--retries", retries.toString())
        request.addOption("--geo-bypass")
        // THROUGH OUR OWN RESOLVER, WHEN ONE IS RUNNING. yt-dlp has no way to
        // be told where a name really is, but it has always been able to be
        // told where to send the request — so the proxy that already knows
        // becomes the answer for the reader as well as for the browser. One
        // mechanism, both halves of the app, and it costs a single argument.
        if (DnsBypassProxy.isRunning) {
            request.addOption("--proxy", "http://127.0.0.1:" + DnsBypassProxy.port)
        }

        // POLITE ONLY WHEN ASKED. A pause between the extractor's own requests
        // is exactly what a rate limit is asking for, but it is dead time on
        // every ordinary read, so it is switched on by evidence and expires by
        // itself rather than being a permanent tax paid for a rare problem.
        if (recentlyRateLimited()) {
            request.addOption("--sleep-requests", "1")
        }
        cacheDir?.let { request.addOption("--cache-dir", it.absolutePath) }

        // THE JS RUNTIME. Without this argument YouTube cannot be extracted at
        // all on a current engine: the challenge goes unsolved, the formats
        // that need a descrambled URL are dropped, and what survives is either
        // nothing or a single progressive rendition -- which is exactly the
        // "one 360p row" and the "reading link forever" we have been chasing.
        //
        // Passed on EVERY call, not just YouTube ones, because the extractors
        // that need it are yt-dlp's business and the argument is free when
        // unused. It costs no network and no process.
        if (!jsRuntimeRejected) {
            jsRuntime?.let { request.addOption("--js-runtimes", it) }
        }

        // The muxer, named explicitly rather than left to be discovered. The
        // reflective FFmpeg.init() call registers the module with the library,
        // but yt-dlp itself is a separate process that only knows what it is
        // told on the command line.
        ffmpegLocation?.let { request.addOption("--ffmpeg-location", it) }

        // The challenge SOLVER SCRIPTS, fetched from yt-dlp's own repository.
        //
        // Off by default and used only as an escalation: the scripts ship
        // inside the official yt-dlp distributions, so in the normal case this
        // would be a pointless network round trip on a phone that may be on
        // mobile data. But if the copy of yt-dlp we happen to be running does
        // NOT carry them -- a real possibility given ours is whatever the
        // library bundled plus whatever self-update fetched -- then this is
        // the difference between working and not, and it repairs itself with
        // no APK and nothing for the user to do.
        if (remoteEjs) {
            request.addOption("--remote-components", "ejs:github")
        }

        // TIKTOK'S APP API INSTEAD OF ITS WEB PAGE.
        //
        // Used only after the ordinary path has already failed with "Unable to
        // extract universal data for rehydration" — TikTok's web page refusing
        // to give up its embedded data, which the device trail shows happening
        // on the FIRST read every single time, costing about thirteen seconds
        // before a retry quietly succeeds.
        //
        // This host is not a guess: it is the one this app's own photo
        // extractor already talks to on this device, and the trail records it
        // answering 200. Gated behind a failure so a working read never pays
        // for it, and so a hostname that goes stale costs one wasted attempt
        // rather than breaking TikTok outright.
        if (tiktokApi) {
            request.addOption(
                "--extractor-args",
                "tiktok:api_hostname=api22-normal-c-useast2a.tiktokv.com"
            )
        }
        // Cookies are filtered to the site being asked about, and resolved
        // HERE rather than being handed in ready-made.
        //
        // Both halves of that mattered, and together they were the whole of
        // the strangest symptom in this project: YouTube worked when pasted
        // but not when shared, while TikTok worked when shared but not when
        // pasted — exact opposites, from one cause.
        //
        // The Dart side read the cookie path from a preference that loads
        // asynchronously, so a link read the instant the screen opened (a
        // share) got NO cookies, and one read a few seconds later (a paste)
        // got them. And the file it got was the WHOLE jar, sent to every site
        // — so TikTok was being handed a YouTube session it never asked for.
        // YouTube needs one and failed without it; TikTok is derailed by one
        // and hung with it. Same asymmetry, opposite signs.
        //
        // Resolving it natively removes the race (there is nothing to load)
        // and the contamination (a site only ever sees its own cookies), and
        // makes sharing and pasting identical by construction rather than by
        // luck.
        resolveCookies(cookies, url)?.let {
            request.addOption("--cookies", it.absolutePath)
        }

        // PRESENT THE SAME BROWSER THAT EARNED THE PASS.
        //
        // A clearance cookie is issued to one user agent and checked against
        // whoever presents it later. Our in-app browser saves the agent it was
        // using when it collected a site's cookies; sending both together is
        // the difference between a session that works and a 403 that looks
        // like the cookies were never there. Only for hosts we have actually
        // browsed — everywhere else the engine's own default is correct.
        savedUserAgent(url)?.let { request.addOption("--user-agent", it) }

        // AND THE PAGE IT CAME FROM.
        //
        // A media CDN generally serves a file only to a request that says
        // which page asked for it. The device notification caught this
        // precisely: a playlist fetched from a sniffed address downloaded
        // fine, then every segment answered 404 — because the playlist itself
        // was allowed and the segments were not. Passing the page as the
        // referer is what makes those segments legal.
        savedReferer(url)?.let { request.addOption("--referer", it) }
        if (!clients.isNullOrBlank()) {
            usableClients(clients)?.let {
                // Filtered, not sent raw: a name the engine has already
                // rejected once is dead weight that only shortens the list
                // of clients that might have worked.
                request.addOption("--extractor-args", "youtube:player_client=$it")
            }
        }
    }

    /**
     * A cookie file containing ONLY the cookies that belong to [url]'s host,
     * or null when there are none — in which case no --cookies argument is
     * passed at all, which is not the same as passing an empty file.
     *
     * Netscape domain rules: a leading dot means "this host and anything under
     * it"; without one it must match exactly.
     */
    /**
     * The host's cookies as a single `name=value; name=value` header value.
     *
     * Netscape format is seven tab-separated fields; the name and value are
     * the last two. Anything shorter is a malformed line and is skipped
     * rather than guessed at.
     */
    /**
     * The user agent our own browser used on this host, if it has been there.
     *
     * Written by BrowserActivity next to the cookies it harvested. Read fresh
     * each time rather than cached: a person can browse a site at any moment,
     * and a cached "no" would outlive the visit that fixed it.
     */
    /** The page our browser was on when it handed this host over. */
    private fun savedReferer(url: String?): String? = readSiteFile("site_referer", url)

    private fun savedUserAgent(url: String?): String? = readSiteFile("site_ua", url)

    /**
     * Reads `filesDir/<dir>/<host>.txt`, or null.
     *
     * Shared by the agent and the referer because they are the same lookup and
     * two copies of it would drift. Read fresh every time rather than cached:
     * a person can browse a site at any moment, and a cached "nothing here"
     * would outlive the visit that fixed it.
     */
    private fun readSiteFile(dir: String, url: String?): String? {
        val ctx = appContext ?: return null
        val host = try {
            android.net.Uri.parse(url ?: return null).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return null
        return try {
            val f = java.io.File(java.io.File(ctx.filesDir, dir), "$host.txt")
            if (!f.exists()) return null
            val v = f.readText().trim()
            if (v.isEmpty()) null else v
        } catch (_: Throwable) {
            null
        }
    }

    private fun cookieHeaderFor(supplied: String?, url: String?): String? {
        val file = resolveCookies(supplied, url) ?: return null
        return try {
            val parts = ArrayList<String>()
            file.forEachLine { line ->
                if (line.isBlank() || line.startsWith("#")) return@forEachLine
                val f = line.split("\t")
                if (f.size < 7) return@forEachLine
                val name = f[5].trim()
                val value = f[6].trim()
                if (name.isNotEmpty()) parts.add("$name=$value")
            }
            if (parts.isEmpty()) null else parts.joinToString("; ")
        } catch (_: Throwable) {
            null
        }
    }

    private fun resolveCookies(supplied: String?, url: String?): File? {
        val ctx = appContext ?: return null
        if (url.isNullOrBlank()) return null
        val host = try {
            android.net.Uri.parse(url).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return null

        val source = when {
            !supplied.isNullOrBlank() && File(supplied).isFile -> File(supplied)
            CookieJar.exists(ctx) -> CookieJar.file(ctx)
            else -> return null
        }

        return try {
            val kept = ArrayList<String>()
            source.forEachLine { line ->
                if (line.isBlank() || line.startsWith("#")) return@forEachLine
                val domain = line.split("\t").firstOrNull()?.lowercase()
                    ?: return@forEachLine
                val match = if (domain.startsWith(".")) {
                    host == domain.substring(1) || host.endsWith(domain)
                } else {
                    host == domain
                }
                if (match) kept.add(line)
            }
            if (kept.isEmpty()) return null

            val dir = File(ctx.cacheDir, "cookies").apply { if (!exists()) mkdirs() }
            // Per host, so two reads at once cannot overwrite each other.
            val out = File(dir, host.replace(Regex("[^a-z0-9.-]"), "_") + ".txt")
            out.writeText(
                buildString {
                    append("# Netscape HTTP Cookie File\n")
                    for (line in kept) append(line).append('\n')
                },
                Charsets.UTF_8
            )
            out
        } catch (_: Throwable) {
            null
        }
    }

    /** Which sites the jar actually holds cookies for — for the report. */
    private fun cookieHosts(): List<String> {
        val ctx = appContext ?: return emptyList()
        if (!CookieJar.exists(ctx)) return emptyList()
        return try {
            val hosts = LinkedHashSet<String>()
            CookieJar.file(ctx).forEachLine { line ->
                if (line.isBlank() || line.startsWith("#")) return@forEachLine
                line.split("\t").firstOrNull()?.trimStart('.')?.let { hosts.add(it) }
            }
            hosts.toList()
        } catch (_: Throwable) {
            emptyList()
        }
    }

    /**
     * True when an error is the kind a different player client might get past:
     * the bot wall, a sign-in gate, or a failed extraction.
     */
    private fun isRetryable(message: String): Boolean {
        val m = message.lowercase()
        return m.contains("not a bot") ||
            m.contains("sign in") ||
            m.contains("confirm you") ||
            m.contains("unable to extract") ||
            m.contains("failed to extract") ||
            m.contains("player response") ||
            m.contains("requested format is not available")
    }

    private fun runProbe(
        url: String,
        cookies: String?,
        clients: String?,
        forceClients: Boolean,
        flatPlaylist: Boolean,
        result: MethodChannel.Result
    ) {
        val ctx = appContext
        if (ctx == null || !initBlocking(ctx)) {
            reply(result) { result.error("ENGINE", initError ?: "engine unavailable", null) }
            return
        }

        // Which escalations were reached, in order. See the note above the
        // final reply: "did the retry run" must never again be unanswerable.
        val rungs = ArrayList<String>()

        fun once(
            withClients: String?,
            remoteEjs: Boolean,
            tiktokApi: Boolean = false
        ): String {
            val request = YoutubeDLRequest(url)
            baseOptions(
                request,
                url,
                cookies,
                withClients,
                playlist = if (flatPlaylist) PlaylistMode.FLAT else PlaylistMode.SINGLE,
                remoteEjs = remoteEjs,
                tiktokApi = tiktokApi
            )
            request.addOption("-J")
            return run(request, PROBE_ID)
        }

        fun attempt(withClients: String?, remoteEjs: Boolean = false): String {
            try {
                return once(withClients, remoteEjs)
            } catch (t: Throwable) {
                // The one failure worth retrying automatically: this engine
                // has never heard of the argument. Retry WITHOUT it rather
                // than reporting a failure the user cannot act on.
                if (!jsRuntimeRejected &&
                    rejectsJsRuntime(t.message ?: t.toString())
                ) {
                    jsRuntimeRejected = true
                    return once(withClients, remoteEjs)
                }
                throw t
            }
        }

        /**
         * Did the site say we are asking too often?
         *
         * Checked against the engine's stderr AND the error text, because a
         * 429 surfaces as whatever request happened to hit it — usually
         * "Unable to download webpage" — and the number is the only reliable
         * part of it.
         */
        fun sawRateLimit(err: String?): Boolean {
            // TAKEN AS A PARAMETER, not read from the enclosing scope.
            //
            // This read `firstError` directly and would not compile: a local
            // function may only see locals declared ABOVE it, and firstError
            // is declared seventy lines below. Passing it in removes the
            // ordering dependency altogether rather than fixing it by moving
            // lines around, which would only survive until the next edit.
            val text = ((lastWarning ?: "") + " " + (err ?: "")).lowercase()
            val hit = text.contains("429") || text.contains("too many requests")
            if (hit) rateLimitedAt = System.currentTimeMillis()
            return hit
        }

        fun keep(json: String) {
            synchronized(probeJson) {
                if (probeJson.size >= MAX_PROBE_JSON && probeJson.isNotEmpty()) {
                    probeJson.remove(probeJson.keys.first())
                }
                probeJson[url] = json
            }
        }

        // A cancel that arrived BEFORE this read started cannot belong to it.
        //
        // This one line is a bug that made the whole downloader look dead. The
        // cancel flag is a set keyed by process id, and the probe always uses
        // the same id — so a cancel issued while nothing was running just sat
        // there. The checks below run only AFTER an attempt, so the next read
        // would do its work, and then, if its first attempt happened to come
        // back empty (routine for YouTube — that is what the alternates are
        // for), it hit the stale flag, reported CANCELLED, and never tried
        // them. The Dart side shows nothing at all for a cancel, on the
        // reasonable grounds that the user asked for it. The result was a
        // downloader that silently stopped producing anything, with no error
        // anywhere, until the app was restarted.
        //
        // Clearing it here is correct and not merely convenient: whoever asked
        // for that cancel has already been told the read stopped.
        cancelledIds.remove(PROBE_ID)

        // v0.99.6: THE DEFAULT CLIENT GOES FIRST AGAIN.
        //
        // v0.99.2 put the alternate player clients first because they are
        // faster. That was a bad trade and it showed up as a real regression:
        // those clients answer with a much SHORTER format list — often a single
        // resolution — and because the answer was valid we accepted it and
        // never asked the client that has the full ladder. The result on screen
        // was a quality sheet with one row on it.
        //
        // Completeness wins over a few seconds. The speed that actually
        // mattered came from the cache directory, not from this. The alternate
        // clients stay as the fallback for when the default is refused, and
        // [forceClients] lets the Dart side deliberately ask for them when a
        // default answer comes back suspiciously thin.
        // GATED ON THE HOST. The alternate players are a YouTube argument and
        // every other extractor ignores it, so retrying a TikTok or Instagram
        // link "through the alternates" re-ran a command byte-for-byte
        // identical to the one that had just come back empty — a second Python
        // startup and a second round trip that could not change the answer.
        // For forceClients the Dart side has already decided, and it only ever
        // asks for YouTube.
        val alternates = clients?.takeIf {
            it.isNotBlank() && !clientsRejected && (forceClients || isYouTube(url))
        }

        var firstError: String? = null
        if (!forceClients) {
            try {
                val out = attempt(null)
                if (out.isNotBlank()) {
                    keep(out)
                    reply(result) { result.success(out) }
                    return
                }
                firstError = "empty response"
            } catch (t: Throwable) {
                firstError = t.message ?: t.toString()
            }
            if (cancelledIds.remove(PROBE_ID)) {
                reply(result) { result.error("CANCELLED", "cancelled", null) }
                return
            }
        }

        // ---- THE ESCALATION LADDER. THE ORDER IS LOAD-BEARING. -----------
        //
        // Read top to bottom; each rung assumes every rung above it has
        // already been ruled out. Adding one in the wrong place does not
        // break anything visibly — it just makes a failure take longer and
        // report the wrong cause, which is the hardest kind of bug to see.
        //
        //   1. broken route   — if the network cannot carry the request, no
        //                       site-specific cleverness below can help.
        //   2. TikTok's API   — a site quirk with a known, cheap answer.
        //   3. rate limit     — STOP. Everything below is another burst at a
        //                       server that has just asked for fewer.
        //   4. alternate players (YouTube only)
        //   5. fetch the JS challenge solver
        //
        // Only rungs 2 and 4 are about a particular site. That is deliberately
        // not abstracted into a per-site framework: two entries would cost
        // more to maintain than the branches they replace. Revisit that if a
        // third site ever needs its own rung.
        //
        // THE ROUTE LOOKS BROKEN — TRY ONCE OVER IPv4.
        //
        // Before any of the site-specific escalation below, because if the
        // network cannot carry the request then none of that can possibly
        // help. Learned once and reused for the rest of the session, so a
        // person on a VPN pays this diagnosis a single time instead of on
        // every link. See [forceIpv4].
        if (!forceIpv4 && looksLikeBrokenRoute(firstError)) {
            forceIpv4 = true
            try {
                val out = attempt(clients)
                if (out.isNotBlank()) {
                    keep(out)
                    reply(result) { result.success(out) }
                    return
                }
            } catch (t: Throwable) {
                firstError = t.message ?: t.toString()
            }
        }

        // TIKTOK'S WEB PAGE REFUSED — ASK ITS API INSTEAD.
        //
        // Retried here rather than letting the Dart side notice and start a
        // whole second read: the trail shows that round trip costing about
        // five seconds on top of the thirteen already spent. Same process,
        // same warm engine, one more attempt.
        if (isTikTok(url) && wantsTikTokApi(firstError)) {
            rungs.add("tiktok-api")
            try {
                val out = once(clients, remoteEjs = false, tiktokApi = true)
                if (out.isNotBlank()) {
                    keep(out)
                    reply(result) { result.success(out) }
                    return
                }
            } catch (t: Throwable) {
                if (firstError == null) firstError = t.message ?: t.toString()
            }
        }

        // STOP HERE ON A RATE LIMIT. Everything below this line is an
        // escalation, and escalating is the one response guaranteed to make
        // this particular failure worse and longer.
        if (sawRateLimit(firstError)) {
            reply(result) {
                result.error(
                    "RATE_LIMIT",
                    firstError ?: "HTTP 429: too many requests",
                    null
                )
            }
            return
        }

        if (alternates != null) {
            rungs.add("alt-clients")
            try {
                val out = attempt(alternates)
                if (out.isNotBlank()) {
                    keep(out)
                    reply(result) { result.success(out) }
                    return
                }
                if (firstError == null) firstError = "empty response"
            } catch (t: Throwable) {
                val message = t.message ?: t.toString()
                if (isBadArgument(message)) clientsRejected = true
                // Keep the default client's error when we have one: it says
                // what the site actually objected to.
                if (firstError == null) firstError = message
            }
        }

        // LAST RESORT: fetch the challenge solver scripts and try once more.
        //
        // Deliberately last and deliberately conditional on yt-dlp having
        // complained about the JS side, so an ordinary site failure -- a dead
        // link, a private video -- does not pay for a GitHub round trip it
        // cannot possibly benefit from. When it does apply, it is the whole
        // difference between a downloader that works and one that does not,
        // and it needs neither a new APK nor anything from the user.
        if (jsRuntime != null && blamesJs() && !cancelledIds.contains(PROBE_ID)) {
            rungs.add("remote-ejs")
            try {
                val out = attempt(alternates ?: clients, remoteEjs = true)
                if (out.isNotBlank()) {
                    keep(out)
                    reply(result) { result.success(out) }
                    return
                }
            } catch (t: Throwable) {
                if (firstError == null) firstError = t.message ?: t.toString()
            }
        }

        // Cancelling makes execute() throw; that must not look like a failure.
        if (cancelledIds.remove(PROBE_ID)) {
            reply(result) { result.error("CANCELLED", "cancelled", null) }
            return
        }

        // Carry the extractor's own words out to the UI. A bare "probe failed"
        // tells the person nothing and tells us less.
        val warn = lastWarning
        var message = firstError ?: "probe failed"
        if (jsRuntime == null) {
            message = "no JS runtime (" + (jsRuntimeError ?: "unknown") + "): " + message
        } else if (!warn.isNullOrBlank() && message == "empty response") {
            message = warn.lines().lastOrNull { it.isNotBlank() } ?: message
        }
        // APPENDED, NEVER SUBSTITUTED. The extractor's own words stay first
        // and whole -- they are the part that says what the site objected to.
        // This only adds what we did about it, which is the part that was
        // missing: a TikTok failure that mentions rehydration reads completely
        // differently once you know whether the API retry was tried.
        if (rungs.isNotEmpty()) {
            message = message + "  [tried: " + rungs.joinToString(", ") + "]"
        }
        reply(result) { result.error("PROBE", message, null) }
    }

    /**
     * Client names the engine has told us it does not know.
     *
     * YouTube's usable clients change every few months, yt-dlp renames and
     * retires them to match, and the list we ship is a snapshot of one moment.
     * When the engine says `Skipping unsupported client "x"` it is handing us
     * the correction directly, and an app that reads that and keeps sending
     * the same dead name is choosing not to listen. Held in memory only: on
     * the next launch the engine may well have been updated and the name may
     * be real again, so this expires by itself rather than becoming another
     * stale opinion of ours.
     */
    private val unsupportedClients = java.util.Collections.synchronizedSet(
        mutableSetOf<String>()
    )

    /**
     * Files the interesting lines away whole, newest last, capped.
     *
     * Only WARNING/ERROR lines: the rest of yt-dlp's chatter is progress and
     * debug noise that would push the useful lines out of a small budget.
     */
    private fun collectWarnings(text: String?) {
        if (text.isNullOrBlank()) return
        for (raw in text.split("\n")) {
            val line = raw.trim()
            if (line.length < 8 || line.length > 300) continue
            if (!line.contains("WARNING") && !line.contains("ERROR")) continue
            synchronized(sessionWarnings) {
                sessionWarnings.add(line)
                while (sessionWarnings.size > 6) {
                    val oldest = sessionWarnings.firstOrNull() ?: break
                    sessionWarnings.remove(oldest)
                }
            }
        }
    }

    /** Reads the names out of `Skipping unsupported client "x"` warnings. */
    private fun learnUnsupported(warning: String?) {
        if (warning.isNullOrBlank()) return
        val marker = "unsupported client " + '"'
        var from = warning.indexOf(marker)
        while (from >= 0) {
            val start = from + marker.length
            val end = warning.indexOf('"', start)
            if (end <= start) break
            val name = warning.substring(start, end).trim()
            if (name.isNotEmpty() && name.length < 40) {
                unsupportedClients.add(name.lowercase())
            }
            from = warning.indexOf(marker, end)
        }
    }

    /** The list minus anything the engine has rejected; null if nothing is left. */
    private fun usableClients(clients: String?): String? {
        if (clients.isNullOrBlank()) return null
        if (unsupportedClients.isEmpty()) return clients
        val kept = clients.split(",")
            .map { it.trim() }
            .filter { it.isNotEmpty() && !unsupportedClients.contains(it.lowercase()) }
        return if (kept.isEmpty()) null else kept.joinToString(",")
    }

    /**
     * Is this a YouTube address?
     *
     * Matched on the registrable host rather than a substring, so a URL that
     * merely mentions youtube in a path or query cannot masquerade as one.
     */
    private fun isYouTube(url: String): Boolean {
        val host = try {
            android.net.Uri.parse(url).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return false
        return host == "youtu.be" ||
            host == "youtube.com" ||
            host.endsWith(".youtube.com") ||
            host.endsWith(".youtube-nocookie.com")
    }

    /**
     * Does this failure look like the network could not carry the request?
     *
     * Deliberately broad. The cost of being wrong is one extra attempt over
     * IPv4; the cost of being too strict is a person on a VPN concluding the
     * whole app is broken, which is precisely what happened.
     */
    /**
     * The requested folder if we can actually write to it, ours if we cannot.
     *
     * WHY: a download failed on the device with
     *
     *   ERROR: Unable to download video: [Errno 13] Permission denied:
     *   '/storage/emulated/0/Download/Innocent/index-v1-a1.mp4.ytdl'
     *
     * The public Downloads folder is only writable through a raw path when
     * "All files access" has been granted, which is a switch in system
     * Settings that nobody flips by accident. `mkdirs()` returning true says
     * nothing about that — the folder can already exist and still refuse a
     * write — so the old check passed and the failure surfaced minutes later
     * as an unreadable errno from inside Python.
     *
     * The app's own external folder needs no permission on any Android
     * version, so it is always available as a floor. Landing a file somewhere
     * slightly awkward beats not landing it at all, and the caller is told
     * which one was used rather than left to guess.
     *
     * PROVED by writing a real file, not by asking: the storage layer answers
     * questions about permission optimistically and only the write is the
     * truth.
     */
    private fun writableDir(ctx: Context, requested: String): File? {
        val wanted = File(requested)
        if (canWrite(wanted)) return wanted
        val fallback = ctx.getExternalFilesDir(android.os.Environment.DIRECTORY_MOVIES)
            ?: ctx.filesDir
        return if (canWrite(fallback)) fallback else null
    }

    /** Creates the folder and proves it by writing a byte and removing it. */
    private fun canWrite(dir: File): Boolean {
        return try {
            if (!dir.exists() && !dir.mkdirs()) return false
            val probe = File(dir, ".innocent-write-test")
            probe.writeText("x")
            probe.delete()
            true
        } catch (_: Throwable) {
            false
        }
    }

    /** A streaming manifest rather than a plain file. */
    private fun looksLikePlaylist(url: String): Boolean {
        val path = try {
            (android.net.Uri.parse(url).path ?: url).lowercase()
        } catch (_: Throwable) {
            url.lowercase()
        }
        return path.endsWith(".m3u8") || path.contains(".m3u8") || path.endsWith(".mpd")
    }

    /** A TikTok address, by registrable host. */
    private fun isTikTok(url: String): Boolean {
        val host = try {
            android.net.Uri.parse(url).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return false
        return host == "tiktok.com" || host.endsWith(".tiktok.com")
    }

    /**
     * Did yt-dlp itself say the JS challenge could not be solved?
     *
     * PROMOTED OUT OF runProbe, where it was a local function and therefore
     * unreachable from the browser read -- which needs exactly the same
     * judgement and was making a single unescalated attempt without it.
     * Copying it would have been the wrong fix: two copies of a question
     * drift, and the drifting one is the one nobody watches.
     */
    private fun blamesJs(): Boolean {
        val w = lastWarning?.lowercase() ?: return false
        return w.contains("javascript runtime") ||
            w.contains("jsc provider") ||
            w.contains("yt-dlp-ejs") ||
            w.contains("wiki/ejs") ||
            w.contains("challenge")
    }

    /** TikTok's web page would not give up its embedded data. */
    private fun wantsTikTokApi(message: String?): Boolean {
        val m = message?.lowercase() ?: return false
        return m.contains("universal data for rehydration") ||
            m.contains("unable to extract webpage video data") ||
            m.contains("unable to extract initial data")
    }

    private fun looksLikeBrokenRoute(message: String?): Boolean {
        val m = message?.lowercase() ?: return false
        return m.contains("network is unreachable") ||
            m.contains("temporary failure in name resolution") ||
            m.contains("name or service not known") ||
            m.contains("getaddrinfo") ||
            m.contains("unable to connect") ||
            m.contains("connection reset") ||
            m.contains("connection refused") ||
            m.contains("timed out") ||
            m.contains("timeout")
    }

    /** An argument yt-dlp itself rejected, as opposed to a site-side failure. */
    private fun isBadArgument(message: String): Boolean {
        val m = message.lowercase()
        return m.contains("invalid player client") ||
            m.contains("unsupported client") ||
            m.contains("unknown client") ||
            m.contains("invalid extractor argument")
    }

    /**
     * An engine that does not know about --js-runtimes at all.
     *
     * Distinguished from a runtime that ran and failed: the first means stop
     * sending the argument, the second means the argument was right and the
     * work was hard. Treating them the same would silently disable the fix on
     * the first slow phone.
     */
    private fun rejectsJsRuntime(message: String?): Boolean {
        val m = message?.lowercase() ?: return false
        if (!m.contains("js-runtimes")) return false
        return m.contains("no such option") ||
            m.contains("unrecognized") ||
            m.contains("unrecognised") ||
            m.contains("unknown option") ||
            m.contains("not allowed")
    }

    private fun runResolve(
        url: String,
        selector: String,
        cookies: String?,
        clients: String?,
        result: MethodChannel.Result
    ) {
        val ctx = appContext
        if (ctx == null || !initBlocking(ctx)) {
            reply(result) { result.error("ENGINE", initError ?: "engine unavailable", null) }
            return
        }

        fun attempt(withClients: String?): String {
            val request = YoutubeDLRequest(url)
            baseOptions(request, url, cookies, withClients)
            request.addOption("-f", selector)
            request.addOption("-g")
            return run(request, RESOLVE_ID)
        }

        fun firstUrl(out: String): String? = out.lineSequence()
            .map { it.trim() }
            .firstOrNull { it.startsWith("http") }

        // Gated on the host for the same reason runProbe is: the alternate
        // players are a YouTube argument, so trying them first on any other
        // site pays for an extra engine run that cannot change the answer.
        val preferred = clients?.takeIf {
            it.isNotBlank() && !clientsRejected && isYouTube(url)
        }
        var firstError: String? = null
        if (preferred != null) {
            try {
                val found = firstUrl(attempt(preferred))
                if (!found.isNullOrEmpty()) {
                    reply(result) { result.success(found) }
                    return
                }
            } catch (t: Throwable) {
                val message = t.message ?: t.toString()
                if (isBadArgument(message)) clientsRejected = true
                firstError = message
            }
        }
        try {
            val found = firstUrl(attempt(null))
            if (!found.isNullOrEmpty()) {
                reply(result) { result.success(found) }
                return
            }
            if (firstError == null) firstError = "no playable url"
        } catch (t: Throwable) {
            firstError = t.message ?: t.toString()
        }

        val message = firstError ?: "resolve failed"
        reply(result) { result.error("RESOLVE", message, null) }
    }

    private fun runDownload(job: Job) {
        val id = job.id
        val url = job.url
        val selector = job.selector
        val dir = job.dir
        val title = job.title
        val audioOnly = job.audioOnly
        val toMp3 = job.toMp3
        val merge = job.merge
        val cookies = job.cookies
        val clients = job.clients
        val ctx = appContext
        if (cancelledIds.remove(id)) {
            finish(id, mapOf("id" to id, "phase" to "cancelled"))
            return
        }
        if (pausedIds.contains(id)) {
            finish(id, mapOf("id" to id, "phase" to "paused"))
            return
        }
        if (ctx == null) {
            finish(id, mapOf("id" to id, "phase" to "error", "error" to "no context"))
            return
        }
        emit(mapOf("id" to id, "phase" to "preparing", "title" to title))
        jobTitles[id] = title.ifEmpty { "Downloading" }
        DownloadService.start(ctx, title.ifEmpty { "Downloading" }, "Preparing…", -1, id)
        if (!initBlocking(ctx)) {
            finish(
                id,
                mapOf(
                    "id" to id, "phase" to "error",
                    "error" to (initError ?: "engine unavailable")
                )
            )
            return
        }
        if (cancelledIds.remove(id)) {
            finish(id, mapOf("id" to id, "phase" to "cancelled"))
            return
        }

        // A DOWNLOAD MUST NEVER DIE ON A PERMISSION. See [writableDir].
        val target = writableDir(ctx, dir)
        if (target == null) {
            finish(id, mapOf("id" to id, "phase" to "error", "error" to "cannot create $dir"))
            return
        }

        // Written once per job, not once per attempt.
        val infoFile: File? = writeInfoJson(ctx, url)
        var useInfo = infoFile != null

        var lastPath: String? = null
        // PER-JOB throttle clock. This was one shared field back when downloads
        // ran strictly one at a time; now that three run at once (see
        // MAX_PARALLEL_DOWNLOADS) a shared clock meant the three rows had to
        // SHARE one update per second between them — two of three sat still —
        // and each new download reset the clock out from under the others. A
        // local per job gives every row its own ~1/sec.
        val lastEmit = AtomicLong(0L)
        var attempt = 0
        while (true) {
        attempt++
        try {
            // With the info we already have, yt-dlp is handed the answer
            // instead of the question: no extraction, no second refusal.
            val request = if (useInfo && infoFile != null) {
                YoutubeDLRequest(listOf<String>()).also {
                    it.addOption("--load-info-json", infoFile.absolutePath)
                }
            } else {
                YoutubeDLRequest(url)
            }
            // 10 retries, not the probe's 2: a download that gives up on a
            // brief signal drop has thrown away everything it fetched, and on a
            // Myanmar mobile connection brief drops are normal.
            baseOptions(request, job.url, cookies, clients, retries = 10)
            request.addOption("--fragment-retries", "10")
            // Explicit rather than implied: resume from the .part file is the
            // entire basis of pause/resume and of surviving a dropped
            // connection, so it must not depend on a default staying put.
            request.addOption("--continue")
            // DON'T RE-FETCH WHAT IS ALREADY HERE. The same clip queued twice
            // used to download twice; now that each clip has a stable `[id]`
            // name, a second run finds the finished file and skips it — yt-dlp
            // prints "has already been downloaded", which extractPath reads back
            // as the result so the row still resolves to the real file. Sits
            // beside --continue without conflict: a FINISHED file is skipped, a
            // half-written .part is still resumed.
            request.addOption("--no-overwrites")
            request.addOption("-f", selector)
            // UNIQUE PER CLIP, NOT PER TITLE. Two different clips on these sites
            // routinely share ONE title — the library showed four "…မလေး" rows
            // at four different sizes — and a title-only name collides them onto
            // a single path. With downloads running three at a time (see
            // MAX_PARALLEL_DOWNLOADS) their .part and embedded-thumbnail temp
            // files then landed on top of one another, which is exactly how a
            // row's title and its video came apart, and how the same title
            // showed up again and again. The `[%(id)s]` tag yt-dlp fills is
            // unique to each clip AND stable across a resume (so `--continue`
            // still finds the right .part), so same-titled clips no longer
            // collide. Title trimmed to 80B to leave room for the tag under the
            // 255-byte filesystem limit (still bytes, not chars — Burmese titles
            // overflow a char count).
            request.addOption("-o", File(target, "%(title).80B [%(id)s].%(ext)s").absolutePath)
            request.addOption("--no-mtime")
            request.addOption("--newline")

            if (audioOnly && toMp3) {
                request.addOption("-x")
                request.addOption("--audio-format", "mp3")
            } else if (merge && ffmpegError == null) {
                request.addOption("--merge-output-format", "mp4")
            }

            // PLAYLISTS GO TO YT-DLP'S OWN FRAGMENT DOWNLOADER, NOT FFMPEG.
            //
            // This is a correction, and it is the reason the progress bar
            // never moved. Handing HLS to ffmpeg works — files arrive — but
            // yt-dlp then sits idle while ffmpeg does everything, and its
            // progress hook is not called again until the whole thing is
            // finished. yt-dlp's own issue #11642 says so in as many words.
            // ffmpeg's own output never reaches our callback either; it only
            // turns up in stderr at the end, which is how it ended up in the
            // trail looking like an error. So there was no percentage to be
            // had anywhere, and a healthy download at two megabytes a second
            // showed nought the entire way.
            //
            // The native fragment downloader prints exactly what we already
            // know how to read — `[hlsnative] Total fragments: 519` then
            // `[download] 45.2% of ...` — and honours --concurrent-fragments
            // below, so it is faster as well as legible.
            //
            // ffmpeg is not lost: yt-dlp still chooses it by itself for real
            // live streams, which is the one case it was ever needed for.
            if (aria2cError == null) {
                // aria2c is a plain HTTP(S) downloader — it cannot walk HLS or
                // DASH fragment lists. The `PROTO:NAME` form scopes it to what
                // it can handle and leaves dash/m3u8 on the native downloader.
                // Deliberately ONE addOption call: YoutubeDLRequest keys
                // options by name.
                request.addOption("--downloader", "http,https:libaria2c.so")
                // MANY CONNECTIONS, BECAUSE THE CDNS CAP EACH ONE.
                //
                // The device log showed a 1.1 GB file crawling at ~1 MB/s on a
                // link the phone itself could pull at 7-13 MB/s. That gap is not
                // the network — it is the CDN throttling a SINGLE connection,
                // which is what these hosts (phncdn and the rest) do as a matter
                // of course. aria2c defaults to one connection per server, so it
                // walked straight into the cap. Splitting the file across many
                // connections is the whole reason aria2c is worth having here:
                // each stream is throttled the same, and sixteen of them add up
                // to the real line speed. `--min-split-size=1M` keeps the pieces
                // from being cut so small the per-request overhead outweighs the
                // gain. Harmless on a CDN that does not throttle — aria2c never
                // opens more connections than a file needs.
                //
                // ONE --downloader-args VALUE ONLY. YoutubeDLRequest keys
                // options by name, so a second call REPLACES the first rather
                // than adding to it — the multi-connection flags and the proxy
                // flag must travel together in one string.
                val aria2Args = StringBuilder(
                    "aria2c:--max-connection-per-server=16 --split=16 " +
                        "--min-split-size=1M " +
                        // START WRITING AT ONCE, DON'T PRE-ALLOCATE. aria2c's
                        // default (prealloc) reserves the whole file up front —
                        // on a 1 GB clip that is a visible "Allocating…" pause
                        // before a single byte arrives, which reads as a stall.
                        // `none` begins immediately; safe on the ext4-backed
                        // internal storage downloads land on, and the standard
                        // setting for aria2 on Android.
                        "--file-allocation=none " +
                        // EACH CONNECTION RETRIES ITSELF. On a phone network a
                        // connection drops often; without this a dropped one is
                        // just gone and the piece waits on the outer retry loop.
                        // Five tries, ten seconds apart, recovers most stumbles
                        // in place. (The whole-download retry still backs it up.)
                        "--max-tries=5 --retry-wait=10 " +
                        // Pull pieces roughly front-to-back so a partially
                        // downloaded clip is playable/scannable sooner, rather
                        // than scattered across the file.
                        "--stream-piece-selector=geom"
                )
                // AND TELL ARIA2C ABOUT THE PROXY ITSELF.
                //
                // `--proxy` configures YT-DLP's own network layer; aria2c is a
                // separate process that has to be told separately, and the
                // failure when it is not is silent and total — youtube-dl
                // #23730 is exactly this: the extraction succeeds through the
                // proxy and then the download goes direct and dies. On this
                // phone that would be invisible in the worst way: the bypass
                // exists precisely because those hosts are unreachable without
                // it, so the quality sheet would open perfectly and every
                // download from it would fail.
                if (DnsBypassProxy.isRunning) {
                    aria2Args.append(" --all-proxy=http://127.0.0.1:")
                        .append(DnsBypassProxy.port)
                }
                request.addOption("--downloader-args", aria2Args.toString())
            }
            // Fragmented HLS/DASH stays on the native downloader (aria2c cannot
            // walk a fragment list), and it pulls segments one at a time unless
            // told otherwise — the same per-connection cap bites a stream as
            // hard as a whole file, so fetch several segments at once.
            request.addOption("--concurrent-fragments", "8")
            // HLS/DASH RESILIENCE. Adult CDNs drop fragments mid-stream, and
            // the default ten retries per fragment is not always enough for a
            // long clip over a phone connection — one unlucky segment then fails
            // the whole download. Twenty tries with exponential backoff (1s, 2s,
            // 4s … capped at 30s) rides out a flaky patch without hammering a
            // struggling CDN. These bind the native fragment path; the aria2c
            // whole-file path has its own --max-tries above. Deliberately NOT
            // using --throttled-rate: it would re-extract whenever the rate dips
            // below a floor, which on the variable mobile networks these users
            // are on would misfire on merely-slow (not throttled) connections
            // and make things worse.
            request.addOption("--fragment-retries", "20")
            request.addOption("--retry-sleep", "fragment:exp=1:30")

            // Extras, all optional and all gated on what is actually possible.
            job.rateLimit?.takeIf { it.isNotBlank() }?.let {
                request.addOption("--limit-rate", it)
            }
            if (ffmpegError == null) {
                // Every one of these is a post-process, so without a muxer they
                // would fail the whole download rather than be skipped.
                job.subLangs?.takeIf { it.isNotBlank() }?.let {
                    request.addOption("--sub-langs", it)
                    request.addOption("--write-subs")
                    request.addOption("--embed-subs")
                }
                if (job.embedThumbnail && !audioOnly) {
                    request.addOption("--embed-thumbnail")
                }
                if (job.embedMetadata) {
                    request.addOption("--embed-metadata")
                }
            }

            var announcedFinalizing = false
            run(request, id) { progress, eta, line ->
                val path = extractPath(line)
                if (path != null) lastPath = path
                val now = System.currentTimeMillis()
                val previous = lastEmit.get()
                // POST-PROCESSING LOOKS LIKE A FREEZE UNLESS WE SAY OTHERWISE. A
                // merge, or a thumbnail/metadata embed, rewrites the whole file
                // AFTER the bytes are all here — several seconds on a big clip —
                // during which the bar would sit at 100% with a stale line. Show
                // "Finalizing…" instead: once immediately (past the throttle so
                // the switch is instant), then throttled like any other update.
                if (isFinalizing(line)) {
                    if (!announcedFinalizing ||
                        (now - previous >= 1000L && lastEmit.compareAndSet(previous, now))
                    ) {
                        announcedFinalizing = true
                        emit(
                            mapOf(
                                "id" to id, "phase" to "progress",
                                "progress" to 100, "eta" to 0, "line" to "Finalizing…"
                            )
                        )
                        DownloadService.update(
                            ctx, title.ifEmpty { "Downloading" }, "Finalizing…", 100, id
                        )
                    }
                } else if (now - previous >= 1000L && lastEmit.compareAndSet(previous, now)) {
                    // With aria2c doing the fetching, yt-dlp's own progress
                    // hooks never fire and `progress` stays at 0 for the whole
                    // download — aria2c prints its own percentage instead, so
                    // fall back to reading it off the line.
                    // Three sources, best wins: yt-dlp's own hook, aria2c's
                    // printed percentage, and — for playlists, where neither
                    // fires — ffmpeg's position against the total it announced.
                    val pct = maxOf(
                        maxOf(progress.toInt(), percentIn(line)),
                        ffmpegPercent(id, line)
                    ).coerceIn(0, 100)
                    emit(
                        mapOf(
                            "id" to id, "phase" to "progress", "progress" to pct,
                            "eta" to eta, "line" to line.trim()
                        )
                    )
                    DownloadService.update(
                        ctx,
                        title.ifEmpty { "Downloading" },
                        if (pct > 0) "$pct%" else line.trim(),
                        pct,
                        id
                    )
                }
            }

            if (cancelledIds.remove(id)) {
                deletePartialsFor(target, lastPath)
                finish(id, mapOf("id" to id, "phase" to "cancelled"))
                return
            }
            if (pausedIds.contains(id)) {
                finish(id, mapOf("id" to id, "phase" to "paused"))
                return
            }

            val resolved = finalFor(lastPath, target)
            if (resolved != null) {
                // Let the MediaStore see it immediately so the file shows up in
                // the Videos tab and the system gallery without a reboot.
                try {
                    MediaScannerConnection.scanFile(ctx, arrayOf(resolved), null, null)
                } catch (_: Throwable) {
                }
            }
            jobs.remove(id)
            finish(
                id,
                mapOf("id" to id, "phase" to "done", "path" to resolved, "title" to title)
            )
            return
        } catch (t: Throwable) {
            // destroyProcessById makes execute() throw, so a cancel and a pause
            // both arrive here. Neither is a failure and neither may retry.
            if (cancelledIds.remove(id)) {
                deletePartialsFor(target, lastPath)
                jobs.remove(id)
                finish(id, mapOf("id" to id, "phase" to "cancelled"))
                return
            }
            if (pausedIds.contains(id)) {
                finish(id, mapOf("id" to id, "phase" to "paused"))
                return
            }
            val message = t.message ?: t.toString()
            // Saved info can go stale — media URLs expire, and a post can be
            // edited or pulled. If the shortcut is what broke, drop it and do
            // the extraction properly. Only ever once, since useInfo latches
            // off, so this cannot loop.
            if (useInfo) {
                useInfo = false
                attempt--
                emit(
                    mapOf(
                        "id" to id, "phase" to "retrying",
                        "attempt" to attempt, "error" to message
                    )
                )
                continue
            }
            // A dropped connection is the common case and it is recoverable:
            // the .part file is still there, so re-running resumes rather than
            // restarting. Back off so we don't hammer a network that is down.
            if (attempt < MAX_DOWNLOAD_ATTEMPTS && isTransient(message)) {
                emit(
                    mapOf(
                        "id" to id, "phase" to "retrying",
                        "attempt" to attempt, "error" to message
                    )
                )
                DownloadService.update(
                    ctx, title.ifEmpty { "Downloading" }, "Reconnecting...", -1, id
                )
                try {
                    Thread.sleep(RETRY_BACKOFF_MS * attempt)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
                if (cancelledIds.remove(id)) {
                    jobs.remove(id)
                    finish(id, mapOf("id" to id, "phase" to "cancelled"))
                    return
                }
                if (pausedIds.contains(id)) {
                    finish(id, mapOf("id" to id, "phase" to "paused"))
                    return
                }
                continue
            }
            jobs.remove(id)
            finish(id, mapOf("id" to id, "phase" to "error", "error" to message))
            return
        }
        }
    }

    /**
     * Saves a TikTok photo post.
     *
     * Deliberately NOT routed through yt-dlp: for a photo post yt-dlp has no
     * formats to give (see TikTokPhotoExtractor for why), so these are plain
     * image URLs that we fetch ourselves. Everything else about the job is
     * unchanged — same queue, same foreground service, same cancel — so a photo
     * post behaves like any other download from the user's side.
     *
     * Images land in their own folder because a post is a set: ten loose files
     * named after the same caption in the Downloads folder is not a result
     * anyone wants.
     */
    private fun runPhotoDownload(
        id: String,
        groups: List<List<String>>,
        dir: String,
        title: String
    ) {
        val ctx = appContext
        if (cancelledIds.remove(id)) {
            finish(id, mapOf("id" to id, "phase" to "cancelled"))
            return
        }
        if (ctx == null) {
            finish(id, mapOf("id" to id, "phase" to "error", "error" to "no context"))
            return
        }
        emit(mapOf("id" to id, "phase" to "preparing", "title" to title))
        jobTitles[id] = title.ifEmpty { "Photos" }
        DownloadService.start(ctx, title.ifEmpty { "Photos" }, "Preparing...", -1, id)

        val folderName = safeName(title.ifEmpty { "tiktok_photos" })
        // Through writableDir for the same reason the video path is: mkdirs()
        // succeeding says nothing about being allowed to WRITE, and a photo set
        // that dies on an errno halfway through is the same failure with a
        // different file extension.
        val parent = writableDir(ctx, dir) ?: File(dir)
        val target = File(parent, folderName)
        if (!target.exists() && !target.mkdirs()) {
            finish(
                id,
                mapOf("id" to id, "phase" to "error", "error" to "cannot create ${target.path}")
            )
            return
        }

        val saved = ArrayList<String>()
        val total = groups.size
        // Per-job throttle clock — see runDownload; a shared one starved
        // concurrent rows of their progress updates.
        val lastEmit = AtomicLong(0L)

        for ((index, candidates) in groups.withIndex()) {
            if (cancelledIds.remove(id)) {
                finish(id, mapOf("id" to id, "phase" to "cancelled"))
                return
            }
            if (pausedIds.contains(id)) {
                finish(id, mapOf("id" to id, "phase" to "paused"))
                return
            }

            var written: File? = null
            var lastError: String? = null
            // Mirrors are tried in order; one 403 must not lose the picture.
            for (candidate in candidates) {
                try {
                    written = fetchImage(candidate, target, index + 1)
                    if (written != null) break
                } catch (t: Throwable) {
                    lastError = t.message ?: t.toString()
                }
            }
            if (written == null) {
                finish(
                    id,
                    mapOf(
                        "id" to id, "phase" to "error",
                        "error" to (lastError ?: "image ${index + 1} failed")
                    )
                )
                return
            }
            saved.add(written.absolutePath)

            val pct = ((index + 1) * 100 / total).coerceIn(0, 100)
            emit(
                mapOf(
                    "id" to id, "phase" to "progress", "progress" to pct,
                    "line" to "photo ${index + 1}/$total"
                )
            )
            DownloadService.update(
                ctx, title.ifEmpty { "Photos" }, "${index + 1}/$total", pct, id
            )
        }

        // One scan for the whole set rather than one per file.
        try {
            MediaScannerConnection.scanFile(ctx, saved.toTypedArray(), null, null)
        } catch (_: Throwable) {
        }
        finish(
            id,
            mapOf(
                "id" to id, "phase" to "done",
                // Point at the first image: tapping Play should open something
                // viewable, and a folder path is not.
                "path" to saved.firstOrNull(),
                "title" to title
            )
        )
    }

    /** Returns the written file, or null when the server didn't serve an image. */
    private fun fetchImage(url: String, dir: File, index: Int): File? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15000
            readTimeout = 20000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", PHOTO_USER_AGENT)
            setRequestProperty("Referer", "https://www.tiktok.com/")
            setRequestProperty("Accept", "image/avif,image/webp,image/*,*/*;q=0.8")
        }
        try {
            if (connection.responseCode !in 200..299) return null
            val type = connection.contentType ?: ""
            val ext = when {
                type.contains("webp") -> "webp"
                type.contains("png") -> "png"
                type.contains("heic") -> "heic"
                type.contains("image") -> "jpg"
                // Not an image at all — usually an error page with a 200.
                else -> return null
            }
            val out = File(dir, String.format("%02d.%s", index, ext))
            connection.inputStream.use { input ->
                FileOutputStream(out).use { output ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        val read = input.read(buffer)
                        if (read <= 0) break
                        output.write(buffer, 0, read)
                    }
                    output.flush()
                }
            }
            // A zero-byte file is a failure that would otherwise look like success.
            if (out.length() > 0) return out
            out.delete()
            return null
        } finally {
            try {
                connection.disconnect()
            } catch (_: Throwable) {
            }
        }
    }

    /** Filesystem-safe, byte-bounded folder name. */
    private fun safeName(raw: String): String {
        // Character-by-character rather than a regex: the illegal set is
        // mostly escape characters, and writing it as a pattern means
        // escaping backslashes twice over — through Kotlin and again
        // through the regex engine — which is how a typo hides.
        val illegal = "/\\:*?\"<>|"
        val cleaned = raw
            .map { if (it in illegal || it.isISOControl()) ' ' else it }
            .joinToString("")
            .split(' ')
            .filter { it.isNotEmpty() }
            .joinToString(" ")
            .trim()
            .ifEmpty { "tiktok_photos" }
        var bytes = cleaned.toByteArray(Charsets.UTF_8)
        if (bytes.size <= 80) return cleaned
        // Cut on a character boundary, not a byte one, or a Burmese title
        // becomes mojibake.
        var end = cleaned.length
        while (end > 1 && bytes.size > 80) {
            end--
            bytes = cleaned.substring(0, end).toByteArray(Charsets.UTF_8)
        }
        return cleaned.substring(0, end).trim().ifEmpty { "tiktok_photos" }
    }

    /**
     * Dumps the cached probe JSON for [url] to a file yt-dlp can load, or null
     * when we have nothing for it (a resumed job after a restart, say).
     */
    private fun writeInfoJson(ctx: Context, url: String): File? {
        val json = synchronized(probeJson) { probeJson[url] } ?: return null
        return try {
            val dir = File(ctx.cacheDir, "info").apply { if (!exists()) mkdirs() }
            val file = File(dir, "info_" + url.hashCode().toString().replace("-", "n") + ".json")
            file.writeText(json, Charsets.UTF_8)
            if (file.length() > 0) file else null
        } catch (_: Throwable) {
            null
        }
    }

    /** Worth retrying by itself: the network, not the content. */
    private fun isTransient(message: String): Boolean {
        val m = message.lowercase()
        return m.contains("timed out") ||
            m.contains("timeout") ||
            m.contains("connection reset") ||
            m.contains("connection aborted") ||
            m.contains("connection refused") ||
            m.contains("network is unreachable") ||
            m.contains("temporary failure") ||
            m.contains("name or service not known") ||
            m.contains("incomplete read") ||
            m.contains("content too short") ||
            m.contains("unable to download") ||
            m.contains("http error 5")
    }

    private val percentRegex = Regex("""(\d+(?:\.\d+)?)\s*%""")

    private fun percentIn(line: String): Int {
        val match = percentRegex.find(line) ?: return 0
        return match.groupValues[1].toDoubleOrNull()?.toInt() ?: 0
    }

    /**
     * True on the lines yt-dlp prints once the bytes are down and it is
     * repackaging the file — merging separate video and audio, embedding the
     * thumbnail or metadata, converting audio, or fixing up an HLS/MP4
     * container. All of it happens at 100% and can take real time on a large
     * clip, so the UI shows "Finalizing…" rather than a bar that looks frozen.
     */
    private fun isFinalizing(line: String): Boolean {
        return line.contains("[Merger]") ||
            line.contains("Merging formats") ||
            line.contains("[EmbedThumbnail]") ||
            line.contains("[Metadata]") ||
            line.contains("[ExtractAudio]") ||
            line.contains("[VideoConvertor]") ||
            line.contains("[ThumbnailsConvertor]") ||
            line.contains("Deleting original file") ||
            line.contains("[FixupM3u8]") ||
            line.contains("[FixupMp4]") ||
            line.contains("[FixupM4a]")
    }

    /**
     * How far along an ffmpeg download is, worked out rather than read.
     *
     * KEPT DELIBERATELY THOUGH IT RARELY FIRES. Playlists no longer go to
     * ffmpeg (see the downloader choice above), but yt-dlp still picks it
     * itself for genuine live streams, and if those lines ever reach the
     * callback this turns them into a percentage instead of nothing. It costs
     * two regexes and a map.
     *
     * WHY: playlists are handed to ffmpeg, and **ffmpeg never prints a
     * percentage**. It reports how long it has been going, not how far through
     * it is. So the figure stayed at nought for the whole download — the
     * notification showed an endless barber's pole and the bar sat still while
     * a perfectly healthy download ran at two megabytes a second. Nothing was
     * wrong except that nobody could tell.
     *
     * But ffmpeg announces the total near the start (`Duration: 00:04:31.20`)
     * and reports its position on every progress line (`time=00:01:07.5`). One
     * over the other is the answer. Kept per job, because two downloads must
     * never inherit each other's total.
     */
    private val ffmpegTotals = java.util.concurrent.ConcurrentHashMap<String, Double>()

    private val durationRegex = Regex("Duration:\\s*(\\d+):(\\d\\d):(\\d\\d(?:\\.\\d+)?)")
    private val timeRegex = Regex("time=\\s*(\\d+):(\\d\\d):(\\d\\d(?:\\.\\d+)?)")

    private fun clockToSeconds(m: MatchResult): Double {
        val h = m.groupValues[1].toDoubleOrNull() ?: return 0.0
        val mi = m.groupValues[2].toDoubleOrNull() ?: return 0.0
        val s = m.groupValues[3].toDoubleOrNull() ?: return 0.0
        return h * 3600 + mi * 60 + s
    }

    /** Reads a total or a position out of one line; 0 when it holds neither. */
    private fun ffmpegPercent(jobId: String, line: String): Int {
        durationRegex.find(line)?.let { m ->
            val total = clockToSeconds(m)
            if (total > 0) ffmpegTotals[jobId] = total
        }
        val total = ffmpegTotals[jobId] ?: return 0
        val at = timeRegex.find(line) ?: return 0
        val done = clockToSeconds(at)
        if (total <= 0 || done <= 0) return 0
        return ((done / total) * 100).toInt().coerceIn(0, 100)
    }

    /** Emits a terminal event and tears the foreground service down if idle. */
    private fun finish(id: String, payload: Map<String, Any?>) {
        activeIds.remove(id)
        cancelledIds.remove(id)
        emit(payload)
        if (activeIds.isEmpty()) {
            appContext?.let { DownloadService.stop(it) }
        }
    }

    private fun extractPath(line: String): String? {
        val text = line.trim()
        val mergeMarker = "Merging formats into \""
        if (text.contains(mergeMarker)) {
            val start = text.indexOf(mergeMarker) + mergeMarker.length
            val end = text.indexOf('"', start)
            if (end > start) return text.substring(start, end)
        }
        val destMarker = "Destination: "
        if (text.contains(destMarker)) {
            val path = text.substring(text.indexOf(destMarker) + destMarker.length).trim()
            if (path.startsWith("/")) return path
        }
        val alreadyMarker = " has already been downloaded"
        if (text.contains(alreadyMarker)) {
            val path = text.substringBefore(alreadyMarker).substringAfterLast("] ").trim()
            if (path.startsWith("/")) return path
        }
        return null
    }

    /**
     * Newest finished file in [dir], ignoring yt-dlp's in-progress artefacts so
     * a failed run can never be reported as a completed download.
     */
    /**
     * The real length, in milliseconds, of each file the UI still shows at
     * zero — read straight off the container header with the same component the
     * system uses, so it works no matter why MediaStore's own value was 0.
     *
     * Only paths it could actually read appear in the result; an unreadable or
     * still-writing file is simply left out, and the row keeps whatever it had.
     * Each retriever is released before the next opens, so a long list never
     * holds more than one at a time on a low-memory phone.
     */
    private fun probeDurations(paths: List<String>): Map<String, Long> {
        val out = HashMap<String, Long>()
        for (path in paths) {
            if (path.isBlank()) continue
            val r = android.media.MediaMetadataRetriever()
            try {
                r.setDataSource(path)
                val ms = r.extractMetadata(
                    android.media.MediaMetadataRetriever.METADATA_KEY_DURATION
                )?.trim()?.toLongOrNull() ?: 0L
                if (ms > 0) out[path] = ms
            } catch (_: Throwable) {
                // Unreadable, not a media file, or mid-write — leave it out.
            } finally {
                try {
                    r.release()
                } catch (_: Throwable) {
                }
            }
        }
        return out
    }

    /**
     * Removes THIS job's half-written pieces after a cancel — the
     * `.part`/`.ytdl`/`.temp` and per-format files that would otherwise sit on
     * the card as dead weight (a cancelled 1 GB download leaves 1 GB behind).
     *
     * Scoped by the clip's `[id]` tag so a CONCURRENT download's partials are
     * never touched; when no tag is known yet — cancelled before yt-dlp named a
     * destination — nothing is deleted, because there is then no safe way to
     * tell this job's pieces from another's, and leaking a few early kilobytes
     * beats deleting a neighbour's gigabyte. Never touches a FINISHED file:
     * pause keeps its `.part` on purpose and returns down a different branch.
     */
    private fun deletePartialsFor(dir: File, lastPath: String?) {
        val tag = lastPath?.let { idTagOf(File(it).name) } ?: return
        try {
            dir.listFiles()?.forEach { f ->
                if (f.isFile && isIntermediate(f.name) && f.name.contains(tag)) {
                    try {
                        f.delete()
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
        }
    }

    private fun newestIn(dir: File): String? = try {
        dir.listFiles()
            ?.filter {
                it.isFile &&
                    !it.name.endsWith(".part") &&
                    !it.name.endsWith(".ytdl") &&
                    !it.name.endsWith(".temp")
            }
            ?.maxByOrNull { it.lastModified() }
            ?.absolutePath
    } catch (_: Throwable) {
        null
    }

    /**
     * The file THIS job produced — never a concurrent job's.
     *
     * newestIn() returns the newest file in the SHARED folder, which was wrong
     * the moment downloads began running three at a time: a job whose own
     * reported path had gone stale (an intermediate that was merged then
     * deleted) fell through to it and picked up whatever a CONCURRENT job had
     * just written, pairing this job's title with that job's video. Resolution
     * is now scoped by the `[id]` tag in the name — unique to this clip: the
     * exact path yt-dlp last reported when it still exists and is final, else
     * the newest FINISHED file whose name carries the same tag. newestIn stays
     * only as a last resort, for the rare case where yt-dlp announced no
     * destination at all (so there is no tag to scope by).
     */
    private fun finalFor(lastPath: String?, dir: File): String? {
        if (lastPath != null) {
            val f = File(lastPath)
            if (f.exists() && !isIntermediate(f.name)) return lastPath
            val tag = idTagOf(f.name)
            if (tag != null) {
                val match = try {
                    dir.listFiles()
                        ?.filter {
                            it.isFile && !isIntermediate(it.name) && it.name.contains(tag)
                        }
                        ?.maxByOrNull { it.lastModified() }
                } catch (_: Throwable) {
                    null
                }
                if (match != null) return match.absolutePath
            }
        }
        return newestIn(dir)
    }

    /**
     * The last `[...]` group in a name — the per-clip id this engine writes into
     * every output name. Returned WITH its brackets so a substring match cannot
     * confuse `[ab]` with `[abc]`. Null when the name has no usable tag (an
     * empty `[]`, or none at all), which sends resolution to its last resort.
     */
    private fun idTagOf(name: String): String? {
        val close = name.lastIndexOf(']')
        if (close <= 0) return null
        val open = name.lastIndexOf('[', close)
        if (open < 0 || close - open < 2) return null
        return name.substring(open, close + 1)
    }

    /**
     * A part-written or pre-merge piece, never the finished result: yt-dlp's
     * own `.part`/`.ytdl`/`.temp`, and its per-format pieces
     * (`title [id].f137.mp4`, `title [id].f251.webm`) that exist only until the
     * merge and would otherwise be mistaken for the output.
     */
    private fun isIntermediate(name: String): Boolean {
        if (name.endsWith(".part") ||
            name.endsWith(".ytdl") ||
            name.endsWith(".temp")
        ) {
            return true
        }
        return Regex("\\.f\\d+\\.[^.]+\$").containsMatchIn(name)
    }

    /**
     * Opens a page inside Innocent instead of handing the person to Chrome.
     *
     * Fire-and-forget like startSignIn: the browser returns its result by
     * SHARING the chosen link back to MainActivity, which is a path that
     * already works and is already instrumented, rather than by an activity
     * result this object would have to plumb through the method channel.
     */
    private fun startBrowser(
        url: String,
        title: String,
        labels: Map<String, String?>
    ): Boolean {
        // The on-screen Activity first — see [activityRef]. Only when there is
        // none does a new task become the right answer rather than a bug.
        val host: Context = activityRef?.get() ?: appContext ?: return false
        return try {
            val intent = Intent(host, BrowserActivity::class.java).apply {
                if (host !is Activity) addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(BrowserActivity.EXTRA_URL, url)
                putExtra(BrowserActivity.EXTRA_TITLE, title)
                // Loop rather than a line each: a label added later cannot be
                // forgotten here, which is exactly how four of them were.
                labels.forEach { (key, value) ->
                    if (!value.isNullOrEmpty()) putExtra(key, value)
                }
            }
            host.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun startSignIn(
        url: String,
        label: String,
        origins: List<String>,
        autoClose: Boolean
    ): Boolean {
        val ctx = appContext ?: return false
        return try {
            val intent = Intent(ctx, SignInWebViewActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                putExtra(SignInWebViewActivity.EXTRA_URL, url)
                putExtra(SignInWebViewActivity.EXTRA_LABEL, label)
                putExtra(
                    SignInWebViewActivity.EXTRA_COOKIE_URLS,
                    origins.toTypedArray()
                )
                putExtra(SignInWebViewActivity.EXTRA_AUTO_CLOSE, autoClose)
            }
            ctx.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }

    private fun deviceStatus(dir: String?): Map<String, Any?> {
        val ctx = appContext
        var online = false
        var unmetered = false
        // WHETHER A VPN IS CARRYING THIS TRAFFIC.
        //
        // Not a curiosity. This user's router blocks the adult sites, so those
        // need a VPN — and YouTube and TikTok then refuse, because a shared
        // exit address is exactly what a bot wall is looking for. Every report
        // from that phone has been ambiguous about which state it was in, and
        // "YouTube does not work" means two completely different things
        // depending on the answer. One line settles it forever.
        var vpn = false
        try {
            val cm = ctx?.getSystemService(Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager
            val network = cm?.activeNetwork
            val caps = if (network == null) null else cm.getNetworkCapabilities(network)
            if (caps != null) {
                online = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                // NOT_METERED is the honest question. Asking "is it Wi-Fi"
                // gets it wrong both ways: a metered hotspot reports Wi-Fi,
                // and an unlimited mobile plan reports cellular.
                unmetered = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                // Android states it as an ABSENCE — a network that is not a
                // VPN carries NOT_VPN. Reading the transport instead misses a
                // VPN that tunnels over Wi-Fi, which is the ordinary case.
                vpn = !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            }
        } catch (_: Throwable) {
        }

        var freeBytes = -1L
        try {
            val target = if (dir.isNullOrBlank()) null else File(dir)
            // The folder may not exist yet, so measure the nearest parent that
            // does — the free space of a filesystem is the same either way.
            var probe = target
            while (probe != null && !probe.exists()) probe = probe.parentFile
            if (probe != null) {
                val stat = StatFs(probe.absolutePath)
                freeBytes = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR2) {
                    stat.availableBytes
                } else {
                    @Suppress("DEPRECATION")
                    stat.availableBlocks.toLong() * stat.blockSize.toLong()
                }
            }
        } catch (_: Throwable) {
        }

        // A download that runs with notifications blocked looks to the user
        // exactly like a download that never started — the foreground service
        // is alive and completely invisible. Worth reporting rather than
        // leaving anyone to guess.
        var notifications = true
        try {
            val ctx2 = appContext
            if (ctx2 != null) {
                notifications = androidx.core.app.NotificationManagerCompat
                    .from(ctx2).areNotificationsEnabled()
            }
        } catch (_: Throwable) {
        }

        return mapOf(
            "online" to online,
            "unmetered" to unmetered,
            "freeBytes" to freeBytes,
            "notifications" to notifications,
            "vpn" to vpn,
            // Carried on the device status because that is where a fact about
            // this phone's network belongs — and because the report is built
            // by a class that never runs a check itself.
            "privateDns" to (lastNetworkAnswer?.get("privateDns") ?: "unknown"),
            "dnsVerdict" to lastDnsVerdict(),
            "bypassRunning" to DnsBypassProxy.isRunning,
            "bypassServed" to DnsBypassProxy.served,
            "bypassRescued" to DnsBypassProxy.rescued
        )
    }

    private fun openExternal(url: String?): Boolean {
        val ctx = appContext ?: return false
        if (url.isNullOrBlank()) return false
        return try {
            ctx.startActivity(
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (_: Throwable) {
            false
        }
    }
}
