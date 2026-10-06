package com.innocent.media.net

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.MessageDigest
import javax.net.ssl.SSLException

/*
 * LOCAL NETWORK — the core (MX Player's Me → Local Network: SMB, FTP, FTPS,
 * SFTP). Plain JVM on purpose: nothing in this folder imports android.*, so
 * tool/netlab builds the very same files on a desktop JVM and runs them
 * against real Samba, vsftpd and OpenSSH servers. NetPlugin.kt is the only
 * Android-side glue.
 *
 * The libraries are the ones the Android open-source file managers settled
 * on after years in the field (Material Files): smbj for SMB 2/3, jcifs-ng
 * for listing a server's shares and for SMB1-only boxes (old routers' USB
 * shares), Apache Commons Net for FTP/FTPS, sshj for SFTP — all over one
 * full BouncyCastle (NetSecurity.kt).
 */

enum class NetProtocol(val defaultPort: Int) {
    SMB(445), FTP(21), FTPS(21), SFTP(22);

    companion object {
        fun parse(s: String): NetProtocol = valueOf(s.uppercase())
    }
}

/** One saved server, as the add-server form describes it. */
data class NetSpec(
    val protocol: NetProtocol,
    val host: String,
    val port: Int = 0,
    /** SMB: "share" or "share/sub/dir"; FTP/SFTP: the folder to start in. */
    val path: String = "",
    val user: String = "",
    val password: String = "",
    val domain: String = "",
    val anonymous: Boolean = false,
    /** FTP/FTPS: passive (the default, and what works through NAT). */
    val passive: Boolean = true,
    /** FTP/FTPS: the control connection's character set. */
    val encoding: String = "UTF-8",
    /** FTPS: implicit TLS (port 990) instead of explicit AUTH TLS. */
    val implicitTls: Boolean = false,
    /** SFTP: an OpenSSH / PEM private key, used instead of the password. */
    val privateKey: String? = null,
    val passphrase: String? = null,
    /**
     * The server's identity as first seen (SFTP host key, FTPS certificate),
     * "SHA256:<base64>". Null on the first connection; a different one later
     * is refused as [NetError.HOSTKEY_CHANGED] — trust on first use, the way
     * ssh itself does it.
     */
    val pinned: String? = null,
    val timeoutMs: Int = 12_000,
    /** The saved server's id (Dart's); names its session and its URLs. */
    val id: String = "",
) {
    val effectivePort: Int get() = if (port > 0) port else when {
        protocol == NetProtocol.FTPS && implicitTls -> 990
        else -> protocol.defaultPort
    }
}

data class NetEntry(
    val name: String,
    /** Absolute in this client's own namespace, "/"-separated. */
    val path: String,
    val dir: Boolean,
    val size: Long,
    /** Epoch millis, 0 when the server does not say. */
    val modified: Long,
)

/** Every failure the UI can explain in words, rather than a stack trace. */
enum class NetError(val code: String) {
    UNREACHABLE("unreachable"),   // no route, unknown host, nothing listening
    TIMEOUT("timeout"),
    AUTH("auth"),                 // wrong user name or password, or no guest
    DENIED("denied"),             // logged in, but not allowed there
    NOT_FOUND("not_found"),       // share / folder / file
    TLS("tls"),                   // FTPS handshake
    HOSTKEY_CHANGED("hostkey_changed"),
    BAD_KEY("bad_key"),           // SFTP private key unreadable / passphrase
    PROTOCOL("protocol"),         // spoke, but not the protocol asked for
    CANCELLED("cancelled"),
}

class NetException(
    val error: NetError,
    message: String,
    /** HOSTKEY_CHANGED: the new fingerprint, so the UI can offer to trust it. */
    val detail: String? = null,
    cause: Throwable? = null,
) : IOException(message, cause)

interface NetClient : Closeable {
    val spec: NetSpec

    /** The server identity seen on connect ("SHA256:…"), for pinning. */
    val fingerprint: String?

    /** Where browsing starts. */
    fun home(): String

    fun list(path: String): List<NetEntry>

    fun size(path: String): Long

    /** The file from [offset] to its end. Close it early to stop. */
    fun open(path: String, offset: Long): InputStream

    /** Cheap liveness check, for reusing a pooled client. */
    fun isAlive(): Boolean
}

object NetClients {
    /** Connects and logs in, or throws [NetException]. */
    fun connect(spec: NetSpec): NetClient {
        NetSecurity.install()
        return when (spec.protocol) {
            NetProtocol.SMB -> SmbNet.connect(spec)
            NetProtocol.FTP, NetProtocol.FTPS -> FtpNet.connect(spec)
            NetProtocol.SFTP -> SftpNet.connect(spec)
        }
    }
}

internal object NetPaths {
    fun join(dir: String, name: String): String =
        if (dir.endsWith("/")) dir + name else "$dir/$name"

    fun normalize(path: String): String {
        val out = ArrayList<String>()
        for (seg in path.replace('\\', '/').split('/')) {
            when (seg) {
                "", "." -> {}
                ".." -> if (out.isNotEmpty()) out.removeAt(out.size - 1)
                else -> out.add(seg)
            }
        }
        return "/" + out.joinToString("/")
    }

    fun name(path: String): String = path.trimEnd('/').substringAfterLast('/')
}

internal object Fingerprints {
    // BouncyCastle's Base64, not java.util's: that one is API 26, and the
    // app runs from API 24.
    fun sha256(bytes: ByteArray): String =
        "SHA256:" + org.bouncycastle.util.encoders.Base64
            .toBase64String(MessageDigest.getInstance("SHA-256").digest(bytes))
            .trimEnd('=')
}

/**
 * Maps whatever a library threw onto [NetError]. Each library has its own
 * vocabulary for "wrong password"; the specific ones are decided where they
 * are thrown, and this is the common floor under them.
 */
internal fun classify(t: Throwable, what: String): NetException {
    if (t is NetException) return t
    var c: Throwable? = t
    while (c != null) {
        when (c) {
            is SocketTimeoutException ->
                return NetException(NetError.TIMEOUT, "$what: timed out", cause = t)
            is UnknownHostException, is NoRouteToHostException, is ConnectException ->
                return NetException(NetError.UNREACHABLE, "$what: ${c.message}", cause = t)
            is SSLException ->
                return NetException(NetError.TLS, "$what: ${c.message}", cause = t)
            is InterruptedException ->
                return NetException(NetError.CANCELLED, "$what: cancelled", cause = t)
        }
        c = c.cause
    }
    return NetException(NetError.PROTOCOL, "$what: ${t.message ?: t.javaClass.simpleName}", cause = t)
}
