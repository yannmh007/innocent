package com.innocent.media

import android.app.Activity
import android.os.Debug
import android.os.Looper
import android.os.SystemClock
import android.util.Printer
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * LAB ONLY — called by SmoothLab (lib/features/player/presentation/lab/,
 * INNOCENT_LAB builds) and nothing else; a release build carries the class
 * but no Dart code there ever calls `innocent/lab`.
 *
 * WHY (27 Nov 2026, docs/handoff_2026_11_27_beyond_mx.md P1). A film
 * playing alone, nothing over it, costs Innocent 65-73 % of one core on
 * Test Lab's phones (54th run, 45969983812: main thread 13-18 %,
 * ExoPlayer's loop 11 %, MediaCodec 10 %, raster 5-9 %) against MX's 26 %
 * on the owner's meter. Every video frame reaches Flutter as a new image
 * of a SurfaceProducer: the engine marks the texture (shell.cc
 * OnPlatformViewMarkTextureFrameAvailable → ScheduleFrame(false)) and on
 * the next vsync draws the whole last layer tree again
 * (Rasterizer::DrawLastLayerTrees; Impeller on Vulkan has no partial
 * repaint), after taking the image through JNI (ImageExternalTextureVK
 * ProcessFrame: acquireLatestImage, getHardwareBuffer, close). MX draws
 * the film on Android's own SurfaceView, which the display composes
 * without the app. This lets one Test Lab run measure, on one phone:
 *  * the window transparent ([transparent]) — Flutter's SurfaceView on top
 *    of the window, see-through where nothing is drawn, so a SurfaceView
 *    BEHIND it (ExoStreamEngine.labSurface) shows the film and Flutter
 *    draws only when its own content changes;
 *  * what the main thread spends its CPU on, message by message
 *    ([profileStart]/[profileStop]: the main Looper's dispatches, each
 *    timed in the thread's own CPU time).
 */
object PlayerLab {
    private const val CHANNEL = "innocent/lab"

    /** The window see-through (Flutter's SurfaceView on top, transparent). */
    @Volatile
    var transparent = false

    /** The next onCreate drops the saved fragment, so the new mode applies. */
    @Volatile
    var recreating = false

    private var activity: WeakReference<Activity>? = null

    fun attach(a: Activity) {
        activity = WeakReference(a)
    }

    fun current(): Activity? = activity?.get()

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "transparent" -> {
                        val on = call.argument<Boolean>("on") ?: false
                        val a = current()
                        if (a == null || on == transparent) {
                            result.success(false)
                        } else {
                            transparent = on
                            recreating = true
                            result.success(true)
                            a.runOnUiThread { a.recreate() }
                        }
                    }
                    "profileStart" -> {
                        profileStart()
                        result.success(true)
                    }
                    "profileStop" -> result.success(profileStop())
                    "mpvSurface" -> mpvSurface(
                        call.argument<Int>("w") ?: 0,
                        call.argument<Int>("h") ?: 0,
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    // ── libmpv's picture on a SurfaceView (SmoothLab `mpvsv`) ───────────
    private var mpvView: android.view.SurfaceView? = null

    /**
     * A SurfaceView behind the window, its buffers the film's own size
     * (`setFixedSize`: the display scales them, not the GPU), fitted to
     * the window; answers libmpv's `wid` for its Surface (a JNI global
     * reference, made by media_kit's helper as for its own surfaces) once
     * the surface exists, or 0.
     */
    private fun mpvSurface(w: Int, h: Int, result: MethodChannel.Result) {
        val a = current()
        val root = a?.findViewById<android.view.ViewGroup>(android.R.id.content)
        if (a == null || root == null || w <= 0 || h <= 0) {
            result.success(0)
            return
        }
        mpvView?.let { (it.parent as? android.view.ViewGroup)?.removeView(it) }
        val v = android.view.SurfaceView(a)
        mpvView = v
        v.holder.setFixedSize(w, h)
        var answered = false
        v.holder.addCallback(object : android.view.SurfaceHolder.Callback {
            override fun surfaceCreated(holder: android.view.SurfaceHolder) {
                if (answered) return
                answered = true
                try {
                    val helper = Class.forName("com.alexmercerind.mediakitandroidhelper.MediaKitAndroidHelper")
                    val ref = helper.getDeclaredMethod("newGlobalObjectRef", Any::class.java)
                    result.success((ref.invoke(null, holder.surface) as Number).toLong())
                } catch (t: Throwable) {
                    result.error("lab", "${t.javaClass.simpleName}: ${t.message ?: ""}", null)
                }
            }

            override fun surfaceChanged(holder: android.view.SurfaceHolder, f: Int, width: Int, height: Int) {}
            override fun surfaceDestroyed(holder: android.view.SurfaceHolder) {}
        })
        val rw = root.width
        val rh = root.height
        val aspect = w.toFloat() / h
        var fw = rw
        var fh = Math.round(rw / aspect)
        if (fh > rh) {
            fh = rh
            fw = Math.round(rh * aspect)
        }
        root.addView(v, 0, android.widget.FrameLayout.LayoutParams(
            fw.coerceAtLeast(1), fh.coerceAtLeast(1), android.view.Gravity.CENTER))
    }

    // ── The main thread, message by message ─────────────────────────────
    private class Kind(var count: Int = 0, var cpuNs: Long = 0)

    private val kinds = HashMap<String, Kind>()
    private var startCpuNs = 0L
    private var startWall = 0L
    private var msgCpuNs = 0L
    private var openKey: String? = null
    private var openCpu = 0L

    /** ">>>>> Dispatching to Handler (X) {hash} Y@hash: what" → "X Y". */
    private fun keyOf(line: String): String {
        val h0 = line.indexOf('(')
        val h1 = line.indexOf(')', h0 + 1)
        val handler = if (h0 >= 0 && h1 > h0) line.substring(h0 + 1, h1) else "?"
        val after = if (h1 > 0) line.substring(h1 + 1) else line
        val cb = after.substringAfter("} ", after).trim()
            .substringBefore('@').substringBefore(':').trim()
        fun short(s: String) = s.substringAfterLast('.')
        return if (cb.isEmpty() || cb == "null") short(handler) else "${short(handler)} ${short(cb)}"
    }

    private val printer = Printer { line ->
        if (line.startsWith(">>>>>")) {
            openKey = keyOf(line)
            openCpu = Debug.threadCpuTimeNanos()
        } else if (line.startsWith("<<<<<")) {
            val k = openKey ?: return@Printer
            val d = Debug.threadCpuTimeNanos() - openCpu
            msgCpuNs += d
            val kind = kinds.getOrPut(k) { Kind() }
            kind.count++
            kind.cpuNs += d
            openKey = null
        }
    }

    private fun profileStart() {
        val main = Looper.getMainLooper()
        if (Looper.myLooper() == main) {
            begin()
        } else {
            android.os.Handler(main).post { begin() }
        }
    }

    private fun begin() {
        kinds.clear()
        msgCpuNs = 0
        openKey = null
        startCpuNs = Debug.threadCpuTimeNanos()
        startWall = SystemClock.uptimeMillis()
        Looper.getMainLooper().setMessageLogging(printer)
    }

    /**
     * `main N% · in messages M% · Handler Callback count×ms …` over the window
     * (shares of one core); what is not in messages is the native looper's
     * own callbacks — Flutter's platform tasks and channel messages, input.
     * Runs on the main thread (a method channel's handler does).
     */
    private fun profileStop(): String {
        Looper.getMainLooper().setMessageLogging(null)
        val wallMs = (SystemClock.uptimeMillis() - startWall).coerceAtLeast(1)
        val cpuNs = Debug.threadCpuTimeNanos() - startCpuNs
        fun pct(ns: Long) = Math.round(ns / 1e4 / wallMs).toInt()
        val top = kinds.entries.sortedByDescending { it.value.cpuNs }.take(8)
            .joinToString(" | ") { (k, v) ->
                "$k ${v.count}x${"%.2f".format(java.util.Locale.ROOT, v.cpuNs / 1e6 / v.count)}ms"
            }
        val out = "main ${pct(cpuNs)}% · in messages ${pct(msgCpuNs)}% · " +
            "${kinds.values.sumOf { it.count }} msgs · $top"
        kinds.clear()
        return out
    }
}
