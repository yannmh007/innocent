package com.innocent.media

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * What Innocent asks of the display's refresh rate (27 Nov 2026,
 * docs/handoff_2026_11_27_beyond_mx.md P2 and P3, the owner's answers:
 * "seamless only" and "120 Hz only while touching").
 *
 * P2, A FILM AT ITS OWN RATE. A 23.976 fps film on a 60 Hz display shows
 * its frames for 3, 2, 3, 2 refreshes (judder); on a display that can run
 * at a multiple (120 = 5 x 24) every frame lasts the same. Android picks
 * the display's mode from the layers' votes (Surface.setFrameRate). The
 * film reaches the screen through Flutter's own SurfaceView (the video is
 * a texture inside Flutter's frame), and Media3's vote goes to the
 * ImageReader it decodes into, which no display shows — so the vote is
 * cast here, on Flutter's surface: the film's exact rate, FIXED_SOURCE,
 * and only if the switch is seamless (no black moment; the owner's
 * choice), 0 when it pauses or closes.
 *
 * P3, 120 HZ WHILE TOUCHED. Flutter never asks for more than the system
 * gives it (flutter/flutter#35162). While a finger is on the screen (and a
 * moment after, for a fling) the highest rate the display offers at its
 * resolution; then the film's vote again, or none — battery between.
 *
 * THE FILM ON ITS OWN SURFACE (P1, 28 Nov 2026). While the film plays on
 * a SurfaceView of its own (ExoStreamEngine's film surface), Media3 casts
 * the film's vote on that surface itself (VideoFrameReleaseHelper: the
 * film's rate times the speed, FIXED_SOURCE, the two-argument form — only
 * if seamless — and none while paused): Flutter's surface then asks only
 * for the touch ([filmOwnSurface]).
 *
 * Android 11 (API 30) and up; below it, nothing to ask.
 */
object DisplayVote {
    private const val CHANNEL = "innocent/display"
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var filmFps = 0f

    @Volatile
    private var touching = false

    /** The film votes on its own SurfaceView (Media3), not through Flutter's. */
    @Volatile
    private var filmOwnSurface = false

    /** What was asked last, for the trail: "24.0 film", "120 touch", "none". */
    @Volatile
    var last = "none"
        private set

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "film" -> {
                        film((call.argument<Number>("fps"))?.toFloat() ?: 0f)
                        result.success(last)
                    }
                    "touch" -> {
                        touch(call.argument<Boolean>("on") ?: false)
                        result.success(last)
                    }
                    "rates" -> result.success(rates())
                    else -> result.notImplemented()
                }
            }
    }

    /** The playing film's rate (0: none plays). Any thread. */
    fun film(fps: Float) {
        filmFps = if (fps in 1f..240f) fps else 0f
        main.post { apply() }
    }

    /** The film moved to its own SurfaceView ([on]) or back to the texture. */
    fun filmSurface(on: Boolean) {
        filmOwnSurface = on
        main.post { apply() }
    }

    fun touch(on: Boolean) {
        touching = on
        main.post { apply() }
    }

    /** Again, on a new surface (the app back from the home screen). */
    fun reapply() {
        main.post { apply() }
        // Its surface may come a moment after the Activity resumes.
        main.postDelayed({ apply() }, 600)
    }

    /** The display's rates at its resolution and the one it runs at. */
    private fun rates(): Map<String, Any?> {
        val a = PlayerWindow.current() ?: return emptyMap()
        val d = displayOf(a) ?: return emptyMap()
        val mode = d.mode
        val rates = d.supportedModes
            .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
            .map { it.refreshRate.toDouble() }
            .distinct().sorted()
        return mapOf("now" to d.refreshRate.toDouble(), "rates" to rates, "asked" to last)
    }

    private fun displayOf(a: Activity): android.view.Display? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) a.display
        else @Suppress("DEPRECATION") a.windowManager.defaultDisplay

    private fun apply() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val a = PlayerWindow.current() ?: return
        val sv = PlayerWindow.flutterSurface(a.window?.decorView) ?: return
        val s = sv.holder?.surface ?: return
        if (!s.isValid) return
        try {
            when {
                touching -> {
                    val top = topRate(a)
                    s.setFrameRate(top, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    last = "${top.toInt()} touch"
                }
                filmFps > 0f && !filmOwnSurface -> {
                    // The two-argument form changes only where it is
                    // seamless (Surface.setFrameRate's documentation).
                    s.setFrameRate(filmFps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
                    last = "${"%.3f".format(java.util.Locale.ROOT, filmFps)} film"
                }
                else -> {
                    s.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    last = if (filmFps > 0f) "film's own surface" else "none"
                }
            }
        } catch (_: Throwable) {
            // A surface torn down between the check and the call.
        }
    }

    private fun topRate(a: Activity): Float {
        val d = displayOf(a) ?: return 60f
        val mode = d.mode
        return d.supportedModes
            .filter { it.physicalWidth == mode.physicalWidth && it.physicalHeight == mode.physicalHeight }
            .maxOfOrNull { it.refreshRate } ?: d.refreshRate
    }
}
