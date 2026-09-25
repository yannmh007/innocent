package com.innocent.media

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * The cipher that keeps a downloaded film from being copied off the phone.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY A DOWNLOADED FILM NEEDS ENCRYPTING AT ALL
 * ═══════════════════════════════════════════════════════════════════════
 *
 * A "watch offline" download is the operator's master, at full quality, sitting
 * in app storage as a plain MP4. On a rooted phone, or through any file manager
 * that has been granted the right permission, it is a file somebody can copy and
 * pass around — which is the entire catalogue leaving by the front door, one
 * download at a time. Every app that sells downloads encrypts them; this one did
 * not.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY CTR, AND NOT GCM
 * ═══════════════════════════════════════════════════════════════════════
 *
 * A player seeks. libmpv will ask for the bytes at 01:42:07 without having read
 * anything before them, so the cipher has to be addressable by byte offset with
 * no state carried from the start of the file. CTR is: the keystream for any
 * block depends only on the IV and that block's index. GCM is not — it is one
 * authenticated message, and authenticating a four-gigabyte film as one message
 * means reading all of it before showing a single frame.
 *
 * That trades away tamper detection, and this is the right trade here rather
 * than a compromise. The threat is a copy of the file being played elsewhere,
 * not an attacker rewriting bytes in place: anybody who can write to the app's
 * private storage can also simply delete the film. ExoPlayer's own cache
 * encryption makes exactly this choice, for exactly this reason.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THE KEY IS WRAPPED RATHER THAN USED DIRECTLY
 * ═══════════════════════════════════════════════════════════════════════
 *
 * A Keystore key never leaves the secure hardware, which is what makes it worth
 * having — and it means every block of every film would be ciphered through a
 * binder call into keymaster. The bulk of a two-hour film is a lot of binder.
 *
 * So this is the envelope that Jetpack Security, Tink and half of Android use: a
 * 256-bit data key does the film, and a Keystore key does nothing but wrap that
 * data key. The wrapped form is kept in an ordinary preferences file, where it is
 * worthless to anyone who cannot ask the hardware to unwrap it, and the bulk
 * cipher runs on the platform's AES — which on every ARMv8 phone is the CPU's own
 * AES instructions.
 */
object MediaCrypto {
    private const val KEK_ALIAS = "mx_offline_kek_v1"
    private const val PREFS = "mx_offline_crypto_v1"
    private const val KEY_DEK = "dek_wrapped_v1"
    private const val GCM_TAG_BITS = 128
    private const val GCM_IV_BYTES = 12

    /** The bulk transform. Symmetric: encrypt and decrypt are the same call. */
    private const val BULK = "AES/CTR/NoPadding"

    /** AES's block size, and therefore the unit a CTR offset is counted in. */
    const val BLOCK = 16

    private val rnd = SecureRandom()

    /// Unwrapped once per process. Holding it in memory is not a weakening:
    /// anything that can read this process's memory can read the decrypted
    /// frames it is already holding.
    @Volatile private var dek: SecretKey? = null

    fun newIv(): String {
        val iv = ByteArray(BLOCK)
        rnd.nextBytes(iv)
        return Base64.encodeToString(iv, Base64.NO_WRAP)
    }

    /**
     * Whether this phone can actually do it — asked before a download commits to
     * an hour of somebody's data, not after.
     *
     * A round trip at a NON-ZERO, NON-BLOCK-ALIGNED offset, because that is the
     * arithmetic that has somewhere to go wrong: offset zero would pass with the
     * block index and the in-block skip both ignored.
     */
    fun selfTest(context: Context): Boolean {
        return try {
            val iv = newIv()
            val plain = ByteArray(77)
            rnd.nextBytes(plain)
            val at = 4099L // not a multiple of 16, and past the first block
            val sealed = transform(context, iv, at, plain)
            val back = transform(context, iv, at, sealed)
            plain.contentEquals(back) && !plain.contentEquals(sealed)
        } catch (e: Throwable) {
            false
        }
    }

    /**
     * Ciphers [bytes] as though they sat at [plainOffset] in the file.
     *
     * THE OFFSET IS THE WHOLE INTERFACE. The caller may hand over any run of
     * bytes from anywhere in the film, in any order, and get back exactly the
     * bytes that belong at that place — which is what lets the downloader append
     * as the network delivers and the player start at a seek point.
     */
    fun transform(context: Context, ivB64: String, plainOffset: Long, bytes: ByteArray): ByteArray {
        if (plainOffset < 0) throw IllegalArgumentException("negative offset")
        val iv = Base64.decode(ivB64, Base64.NO_WRAP)
        if (iv.size != BLOCK) throw IllegalArgumentException("iv is not $BLOCK bytes")

        val skip = (plainOffset % BLOCK).toInt()
        val counter = counterFor(iv, plainOffset / BLOCK)

        val cipher = Cipher.getInstance(BULK)
        cipher.init(Cipher.ENCRYPT_MODE, dataKey(context), IvParameterSpec(counter))

        // The in-block skip is done by feeding the cipher that many bytes of
        // nothing and throwing the answer away. CTR's keystream does not care
        // what it is XORed with, so this advances it to the right place — and
        // doing it this way means no keystream arithmetic lives in this file.
        if (skip > 0) cipher.update(ByteArray(skip))
        return cipher.doFinal(bytes)
    }

    /**
     * The counter block for a given AES block index: the IV, as one 128-bit
     * big-endian number, plus the index.
     *
     * BY HAND AND NOT WITH BigInteger, because BigInteger's two's-complement
     * byte form is 17 bytes as soon as the top bit is set, and trimming that
     * back is one more place to be wrong. This carries through all sixteen
     * bytes and wraps silently at 2^128, which is the same thing AES-CTR itself
     * does.
     */
    private fun counterFor(iv: ByteArray, blockIndex: Long): ByteArray {
        val out = iv.copyOf()
        var carry = blockIndex
        var i = out.size - 1
        while (i >= 0 && carry != 0L) {
            val sum = (out[i].toInt() and 0xFF) + (carry and 0xFFL).toInt()
            out[i] = (sum and 0xFF).toByte()
            carry = (carry ushr 8) + (if (sum > 0xFF) 1L else 0L)
            i--
        }
        return out
    }

    private fun dataKey(context: Context): SecretKey {
        dek?.let { return it }
        synchronized(this) {
            dek?.let { return it }
            val made = loadOrCreateDek(context)
            dek = made
            return made
        }
    }

    private fun loadOrCreateDek(context: Context): SecretKey {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val stored = prefs.getString(KEY_DEK, null)
        if (stored != null) {
            try {
                return SecretKeySpec(unwrap(stored), "AES")
            } catch (e: Throwable) {
                // A KEK that will not unwrap its own data key is a key that is
                // gone — the user restored a backup onto another phone, or
                // cleared the lock screen on a build where that invalidates it.
                // Every film sealed with the old data key is unreadable and
                // nothing here can change that; making a new one at least means
                // the next download works. The unreadable files are caught by
                // the shelf's own verification, which deletes what it cannot
                // open.
                prefs.edit().remove(KEY_DEK).apply()
            }
        }
        val raw = ByteArray(32)
        rnd.nextBytes(raw)
        prefs.edit().putString(KEY_DEK, wrap(raw)).apply()
        return SecretKeySpec(raw, "AES")
    }

    private fun wrap(raw: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, kek())
        val sealed = cipher.doFinal(raw)
        val out = ByteArray(cipher.iv.size + sealed.size)
        System.arraycopy(cipher.iv, 0, out, 0, cipher.iv.size)
        System.arraycopy(sealed, 0, out, cipher.iv.size, sealed.size)
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    private fun unwrap(stored: String): ByteArray {
        val all = Base64.decode(stored, Base64.NO_WRAP)
        val iv = all.copyOfRange(0, GCM_IV_BYTES)
        val body = all.copyOfRange(GCM_IV_BYTES, all.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, kek(), GCMParameterSpec(GCM_TAG_BITS, iv))
        return cipher.doFinal(body)
    }

    private fun kek(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore")
        ks.load(null)
        (ks.getKey(KEK_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEK_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                // NO USER AUTHENTICATION REQUIREMENT, deliberately. A download
                // resumes by itself while the phone is in somebody's pocket, and
                // a key that needs the screen unlocked would make that
                // impossible — the feature this exists to protect would stop
                // working to protect it.
                .setUserAuthenticationRequired(false)
                .build()
        )
        return gen.generateKey()
    }
}
