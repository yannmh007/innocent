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
 * Keeps an OFFLINE CATALOGUE DOWNLOAD alive while the phone is put down.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * WHY THIS HAD TO EXIST
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Most viewers of this app are in Myanmar, on mobile data, on a connection
 * that is not good enough to stream a film without stopping. What they do
 * instead — what people on such connections everywhere do — is start the
 * download, put the phone in a pocket, and watch it later. That is the whole
 * feature, and until now it did not work.
 *
 * The offline downloader runs entirely in the Flutter isolate: a Dart `http`
 * request writing to a file. Nothing in Android knows that work is happening.
 * So the moment the user pressed Home, or the screen turned off, the process
 * became an ordinary backgrounded app — deprioritised, then frozen, then
 * reclaimed under memory pressure — and a 900 MB film that was forty per cent
 * downloaded simply stopped, with no notification and nothing on screen to
 * say so. On the exact connection where the download was the answer.
 *
 * A foreground service is the only thing Android accepts as "this process is
 * doing work the user asked for". This one does no downloading itself; what
 * it provides is that declaration, a progress notification, and the two locks
 * that stop a sleeping device from stalling the transfer.
 *
 * ═══════════════════════════════════════════════════════════════════════
 * A NEAR-COPY OF [TransferService], DELIBERATELY
 * ═══════════════════════════════════════════════════════════════════════
 *
 * Not a shared base class, for the same reason [DownloadService] is not one:
 * a LAN transfer, a web download and a catalogue download can all be running
 * at once, and each needs its own notification id and channel or they
 * overwrite each other in the shade. The behaviours that were hard-won there
 * are reproduced exactly:
 *
 *  • `onTaskRemoved` does NOT stopSelf — swiping Innocent out of recents must
 *    not throw away forty minutes of somebody's data allowance.
 *  • START_STICKY everywhere except ACTION_STOP.
 *  • Partial WakeLock so screen-off does not stall the write loop, with a
 *    60-minute safety cap refreshed on every ACTION_UPDATE. A film on a slow
 *    connection can take longer than an hour, which is exactly why the
 *    refresh matters here more than anywhere else in this app.
 *  • A WifiLock too, which does nothing at all on mobile data and costs
 *    nothing to hold; it is here for the viewer who started the download on
 *    wifi at home.
 *
 * The manifest declares foregroundServiceType="dataSync".
 */
class OfflineService : Service() {

    companion object {
        private const val CHANNEL_ID = "innocent_offline"
        private const val CHANNEL_NAME = "Offline downloads"

        // Distinct from TransferService (0xAB43), DownloadService (0xAB44) and
        // TransferService's completion notice (0xAB46). Three ongoing
        // notifications can be on screen at once and none of them may replace
        // another.
        private const val NOTIFICATION_ID = 0xAB47
        private const val DONE_NOTIFICATION_ID = 0xAB48

        const val ACTION_START = "com.innocent.media.OFFLINE_START"
        const val ACTION_UPDATE = "com.innocent.media.OFFLINE_UPDATE"
        const val ACTION_STOP = "com.innocent.media.OFFLINE_STOP"

        /** The Pause button on the notification itself. */
        const val ACTION_PAUSE = "com.innocent.media.OFFLINE_PAUSE"

        /**
         * Set by the Pause button, read and cleared by the Dart downloader.
         *
         * WHY A FLAG AND NOT A CALL INTO DART. A notification button arrives in
         * the service, which may have been recreated by START_STICKY with no
         * Activity attached — and the channel that would carry a call to Dart
         * belongs to the Activity's Flutter engine. A flag needs nobody to be
         * listening: the downloader is already asking every couple of seconds
         * while it updates this notification, and if it is not asking then it
         * is not running and there is nothing to pause.
         */
        @Volatile
        var pauseRequested: Boolean = false

        /** Read once and cleared, so one press pauses one download. */
        fun takePauseRequest(): Boolean {
            val v = pauseRequested
            pauseRequested = false
            return v
        }

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress" // 0..100, or <0 for indeterminate

        /**
         * True between ACTION_START and ACTION_STOP. Read the same way
         * [TransferService.isRunning] is: a download deliberately outlives the
         * Activity, so anything that tears down on Activity death has to ask
         * first.
         */
        @Volatile
        var isRunning: Boolean = false
            private set

        fun start(context: Context, title: String, text: String, progress: Int) {
            send(context, ACTION_START, title, text, progress, foreground = true)
        }

        fun update(context: Context, title: String, text: String, progress: Int) {
            send(context, ACTION_UPDATE, title, text, progress, foreground = false)
        }

        /**
         * A dismissible "it is on your phone" notice, posted directly rather
         * than through the service, which is on its way down by then.
         *
         * WORTH MORE HERE THAN ANYWHERE ELSE IN THIS APP. The person who
         * started this download is not looking at the screen — that is the
         * entire reason the download exists — so this notice is how they find
         * out they can watch. Without it they have to keep opening the app to
         * check, on a connection where opening the app costs them data.
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
                        PendingIntent.getActivity(context, 3, open, flags)
                    )
                }
                nm.notify(DONE_NOTIFICATION_ID, builder.build())
            } catch (_: Throwable) {
                // A missing notification never fails a finished download.
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, OfflineService::class.java).apply {
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
            val intent = Intent(context, OfflineService::class.java).apply {
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
                // Starting a foreground service from the background is blocked
                // on newer Android. The download still runs while the app is
                // in front; it just loses the kept-alive guarantee, which is
                // the same position it was in before this class existed.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

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
                wifiLock = wm.createWifiLock(mode, "innocent:offline").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "innocent:offline"
                ).apply {
                    setReferenceCounted(false)
                    acquire(60 * 60 * 1000L)
                }
            }
        } catch (_: Throwable) {
            // Locks are an optimization; the download still runs without them.
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
        pauseRequested = false
        idleHandler.removeCallbacks(idleTimeout)
        releaseLocks()
        super.onDestroy()
    }

    /**
     * Stops the service when Dart stops talking to it.
     *
     * ─── THE LEAK THIS CLOSES ──────────────────────────────────────────────
     *
     * This service keeps the PROCESS alive; it does not keep the Flutter engine
     * alive, and the downloader is Dart code. An Activity that is destroyed —
     * swiped from recents, backed out of, or reclaimed — takes its engine and
     * therefore the download with it, and START_STICKY then recreates this
     * service with a null intent. What was left was a partial WakeLock pinning
     * the CPU and a notification saying "Downloading" beside a download that
     * had stopped: a battery drain and a lie, and neither of them visible to
     * anybody who could act on it.
     *
     * Rather than asserting anything about engine lifetimes — which differ by
     * Android version and by how the app was closed — the service simply
     * requires proof of life. The downloader refreshes this notification every
     * couple of seconds, including while it waits out a lost connection, so
     * three minutes of silence means nothing is downloading. Generous on
     * purpose: the size question can hold the downloader on a dialog, and the
     * cost of waiting too long is a few minutes of WakeLock while the cost of
     * stopping too early is a download that dies for no reason.
     */
    private val idleHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val idleTimeout = Runnable {
        isRunning = false
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun armIdleWatchdog() {
        idleHandler.removeCallbacks(idleTimeout)
        idleHandler.postDelayed(idleTimeout, 3 * 60 * 1000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PAUSE -> {
                // Only a flag and a redraw. The download is Dart's and it will
                // notice within a couple of seconds; stopping the service here
                // would drop the WakeLock out from under the last write.
                pauseRequested = true
                ensureChannel()
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(
                    NOTIFICATION_ID,
                    buildNotification("Pausing…", "", -1, pausable = false)
                )
                armIdleWatchdog()
                return START_STICKY
            }
            ACTION_STOP -> {
                isRunning = false
                idleHandler.removeCallbacks(idleTimeout)
                pauseRequested = false
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                // A film on a bad connection can take hours. Refreshing the
                // cap on every progress update is what stops the WakeLock
                // expiring in the middle of one.
                try {
                    wakeLock?.acquire(60 * 60 * 1000L)
                } catch (_: Throwable) {}
                armIdleWatchdog()
                ensureChannel()
                val notification = buildNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, -1)
                )
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, notification)
            }
            else -> {
                acquireLocks()
                armIdleWatchdog()
                ensureChannel()
                val notification = buildNotification(
                    intent?.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                    intent?.getStringExtra(EXTRA_TEXT) ?: "",
                    intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                )
                isRunning = true
                startForeground(NOTIFICATION_ID, notification)
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Deliberately NOT stopping. Swiping the app away is not a decision to
        // throw away a part-finished download — the bytes on disk and the data
        // they cost are the user's, and the downloader resumes from them.
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
            description = "Shows progress while Innocent downloads a title to watch offline."
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        pausable: Boolean = true
    ): Notification {
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPi = if (openIntent != null) {
            PendingIntent.getActivity(this, 2, openIntent, pendingFlags)
        } else null

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)

        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }
        if (contentPi != null) builder.setContentIntent(contentPi)
        // PAUSE ON THE NOTIFICATION, which is where the download is being
        // watched from. Somebody who started a two-hour download and then
        // needed their data for something else had to find the app, find the
        // title and find the control; every other download in the shade — a
        // browser's, a chat app's — can be stopped where it is shown.
        //
        // PAUSE AND NOT CANCEL. What this does is keep the bytes: discarding
        // them is destructive, it cannot be undone, and a destructive button
        // beside a progress bar in the shade is a mis-tap waiting to happen.
        // Discarding lives on the Downloads screen, next to a figure saying
        // how much would be thrown away.
        if (pausable) {
            val pauseIntent = Intent(this, OfflineService::class.java).apply {
                action = ACTION_PAUSE
            }
            builder.addAction(
                android.R.drawable.ic_media_pause,
                "Pause",
                PendingIntent.getService(this, 4, pauseIntent, pendingFlags)
            )
        }
        return builder.build()
    }
}
