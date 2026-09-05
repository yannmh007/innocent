package com.innocent.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import io.github.muntashirakon.adb.android.AdbMdns
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread

/**
 * iADB-style "pair from the notification shade" service (v0.90 / Backend 1).
 *
 * The pain this removes: Android only advertises the `_adb-tls-pairing._tcp`
 * mDNS service (and shows the 6-digit code) while the "Pair device with pairing
 * code" dialog is open, so an in-app pairing flow normally forces the user into
 * split-screen / pop-up so BOTH the dialog and the app are visible at once.
 * iADB avoids that by not needing the app in the foreground at all.
 *
 * Design (hardened after v0.89 where the notification never appeared):
 *  - The notification is posted IMMEDIATELY on start, with the RemoteInput reply
 *    action already present — so the moment the user opens the system pairing
 *    dialog and reads the 6-digit code, they can pull down the shade and type it.
 *    (v0.89 waited for mDNS discovery before showing anything; combined with the
 *    missing POST_NOTIFICATIONS grant that meant nothing ever showed.)
 *  - POST_NOTIFICATIONS (Android 13+) is requested by the ADB screen BEFORE this
 *    service starts; without it a foreground-service notification is suppressed.
 *  - A background mDNS discovery runs continuously and, when it finds the pairing
 *    service, updates the notification to "Pairing service found" for confidence
 *    and caches host:port so the pair is fast.
 *  - The reply is delivered to a MANIFEST-declared receiver ([AdbPairReplyReceiver])
 *    — not a receiver registered inside this service — so the code is captured
 *    even if the OS killed the service while the user was in Settings. The
 *    receiver hands the code back to this service (ACTION_PAIR_WITH_CODE), which
 *    does the actual pairing on a worker thread (pairing can take longer than a
 *    BroadcastReceiver is allowed to run).
 *  - Results are broadcast back (ADB_PAIR_RESULT) and forwarded to Flutter.
 *
 * Modeled on [TransferService] / [PlaybackService] for the FGS + notification
 * plumbing. Foreground type is `dataSync` (network discovery).
 */
class AdbPairingService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    @Volatile
    private var discovering = false
    @Volatile
    private var pairing = false

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopEverything()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_PAIR_WITH_CODE -> {
                // Always re-enter the foreground first: the OS may have brought
                // us up fresh to deliver this, and we must satisfy the
                // start-foreground contract within 5s regardless.
                startForeground(NOTIFICATION_ID, buildNotification(STATUS_PAIRING))
                val code = intent.getStringExtra(EXTRA_CODE)
                    ?.trim()?.filter { it.isDigit() } ?: ""
                handlePairing(code)
            }
            else -> {
                // ACTION_START (or a restart): show the reply notification and
                // begin background discovery of the pairing service.
                startForeground(NOTIFICATION_ID, buildNotification(STATUS_WAITING))
                startDiscovery()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        stopEverything()
        super.onDestroy()
    }

    // ---- Discovery (keeps the pairing host:port warm in the background) ----

    private fun startDiscovery() {
        if (discovering) return
        discovering = true
        thread(start = true, isDaemon = true, name = "adb-pair-discover") {
            var mdns: AdbMdns? = null
            try {
                mdns = AdbMdns(
                    applicationContext,
                    AdbMdns.SERVICE_TYPE_TLS_PAIRING,
                ) { host, port ->
                    if (host != null && port > 0) {
                        val was = lastPairingPort.getAndSet(port)
                        lastPairingHost.set(host.hostAddress)
                        // First time we see it, nudge the notification so the
                        // user knows the dialog was detected (iADB shows
                        // "Pairing service found").
                        if (was <= 0 && !pairing) {
                            try {
                                update(STATUS_FOUND)
                            } catch (_: Throwable) {
                            }
                        }
                    }
                }
                mdns.start()
                while (discovering && !Thread.currentThread().isInterrupted) {
                    try {
                        Thread.sleep(1000)
                    } catch (_: InterruptedException) {
                        break
                    }
                }
            } catch (_: Throwable) {
                // Discovery is best-effort; pairWithMdns() also discovers at
                // reply time, so a failure here is not fatal.
            } finally {
                try {
                    mdns?.stop()
                } catch (_: Throwable) {
                }
            }
        }
    }

    // ---- Pairing ----

    private fun handlePairing(code: String) {
        if (pairing) return
        if (code.length < 6) {
            update(STATUS_BAD_CODE)
            broadcastResult(applicationContext, "ERROR: enter the full 6-digit code")
            return
        }
        pairing = true
        update(STATUS_PAIRING)
        thread(start = true, isDaemon = true, name = "adb-pair-do") {
            val result = try {
                // TIER 1: pair AND immediately connect + save the port, while WD
                // is freshly advertising, so the pairing→connection handoff is
                // seamless and later reconnects use the fast saved-port path.
                // (pairWithMdns/autoConnect both discover the right service
                // themselves, so this works even without cached discovery.)
                AdbManager.pairThenConnect(applicationContext, code, 25000L)
            } catch (e: Throwable) {
                "ERROR: ${e.javaClass.simpleName}: ${e.message}"
            }
            val ok = result.startsWith("OK")
            broadcastResult(applicationContext, result)
            pairing = false
            if (ok) {
                update(STATUS_PAIRED)
                try {
                    Thread.sleep(1500)
                } catch (_: Throwable) {
                }
                stopEverything()
                stopSelf()
            } else {
                // Let the user try again with a fresh code — keep discovery and
                // the reply action alive.
                update(STATUS_RETRY)
            }
        }
    }

    private fun broadcastResult(context: Context, result: String) {
        try {
            context.sendBroadcast(
                Intent(ACTION_RESULT)
                    .setPackage(context.packageName)
                    .putExtra(EXTRA_RESULT, result),
            )
        } catch (_: Throwable) {
        }
    }

    private fun stopEverything() {
        discovering = false
        try {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } catch (_: Throwable) {
        }
    }

    // ---- Notification ----

    private fun update(status: Int) {
        try {
            val nm =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(status))
        } catch (_: Throwable) {
        }
    }

    private fun buildNotification(status: Int): Notification {
        val (title, text) = when (status) {
            STATUS_FOUND ->
                "Pairing dialog detected" to
                    "Now type the 6-digit code: tap Reply and enter it."
            STATUS_PAIRING -> "Pairing\u2026" to "Contacting the device over Wi-Fi."
            STATUS_PAIRED -> "Paired & connected \u2713" to
                "Innocent can now read Android/data."
            STATUS_BAD_CODE ->
                "Enter all 6 digits" to "Tap Reply and type the 6-digit code."
            STATUS_RETRY ->
                "Pairing didn't work" to
                    "Re-open \"Pair device with pairing code\" for a fresh " +
                    "code, then tap Reply and enter it."
            else ->
                "Enter the pairing code here" to
                    "Open Wireless debugging \u2192 \"Pair device with pairing " +
                    "code\", then tap Reply and type the 6-digit code. No " +
                    "split-screen needed."
        }

        val remoteInput = RemoteInput.Builder(KEY_CODE)
            .setLabel("6-digit code")
            .build()

        // The reply PendingIntent targets the MANIFEST receiver explicitly, so
        // the typed code is delivered even if this service was killed.
        val replyIntent = Intent(this, AdbPairReplyReceiver::class.java)
            .setAction(ACTION_REPLY)
        val replyFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val replyPending = PendingIntent.getBroadcast(
            this, REQ_REPLY, replyIntent, replyFlags,
        )
        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "Reply",
            replyPending,
        ).addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()

        // Tapping the body opens the app (ADB screen lives inside).
        val openFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val openApp = packageManager.getLaunchIntentForPackage(packageName)
        val contentPending = if (openApp != null) {
            PendingIntent.getActivity(this, REQ_OPEN, openApp, openFlags)
        } else {
            null
        }

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setOngoing(status != STATUS_PAIRED)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
        // Offer the reply action except while actively pairing / after success.
        if (status != STATUS_PAIRED && status != STATUS_PAIRING) {
            builder.addAction(replyAction)
        }
        if (contentPending != null) builder.setContentIntent(contentPending)
        return builder.build()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm =
                getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val ch = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "Lets you enter the ADB pairing code from the " +
                    "notification shade \u2014 no split-screen."
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(ch)
        }
    }

    companion object {
        private const val CHANNEL_ID = "mx_clone_adb_pairing"
        private const val CHANNEL_NAME = "ADB pairing"
        private const val NOTIFICATION_ID = 0xAD01
        private const val REQ_REPLY = 0xAD02
        private const val REQ_OPEN = 0xAD03
        const val KEY_CODE = "adb_pair_code"

        const val ACTION_START = "com.innocent.media.ADB_PAIR_START"
        const val ACTION_STOP = "com.innocent.media.ADB_PAIR_STOP"
        const val ACTION_REPLY = "com.innocent.media.ADB_PAIR_REPLY"
        /** Sent by [AdbPairReplyReceiver] to this service with EXTRA_CODE. */
        const val ACTION_PAIR_WITH_CODE = "com.innocent.media.ADB_PAIR_CODE"
        const val EXTRA_CODE = "code"
        /** Broadcast back to the app with EXTRA_RESULT after a pairing attempt. */
        const val ACTION_RESULT = "com.innocent.media.ADB_PAIR_RESULT"
        const val EXTRA_RESULT = "result"

        private const val STATUS_WAITING = 0
        private const val STATUS_PAIRING = 1
        private const val STATUS_PAIRED = 2
        private const val STATUS_BAD_CODE = 3
        private const val STATUS_RETRY = 4
        private const val STATUS_FOUND = 5

        /** Most recent pairing host:port seen over mDNS (informational). */
        val lastPairingHost = AtomicReference<String?>(null)
        val lastPairingPort = AtomicInteger(-1)

        private fun startWith(context: Context, action: String, code: String?) {
            val intent = Intent(context, AdbPairingService::class.java).apply {
                this.action = action
                if (code != null) putExtra(EXTRA_CODE, code)
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Throwable) {
                // Starting an FGS from the background can be blocked on newer
                // Androids; the ADB screen starts it while visible so this is
                // the safe case. If it still fails, the UI shows no progress and
                // the user can retry.
            }
        }

        fun start(context: Context) = startWith(context, ACTION_START, null)

        /** Deliver a typed code to the running service to complete pairing. */
        fun pairWithCode(context: Context, code: String) =
            startWith(context, ACTION_PAIR_WITH_CODE, code)

        fun stop(context: Context) {
            val intent = Intent(context, AdbPairingService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
            }
        }
    }
}
