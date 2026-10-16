package com.innocent.media

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.transformer.Composition
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import java.io.File
import java.io.RandomAccessFile

/**
 * The player's Cut, starting exactly where the user set A.
 *
 * A lossless cut ([VideoTrimmer]) can only start on a key frame, so the clip
 * began up to a few seconds before A. This is the smart cut editors use:
 * Media3 Transformer re-encodes only the stretch from A to the next key frame
 * and copies everything after it untouched ("trim optimization"), so the
 * start is exact, the rest loses nothing, and a long clip still takes seconds.
 *
 * WHAT IT IS NOT ALLOWED TO DO: Media3, when it cannot stitch the two parts
 * (an encoder that cannot match the source's profile — the emulator's software
 * encoder and a High-profile film, run 38856111434), when the audio needs
 * converting, or when the file is not MP4, re-encodes the WHOLE clip instead:
 * exact, but minutes for a long clip, and not the quality of the original.
 * So [probe] reads the file first, and only an MP4 with H.264/H.265 video
 * whose A is not already a key frame goes to Media3, with a deadline sized for
 * a smart cut ([deadlineMs]); past it, the caller cancels and makes the
 * lossless cut instead. Everything else is the lossless cut from the start,
 * which is exact anyway when A is a key frame.
 *
 * Transformer must be started on a thread with a Looper, and reports on it:
 * [trim] runs on the main thread.
 */
@OptIn(UnstableApi::class)
object PreciseTrimmer {

    /** [error] is null on success; [silent]: the source had sound, the cut has none. */
    class Outcome(val error: String?, val silent: Boolean = false, val exact: Boolean = false)

    /**
     * What the file allows. [nextKeyUs]: the first key frame at or after A,
     * or -1 when there is none; [bytes] and [durationUs] size the deadline.
     */
    class Probe(
        val mp4: Boolean,
        val videoMime: String?,
        val nextKeyUs: Long,
        val durationUs: Long,
        val bytes: Long,
        val hasAudio: Boolean,
    ) {
        /** A is on a key frame (within a frame): a lossless cut is exact. */
        fun keyFrameAt(startUs: Long) = nextKeyUs >= 0 && nextKeyUs - startUs <= ONE_FRAME_US

        /** Media3 can make the smart cut of this file, from [startUs]. */
        fun smartCut(startUs: Long) =
            mp4 && (videoMime == "video/avc" || videoMime == "video/hevc") && !keyFrameAt(startUs)
    }

    private const val ONE_FRAME_US = 40_000L

    /** Off the main thread: it reads the file. */
    fun probe(src: String, startUs: Long): Probe {
        val file = File(src)
        val extractor = MediaExtractor()
        var videoMime: String? = null
        var nextKey = -1L
        var duration = 0L
        var audio = false
        try {
            extractor.setDataSource(src)
            var video = -1
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                if (mime.startsWith("audio/")) audio = true
                if (mime.startsWith("video/") && video < 0) {
                    video = i
                    videoMime = mime
                    if (format.containsKey(MediaFormat.KEY_DURATION)) {
                        duration = format.getLong(MediaFormat.KEY_DURATION)
                    }
                }
            }
            if (video >= 0) {
                extractor.selectTrack(video)
                extractor.seekTo(startUs, MediaExtractor.SEEK_TO_NEXT_SYNC)
                nextKey = extractor.sampleTime
            }
        } catch (_: Exception) {
        } finally {
            extractor.release()
        }
        return Probe(isMp4(file), videoMime, nextKey, duration, file.length(), audio)
    }

    /**
     * How long a smart cut of [p] from A to B may take before it can only be
     * Media3 re-encoding the whole clip: the stretch to the next key frame
     * re-encoded at a slow phone's half speed, the rest copied at 15 MB/s,
     * and ten seconds to start up.
     */
    fun deadlineMs(p: Probe, startUs: Long, endUs: Long): Long {
        val headUs =
            if (p.nextKeyUs < 0 || p.nextKeyUs > endUs) endUs - startUs else p.nextKeyUs - startUs
        val clipBytes = if (p.durationUs > 0) {
            (p.bytes.toDouble() * (endUs - startUs) / p.durationUs).toLong()
        } else {
            p.bytes
        }
        return 10_000L + 3 * headUs / 1000 + clipBytes / 15_000
    }

    /** Running exports, held until they report, so nothing collects them mid-cut. */
    private val running = HashSet<Transformer>()

    /** On the main thread. [done] is called once, on the main thread. */
    fun trim(
        context: Context,
        src: String,
        dst: String,
        startMs: Long,
        endMs: Long,
        hadAudio: Boolean,
        deadlineMs: Long,
        done: (Outcome) -> Unit,
    ) {
        if (endMs <= startMs) {
            done(Outcome("empty range"))
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
        val handler = Handler(Looper.getMainLooper())
        var transformer: Transformer? = null
        var finished = false
        val finish = { outcome: Outcome ->
            if (!finished) {
                finished = true
                handler.removeCallbacksAndMessages(null)
                transformer?.let { running.remove(it) }
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
                        // or (a clip shorter than its key-frame gap) the whole.
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
            handler.postDelayed({
                if (!finished) {
                    android.util.Log.w("Innocent", "Cut: smart cut past ${deadlineMs}ms; cancelled")
                    try {
                        t.cancel()
                    } catch (_: Exception) {
                    }
                    finish(Outcome("deadline"))
                }
            }, deadlineMs)
        } catch (e: Exception) {
            finish(Outcome(e.message ?: e.javaClass.simpleName))
        }
    }

    /** An ISO base media file (MP4, MOV, 3GP): its first box is `ftyp`. */
    private fun isMp4(file: File): Boolean = try {
        RandomAccessFile(file, "r").use { f ->
            val head = ByteArray(8)
            f.readFully(head)
            head[4] == 'f'.code.toByte() && head[5] == 't'.code.toByte() &&
                head[6] == 'y'.code.toByte() && head[7] == 'p'.code.toByte()
        }
    } catch (_: Exception) {
        false
    }
}
