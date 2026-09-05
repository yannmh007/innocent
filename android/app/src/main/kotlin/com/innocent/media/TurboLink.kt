package com.innocent.media

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import java.net.NetworkInterface
import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicBoolean

/**
 * TURBO LINK — the direct phone-to-phone radio link behind the Transfer tab.
 *
 * WHY THIS EXISTS
 * Innocent's transfer already runs several parallel TCP streams, which is the
 * whole of what software can do about throughput. The remaining gap against
 * Zapya/SHAREit is physical: over a shared Wi-Fi router EVERY byte crosses the
 * air twice (sender → AP, AP → receiver) on a channel shared with everyone
 * else on that router. A direct link crosses the air once, on a channel with
 * two devices on it. That is worth roughly 2x on its own, and far more when
 * the router is busy or is 2.4 GHz only.
 *
 * WHAT IT USES, AND WHY IN THIS ORDER
 *  1. Wi-Fi Direct autonomous group (`createGroup`, API 29+ with a config).
 *     This is the good one. The API lets us choose the SSID, the passphrase
 *     AND — the reason it beats every alternative — `GROUP_OWNER_BAND_5GHZ`.
 *     5 GHz is what makes 20-30 MB/s reachable at all; 2.4 GHz realistically
 *     tops out far below that. Android's own docs note a group owner is an
 *     ordinary access point that "legacy" (non-P2P) Wi-Fi clients can join,
 *     which is exactly how the receiving phone connects.
 *  2. Wi-Fi Direct with the band left on AUTO, if the device refuses 5 GHz.
 *  3. LocalOnlyHotspot (API 26+). Always 2.4 GHz in practice and the SSID and
 *     passphrase are random, but it is the only route on Android 8-9 and it
 *     still removes the router hop.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 * It never turns Wi-Fi on for the user (no API allows it since Android 10) and
 * it never guesses at a hidden/system API. Every failure returns a reason the
 * Dart side can turn into a sentence, because a "Turbo failed" toast with no
 * explanation is worse than not offering Turbo at all.
 *
 * PROCESS-SCOPED ON PURPOSE: the group must outlive MainActivity, since the
 * transfer keeps running when the user swipes Innocent out of recents (see
 * TransferService.onTaskRemoved). Everything here therefore holds the
 * APPLICATION context and is cleaned up explicitly by hostStop/joinStop.
 */
object TurboLink {

    private const val JOIN_TIMEOUT_MS = 40_000L
    // Generous because hostStart can try three transports in a row and each
    // one waits for its interface to actually come up (see awaitInterface).
    private const val HOST_TIMEOUT_MS = 35_000L
    // How long to wait for the p2p/AP interface to get an address after the
    // framework says the group is up. A single fixed delay was the wrong
    // shape: fast phones are ready in 300 ms, slow ones take four seconds, and
    // guessing a number either wastes time or fails a link that was about to
    // work.
    private const val IFACE_TIMEOUT_MS = 6_000L

    // ---- host state ------------------------------------------------------
    private var p2pManager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var lohsReservation: Any? = null // WifiManager.LocalOnlyHotspotReservation
    private var hosting = false
    private var hostMode = ""      // "p2p5" | "p2p" | "lohs"
    private var hostSsid: String? = null
    private var hostPass: String? = null
    private var hostIp: String? = null
    /// "5", "2.4" or "" — read from the group's ACTUAL frequency, never from
    /// the band we asked for. See the SCC note in startP2pGroup.
    private var hostBand: String = ""
    /// Whether this phone was on a Wi-Fi network when the link came up. Drives
    /// an honest tip in the UI rather than a promise we can't keep.
    private var hostStaWasConnected = false

    // ---- join state ------------------------------------------------------
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var joinedNetwork: Network? = null
    private var legacyNetId: Int = -1
    private var joinedSsid: String? = null

    private val main = Handler(Looper.getMainLooper())

    // ---------------------------------------------------------------------
    // Preconditions
    // ---------------------------------------------------------------------

    fun isWifiEnabled(ctx: Context): Boolean {
        return try {
            val wm = ctx.applicationContext
                .getSystemService(Context.WIFI_SERVICE) as WifiManager
            wm.isWifiEnabled
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Android 12 and below refuse every Wi-Fi peer API unless Location
     * Services is switched on — not just the permission, the master toggle.
     * On 13+ the NEARBY_WIFI_DEVICES permission replaces that entirely, so we
     * report "enabled" there rather than sending the user on a pointless trip
     * to Settings.
     */
    fun isLocationEnabled(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return true
        return try {
            val lm = ctx.applicationContext
                .getSystemService(Context.LOCATION_SERVICE) as LocationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                lm.isLocationEnabled
            } else {
                @Suppress("DEPRECATION")
                Settings.Secure.getInt(
                    ctx.contentResolver,
                    Settings.Secure.LOCATION_MODE,
                    Settings.Secure.LOCATION_MODE_OFF
                ) != Settings.Secure.LOCATION_MODE_OFF
            }
        } catch (_: Throwable) {
            true // Can't tell — don't block the user on a guess.
        }
    }

    fun openSettings(ctx: Context, which: String) {
        val action = when (which) {
            "wifi" -> Settings.ACTION_WIFI_SETTINGS
            "location" -> Settings.ACTION_LOCATION_SOURCE_SETTINGS
            else -> Settings.ACTION_SETTINGS
        }
        try {
            ctx.startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Throwable) {
        }
    }

    // ---------------------------------------------------------------------
    // Hosting
    // ---------------------------------------------------------------------

    fun hostState(): Map<String, Any?> = mapOf(
        "active" to hosting,
        "mode" to hostMode,
        "ssid" to hostSsid,
        "pass" to hostPass,
        "ip" to hostIp,
        "band" to hostBand,
        "staConnected" to hostStaWasConnected
    )

    /**
     * Is this phone currently on a Wi-Fi network?
     *
     * This matters more than it looks. Most Wi-Fi chips only do Single Channel
     * Concurrency: with the station side connected, the P2P group owner is
     * pushed onto the STA's channel. So a phone sitting on a 2.4 GHz router
     * gets a 2.4 GHz direct link no matter what band we ask for. Read through
     * ConnectivityManager rather than WifiManager on purpose — getConnectionInfo
     * is redacted without location permission on Android 10+, while transport
     * capabilities need only ACCESS_NETWORK_STATE.
     */
    private fun isStaConnected(app: Context): Boolean {
        return try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as ConnectivityManager
            val n = cm.activeNetwork ?: return false
            val caps = cm.getNetworkCapabilities(n) ?: return false
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
        } catch (_: Throwable) {
            false
        }
    }

    private fun bandOf(freqMhz: Int): String = when {
        freqMhz >= 5000 -> "5"
        freqMhz in 2400..2500 -> "2.4"
        else -> ""
    }

    /**
     * Poll until the new interface has an address, or give up.
     *
     * createGroup's onSuccess fires before the framework has finished bringing
     * p2p-wlan0-0 up and running DHCP on it, so asking for the address
     * immediately returns nothing on most devices.
     */
    private fun awaitInterface(app: Context, p2p: Boolean, cb: (String?) -> Unit) {
        val deadline = System.currentTimeMillis() + IFACE_TIMEOUT_MS
        val poll = object : Runnable {
            override fun run() {
                val ip = resolveHostIp(app, p2p)
                if (ip != null) {
                    cb(ip); return
                }
                if (System.currentTimeMillis() > deadline) {
                    cb(null); return
                }
                main.postDelayed(this, 400)
            }
        }
        main.postDelayed(poll, 400)
    }

    /**
     * Bring up the direct link. [done] is invoked exactly once with either
     * `{ok:true, mode, ssid, pass, ip}` or `{ok:false, reason}`.
     */
    fun hostStart(ctx: Context, done: (Map<String, Any?>) -> Unit) {
        val app = ctx.applicationContext
        val replied = AtomicBoolean(false)
        fun reply(m: Map<String, Any?>) {
            if (replied.compareAndSet(false, true)) main.post { done(m) }
        }
        // A watchdog, because several of the callbacks below are documented to
        // fire "eventually" and at least one OEM never calls onFailure at all.
        // A Turbo switch that spins forever is the worst possible outcome.
        main.postDelayed({
            if (!replied.get()) {
                hostStopInternal(app)
                reply(mapOf("ok" to false, "reason" to "timeout"))
            }
        }, HOST_TIMEOUT_MS)

        if (hosting && hostSsid != null) {
            reply(successMap()); return
        }
        if (!isWifiEnabled(app)) {
            reply(mapOf("ok" to false, "reason" to "wifi_off")); return
        }
        if (!isLocationEnabled(app)) {
            reply(mapOf("ok" to false, "reason" to "location_off")); return
        }
        hostStaWasConnected = isStaConnected(app)

        val hasP2p = try {
            app.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)
        } catch (_: Throwable) {
            true
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && hasP2p) {
            startP2pGroup(app, fiveGhz = true) { ok ->
                if (ok) {
                    reply(successMap())
                } else {
                    startP2pGroup(app, fiveGhz = false) { ok2 ->
                        if (ok2) reply(successMap())
                        else startLohs(app) { ok3, reason ->
                            if (ok3) reply(successMap())
                            else reply(mapOf("ok" to false, "reason" to reason))
                        }
                    }
                }
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startLohs(app) { ok, reason ->
                if (ok) reply(successMap())
                else reply(mapOf("ok" to false, "reason" to reason))
            }
        } else {
            reply(mapOf("ok" to false, "reason" to "unsupported"))
        }
    }

    private fun successMap(): Map<String, Any?> = mapOf(
        "ok" to true,
        "mode" to hostMode,
        "ssid" to hostSsid,
        "pass" to hostPass,
        "ip" to hostIp,
        "band" to hostBand,
        "staConnected" to hostStaWasConnected
    )

    private fun randomToken(len: Int, charset: String): String {
        val rnd = SecureRandom()
        val sb = StringBuilder(len)
        repeat(len) { sb.append(charset[rnd.nextInt(charset.length)]) }
        return sb.toString()
    }

    @Suppress("MissingPermission")
    private fun startP2pGroup(
        app: Context,
        fiveGhz: Boolean,
        done: (Boolean) -> Unit
    ) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) { done(false); return }
        val mgr = try {
            app.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
        } catch (_: Throwable) {
            null
        }
        if (mgr == null) { done(false); return }
        val ch = try {
            p2pChannel ?: mgr.initialize(app, Looper.getMainLooper(), null)
        } catch (_: Throwable) {
            null
        }
        if (ch == null) { done(false); return }
        p2pManager = mgr
        p2pChannel = ch

        // A leftover group from a previous run makes createGroup fail with
        // BUSY, and a persistent group survives a reboot — so always clear
        // first and ignore the (expected) failure when there is nothing there.
        val proceed = AtomicBoolean(false)
        fun create() {
            if (!proceed.compareAndSet(false, true)) return
            // "DIRECT-" prefix is required by the P2P spec; the name must be
            // at least 9 characters. Randomising the tail keeps two nearby
            // Innocent users from creating colliding SSIDs.
            val name = "DIRECT-in-" + randomToken(4, "ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
            // Avoid 0/O and 1/l — this passphrase gets typed by hand when the
            // other phone is not running Innocent.
            val pass = randomToken(10, "abcdefghjkmnpqrstuvwxyz23456789")
            val builder = WifiP2pConfig.Builder()
                .setNetworkName(name)
                .setPassphrase(pass)
                .enablePersistentMode(false)
            if (fiveGhz) {
                builder.setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_5GHZ)
            } else {
                builder.setGroupOperatingBand(WifiP2pConfig.GROUP_OWNER_BAND_AUTO)
            }
            val cfg = try {
                builder.build()
            } catch (_: Throwable) {
                done(false); return
            }
            try {
                mgr.createGroup(ch, cfg, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() {
                        hosting = true
                        hostMode = "p2p"
                        hostSsid = name
                        hostPass = pass
                        awaitInterface(app, p2p = true) { ip ->
                            if (ip == null) {
                                // The group exists but has no address, so
                                // nothing could ever reach us on it. Take it
                                // back down before trying the next transport,
                                // or the fallback inherits a live group.
                                try {
                                    mgr.removeGroup(ch, null)
                                } catch (_: Throwable) {
                                }
                                hosting = false
                                hostSsid = null
                                hostPass = null
                                done(false)
                                return@awaitInterface
                            }
                            hostIp = ip
                            // Read what the framework ACTUALLY created. We ask
                            // for 5 GHz, but with the station side connected
                            // most chips force the group onto the STA's
                            // channel (single channel concurrency) — the call
                            // still succeeds and lands on 2.4 GHz. Reporting
                            // the band we requested would be a straight lie to
                            // the user about how fast this is going to be.
                            readGroupInfo(mgr, ch) { realName, realPass, freq ->
                                if (!realName.isNullOrBlank()) hostSsid = realName
                                if (!realPass.isNullOrBlank()) hostPass = realPass
                                hostBand = bandOf(freq)
                                done(true)
                            }
                        }
                    }

                    override fun onFailure(reason: Int) = done(false)
                })
            } catch (_: Throwable) {
                done(false)
            }
        }
        try {
            mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() { main.postDelayed({ create() }, 400) }
                override fun onFailure(reason: Int) { create() }
            })
        } catch (_: Throwable) {
            create()
        }
        // removeGroup on a device with no group sometimes calls neither
        // callback. Don't let that strand the whole flow.
        main.postDelayed({ create() }, 1500)
    }

    /**
     * Best-effort read of the live group: real SSID, real passphrase, real
     * frequency. Every part is optional — a device that refuses this still has
     * a working link, it just doesn't get a band label.
     */
    @Suppress("MissingPermission")
    private fun readGroupInfo(
        mgr: WifiP2pManager,
        ch: WifiP2pManager.Channel,
        cb: (String?, String?, Int) -> Unit
    ) {
        val replied = AtomicBoolean(false)
        fun finish(a: String?, b: String?, f: Int) {
            if (replied.compareAndSet(false, true)) cb(a, b, f)
        }
        try {
            mgr.requestGroupInfo(ch) { group ->
                if (group == null) {
                    finish(null, null, 0)
                } else {
                    val freq = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        try {
                            group.frequency
                        } catch (_: Throwable) {
                            0
                        }
                    } else {
                        0
                    }
                    finish(group.networkName, group.passphrase, freq)
                }
            }
        } catch (_: Throwable) {
            finish(null, null, 0)
        }
        // Some devices never call the listener at all.
        main.postDelayed({ finish(null, null, 0) }, 2500)
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun startLohs(app: Context, done: (Boolean, String) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            done(false, "unsupported"); return
        }
        val wm = try {
            app.getSystemService(Context.WIFI_SERVICE) as WifiManager
        } catch (_: Throwable) {
            done(false, "no_wifi_service"); return
        }
        val replied = AtomicBoolean(false)
        try {
            wm.startLocalOnlyHotspot(
                object : WifiManager.LocalOnlyHotspotCallback() {
                    override fun onStarted(
                        reservation: WifiManager.LocalOnlyHotspotReservation
                    ) {
                        lohsReservation = reservation
                        var ssid: String? = null
                        var pass: String? = null
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                val c = reservation.softApConfiguration
                                ssid = c.ssid
                                pass = c.passphrase
                            } else {
                                val c = reservation.wifiConfiguration
                                // Pre-30 the SSID comes back quoted.
                                ssid = c?.SSID?.trim('"')
                                pass = c?.preSharedKey?.trim('"')
                            }
                        } catch (_: Throwable) {
                        }
                        if (ssid.isNullOrBlank()) {
                            if (replied.compareAndSet(false, true)) {
                                done(false, "no_credentials")
                            }
                            return
                        }
                        hosting = true
                        hostMode = "lohs"
                        hostSsid = ssid
                        hostPass = pass
                        // A local-only hotspot is 2.4 GHz on every device we
                        // know of, and there is no API to ask.
                        hostBand = "2.4"
                        awaitInterface(app, p2p = false) { ip ->
                            hostIp = ip
                            if (replied.compareAndSet(false, true)) {
                                if (ip == null) {
                                    hosting = false
                                    done(false, "no_address")
                                } else {
                                    done(true, "")
                                }
                            }
                        }
                    }

                    override fun onFailed(reason: Int) {
                        if (replied.compareAndSet(false, true)) {
                            done(false, "lohs_failed_$reason")
                        }
                    }

                    override fun onStopped() {
                        hosting = false
                        lohsReservation = null
                    }
                },
                main
            )
        } catch (t: Throwable) {
            if (replied.compareAndSet(false, true)) done(false, "lohs_exception")
        }
    }

    /**
     * Find the address the other phone should dial.
     *
     * A Wi-Fi Direct group owner is 192.168.49.1 and a local-only hotspot is
     * usually 192.168.43.1, but neither is guaranteed, and on a device that
     * kept its router connection alive there are now TWO addresses — handing
     * out the router one would send the receiver back over the slow path we
     * just went to all this trouble to avoid. So: match the known direct-link
     * ranges first, then the AP-ish interface names, and only then give up.
     */
    private fun resolveHostIp(app: Context, p2p: Boolean): String? {
        val preferredPrefix = if (p2p) "192.168.49." else "192.168.43."
        var apCandidate: String? = null
        try {
            val ifaces = NetworkInterface.getNetworkInterfaces() ?: return null
            for (ni in ifaces) {
                if (!ni.isUp || ni.isLoopback) continue
                val name = ni.name.lowercase()
                for (addr in ni.inetAddresses) {
                    val host = addr.hostAddress ?: continue
                    if (addr.isLoopbackAddress || host.contains(':')) continue
                    if (host.startsWith(preferredPrefix)) return host
                    if (host.startsWith("192.168.49.") ||
                        host.startsWith("192.168.43.")
                    ) {
                        apCandidate = apCandidate ?: host
                        continue
                    }
                    if (name.startsWith("p2p") || name.startsWith("ap") ||
                        name.contains("swlan") || name.contains("softap")
                    ) {
                        apCandidate = apCandidate ?: host
                    }
                }
            }
        } catch (_: Throwable) {
        }
        return apCandidate
    }

    fun hostStop(ctx: Context) = hostStopInternal(ctx.applicationContext)

    private fun hostStopInternal(app: Context) {
        try {
            val mgr = p2pManager
            val ch = p2pChannel
            if (mgr != null && ch != null) {
                try {
                    mgr.removeGroup(ch, null)
                } catch (_: Throwable) {
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                    try {
                        ch.close()
                    } catch (_: Throwable) {
                    }
                }
            }
        } catch (_: Throwable) {
        }
        p2pManager = null
        p2pChannel = null
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                (lohsReservation as? WifiManager.LocalOnlyHotspotReservation)?.close()
            }
        } catch (_: Throwable) {
        }
        lohsReservation = null
        hosting = false
        hostMode = ""
        hostSsid = null
        hostPass = null
        hostIp = null
        hostBand = ""
        hostStaWasConnected = false
    }

    // ---------------------------------------------------------------------
    // Joining (receiver side)
    // ---------------------------------------------------------------------

    fun joinState(): Map<String, Any?> = mapOf(
        "joined" to (joinedNetwork != null || legacyNetId >= 0),
        "ssid" to joinedSsid
    )

    /**
     * Join the sender's direct link and pin this process's traffic to it.
     *
     * The pinning is the part that is easy to miss: without
     * bindProcessToNetwork, Android keeps routing through whatever network has
     * internet, so every socket would go out over mobile data and the transfer
     * would simply never connect. Binding is process-wide and affects Dart's
     * sockets too, which is exactly what we want here — and exactly why
     * [joinStop] must always run afterwards.
     */
    @Suppress("MissingPermission", "DEPRECATION")
    fun joinStart(
        ctx: Context,
        ssid: String,
        pass: String,
        done: (Map<String, Any?>) -> Unit
    ) {
        val app = ctx.applicationContext
        val replied = AtomicBoolean(false)
        fun reply(m: Map<String, Any?>) {
            if (replied.compareAndSet(false, true)) main.post { done(m) }
        }
        if (!isWifiEnabled(app)) {
            reply(mapOf("ok" to false, "reason" to "wifi_off")); return
        }
        if (!isLocationEnabled(app)) {
            reply(mapOf("ok" to false, "reason" to "location_off")); return
        }
        // Re-joining the same link is a no-op, not an error: the user may have
        // tapped Retry while we were already on it.
        if (joinedSsid == ssid && (joinedNetwork != null || legacyNetId >= 0)) {
            reply(mapOf("ok" to true, "reason" to "already")); return
        }
        joinStopInternal(app)

        val cm = try {
            app.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        } catch (_: Throwable) {
            reply(mapOf("ok" to false, "reason" to "no_conn_service")); return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val specifier = try {
                WifiNetworkSpecifier.Builder()
                    .setSsid(ssid)
                    .setWpa2Passphrase(pass)
                    .build()
            } catch (_: Throwable) {
                reply(mapOf("ok" to false, "reason" to "bad_credentials")); return
            }
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                // A direct link has no internet by definition. Leaving the
                // default INTERNET capability in the request means the system
                // never matches it and the user's approval dialog leads
                // nowhere.
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(specifier)
                .build()
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    joinedNetwork = network
                    joinedSsid = ssid
                    fun bind(): Boolean = try {
                        cm.bindProcessToNetwork(network)
                    } catch (_: Throwable) {
                        false
                    }
                    if (bind()) {
                        reply(mapOf("ok" to true, "bound" to true,
                            "mode" to "specifier"))
                    } else {
                        // The bind can lose a race with the network finishing
                        // its setup. Without it every socket goes out over the
                        // old default route and the transfer never connects,
                        // so it is worth one more try before giving up.
                        main.postDelayed({
                            reply(mapOf("ok" to true, "bound" to bind(),
                                "mode" to "specifier"))
                        }, 700)
                    }
                }

                override fun onUnavailable() {
                    reply(mapOf("ok" to false, "reason" to "declined_or_not_found"))
                }

                override fun onLost(network: Network) {
                    // The sender walked away or stopped sharing. Drop the pin
                    // so the app's other features get their network back
                    // instead of silently failing every request.
                    if (joinedNetwork == network) {
                        try {
                            cm.bindProcessToNetwork(null)
                        } catch (_: Throwable) {
                        }
                        joinedNetwork = null
                        joinedSsid = null
                    }
                }
            }
            joinCallback = cb
            try {
                cm.requestNetwork(request, cb, JOIN_TIMEOUT_MS.toInt())
            } catch (_: Throwable) {
                joinCallback = null
                reply(mapOf("ok" to false, "reason" to "request_failed"))
            }
            return
        }

        // ---- Android 8-9 legacy path ----
        // addNetwork/enableNetwork was removed for apps on Android 10, but a
        // large share of phones in this app's audience are still on 8 or 9 and
        // would otherwise get no Turbo at all. There is no callback here, so
        // poll the supplicant and give up honestly rather than pretending.
        val wm = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val conf = android.net.wifi.WifiConfiguration().apply {
            SSID = "\"" + ssid + "\""
            preSharedKey = "\"" + pass + "\""
        }
        val netId = try {
            wm.addNetwork(conf)
        } catch (_: Throwable) {
            -1
        }
        if (netId < 0) {
            reply(mapOf("ok" to false, "reason" to "add_network_failed")); return
        }
        legacyNetId = netId
        try {
            wm.disconnect()
            wm.enableNetwork(netId, true)
            wm.reconnect()
        } catch (_: Throwable) {
        }
        val deadline = System.currentTimeMillis() + 25_000L
        val poll = object : Runnable {
            override fun run() {
                if (replied.get()) return
                val current = try {
                    wm.connectionInfo?.ssid?.trim('"')
                } catch (_: Throwable) {
                    null
                }
                if (current == ssid) {
                    joinedSsid = ssid
                    reply(mapOf("ok" to true, "bound" to false, "mode" to "legacy"))
                    return
                }
                if (System.currentTimeMillis() > deadline) {
                    joinStopInternal(app)
                    reply(mapOf("ok" to false, "reason" to "legacy_timeout"))
                    return
                }
                main.postDelayed(this, 1000)
            }
        }
        main.postDelayed(poll, 1500)
    }

    fun joinStop(ctx: Context) = joinStopInternal(ctx.applicationContext)

    private fun joinStopInternal(app: Context) {
        try {
            val cm = app.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as ConnectivityManager
            try {
                cm.bindProcessToNetwork(null)
            } catch (_: Throwable) {
            }
            joinCallback?.let {
                try {
                    cm.unregisterNetworkCallback(it)
                } catch (_: Throwable) {
                }
            }
        } catch (_: Throwable) {
        }
        joinCallback = null
        joinedNetwork = null
        joinedSsid = null
        if (legacyNetId >= 0) {
            try {
                @Suppress("DEPRECATION")
                val wm = app.getSystemService(Context.WIFI_SERVICE) as WifiManager
                @Suppress("DEPRECATION")
                wm.removeNetwork(legacyNetId)
                @Suppress("DEPRECATION")
                wm.reconnect()
            } catch (_: Throwable) {
            }
            legacyNetId = -1
        }
    }

    /** Release everything. Called when the Transfer feature shuts down. */
    fun shutdown(ctx: Context) {
        hostStop(ctx)
        joinStop(ctx)
    }
}
