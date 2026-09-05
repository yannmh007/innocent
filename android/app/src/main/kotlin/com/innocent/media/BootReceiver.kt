package com.innocent.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlin.concurrent.thread

/**
 * Restores wireless ADB after a reboot with zero manual steps.
 *
 * Once the user has set up auto-enable (we hold WRITE_SECURE_SETTINGS), a reboot
 * would normally turn Wireless debugging off and randomise its port, forcing a
 * manual re-enable + reconnect. Here we flip it back on via Settings.Global and
 * reconnect over mDNS — pairing persists, so no re-pairing is needed.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.LOCKED_BOOT_COMPLETED" &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        val appContext = context.applicationContext
        if (!AdbManager.autoEnableOn(appContext)) return
        if (!AdbManager.hasSecureSettings(appContext)) return

        val pending = goAsync()
        thread(start = true, isDaemon = true, name = "adb-boot") {
            try {
                // Give Wi-Fi and the system a moment to come up after boot.
                try {
                    Thread.sleep(45000)
                } catch (_: Throwable) {
                }
                AdbManager.enableWirelessDebugging(appContext)
                // Wait for adbd to start advertising the connect service.
                try {
                    Thread.sleep(8000)
                } catch (_: Throwable) {
                }
                // Reconnect over mDNS (port changed on reboot) and prove it.
                AdbManager.autoConnectAndRun(appContext, "id", 25000L)
            } catch (_: Throwable) {
            } finally {
                pending.finish()
            }
        }
    }
}
