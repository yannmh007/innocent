package com.innocent.media

import android.content.Context
import androidx.annotation.OptIn
import androidx.media3.common.C
import androidx.media3.common.audio.AudioProcessor
import androidx.media3.common.audio.BaseAudioProcessor
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.audio.AudioSink
import androidx.media3.exoplayer.audio.DefaultAudioSink
import androidx.media3.exoplayer.audio.ForwardingAudioSink
import com.innocent.media.audio.AudioShape
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * ExoPlayer's sound as ♪ asks for it on a catalogue film (27 Nov 2026,
 * docs/handoff_2026_11_27_beyond_mx.md P4): Stereo mode and Night mode
 * ([AudioShape], tested on the JVM in tool/audiojvm) and the audio delay
 * (Synchronization), which Media3 has no setting for.
 *
 * THE DELAY moves the audio clock, not the sound. ExoPlayer shows each
 * video frame when the audio sink's position reaches it (the audio
 * renderer is the media clock: MediaCodecAudioRenderer.updateCurrentPosition
 * reads AudioSink.getCurrentPositionUs). Reported [delayUs] ahead, every
 * frame is shown that much before its sound is heard: the sound comes
 * [delayUs] later against the picture — libmpv's `audio-delay`, positive
 * delays the sound. Larger takes effect at once (frames are skipped to
 * catch up); smaller holds the picture for the difference (the renderer
 * never lets its clock go back), as a viewer expects of a sync control.
 */
@OptIn(UnstableApi::class)
object ExoAudio {
    fun renderers(context: Context, shape: AudioShape, delayUs: () -> Long): DefaultRenderersFactory =
        object : DefaultRenderersFactory(context) {
            override fun buildAudioSink(
                context: Context,
                enableFloatOutput: Boolean,
                enableAudioOutputPlaybackParams: Boolean,
            ): AudioSink = DelayedSink(
                DefaultAudioSink.Builder(context)
                    .setEnableFloatOutput(enableFloatOutput)
                    .setEnableAudioOutputPlaybackParameters(enableAudioOutputPlaybackParams)
                    .setAudioProcessors(arrayOf<AudioProcessor>(Shaping(shape)))
                    .build(),
                delayUs,
            )
        }

    private class DelayedSink(sink: AudioSink, private val delayUs: () -> Long) : ForwardingAudioSink(sink) {
        override fun getCurrentPositionUs(sourceEnded: Boolean): Long {
            val p = super.getCurrentPositionUs(sourceEnded)
            if (p == AudioSink.CURRENT_POSITION_NOT_SET) return p
            return (p + delayUs()).coerceAtLeast(0)
        }
    }

    /** [AudioShape] on the decoders' 16-bit PCM; other encodings pass by. */
    private class Shaping(private val shape: AudioShape) : BaseAudioProcessor() {
        private var channels = 2
        private var scratch = ShortArray(0)

        override fun onConfigure(inputAudioFormat: AudioProcessor.AudioFormat): AudioProcessor.AudioFormat {
            if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT) return AudioProcessor.AudioFormat.NOT_SET
            channels = inputAudioFormat.channelCount
            shape.configure(inputAudioFormat.sampleRate)
            return inputAudioFormat
        }

        override fun queueInput(inputBuffer: ByteBuffer) {
            val bytes = inputBuffer.remaining()
            if (bytes == 0) return
            val out = replaceOutputBuffer(bytes)
            if (!shape.shapes(channels)) {
                out.put(inputBuffer)
                out.flip()
                return
            }
            val n = bytes / 2
            if (scratch.size < n) scratch = ShortArray(n)
            inputBuffer.order(ByteOrder.nativeOrder()).asShortBuffer().get(scratch, 0, n)
            inputBuffer.position(inputBuffer.position() + n * 2)
            shape.process(scratch, n, channels)
            out.order(ByteOrder.nativeOrder()).asShortBuffer().put(scratch, 0, n)
            out.position(out.position() + n * 2)
            // An odd byte (never, for 16-bit PCM) goes as it came.
            while (inputBuffer.hasRemaining()) out.put(inputBuffer.get())
            out.flip()
        }

        override fun onFlush(streamMetadata: AudioProcessor.StreamMetadata) {
            shape.reset()
        }
    }
}
