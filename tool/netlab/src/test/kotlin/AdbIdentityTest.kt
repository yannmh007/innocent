import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder

/**
 * The ADB client identity, built with the BouncyCastle this project ships.
 *
 * WHY HERE. AdbManager (android/app/.../AdbManager.kt) makes the key and
 * self-signed certificate that adbd remembers after pairing, and it needs an
 * Android Context, so it cannot be compiled on a desktop JVM. The settings
 * row that ran it on a phone (the ADB engine self-test) went with the dead
 * settings on 15 Oct, so since then only a real pairing builds one. These
 * are AdbManager's own calls, in its order, on the same BouncyCastle as the
 * app: a version change that broke them would otherwise first show as
 * "pairing failed" on somebody's phone.
 */
class AdbIdentityTest {
    @Test
    fun `the ADB key and certificate build, persist and read back`() {
        val gen = KeyPairGenerator.getInstance("RSA")
        gen.initialize(2048)
        val pair = gen.generateKeyPair()
        val name = X500Name("CN=Innocent")
        val builder = JcaX509v3CertificateBuilder(
            name, BigInteger.valueOf(System.currentTimeMillis()), Date(),
            Date(System.currentTimeMillis() + 86400000L * 3650L), name, pair.public,
        )
        val signer = JcaContentSignerBuilder("SHA512withRSA").build(pair.private)
        val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))

        // What AdbManager writes to adb_key.pk8 and adb_cert.der, read back
        // the way it reads them on the next launch.
        val key = KeyFactory.getInstance("RSA")
            .generatePrivate(PKCS8EncodedKeySpec(pair.private.encoded))
        val again = CertificateFactory.getInstance("X.509")
            .generateCertificate(ByteArrayInputStream(cert.encoded)) as X509Certificate

        assertContentEquals(pair.private.encoded, key.encoded)
        assertContentEquals(cert.encoded, again.encoded)
        assertEquals("CN=Innocent", again.subjectX500Principal.name)
        assertEquals("SHA512withRSA", again.sigAlgName)
        again.verify(pair.public) // self-signed, by the key it carries
        again.checkValidity()
        assertTrue(again.notAfter.time - again.notBefore.time > 86400000L * 3600L)
    }

    @Test
    fun `the BouncyCastle on the classpath is the one the app pins`() {
        val v = org.bouncycastle.jce.provider.BouncyCastleProvider().versionStr
        assertEquals("1.86", v, "tool/netlab and android/app must ship the same BouncyCastle")
    }
}
