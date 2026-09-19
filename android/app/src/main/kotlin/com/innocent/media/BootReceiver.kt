package com.innocent.media

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Restores wireless ADB after a reboot with zero manual steps.
 *
 * Once the user has set up auto-enable (we hold WRITE_SECURE_SETTINGS), a reboot
 * would normally turn Wireless debugging off and randomise its port, forcing a
 * manual re-enable + reconnect. [AdbBootJobService] flips it back on via
 * Settings.Global and reconnects — pairing persists, so no re-pairing is needed.
 *
 * This receiver does NOT do that work itself any more. It schedules the job and
 * returns; audit_adb.md A5 has the whole argument, and [AdbBootJobService]'s
 * header carries it.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        // audit_adb.md A3. Narrowed to the one action the manifest now
        // declares. This check is load-bearing, not decoration: the receiver
        // must stay exported to receive BOOT_COMPLETED, and an exported
        // receiver can be handed an EXPLICIT intent carrying any action at
        // all by any app on the device. BOOT_COMPLETED itself is a protected
        // broadcast, so the system refuses to deliver a forged one — which
        // leaves this guard as what rejects everything else.
        val action = intent?.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED) return
        val appContext = context.applicationContext
        if (!AdbManager.autoEnableOn(appContext)) return
        if (!AdbManager.hasSecureSettings(appContext)) return

        // No goAsync(), no thread, no sleep. Scheduling is a single binder
        // call, so onReceive returns in microseconds and the process becomes
        // reclaimable again immediately — which at boot is the whole point.
        if (!AdbBootJobService.schedule(appContext)) {
            android.util.Log.w(
                "BootReceiver",
                "could not schedule the post-boot ADB restore",
            )
        }
    }
}
