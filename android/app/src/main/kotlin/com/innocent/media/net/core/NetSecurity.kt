package com.innocent.media.net

import java.security.Security
import org.bouncycastle.jce.provider.BouncyCastleProvider

/**
 * One full BouncyCastle under the name "BC", for sshj (curve25519 key
 * exchange, ed25519 keys, OpenSSH key files) and smbj / jcifs-ng (MD4 for
 * NTLM, AES-CMAC / CCM for SMB3 signing and encryption).
 *
 * Android registers its own CUT-DOWN BouncyCastle as "BC"
 * (com.android.org.bouncycastle…). sshj asks "is BC registered?", hears yes,
 * and then finds half its algorithms missing. So the platform's one is
 * swapped for the full library the app already ships (bcprov 1.81, via
 * libadb-android) — appended LAST, so Conscrypt stays first for TLS and
 * everything that does not name a provider.
 */
object NetSecurity {
    @Volatile private var installed = false

    fun install() {
        if (installed) return
        synchronized(this) {
            if (installed) return
            val current = Security.getProvider(BouncyCastleProvider.PROVIDER_NAME)
            if (current == null || current.javaClass != BouncyCastleProvider::class.java) {
                if (current != null) Security.removeProvider(BouncyCastleProvider.PROVIDER_NAME)
                Security.addProvider(BouncyCastleProvider())
            }
            installed = true
        }
    }
}
