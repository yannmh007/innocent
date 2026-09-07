package com.innocent.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

/**
 * The quiet "an update is available" notice. Step 6 of `docs/updater_plan.md`,
 * §4A.
 *
 * NOT A SECOND NOTIFICATION SYSTEM. This is the same shape as
 * [TransferService.notifyDone]: a plain [NotificationCompat] build, posted
 * straight through [NotificationManager], with the channel created lazily on
 * first use. It is a companion-style object rather than a Service because
 * there is nothing to keep alive — a one-shot notice needs no foreground
 * service, and asking for one would cost the user a permanent shade entry for
 * a message that fits on one line.
 *
 * ITS OWN CHANNEL, and that is the point of §4A's "low importance channel so
 * it does not buzz". Android 8+ lets the user mute a channel; Android 14 puts
 * that control one long-press away. Sharing `mx_clone_transfer` with the
 * download-progress notification would mean muting update notices also mutes
 * the progress bar of a transfer in flight, which is the one notification a
 * user actually wants while sending a film to a friend.
 */
object UpdateNotification {

    /**
     * Set on the launch intent so the app knows to open Settings → App update
     * rather than just coming to the foreground. Read by
     * `MainActivity.handleUpdateIntent`.
     */
    const val EXTRA_OPEN_APP_UPDATE = "com.innocent.media.OPEN_APP_UPDATE"

    private const val CHANNEL_ID = "innocent_app_update"
    private const val CHANNEL_NAME = "App updates"
    private const val NOTIFICATION_ID = 0xAB45

    /**
     * Distinct from the transfer notifications' request codes (0 and 1), and
     * that is load-bearing rather than tidy. [Intent.filterEquals] — which is
     * what [PendingIntent] matches on — IGNORES extras, so this launch intent
     * and the transfer notification's launch intent are "the same" intent to
     * the system. Reusing their request code with FLAG_UPDATE_CURRENT would
     * overwrite the live transfer notification's PendingIntent with this one's
     * extras, and tapping a finished transfer would open the update screen.
     */
    private const val REQUEST_CODE = 2

    /**
     * Post the notice. Returns false if anything went wrong, including the
     * user having notifications switched off.
     *
     * §6's first two rows are the rule here: an update the user cannot be told
     * about is silence, never an error. The Dart side already declines to call
     * this without POST_NOTIFICATIONS; the try/catch is for everything else an
     * OEM shade can do.
     */
    fun show(context: Context, title: String, text: String): Boolean {
        return try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
            ensureChannel(nm)

            val open = context.packageManager
                .getLaunchIntentForPackage(context.packageName)
                ?.apply {
                    flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra(EXTRA_OPEN_APP_UPDATE, true)
                } ?: return false

            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.stat_sys_download_done)
                // Dismissible, always. §7 and step 6's brief both rule out
                // anything the user cannot swipe away; a forced path is step
                // 7's to argue for, and even there it would not be this.
                .setAutoCancel(true)
                .setOngoing(false)
                .setOnlyAlertOnce(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setContentIntent(
                    PendingIntent.getActivity(context, REQUEST_CODE, open, pendingFlags)
                )

            nm.notify(NOTIFICATION_ID, builder.build())
            true
        } catch (_: Throwable) {
            false
        }
    }

    /**
     * Take the notice down.
     *
     * Called once the user has been asked directly — they answered the dialog,
     * or they are standing on the update screen. Leaving it up after that is
     * the nagging §3 names as the actual failure mode of this whole feature.
     */
    fun cancel(context: Context) {
        try {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
            nm.cancel(NOTIFICATION_ID)
        } catch (_: Throwable) {
            // Nothing to take down, or no shade to take it down from.
        }
    }

    private fun ensureChannel(nm: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            // §4A: "low importance channel so it does not buzz". IMPORTANCE_LOW
            // means it appears in the shade with no sound and no heads-up
            // banner. An update notice that interrupts is worse than no notice.
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Tells you when a new version of Innocent is available."
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(channel)
    }
}
