package com.innocent.media

import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * Whether this phone will let a download finish while the screen is off.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY A FOREGROUND SERVICE IS NOT THE END OF THE STORY
 * ═══════════════════════════════════════════════════════════════════════
 *
 * [OfflineService] already declares the work to Android, holds a partial
 * WakeLock and a WifiLock, and survives a swipe out of recents. On stock
 * Android that is enough.
 *
 * It is not enough on the phones this app is actually used on. Xiaomi, Oppo,
 * Vivo, Realme and Huawei all ship battery managers that go beyond Doze and
 * freeze or kill backgrounded processes *including ones holding a foreground
 * service*, on a timer, by default. A 900 MB film forty per cent downloaded
 * stops, and the viewer — on the mobile connection that made downloading the
 * right answer in the first place — is given no reason.
 *
 * Nothing in the app can override that. What it CAN do is two things, and this
 * file is both:
 *
 *   1. ASK. Android has one standard dialog for it, and the user's answer is
 *      the only thing that changes the outcome. It is a dialog and not a
 *      settings page, so it costs one tap.
 *   2. SAY SO. When the phone is restricting and the user has not lifted it,
 *      the Downloads screen can put the reason where somebody looking at a
 *      stalled download will read it — instead of leaving them to conclude the
 *      app is broken.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * THE PERMISSION, AND WHY IT IS ALLOWED TO BE HERE
 * ═══════════════════════════════════════════════════════════════════════
 *
 * `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` is on Google Play's restricted list:
 * an app on Play may only declare it when its core function genuinely needs
 * it, and "we would like to be faster" is not that. Innocent is distributed as
 * an APK from its own GitHub Releases and is not on Play, so the policy does
 * not bind — and the justification would hold anyway: the core function is
 * fetching multi-gigabyte files over connections where that takes hours, with
 * the screen off, which is precisely the case the exemption exists for.
 *
 * Written down because the next person to read the manifest will wonder.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHAT EACH FIELD MEANS, AND WHY THEY ARE SEPARATE
 * ═══════════════════════════════════════════════════════════════════════
 *
 * They are three different refusals with three different fixes, and collapsing
 * them into one "battery problem" boolean would make the message unactionable:
 *
 *  • [KEY_EXEMPT] — `isIgnoringBatteryOptimizations`. False means Doze may
 *    defer this app's work when the phone is idle. Fixed by the dialog.
 *  • [KEY_RESTRICTED] — `isBackgroundRestricted`. The user (or an OEM
 *    assistant acting for them) has switched this app's background work off
 *    entirely. THE DIALOG DOES NOT FIX THIS ONE and pretending otherwise
 *    would waste the tap: it is a per-app setting under Battery, so the only
 *    honest action is to open that page.
 *  • [KEY_MANUFACTURER] — the name, because the settings page that actually
 *    matters has a different name on every one of these ROMs and a viewer
 *    being told "your phone" learns nothing.
 */
object PowerPolicy {

    const val KEY_EXEMPT = "exempt"
    const val KEY_RESTRICTED = "restricted"
    const val KEY_MANUFACTURER = "manufacturer"
    const val KEY_SDK = "sdk"

    /**
     * Reads the three facts. Never throws: an unreadable platform reports the
     * PERMISSIVE answer, because a card that tells somebody to fix a problem
     * they do not have is worse than silence — the one on their screen is a
     * download that is working.
     */
    fun state(context: Context): Map<String, Any> {
        var exempt = true
        var restricted = false
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (pm != null) exempt = pm.isIgnoringBatteryOptimizations(context.packageName)
        } catch (_: Throwable) {
            // Left as exempt. See above.
        }
        try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            // API 28. Below it there is no such switch, so "not restricted" is
            // the truth and not a guess.
            if (am != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                restricted = am.isBackgroundRestricted
            }
        } catch (_: Throwable) {
        }
        return mapOf(
            KEY_EXEMPT to exempt,
            KEY_RESTRICTED to restricted,
            KEY_MANUFACTURER to (Build.MANUFACTURER ?: ""),
            KEY_SDK to Build.VERSION.SDK_INT,
        )
    }

    /**
     * The system dialog that asks for the Doze exemption.
     *
     * `ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` with the package uri is the
     * one-tap form. It is deliberately NOT retried or looped: the dialog is the
     * user's decision, and an app that reopens it is an app people uninstall.
     *
     * Returns null when the phone is already exempt, so the caller cannot open
     * a dialog that has nothing to ask.
     */
    fun exemptionIntent(context: Context): Intent? {
        try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                ?: return null
            if (pm.isIgnoringBatteryOptimizations(context.packageName)) return null
            return Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                .setData(Uri.parse("package:" + context.packageName))
        } catch (_: Throwable) {
            return null
        }
    }

    /**
     * This app's own page under Battery, for the case the dialog cannot fix.
     *
     * `isBackgroundRestricted` is switched by hand and can only be switched
     * back by hand, so the honest action is to put the user on the page that
     * holds the switch. App details is the one screen that exists under that
     * name on every ROM; the OEM's own "battery saver" list does not, and
     * guessing at an activity name per manufacturer is how a button starts
     * crashing on a phone nobody in this project owns.
     */
    fun appSettingsIntent(context: Context): Intent {
        return Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
            .setData(Uri.parse("package:" + context.packageName))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}
