package com.innocent.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * The player's Cut, starting exactly where the user set A.
 *
 * A lossless cut ([VideoTrimmer]) can only start on a key frame, so the clip
 * began up to a few seconds before A. This is the smart cut editors use:
 * Media3 Transformer re-encodes only the stretch from A to the next key frame
 * and copies everything after it untouched ("trim optimization"), so the
 * start is exact, the rest loses nothing, and a long clip still takes seconds.
 * Where it cannot stitch the two (an encoder that cannot match the source's
 * profile, a container other than MP4), Transformer itself falls back to a
 * plain export. Audio MP4 cannot carry is converted to AAC rather than left
 * out.
 *
 * Anything Transformer refuses outright is cut by [VideoTrimmer] instead
 * (the caller does that), so the worst case is the old key-frame start.
 *
 * Transformer must be started on a thread with a Looper, and reports on it:
 * the caller runs this on the main thread.
 */
@OptIn(UnstableApi::class)
object PreciseTrimmer {

    /** [error] is null on success; [silent]: the source had sound, the cut has none. */
    class Outcome(val error: String?, val silent: Boolean = false, val exact: Boolean = false)

    /** Running exports, held until they report, so nothing collects them mid-cut. */
    private val running = HashSet<Transformer>()

    fun trim(
        context: Context,
        src: String,
        dst: String,
        startMs: Long,
        endMs: Long,
        done: (Outcome) -> Unit,
    ) {
        if (endMs <= startMs) {
            done(Outcome("empty range"))
            return
        }
        val hadAudio = hasAudio(src)
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(File(src)))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs)
                    .setEndPositionMs(endMs)
                    .build()
            )
            .build()
        var transformer: Transformer? = null
        val finish = { outcome: Outcome ->
            transformer?.let { running.remove(it) }
            done(outcome)
        }
        try {
            val t = Transformer.Builder(context)
                .experimentalSetTrimOptimizationEnabled(true)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        val noAudio =
                            exportResult.audioConversionProcess == ExportResult.CONVERSION_PROCESS_NA
                        // Exact when the start was re-encoded: the smart cut,
                        // or a full export. Otherwise it was copied from the
                        // key frame before A, as VideoTrimmer does.
                        val exact = exportResult.optimizationResult ==
                            ExportResult.OPTIMIZATION_SUCCEEDED ||
                            exportResult.videoConversionProcess ==
                            ExportResult.CONVERSION_PROCESS_TRANSCODED
                        android.util.Log.i(
                            "Innocent",
                            "Cut: optimization=${exportResult.optimizationResult} " +
                                "video=${exportResult.videoConversionProcess} " +
                                "audio=${exportResult.audioConversionProcess} " +
                                "durationMs=${exportResult.approximateDurationMs} exact=$exact"
                        )
                        finish(Outcome(null, silent = hadAudio && noAudio, exact = exact))
                    }

                    override fun onError(
                        composition: Composition,
                        exportResult: ExportResult,
                        exportException: ExportException,
                    ) {
                        finish(Outcome(exportException.errorCodeName))
                    }
                })
                .build()
            transformer = t
            running.add(t)
            t.start(item, dst)
        } catch (e: Exception) {
            finish(Outcome(e.message ?: e.javaClass.simpleName))
        }
    }

    private fun hasAudio(src: String): Boolean {
        val extractor = MediaExtractor()
        return try {
            extractor.setDataSource(src)
            (0 until extractor.trackCount).any {
                extractor.getTrackFormat(it).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            }
        } catch (_: Exception) {
            false
        } finally {
            extractor.release()
        }
    }
}
