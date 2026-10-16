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
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import java.io.File

/**
 * The player's Cut with "Exact start": the clip begins exactly at A.
 *
 * The default cut ([VideoTrimmer]) copies the video as it is, so it can only
 * start on a key frame, up to a few seconds before A, and takes a moment.
 * For an exact start the first frames have to be made anew: Media3
 * Transformer, with trim optimization, re-encodes only A to the next key
 * frame and copies the rest when this phone's encoder writes the same
 * parameter sets as the file (Media3 requires them byte for byte, so in
 * practice: a video this phone recorded). Otherwise it re-encodes the whole
 * clip, which is exact but takes about as long as the clip on a phone, and
 * longer on the device lab's all-software emulator (run 38870594057:
 * optimization=6, format mismatch, even for a Baseline film). So it is the
 * user's choice, with progress and Cancel ([progress], [cancel]), never a
 * silent wait.
 *
 * Transformer must be started on a thread with a Looper, and reports on it:
 * everything here runs on the main thread.
 */
@OptIn(UnstableApi::class)
object PreciseTrimmer {

    /** [error] is null on success; [silent]: the source had sound, the cut has none. */
    class Outcome(val error: String?, val silent: Boolean = false, val exact: Boolean = false)

    /** What the file allows. [nextKeyUs]: the first key frame at or after A, or -1. */
    class Probe(
        val mp4: Boolean,
        val videoMime: String?,
        val keyBeforeUs: Long,
        val nextKeyUs: Long,
        val hasAudio: Boolean,
    ) {
        /** A is on a key frame (within a frame): the lossless cut is exact. */
        fun keyFrameAt(startUs: Long) =
            nextKeyUs >= 0 && nextKeyUs - startUs <= ONE_FRAME_US ||
                keyBeforeUs >= 0 && startUs - keyBeforeUs <= ONE_FRAME_US
    }

    private const val ONE_FRAME_US = 40_000L

    /** Off the main thread: it reads the file. */
    fun probe(src: String, startUs: Long): Probe {
        val extractor = MediaExtractor()
        var videoMime: String? = null
        var keyBefore = -1L
        var nextKey = -1L
        var audio = false
        try {
            extractor.setDataSource(src)
            var video = -1
            for (i in 0 until extractor.trackCount) {
                val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) audio = true
                if (mime.startsWith("video/") && video < 0) {
                    video = i
                    videoMime = mime
                }
            }
            if (video >= 0) {
                extractor.selectTrack(video)
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
                keyBefore = extractor.sampleTime
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_NEXT_SYNC)
                nextKey = extractor.sampleTime
            }
        } catch (_: Exception) {
        } finally {
            extractor.release()
        }
        return Probe(isMp4(File(src)), videoMime, keyBefore, nextKey, audio)
    }

    /** The export running now, for [progress] and [cancel]. One cut at a time. */
    private var current: Transformer? = null
    private var finishCurrent: ((Outcome) -> Unit)? = null

    /** 0-100 while an exact cut runs, -1 when unknown or none. */
    fun progress(): Int {
        val t = current ?: return -1
        val holder = ProgressHolder()
        return try {
            if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) holder.progress else -1
        } catch (_: Exception) {
            -1
        }
    }

    /** Stops the exact cut; it reports "cancelled". */
    fun cancel() {
        val t = current ?: return
        try {
            t.cancel()
        } catch (_: Exception) {
        }
        finishCurrent?.invoke(Outcome("cancelled"))
    }

    /** [done] is called once, on the main thread. */
    fun trim(
        context: Context,
        src: String,
        dst: String,
        startMs: Long,
        endMs: Long,
        hadAudio: Boolean,
        done: (Outcome) -> Unit,
    ) {
        if (endMs <= startMs) {
            done(Outcome("empty range"))
            return
        }
        if (current != null) {
            done(Outcome("busy"))
            return
        }
        val item = MediaItem.Builder()
            .setUri(Uri.fromFile(File(src)))
            .setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(startMs)
                    .setEndPositionMs(endMs)
                    .build()
            )
            .build()
        var finished = false
        val finish = { outcome: Outcome ->
            if (!finished) {
                finished = true
                current = null
                finishCurrent = null
                done(outcome)
            }
        }
        try {
            val t = Transformer.Builder(context)
                .experimentalSetTrimOptimizationEnabled(true)
                .addListener(object : Transformer.Listener {
                    override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                        val noAudio =
                            exportResult.audioConversionProcess == ExportResult.CONVERSION_PROCESS_NA
                        // Exact when the start was re-encoded: the smart cut,
                        // or the whole clip.
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
            current = t
            finishCurrent = finish
            t.start(item, dst)
        } catch (e: Exception) {
            finish(Outcome(e.message ?: e.javaClass.simpleName))
        }
    }

    /** An ISO base media file (MP4, MOV, 3GP): its first box is `ftyp`. */
    private fun isMp4(file: File): Boolean = try {
        java.io.RandomAccessFile(file, "r").use { f ->
            val head = ByteArray(8)
            f.readFully(head)
            head[4] == 'f'.code.toByte() && head[5] == 't'.code.toByte() &&
                head[6] == 'y'.code.toByte() && head[7] == 'p'.code.toByte()
        }
    } catch (_: Exception) {
        false
    }
}
