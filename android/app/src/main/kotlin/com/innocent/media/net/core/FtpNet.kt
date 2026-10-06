package com.innocent.media.net

import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketAddress
import java.security.cert.X509Certificate
import java.util.concurrent.ConcurrentLinkedDeque
import javax.net.SocketFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager
import org.apache.commons.net.ftp.FTP
import org.apache.commons.net.ftp.FTPClient
import org.apache.commons.net.ftp.FTPFile
import org.apache.commons.net.ftp.FTPReply
import org.apache.commons.net.ftp.FTPSClient

/**
 * FTP and FTPS (explicit AUTH TLS on 21, implicit on 990) through Apache
 * Commons Net.
 *
 * FTP allows one transfer per control connection, so browsing keeps one
 * connection and every open file gets its own from a small pool — the
 * player opens a second range while the first is still flowing, and a seek
 * is a fresh `REST n` + `RETR` on a spare connection.
 *
 * Three things that make FTP actually work on a phone, all learned the hard
 * way by FileZilla and friends:
 *  - PASSIVE replies often carry the wrong address (the server's private or
 *    container address, 0.0.0.0, a NAT's inside): data always goes to the
 *    host the control connection reached.
 *  - FTPS servers (vsftpd's default, FileZilla Server) refuse a data channel
 *    that does not RESUME the control channel's TLS session. Java opens the
 *    data socket to a new port, so its session cache never matches; the
 *    data socket here is layered under the CONTROL host:port name, which is
 *    the key the cache — OpenJDK's and Android's Conscrypt alike — looks up.
 *  - The control channel's character set is the user's choice (GBK, Big5,
 *    Shift_JIS servers are common), with UTF-8 auto-detected via FEAT.
 */
class FtpNet private constructor(
    override val spec: NetSpec,
    private val browse: FTPClient,
    private val start: String,
    private val mlsd: Boolean,
    override val fingerprint: String?,
) : NetClient {

    private val idle = ConcurrentLinkedDeque<FTPClient>()

    /** Stream connections must meet the certificate browsing met. */
    private val poolSpec = spec.copy(pinned = fingerprint ?: spec.pinned)

    override fun home(): String = start

    override fun isAlive(): Boolean = synchronized(browse) {
        browse.isConnected && runCatching { browse.sendNoOp() }.getOrDefault(false)
    }

    override fun list(path: String): List<NetEntry> = synchronized(browse) {
        val dir = NetPaths.normalize(path)
        val files = try {
            ensure(browse)
            if (mlsd) browse.mlistDir(dir) else browse.listFiles(dir)
        } catch (t: Throwable) {
            throw classify(t, dir)
        }
        if (files == null) throw NetException(NetError.PROTOCOL, "No listing for $dir")
        // An empty LIST is also how vsftpd and others say "no such folder"
        // (226, nothing listed): ask the folder itself.
        if (files.isEmpty()) {
            if (!FTPReply.isPositiveCompletion(browse.replyCode)) throw replyError(browse, dir)
            val exists = try {
                browse.changeWorkingDirectory(dir)
            } catch (t: Throwable) {
                throw classify(t, dir)
            }
            if (!exists) throw NetException(NetError.NOT_FOUND, "Not found: $dir")
        }
        files.mapNotNull { f -> f?.let { entry(dir, it) } }
    }

    private fun entry(dir: String, f: FTPFile): NetEntry? {
        val name = f.name?.substringAfterLast('/') ?: return null
        if (name.isEmpty() || name == "." || name == "..") return null
        val isDir = f.isDirectory || (f.isSymbolicLink && !name.contains('.'))
        return NetEntry(
            name, NetPaths.join(dir, name), isDir,
            if (isDir) 0 else maxOf(f.size, 0),
            f.timestamp?.timeInMillis ?: 0,
        )
    }

    override fun size(path: String): Long = synchronized(browse) {
        val p = NetPaths.normalize(path)
        try {
            ensure(browse)
            browse.getSize(p)?.trim()?.toLongOrNull()?.let { return it }
            if (mlsd) browse.mlistFile(p)?.size?.takeIf { it >= 0 }?.let { return it }
            // Old servers: no SIZE, no MLST — the parent's listing has it.
            val parent = p.substringBeforeLast('/').ifEmpty { "/" }
            val name = NetPaths.name(p)
            val f = (browse.listFiles(parent) ?: emptyArray()).firstOrNull { it?.name == name }
            f?.size?.takeIf { it >= 0 } ?: throw NetException(NetError.NOT_FOUND, "Not found: $p")
        } catch (t: Throwable) {
            throw classify(t, p)
        }
    }

    override fun open(path: String, offset: Long): InputStream {
        val p = NetPaths.normalize(path)
        val c = borrow()
        val raw = try {
            c.setRestartOffset(offset)
            c.retrieveFileStream(p)
        } catch (t: Throwable) {
            discard(c)
            throw classify(t, p)
        }
        if (raw == null) {
            val e = replyError(c, p)
            discard(c)
            throw e
        }
        return object : FilterInputStream(raw) {
            private var done = false
            private var finished = false

            override fun read(): Int = super.read().also { if (it < 0) finished = true }

            override fun read(b: ByteArray, off: Int, len: Int): Int =
                super.read(b, off, len).also { if (it < 0) finished = true }

            override fun close() {
                if (done) return
                done = true
                if (finished) {
                    // Read to the end: the server's 226 lets this
                    // connection go back to the pool.
                    runCatching { raw.close() }
                    val ok = runCatching { c.completePendingCommand() }.getOrDefault(false)
                    if (ok) giveBack(c) else discard(c)
                } else {
                    // Stopped early (a seek): ABOR is ignored by enough
                    // servers that the only certain way out is to hang up.
                    discard(c)
                    runCatching { raw.close() }
                }
            }
        }
    }

    private fun borrow(): FTPClient {
        while (true) {
            val c = idle.pollFirst() ?: return login(poolSpec).first
            if (c.isConnected && runCatching { c.sendNoOp() }.getOrDefault(false)) return c
            discard(c)
        }
    }

    private fun giveBack(c: FTPClient) {
        if (idle.size < MAX_IDLE) idle.addFirst(c) else discard(c)
    }

    private fun discard(c: FTPClient) {
        runCatching { if (c.isConnected) c.disconnect() }
    }

    /** The control connection dropped while idle (servers time out at ~5 min). */
    private fun ensure(c: FTPClient) {
        if (c.isConnected && runCatching { c.sendNoOp() }.getOrDefault(false)) return
        discard(c)
        reconnect(c, poolSpec)
    }

    override fun close() {
        while (true) discard(idle.pollFirst() ?: break)
        runCatching { browse.logout() }
        discard(browse)
    }

    companion object {
        private const val MAX_IDLE = 2

        fun connect(spec: NetSpec): NetClient {
            val (c, fp) = login(spec)
            return try {
                val mlsd = runCatching { c.hasFeature("MLST") }.getOrDefault(false)
                val start = spec.path.takeIf { it.isNotBlank() }?.let { NetPaths.normalize(it) }
                    ?: runCatching { c.printWorkingDirectory() }.getOrNull()?.let { NetPaths.normalize(it) }
                    ?: "/"
                val net = FtpNet(spec, c, start, mlsd, fp)
                // Prove the folder before saying "connected".
                net.list(start)
                net
            } catch (t: Throwable) {
                runCatching { c.disconnect() }
                throw classify(t, spec.host)
            }
        }

        /** A logged-in connection, and the FTPS certificate's fingerprint. */
        fun login(spec: NetSpec): Pair<FTPClient, String?> {
            val c: FTPClient
            val trust: PinningTrust?
            if (spec.protocol == NetProtocol.FTPS) {
                trust = PinningTrust(spec.pinned)
                val ctx = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), null) }
                c = SessionReusingFtps(spec.implicitTls, ctx, trust)
                c.setTrustManager(trust)
                c.setEnabledProtocols(arrayOf("TLSv1.2"))
                // NAS boxes present self-signed certificates for an address,
                // not a name; trust is the pin below, not the name.
                c.setEndpointCheckingEnabled(false)
                c.setHostnameVerifier { _, _ -> true }
            } else {
                trust = null
                c = FTPClient()
            }
            reconnect(c, spec)
            return c to trust?.seen
        }

        fun reconnect(c: FTPClient, spec: NetSpec) {
            val t = spec.timeoutMs
            c.controlEncoding = spec.encoding.ifBlank { "UTF-8" }
            c.setAutodetectUTF8(spec.encoding.equals("UTF-8", ignoreCase = true))
            c.connectTimeout = t
            c.defaultTimeout = t * 2
            @Suppress("DEPRECATION")
            c.setDataTimeout(t * 3)
            c.setListHiddenFiles(false)
            c.setUseEPSVwithIPv4(false)
            c.isRemoteVerificationEnabled = false
            try {
                c.connect(spec.host, spec.effectivePort)
            } catch (t2: Throwable) {
                runCatching { c.disconnect() }
                // A changed certificate is its own answer, whatever the TLS
                // stack wrapped it in.
                (c as? SessionReusingFtps)?.trust?.changed?.let { throw it }
                throw if (t2 is javax.net.ssl.SSLException) {
                    NetException(NetError.TLS, "TLS handshake failed: ${t2.message}", cause = t2)
                } else {
                    classify(t2, "${spec.host}:${spec.effectivePort}")
                }
            }
            if (!FTPReply.isPositiveCompletion(c.replyCode)) {
                val e = NetException(NetError.PROTOCOL, "Server said: ${c.replyString?.trim()}")
                runCatching { c.disconnect() }
                throw e
            }
            // Data always goes back to the host we reached (see the class note).
            val control = c.remoteAddress.hostAddress
            c.setPassiveNatWorkaroundStrategy { control }
            if (c is FTPSClient) {
                c.execPBSZ(0)
                c.execPROT("P")
            }
            val user = if (spec.anonymous || spec.user.isBlank()) "anonymous" else spec.user
            val pass = if (spec.anonymous || spec.user.isBlank()) "guest@innocent" else spec.password
            val ok = try {
                c.login(user, pass)
            } catch (t2: Throwable) {
                runCatching { c.disconnect() }
                throw classify(t2, "login")
            }
            if (!ok) {
                val code = c.replyCode
                runCatching { c.disconnect() }
                throw if (code == 530 || code == 331 || code == 332) {
                    NetException(NetError.AUTH, "Sign-in refused")
                } else {
                    NetException(NetError.PROTOCOL, "Login failed: $code")
                }
            }
            if (spec.encoding.equals("UTF-8", ignoreCase = true)) {
                runCatching { c.sendCommand("OPTS UTF8 ON") }
            }
            c.setFileType(FTP.BINARY_FILE_TYPE)
            if (spec.passive) c.enterLocalPassiveMode() else c.enterLocalActiveMode()
        }

        fun replyError(c: FTPClient, what: String): NetException {
            val code = c.replyCode
            return when (code) {
                550, 450, 553 -> NetException(NetError.NOT_FOUND, "Not found or not allowed: $what")
                530 -> NetException(NetError.AUTH, "Sign-in refused")
                else -> NetException(NetError.PROTOCOL, "Server said: ${c.replyString?.trim()}")
            }
        }
    }
}

/**
 * Accepts the server's certificate the way ssh accepts a host key: whatever
 * it is the first time (self-signed is the norm on a LAN), and only that one
 * afterwards. Encryption against a passive listener, pinning against an
 * active one — which is more than "accept all", the usual FTPS client
 * setting, ever gave.
 */
internal class PinningTrust(private val pinned: String?) : X509TrustManager {
    @Volatile var seen: String? = null
        private set
    @Volatile var changed: NetException? = null
        private set

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
        val leaf = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("no certificate")
        val fp = Fingerprints.sha256(leaf.encoded)
        seen = fp
        if (pinned != null && pinned != fp) {
            val e = NetException(NetError.HOSTKEY_CHANGED, "The server's certificate changed", detail = fp)
            changed = e
            throw java.security.cert.CertificateException("certificate changed", e)
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/**
 * FTPS whose data sockets resume the control connection's TLS session.
 * Commons Net creates the data socket unconnected and then connects it; this
 * factory hands it a socket that, on connect, dials plain TCP and layers TLS
 * on top under the control host:port — the session cache's key — and
 * handshakes there (NET-408, vsftpd's `require_ssl_reuse`).
 */
private class SessionReusingFtps(
    implicit: Boolean,
    private val ctx: SSLContext,
    val trust: PinningTrust,
) : FTPSClient(implicit, ctx) {

    override fun execPROT(prot: String?) {
        super.execPROT(prot)
        if (prot == "P") {
            // The very key the control socket was cached under: Commons
            // Net layers it as (_hostname_, port).
            val host = _hostname_ ?: remoteAddress.hostAddress
            val port = remotePort
            setSocketFactory(object : SocketFactory() {
                override fun createSocket(): Socket = LayeredTlsSocket(ctx, host, port)
                override fun createSocket(h: String?, p: Int): Socket =
                    createSocket().apply { connect(InetSocketAddress(h, p)) }
                override fun createSocket(h: String?, p: Int, la: InetAddress?, lp: Int): Socket =
                    createSocket(h, p)
                override fun createSocket(a: InetAddress?, p: Int): Socket =
                    createSocket().apply { connect(InetSocketAddress(a, p)) }
                override fun createSocket(a: InetAddress?, p: Int, la: InetAddress?, lp: Int): Socket =
                    createSocket(a, p)
            })
        }
    }
}

/**
 * A plain-looking Socket that is TLS inside once connected.
 *
 * The session cache is keyed by (host, port) — and both OpenJDK's
 * SSLSocketImpl and Conscrypt take the port of a LAYERED socket from the
 * socket underneath, not from the port they were given. So the TCP socket
 * underneath answers getPort() with the CONTROL port: the cache then finds
 * the control connection's session and the data channel resumes it.
 */
private class LayeredTlsSocket(
    private val ctx: SSLContext,
    private val sessionHost: String,
    private val sessionPort: Int,
) : Socket() {
    private val raw: Socket = object : Socket() {
        override fun getPort(): Int = if (isConnected) sessionPort else super.getPort()
    }
    @Volatile private var tls: SSLSocket? = null

    override fun connect(endpoint: SocketAddress?) = connect(endpoint, 0)

    override fun connect(endpoint: SocketAddress?, timeout: Int) {
        raw.connect(endpoint, timeout)
        val s = ctx.socketFactory.createSocket(raw, sessionHost, sessionPort, true) as SSLSocket
        s.useClientMode = true
        s.enabledProtocols = arrayOf("TLSv1.2")
        s.soTimeout = raw.soTimeout
        // No startHandshake() here: the server begins TLS on the data
        // channel only once it has the command (LIST / RETR), which Commons
        // Net sends AFTER connecting. The first read or write handshakes.
        tls = s
    }

    private val io: Socket get() = tls ?: raw

    override fun getInputStream(): InputStream = io.getInputStream()
    override fun getOutputStream(): OutputStream = io.getOutputStream()
    override fun setSoTimeout(timeout: Int) { raw.soTimeout = timeout; tls?.soTimeout = timeout }
    override fun getSoTimeout(): Int = raw.soTimeout
    override fun setReceiveBufferSize(size: Int) { raw.receiveBufferSize = size }
    override fun getReceiveBufferSize(): Int = raw.receiveBufferSize
    override fun setSendBufferSize(size: Int) { raw.sendBufferSize = size }
    override fun getSendBufferSize(): Int = raw.sendBufferSize
    override fun setTcpNoDelay(on: Boolean) { raw.tcpNoDelay = on }
    override fun setKeepAlive(on: Boolean) { raw.keepAlive = on }
    override fun setSoLinger(on: Boolean, linger: Int) { raw.setSoLinger(on, linger) }
    override fun isConnected(): Boolean = raw.isConnected
    override fun isClosed(): Boolean = raw.isClosed
    override fun getInetAddress(): InetAddress? = raw.inetAddress
    override fun getPort(): Int = (raw.remoteSocketAddress as? InetSocketAddress)?.port ?: 0
    override fun getLocalAddress(): InetAddress = raw.localAddress
    override fun getLocalPort(): Int = raw.localPort
    override fun getRemoteSocketAddress(): SocketAddress? = raw.remoteSocketAddress
    override fun getLocalSocketAddress(): SocketAddress? = raw.localSocketAddress
    override fun shutdownInput() { io.shutdownInput() }
    override fun shutdownOutput() { io.shutdownOutput() }

    override fun close() {
        runCatching { tls?.close() }
        raw.close()
    }
}
