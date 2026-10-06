package com.innocent.media.net

import java.io.InputStream
import java.security.PublicKey
import net.schmizz.sshj.DefaultConfig
import net.schmizz.sshj.SSHClient
import net.schmizz.sshj.common.Buffer
import net.schmizz.sshj.sftp.FileMode
import net.schmizz.sshj.sftp.OpenMode
import net.schmizz.sshj.sftp.RemoteFile
import net.schmizz.sshj.sftp.Response
import net.schmizz.sshj.sftp.SFTPClient
import net.schmizz.sshj.sftp.SFTPException
import net.schmizz.sshj.transport.verification.HostKeyVerifier
import net.schmizz.sshj.userauth.UserAuthException
import net.schmizz.sshj.userauth.method.AuthKeyboardInteractive
import net.schmizz.sshj.userauth.method.AuthMethod
import net.schmizz.sshj.userauth.method.AuthPassword
import net.schmizz.sshj.userauth.method.AuthPublickey
import net.schmizz.sshj.userauth.method.PasswordResponseProvider
import net.schmizz.sshj.userauth.password.PasswordUtils

/**
 * SFTP through sshj: a password (also offered as keyboard-interactive, which
 * is all some servers allow), or an OpenSSH / PEM private key with an
 * optional passphrase — MX's "Login With Private Key".
 *
 * The host key is trusted on first use and pinned (see [NetSpec.pinned]);
 * a changed key is refused with the new fingerprint, so the person can say
 * "yes, I reinstalled the NAS" instead of being silently redirected.
 *
 * Reads go through sshj's read-ahead stream with 16 requests in flight —
 * OpenSSH's own sftp keeps 64; one at a time would cap a stream at a few
 * MB/s on Wi-Fi.
 */
class SftpNet private constructor(
    override val spec: NetSpec,
    private val ssh: SSHClient,
    private val sftp: SFTPClient,
    private val start: String,
    override val fingerprint: String?,
) : NetClient {

    override fun home(): String = start

    override fun isAlive(): Boolean = ssh.isConnected && ssh.isAuthenticated

    override fun list(path: String): List<NetEntry> {
        val dir = NetPaths.normalize(path)
        return try {
            sftp.ls(dir).mapNotNull { r ->
                val name = r.name
                if (name == "." || name == ".." || name.startsWith(".")) return@mapNotNull null
                var attrs = r.attributes
                if (attrs.type == FileMode.Type.SYMLINK) {
                    // Follow it: a link to a folder is a folder to browse.
                    attrs = runCatching { sftp.stat(r.path) }.getOrNull() ?: return@mapNotNull null
                }
                val isDir = attrs.type == FileMode.Type.DIRECTORY
                NetEntry(
                    name, NetPaths.join(dir, name), isDir,
                    if (isDir) 0 else attrs.size, attrs.mtime * 1000,
                )
            }
        } catch (e: SFTPException) {
            throw sftpError(e, dir)
        } catch (t: Throwable) {
            throw classify(t, dir)
        }
    }

    override fun size(path: String): Long = try {
        sftp.stat(NetPaths.normalize(path)).size
    } catch (e: SFTPException) {
        throw sftpError(e, path)
    } catch (t: Throwable) {
        throw classify(t, path)
    }

    override fun open(path: String, offset: Long): InputStream {
        val p = NetPaths.normalize(path)
        val rf: RemoteFile = try {
            sftp.open(p, setOf(OpenMode.READ))
        } catch (e: SFTPException) {
            throw sftpError(e, p)
        } catch (t: Throwable) {
            throw classify(t, p)
        }
        val inner = rf.ReadAheadRemoteFileInputStream(16, offset)
        return object : InputStream() {
            override fun read(): Int = inner.read()
            override fun read(b: ByteArray, off: Int, len: Int): Int = inner.read(b, off, len)
            override fun available(): Int = inner.available()
            override fun close() {
                runCatching { inner.close() }
                runCatching { rf.close() }
            }
        }
    }

    override fun close() {
        runCatching { sftp.close() }
        runCatching { ssh.disconnect() }
    }

    companion object {
        fun connect(spec: NetSpec): NetClient {
            val verifier = PinningVerifier(spec.pinned)
            val ssh = SSHClient(DefaultConfig())
            ssh.addHostKeyVerifier(verifier)
            ssh.connectTimeout = spec.timeoutMs
            ssh.timeout = spec.timeoutMs * 3
            try {
                ssh.connect(spec.host, spec.effectivePort)
            } catch (t: Throwable) {
                runCatching { ssh.disconnect() }
                verifier.changed?.let { throw it }
                throw classify(t, "${spec.host}:${spec.effectivePort}")
            }
            try {
                ssh.auth(spec.user.ifBlank { "anonymous" }, methods(ssh, spec))
            } catch (e: UserAuthException) {
                runCatching { ssh.disconnect() }
                throw NetException(NetError.AUTH, "Sign-in refused", cause = e)
            } catch (t: Throwable) {
                runCatching { ssh.disconnect() }
                throw t as? NetException ?: classify(t, "login")
            }
            try {
                val sftp = ssh.newSFTPClient()
                val start = if (spec.path.isNotBlank()) {
                    NetPaths.normalize(spec.path)
                } else {
                    NetPaths.normalize(sftp.canonicalize("."))
                }
                val c = SftpNet(spec, ssh, sftp, start, verifier.seen)
                c.list(start)
                return c
            } catch (t: Throwable) {
                runCatching { ssh.disconnect() }
                throw t as? NetException ?: classify(t, "sftp")
            }
        }

        private fun methods(ssh: SSHClient, spec: NetSpec): List<AuthMethod> {
            val key = spec.privateKey?.trim()?.takeIf { it.isNotEmpty() }
            if (key != null) {
                val kp = try {
                    val finder = spec.passphrase?.takeIf { it.isNotEmpty() }
                        ?.let { PasswordUtils.createOneOff(it.toCharArray()) }
                    ssh.loadKeys(key, null, finder).also { it.private } // decrypts now
                } catch (t: Throwable) {
                    throw NetException(NetError.BAD_KEY, "Private key could not be read: ${t.message}", cause = t)
                }
                return listOf(AuthPublickey(kp))
            }
            val pw = spec.password
            return listOf(
                AuthPassword(PasswordUtils.createOneOff(pw.toCharArray())),
                AuthKeyboardInteractive(PasswordResponseProvider(PasswordUtils.createOneOff(pw.toCharArray()))),
            )
        }

        fun sftpError(e: SFTPException, what: String): NetException = when (e.statusCode) {
            Response.StatusCode.NO_SUCH_FILE, Response.StatusCode.NO_SUCH_PATH ->
                NetException(NetError.NOT_FOUND, "Not found: $what", cause = e)
            Response.StatusCode.PERMISSION_DENIED ->
                NetException(NetError.DENIED, "Access denied: $what", cause = e)
            else -> NetException(NetError.PROTOCOL, "${e.statusCode}: $what", cause = e)
        }
    }
}

private class PinningVerifier(private val pinned: String?) : HostKeyVerifier {
    @Volatile var seen: String? = null
    @Volatile var changed: NetException? = null

    override fun verify(hostname: String?, port: Int, key: PublicKey): Boolean {
        val fp = Fingerprints.sha256(Buffer.PlainBuffer().putPublicKey(key).compactData)
        seen = fp
        if (pinned != null && pinned != fp) {
            changed = NetException(NetError.HOSTKEY_CHANGED, "The server's host key changed", detail = fp)
            return false
        }
        return true
    }

    override fun findExistingAlgorithms(hostname: String?, port: Int): List<String> = emptyList()
}
