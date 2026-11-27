package com.innocent.media

import android.media.audiofx.DynamicsProcessing
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Night mode and loudness levelling for libmpv's sound (27 Nov 2026,
 * docs/handoff_2026_11_27_beyond_mx.md P4).
 *
 * WHY HERE. libmpv's Android build (media_kit, libmpv-android-video-build
 * v1.1.11) carries libavfilter with almost no filters: `dynaudnorm`,
 * `acompressor`, `alimiter` are not in libmpv.so (read from the jar, 27
 * Nov), so the `af` the player set for "loudness normalization" did
 * nothing on any phone. libmpv's AudioTrack plays on the app's own audio
 * session (the Equalizer's, `audiotrack-session-id`), and Android's
 * DynamicsProcessing (API 28) works on a session: a one-band compressor
 * and a limiter, the same curve as ExoPlayer's [com.innocent.media.audio.AudioShape]
 * for Night (threshold -28 dB, 4:1, a 6 dB knee, attack 5 ms, release
 * 150 ms, +10 dB, nothing past -1 dBFS), gentler for levelling (-24 dB,
 * 2:1, +6 dB). Below Android 9 it answers false and the player says so.
 */
object SessionDynamics {
    private const val CHANNEL = "innocent/dynamics"
    const val OFF = 0
    const val NIGHT = 1
    const val LEVEL = 2

    private var dp: DynamicsProcessing? = null
    private var session = 0
    private var mode = OFF

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "set" -> result.success(
                        set(call.argument<Int>("session") ?: 0, call.argument<Int>("mode") ?: OFF))
                    "available" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.P)
                    else -> result.notImplemented()
                }
            }
    }

    /** [m] on [sid] (a session libmpv plays on); false when it cannot be. */
    fun set(sid: Int, m: Int): Boolean {
        if (m == OFF || sid == 0) {
            release()
            return m == OFF
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return false
        if (dp != null && session == sid && mode == m) return true
        release()
        return try {
            val cfg = DynamicsProcessing.Config.Builder(
                DynamicsProcessing.VARIANT_FAVOR_FREQUENCY_RESOLUTION, 2,
                false, 0, true, 1, false, 0, true,
            ).build()
            val d = DynamicsProcessing(0, sid, cfg)
            val night = m == NIGHT
            d.setMbcBandAllChannelsTo(0, DynamicsProcessing.MbcBand(
                true, 20000f, 5f, 150f,
                if (night) 4f else 2f,
                if (night) -28f else -24f,
                6f, -90f, 1f, 0f,
                if (night) 10f else 6f,
            ))
            d.setLimiterAllChannelsTo(DynamicsProcessing.Limiter(
                true, true, 0, 1f, 60f, 10f, -1f, 0f))
            d.enabled = true
            dp = d
            session = sid
            mode = m
            true
        } catch (t: Throwable) {
            release()
            false
        }
    }

    private fun release() {
        try {
            dp?.release()
        } catch (_: Throwable) {
        }
        dp = null
        session = 0
        mode = OFF
    }
}
