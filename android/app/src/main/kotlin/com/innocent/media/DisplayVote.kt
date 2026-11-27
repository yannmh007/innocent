package com.innocent.media

import android.app.Activity
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Surface
import android.view.SurfaceView
import android.view.View
import android.view.ViewGroup
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
 * Android 11 (API 30) and up; below it, nothing to ask.
 */
object DisplayVote {
    private const val CHANNEL = "innocent/display"
    private val main = Handler(Looper.getMainLooper())

    @Volatile
    private var filmFps = 0f

    @Volatile
    private var touching = false

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
        val a = PlayerLab.current() ?: return emptyMap()
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
        val a = PlayerLab.current() ?: return
        val sv = flutterSurface(a.window?.decorView) ?: return
        val s = sv.holder?.surface ?: return
        if (!s.isValid) return
        try {
            when {
                touching -> {
                    val top = topRate(a)
                    s.setFrameRate(top, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    last = "${top.toInt()} touch"
                }
                filmFps > 0f -> {
                    // The two-argument form changes only where it is
                    // seamless (Surface.setFrameRate's documentation).
                    s.setFrameRate(filmFps, Surface.FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)
                    last = "${"%.3f".format(java.util.Locale.ROOT, filmFps)} film"
                }
                else -> {
                    s.setFrameRate(0f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
                    last = "none"
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

    /** Flutter's own SurfaceView in the window (not a film's of its own). */
    private fun flutterSurface(v: View?): SurfaceView? {
        if (v is io.flutter.embedding.android.FlutterSurfaceView) return v
        if (v is ViewGroup) {
            for (i in 0 until v.childCount) {
                flutterSurface(v.getChildAt(i))?.let { return it }
            }
        }
        return null
    }
}
