import com.innocent.media.seal.MediaSeal
import com.innocent.media.seal.SealException
import com.innocent.media.seal.SealOpener
import com.innocent.media.seal.SealWriter
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * The app's media seal against the shared vectors (Tink opens them; see
 * tool/media_seal_test.py), any range from whole segments, and nothing
 * altered, cut or swapped ever opening.
 */
class MediaSealTest {
    private data class Vector(
        val plainSize: Long, val seed: String, val dek: ByteArray, val dekId: String,
        val salt: ByteArray, val prefix: ByteArray, val sealedSize: Long,
        val sealedSha: String, val sealedHead: String, val plainSha: String,
    )

    private fun vectors(): List<Vector> {
        val text = File(System.getProperty("seal.vectors")).readText()
        // The file is flat objects of strings and numbers; no JSON library.
        return Regex("\\{([^}]*)\\}").findAll(text).map { m ->
            val body = m.groupValues[1]
            fun s(k: String) = Regex("\"$k\":\\s*\"([^\"]*)\"").find(body)!!.groupValues[1]
            fun n(k: String) = Regex("\"$k\":\\s*(\\d+)").find(body)!!.groupValues[1].toLong()
            Vector(n("plain_size"), s("seed"), unhex(s("dek")), s("dek_id"), unhex(s("salt")),
                unhex(s("prefix")), n("sealed_size"), s("sealed_sha256"), s("sealed_head"), s("plain_sha256"))
        }.toList()
    }

    private fun unhex(h: String) = ByteArray(h.length / 2) { h.substring(2 * it, 2 * it + 2).toInt(16).toByte() }
    private fun hex(b: ByteArray) = b.joinToString("") { "%02x".format(it) }
    private fun sha(b: ByteArray) = hex(MessageDigest.getInstance("SHA-256").digest(b))

    private fun pattern(n: Long, seed: String): ByteArray {
        val out = ByteArrayOutputStream()
        var i = 0
        while (out.size() < n) {
            out.write(MessageDigest.getInstance("SHA-256").digest("$seed:$i".toByteArray()))
            i++
        }
        return out.toByteArray().copyOf(n.toInt())
    }

    private fun sealAll(pt: ByteArray, w: SealWriter): ByteArray {
        val out = ByteArrayOutputStream()
        out.write(w.header)
        for (i in 0 until w.count) {
            val p0 = MediaSeal.plainStart(i).toInt()
            out.write(w.sealSegment(i, pt, p0, w.plainLength(i)))
        }
        return out.toByteArray()
    }

    private fun openAll(sealed: ByteArray, dek: ByteArray, aad: ByteArray): ByteArray {
        val total = MediaSeal.plainSize(sealed.size.toLong())
        val op = SealOpener(dek, aad, sealed.copyOf(MediaSeal.HEADER), total)
        val start = MediaSeal.HEADER
        return op.openRun(0, sealed, start, sealed.size - start)
    }

    @Test fun `the same sealed bytes as the reference, and back`() {
        val vs = vectors()
        assertEquals(9, vs.size)
        for (v in vs) {
            val pt = pattern(v.plainSize, v.seed)
            assertEquals(v.plainSha, sha(pt), "pattern ${v.plainSize}")
            val sealed = sealAll(pt, SealWriter(v.dek, MediaSeal.aadFor(v.dekId), v.plainSize, v.salt, v.prefix))
            assertEquals(v.sealedSize, sealed.size.toLong(), "size ${v.plainSize}")
            assertEquals(v.sealedSha, sha(sealed), "bytes ${v.plainSize}")
            assertEquals(v.sealedHead, hex(sealed.copyOf(96)).take(v.sealedHead.length), "head ${v.plainSize}")
            assertContentEquals(pt, openAll(sealed, v.dek, MediaSeal.aadFor(v.dekId)), "open ${v.plainSize}")
        }
    }

    @Test fun `sizes invert, past four gigabytes too`() {
        val r = Random(5)
        val sizes = mutableListOf(0L, 1L, MediaSeal.FIRST_PLAIN - 1L, MediaSeal.FIRST_PLAIN.toLong(), MediaSeal.FIRST_PLAIN + 1L)
        repeat(500) { sizes += r.nextLong(0, 8_000_000_000L) }
        for (n in sizes) assertEquals(n, MediaSeal.plainSize(MediaSeal.sealedSize(n)), "size $n")
        for (i in 1L..40L) assertEquals(i * MediaSeal.SEGMENT, MediaSeal.sealedStart(i))
        assertFailsWith<SealException> { MediaSeal.plainSize(MediaSeal.HEADER + MediaSeal.TAG - 1L) }
    }

    @Test fun `any range from whole segments`() {
        val rnd = SecureRandom()
        val dek = ByteArray(32).also { rnd.nextBytes(it) }
        val aad = MediaSeal.aadFor("ra")
        val pt = ByteArray(MediaSeal.FIRST_PLAIN + 5 * MediaSeal.PLAIN_SEGMENT + 4321).also { rnd.nextBytes(it) }
        val sealed = sealAll(pt, SealWriter(dek, aad, pt.size.toLong()))
        val op = SealOpener(dek, aad, sealed.copyOf(MediaSeal.HEADER), pt.size.toLong())
        val r = Random(9)
        repeat(200) {
            val a = r.nextLong(0, pt.size.toLong())
            val b = minOf(pt.size - 1L, a + listOf(0L, 1L, 65519L, 65520L, 150000L)[it % 5])
            val sa = MediaSeal.segmentOf(a)
            val sb = MediaSeal.segmentOf(b)
            val s0 = MediaSeal.sealedStart(sa).toInt()
            val s1 = (if (sb + 1 < op.count) MediaSeal.sealedStart(sb + 1) else sealed.size.toLong()).toInt()
            val plain = op.openRun(sa, sealed, s0, s1 - s0)
            val skip = (a - MediaSeal.plainStart(sa)).toInt()
            assertContentEquals(pt.copyOfRange(a.toInt(), b.toInt() + 1), plain.copyOfRange(skip, skip + (b - a + 1).toInt()))
        }
    }

    @Test fun `nothing altered, cut or swapped opens`() {
        val rnd = SecureRandom()
        val dek = ByteArray(32).also { rnd.nextBytes(it) }
        val aad = MediaSeal.aadFor("t")
        val pt = ByteArray(MediaSeal.FIRST_PLAIN + 4 * MediaSeal.PLAIN_SEGMENT + 7).also { rnd.nextBytes(it) }
        val sealed = sealAll(pt, SealWriter(dek, aad, pt.size.toLong()))
        val flipped = sealed.copyOf().also { it[MediaSeal.SEGMENT * 2 + 5] = (it[MediaSeal.SEGMENT * 2 + 5].toInt() xor 1).toByte() }
        assertFailsWith<SealException> { openAll(flipped, dek, aad) }
        assertFailsWith<SealException> { openAll(sealed.copyOf(MediaSeal.SEGMENT * 3), dek, aad) }
        val swapped = sealed.copyOf()
        System.arraycopy(sealed, 2 * MediaSeal.SEGMENT, swapped, 3 * MediaSeal.SEGMENT, MediaSeal.SEGMENT)
        System.arraycopy(sealed, 3 * MediaSeal.SEGMENT, swapped, 2 * MediaSeal.SEGMENT, MediaSeal.SEGMENT)
        assertFailsWith<SealException> { openAll(swapped, dek, aad) }
        assertFailsWith<SealException> { openAll(sealed, ByteArray(32), aad) }
        assertFailsWith<SealException> { openAll(sealed, dek, MediaSeal.aadFor("other")) }
    }

    @Test fun `throughput is far above any film's bitrate`() {
        val rnd = SecureRandom()
        val dek = ByteArray(32).also { rnd.nextBytes(it) }
        val aad = MediaSeal.aadFor("speed")
        val pt = ByteArray(32 * 1024 * 1024).also { rnd.nextBytes(it) }
        val sealed = sealAll(pt, SealWriter(dek, aad, pt.size.toLong()))
        val op = SealOpener(dek, aad, sealed.copyOf(MediaSeal.HEADER), pt.size.toLong())
        repeat(2) { op.openRun(0, sealed, MediaSeal.HEADER, sealed.size - MediaSeal.HEADER) } // warm up
        val t0 = System.nanoTime()
        val back = op.openRun(0, sealed, MediaSeal.HEADER, sealed.size - MediaSeal.HEADER)
        val ms = (System.nanoTime() - t0) / 1e6
        assertContentEquals(pt, back)
        val mbps = 32 / (ms / 1000)
        println("open: 32 MiB in %.1f ms = %.0f MiB/s on this JVM".format(ms, mbps))
        // A 1080p rung is about 1 MB/s. A desktop JVM's SunJCE is no phone's
        // Conscrypt (BoringSSL, ~1 GB/s on ARMv8; 52 MiB/s was SunJCE in a
        // sandboxed CI VM on 31 Oct 2026), so the phone's figure comes from the
        // lab. This only catches a pathological slip, such as a key derivation
        // per segment.
        kotlin.test.assertTrue(mbps > 5, "open throughput $mbps MiB/s")
    }
}

class DeviceDekTest {
    private fun field(text: String, k: String) = Regex("\"$k\":\\s*\"([^\"]*)\"").find(text)!!.groupValues[1]

    @Test fun `opens what the edge function wrapped for the phone`() {
        val fx = File(System.getProperty("seal.device")).readText()
        val dec = java.util.Base64.getDecoder()
        val priv = java.security.KeyFactory.getInstance("RSA")
            .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(dec.decode(field(fx, "private_pkcs8"))))
        val dek = com.innocent.media.seal.DeviceDek.open(priv, dec.decode(field(fx, "wrapped_for_device")))
        assertContentEquals(dec.decode(field(fx, "dek_b64")), dek)
        // Someone else's key: refused, never 32 bytes of garbage.
        val other = java.security.KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        assertFailsWith<SealException> { com.innocent.media.seal.DeviceDek.open(other.private, dec.decode(field(fx, "wrapped_for_device"))) }
    }
}
