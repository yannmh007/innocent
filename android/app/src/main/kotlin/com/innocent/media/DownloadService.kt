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
 * v0.99 Downloader: foreground service that keeps a yt-dlp download alive while
 * the user leaves Innocent (Home, app switch, or swiping the app out of
 * recents) and shows its progress in the notification shade.
 *
 * Deliberately a near-copy of [TransferService] rather than a shared base
 * class: the two run concurrently (a LAN transfer and a web download at the
 * same time is a normal thing to do) and each needs its OWN notification id
 * and channel, so sharing one service instance would have them overwrite each
 * other's notification. The behaviours that were hard-won in TransferService
 * are reproduced exactly:
 *
 *  • onTaskRemoved does NOT stopSelf — swiping the app away must not kill an
 *    in-flight download.
 *  • START_STICKY everywhere except ACTION_STOP (which returns
 *    START_NOT_STICKY so an intentional stop leaves no zombie service).
 *  • WifiLock + partial WakeLock so screen-off doesn't stall the transfer, with
 *    a 60-minute safety cap refreshed on every ACTION_UPDATE.
 *
 * Unlike TransferService the actual work here runs in [DownloadEngine]'s
 * executor inside our own process (yt-dlp is a child process of ours), so this
 * service is precisely what stops Android reclaiming that process mid-download.
 */
class DownloadService : Service() {

    companion object {
        private const val CHANNEL_ID = "mx_clone_downloader"
        private const val CHANNEL_NAME = "Downloads"
        private const val NOTIFICATION_ID = 0xAB44

        const val ACTION_START = "com.innocent.media.DOWNLOAD_START"
        const val ACTION_UPDATE = "com.innocent.media.DOWNLOAD_UPDATE"
        const val ACTION_STOP = "com.innocent.media.DOWNLOAD_STOP"

        /** Buttons on the notification itself. */
        const val ACTION_PAUSE = "com.innocent.media.DOWNLOAD_PAUSE"
        const val ACTION_CANCEL = "com.innocent.media.DOWNLOAD_CANCEL"
        const val ACTION_RESUME = "com.innocent.media.DOWNLOAD_RESUME"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress" // 0..100, or <0 for indeterminate
        const val EXTRA_JOB_ID = "jobId"

        /**
         * True while this job is paused, so the button can offer the opposite.
         *
         * A NOTIFICATION THAT ONLY EVER OFFERS PAUSE IS HALF A CONTROL. The
         * moment somebody wants a download back is the same moment they are
         * looking at the shade — and until now the only way was to open the
         * app, find the row, and press it there.
         */
        const val EXTRA_PAUSED = "paused"

        fun start(
            context: Context,
            title: String,
            text: String,
            progress: Int,
            jobId: String
        ) {
            send(context, ACTION_START, title, text, progress, jobId, foreground = true)
        }

        /** Redraws the notification for a job that is now paused. */
        fun markPaused(context: Context, title: String, jobId: String) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, "Paused")
                putExtra(EXTRA_PROGRESS, -1)
                putExtra(EXTRA_JOB_ID, jobId)
                putExtra(EXTRA_PAUSED, true)
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
            }
        }

        fun update(
            context: Context,
            title: String,
            text: String,
            progress: Int,
            jobId: String
        ) {
            send(context, ACTION_UPDATE, title, text, progress, jobId, foreground = false)
        }

        /** Safe to call when not running. */
        fun stop(context: Context) {
            val intent = Intent(context, DownloadService::class.java).apply {
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
            jobId: String,
            foreground: Boolean
        ) {
            val intent = Intent(context, DownloadService::class.java).apply {
                this.action = action
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_TEXT, text)
                putExtra(EXTRA_PROGRESS, progress)
                putExtra(EXTRA_JOB_ID, jobId)
            }
            try {
                if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // Starting from the background can be blocked on newer Android;
                // the download still proceeds, just without the kept-alive
                // guarantee.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    /** The job the current notification is about, so its buttons act on it. */
    private var jobId: String? = null

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
                wifiLock = wm.createWifiLock(mode, "mx_clone:downloader").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "mx_clone:downloader"
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
        releaseLocks()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            // Pause and cancel from the shade. Worth having because the moment
            // someone wants to stop a download is usually the moment they are
            // looking at its notification, not at the app.
            ACTION_PAUSE -> {
                intent.getStringExtra(EXTRA_JOB_ID)?.let { DownloadEngine.pauseJob(it) }
                return START_NOT_STICKY
            }
            ACTION_CANCEL -> {
                intent.getStringExtra(EXTRA_JOB_ID)?.let { DownloadEngine.cancelJob(it) }
                return START_NOT_STICKY
            }
            ACTION_RESUME -> {
                intent.getStringExtra(EXTRA_JOB_ID)?.let { DownloadEngine.requestResume(it) }
                return START_NOT_STICKY
            }
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                try {
                    wakeLock?.acquire(60 * 60 * 1000L)
                } catch (_: Throwable) {}
                intent.getStringExtra(EXTRA_JOB_ID)?.let { jobId = it }
                ensureChannel()
                val notification = buildNotification(
                    intent.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                    intent.getStringExtra(EXTRA_TEXT) ?: "",
                    intent.getIntExtra(EXTRA_PROGRESS, -1),
                    intent.getBooleanExtra(EXTRA_PAUSED, false)
                )
                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.notify(NOTIFICATION_ID, notification)
            }
            else -> {
                acquireLocks()
                jobId = intent?.getStringExtra(EXTRA_JOB_ID)
                ensureChannel()
                val notification = buildNotification(
                    intent?.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                    intent?.getStringExtra(EXTRA_TEXT) ?: "",
                    intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                )
                startForeground(NOTIFICATION_ID, notification)
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping Innocent out of recents must NOT abort a download in flight.
        // Deliberately no stopSelf here.
        super.onTaskRemoved(rootIntent)
    }

    private fun servicePendingIntent(
        action: String,
        id: String,
        requestCode: Int,
        flags: Int
    ): PendingIntent {
        val intent = Intent(this, DownloadService::class.java).apply {
            this.action = action
            putExtra(EXTRA_JOB_ID, id)
        }
        return PendingIntent.getService(this, requestCode, intent, flags)
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
            description = "Shows progress while Innocent downloads media from the web."
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
        paused: Boolean = false
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
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)
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

        // Distinct request codes per action, or the second PendingIntent would
        // reuse the first's extras and both buttons would do the same thing.
        jobId?.let { id ->
            // THE OPPOSITE OF WHAT IS HAPPENING. A paused download offered a
            // Pause button, which does nothing anyone wants; the one thing to
            // do from here is start it again.
            if (paused) {
                builder.addAction(
                    android.R.drawable.ic_media_play,
                    "Resume",
                    servicePendingIntent(ACTION_RESUME, id, 3, pendingFlags)
                )
            } else {
                builder.addAction(
                    android.R.drawable.ic_media_pause,
                    "Pause",
                    servicePendingIntent(ACTION_PAUSE, id, 1, pendingFlags)
                )
            }
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                servicePendingIntent(ACTION_CANCEL, id, 2, pendingFlags)
            )
        }
        return builder.build()
    }
}
