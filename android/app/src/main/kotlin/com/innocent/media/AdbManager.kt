package com.innocent.media

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.github.muntashirakon.adb.AbsAdbConnectionManager
import io.github.muntashirakon.adb.android.AdbMdns
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.net.InetAddress
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.PrivateKey
import java.security.PublicKey
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Concrete [AbsAdbConnectionManager] for Innocent (Phase 64).
 *
 * Holds a PERSISTENT RSA key + self-signed X509 certificate: once a device has
 * paired with this key, the adbd keystore remembers it, so the key must stay
 * the same across app restarts for "pair once, reconnect forever" to work. The
 * key/cert are generated once and cached in the app's private files dir.
 *
 * M1a (this step) only sets up the key/cert engine and a [selfTest]; pairing,
 * connecting and shell come in M1b. Certificate generation uses BouncyCastle
 * (Android blocks referencing the sun.security.* classes the README shows).
 */
class AdbManager private constructor(context: Context) : AbsAdbConnectionManager() {

    private val privateKey: PrivateKey
    private val certificate: Certificate

    init {
        // Tell the library which adbd protocol version to speak.
        setApi(Build.VERSION.SDK_INT)

        val dir = context.filesDir
        val keyFile = File(dir, "adb_key.pk8")
        val certFile = File(dir, "adb_cert.der")

        if (keyFile.exists() && certFile.exists()) {
            // Reuse the previously generated identity.
            privateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(keyFile.readBytes()))
            certificate = CertificateFactory.getInstance("X.509")
                .generateCertificate(ByteArrayInputStream(certFile.readBytes()))
        } else {
            // Generate a fresh RSA key pair.
            val keyPairGenerator = KeyPairGenerator.getInstance("RSA")
            keyPairGenerator.initialize(2048)
            val keyPair = keyPairGenerator.generateKeyPair()
            val publicKey: PublicKey = keyPair.public
            privateKey = keyPair.private

            // Build a long-lived self-signed certificate with BouncyCastle.
            val notBefore = Date()
            val notAfter = Date(System.currentTimeMillis() + 86400000L * 3650L) // ~10y
            val serial = BigInteger.valueOf(System.currentTimeMillis())
            val name = X500Name("CN=Innocent")
            val builder = JcaX509v3CertificateBuilder(
                name, serial, notBefore, notAfter, name, publicKey
            )
            val signer = JcaContentSignerBuilder("SHA512withRSA").build(privateKey)
            val holder = builder.build(signer)
            certificate = JcaX509CertificateConverter().getCertificate(holder)

            // Persist so future launches reuse the same identity.
            keyFile.writeBytes(privateKey.encoded)
            certFile.writeBytes(certificate.encoded)
        }
    }

    override fun getPrivateKey(): PrivateKey = privateKey

    override fun getCertificate(): Certificate = certificate

    override fun getDeviceName(): String = "Innocent"

    companion object {
        @Volatile
        private var INSTANCE: AdbManager? = null

        fun getInstance(context: Context): AdbManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: AdbManager(context.applicationContext).also { INSTANCE = it }
            }
        }

        /**
         * M1a self-test: build (or load) the key + certificate and report
         * status. Proves the library links, the package names are right, the
         * BouncyCastle cert generation runs, and the manager instantiates —
         * all WITHOUT touching the network. Never throws (errors come back as
         * a string for the UI to show).
         */
        fun selfTest(context: Context): String {
            return try {
                getInstance(context)
                "OK \u2014 ADB engine ready: key + certificate generated/loaded " +
                    "(Android API ${Build.VERSION.SDK_INT}). " +
                    "Hidden-API: ${InnocentApplication.exemptionStatus}."
            } catch (e: Throwable) {
                "ERROR: ${e.javaClass.simpleName}: ${e.message}"
            }
        }

        /**
         * M1b: pair with the device using the port + 6-digit code shown by
         * "Pair device with pairing code" in Wireless debugging. One-time —
         * adbd remembers our key afterwards.
         */
        /**
         * On-device adbd is reachable over loopback even though the Wireless
         * debugging screen shows a LAN/link-local IP (that address is meant for
         * a *remote* machine). So we try 127.0.0.1 first, then the shown IP.
         */
        private fun candidateHosts(host: String): List<String> {
            val h = host.trim()
            return if (h.isEmpty() || h == "127.0.0.1" || h == "localhost") {
                listOf("127.0.0.1")
            } else {
                listOf("127.0.0.1", h)
            }
        }

        /**
         * M1b: pair with the device using the port + 6-digit code shown by
         * "Pair device with pairing code" in Wireless debugging. One-time —
         * adbd remembers our key afterwards. Keep that dialog open while this
         * runs (the pairing service only lives while it's showing).
         */
        fun pairDevice(context: Context, host: String, port: Int, code: String): String {
            val mgr = getInstance(context)
            val errors = StringBuilder()
            for (h in candidateHosts(host)) {
                try {
                    if (mgr.pair(h, port, code)) return "OK \u2014 paired via $h:$port"
                    errors.append("$h:$port returned false. ")
                } catch (e: Throwable) {
                    errors.append("$h:$port ${e.javaClass.simpleName}: ${e.message}. ")
                }
            }
            return "ERROR: pairing failed \u2014 $errors" +
                "(is the pairing dialog still open, and the code fresh?)"
        }

        /**
         * M1b: connect (if not already) to the debug port shown on the main
         * Wireless debugging screen, then run one shell command and return its
         * output. Success proves the whole chain — a shell as uid=2000(shell).
         */
        // Serializes connect/pair/shell so a screen-open auto-reconnect can't
        // race a user-initiated pair/connect on the shared singleton (which
        // corrupted the connection and surfaced as "Stream closed"). Streaming
        // (streamRange) deliberately does NOT take this lock so playback stays
        // concurrent.
        private val opLock = Any()

        private fun errorString(err: String?): String = when {
            err == null -> "ERROR: couldn't connect"
            err.startsWith("ERROR") -> err
            else -> "ERROR: $err"
        }

        /** Connect to a specific host:port (loopback first). null on success. */
        private fun connectHostPort(
            context: Context,
            mgr: AbsAdbConnectionManager,
            host: String,
            port: Int,
        ): String? {
            val errors = StringBuilder()
            for (h in candidateHosts(host)) {
                try {
                    // connect() returns false when already connected; isConnected
                    // below is the real truth.
                    mgr.connect(h, port)
                } catch (e: Throwable) {
                    errors.append("$h:$port ${e.javaClass.simpleName}: ${e.message}. ")
                    continue
                }
                if (mgr.isConnected) {
                    saveLastConnect(context, h, port)
                    return null
                }
                errors.append("$h:$port did not connect. ")
            }
            return "connect failed \u2014 $errors"
        }

        /**
         * Open [service] (e.g. "shell:id"), read all output as text, and recover
         * from a stale socket. isConnected() can report a dead connection as
         * alive (after a reboot or Wi-Fi change), so the first openStream may
         * throw "Stream closed"; we then drop the connection and reconnect fresh
         * (saved port -> mDNS) before a single retry. [firstConnect] runs when
         * not connected on the first pass; the retry always uses saved -> mDNS.
         */
        /**
         * Run [block] on a worker thread with a hard deadline. If it doesn't
         * finish in time we disconnect (which unblocks a stuck native socket
         * read) and throw. Without this a half-dead connection makes openStream
         * / read block forever — and because operations hold [opLock], one hung
         * call would freeze the whole ADB subsystem (the "spinner forever" bug).
         */
        private fun runWithDeadline(context: Context, ms: Long, block: () -> String): String {
            val holder = AtomicReference<String?>(null)
            val err = AtomicReference<Throwable?>(null)
            val latch = CountDownLatch(1)
            val worker = Thread {
                try {
                    holder.set(block())
                } catch (e: Throwable) {
                    err.set(e)
                } finally {
                    latch.countDown()
                }
            }
            worker.isDaemon = true
            worker.name = "adb-op"
            worker.start()
            if (!latch.await(ms, TimeUnit.MILLISECONDS)) {
                // Tear the socket down so the stuck read unwinds.
                try {
                    getInstance(context).disconnect()
                } catch (_: Throwable) {
                }
                latch.await(2, TimeUnit.SECONDS)
                throw java.io.IOException("timed out after ${ms}ms")
            }
            err.get()?.let { throw it }
            return holder.get() ?: ""
        }

        private fun execRead(
            context: Context,
            service: String,
            deadlineMs: Long = 12000L,
            firstConnect: (AbsAdbConnectionManager) -> String?,
        ): String = synchronized(opLock) {
            var lastErr = "unknown"
            for (attempt in 0..1) {
                try {
                    val mgr = getInstance(context)
                    if (!mgr.isConnected) {
                        val err = if (attempt == 0) {
                            firstConnect(mgr)
                        } else {
                            if (reconnectFromSaved(context, mgr)) null else lastErr
                        }
                        if (!mgr.isConnected) return errorString(err)
                    }
                    // Bounded: most round-trips must answer in ~12s or we treat
                    // the socket as dead and reconnect. The scan passes a longer
                    // budget (a find over a full device is legitimately slow).
                    val text = runWithDeadline(context, deadlineMs) {
                        val stream = mgr.openStream(service)
                        val body = stream.openInputStream().bufferedReader()
                            .use { r -> r.readText() }
                        stream.close()
                        body
                    }
                    // A round-trip just worked, so we're genuinely connected —
                    // keep the socket warm so it doesn't go idle between actions.
                    startKeepAlive(context)
                    return text
                } catch (e: Throwable) {
                    lastErr = "${e.javaClass.simpleName}: ${e.message}"
                    // Stale/stuck connection — drop it so the next attempt
                    // reconnects from scratch.
                    try {
                        getInstance(context).disconnect()
                    } catch (_: Throwable) {
                    }
                }
            }
            return "ERROR: $lastErr"
        }

        fun connectAndRun(context: Context, host: String, port: Int, command: String): String {
            val out = execRead(context, "shell:$command") { mgr ->
                connectHostPort(context, mgr, host, port)
            }
            return if (out.startsWith("ERROR")) out
            else "OK \u2014 connected.\n\n\$ $command\n$out"
        }

        /**
         * Daily reconnect: saved port first (fast, works through a VPN via
         * loopback), then mDNS if that's stale (e.g. after a reboot the port
         * changed). Used when the ADB screen opens.
         */
        fun reconnectAndRun(context: Context, command: String): String {
            val out = execRead(context, "shell:$command") { mgr ->
                if (reconnectFromSaved(context, mgr)) null
                else "couldn't reach the device over the saved port or mDNS"
            }
            return if (out.startsWith("ERROR")) out
            else "OK \u2014 connected.\n\n\$ $command\n$out"
        }

        // ---- ADB backend selection (v0.89 / Backend selector) ----
        // Innocent can read Android/data two ways:
        //   "builtin" — the embedded libadb-android engine (no other app needed;
        //               pairs via mDNS or the notification service).
        //   "iadb"    — bind to the separately-installed iADB app as a client
        //               (Shizuku-style, persistent, "pair once"). DEFAULT on
        //               Android 11+ (v0.94): it's the smoother experience and
        //               the one the user should land on first.
        // DEFAULT LOGIC: if the user has never chosen, prefer "iadb" on API >= 30
        // (where it can work) and "builtin" below. Once the user picks, that
        // choice is honoured forever. The value is a plain string so new
        // backends can be added without a migration.
        fun adbBackend(context: Context): String {
            val prefs = context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
            val saved = prefs.getString("adb_backend", null)
            if (saved == "builtin" || saved == "iadb") return saved
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) "iadb"
            else "builtin"
        }

        fun setAdbBackend(context: Context, backend: String) {
            val v = if (backend == "iadb") "iadb" else "builtin"
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .edit().putString("adb_backend", v).apply()
        }

        /**
         * Open the iADB app's Play Store page (falls back to the web URL if the
         * Play Store app isn't present). Used by the ADB screen when iADB isn't
         * installed, so the user can get it in one tap.
         */
        fun openIadbInStore(context: Context) {
            val pkg = "com.iadb.helper"
            try {
                val market = Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("market://details?id=$pkg"),
                ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                context.startActivity(market)
            } catch (_: Throwable) {
                try {
                    val web = Intent(
                        Intent.ACTION_VIEW,
                        Uri.parse("https://play.google.com/store/apps/details?id=$pkg"),
                    ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                    context.startActivity(web)
                } catch (_: Throwable) {
                }
            }
        }

        /** Remember the host:port that last connected, to auto-fill/reconnect. */
        private fun saveLastConnect(context: Context, host: String, port: Int) {
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .edit().putString("last_connect", "$host:$port").apply()
        }

        /** The last host:port that connected (empty if never). */
        fun lastConnect(context: Context): String =
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .getString("last_connect", "") ?: ""

        /** Remember the video paths found by the last Android/data scan, so the
         *  Local library can show them without re-scanning every launch. */
        fun saveScannedVideos(context: Context, paths: List<String>) {
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .edit().putString("scanned_videos", paths.joinToString("\n")).apply()
        }

        /** The video paths remembered from the last scan (newline-joined). */
        fun scannedVideos(context: Context): String =
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .getString("scanned_videos", "") ?: ""

        /**
         * M2: run a shell command over the existing ADB connection and return
         * its raw output. If not currently connected, transparently reconnects
         * using the remembered address (loopback bypasses VPN). This is the
         * workhorse for listing/reading files inside Android/data.
         */
        fun runShell(context: Context, command: String, deadlineMs: Long = 12000L): String {
            // The Android/data scan is a long `find … -exec stat` over the whole
            // Android/data + Android/obb tree. Mark it so keep-alive backs off
            // and doesn't interleave a ping between the scan's stat batches
            // (which drops the scan on some devices).
            val isScan = command.contains("Android/data") &&
                command.contains("find ")
            if (isScan) scanInProgress = true
            try {
                return execRead(context, "shell:$command", deadlineMs) { mgr ->
                    if (reconnectFromSaved(context, mgr)) null
                    // If the saved port is stale (WD restarted), do the full
                    // rediscovery here too so a scan started after a drop can
                    // recover on its own instead of failing.
                    else if (isScan && scanLocalPort(context, mgr)) null
                    else if (isScan) mdnsConnect(context, 12000L)
                    else "not connected \u2014 open the ADB screen and connect first."
                }
            } finally {
                if (isScan) scanInProgress = false
            }
        }


        /** Reconnect: try the saved host:port (loopback first), then mDNS. */
        private fun reconnectFromSaved(context: Context, mgr: AbsAdbConnectionManager): Boolean {
            // LIGHT reconnect: try only the remembered port, bounded so it can't
            // wedge. This runs automatically when the ADB screen opens and when
            // an in-session op needs the socket back, so it MUST be quick and
            // must not hold the lock long — otherwise it delays the user's own
            // pair/connect. Full rediscovery (localhost sweep + mDNS, which is
            // slower) is reserved for the explicit connect path
            // (autoConnectAndRun) — after pairing, the Connect button, and the
            // after-reboot receiver — so it never blocks anything interactive.
            //
            // TIER 1 half-open fix: mgr.isConnected only reflects whether the
            // socket OBJECT is open — a half-open/dead TCP socket (Wi-Fi
            // dropped, device dozed, WD restarted on a new port) still reports
            // "connected", which is why status could read Connected while every
            // operation actually failed. So if it claims to be connected, first
            // PROVE it with a tiny bounded round-trip; if the probe fails, drop
            // the dead socket and fall through to a real reconnect below.
            if (mgr.isConnected && !isConnectionLive(context)) {
                try {
                    mgr.disconnect()
                } catch (_: Throwable) {
                }
            }
            if (mgr.isConnected) return true
            val last = lastConnect(context)
            if (last.isNotEmpty()) {
                val idx = last.lastIndexOf(':')
                if (idx > 0) {
                    val h = last.substring(0, idx)
                    val p = last.substring(idx + 1).toIntOrNull()
                    if (p != null) {
                        for (host in candidateHosts(h)) {
                            if (tryConnectBounded(mgr, host, p, 2500L)) return true
                        }
                    }
                }
            }
            return mgr.isConnected
        }

        /**
         * Quick liveness probe for a socket that CLAIMS to be connected. Opens a
         * `shell:true` stream with a short deadline; a real dead/half-open socket
         * throws or hangs (caught by the deadline) so we return false. Kept tiny
         * and bounded because it runs on the interactive reconnect path.
         */
        private fun isConnectionLive(context: Context): Boolean {
            return try {
                runWithDeadline(context, 3000L) {
                    val mgr = getInstance(context)
                    val s = mgr.openStream("shell:true")
                    s.openInputStream().use { it.readBytes() }
                    s.close()
                    ""
                }
                true
            } catch (_: Throwable) {
                false
            }
        }

        /**
         * Find the current adbd wireless port by sweeping localhost. Because the
         * app and adbd share the device, we only need the port; a refused
         * connect on 127.0.0.1 returns instantly, so scanning the whole
         * ephemeral range is fast. We first collect open ports with plain TCP,
         * then try an adb handshake on each — the one that authenticates is
         * adbd. Reliable where NsdManager/mDNS silently finds nothing.
         */
        private fun scanLocalPort(context: Context, mgr: AbsAdbConnectionManager): Boolean {
            val open = findOpenLocalPorts()
            for (port in open) {
                try {
                    mgr.disconnect()
                } catch (_: Throwable) {
                }
                if (tryConnectBounded(mgr, "127.0.0.1", port, 3500L)) {
                    saveLastConnect(context, "127.0.0.1", port)
                    return true
                }
            }
            return false
        }

        /** Ports on 127.0.0.1 accepting TCP, across the ephemeral range. */
        private fun findOpenLocalPorts(): List<Int> {
            val open = java.util.Collections.synchronizedList(ArrayList<Int>())
            val pool = java.util.concurrent.Executors.newFixedThreadPool(64)
            try {
                val tasks = (32768..61000).map { port ->
                    java.util.concurrent.Callable<Unit> {
                        try {
                            java.net.Socket().use { s ->
                                s.connect(
                                    java.net.InetSocketAddress("127.0.0.1", port),
                                    120,
                                )
                                open.add(port)
                            }
                        } catch (_: Throwable) {
                        }
                        Unit
                    }
                }
                pool.invokeAll(tasks, 8, TimeUnit.SECONDS)
            } catch (_: Throwable) {
            } finally {
                pool.shutdownNow()
            }
            return ArrayList(open).sorted()
        }

        /**
         * Attempt an adb connect with a hard deadline so a non-adb port that
         * accepts TCP but never completes the handshake can't wedge the sweep.
         */
        private fun tryConnectBounded(
            mgr: AbsAdbConnectionManager,
            host: String,
            port: Int,
            ms: Long,
        ): Boolean {
            val ok = java.util.concurrent.atomic.AtomicBoolean(false)
            val latch = CountDownLatch(1)
            val w = Thread {
                try {
                    mgr.connect(host, port)
                    if (mgr.isConnected) ok.set(true)
                } catch (_: Throwable) {
                } finally {
                    latch.countDown()
                }
            }
            w.isDaemon = true
            w.start()
            if (!latch.await(ms, TimeUnit.MILLISECONDS)) {
                try {
                    mgr.disconnect()
                } catch (_: Throwable) {
                }
                return false
            }
            return ok.get()
        }

        // ---- Auto-enable-after-reboot (no PC, no root) ----
        // Once connected we grant OURSELVES WRITE_SECURE_SETTINGS via the ADB
        // shell; after that the app can flip wireless debugging back on with a
        // plain Settings.Global write, so a BOOT_COMPLETED receiver can restore
        // ADB with zero manual steps. This is the same technique the
        // libadb-android-based "adb-auto-enable" project uses.

        private const val ADB_WIFI_ENABLED = "adb_wifi_enabled"

        /** True once this app holds WRITE_SECURE_SETTINGS. */
        fun hasSecureSettings(context: Context): Boolean =
            context.checkSelfPermission(
                "android.permission.WRITE_SECURE_SETTINGS",
            ) == PackageManager.PERMISSION_GRANTED

        /**
         * Grant WRITE_SECURE_SETTINGS to ourselves over the existing ADB shell,
         * then record that auto-enable is set up. Returns a human-readable
         * status. Safe to call repeatedly.
         */
        fun setupAutoEnable(context: Context): String {
            if (hasSecureSettings(context)) {
                context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                    .edit().putBoolean("auto_enable", true).apply()
                return "OK \u2014 already set up (auto-enable after reboot is on)."
            }
            val pkg = context.packageName
            val out = runShell(
                context,
                "pm grant $pkg android.permission.WRITE_SECURE_SETTINGS 2>&1",
            )
            if (out.startsWith("ERROR:")) return out
            // pm prints nothing on success; re-check the actual grant state.
            return if (hasSecureSettings(context)) {
                context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                    .edit().putBoolean("auto_enable", true).apply()
                "OK \u2014 auto-enable is set up. Wireless debugging will turn " +
                    "itself back on after a reboot; no re-pairing needed."
            } else {
                "Couldn't grant the permission automatically" +
                    (if (out.isBlank()) "" else " ($out)") +
                    ". On some phones (Xiaomi/MIUI, OnePlus) enable Developer " +
                    "options \u2192 \"Disable permission monitoring\" (and USB " +
                    "debugging (Security settings)), then try again."
            }
        }

        /** Whether the user has opted into auto-enable. */
        fun autoEnableOn(context: Context): Boolean =
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .getBoolean("auto_enable", false)

        fun setAutoEnable(context: Context, on: Boolean) {
            context.getSharedPreferences("adb_state", Context.MODE_PRIVATE)
                .edit().putBoolean("auto_enable", on).apply()
        }

        // ---- Keep-alive ----
        // Wi-Fi power-save / adbd idle can drop the TLS socket while it sits
        // unused between actions. A light periodic ping keeps it warm so the
        // next scan/play is instant instead of paying a reconnect. This is now
        // safe (the earlier version was removed because it could hang): the ping
        // runs through runWithDeadline, so it can never block, and it only ever
        // holds opLock for the short bounded ping — never for a reconnect.
        @Volatile
        private var keepAliveThread: Thread? = null

        // While a long Android/data scan is running we don't want the keep-alive
        // ping to contend for the connection or interleave a `shell:true` stream
        // between the scan's stat batches — on some devices that interleaving is
        // exactly what drops the scan. The scan sets this; keep-alive skips its
        // ping while it's true.
        @Volatile
        private var scanInProgress = false

        @Synchronized
        fun startKeepAlive(context: Context) {
            if (keepAliveThread?.isAlive == true) return
            val app = context.applicationContext
            val t = Thread {
                while (!Thread.currentThread().isInterrupted) {
                    try {
                        Thread.sleep(25000)
                    } catch (_: InterruptedException) {
                        break
                    }
                    // Don't ping mid-scan — let the scan own the connection.
                    if (scanInProgress) continue
                    try {
                        val stillUp = synchronized(opLock) {
                            val mgr = getInstance(app)
                            if (!mgr.isConnected) {
                                false
                            } else {
                                // Bounded warm-up. If the socket is secretly
                                // dead this times out and drops it. We never do
                                // an expensive reconnect while holding the lock.
                                runWithDeadline(app, 8000L) {
                                    val s = mgr.openStream("shell:true")
                                    s.openInputStream().use { it.readBytes() }
                                    s.close()
                                    ""
                                }
                                mgr.isConnected
                            }
                        }
                        // Connection is gone — stop pinging so we don't keep
                        // taking the lock (which would stall the user's own
                        // pair/connect). A later successful connect restarts us.
                        if (!stillUp) break
                    } catch (_: Throwable) {
                        // Ping failed → socket dead. Stop; next connect restarts.
                        break
                    }
                }
            }
            t.isDaemon = true
            t.name = "adb-keepalive"
            keepAliveThread = t
            t.start()
        }

        /**
         * Turn wireless debugging ON via Settings.Global (needs
         * WRITE_SECURE_SETTINGS). Returns true if the write went through.
         */
        fun enableWirelessDebugging(context: Context): Boolean {
            if (!hasSecureSettings(context)) return false
            return try {
                Settings.Global.putInt(context.contentResolver, "adb_enabled", 1)
                Settings.Global.putInt(
                    context.contentResolver, ADB_WIFI_ENABLED, 1,
                )
            } catch (e: Throwable) {
                false
            }
        }

        /**
         * M3: copy a file that only the ADB shell can read (inside Android/data)
         * out to a location the app CAN read (/sdcard/Movies/.Innocent_cache,
         * reachable via MANAGE_EXTERNAL_STORAGE), then return that local path so
         * media_kit can play it. Copies on demand (not the whole library) and
         * prunes the cache so it never fills the phone. Returns "ERROR: …" on
         * failure.
         */
        /**
         * M3 (robust): make an Android/data video playable. The ADB shell can
         * read it but the app can't; and a file the *shell* writes to /sdcard
         * often isn't readable/visible to the app (cross-uid + FUSE). So the APP
         * itself streams the bytes over the ADB connection ("exec:cat" = raw, no
         * PTY translation that would corrupt binary) and writes them into its
         * OWN external cache dir — a location this app can always open. Copies on
         * demand and prunes to stay under a size cap. Returns the local path, or
         * an "ERROR: …" string.
         */
        fun pullForPlayback(context: Context, srcPath: String): String {
            return try {
                val baseDir = context.externalCacheDir ?: context.cacheDir
                val cacheDir = File(baseDir, "adb_pull")
                if (!cacheDir.exists()) cacheDir.mkdirs()
                pruneCache(cacheDir, 2L * 1024 * 1024 * 1024)
                val name = srcPath.substringAfterLast('/')
                    .replace(Regex("[^A-Za-z0-9._-]"), "_")
                    .ifEmpty { "video_${System.currentTimeMillis()}" }
                val dest = File(cacheDir, name)

                // Expected size, so we can tell a COMPLETE copy from one cut short
                // by a dropped connection (the old code kept truncated files,
                // which media_kit then rejected as "unrecognised format").
                val expected = fileSize(context, srcPath) // -1 if unknown

                // Re-use a previous copy only if it's verifiably whole.
                if (dest.exists() && dest.length() > 0L &&
                    (expected <= 0L || dest.length() == expected)
                ) {
                    dest.setLastModified(System.currentTimeMillis())
                    return dest.absolutePath
                }
                if (dest.exists()) dest.delete()

                val safeSrc = srcPath.replace("\"", "")
                var lastErr = "unknown"
                for (attempt in 0..1) {
                    val mgr = getInstance(context)
                    if (!mgr.isConnected &&
                        !reconnectFromSaved(context, mgr) &&
                        !scanLocalPort(context, mgr)
                    ) {
                        lastErr = "not connected"
                        continue
                    }
                    val tmp = File(cacheDir, "$name.part")
                    if (tmp.exists()) tmp.delete()
                    var copied = 0L
                    // Stall watchdog: if no bytes arrive for 30s the connection is
                    // wedged — tear it down so the read unwinds instead of hanging
                    // "Preparing…" forever.
                    val lastRead = AtomicReference(System.currentTimeMillis())
                    val done = java.util.concurrent.atomic.AtomicBoolean(false)
                    val watchdog = Thread {
                        while (!done.get()) {
                            try {
                                Thread.sleep(5000)
                            } catch (_: InterruptedException) {
                                break
                            }
                            if (!done.get() &&
                                System.currentTimeMillis() - lastRead.get() > 30000
                            ) {
                                try {
                                    getInstance(context).disconnect()
                                } catch (_: Throwable) {
                                }
                                break
                            }
                        }
                    }
                    watchdog.isDaemon = true
                    watchdog.start()
                    try {
                        val stream = mgr.openStream("exec:cat \"$safeSrc\"")
                        try {
                            stream.openInputStream().use { input ->
                                FileOutputStream(tmp).use { output ->
                                    val buf = ByteArray(256 * 1024)
                                    while (true) {
                                        val n = input.read(buf)
                                        if (n < 0) break
                                        output.write(buf, 0, n)
                                        copied += n
                                        lastRead.set(System.currentTimeMillis())
                                    }
                                    output.flush()
                                }
                            }
                        } finally {
                            try {
                                stream.close()
                            } catch (_: Throwable) {
                            }
                        }
                    } catch (e: Throwable) {
                        lastErr = "${e.javaClass.simpleName}: ${e.message}"
                        tmp.delete()
                        try {
                            getInstance(context).disconnect()
                        } catch (_: Throwable) {
                        }
                        continue
                    } finally {
                        done.set(true)
                        watchdog.interrupt()
                    }
                    // Only accept a copy we can prove is whole.
                    if (copied <= 0L) {
                        tmp.delete()
                        lastErr = "copied 0 bytes (file unreadable or dropped)"
                        continue
                    }
                    if (expected > 0L && copied < expected) {
                        tmp.delete()
                        lastErr = "incomplete copy ($copied/$expected) \u2014 connection dropped"
                        try {
                            getInstance(context).disconnect()
                        } catch (_: Throwable) {
                        }
                        continue
                    }
                    if (!tmp.renameTo(dest)) {
                        tmp.copyTo(dest, overwrite = true)
                        tmp.delete()
                    }
                    return dest.absolutePath
                }
                "ERROR: $lastErr"
            } catch (e: Throwable) {
                "ERROR: ${e.javaClass.simpleName}: ${e.message}"
            }
        }

        // ---- On-demand streaming (instant playback, no full pre-copy) ----
        // media_kit plays from a tiny local HTTP proxy that streams bytes out of
        // Android/data over ADB on demand, with Range support so seeking works.
        // If any of this fails we return "ERROR:" and the caller falls back to
        // the proven full-copy path (pullForPlayback).

        private fun sanitizePath(srcPath: String): String =
            srcPath.replace("\"", "").replace("$", "").replace("`", "")

        /** File size in bytes over ADB (`stat`), or -1 if it can't be read. */
        fun fileSize(context: Context, srcPath: String): Long {
            val safe = sanitizePath(srcPath)
            val out = runShell(context, "stat -c %s \"$safe\" 2>/dev/null").trim()
            return out.toLongOrNull() ?: -1L
        }

        /**
         * Stream bytes [start, start+len) of [srcPath] to [out]. A block-aligned
         * `dd` seek jumps close to the offset fast (lseek, no read-through), then
         * `tail` trims the ≤1 MB remainder and `head` caps the length. Works for
         * start=0 too. Returns bytes written, or -1 on failure.
         */
        fun streamRange(
            context: Context,
            srcPath: String,
            start: Long,
            len: Long,
            out: java.io.OutputStream,
        ): Long {
            if (len <= 0L) return 0L
            return try {
                val mgr = getInstance(context)
                if (!mgr.isConnected && !reconnectFromSaved(context, mgr)) return -1L
                val safe = sanitizePath(srcPath)
                val block = 1048576L
                val skip = start / block
                val inner = (start % block) + 1 // tail -c +N is 1-indexed
                val cmd = "exec:dd if=\"$safe\" bs=$block skip=$skip 2>/dev/null " +
                    "| tail -c +$inner | head -c $len"
                val stream = mgr.openStream(cmd)
                var written = 0L
                try {
                    stream.openInputStream().use { input ->
                        val buf = ByteArray(256 * 1024)
                        while (true) {
                            val n = input.read(buf)
                            if (n < 0) break
                            out.write(buf, 0, n)
                            written += n
                        }
                        out.flush()
                    }
                } finally {
                    try {
                        stream.close()
                    } catch (_: Throwable) {
                    }
                }
                written
            } catch (e: Throwable) {
                -1L
            }
        }

        /**
         * Return an http URL media_kit can play that streams [srcPath] on demand,
         * or an "ERROR: …" string (the caller then falls back to full copy). We
         * probe a real 4-byte range first, so we only hand back a URL when the
         * range pipeline actually works on this device.
         */
        fun streamUrl(context: Context, srcPath: String): String {
            return try {
                val mgr = getInstance(context)
                if (!mgr.isConnected && !reconnectFromSaved(context, mgr)) {
                    return "ERROR: not connected"
                }
                val size = fileSize(context, srcPath)
                if (size <= 0L) return "ERROR: could not stat file"
                val probeLen = if (size < 4L) size else 4L
                val probe = java.io.ByteArrayOutputStream()
                val got = streamRange(context, srcPath, 0L, probeLen, probe)
                if (got < probeLen) return "ERROR: range probe failed ($got/$probeLen)"
                val port = AdbHttpProxy.ensureStarted(context)
                if (port <= 0) return "ERROR: proxy not started"
                val enc = java.net.URLEncoder.encode(srcPath, "UTF-8")
                "http://127.0.0.1:$port/f?p=$enc"
            } catch (e: Throwable) {
                "ERROR: ${e.javaClass.simpleName}: ${e.message}"
            }
        }

        /** Delete oldest cached files until the folder is under [maxBytes]. */
        private fun pruneCache(dir: java.io.File, maxBytes: Long) {
            val files = dir.listFiles()?.filter { it.isFile }
                ?.sortedBy { it.lastModified() } ?: return
            var total = files.sumOf { it.length() }
            for (f in files) {
                if (total <= maxBytes) break
                val len = f.length()
                if (f.delete()) total -= len
            }
        }

        /**
         * M1b (simplified): discover the pairing service over mDNS and pair
         * using only the 6-digit code — no host/port typing. The "Pair device
         * with pairing code" dialog must stay OPEN (it only advertises the
         * mDNS pairing service while visible).
         */
        fun pairWithMdns(context: Context, code: String, timeoutMs: Long): String = synchronized(opLock) {
            var mdns: AdbMdns? = null
            return try {
                val hostRef = AtomicReference<String?>(null)
                val portRef = AtomicInteger(-1)
                val latch = CountDownLatch(1)
                mdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_PAIRING) { host, port ->
                    if (host != null && port > 0) {
                        hostRef.set(host.hostAddress)
                        portRef.set(port)
                        latch.countDown()
                    }
                }
                mdns.start()
                val found = latch.await(timeoutMs, TimeUnit.MILLISECONDS)
                if (!found) {
                    return "ERROR: couldn't find the pairing service over mDNS. " +
                        "Keep the \"Pair device with pairing code\" dialog open, " +
                        "or use Advanced (manual)."
                }
                val host = hostRef.get() ?: return "ERROR: pairing host not resolved"
                val port = portRef.get()
                val ok = getInstance(context).pair(host, port, code)
                if (ok) "OK \u2014 paired via mDNS ($host:$port)"
                else "ERROR: pairing returned false (re-check the code)"
            } catch (e: Throwable) {
                "ERROR: ${e.javaClass.simpleName}: ${e.message}"
            } finally {
                try {
                    mdns?.stop()
                } catch (_: Throwable) {
                }
            }
        }

        /**
         * TIER 1 handoff fix: pair, then IMMEDIATELY connect and save the port.
         *
         * The gap this closes: pairWithMdns() only pairs — the pairing service
         * (`_adb-tls-pairing._tcp`) and the connect service (`_adb-tls-connect
         * ._tcp`) are DIFFERENT mDNS services on DIFFERENT ports, so after a
         * successful pair there is still no live connection and no saved port.
         * The user then had to trigger a second, separate connect that had to
         * re-discover the connect service over (flaky) mDNS. Chaining the
         * connect here, while Wireless debugging is freshly on and advertising,
         * is the most reliable moment to grab and remember the connect port — so
         * every later reconnect is the fast saved-port path instead of mDNS.
         *
         * Returns the pair result string; on a successful pair it appends a
         * short note about whether the immediate connect also succeeded (a
         * connect failure here is non-fatal — the pairing still persisted, and
         * the user can Connect normally).
         */
        fun pairThenConnect(context: Context, code: String, timeoutMs: Long): String {
            val pairResult = pairWithMdns(context, code, timeoutMs)
            if (!pairResult.startsWith("OK")) return pairResult
            // Give Wireless debugging a beat to switch from advertising the
            // pairing service to advertising the connect service.
            try {
                Thread.sleep(500)
            } catch (_: Throwable) {
            }
            val connect = autoConnectAndRun(context, "id", timeoutMs)
            return if (connect.startsWith("ERROR")) {
                // Pair succeeded, connect didn't — still a success overall.
                "$pairResult\n(Paired. Auto-connect will retry — tap Connect if " +
                    "it doesn't come up on its own.)"
            } else {
                "$pairResult\nConnected."
            }
        }

        /**
         * M1b (simplified): discover the connect service over mDNS and connect
         * with no port typing (also resolves the correct host IP itself), then
         * run one shell command. Requires having paired once already.
         */
        fun autoConnectAndRun(context: Context, command: String, timeoutMs: Long): String {
            val out = execRead(context, "shell:$command") { mgr ->
                // Fast path first (saved port), then the localhost sweep, then
                // mDNS. This is the full/deep connect used for the explicit
                // Connect button, right after pairing, and the after-reboot
                // receiver — none of which block interactive pairing.
                if (reconnectFromSaved(context, mgr)) null
                else if (scanLocalPort(context, mgr)) null
                else mdnsConnect(context, timeoutMs)
            }
            return if (out.startsWith("ERROR")) out
            else "OK \u2014 connected\n\n\$ $command\n$out"
        }

        /**
         * Discover the TLS-connect service over mDNS to learn host+port, then
         * connect via loopback first (bypasses VPN) and SAVE the port so later
         * reconnects don't need mDNS again. Returns null on success, or an
         * "ERROR: …" string. Must be called holding no connection.
         */
        /**
         * Discover the TLS-connect service over mDNS to learn host+port, then
         * connect via loopback first (bypasses VPN) and SAVE the port so later
         * reconnects don't need mDNS again. NsdManager (Android's mDNS) is
         * flaky — especially a second discovery right after the pairing one, and
         * its resolve step fails intermittently — so we retry with a FRESH
         * AdbMdns each attempt. Returns null on success, or an "ERROR: …" string.
         */
        private fun mdnsConnect(context: Context, timeoutMs: Long): String? {
            val mgr = getInstance(context)
            if (mgr.isConnected) return null
            // ONE CONTINUOUS discovery for the whole budget. NsdManager needs an
            // uninterrupted window: discovery start-up + finding the service +
            // resolving host/port routinely takes several seconds, and
            // restarting the discovery mid-way resets all of that so it never
            // completes. (An earlier "retry in 5s slices" version broke exactly
            // this — the resolve never had time to finish.) This long single
            // window is the one that reliably connects.
            //
            // We deliberately do NOT stack a second long window here: doing so
            // let a wedged NsdManager spin the UI for 30s+ before failing. One
            // bounded window, then fail fast with actionable guidance — the user
            // can paste IP:Port once (remembered afterwards) instead of waiting.
            val err = mdnsConnectOnce(context, mgr, timeoutMs)
            if (err == null || mgr.isConnected) return null
            return "ERROR: couldn't reach the device over mDNS ($err). Open " +
                "Wireless debugging (button above) and check the toggle is ON, " +
                "then tap Connect again. If it keeps failing, open Advanced " +
                "below and paste the IP:Port shown on the Wireless debugging " +
                "screen once — it's remembered after that, so future connects " +
                "are instant."
        }

        /** One mDNS discover+connect attempt. Returns null on success. */
        private fun mdnsConnectOnce(
            context: Context,
            mgr: AbsAdbConnectionManager,
            timeoutMs: Long,
        ): String? {
            var mdns: AdbMdns? = null
            return try {
                val hostRef = AtomicReference<String?>(null)
                val portRef = AtomicInteger(-1)
                val latch = CountDownLatch(1)
                mdns = AdbMdns(context, AdbMdns.SERVICE_TYPE_TLS_CONNECT) { host, port ->
                    if (host != null && port > 0) {
                        hostRef.set(host.hostAddress)
                        portRef.set(port)
                        latch.countDown()
                    }
                }
                mdns.start()
                if (!latch.await(timeoutMs, TimeUnit.MILLISECONDS)) {
                    return "service not found"
                }
                val host = hostRef.get() ?: return "host not resolved"
                val port = portRef.get()
                for (h in candidateHosts(host)) {
                    try {
                        mgr.connect(h, port)
                    } catch (e: Throwable) {
                        continue
                    }
                    if (mgr.isConnected) {
                        saveLastConnect(context, h, port)
                        return null
                    }
                }
                if (mgr.isConnected) null else "found $host:$port but connect failed"
            } catch (e: Throwable) {
                "${e.javaClass.simpleName}: ${e.message}"
            } finally {
                try {
                    mdns?.stop()
                } catch (_: Throwable) {
                }
            }
        }
    }
}
