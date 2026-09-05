package com.innocent.media

import android.content.Context
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * A proxy that lives inside this app and does its own name lookups.
 *
 * ---------------------------------------------------------------------------
 * WHY THIS EXISTS, AND WHY IT IS THE ONLY THING THAT CAN WORK.
 *
 * This phone is caught between two requirements that cannot both be met by
 * switching something on or off. The router answers the adult sites' names
 * with an address that goes nowhere, so those sites need a VPN to be reached
 * at all — and YouTube then refuses, because a shared exit address is exactly
 * what its bot check is looking for. Turning the VPN on fixes one half and
 * breaks the other, every time, in both directions.
 *
 * The measurement in [DownloadEngine.networkCheck] says the block is at the
 * RESOLVER: `www.pornhub.com=sinkhole`, an answer of `127.0.0.1` where a real
 * address should be. Nothing about the route is blocked — only the answer to
 * the question "where is it".
 *
 * So the fix is to stop asking that router. This proxy resolves names over
 * HTTPS instead, opens the connection to the address it gets back, and hands
 * the bytes on untouched. The VPN can stay off, so YouTube stays unchallenged,
 * and the blocked sites open anyway. One problem, one answer, no toggling.
 *
 * ---------------------------------------------------------------------------
 * IT NEVER READS THE TRAFFIC. For `CONNECT` — every https:// page — it opens a
 * plain socket to the resolved address and pipes bytes in both directions
 * without looking. The encryption is between the browser and the site exactly
 * as it would be without us: no certificate is generated, none is installed,
 * and nothing here could decrypt anything if it wanted to. That is not only
 * more private, it is far more robust — there is no certificate to go wrong.
 *
 * NOT AN ANONYMISER. It changes WHICH ADDRESS the phone is told to connect to,
 * and nothing else. The connection still comes from this phone's own address,
 * which is precisely why YouTube remains happy: a VPN would replace that.
 *
 * ---------------------------------------------------------------------------
 * DELIBERATELY IDLE UNTIL IT IS NEEDED. Started only when a measurement has
 * shown a poisoned name AND the person has said yes, because a proxy that
 * carries every byte of every video for no reason is a battery cost with
 * nothing to show for it.
 */
object DnsBypassProxy {

    private const val PREFS = "inno_net"
    private const val KEY_ON = "dns_bypass_on"

    /**
     * Has this phone ever needed the bypass?
     *
     * REMEMBERED, BECAUSE NOBODY SHOULD HAVE TO FIND THE BUTTON TWICE. The
     * person who turned this on did so because a site would not open; the same
     * router will be there tomorrow. Asking again every launch is asking them
     * to solve a solved problem, and the device report showed exactly that —
     * "I do not know which one I pressed, but it worked".
     */
    fun remembered(ctx: Context): Boolean = try {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getBoolean(KEY_ON, false)
    } catch (_: Throwable) {
        false
    }

    private fun remember(ctx: Context, on: Boolean) {
        try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_ON, on).apply()
        } catch (_: Throwable) {
        }
    }

    /**
     * Starts the bypass and writes down that this phone wants it.
     *
     * The one entry point anything else should use. Starting without
     * remembering would mean the next launch begins the whole discovery again.
     */
    fun enable(ctx: Context): Int {
        val opened = start()
        if (opened > 0) remember(ctx, true)
        return opened
    }

    /** Brings it back on a cold start, if this phone has needed it before. */
    fun restore(ctx: Context): Int = if (remembered(ctx)) start() else 0

    fun disable(ctx: Context) {
        remember(ctx, false)
        stop()
    }

    /** The port, or 0 when not running. */
    @Volatile
    var port: Int = 0
        private set

    val isRunning: Boolean get() = port != 0

    private var server: ServerSocket? = null
    private val pool = Executors.newCachedThreadPool()

    /** Resolved addresses, with the moment they were learned. */
    private val cache = ConcurrentHashMap<String, Pair<String, Long>>()
    private const val CACHE_MS = 5 * 60 * 1000L

    /** How many connections this proxy has carried, for the trail. */
    @Volatile
    var served: Int = 0
        private set

    /** How many of those needed the encrypted resolver, for the trail. */
    @Volatile
    var rescued: Int = 0
        private set

    /**
     * Starts listening on the loopback, and says which port.
     *
     * Loopback only — binding anywhere else would put an open proxy on the
     * local network, which is somebody else's phone's problem waiting to
     * happen. Port 0 asks the system for a free one; hard-coding a port is how
     * an app fails to start on the one device where something else has it.
     */
    @Synchronized
    fun start(): Int {
        if (isRunning) return port
        return try {
            val socket = ServerSocket()
            socket.reuseAddress = true
            socket.bind(InetSocketAddress("127.0.0.1", 0), 64)
            server = socket
            port = socket.localPort
            pool.execute { accept(socket) }
            port
        } catch (_: Throwable) {
            port = 0
            0
        }
    }

    @Synchronized
    fun stop() {
        try {
            server?.close()
        } catch (_: Throwable) {
        }
        server = null
        port = 0
        cache.clear()
    }

    private fun accept(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try {
                socket.accept()
            } catch (_: Throwable) {
                return
            }
            pool.execute { serve(client) }
        }
    }

    /**
     * One connection from the browser or the reader.
     *
     * Everything here is best-effort and closes on any doubt: a proxy that
     * hangs onto a broken connection is worse than one that drops it, because
     * the client will retry a drop and wait forever on a hang.
     */
    private fun serve(client: Socket) {
        var upstream: Socket? = null
        try {
            client.soTimeout = 30000
            val input = client.getInputStream()
            val head = readHead(input) ?: return
            val firstLine = head.substringBefore("\r\n")
            val parts = firstLine.split(" ")
            if (parts.size < 3) return

            if (parts[0].equals("CONNECT", ignoreCase = true)) {
                // `CONNECT host:443 HTTP/1.1` — a tunnel, and the only shape
                // that matters here because every one of these sites is https.
                val hostPort = parts[1]
                val host = hostPort.substringBeforeLast(':')
                val targetPort = hostPort.substringAfterLast(':').toIntOrNull() ?: 443
                val ip = resolve(host) ?: return
                upstream = Socket()
                upstream.connect(InetSocketAddress(ip, targetPort), 15000)
                client.getOutputStream().apply {
                    write("HTTP/1.1 200 Connection established\r\n\r\n".toByteArray())
                    flush()
                }
                served++
                pipeBoth(client, upstream)
                return
            }

            // Plain http. The request line already carries the whole address,
            // which origin servers are required to accept, so the bytes go on
            // exactly as they arrived — nothing here rewrites a request.
            val host = hostHeaderOf(head) ?: return
            val ip = resolve(host) ?: return
            upstream = Socket()
            upstream.connect(InetSocketAddress(ip, 80), 15000)
            upstream.getOutputStream().apply {
                write(head.toByteArray())
                flush()
            }
            served++
            pipeBoth(client, upstream)
        } catch (_: Throwable) {
            // Nothing here is worth a crash; the client will retry.
        } finally {
            closeQuietly(client)
            closeQuietly(upstream)
        }
    }

    /** Reads up to the end of the request head, and no further. */
    private fun readHead(input: InputStream): String? {
        val out = StringBuilder()
        var last = 0
        while (out.length < 16384) {
            val b = input.read()
            if (b < 0) return null
            out.append(b.toChar())
            if (b == '\n'.code && last == '\n'.code) break
            if (b != '\r'.code) last = b
            if (out.length >= 4 && out.endsWith("\r\n\r\n")) break
        }
        return out.toString()
    }

    private fun hostHeaderOf(head: String): String? {
        for (line in head.split("\r\n")) {
            if (line.startsWith("Host:", ignoreCase = true)) {
                return line.substringAfter(':').trim().substringBefore(':')
            }
        }
        return null
    }

    /**
     * Where this name really is.
     *
     * THE SYSTEM RESOLVER GETS THE FIRST WORD, and that ordering is the whole
     * design. On a name nobody is interfering with, the phone's own answer is
     * the right one — it is the closest, it is cached, and a site the size of
     * YouTube is served from pools where a distant resolver's answer is a
     * worse address, not a better one. Only when that answer is MISSING or
     * points somewhere that cannot be a real site do we go and ask elsewhere.
     *
     * So this proxy is transparent on a healthy network and only becomes a
     * bypass on the names that are actually being tampered with.
     */
    private fun resolve(host: String): String? {
        val now = System.currentTimeMillis()
        cache[host]?.let { (ip, at) ->
            if (now - at < CACHE_MS) return ip
        }
        val system = DownloadEngine.systemAddresses(host)
        val honest = system.firstOrNull { !DownloadEngine.isNonRoutable(it) }
        if (honest != null) {
            cache[host] = Pair(honest, now)
            return honest
        }
        val overHttps = DownloadEngine.dohAddresses(host).firstOrNull()
        if (overHttps != null) {
            rescued++
            cache[host] = Pair(overHttps, now)
            return overHttps
        }
        return null
    }

    /** Copies in both directions until either side stops. */
    private fun pipeBoth(a: Socket, b: Socket) {
        val one = Thread { copy(a.getInputStream(), b.getOutputStream()) }
        one.start()
        copy(b.getInputStream(), a.getOutputStream())
        try {
            one.join(2000)
        } catch (_: Throwable) {
        }
    }

    private fun copy(from: InputStream, to: OutputStream) {
        val buffer = ByteArray(32 * 1024)
        try {
            while (true) {
                val read = from.read(buffer)
                if (read < 0) break
                to.write(buffer, 0, read)
                to.flush()
            }
        } catch (_: Throwable) {
        }
    }

    private fun closeQuietly(socket: Socket?) {
        try {
            socket?.close()
        } catch (_: Throwable) {
        }
    }
}
