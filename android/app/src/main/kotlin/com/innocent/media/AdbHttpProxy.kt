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
 * URL shape: http://127.0.0.1:<port>/f?p=<url-encoded-absolute-path>
 */
object AdbHttpProxy {
    private var server: ServerSocket? = null

    @Volatile
    private var port: Int = -1

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
            thread(start = true, isDaemon = true, name = "adb-http") {
                while (!sock.isClosed) {
                    val client = try {
                        sock.accept()
                    } catch (e: Throwable) {
                        break
                    }
                    thread(start = true, isDaemon = true, name = "adb-http-conn") {
                        try {
                            handle(appContext, client)
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

    private fun handle(context: Context, client: Socket) {
        client.use { sock ->
            val out = sock.getOutputStream()
            val reader = BufferedReader(InputStreamReader(sock.getInputStream()))
            val requestLine = reader.readLine() ?: return
            val parts = requestLine.split(" ")
            if (parts.size < 2) {
                writeStatus(out, 400, "Bad Request")
                return
            }
            val method = parts[0].uppercase()
            val target = parts[1]

            // Read headers; capture Range only.
            var range: String? = null
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
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
            for (kv in target.substring(q + 1).split("&")) {
                val e = kv.indexOf('=')
                if (e > 0 && kv.substring(0, e) == "p") {
                    pathEnc = kv.substring(e + 1)
                    break
                }
            }
            if (pathEnc == null) {
                writeStatus(out, 400, "Bad Request")
                return
            }
            val srcPath = URLDecoder.decode(pathEnc, "UTF-8")
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
