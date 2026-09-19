package com.innocent.media

import android.content.Context
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import kotlin.concurrent.thread

/**
 * A tiny loopback HTTP server that lets media_kit play a file living inside
 * Android/data without copying the whole thing first. For each request it
 * streams the requested byte range straight off the device over ADB
 * ([AdbManager.streamRange]). It advertises Accept-Ranges and answers Range
 * requests with 206, so libmpv can seek. Bound to 127.0.0.1 only.
 *
 * URL shape: http://127.0.0.1:<port>/f?t=<token>&p=<url-encoded-path>
 *
 * ─── WHY THERE IS A TOKEN AND A PREFIX CHECK (audit_adb.md A2) ───────────
 *
 * This used to take `?p=` as an absolute path with NO restriction: no token,
 * no prefix check, no cap on connections or headers. Everything it serves is
 * read by `stat` and `dd` over the ADB connection, i.e. as uid 2000.
 *
 * `127.0.0.1` is not an app-private address on Android. Any installed
 * application holding INTERNET — a normal permission granted silently at
 * install, which essentially every app has — can connect to it, and finding
 * the port costs seconds (AdbManager.findOpenLocalPorts in this same codebase
 * demonstrates the technique). So while the proxy was up, any app on the phone
 * could read anything the shell user can read, the prize being every other
 * app's Android/data — precisely what Android 11's scoped storage was
 * introduced to take away from apps. streamRange even reconnects on the way,
 * so a request could WAKE the ADB connection rather than needing to catch it
 * live.
 *
 * It was never reachable, because [AdbManager.streamUrl] has no Dart caller
 * and so nothing ever called [ensureStarted]. That is why this is being fixed
 * now rather than after an incident: finishing the wiring is one line, and
 * that line will be called "make Android/data playback instant" and will not
 * go to security review.
 *
 * Four things now stand in the way, and none of them costs a frame:
 *
 *  1. a TOKEN, minted per process start from SecureRandom and compared in
 *     constant time. A caller that has not been handed the URL cannot guess it.
 *  2. a PATH PREFIX check on the RESOLVED path, so even a caller holding the
 *     token can only reach the directories this feature exists for, and
 *     `Android/data/../../../..` is judged on where it lands.
 *  3. a CONNECTION CAP with a bounded pool, so a peer cannot spend the
 *     process's threads by opening sockets.
 *  4. a BOUNDED line reader, a header budget and a socket timeout, so a peer
 *     that connects and then says nothing — or says one endless thing —
 *     cannot hold a thread or the heap.
 *
 * The server still lives for the life of the process, which is deliberate:
 * playback can outlast any one screen and a fresh port per file would be
 * worse. With a per-process token and a prefix check, an always-listening
 * socket is no longer the thing that matters.
 */
object AdbHttpProxy {
    private var server: ServerSocket? = null

    @Volatile
    private var port: Int = -1

    /**
     * Minted once per process start. Callers get it inside the URL from
     * [AdbManager.streamUrl]; nothing else can produce it.
     */
    @Volatile
    private var token: String = ""

    /** The only directories this proxy exists to serve. */
    private const val ALLOWED_PREFIX = "/storage/emulated/0/Android/"

    /**
     * libmpv opens a handful of connections while seeking. Eight is generous
     * for that and small enough that nobody can spend the process's threads.
     */
    private const val MAX_CONNECTIONS = 8

    private const val MAX_HEADERS = 40

    /** Ceiling on ANY single line: the request line and each header. */
    private const val MAX_LINE = 4096
    private const val SOCKET_TIMEOUT_MS = 15_000

    private val pool = java.util.concurrent.ThreadPoolExecutor(
        1,
        MAX_CONNECTIONS,
        30L,
        java.util.concurrent.TimeUnit.SECONDS,
        java.util.concurrent.SynchronousQueue(),
        java.util.concurrent.ThreadPoolExecutor.AbortPolicy(),
    ).apply { allowCoreThreadTimeOut(true) }

    /** The token to put in a URL. Empty until [ensureStarted] has run. */
    fun token(): String = token

    /** Start the server if it isn't running; return the loopback port (or -1). */
    @Synchronized
    fun ensureStarted(context: Context): Int {
        val existing = server
        if (existing != null && !existing.isClosed && port > 0) return port
        val appContext = context.applicationContext
        return try {
            val sock = ServerSocket(0, 50, InetAddress.getByName("127.0.0.1"))
            server = sock
            port = sock.localPort
            token = newToken()
            thread(start = true, isDaemon = true, name = "adb-http") {
                while (!sock.isClosed) {
                    val client = try {
                        sock.accept()
                    } catch (e: Throwable) {
                        break
                    }
                    try {
                        client.soTimeout = SOCKET_TIMEOUT_MS
                        pool.execute {
                            try {
                                handle(appContext, client)
                            } catch (_: Throwable) {
                            }
                        }
                    } catch (_: Throwable) {
                        // Over the cap, or the socket died before we could
                        // configure it. Close it rather than leaking the fd;
                        // libmpv retries.
                        try {
                            client.close()
                        } catch (_: Throwable) {
                        }
                    }
                }
            }
            port
        } catch (e: Throwable) {
            -1
        }
    }

    private fun newToken(): String {
        val bytes = ByteArray(24)
        java.security.SecureRandom().nextBytes(bytes)
        return android.util.Base64.encodeToString(
            bytes,
            android.util.Base64.URL_SAFE or android.util.Base64.NO_WRAP or
                android.util.Base64.NO_PADDING,
        )
    }

    /**
     * Constant-time compare. Loopback makes a timing attack far-fetched, but
     * the correct comparison is one line and the wrong one is a habit.
     */
    private fun tokenOk(given: String?): Boolean {
        val expected = token
        if (expected.isEmpty() || given == null) return false
        return java.security.MessageDigest.isEqual(
            given.toByteArray(Charsets.UTF_8),
            expected.toByteArray(Charsets.UTF_8),
        )
    }

    /**
     * True when [path] is inside the directories this proxy serves.
     *
     * Decided on what the path RESOLVES to, not on how it is spelled, so
     * `Android/data/../../../../data/data/com.bank/x` is rejected.
     *
     * The resolution is done lexically FIRST and by the filesystem second, in
     * that order and not the other way round. `File.getCanonicalPath` has to
     * touch the filesystem and throws when it cannot — and the paths this
     * feature exists for are precisely the ones this app is not allowed to
     * read, which is why they are being fetched over ADB in the first place.
     * Treating that failure as a rejection would turn the whole feature off on
     * the devices it is for. So a canonical answer overrules the lexical one
     * when there is one, and a failure to get one leaves the lexical answer
     * standing rather than becoming a veto.
     */
    fun canServe(path: String): Boolean {
        if (!path.startsWith("/")) return false
        val normal = normalize(path)
        if (!normal.startsWith(ALLOWED_PREFIX)) return false
        return try {
            java.io.File(normal).canonicalPath.startsWith(ALLOWED_PREFIX)
        } catch (_: Throwable) {
            true
        }
    }

    /** Collapse `.` and `..` without consulting the filesystem. */
    private fun normalize(path: String): String {
        val stack = ArrayList<String>()
        for (seg in path.split('/')) {
            when (seg) {
                "", "." -> Unit
                ".." -> if (stack.isNotEmpty()) stack.removeAt(stack.size - 1)
                else -> stack.add(seg)
            }
        }
        return "/" + stack.joinToString("/")
    }

    /**
     * Read one line, refusing to buffer more than [limit] characters.
     *
     * NOT `BufferedReader.readLine`, and not a length check after it returns:
     * readLine reads until it finds a newline with no ceiling at all, so a
     * peer that sends a gigabyte without one gets this process to allocate a
     * gigabyte. Checking the length afterwards is checking the lock once the
     * door is already open.
     *
     * Returns null at end of stream and null on overflow — both mean "stop
     * reading this connection", and the caller drops it either way.
     */
    private fun readBounded(reader: BufferedReader, limit: Int): String? {
        val sb = StringBuilder()
        while (true) {
            val c = reader.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString()
            if (c == '\r'.code) continue
            if (sb.length >= limit) return null
            sb.append(c.toChar())
        }
    }

    private fun handle(context: Context, client: Socket) {
        client.use { sock ->
            val out = sock.getOutputStream()
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            val requestLine = readBounded(reader, MAX_LINE) ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) {
                writeStatus(out, 400, "Bad Request")
                return
            }
            val method = parts[0].uppercase()
            val target = parts[1]

            // Read headers; capture Range only. Bounded, because a peer that
            // keeps sending headers and never sends the blank line would
            // otherwise hold this thread — one of eight — for as long as it
            // likes. The socket timeout catches the peer that says nothing;
            // this catches the one that says too much.
            var range: String? = null
            var headers = 0
            while (true) {
                val line = readBounded(reader, MAX_LINE) ?: break
                if (line.isEmpty()) break
                if (++headers > MAX_HEADERS) {
                    writeStatus(out, 431, "Request Header Fields Too Large")
                    return
                }
                val idx = line.indexOf(':')
                if (idx > 0) {
                    val name = line.substring(0, idx).trim().lowercase()
                    if (name == "range") range = line.substring(idx + 1).trim()
                }
            }

            if (!target.startsWith("/f")) {
                writeStatus(out, 404, "Not Found")
                return
            }
            val q = target.indexOf('?')
            if (q < 0) {
                writeStatus(out, 400, "Bad Request")
                return
            }
            var pathEnc: String? = null
            var given: String? = null
            for (kv in target.substring(q + 1).split("&")) {
                val e = kv.indexOf('=')
                if (e <= 0) continue
                when (kv.substring(0, e)) {
                    "p" -> pathEnc = kv.substring(e + 1)
                    "t" -> given = kv.substring(e + 1)
                }
            }
            // 404 rather than 401 or 403, all the way down: a caller without
            // the token learns nothing from the reply, not even that the path
            // it guessed exists.
            if (!tokenOk(given)) {
                writeStatus(out, 404, "Not Found")
                return
            }
            if (pathEnc == null) {
                writeStatus(out, 400, "Bad Request")
                return
            }
            val srcPath = URLDecoder.decode(pathEnc, "UTF-8")
            if (!canServe(srcPath)) {
                writeStatus(out, 404, "Not Found")
                return
            }
            val size = AdbManager.fileSize(context, srcPath)
            if (size <= 0L) {
                writeStatus(out, 404, "Not Found")
                return
            }
            val ctype = contentType(srcPath)

            var start = 0L
            var end = size - 1
            var partial = false
            val rangeHeader = range
            if (rangeHeader != null && rangeHeader.startsWith("bytes=")) {
                partial = true
                val spec = rangeHeader.substring("bytes=".length)
                val dash = spec.indexOf('-')
                if (dash >= 0) {
                    val s = spec.substring(0, dash).trim()
                    val e = spec.substring(dash + 1).trim()
                    if (s.isNotEmpty()) start = s.toLongOrNull() ?: 0L
                    if (e.isNotEmpty()) end = e.toLongOrNull() ?: (size - 1)
                }
                if (start < 0L) start = 0L
                if (end > size - 1) end = size - 1
                if (start > end) {
                    start = 0L
                    end = size - 1
                }
            }
            val len = end - start + 1

            val sb = StringBuilder()
            if (partial) {
                sb.append("HTTP/1.1 206 Partial Content\r\n")
                sb.append("Content-Range: bytes $start-$end/$size\r\n")
            } else {
                sb.append("HTTP/1.1 200 OK\r\n")
            }
            sb.append("Content-Type: ").append(ctype).append("\r\n")
            sb.append("Accept-Ranges: bytes\r\n")
            sb.append("Content-Length: ").append(len).append("\r\n")
            sb.append("Connection: close\r\n\r\n")
            out.write(sb.toString().toByteArray(Charsets.US_ASCII))
            out.flush()
            if (method == "HEAD") return

            AdbManager.streamRange(context, srcPath, start, len, out)
            try {
                out.flush()
            } catch (_: Throwable) {
            }
        }
    }

    private fun writeStatus(out: OutputStream, code: Int, msg: String) {
        try {
            out.write(
                ("HTTP/1.1 $code $msg\r\nContent-Length: 0\r\n" +
                    "Connection: close\r\n\r\n").toByteArray(Charsets.US_ASCII),
            )
            out.flush()
        } catch (_: Throwable) {
        }
    }

    private fun contentType(path: String): String {
        val lower = path.lowercase()
        return when {
            lower.endsWith(".mp4") || lower.endsWith(".m4v") -> "video/mp4"
            lower.endsWith(".webm") -> "video/webm"
            lower.endsWith(".mkv") -> "video/x-matroska"
            lower.endsWith(".mov") -> "video/quicktime"
            lower.endsWith(".avi") -> "video/x-msvideo"
            lower.endsWith(".3gp") -> "video/3gpp"
            lower.endsWith(".ts") -> "video/mp2t"
            lower.endsWith(".flv") -> "video/x-flv"
            lower.endsWith(".wmv") -> "video/x-ms-wmv"
            else -> "application/octet-stream"
        }
    }
}
