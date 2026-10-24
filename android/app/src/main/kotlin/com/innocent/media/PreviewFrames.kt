package com.innocent.media

import android.graphics.Bitmap
import android.media.MediaDataSource
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * The seek bar's preview picture for a film on the ladder engine.
 *
 * Dart hands over a little fragmented MP4 — the smallest rung's init
 * segment and the one fragment that holds the moment the finger is on
 * (StreamCacheServer.previewClip) — and gets back that fragment's keyframe
 * as a JPEG, scaled to [maxWidth].
 *
 * FROM MEMORY, NOT A FILE: a paid film's bytes are not written out in the
 * clear for a thumbnail. One thread, so a drag's requests queue rather than
 * pile up decoders; Dart drops the answers it no longer wants.
 *
 *   channel `innocent/preview`, method `frame`:
 *     { film: bytes, timeUs: long, maxWidth: int } -> JPEG bytes, or null
 */
object PreviewFrames {
    private const val CHANNEL = "innocent/preview"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method != "frame") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val film = call.argument<ByteArray>("film")
                val timeUs = call.argument<Number>("timeUs")?.toLong() ?: -1L
                val maxWidth = call.argument<Number>("maxWidth")?.toInt() ?: 320
                if (film == null || film.isEmpty()) {
                    result.success(null)
                    return@setMethodCallHandler
                }
                worker.execute {
                    val jpeg = try {
                        frame(film, timeUs, maxWidth)
                    } catch (t: Throwable) {
                        // A picture that cannot be had is no picture, never
                        // a crash: the bar shows the time alone.
                        null
                    }
                    main.post { result.success(jpeg) }
                }
            }
    }

    private fun frame(film: ByteArray, timeUs: Long, maxWidth: Int): ByteArray? {
        val r = MediaMetadataRetriever()
        try {
            r.setDataSource(object : MediaDataSource() {
                override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
                    if (position >= film.size) return -1
                    val n = minOf(size.toLong(), film.size - position).toInt()
                    System.arraycopy(film, position.toInt(), buffer, offset, n)
                    return n
                }

                override fun getSize(): Long = film.size.toLong()

                override fun close() {}
            })
            // The fragment starts on its keyframe; asked for any frame, a
            // retriever that does not place a lone fragment in time still
            // returns that one.
            val bmp = r.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: r.getFrameAtTime(-1)
                ?: return null
            val scaled = if (bmp.width > maxWidth && maxWidth > 0) {
                Bitmap.createScaledBitmap(bmp, maxWidth, maxOf(1, bmp.height * maxWidth / bmp.width), true)
            } else {
                bmp
            }
            val out = ByteArrayOutputStream()
            scaled.compress(Bitmap.CompressFormat.JPEG, 80, out)
            if (scaled !== bmp) scaled.recycle()
            bmp.recycle()
            return out.toByteArray()
        } finally {
            try {
                r.release()
            } catch (_: Throwable) {
            }
        }
    }
}
