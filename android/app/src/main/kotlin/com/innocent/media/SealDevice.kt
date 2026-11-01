package com.innocent.media

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.innocent.media.seal.DeviceDek
import com.innocent.media.seal.SealException
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.spec.MGF1ParameterSpec
import java.security.spec.RSAKeyGenParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * This install's media key: the RSA-2048 key in Android Keystore that the
 * server wraps each film's DEK for (docs/MEDIA_ENCRYPTION.md §5).
 *
 * THE PRIVATE HALF NEVER LEAVES THE SECURE HARDWARE. Only its public half
 * (SubjectPublicKeyInfo, base64) goes to request-playback, which pins it to
 * the install on first use. A grant captured on its way — a log, a proxy —
 * then carries a DEK that opens only on this phone.
 *
 * RSA-OAEP WITH SHA-1 AND MGF1-SHA-1. Keystore accepts only MGF1-SHA-1 below
 * API 35, and WebCrypto (the edge function) uses one hash for both, so SHA-1
 * it is for both; OAEP with SHA-1 remains approved for encryption. The
 * parameters are spelled out rather than left to a provider's defaults.
 *
 * NO USER AUTHENTICATION, as with MediaCrypto: a film plays, and a download
 * resumes, with the screen locked.
 *
 * MADE ONCE, TESTED ONCE A PROCESS. Generating the key takes 0.1–2 s in a
 * phone's TEE, so the app asks for it at start-up, in the background, never
 * on the way to a first frame; a grant asked before it is ready goes without
 * it and the server sends that grant's DEK over TLS instead (SEAL_DEVICE_WRAP
 * = prefer). A key that fails its round trip is made again once; a phone
 * whose Keystore cannot do this at all answers null for good.
 */
object SealDevice {
    private const val ALIAS = "inv_media_device_v1"
    private val OAEP = OAEPParameterSpec("SHA-1", "MGF1", MGF1ParameterSpec.SHA1, PSource.PSpecified.DEFAULT)

    @Volatile private var spki: String? = null
    @Volatile private var failed = false

    /** The public half as base64 SPKI, making and testing the key first; null when this phone cannot. */
    @Synchronized
    fun publicKey(): String? {
        spki?.let { return it }
        if (failed) return null
        for (attempt in 0 until 2) {
            try {
                val pub = publicHalf() ?: make()
                if (roundTrip(pub)) {
                    val s = Base64.encodeToString(pub.encoded, Base64.NO_WRAP)
                    spki = s
                    return s
                }
            } catch (_: Throwable) {
            }
            // A key that will not open what was wrapped for it is no key:
            // made again, once.
            try {
                keyStore().deleteEntry(ALIAS)
            } catch (_: Throwable) {
            }
        }
        failed = true
        return null
    }

    /** The DEK the server wrapped for this install. */
    fun unwrap(wrapped: ByteArray): ByteArray {
        val priv = keyStore().getKey(ALIAS, null) as? PrivateKey
            ?: throw SealException("this install has no media key")
        return DeviceDek.open(priv, wrapped)
    }

    /**
     * [dek] wrapped for this install, for keeping beside a download: the same
     * form the server sends, so one path opens both.
     */
    fun wrapForStorage(dek: ByteArray): String {
        val pub = publicHalf() ?: throw SealException("this install has no media key")
        val c = Cipher.getInstance(DeviceDek.TRANSFORM)
        c.init(Cipher.ENCRYPT_MODE, software(pub), OAEP)
        return Base64.encodeToString(c.doFinal(dek), Base64.NO_WRAP)
    }

    private fun keyStore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun publicHalf(): PublicKey? = keyStore().getCertificate(ALIAS)?.publicKey

    private fun make(): PublicKey {
        val gen = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore")
        gen.initialize(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_DECRYPT or KeyProperties.PURPOSE_ENCRYPT)
                .setAlgorithmParameterSpec(RSAKeyGenParameterSpec(2048, RSAKeyGenParameterSpec.F4))
                .setDigests(KeyProperties.DIGEST_SHA1, KeyProperties.DIGEST_SHA256)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_RSA_OAEP)
                .setUserAuthenticationRequired(false)
                .build()
        )
        return gen.generateKeyPair().public
    }

    /**
     * The public key as an ordinary software key: encrypting with the
     * Keystore's own public-key object can be routed to the Keystore provider,
     * which some builds refuse for OAEP with an explicit parameter spec.
     */
    private fun software(pub: PublicKey): PublicKey =
        KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(pub.encoded))

    /** Wrapped with the public half, opened with the Keystore's: the path a grant takes. */
    private fun roundTrip(pub: PublicKey): Boolean {
        val probe = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance(DeviceDek.TRANSFORM)
        c.init(Cipher.ENCRYPT_MODE, software(pub), OAEP)
        val back = unwrap(c.doFinal(probe))
        val ok = back.contentEquals(probe)
        back.fill(0)
        probe.fill(0)
        return ok
    }
}
