package com.innocent.media.net

import java.io.BufferedInputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.net.URLEncoder
import java.security.MessageDigest
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread

/**
 * The player's door to a network file: a loopback HTTP server that answers
 * Range requests from an SMB / FTP / SFTP file, so libmpv seeks a film on a
 * NAS exactly as it seeks one on a web server — and never learns a password.
 *
 *   http://127.0.0.1:<port>/n/<token>/<server id>/<path…>
 *
 * Hardened the way [com.innocent.media.AdbHttpProxy] is (audit_adb.md A2),
 * for the same reason: 127.0.0.1 is reachable by every app on the phone.
 * A secret token in every URL (404 without it, so a guess learns nothing),
 * a cap on connections, bounded request lines and headers, socket timeouts.
 *
 * The token and the port are STABLE across launches (both kept by the
 * caller), so a film's URL is the same tomorrow and the player's resume
 * point and history — keyed by URL — find it again.
 */
class NetRangeServer(
    private val token: String,
    private val preferredPort: Int,
    private val clientFor: (String) -> NetClient?,
    private val onActive: (Int) -> Unit = {},
) {
    @Volatile private var server: ServerSocket? = null
    @Volatile var port: Int = -1
        private set
    private val active = AtomicInteger()

    private val pool = ThreadPoolExecutor(
        1, MAX_CONNECTIONS, 30, TimeUnit.SECONDS, SynchronousQueue(),
        { r -> Thread(r, "net-http").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    ).apply { allowCoreThreadTimeOut(true) }

    @Synchronized
    fun start(): Int {
        server?.takeIf { !it.isClosed }?.let { return port }
        val lo = InetAddress.getByName("127.0.0.1")
        val sock = runCatching { ServerSocket(preferredPort, 50, lo) }.getOrNull()
            ?: ServerSocket(0, 50, lo)
        server = sock
        port = sock.localPort
        thread(isDaemon = true, name = "net-http-accept") {
            while (!sock.isClosed) {
                val c = try { sock.accept() } catch (_: Throwable) { break }
                try {
                    c.soTimeout = SOCKET_TIMEOUT_MS
                    pool.execute { runCatching { handle(c) } }
                } catch (_: Throwable) {
                    runCatching { c.close() }
                }
            }
        }
        return port
    }

    @Synchronized
    fun stop() {
        runCatching { server?.close() }
        server = null
    }

    fun url(serverId: String, path: String): String {
        val p = start()
        val segs = NetPaths.normalize(path).split('/').filter { it.isNotEmpty() }
            .joinToString("/") { enc(it) }
        return "http://127.0.0.1:$p/n/$token/${enc(serverId)}/$segs"
    }

    private fun tokenOk(given: String): Boolean =
        token.isNotEmpty() &&
            MessageDigest.isEqual(given.toByteArray(Charsets.UTF_8), token.toByteArray(Charsets.UTF_8))

    private fun handle(sock: Socket) {
        sock.use { s ->
            val input = BufferedInputStream(s.getInputStream())
            val out = s.getOutputStream()
            val requestLine = readLine(input) ?: return
            val parts = requestLine.split(' ')
            if (parts.size < 2) return status(out, 400, "Bad Request")
            val method = parts[0].uppercase()
            if (method != "GET" && method != "HEAD") return status(out, 405, "Method Not Allowed")
            var range: String? = null
            var headers = 0
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                if (++headers > MAX_HEADERS) return status(out, 431, "Request Header Fields Too Large")
                val i = line.indexOf(':')
                if (i > 0 && line.substring(0, i).trim().equals("range", ignoreCase = true)) {
                    range = line.substring(i + 1).trim()
                }
            }
            // /n/<token>/<id>/<path…>
            val target = parts[1].substringBefore('?')
            val segs = target.split('/')
            if (segs.size < 5 || segs[1] != "n" || !tokenOk(segs[2])) return status(out, 404, "Not Found")
            val id = dec(segs[3])
            val path = "/" + segs.drop(4).joinToString("/") { dec(it) }
            val client = clientFor(id) ?: return status(out, 404, "Not Found")

            val size = try {
                client.size(path)
            } catch (e: NetException) {
                return status(out, if (e.error == NetError.NOT_FOUND) 404 else 502, "Unavailable")
            } catch (_: Throwable) {
                return status(out, 502, "Unavailable")
            }

            var start = 0L
            var end = size - 1
            var partial = false
            val r = range
            if (r != null && r.startsWith("bytes=") && size > 0) {
                val spec = r.removePrefix("bytes=").substringBefore(',').trim()
                val a = spec.substringBefore('-').trim()
                val b = spec.substringAfter('-', "").trim()
                if (a.isEmpty() && b.isNotEmpty()) {
                    start = maxOf(0, size - (b.toLongOrNull() ?: 0))
                } else {
                    start = a.toLongOrNull() ?: 0
                    if (b.isNotEmpty()) end = minOf(b.toLongOrNull() ?: end, size - 1)
                }
                if (start >= size) {
                    out.write(("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */$size\r\n" +
                        "Content-Length: 0\r\nConnection: close\r\n\r\n").toByteArray(Charsets.US_ASCII))
                    return
                }
                partial = true
            }
            val len = if (size == 0L) 0 else end - start + 1
            val head = StringBuilder()
            if (partial) {
                head.append("HTTP/1.1 206 Partial Content\r\n")
                head.append("Content-Range: bytes $start-$end/$size\r\n")
            } else {
                head.append("HTTP/1.1 200 OK\r\n")
            }
            head.append("Content-Type: ").append(contentType(path)).append("\r\n")
            head.append("Accept-Ranges: bytes\r\n")
            head.append("Content-Length: ").append(len).append("\r\n")
            head.append("Connection: close\r\n\r\n")
            out.write(head.toString().toByteArray(Charsets.US_ASCII))
            out.flush()
            if (method == "HEAD" || len == 0L) return

            onActive(active.incrementAndGet())
            try {
                client.open(path, start).use { src -> copy(src, out, len) }
            } catch (_: Throwable) {
                // The player hung up (a seek) or the server did; either way
                // this connection is over, and libmpv asks again if it wants.
            } finally {
                onActive(active.decrementAndGet())
            }
        }
    }

    private fun copy(src: InputStream, out: OutputStream, len: Long) {
        val buf = ByteArray(256 * 1024)
        var left = len
        while (left > 0) {
            val n = src.read(buf, 0, minOf(buf.size.toLong(), left).toInt())
            if (n < 0) break
            out.write(buf, 0, n)
            left -= n
        }
        out.flush()
    }

    /** One header line, never more than [MAX_LINE] bytes buffered. */
    private fun readLine(input: InputStream): String? {
        val sb = StringBuilder()
        while (true) {
            val c = input.read()
            if (c < 0) return if (sb.isEmpty()) null else sb.toString()
            if (c == '\n'.code) return sb.toString()
            if (c == '\r'.code) continue
            if (sb.length >= MAX_LINE) return null
            sb.append(c.toChar())
        }
    }

    private fun status(out: OutputStream, code: Int, msg: String) {
        runCatching {
            out.write("HTTP/1.1 $code $msg\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                .toByteArray(Charsets.US_ASCII))
            out.flush()
        }
    }

    companion object {
        /** libmpv opens a few at once while seeking; FTP takes one per stream. */
        const val MAX_CONNECTIONS = 12
        private const val MAX_HEADERS = 40
        private const val MAX_LINE = 8192
        private const val SOCKET_TIMEOUT_MS = 60_000

        private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8").replace("+", "%20")
        private fun dec(s: String): String = URLDecoder.decode(s.replace("+", "%2B"), "UTF-8")

        fun contentType(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
            "mp4", "m4v" -> "video/mp4"
            "mkv" -> "video/x-matroska"
            "webm" -> "video/webm"
            "mov" -> "video/quicktime"
            "avi" -> "video/x-msvideo"
            "ts", "m2ts", "mts" -> "video/mp2t"
            "flv" -> "video/x-flv"
            "wmv" -> "video/x-ms-wmv"
            "3gp" -> "video/3gpp"
            "mp3" -> "audio/mpeg"
            "m4a", "aac" -> "audio/mp4"
            "flac" -> "audio/flac"
            "ogg", "opus" -> "audio/ogg"
            "wav" -> "audio/wav"
            "srt" -> "application/x-subrip"
            "vtt" -> "text/vtt"
            "ass", "ssa" -> "text/x-ssa"
            "jpg", "jpeg" -> "image/jpeg"
            "png" -> "image/png"
            else -> "application/octet-stream"
        }
    }
}
