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
import java.util.Locale

/**
 * Keeps a COPY OUT OF ANDROID/DATA alive while it runs.
 *
 * A copy over the phone's own wireless-debugging connection is a long read
 * on one socket, and three ordinary things ended it half way:
 *
 *  • The viewer pressed Home. The process became an ordinary background app,
 *    was frozen, and the copy stopped with nothing on screen to say so.
 *  • The screen went off. The CPU slept between reads.
 *  • The Wi-Fi radio dozed. Wireless debugging lives on the Wi-Fi network —
 *    Android turns it off when the phone leaves that network — and a radio
 *    in power save is the commonest way a long ADB session dies.
 *
 * So, like [OfflineService] for catalogue downloads: a foreground service
 * (the one thing Android accepts as "the user asked for this work"), a
 * partial wake lock, and a Wi-Fi lock in low-latency mode, held only while a
 * copy runs and released the moment the last one ends. It does no copying
 * itself; the copy runs where it always did ([AdbManager.pullForPlayback],
 * [AdbManager.pullToVault]), which also resumes after a drop.
 *
 * Several copies may run at once (a bulk "send to Transfer"); the service
 * counts them and stays up until all have ended. Swiping the app out of
 * recents does not stop it — the copy is the thing the viewer asked for.
 *
 * The manifest declares foregroundServiceType="dataSync".
 */
class AdbWorkService : Service() {

    companion object {
        private const val CHANNEL_ID = "innocent_adb_work"

        // Distinct from every other ongoing notification (0xAB42..0xAB48,
        // the pairing service's 0xAD01).
        private const val NOTIFICATION_ID = 0xAB49

        private const val ACTION_START = "com.innocent.media.ADB_WORK_START"
        private const val ACTION_UPDATE = "com.innocent.media.ADB_WORK_UPDATE"
        private const val ACTION_STOP = "com.innocent.media.ADB_WORK_STOP"
        private const val EXTRA_NAME = "name"
        private const val EXTRA_PERCENT = "percent"

        /** The copies running now, by source path. */
        private val running = LinkedHashSet<String>()

        /** Last percent sent per source, so the shade is not flooded. */
        private val lastPercent = HashMap<String, Int>()

        @Volatile
        var isRunning: Boolean = false
            private set

        fun begin(context: Context, src: String) {
            val first: Boolean
            synchronized(running) {
                first = running.isEmpty()
                running.add(src)
                lastPercent.remove(src)
            }
            if (first) send(context, ACTION_START, nameOf(src), -1, foreground = true)
        }

        fun progress(context: Context, src: String, done: Long, total: Long) {
            val pct = if (total > 0L) ((done * 100) / total).toInt().coerceIn(0, 100) else -1
            synchronized(running) {
                if (lastPercent[src] == pct) return
                lastPercent[src] = pct
            }
            send(context, ACTION_UPDATE, nameOf(src), pct, foreground = false)
        }

        fun end(context: Context, src: String) {
            val last: Boolean
            synchronized(running) {
                running.remove(src)
                lastPercent.remove(src)
                last = running.isEmpty()
            }
            if (last) {
                try {
                    context.startService(
                        Intent(context, AdbWorkService::class.java).apply { action = ACTION_STOP },
                    )
                } catch (_: Throwable) {
                }
            }
        }

        private fun nameOf(src: String): String =
            src.substringAfterLast('/').ifEmpty { src }

        private fun send(
            context: Context,
            action: String,
            name: String,
            percent: Int,
            foreground: Boolean,
        ) {
            val intent = Intent(context, AdbWorkService::class.java).apply {
                this.action = action
                putExtra(EXTRA_NAME, name)
                putExtra(EXTRA_PERCENT, percent)
            }
            try {
                if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // Not allowed from the background on newer Android: the copy
                // still runs while the app is in front, and still resumes.
            }
        }

        private fun burmese(): Boolean = Locale.getDefault().language == "my"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private var wifiLock: WifiManager.WifiLock? = null
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                isRunning = false
                releaseLocks()
                stopForegroundCompat()
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val name = intent?.getStringExtra(EXTRA_NAME) ?: ""
                val pct = intent?.getIntExtra(EXTRA_PERCENT, -1) ?: -1
                val n = build(name, pct)
                if (intent?.action == ACTION_UPDATE && !isRunning) {
                    // An update for a service that never made it to the
                    // foreground (not allowed then): nothing to show.
                    stopSelf()
                    return START_NOT_STICKY
                }
                if (intent?.action == ACTION_START) {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            startForeground(
                                NOTIFICATION_ID,
                                n,
                                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                            )
                        } else {
                            startForeground(NOTIFICATION_ID, n)
                        }
                        isRunning = true
                        acquireLocks()
                    } catch (_: Throwable) {
                        stopSelf()
                        return START_NOT_STICKY
                    }
                } else {
                    try {
                        (getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager)
                            .notify(NOTIFICATION_ID, n)
                    } catch (_: Throwable) {
                    }
                }
            }
        }
        // Not sticky: a restarted service with no copy behind it would only
        // hold locks for nothing. The copy itself resumes from its part file
        // the next time it is asked for.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        releaseLocks()
        super.onDestroy()
    }

    private fun build(name: String, percent: Int): Notification {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(CHANNEL_ID) == null
        ) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    if (burmese()) "Android/data မှ ကူးယူခြင်း" else "Android/data copies",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
        val title = if (burmese()) {
            "Android/data မှ ကူးယူနေသည်"
        } else {
            "Copying from Android/data"
        }
        val text = if (percent >= 0) "$name · $percent%" else name
        val open = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(100, percent.coerceAtLeast(0), percent < 0)
        if (open != null) b.setContentIntent(PendingIntent.getActivity(this, 9, open, piFlags))
        return b.build()
    }

    private fun acquireLocks() {
        try {
            if (wifiLock == null) {
                val wm = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "innocent:adb-work").apply {
                    setReferenceCounted(false)
                    acquire()
                }
            }
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "innocent:adb-work").apply {
                    setReferenceCounted(false)
                    // A cap, in case a copy never reports its end: an hour.
                    acquire(60 * 60 * 1000L)
                }
            }
        } catch (_: Throwable) {
            // Locks help; the copy runs (and resumes) without them.
        }
    }

    private fun releaseLocks() {
        try {
            wifiLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
        }
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {
        }
        wifiLock = null
        wakeLock = null
    }

    private fun stopForegroundCompat() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
        } catch (_: Throwable) {
        }
    }
}
