package com.innocent.media

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.media.AudioAttributes
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.IBinder
import android.os.PowerManager

/**
 * Phase 45: lightweight foreground service that lets the app continue
 * audio playback (and media_kit/libmpv decoding) after the user backs
 * out of the player screen, presses Home, OR the screen goes to sleep.
 *
 * The service does NOT do any decoding itself — media_kit's libmpv
 * audio thread is what actually produces sound. What this service
 * gives us is the system-level guarantee that Android will not stop
 * our process or throttle our audio thread while playback is meant to
 * continue. Without a foreground service the system can kill the
 * background process during deep Doze, especially on aggressive
 * Chinese OEM phones (Xiaomi, Huawei, Oppo).
 *
 * The notification is intentionally minimal — title + "Playing in
 * background" subtitle. A future phase could add MediaSession +
 * media-style notification with play/pause/skip controls.
 */
class PlaybackService : Service() {

    companion object {
        private const val CHANNEL_ID = "mx_clone_playback"
        private const val CHANNEL_NAME = "Background Playback"
        private const val NOTIFICATION_ID = 0xAB42

        const val ACTION_START = "com.innocent.media.PLAYBACK_START"
        const val ACTION_STOP = "com.innocent.media.PLAYBACK_STOP"
        // v1.51: refresh the notification (title / play-pause icon) without
        // restarting the service or re-taking the WakeLock.
        const val ACTION_UPDATE = "com.innocent.media.PLAYBACK_UPDATE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_PLAYING = "isPlaying"
        const val EXTRA_POSITION = "positionMs"
        const val EXTRA_DURATION = "durationMs"

        /** Start the foreground service. Idempotent — repeated calls update the title. */
        fun start(
            context: Context,
            title: String,
            positionMs: Long = -1L,
            durationMs: Long = -1L
        ) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_POSITION, positionMs)
                putExtra(EXTRA_DURATION, durationMs)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /**
         * v1.51 — MX parity. MX Player's background-play notification is not a
         * dead label: it carries transport controls, which is the whole point
         * of a notification you cannot see the screen behind. Updating it is
         * separate from [start] so a play/pause tap does not re-acquire the
         * WakeLock or re-enter the foreground state.
         */
        fun update(
            context: Context,
            title: String,
            isPlaying: Boolean,
            positionMs: Long = -1L,
            durationMs: Long = -1L
        ) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                action = ACTION_UPDATE
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_PLAYING, isPlaying)
                putExtra(EXTRA_POSITION, positionMs)
                putExtra(EXTRA_DURATION, durationMs)
            }
            try {
                context.startService(intent)
            } catch (_: Throwable) {
                // Service not running (or app shutting down) — nothing to update.
            }
        }

        /** Stop the foreground service. Safe to call when not running. */
        fun stop(context: Context) {
            val intent = Intent(context, PlaybackService::class.java).apply {
                action = ACTION_STOP
            }
            // Use startService for the stop so we always reach onStartCommand,
            // which then calls stopSelf cleanly. Calling stopService directly
            // can lose the notification on some OEMs.
            try {
                context.startService(intent)
            } catch (_: Throwable) {
                // App is being destroyed — ignore.
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // A partial WakeLock keeps the CPU running while background audio plays.
    // The foreground service alone stops the PROCESS being killed, but on a
    // sleeping device the CPU can still suspend and silence libmpv's audio
    // thread — the WakeLock is what actually keeps decoding alive with the
    // screen off. Released the moment playback stops so it can't drain the
    // battery. (No WifiLock here: local file playback doesn't need Wi-Fi;
    // network streams are not a use case for this service.)
    private var wakeLock: PowerManager.WakeLock? = null

    /**
     * v1.61 — has this instance actually entered the foreground?
     *
     * THE BUG THIS FIXES. `update()` reaches the service with `startService`,
     * which on a live app SUCCEEDS EVEN WHEN THE SERVICE IS NOT RUNNING — it
     * creates a fresh instance. That instance took the ACTION_UPDATE branch,
     * which never calls startForeground, and posted the ongoing notification
     * with `NotificationManager.notify`. The old comment claimed such an
     * update would be "dropped by notify() targeting an id that isn't shown",
     * which is simply not how notify() works: it CREATES the notification if
     * it is not there. The result was an ongoing notification with no
     * foreground service behind it and nothing that would ever remove it —
     * the notification that stayed on screen after playback had stopped.
     */
    private var isForeground = false

    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "mx_clone:playback"
                ).apply {
                    setReferenceCounted(false)
                    // No timeout: audio can legitimately play for hours. It's
                    // released deterministically on ACTION_STOP / onDestroy /
                    // onTaskRemoved, so it can't leak past playback.
                    acquire()
                }
            }
        } catch (_: Throwable) {
            // WakeLock is an enhancement; playback still works without it.
        }
    }

    /** Keep the last known progress; -1 from Dart means "unchanged". */
    private fun rememberProgress(intent: Intent?) {
        val pos = intent?.getLongExtra(EXTRA_POSITION, -1L) ?: -1L
        val dur = intent?.getLongExtra(EXTRA_DURATION, -1L) ?: -1L
        if (pos >= 0) lastPosition = pos
        if (dur > 0) lastDuration = dur
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (_: Throwable) {}
        wakeLock = null
    }

    override fun onDestroy() {
        isForeground = false
        releaseWakeLock()
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Throwable) {}
        mediaSession = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseWakeLock()
                stopForeground(STOP_FOREGROUND_REMOVE)
                isForeground = false
                // Belt and braces: if anything ever posted this id outside of
                // startForeground, stopForeground would not take it down.
                try {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                        as NotificationManager
                    nm.cancel(NOTIFICATION_ID)
                } catch (_: Throwable) {}
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                // An update is only meaningful for a service that is already
                // showing the notification. If this instance was created BY
                // this very intent, there is nothing to refresh — post nothing
                // and go away again, or we leak an ownerless ongoing
                // notification (see [isForeground]).
                if (!isForeground) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                // `when (intent?.action)` does NOT smart-cast `intent` to
                // non-null inside the branch, so the safe call is required.
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: lastTitle
                val playing =
                    intent?.getBooleanExtra(EXTRA_PLAYING, lastPlaying)
                        ?: lastPlaying
                lastTitle = title
                lastPlaying = playing
                rememberProgress(intent)
                publishSession(title, playing, lastPosition, lastDuration)
                try {
                    ensureChannel()
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE)
                            as NotificationManager
                    nm.notify(NOTIFICATION_ID, buildNotification(title, playing))
                } catch (_: Throwable) {}
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Playing"
                val playing = intent?.getBooleanExtra(EXTRA_PLAYING, true) ?: true
                lastTitle = title
                lastPlaying = playing
                rememberProgress(intent)
                publishSession(title, playing, lastPosition, lastDuration)
                ensureChannel()
                val notification = buildNotification(title, playing)
                startForeground(NOTIFICATION_ID, notification)
                isForeground = true
                acquireWakeLock()
            }
        }
        // START_NOT_STICKY: if Android kills us under memory pressure,
        // don't auto-restart — the user already left playback if that
        // happens, so silently dying is correct.
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // User swiped the app away from the recents list → stop playback.
        // This matches MX Player's behavior: the persistent notification
        // doesn't survive a task removal.
        releaseWakeLock()
        stopForeground(STOP_FOREGROUND_REMOVE)
        isForeground = false
        stopSelf()
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
            description = "Lets Innocent keep playing audio when the app is in background."
            setShowBadge(false)
            enableLights(false)
            enableVibration(false)
            setSound(null, null)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }
        nm.createNotificationChannel(channel)
    }

    // Remembered so an ACTION_UPDATE that only carries one of the two fields
    // (or arrives with neither) still rebuilds a correct notification.
    private var lastTitle: String = "Playing"
    private var lastPlaying: Boolean = true
    private var lastPosition: Long = -1L
    private var lastDuration: Long = -1L

    /**
     * v1.55 — the last real gap against MX Player.
     *
     * Everything the transport buttons on the notification could already do,
     * a MediaSession does better and in more places: the lock screen and the
     * shade's media panel, wired headset buttons, Bluetooth car controls and
     * watches. It is also how Android itself decides what "media" means —
     * an app holding an ACTIVE session with a PLAYING state is treated
     * differently by the audio policy and, in practice, by the OEM battery
     * managers that are most of the reason background audio is hard here.
     * On Android 14+ a `mediaPlayback` foreground service is expected to
     * have one.
     *
     * Deliberately the FRAMEWORK MediaSession rather than MediaSessionCompat:
     * the Music tab already runs its own session through audio_service, which
     * brings the androidx.media stack with it, and two owners of the same
     * compat layer is a class of bug worth not having. minSdk is 24, so the
     * framework API is available unconditionally.
     */
    private var mediaSession: MediaSession? = null

    override fun onCreate() {
        super.onCreate()
        try {
            mediaSession = MediaSession(this, "InnocentPlayback").apply {
                setCallback(object : MediaSession.Callback() {
                    // Distinct play and pause, never a toggle: the system
                    // knows which state it is asking for, and folding them
                    // together inverts playback the moment the two disagree.
                    override fun onPlay() =
                        broadcast(MainActivity.PLAYBACK_CONTROL_PLAY)

                    override fun onPause() =
                        broadcast(MainActivity.PLAYBACK_CONTROL_PAUSE)

                    override fun onStop() =
                        broadcast(MainActivity.PLAYBACK_CONTROL_STOP)

                    override fun onSkipToNext() =
                        broadcast(MainActivity.PLAYBACK_CONTROL_NEXT)

                    override fun onSkipToPrevious() =
                        broadcast(MainActivity.PLAYBACK_CONTROL_PREVIOUS)

                    override fun onSeekTo(pos: Long) =
                        broadcast(MainActivity.PLAYBACK_CONTROL_SEEK, pos)
                })
                // Tell the framework which stream this session speaks for.
                // Without it the session is not associated with a stream, so
                // the volume keys and the media-output picker have nothing to
                // attach to. CONTENT_TYPE_MOVIE rather than MUSIC because that
                // is what this is, and some devices route and duck on it.
                setPlaybackToLocal(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
                isActive = true
            }
        } catch (_: Throwable) {
            // A session is an enhancement; the service still works without it.
            mediaSession = null
        }
    }

    /**
     * Route a session command back to Flutter through the same internal
     * broadcast the notification buttons use, so there is one path in and one
     * handler on the Dart side.
     */
    private fun broadcast(which: String, positionMs: Long = -1L) {
        try {
            sendBroadcast(
                Intent(MainActivity.ACTION_PLAYBACK_CONTROL)
                    .setPackage(packageName)
                    .putExtra(MainActivity.EXTRA_PLAYBACK_CONTROL, which)
                    .putExtra(MainActivity.EXTRA_PLAYBACK_POSITION, positionMs)
            )
        } catch (_: Throwable) {}
    }

    /** Push what we know into the session so the system UI is truthful. */
    private fun publishSession(
        title: String,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long
    ) {
        val session = mediaSession ?: return
        try {
            if (durationMs > 0) {
                session.setMetadata(
                    MediaMetadata.Builder()
                        .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                        .putString(
                            MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title
                        )
                        .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                        .build()
                )
            }
            // The system extrapolates the elapsed time from position + speed +
            // the update timestamp, so this only has to be pushed on real
            // state changes — not on every tick.
            val state = PlaybackState.Builder()
                .setActions(
                    PlaybackState.ACTION_PLAY or
                        PlaybackState.ACTION_PAUSE or
                        PlaybackState.ACTION_PLAY_PAUSE or
                        PlaybackState.ACTION_STOP or
                        PlaybackState.ACTION_SEEK_TO or
                        PlaybackState.ACTION_SKIP_TO_NEXT or
                        PlaybackState.ACTION_SKIP_TO_PREVIOUS
                )
                .setState(
                    if (isPlaying) PlaybackState.STATE_PLAYING
                    else PlaybackState.STATE_PAUSED,
                    if (positionMs >= 0) positionMs
                    else PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    if (isPlaying) 1.0f else 0.0f
                )
                .build()
            session.setPlaybackState(state)
            session.isActive = true
        } catch (_: Throwable) {}
    }

    /**
     * A same-app broadcast PendingIntent for one transport button.
     * `setPackage` keeps it internal; MainActivity holds the receiver.
     */
    private fun controlIntent(which: String, requestCode: Int): PendingIntent? {
        return try {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
            PendingIntent.getBroadcast(
                this,
                requestCode,
                Intent(MainActivity.ACTION_PLAYBACK_CONTROL)
                    .setPackage(packageName)
                    .putExtra(MainActivity.EXTRA_PLAYBACK_CONTROL, which),
                flags
            )
        } catch (_: Throwable) {
            null
        }
    }

    private fun buildNotification(title: String, isPlaying: Boolean): Notification {
        // Tap the notification → bring the player Activity back to front.
        val openIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val contentPi = if (openIntent != null) {
            PendingIntent.getActivity(this, 0, openIntent, pendingFlags)
        } else null

        // The notification button now sends a DEFINITE play or pause rather
        // than the old toggle, because the button and the session should not
        // disagree about what "the other state" means.
        val playPause = if (isPlaying) {
            MainActivity.PLAYBACK_CONTROL_PAUSE
        } else {
            MainActivity.PLAYBACK_CONTROL_PLAY
        }
        val playPausePi = controlIntent(playPause, 1)
        val stopPi = controlIntent(MainActivity.PLAYBACK_CONTROL_STOP, 2)

        // RESEARCH CORRECTION (v1.55.1) — this was a NotificationCompat build
        // that merely stuffed the session token into `EXTRA_MEDIA_SESSION` and
        // assumed the system would pick it up. It would not have. Google's own
        // guidance is explicit that the media card on the lock screen and in
        // the shade's media panel comes from a **MediaStyle notification with a
        // valid session token** — the style is the contract, not the extra.
        //
        // So this builds with the FRAMEWORK Notification.Builder and
        // Notification.MediaStyle. That keeps the zero-new-dependency position
        // (androidx's MediaStyle would drag in androidx.media, whose
        // MediaSessionCompat.Token this framework session does not natively
        // speak) and it takes our token directly. minSdk is 24, so the only
        // branch needed is the channel, which arrived in 26.
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }

        builder
            .setContentTitle(title)
            .setContentText(if (isPlaying) "Playing in background" else "Paused")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setOngoing(true)
            .setShowWhen(false)
            // CATEGORY_TRANSPORT is how the system knows this is media at all;
            // CATEGORY_SERVICE told it we were a housekeeping task.
            .setCategory(Notification.CATEGORY_TRANSPORT)
            // The bare minimum for anything to show on a secured lock screen.
            .setVisibility(Notification.VISIBILITY_PUBLIC)

        if (contentPi != null) builder.setContentIntent(contentPi)
        if (playPausePi != null) {
            @Suppress("DEPRECATION")
            builder.addAction(
                if (isPlaying) android.R.drawable.ic_media_pause
                else android.R.drawable.ic_media_play,
                if (isPlaying) "Pause" else "Play",
                playPausePi
            )
        }
        if (stopPi != null) {
            @Suppress("DEPRECATION")
            builder.addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop",
                stopPi
            )
        }

        val token = mediaSession?.sessionToken
        if (token != null) {
            val style = Notification.MediaStyle().setMediaSession(token)
            // Which actions collapse into the compact row. Play/pause first —
            // it is the one people reach for without looking.
            if (playPausePi != null && stopPi != null) {
                style.setShowActionsInCompactView(0, 1)
            } else if (playPausePi != null || stopPi != null) {
                style.setShowActionsInCompactView(0)
            }
            builder.setStyle(style)
        }

        return builder.build()
    }
}
