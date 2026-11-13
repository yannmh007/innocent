package com.innocent.media

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState

/**
 * THE PLAYER'S OWN MEDIA SESSION, for as long as a film is open (13 Nov).
 *
 * The only video session was the background-play service's (PlaybackService),
 * which exists only while background play is on. In ordinary playback —
 * every film on a TV — Android had no session for the film, so a TV's voice
 * commands ("pause", "skip 30 seconds", "play the next one") and its Now
 * Playing card never reached the player. This one is active while the player
 * is open; with background play on, the service's session (and its
 * notification) is there too, and either one's command reaches the same
 * handler. It shows nothing by itself — no notification.
 *
 * Its commands go the way the notification's buttons do: the same in-app
 * broadcast, received by MainActivity, one handler in Dart
 * (`onPlaybackAction`). A media key while the app is in front still reaches
 * MainActivity.onKeyDown first — Android hands a key to the focused window
 * before any session — so a headset behaves as it did.
 *
 * The framework MediaSession, as PlaybackService uses, for the reason given
 * there (the Music tab's audio_service owns the androidx compat stack).
 * A private film never gets one: its title would reach the system's media
 * surfaces (Dart does not start it for the Private Folder).
 */
class PlayerMediaSession(private val context: Context) {
    private var session: MediaSession? = null

    /** Publish the film's state, starting the session on the first call. */
    fun update(
        title: String,
        isPlaying: Boolean,
        positionMs: Long,
        durationMs: Long,
        speed: Float
    ) {
        val s = session ?: create() ?: return
        try {
            if (durationMs > 0) {
                s.setMetadata(
                    MediaMetadata.Builder()
                        .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                        .putString(MediaMetadata.METADATA_KEY_DISPLAY_TITLE, title)
                        .putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                        .build()
                )
            }
            // The system works the elapsed time out from position, speed and
            // when it was told, so Dart pushes on real changes only.
            s.setPlaybackState(
                PlaybackState.Builder()
                    .setActions(
                        PlaybackState.ACTION_PLAY or
                            PlaybackState.ACTION_PAUSE or
                            PlaybackState.ACTION_PLAY_PAUSE or
                            PlaybackState.ACTION_STOP or
                            PlaybackState.ACTION_SEEK_TO or
                            PlaybackState.ACTION_SKIP_TO_NEXT or
                            PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                            PlaybackState.ACTION_REWIND or
                            PlaybackState.ACTION_FAST_FORWARD
                    )
                    .setState(
                        if (isPlaying) PlaybackState.STATE_PLAYING
                        else PlaybackState.STATE_PAUSED,
                        if (positionMs >= 0) positionMs
                        else PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                        if (isPlaying) speed else 0f
                    )
                    .build()
            )
            s.isActive = true
        } catch (_: Throwable) {
        }
    }

    /** The player closed. */
    fun release() {
        val s = session ?: return
        session = null
        try {
            s.isActive = false
            s.release()
        } catch (_: Throwable) {
        }
    }

    private fun create(): MediaSession? {
        return try {
            MediaSession(context, "InnocentPlayer").apply {
                setCallback(object : MediaSession.Callback() {
                    // Distinct play and pause, never a toggle (PlaybackService).
                    override fun onPlay() = send(MainActivity.PLAYBACK_CONTROL_PLAY)
                    override fun onPause() = send(MainActivity.PLAYBACK_CONTROL_PAUSE)
                    override fun onStop() = send(MainActivity.PLAYBACK_CONTROL_STOP)
                    override fun onSkipToNext() = send(MainActivity.PLAYBACK_CONTROL_NEXT)
                    override fun onSkipToPrevious() =
                        send(MainActivity.PLAYBACK_CONTROL_PREVIOUS)
                    override fun onSeekTo(pos: Long) =
                        send(MainActivity.PLAYBACK_CONTROL_SEEK, pos)
                    override fun onRewind() = send(MainActivity.PLAYBACK_CONTROL_REWIND)
                    override fun onFastForward() =
                        send(MainActivity.PLAYBACK_CONTROL_FORWARD)
                })
                setPlaybackToLocal(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_MEDIA)
                        .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                        .build()
                )
            }.also { session = it }
        } catch (_: Throwable) {
            null
        }
    }

    private fun send(which: String, positionMs: Long = -1L) {
        try {
            context.sendBroadcast(
                Intent(MainActivity.ACTION_PLAYBACK_CONTROL)
                    .setPackage(context.packageName)
                    .putExtra(MainActivity.EXTRA_PLAYBACK_CONTROL, which)
                    .putExtra(MainActivity.EXTRA_PLAYBACK_POSITION, positionMs)
            )
        } catch (_: Throwable) {
        }
    }
}
