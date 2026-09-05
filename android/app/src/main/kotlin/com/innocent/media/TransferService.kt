package com.innocent.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps a Wi-Fi file transfer alive while the user
 * leaves Innocent (presses Home or switches apps) and shows the transfer
 * progress in the notification shade.
 *
 * Modeled on [PlaybackService]: the service does no transfer work itself —
 * the shelf HTTP server (sender) and the streamed download loop (receiver)
 * run in the Flutter isolate. What this gives us is the system-level
 * guarantee that Android keeps our process alive (instead of killing the
 * backgrounded app under memory pressure) for the duration of the transfer,
 * plus an ongoing progress notification.
 *
 * ACTION_START shows the notification + enters the foreground; ACTION_UPDATE
 * refreshes the text/progress without re-entering foreground; ACTION_STOP
 * tears it down. The manifest declares foregroundServiceType="dataSync".
 */
class TransferService : Service() {

    companion object {
        private const val CHANNEL_ID = "mx_clone_transfer"
        private const val CHANNEL_NAME = "File Transfer"
        private const val NOTIFICATION_ID = 0xAB43
        // Separate id so the "done" notice does not replace, or get replaced
        // by, the ongoing progress one.
        private const val DONE_NOTIFICATION_ID = 0xAB44

        const val ACTION_START = "com.innocent.media.TRANSFER_START"
        const val ACTION_UPDATE = "com.innocent.media.TRANSFER_UPDATE"
        const val ACTION_STOP = "com.innocent.media.TRANSFER_STOP"
        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress" // 0..100, or <0 for indeterminate

        /**
         * True between ACTION_START and ACTION_STOP. MainActivity reads this
         * on teardown: a transfer deliberately survives the Activity dying
         * (swipe-from-recents), so the Turbo radio link must survive with it —
         * but a plain app exit with no transfer running must release it.
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        /** Start (or restart) the foreground transfer notification. */
        fun start(context: Context, title: String, text: String, progress: Int) {
            send(context, ACTION_START, title, text, progress, foreground = true)
        }

        /** Update the existing notification's text + progress. */
        fun update(context: Context, title: String, text: String, progress: Int) {
            send(context, ACTION_UPDATE, title, text, progress, foreground = false)
        }

        /**
         * A dismissible completion notification, posted directly rather than
         * through the service: the service is on its way down at this point,
         * and its ongoing notification goes with it.
         */
        fun notifyDone(context: Context, title: String, text: String) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE)
                        as NotificationManager
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    nm.getNotificationChannel(CHANNEL_ID) == null
                ) {
                    nm.createNotificationChannel(
                        NotificationChannel(
                            CHANNEL_ID,
                            CHANNEL_NAME,
                            NotificationManager.IMPORTANCE_LOW
                        )
                    )
                }
                val open = context.packageManager
                    .getLaunchIntentForPackage(context.packageName)?.apply {
                        flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_CLEAR_TOP
                    }
                val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val builder = NotificationCompat.Builder(context, CHANNEL_ID)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setAutoCancel(true)
                    .setOnlyAlertOnce(true)
                    .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                if (open != null) {
                    builder.setContentIntent(
                        PendingIntent.getActivity(context, 1, open, flags)
                    )
                }
                nm.notify(DONE_NOTIFICATION_ID, builder.build())
            } catch (_: Throwable) {
                // A missing notification never fails a finished transfer.
            }
        }

        /** Stop the foreground service. Safe to call when not running. */
        fun stop(context: Context) {
            val intent = Intent(context, TransferService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
                // App is being destroyed — ignore.
            }
        }

        private fun send(
            context: Context,
            action: String,
            title: String,
            text: String,
            progress: Int,
            foreground: Boolean
        ) {
            val intent = Intent(context, TransferService::class.java).apply {
                this.action = action
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
            }
            try {
                if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // Starting from background can be blocked; transfer still
                // proceeds in-app, just without the kept-alive guarantee.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // Held for the life of a transfer so sleep doesn't stall it:
    //  • WifiLock (HIGH_PERF) stops the Wi-Fi radio dropping to power-save,
    //    which is what throttles/kills transfers when the screen turns off.
    //  • Partial WakeLock keeps the CPU running so the download/serve loop
    //    in the Flutter isolate keeps executing while the device sleeps.
    // Both are released in onDestroy / ACTION_STOP so they can never leak.
    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    private fun acquireLocks() {
        try {
            if (wifiLock == null) {
                val wm = applicationContext
                    .getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "mx_clone:transfer").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "mx_clone:transfer"
                ).apply {
                    setReferenceCounted(false)
                    // 60-min safety cap so a crash can't pin the CPU on
                    // forever; refreshed on each ACTION_UPDATE.
                    acquire(60 * 60 * 1000L)
                }
            }
        } catch (_: Throwable) {
            // Locks are an optimization; the transfer still runs without them.
        }
    }

    private fun releaseLocks() {
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {}
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {}
        wifiLock = null
        wakeLock = null
    }

    override fun onDestroy() {
        isRunning = false
        releaseLocks()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                isRunning = false
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                // Refresh the WakeLock's safety timeout so a long transfer
                // never hits the 60-min cap mid-flight.
                try {
                    wakeLock?.acquire(60 * 60 * 1000L)
                } catch (_: Throwable) {}
                ensureChannel()
                val notification = buildNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "Transferring",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, -1)
                )
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, notification)
            }
            else -> {
                acquireLocks()
                ensureChannel()
                val notification = buildNotification(
                    intent?.getStringExtra(EXTRA_TITLE) ?: "Transferring",
                    intent?.getStringExtra(EXTRA_TEXT) ?: "",
                    intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                )
                isRunning = true
                startForeground(NOTIFICATION_ID, notification)
            }
        }
        // START_STICKY: if Android kills us under memory pressure while a
        // transfer runs, recreate the service (with a null intent) so the
        // kept-alive guarantee and the notification come back. The Flutter
        // isolate re-drives the actual transfer on relaunch via its persisted
        // resume state; this just keeps the process priority high meanwhile.
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // The user explicitly wants a transfer to SURVIVE swiping Innocent out
        // of recents. Unlike PlaybackService (music stops when you dismiss the
        // app), a half-finished file transfer is worth keeping: the receiver's
        // resume state is persisted, so even if the OS later kills the process
        // the download picks up where it left off when the app is reopened.
        // So we deliberately do NOT stop here — the foreground service + locks
        // stay, and the transfer keeps running in the background.
        super.onTaskRemoved(rootIntent)
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            CHANNEL_NAME,
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shows progress while Innocent transfers files over Wi-Fi."
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(title: String, text: String, progress: Int): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPi = if (openIntent != null) {
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)
        } else null

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true) // indeterminate
        }
        if (contentPi != null) builder.setContentIntent(contentPi)
        return builder.build()
    }
}
