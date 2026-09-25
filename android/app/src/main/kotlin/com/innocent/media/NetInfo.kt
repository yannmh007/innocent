package com.innocent.media

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/**
 * What kind of connection this phone is on, and whether it costs money to use.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY "METERED" AND NOT "WI-FI"
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Every download feature asks the same question and most of them ask it badly.
 * "Is this Wi-Fi?" is the wrong question: a phone tethering to another phone, a
 * paid hotspot in a tea shop, a Wi-Fi dongle on a data SIM — all of those are
 * Wi-Fi and all of them cost the user money by the megabyte. Android already
 * knows the difference and publishes it as NET_CAPABILITY_NOT_METERED, which
 * the user (or their carrier) can also set by hand for a connection Android
 * guessed wrong about. Asking the platform is both more correct and less work
 * than inferring it from the transport.
 *
 * The transport is reported as well, because it is what a person recognises on
 * screen: "mobile data" means something to somebody deciding whether to spend
 * 1.8 GB, and "metered transport" does not.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHAT THIS DOES NOT ANSWER
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Whether the internet actually works. An interface can be attached, validated
 * and useless — a captive portal, a carrier with no credit, a tower that
 * accepts the association and routes nothing. `ConnectivityService.isOnline()`
 * on the Dart side answers that with a DNS lookup, and the two are deliberately
 * separate: this one is cheap and instant and says what KIND, that one costs a
 * round trip and says WHETHER. Conflating them would mean paying for a DNS
 * lookup to draw a label, or drawing a label from an interface that is lying.
 */
object NetInfo {

    /** `wifi`, `cellular`, `ethernet`, `vpn`, `other`, or `none`. */
    fun transport(context: Context): String {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return "none"
            val network = cm.activeNetwork ?: return "none"
            val caps = cm.getNetworkCapabilities(network) ?: return "none"
            return when {
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                else -> "other"
            }
        } catch (_: Throwable) {
            // An unreadable platform is NOT the same as no connection. Saying
            // "none" would make a Wi-Fi-only rule refuse a download on a phone
            // that is perfectly online; "other" lets the caller decide, and the
            // caller's rule below treats an unknown connection as metered.
            return "other"
        }
    }

    /**
     * True when using this connection costs the user by the megabyte.
     *
     * DEFAULTS TO METERED WHEN NOTHING CAN BE READ. The two mistakes are not
     * symmetrical: treating a free connection as metered costs somebody a
     * settings toggle, and treating a metered one as free costs them a data
     * bundle on a 1.8 GB film they never agreed to spend it on.
     */
    fun metered(context: Context): Boolean {
        try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return true
            val caps = cm.getNetworkCapabilities(cm.activeNetwork ?: return true)
                ?: return true
            return !caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
        } catch (_: Throwable) {
            return true
        }
    }
}
