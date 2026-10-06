package com.innocent.media.net

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Local Network, the Android side: one MethodChannel ("mx_clone/net") over
 * the plain-JVM core in ./core.
 *
 * Dart owns the saved servers (passwords in the Keystore-backed secure
 * storage); every call carries the server's spec, so a session that died —
 * Wi-Fi dropped, the NAS slept, the process was killed and restored — is
 * simply opened again, and the caller never sees "not connected".
 *
 *   connect {spec}           → {home, fingerprint}   (tests the login)
 *   list    {spec, path}     → [{name, path, dir, size, modified}]
 *   url     {spec, path}     → "http://127.0.0.1:…"  (for the player)
 *   register{specs}          → so the player can resume a network film
 *                              straight from History after a restart
 *   forget  {id}
 *   scan    {protocol}       → {subnet, hits:[{ip, port, name}]}
 *
 * Errors come back as PlatformException(code = NetError.code, details =
 * the new fingerprint for "hostkey_changed").
 */
object NetPlugin {
    private const val CHANNEL = "mx_clone/net"

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newCachedThreadPool { r ->
        Thread(r, "net-call").apply { isDaemon = true }
    }

    private val specs = ConcurrentHashMap<String, NetSpec>()
    private val sessions = ConcurrentHashMap<String, NetClient>()
    private val locks = ConcurrentHashMap<String, Any>()

    @Volatile private var wifiLock: WifiManager.WifiLock? = null

    private val server: NetRangeServer by lazy {
        val prefs = app.getSharedPreferences("net_proxy", Context.MODE_PRIVATE)
        // Stable token and port (see NetRangeServer): the same film has the
        // same URL tomorrow, so the player's resume point finds it.
        val token = prefs.getString("token", null) ?: ByteArray(18).let {
            SecureRandom().nextBytes(it)
            it.joinToString("") { b -> "%02x".format(b) }
        }.also { prefs.edit().putString("token", it).apply() }
        var port = prefs.getInt("port", 0)
        if (port == 0) port = 38000 + SecureRandom().nextInt(2000)
        NetRangeServer(token, port, { id -> sessionFor(id) }, ::onActive).also {
            val bound = it.start()
            prefs.edit().putInt("port", bound).apply()
        }
    }

    fun register(messenger: BinaryMessenger, context: Context) {
        app = context.applicationContext
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            io.execute { handle(call, result) }
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            val value: Any? = when (call.method) {
                "connect" -> {
                    val spec = spec(call.argument<Map<String, Any?>>("spec")!!)
                    // The form's test is always a fresh login; the browser
                    // opening right after it reuses that one (fresh=false).
                    val c = if (call.argument<Boolean>("fresh") != false) {
                        forget(spec.id)
                        open(spec).client
                    } else {
                        sessionFor(spec.id) ?: open(spec).client
                    }
                    mapOf("home" to c.home(), "fingerprint" to c.fingerprint)
                }
                "list" -> {
                    val spec = spec(call.argument<Map<String, Any?>>("spec")!!)
                    val path = call.argument<String>("path") ?: "/"
                    withRetry(spec) { it.list(path) }.map {
                        mapOf(
                            "name" to it.name, "path" to it.path, "dir" to it.dir,
                            "size" to it.size, "modified" to it.modified,
                        )
                    }
                }
                "url" -> {
                    val spec = spec(call.argument<Map<String, Any?>>("spec")!!)
                    server.url(spec.id, call.argument<String>("path")!!)
                }
                "register" -> {
                    call.argument<List<Map<String, Any?>>>("specs")?.forEach { spec(it) }
                    true
                }
                "forget" -> {
                    call.argument<String>("id")?.let { forget(it); specs.remove(it) }
                    true
                }
                "scan" -> scan(NetProtocol.parse(call.argument<String>("protocol") ?: "SMB"))
                "localNetworkBlocked" -> localNetworkBlocked()
                else -> {
                    main.post { result.notImplemented() }
                    return
                }
            }
            log("${call.method} ok")
            main.post { result.success(value) }
        } catch (e: NetException) {
            log("${call.method} ${e.error.code}: ${e.message}")
            main.post { result.error(e.error.code, e.message, e.detail) }
        } catch (e: LinkageError) {
            // A library reaching for an API this Android lacks: say so
            // instead of taking the app down.
            main.post { result.error("protocol", "Not supported on this Android: ${e.message}", null) }
        } catch (t: Throwable) {
            val e = classify(t, call.method)
            main.post { result.error(e.error.code, e.message, e.detail) }
        }
    }

    /** One line per call, as "LAB net …" — the device lab's trace greps it. */
    private fun log(msg: String) {
        android.util.Log.i("Innocent", "LAB net $msg")
    }

    // ── sessions ────────────────────────────────────────────────────────

    private class Opened(val client: NetClient)

    private fun spec(m: Map<String, Any?>): NetSpec {
        val s = NetSpec(
            id = m["id"] as String,
            protocol = NetProtocol.parse(m["protocol"] as String),
            host = (m["host"] as String).trim(),
            port = (m["port"] as? Number)?.toInt() ?: 0,
            path = (m["path"] as? String) ?: "",
            user = (m["user"] as? String) ?: "",
            password = (m["password"] as? String) ?: "",
            domain = (m["domain"] as? String) ?: "",
            anonymous = (m["anonymous"] as? Boolean) ?: false,
            passive = (m["passive"] as? Boolean) ?: true,
            encoding = (m["encoding"] as? String) ?: "UTF-8",
            implicitTls = (m["implicitTls"] as? Boolean) ?: false,
            privateKey = m["privateKey"] as? String,
            passphrase = m["passphrase"] as? String,
            pinned = m["pinned"] as? String,
        )
        val old = specs.put(s.id, s)
        // Edited (new password, new folder…): the old login is stale.
        if (old != null && old != s) forget(s.id)
        return s
    }

    private fun open(spec: NetSpec): Opened {
        if (localNetworkBlocked()) {
            throw NetException(NetError.UNREACHABLE, "Local network access is not allowed for Innocent")
        }
        val c = NetClients.connect(spec)
        sessions.put(spec.id, c)?.let { old -> io.execute { runCatching { old.close() } } }
        return Opened(c)
    }

    /** The live session for [id], opening it again if it died. */
    private fun sessionFor(id: String): NetClient? {
        val spec = specs[id] ?: return null
        val lock = locks.getOrPut(id) { Any() }
        synchronized(lock) {
            sessions[id]?.let { if (it.isAlive()) return it }
            forget(id)
            return runCatching { open(spec).client }.getOrNull()
        }
    }

    /** One retry on a fresh login: a NAS that slept drops idle sessions. */
    private fun <T> withRetry(spec: NetSpec, f: (NetClient) -> T): T {
        val c = sessionFor(spec.id) ?: open(spec).client
        return try {
            f(c)
        } catch (e: NetException) {
            if (e.error == NetError.TIMEOUT || e.error == NetError.PROTOCOL || e.error == NetError.UNREACHABLE) {
                forget(spec.id)
                f(open(spec).client)
            } else {
                throw e
            }
        }
    }

    private fun forget(id: String) {
        sessions.remove(id)?.let { old -> io.execute { runCatching { old.close() } } }
    }

    // ── keeping Wi-Fi awake while a film streams ──────────────────────

    private fun onActive(n: Int) {
        lastActive = n
        try {
            if (n > 0 && wifiLock == null) {
                val wm = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "innocent:net-stream").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } else if (n == 0) {
                // A seek closes one connection a moment before the next one
                // opens: let go only if it is still quiet a little later.
                main.postDelayed({
                    if (activeNow() == 0) {
                        runCatching { wifiLock?.release() }
                        wifiLock = null
                    }
                }, 15_000)
            }
        } catch (_: Throwable) {
        }
    }

    @Volatile private var lastActive = 0
    private fun activeNow() = lastActive

    // ── Scan ──────────────────────────────────────────────────────────

    /** The phone's IPv4 on the Wi-Fi / Ethernet it is on, if any. */
    private fun localV4(): Inet4Address? {
        val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val nets = cm.allNetworks
        var best: Inet4Address? = null
        for (n in nets) {
            val caps = cm.getNetworkCapabilities(n) ?: continue
            val lan = caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)
            if (!lan) continue
            val lp: LinkProperties = cm.getLinkProperties(n) ?: continue
            val a = lp.linkAddresses.map { it.address }.filterIsInstance<Inet4Address>().firstOrNull()
            if (a != null) best = a
        }
        if (best != null) return best
        // A hotspot this phone is hosting, or a network the API hides.
        return runCatching {
            java.net.NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { it.inetAddresses.toList() }
                .filterIsInstance<Inet4Address>()
                .firstOrNull { it.isSiteLocalAddress }
        }.getOrNull()
    }

    private fun scan(p: NetProtocol): Map<String, Any?> {
        val me = localV4() ?: throw NetException(NetError.UNREACHABLE, "Not on a Wi-Fi network")
        val found = ConcurrentHashMap<String, MutableMap<String, Any?>>()
        // mDNS alongside the knock, for the names Macs and NASes announce.
        val nsdNames = ConcurrentHashMap<String, String>()
        val nsdDone = discoverNsd(p, nsdNames)
        val hits = NetScan.probe(NetScan.neighbours(me), NetScan.portsFor(p))
        for (h in hits) {
            found.getOrPut(h.ip) { mutableMapOf("ip" to h.ip, "port" to h.port, "name" to null) }
        }
        if (p == NetProtocol.SMB) {
            val names = found.keys.map { ip ->
                io.submit<Pair<String, String?>> {
                    ip to NetScan.netbiosName(java.net.InetAddress.getByName(ip))
                }
            }
            names.forEach { f ->
                runCatching { f.get(2, TimeUnit.SECONDS) }.getOrNull()?.let { (ip, n) ->
                    if (n != null) found[ip]?.set("name", n)
                }
            }
        }
        nsdDone.await(1500, TimeUnit.MILLISECONDS)
        for ((ip, n) in nsdNames) {
            val e = found[ip]
            if (e != null) {
                if (e["name"] == null) e["name"] = n
            } else {
                // Announced but our knock missed it (a slow box): still list it.
                found[ip] = mutableMapOf("ip" to ip, "port" to NetScan.portsFor(p)[0], "name" to n)
            }
        }
        val subnet = me.hostAddress.substringBeforeLast('.') + ".x"
        return mapOf(
            "subnet" to subnet,
            "hits" to found.values.sortedBy { ip ->
                (ip["ip"] as String).substringAfterLast('.').toIntOrNull() ?: 0
            },
        )
    }

    private fun discoverNsd(p: NetProtocol, out: MutableMap<String, String>): CountDownLatch {
        val done = CountDownLatch(1)
        val type = when (p) {
            NetProtocol.SMB -> "_smb._tcp."
            NetProtocol.SFTP -> "_sftp-ssh._tcp."
            NetProtocol.FTP, NetProtocol.FTPS -> "_ftp._tcp."
        }
        val nsd = runCatching { app.getSystemService(Context.NSD_SERVICE) as NsdManager }.getOrNull()
            ?: return done.also { it.countDown() }
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String?) {}
            override fun onDiscoveryStopped(serviceType: String?) { done.countDown() }
            override fun onStartDiscoveryFailed(serviceType: String?, errorCode: Int) { done.countDown() }
            override fun onStopDiscoveryFailed(serviceType: String?, errorCode: Int) { done.countDown() }
            override fun onServiceLost(serviceInfo: NsdServiceInfo?) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                @Suppress("DEPRECATION")
                runCatching {
                    nsd.resolveService(info, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(si: NsdServiceInfo?, errorCode: Int) {}
                        override fun onServiceResolved(si: NsdServiceInfo) {
                            val ip = si.host?.hostAddress ?: return
                            if (si.host is Inet4Address) out[ip] = si.serviceName
                        }
                    })
                }
            }
        }
        runCatching {
            nsd.discoverServices(type, NsdManager.PROTOCOL_DNS_SD, listener)
            main.postDelayed({ runCatching { nsd.stopServiceDiscovery(listener) } }, 2500)
        }.onFailure { done.countDown() }
        return done
    }

    // ── Android 17's local network permission ─────────────────────────

    /**
     * True only where Android 17's Local Network Protection applies to this
     * app (targetSdk 37+) and the permission is not granted. Today the app
     * targets below 37, so the platform grants local access with INTERNET
     * and this answers false; it is here so the day the target moves, the
     * feature says why it cannot connect instead of timing out.
     */
    private fun localNetworkBlocked(): Boolean {
        if (Build.VERSION.SDK_INT < 37) return false
        if (app.applicationInfo.targetSdkVersion < 37) return false
        return app.checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") !=
            PackageManager.PERMISSION_GRANTED
    }
}
