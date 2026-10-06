import com.innocent.media.net.FtpNet
import com.innocent.media.net.NetClient
import com.innocent.media.net.NetClients
import com.innocent.media.net.NetError
import com.innocent.media.net.NetException
import com.innocent.media.net.NetProtocol
import com.innocent.media.net.NetRangeServer
import com.innocent.media.net.NetScan
import com.innocent.media.net.NetSpec
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * The Local Network core against real servers (tool/netlab/servers.sh):
 * Samba 4 (SMB2/3 + an SMB1-only instance), vsftpd (FTP, FTPS explicit with
 * require_ssl_reuse, FTPS implicit) and OpenSSH (SFTP: password, ed25519,
 * passphrase-protected RSA PEM).
 */
class NetLabTest {
    private val host = System.getenv("NETLAB_HOST") ?: "127.0.0.1"
    private val state = File(System.getenv("NETLAB_STATE") ?: "/tmp/netlab")
    private val media = File(state, "media")
    private val film = File(media, "Movies/film.mkv").readBytes()

    private fun spec(p: NetProtocol, port: Int, block: NetSpec.() -> NetSpec = { this }) =
        NetSpec(p, host, port, user = "netlab", password = "netlab-pass", timeoutMs = 5000).block()

    private fun expectError(e: NetError, f: () -> Unit) {
        try {
            f()
            fail("expected $e")
        } catch (x: NetException) {
            assertEquals(e, x.error, "got ${x.error}: ${x.message}")
        }
    }

    /** Reads [len] bytes at [off] and compares them with the file on disk. */
    private fun checkRange(c: NetClient, path: String, off: Long, len: Int) {
        c.open(path, off).use { s ->
            val got = ByteArray(len)
            var n = 0
            while (n < len) {
                val r = s.read(got, n, len - n)
                if (r < 0) break
                n += r
            }
            assertEquals(len, n, "short read at $off")
            assertContentEquals(film.copyOfRange(off.toInt(), off.toInt() + len), got, "bytes at $off")
        }
    }

    /** The whole file, start to end, through the stream. */
    private fun checkWhole(c: NetClient, path: String) {
        val got = c.open(path, 0).use { it.readBytes() }
        assertEquals(film.size, got.size)
        assertContentEquals(film, got)
    }

    private fun browseAndRead(c: NetClient, movies: String) {
        val names = c.list(movies).associateBy { it.name }
        assertTrue("film.mkv" in names, "listing: ${names.keys}")
        assertTrue(names.getValue("Sub dir").dir)
        assertEquals(film.size.toLong(), names.getValue("film.mkv").size)
        val sub = c.list("$movies/Sub dir").map { it.name }.toSet()
        assertTrue("space name.mp4" in sub && "ငါ့ဇာတ်ကား.mp4" in sub, "sub: $sub")
        assertEquals(film.size.toLong(), c.size("$movies/film.mkv"))
        checkRange(c, "$movies/film.mkv", 0, 4096)
        checkRange(c, "$movies/film.mkv", 3_333_333, 1_500_000) // spans chunks
        checkRange(c, "$movies/Sub dir/space name.mp4", film.size - 10L, 10) // the tail
        checkWhole(c, "$movies/film.mkv")
        expectError(NetError.NOT_FOUND) { c.list("$movies/nope") }
    }

    // ── SMB ──────────────────────────────────────────────────────────────

    @Test fun smbAnonymousListsSharesAndReads() {
        NetClients.connect(spec(NetProtocol.SMB, 445) { copy(anonymous = true, user = "", password = "") }).use { c ->
            assertEquals("/", c.home())
            val shares = c.list("/").map { it.name }.toSet()
            assertTrue("public" in shares && "private" in shares, "shares: $shares")
            assertTrue(shares.none { it.endsWith("$") }, "hidden shares leaked: $shares")
            browseAndRead(c, "/public/Movies")
        }
    }

    @Test fun smbAccountWithSharePath() {
        NetClients.connect(spec(NetProtocol.SMB, 445) { copy(path = "private/Movies") }).use { c ->
            assertEquals("/private/Movies", c.home())
            browseAndRead(c, c.home())
        }
    }

    @Test fun smbWrongPasswordIsAuth() = expectError(NetError.AUTH) {
        NetClients.connect(spec(NetProtocol.SMB, 445) { copy(password = "wrong") }).close()
    }

    @Test fun smbMissingShareIsNotFound() = expectError(NetError.NOT_FOUND) {
        NetClients.connect(spec(NetProtocol.SMB, 445) { copy(path = "nosuchshare") }).close()
    }

    @Test fun smbNothingListeningIsUnreachable() = expectError(NetError.UNREACHABLE) {
        NetClients.connect(spec(NetProtocol.SMB, 4459)).close()
    }

    @Test fun smb1OnlyServerFallsBackToJcifs() {
        NetClients.connect(spec(NetProtocol.SMB, 4451) { copy(anonymous = true, user = "", password = "") }).use { c ->
            assertEquals("JcifsNet", c.javaClass.simpleName)
            assertTrue("public" in c.list("/").map { it.name })
            browseAndRead(c, "/public/Movies")
        }
        NetClients.connect(spec(NetProtocol.SMB, 4451) { copy(path = "private") }).use { c ->
            checkRange(c, "/private/Movies/film.mkv", 1_000_000, 70_000)
        }
    }

    // ── FTP / FTPS ───────────────────────────────────────────────────────

    @Test fun ftpAnonymous() {
        NetClients.connect(spec(NetProtocol.FTP, 2121) { copy(anonymous = true) }).use { c ->
            browseAndRead(c, "/Movies")
        }
    }

    @Test fun ftpAccountPassiveAndActive() {
        for (passive in listOf(true, false)) {
            NetClients.connect(spec(NetProtocol.FTP, 2121) { copy(passive = passive) }).use { c ->
                browseAndRead(c, "/Movies")
            }
        }
    }

    @Test fun ftpWrongPasswordIsAuth() = expectError(NetError.AUTH) {
        NetClients.connect(spec(NetProtocol.FTP, 2121) { copy(password = "wrong") }).close()
    }

    @Test fun ftpGbkNames() {
        NetClients.connect(spec(NetProtocol.FTP, 2121) { copy(encoding = "GBK") }).use { c ->
            val names = c.list("/Movies").map { it.name }
            assertTrue("中文.mp4" in names, "GBK listing: $names")
            assertEquals(1234L, c.size("/Movies/中文.mp4"))
        }
    }

    @Test fun ftpParallelStreamsUseTheirOwnConnections() {
        NetClients.connect(spec(NetProtocol.FTP, 2121)).use { c ->
            val pool = Executors.newFixedThreadPool(4)
            val jobs = (0 until 4).map { i ->
                pool.submit { checkRange(c, "/Movies/film.mkv", i * 1_000_000L, 900_000) }
            }
            jobs.forEach { it.get(60, TimeUnit.SECONDS) }
            pool.shutdown()
            // A stream abandoned half way (a seek) must not poison the pool.
            c.open("/Movies/film.mkv", 0).use { it.read(ByteArray(10)) }
            checkRange(c, "/Movies/film.mkv", 5_000_000, 1000)
        }
    }

    @Test fun ftpsExplicitWithRequiredSessionReuse() {
        val first = NetClients.connect(spec(NetProtocol.FTPS, 2122)).use { c ->
            assertNotNull(c.fingerprint)
            browseAndRead(c, "/Movies")
            c.fingerprint!!
        }
        // Same certificate: fine. A different pin: refused, with the new one.
        NetClients.connect(spec(NetProtocol.FTPS, 2122) { copy(pinned = first) }).close()
        try {
            NetClients.connect(spec(NetProtocol.FTPS, 2122) { copy(pinned = "SHA256:somethingelse") }).close()
            fail("pin mismatch accepted")
        } catch (e: NetException) {
            assertEquals(NetError.HOSTKEY_CHANGED, e.error, e.message)
            assertEquals(first, e.detail)
        }
    }

    @Test fun ftpsImplicit() {
        NetClients.connect(spec(NetProtocol.FTPS, 9900) { copy(implicitTls = true) }).use { c ->
            browseAndRead(c, "/Movies")
        }
    }

    // ── SFTP ─────────────────────────────────────────────────────────────

    private val home = "/tmp/netlab/media"

    @Test fun sftpPassword() {
        NetClients.connect(spec(NetProtocol.SFTP, 2222) { copy(path = home) }).use { c ->
            assertNotNull(c.fingerprint)
            browseAndRead(c, "$home/Movies")
        }
    }

    @Test fun sftpEd25519Key() {
        val key = File(state, "keys/user_ed25519").readText()
        NetClients.connect(spec(NetProtocol.SFTP, 2222) { copy(password = "", privateKey = key) }).use { c ->
            checkRange(c, "$home/Movies/film.mkv", 123_456, 100_000)
        }
    }

    @Test fun sftpRsaPemKeyWithPassphrase() {
        val key = File(state, "keys/user_rsa").readText()
        NetClients.connect(spec(NetProtocol.SFTP, 2222) {
            copy(password = "", privateKey = key, passphrase = "key-pass")
        }).use { c -> checkRange(c, "$home/Movies/film.mkv", 0, 1000) }
        expectError(NetError.BAD_KEY) {
            NetClients.connect(spec(NetProtocol.SFTP, 2222) {
                copy(password = "", privateKey = key, passphrase = "wrong")
            }).close()
        }
    }

    @Test fun sftpWrongPasswordIsAuth() = expectError(NetError.AUTH) {
        NetClients.connect(spec(NetProtocol.SFTP, 2222) { copy(password = "wrong") }).close()
    }

    @Test fun sftpHostKeyPinned() {
        val fp = NetClients.connect(spec(NetProtocol.SFTP, 2222)).use { it.fingerprint!! }
        NetClients.connect(spec(NetProtocol.SFTP, 2222) { copy(pinned = fp) }).close()
        try {
            NetClients.connect(spec(NetProtocol.SFTP, 2222) { copy(pinned = "SHA256:other") }).close()
            fail("changed host key accepted")
        } catch (e: NetException) {
            assertEquals(NetError.HOSTKEY_CHANGED, e.error)
            assertEquals(fp, e.detail)
        }
    }

    // ── the player's door ────────────────────────────────────────────────

    @Test fun rangeServerServesEveryProtocol() {
        val clients = mapOf(
            "smb" to NetClients.connect(spec(NetProtocol.SMB, 445) { copy(anonymous = true, user = "", password = "") }),
            "ftp" to NetClients.connect(spec(NetProtocol.FTP, 2121)),
            "ftps" to NetClients.connect(spec(NetProtocol.FTPS, 2122)),
            "sftp" to NetClients.connect(spec(NetProtocol.SFTP, 2222)),
        )
        val paths = mapOf(
            "smb" to "/public/Movies/film.mkv",
            "ftp" to "/Movies/film.mkv",
            "ftps" to "/Movies/film.mkv",
            "sftp" to "$home/Movies/film.mkv",
        )
        val server = NetRangeServer("tok-123", 0, { clients[it] })
        try {
            for ((id, path) in paths) {
                val url = server.url(id, path)
                // Whole file.
                val all = (URL(url).openConnection() as HttpURLConnection).run {
                    assertEquals(200, responseCode, "$id GET")
                    assertEquals("video/x-matroska", contentType)
                    inputStream.use { it.readBytes() }
                }
                assertContentEquals(film, all, "$id whole")
                // A seek.
                (URL(url).openConnection() as HttpURLConnection).run {
                    setRequestProperty("Range", "bytes=4000000-4000999")
                    assertEquals(206, responseCode, "$id range")
                    assertEquals("bytes 4000000-4000999/${film.size}", getHeaderField("Content-Range"))
                    assertContentEquals(film.copyOfRange(4_000_000, 4_001_000), inputStream.use { it.readBytes() })
                }
                // The last bytes, the way players probe for an index.
                (URL(url).openConnection() as HttpURLConnection).run {
                    setRequestProperty("Range", "bytes=-100")
                    assertEquals(206, responseCode)
                    assertContentEquals(film.copyOfRange(film.size - 100, film.size), inputStream.use { it.readBytes() })
                }
            }
            // No token, no file — and not even a hint that it exists.
            val bad = server.url("smb", paths.getValue("smb")).replace("tok-123", "tok-124")
            assertEquals(404, (URL(bad).openConnection() as HttpURLConnection).responseCode)
            // A path with a space and Burmese in it survives the round trip.
            val odd = server.url("smb", "/public/Movies/Sub dir/ငါ့ဇာတ်ကား.mp4")
            assertEquals(300_000, (URL(odd).openConnection() as HttpURLConnection).inputStream.use { it.readBytes() }.size)
        } finally {
            server.stop()
            clients.values.forEach { it.close() }
        }
    }

    // ── Scan ─────────────────────────────────────────────────────────────

    @Test fun scanFindsServersAndNames() {
        val lo = InetAddress.getByName(host)
        val hits = NetScan.probe(listOf(lo, InetAddress.getByName("127.0.0.2")), NetScan.portsFor(NetProtocol.SMB))
        assertTrue(hits.any { it.ip == lo.hostAddress && it.port == 445 }, "hits: $hits")
        assertEquals("NETLAB445", NetScan.netbiosName(lo))
        val sftp = NetScan.probe(listOf(lo), intArrayOf(2222))
        assertEquals(1, sftp.size)
    }

    @Suppress("unused")
    private fun touch() = FtpNet
}
