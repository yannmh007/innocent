package com.innocent.media.seal

import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Media seal v1 — the phone's half (see docs/MEDIA_ENCRYPTION.md).
 *
 * Every photo and video in R2 is stored sealed; the app opens it on the way to
 * the player. The format is Google Tink's AES-GCM-HKDF streaming AEAD with a
 * 64 KiB ciphertext segment, a 32-byte DEK, AES-256 and HKDF-SHA256, and this
 * file is checked byte for byte against the vectors Tink itself opens
 * (test/fixtures/media_seal_vectors.json, by tool/sealjvm).
 *
 * PURE JVM ON PURPOSE: javax.crypto and nothing from Android, so the same
 * source runs in the JVM tests and in the APK. On a phone, "AES/GCM/NoPadding"
 * resolves to Conscrypt (BoringSSL), which uses the CPU's AES and PMULL
 * instructions on every ARMv8 device — gigabytes a second, where a film needs
 * one or two megabytes a second.
 *
 * WHY THE DATA KEY IS USED DIRECTLY, AND NOT THROUGH THE KEYSTORE: a Keystore
 * key can only be used through a binder call into keymaster, per operation.
 * Opening a film segment by segment through that would be thousands of calls a
 * film. The DEK arrives wrapped for this device and is unwrapped once; the
 * bulk work runs on the platform AES, as MediaCrypto already does for
 * downloads.
 */
object MediaSeal {
    const val SEGMENT = 65536
    const val TAG = 16
    const val SALT = 32
    const val PREFIX = 7
    const val HEADER = 1 + SALT + PREFIX // 40
    const val PLAIN_SEGMENT = SEGMENT - TAG // 65520
    const val FIRST_PLAIN = SEGMENT - HEADER - TAG // 65480
    private const val AAD_PREFIX = "inv-media-v1|"

    fun aadFor(dekId: String): ByteArray = (AAD_PREFIX + dekId).toByteArray(Charsets.UTF_8)

    fun segmentCount(plain: Long): Long =
        if (plain <= FIRST_PLAIN) 1 else 1 + ceilDiv(plain - FIRST_PLAIN, PLAIN_SEGMENT.toLong())

    fun sealedSize(plain: Long): Long = HEADER + plain + TAG * segmentCount(plain)

    /** The plaintext size of a sealed object, from its size alone. */
    fun plainSize(sealed: Long): Long {
        if (sealed < HEADER + TAG) throw SealException("too short to be sealed: $sealed bytes")
        val count = sealed / SEGMENT + if (sealed % SEGMENT != 0L) 1 else 0
        val n = sealed - HEADER - TAG * count
        if (n < 0 || sealedSize(n) != sealed) throw SealException("no plaintext seals to $sealed bytes")
        return n
    }

    fun plainStart(i: Long): Long = if (i == 0L) 0 else FIRST_PLAIN + (i - 1) * PLAIN_SEGMENT

    fun sealedStart(i: Long): Long = if (i == 0L) HEADER.toLong() else i * SEGMENT

    fun segmentOf(plainOffset: Long): Long =
        if (plainOffset < FIRST_PLAIN) 0 else 1 + (plainOffset - FIRST_PLAIN) / PLAIN_SEGMENT

    /** Sealed length of segment [i] in an object of [plainTotal] bytes. */
    fun sealedLength(i: Long, plainTotal: Long): Int {
        val count = segmentCount(plainTotal)
        val end = if (i + 1 < count) sealedStart(i + 1) else sealedSize(plainTotal)
        return (end - sealedStart(i)).toInt()
    }

    internal fun derive(dek: ByteArray, salt: ByteArray, aad: ByteArray): ByteArray {
        if (dek.size != 32) throw SealException("a DEK is 32 bytes, not ${dek.size}")
        // HKDF-SHA256 (RFC 5869) for one 32-byte block: PRK = HMAC(salt, IKM),
        // OKM = HMAC(PRK, info || 0x01).
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(salt, "HmacSHA256"))
        val prk = mac.doFinal(dek)
        mac.init(SecretKeySpec(prk, "HmacSHA256"))
        mac.update(aad)
        mac.update(1)
        val okm = mac.doFinal()
        prk.fill(0)
        return okm
    }

    internal fun nonce(prefix: ByteArray, i: Long, last: Boolean): ByteArray {
        val n = ByteArray(12)
        System.arraycopy(prefix, 0, n, 0, PREFIX)
        n[7] = (i ushr 24).toByte()
        n[8] = (i ushr 16).toByte()
        n[9] = (i ushr 8).toByte()
        n[10] = i.toByte()
        n[11] = if (last) 1 else 0
        return n
    }

    private fun ceilDiv(a: Long, b: Long) = (a + b - 1) / b
}

class SealException(message: String) : Exception(message)

/**
 * Opens any segment of one sealed object, in any order, from any thread.
 *
 * One per object being played; cheap to make (one HKDF) and holds only the
 * derived key, never the DEK.
 */
class SealOpener(dek: ByteArray, aad: ByteArray, header: ByteArray, val plainTotal: Long) {
    private val key: SecretKeySpec
    private val prefix: ByteArray
    val count: Long = MediaSeal.segmentCount(plainTotal)

    init {
        if (header.size < MediaSeal.HEADER || header[0].toInt() != MediaSeal.HEADER) {
            throw SealException("not a media seal v1 header")
        }
        prefix = header.copyOfRange(1 + MediaSeal.SALT, MediaSeal.HEADER)
        val k = MediaSeal.derive(dek, header.copyOfRange(1, 1 + MediaSeal.SALT), aad)
        key = SecretKeySpec(k, "AES")
        k.fill(0)
    }

    /**
     * Opens segment [i] from `src[srcOff, srcOff + srcLen)` into `dst` at
     * [dstOff]; returns the plaintext length. No allocation besides the nonce.
     */
    fun openSegment(i: Long, src: ByteArray, srcOff: Int, srcLen: Int, dst: ByteArray, dstOff: Int): Int {
        if (i < 0 || i >= count) throw SealException("segment $i of $count")
        if (srcLen != MediaSeal.sealedLength(i, plainTotal)) {
            throw SealException("segment $i is ${MediaSeal.sealedLength(i, plainTotal)} sealed bytes, not $srcLen")
        }
        val c = cipher.get()!!
        return try {
            c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, MediaSeal.nonce(prefix, i, i == count - 1)))
            c.doFinal(src, srcOff, srcLen, dst, dstOff)
        } catch (e: javax.crypto.AEADBadTagException) {
            throw SealException("segment $i does not open")
        }
    }

    /**
     * Opens consecutive segments [first].. laid end to end in `src` (as one
     * aligned range request returns them) and returns their plaintext. The
     * phone's proxy sends one of these across the platform channel per run,
     * not one per segment.
     */
    fun openRun(first: Long, src: ByteArray, srcOff: Int = 0, srcLen: Int = src.size): ByteArray {
        var at = srcOff
        val end = srcOff + srcLen
        var i = first
        var plain = 0L
        while (at < end) {
            val n = MediaSeal.sealedLength(i, plainTotal)
            if (at + n > end) throw SealException("run ends inside segment $i")
            plain += n - MediaSeal.TAG
            at += n
            i++
        }
        val out = ByteArray(plain.toInt())
        at = srcOff
        var o = 0
        i = first
        while (at < end) {
            val n = MediaSeal.sealedLength(i, plainTotal)
            o += openSegment(i, src, at, n, out, o)
            at += n
            i++
        }
        return out
    }

    private companion object {
        // Cipher objects are not thread-safe; one per thread, reused, because
        // getInstance is a provider lookup per call.
        val cipher: ThreadLocal<Cipher> = ThreadLocal.withInitial { Cipher.getInstance("AES/GCM/NoPadding") }
    }
}

/** Seals one object segment by segment (tests, and anything the app uploads). */
class SealWriter(dek: ByteArray, aad: ByteArray, val plainTotal: Long,
                 salt: ByteArray? = null, prefix: ByteArray? = null) {
    val header: ByteArray
    private val key: SecretKeySpec
    private val noncePrefix: ByteArray
    val count: Long = MediaSeal.segmentCount(plainTotal)

    init {
        val s = salt ?: ByteArray(MediaSeal.SALT).also { rnd.nextBytes(it) }
        noncePrefix = prefix ?: ByteArray(MediaSeal.PREFIX).also { rnd.nextBytes(it) }
        if (s.size != MediaSeal.SALT || noncePrefix.size != MediaSeal.PREFIX) throw SealException("bad salt or prefix size")
        header = ByteArray(MediaSeal.HEADER)
        header[0] = MediaSeal.HEADER.toByte()
        System.arraycopy(s, 0, header, 1, MediaSeal.SALT)
        System.arraycopy(noncePrefix, 0, header, 1 + MediaSeal.SALT, MediaSeal.PREFIX)
        val k = MediaSeal.derive(dek, s, aad)
        key = SecretKeySpec(k, "AES")
        k.fill(0)
    }

    fun plainLength(i: Long): Int {
        val full = if (i == 0L) MediaSeal.FIRST_PLAIN else MediaSeal.PLAIN_SEGMENT
        return minOf(full.toLong(), plainTotal - MediaSeal.plainStart(i)).toInt()
    }

    fun sealSegment(i: Long, plain: ByteArray, off: Int = 0, len: Int = plain.size): ByteArray {
        if (i < 0 || i >= count) throw SealException("segment $i of $count")
        if (len != plainLength(i)) throw SealException("segment $i wants ${plainLength(i)} bytes, got $len")
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, MediaSeal.nonce(noncePrefix, i, i == count - 1)))
        return c.doFinal(plain, off, len)
    }

    private companion object {
        val rnd = SecureRandom()
    }
}

/**
 * Opens a DEK the server wrapped for this install (docs/MEDIA_ENCRYPTION.md
 * §5): RSA-OAEP with SHA-1 and MGF1-SHA-1, the only MGF1 digest Android
 * Keystore accepts below API 35. [privateKey] is the Keystore key's handle on
 * a phone (its bytes never leave the secure hardware) and an ordinary key in
 * the JVM tests; the parameters are spelled out rather than left to the
 * provider's defaults, which differ between providers.
 */
object DeviceDek {
    const val TRANSFORM = "RSA/ECB/OAEPWithSHA-1AndMGF1Padding"

    fun open(privateKey: java.security.PrivateKey, wrapped: ByteArray): ByteArray {
        val c = Cipher.getInstance(TRANSFORM)
        c.init(Cipher.DECRYPT_MODE, privateKey, javax.crypto.spec.OAEPParameterSpec(
            "SHA-1", "MGF1", java.security.spec.MGF1ParameterSpec.SHA1,
            javax.crypto.spec.PSource.PSpecified.DEFAULT))
        val dek = try {
            c.doFinal(wrapped)
        } catch (e: java.security.GeneralSecurityException) {
            throw SealException("the DEK was not wrapped for this install")
        }
        if (dek.size != 32) throw SealException("a DEK is 32 bytes, not ${dek.size}")
        return dek
    }
}
