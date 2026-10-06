package com.innocent.media.net

import com.hierynomus.msdtyp.AccessMask
import com.hierynomus.mserref.NtStatus
import com.hierynomus.msfscc.FileAttributes
import com.hierynomus.mssmb.SMB1NotSupportedException
import com.hierynomus.mssmb2.SMB2CreateDisposition
import com.hierynomus.mssmb2.SMB2CreateOptions
import com.hierynomus.mssmb2.SMB2ShareAccess
import com.hierynomus.mssmb2.SMBApiException
import com.hierynomus.msfscc.fileinformation.FileStandardInformation
import com.hierynomus.security.bc.BCSecurityProvider
import com.hierynomus.smbj.SMBClient
import com.hierynomus.smbj.SmbConfig
import com.hierynomus.smbj.auth.AuthenticationContext
import com.hierynomus.smbj.connection.Connection
import com.hierynomus.smbj.session.Session
import com.hierynomus.smbj.share.DiskShare
import com.hierynomus.smbj.share.File
import java.io.IOException
import java.io.InputStream
import java.util.EnumSet
import java.util.Properties
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/**
 * SMB 2.0.2 – 3.1.1 through smbj, with jcifs-ng beside it for the two things
 * smbj cannot do: list a server's shares (srvsvc NetShareEnum) and talk to an
 * SMB1-only box. Windows 10/11, macOS, every NAS made since ~2015 and Samba 4
 * all speak SMB2+, so smbj carries the files; old routers' USB shares and
 * Windows XP-era machines fall through to [JcifsNet].
 *
 * smbj is pinned at 0.11.5 on purpose: 0.12.0 broke anonymous / guest logins
 * (hierynomus/smbj#792), still open in 0.14 — and "Connect Anonymously" is
 * the box MX ticks by default.
 *
 * Paths are "/share/dir/file". "/" is the server: its share list.
 */
class SmbNet private constructor(
    override val spec: NetSpec,
    private val client: SMBClient,
    private val connection: Connection,
    private val session: Session,
    private val auth: AuthenticationContext,
) : NetClient {

    override val fingerprint: String? = null

    private val shares = ConcurrentHashMap<String, DiskShare>()

    /** Lazily, for the share list only. */
    @Volatile private var lister: JcifsNet? = null

    /** Bytes per request: the server's own ceiling, capped at 1 MiB. */
    private val chunk: Int =
        connection.negotiatedProtocol.maxReadSize.coerceIn(64 * 1024, 1024 * 1024)

    override fun home(): String = NetPaths.normalize(spec.path)

    override fun isAlive(): Boolean = connection.isConnected

    private fun split(path: String): Pair<String, String> {
        val n = NetPaths.normalize(path).removePrefix("/")
        val share = n.substringBefore('/')
        val rest = if (n.contains('/')) n.substringAfter('/').replace('/', '\\') else ""
        return share to rest
    }

    private fun share(name: String): DiskShare = shares[name] ?: synchronized(shares) {
        shares[name]?.takeIf { it.isConnected } ?: run {
            val s = try {
                session.connectShare(name)
            } catch (e: SMBApiException) {
                throw smbError(e, "\\\\${spec.host}\\$name")
            } catch (t: Throwable) {
                throw classify(t, "share $name")
            }
            if (s !is DiskShare) {
                runCatching { s.close() }
                throw NetException(NetError.NOT_FOUND, "$name is not a folder share")
            }
            shares[name] = s
            s
        }
    }

    override fun list(path: String): List<NetEntry> {
        val (shareName, rest) = split(path)
        if (shareName.isEmpty()) return listShares()
        val share = share(shareName)
        val dir = NetPaths.normalize(path)
        return try {
            share.list(rest).mapNotNull { info ->
                val name = info.fileName
                if (name == "." || name == "..") return@mapNotNull null
                val attrs = info.fileAttributes
                if (attrs and FileAttributes.FILE_ATTRIBUTE_HIDDEN.value != 0L &&
                    attrs and FileAttributes.FILE_ATTRIBUTE_SYSTEM.value != 0L
                ) return@mapNotNull null // desktop.ini, $RECYCLE.BIN, …
                val isDir = attrs and FileAttributes.FILE_ATTRIBUTE_DIRECTORY.value != 0L
                NetEntry(
                    name = name,
                    path = NetPaths.join(dir, name),
                    dir = isDir,
                    size = if (isDir) 0 else info.endOfFile,
                    modified = info.lastWriteTime.toEpochMillis(),
                )
            }
        } catch (e: SMBApiException) {
            throw smbError(e, dir)
        } catch (t: Throwable) {
            throw classify(t, dir)
        }
    }

    private fun listShares(): List<NetEntry> {
        val l = lister ?: synchronized(this) {
            lister ?: JcifsNet.connect(spec, smb1 = false, probe = false).also { lister = it }
        }
        return l.list("/")
    }

    override fun size(path: String): Long {
        val (shareName, rest) = split(path)
        try {
            return share(shareName)
                .getFileInformation(rest, FileStandardInformation::class.java)
                .endOfFile
        } catch (e: SMBApiException) {
            throw smbError(e, path)
        } catch (t: Throwable) {
            throw classify(t, path)
        }
    }

    override fun open(path: String, offset: Long): InputStream {
        val (shareName, rest) = split(path)
        val file = try {
            share(shareName).openFile(
                rest,
                EnumSet.of(AccessMask.GENERIC_READ),
                null,
                SMB2ShareAccess.ALL,
                SMB2CreateDisposition.FILE_OPEN,
                EnumSet.of(SMB2CreateOptions.FILE_NON_DIRECTORY_FILE),
            )
        } catch (e: SMBApiException) {
            throw smbError(e, path)
        } catch (t: Throwable) {
            throw classify(t, path)
        }
        val length = try {
            file.fileInformation.standardInformation.endOfFile
        } catch (t: Throwable) {
            runCatching { file.close() }
            throw classify(t, path)
        }
        return ReadAheadStream(offset, length, chunk, depth = 4) { buf, off ->
            readFully(file, buf, off)
        }.onClose { runCatching { file.close() } }
    }

    /** One request may come back short; the stream wants whole chunks. */
    private fun readFully(file: File, buf: ByteArray, off: Long): Int {
        var got = 0
        while (got < buf.size) {
            val n = try {
                file.read(buf, off + got, got, buf.size - got)
            } catch (e: SMBApiException) {
                if (e.status == NtStatus.STATUS_END_OF_FILE) -1 else throw smbError(e, "read")
            }
            if (n <= 0) break
            got += n
        }
        return got
    }

    override fun close() {
        runCatching { lister?.close() }
        shares.values.forEach { runCatching { it.close() } }
        runCatching { session.close() }
        runCatching { connection.close(true) }
        runCatching { client.close() }
    }

    companion object {
        fun config(spec: NetSpec): SmbConfig = SmbConfig.builder()
            .withSecurityProvider(BCSecurityProvider())
            .withMultiProtocolNegotiate(true)
            .withSigningRequired(false)
            .withEncryptData(false) // the server can still require it; smbj complies
            .withDfsEnabled(true)
            .withTimeout(spec.timeoutMs.toLong(), TimeUnit.MILLISECONDS)
            .withSoTimeout(spec.timeoutMs.toLong() * 3, TimeUnit.MILLISECONDS)
            .build()

        fun connect(spec: NetSpec): NetClient {
            val client = SMBClient(config(spec))
            val connection = try {
                client.connect(spec.host, spec.effectivePort)
            } catch (t: Throwable) {
                runCatching { client.close() }
                if (isSmb1(t)) return JcifsNet.connect(spec, smb1 = true, probe = true)
                throw classify(t, "${spec.host}:${spec.effectivePort}")
            }
            // Anonymous, the way MX means it: a null session first, then the
            // Guest account — Samba's "map to guest = bad user" takes the
            // first, a Windows box with Guest enabled the second.
            val tries = if (spec.anonymous) {
                listOf(AuthenticationContext.anonymous(), AuthenticationContext.guest())
            } else {
                listOf(AuthenticationContext(spec.user, spec.password.toCharArray(), spec.domain.ifBlank { null }))
            }
            var last: Throwable? = null
            for (auth in tries) {
                try {
                    val session = connection.authenticate(auth)
                    val c = SmbNet(spec, client, connection, session, auth)
                    // Prove the share (if one was given) before saying "connected".
                    val share = c.split(c.home()).first
                    if (share.isNotEmpty()) c.share(share)
                    return c
                } catch (t: Throwable) {
                    last = t
                }
            }
            runCatching { connection.close(true) }
            runCatching { client.close() }
            val e = last!!
            if (e is NetException) throw e
            if (e is SMBApiException) throw smbError(e, spec.host)
            throw classify(e, spec.host)
        }

        private fun isSmb1(t: Throwable): Boolean {
            var c: Throwable? = t
            while (c != null) {
                if (c is SMB1NotSupportedException) return true
                c = c.cause
            }
            return false
        }

        fun smbError(e: SMBApiException, what: String): NetException = when (e.status) {
            NtStatus.STATUS_LOGON_FAILURE, NtStatus.STATUS_PASSWORD_EXPIRED,
            NtStatus.STATUS_ACCOUNT_DISABLED, NtStatus.STATUS_LOGON_TYPE_NOT_GRANTED ->
                NetException(NetError.AUTH, "Sign-in refused", cause = e)
            NtStatus.STATUS_ACCESS_DENIED ->
                NetException(NetError.DENIED, "Access denied: $what", cause = e)
            NtStatus.STATUS_BAD_NETWORK_NAME, NtStatus.STATUS_BAD_NETWORK_PATH,
            NtStatus.STATUS_OBJECT_NAME_NOT_FOUND, NtStatus.STATUS_OBJECT_PATH_NOT_FOUND,
            NtStatus.STATUS_NO_SUCH_FILE, NtStatus.STATUS_NOT_FOUND ->
                NetException(NetError.NOT_FOUND, "Not found: $what", cause = e)
            else -> NetException(NetError.PROTOCOL, "${e.status}: $what", cause = e)
        }
    }
}

/**
 * jcifs-ng: the share list for [SmbNet], and the whole client for an
 * SMB1-only server.
 */
class JcifsNet private constructor(
    override val spec: NetSpec,
    private val ctx: jcifs.CIFSContext,
) : NetClient {

    override val fingerprint: String? = null

    private val base: String = "smb://${hostForUrl(spec.host)}:${spec.effectivePort}"

    private fun url(path: String, dir: Boolean): String {
        val n = NetPaths.normalize(path)
        val enc = n.split('/').filter { it.isNotEmpty() }.joinToString("/")
        return if (enc.isEmpty()) "$base/" else "$base/$enc" + if (dir) "/" else ""
    }

    override fun home(): String = NetPaths.normalize(spec.path)

    override fun isAlive(): Boolean = true

    override fun list(path: String): List<NetEntry> {
        val dir = NetPaths.normalize(path)
        val atRoot = dir == "/"
        return try {
            jcifs.smb.SmbFile(url(dir, true), ctx).use { f ->
                f.listFiles().mapNotNull { c ->
                    c.use {
                        val name = c.name.trimEnd('/')
                        if (atRoot) {
                            // Only folder shares a person browses: no IPC$,
                            // no ADMIN$ / C$, no printers.
                            // getType() can tree-connect to find out, and a
                            // share this account may not open answers that
                            // with "access denied": ask only for printers,
                            // and keep the share when it will not say.
                            if (name.endsWith("$")) return@mapNotNull null
                            val type = runCatching { c.type }.getOrDefault(jcifs.SmbConstants.TYPE_SHARE)
                            if (type == jcifs.SmbConstants.TYPE_PRINTER ||
                                type == jcifs.SmbConstants.TYPE_NAMED_PIPE ||
                                type == jcifs.SmbConstants.TYPE_COMM
                            ) return@mapNotNull null
                            NetEntry(name, "/$name", true, 0, 0)
                        } else {
                            if (c.isHidden && name.startsWith("$")) return@mapNotNull null
                            val isDir = c.isDirectory
                            NetEntry(
                                name, NetPaths.join(dir, name), isDir,
                                if (isDir) 0 else c.length(), c.lastModified(),
                            )
                        }
                    }
                }
            }
        } catch (e: jcifs.smb.SmbAuthException) {
            throw NetException(NetError.AUTH, "Sign-in refused", cause = e)
        } catch (e: jcifs.smb.SmbException) {
            throw jcifsError(e, dir)
        } catch (t: Throwable) {
            throw classify(t, dir)
        }
    }

    override fun size(path: String): Long = try {
        jcifs.smb.SmbFile(url(path, false), ctx).use { it.length() }
    } catch (e: jcifs.smb.SmbException) {
        throw jcifsError(e, path)
    }

    override fun open(path: String, offset: Long): InputStream {
        val f = jcifs.smb.SmbFile(url(path, false), ctx)
        val raf = try {
            jcifs.smb.SmbRandomAccessFile(f, "r")
        } catch (e: jcifs.smb.SmbException) {
            f.close()
            throw jcifsError(e, path)
        }
        val length = raf.length()
        // One handle, one position: reads here are sequential by nature.
        return ReadAheadStream(offset, length, 60 * 1024, depth = 1) { buf, off ->
            synchronized(raf) {
                raf.seek(off)
                var got = 0
                while (got < buf.size) {
                    val n = raf.read(buf, got, buf.size - got)
                    if (n <= 0) break
                    got += n
                }
                got
            }
        }.onClose {
            runCatching { raf.close() }
            runCatching { f.close() }
        }
    }

    override fun close() {
        runCatching { ctx.close() }
    }

    companion object {
        private fun hostForUrl(h: String) = if (h.contains(':') && !h.startsWith("[")) "[$h]" else h

        fun connect(spec: NetSpec, smb1: Boolean, probe: Boolean): JcifsNet {
            val t = spec.timeoutMs
            val p = Properties().apply {
                setProperty("jcifs.smb.client.minVersion", if (smb1) "SMB1" else "SMB202")
                setProperty("jcifs.smb.client.maxVersion", if (smb1) "SMB1" else "SMB311")
                setProperty("jcifs.smb.client.connTimeout", t.toString())
                setProperty("jcifs.smb.client.responseTimeout", (t * 2).toString())
                setProperty("jcifs.smb.client.soTimeout", (t * 3).toString())
                setProperty("jcifs.smb.client.sessionTimeout", (t * 3).toString())
                // Names are typed as addresses or DNS names; no slow WINS /
                // broadcast lookups on every request.
                setProperty("jcifs.resolveOrder", "DNS")
                setProperty("jcifs.netbios.cachePolicy", "600")
                // Old boxes that only know plain NTLM (no NTLMv2).
                if (smb1) setProperty("jcifs.smb.lmCompatibility", "1")
                setProperty("jcifs.smb.client.useExtendedSecurity", "true")
                setProperty("jcifs.smb.client.ipcSigningEnforced", "false")
            }
            val base = jcifs.context.BaseContext(jcifs.config.PropertyConfiguration(p))
            val contexts: List<jcifs.CIFSContext> = if (spec.anonymous) {
                listOf(base.withAnonymousCredentials(), base.withGuestCrendentials())
            } else {
                listOf(base.withCredentials(
                    jcifs.smb.NtlmPasswordAuthenticator(spec.domain.ifBlank { null }, spec.user, spec.password)))
            }
            var last: Throwable? = null
            for (ctx in contexts) {
                val c = JcifsNet(spec, ctx)
                if (!probe) return c
                try {
                    c.list(c.home())
                    return c
                } catch (e: Throwable) {
                    last = e
                }
            }
            runCatching { base.close() }
            throw last as? NetException ?: classify(last!!, spec.host)
        }

        fun jcifsError(e: jcifs.smb.SmbException, what: String): NetException {
            if (e is jcifs.smb.SmbAuthException) return NetException(NetError.AUTH, "Sign-in refused", cause = e)
            return when (e.ntStatus) {
                jcifs.smb.NtStatus.NT_STATUS_LOGON_FAILURE, jcifs.smb.NtStatus.NT_STATUS_ACCOUNT_DISABLED,
                jcifs.smb.NtStatus.NT_STATUS_PASSWORD_EXPIRED, jcifs.smb.NtStatus.NT_STATUS_WRONG_PASSWORD ->
                    NetException(NetError.AUTH, "Sign-in refused", cause = e)
                jcifs.smb.NtStatus.NT_STATUS_ACCESS_DENIED ->
                    NetException(NetError.DENIED, "Access denied: $what", cause = e)
                jcifs.smb.NtStatus.NT_STATUS_BAD_NETWORK_NAME, jcifs.smb.NtStatus.NT_STATUS_OBJECT_NAME_NOT_FOUND,
                jcifs.smb.NtStatus.NT_STATUS_OBJECT_PATH_NOT_FOUND, jcifs.smb.NtStatus.NT_STATUS_NO_SUCH_FILE ->
                    NetException(NetError.NOT_FOUND, "Not found: $what", cause = e)
                else -> classify(e, what)
            }
        }
    }
}
