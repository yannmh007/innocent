package com.innocent.media

import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import java.io.File
import java.nio.ByteBuffer

/**
 * The player's Cut: copies the stretch between two points of a video into a
 * new MP4, without re-encoding.
 *
 * Samples are copied as they are (MediaExtractor → MediaMuxer), so a cut of
 * a long film takes seconds and loses nothing. The price is that it starts
 * on the key frame at or before the chosen start, as every lossless cutter
 * does; the end is the last sample at or before the chosen end.
 *
 * Only tracks MP4 can hold are kept: a video track the muxer refuses fails
 * the cut (there would be nothing to watch), an audio track it refuses is
 * left out — and when that leaves the cut with no sound at all, the result
 * says so, rather than "saved" over a silent clip.
 */
object VideoTrimmer {

    /** [error] is null on success; [silent]: the source had sound, the cut has none. */
    class Outcome(val error: String?, val silent: Boolean = false)

    private fun fail(reason: String) = Outcome(reason)

    /** [dst] is removed by the caller on failure ([discard]). */
    fun trim(src: String, dst: String, startUs: Long, endUs: Long): Outcome {
        if (endUs <= startUs) return fail("empty range")
        val extractor = MediaExtractor()
        var muxer: MediaMuxer? = null
        var started = false
        try {
            extractor.setDataSource(src)
            muxer = MediaMuxer(dst, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
            val tracks = HashMap<Int, Int>()
            var bufferSize = 1 shl 20
            var videoTrack = -1
            var audioKept = 0
            var audioDropped = 0
            for (i in 0 until extractor.trackCount) {
                val format = extractor.getTrackFormat(i)
                val mime = format.getString(MediaFormat.KEY_MIME) ?: continue
                val isVideo = mime.startsWith("video/")
                if (!isVideo && !mime.startsWith("audio/")) continue
                val out = try {
                    muxer.addTrack(format)
                } catch (e: Exception) {
                    if (isVideo) return fail("unsupported video ($mime)")
                    audioDropped++
                    continue
                }
                if (!isVideo) audioKept++
                tracks[i] = out
                if (isVideo && videoTrack < 0) videoTrack = i
                if (format.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE)) {
                    bufferSize = maxOf(bufferSize, format.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE))
                }
            }
            if (videoTrack < 0) return fail("no video track")
            rotationOf(src)?.let { muxer.setOrientationHint(it) }

            // Where the cut really starts: the video key frame at or before
            // the chosen start, found with the video track alone.
            extractor.selectTrack(videoTrack)
            extractor.seekTo(startUs, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val base = extractor.sampleTime.coerceAtLeast(0L)
            // Then every kept track, from that point.
            for (i in tracks.keys) if (i != videoTrack) extractor.selectTrack(i)
            extractor.seekTo(base, MediaExtractor.SEEK_TO_PREVIOUS_SYNC)

            muxer.start()
            started = true
            val buffer = ByteBuffer.allocate(bufferSize)
            val info = MediaCodec.BufferInfo()
            var videoStarted = false
            var written = 0
            while (true) {
                val track = extractor.sampleTrackIndex
                if (track < 0) break
                val time = extractor.sampleTime
                if (time > endUs) break
                val out = tracks[track]
                if (out == null) {
                    extractor.advance()
                    continue
                }
                // Nothing from before the key frame (audio read ahead of it
                // would play before the picture exists), and no video until a
                // key frame — a picture cannot start mid-group.
                val isKey = extractor.sampleFlags and MediaExtractor.SAMPLE_FLAG_SYNC != 0
                if (time < base || (track == videoTrack && !videoStarted && !isKey)) {
                    extractor.advance()
                    continue
                }
                if (track == videoTrack) videoStarted = true
                val size = extractor.readSampleData(buffer, 0)
                if (size < 0) break
                info.offset = 0
                info.size = size
                info.presentationTimeUs = time - base
                info.flags = if (isKey) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                muxer.writeSampleData(out, buffer, info)
                written++
                extractor.advance()
            }
            if (written == 0) return fail("nothing in that range")
            muxer.stop()
            started = false
            return Outcome(null, silent = audioKept == 0 && audioDropped > 0)
        } catch (e: Exception) {
            return fail(e.message ?: e.javaClass.simpleName)
        } finally {
            extractor.release()
            try {
                if (started) muxer?.stop()
            } catch (_: Exception) {
            }
            try {
                muxer?.release()
            } catch (_: Exception) {
            }
        }
    }

    /** Remove a half-written output. Called by the channel on failure. */
    fun discard(dst: String) {
        try {
            File(dst).delete()
        } catch (_: Exception) {
        }
    }

    private fun rotationOf(src: String): Int? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(src)
            r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull()
        } catch (_: Exception) {
            null
        } finally {
            try {
                r.release()
            } catch (_: Exception) {
            }
        }
    }
}
