import com.innocent.media.audio.AudioShape
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * ♪'s Stereo mode and Night mode on ExoPlayer's 16-bit PCM (27 Nov 2026,
 * docs/handoff_2026_11_27_beyond_mx.md P4).
 */
class AudioShapeTest {
    private val rate = 48000

    /** [seconds] of a 440 Hz tone at [dbfs], interleaved stereo. */
    private fun tone(dbfs: Double, seconds: Double, channels: Int = 2): ShortArray {
        val frames = (rate * seconds).toInt()
        val amp = 32767.0 * Math.pow(10.0, dbfs / 20)
        val out = ShortArray(frames * channels)
        for (f in 0 until frames) {
            val v = (amp * sin(2 * PI * 440 * f / rate)).toInt().toShort()
            for (c in 0 until channels) out[f * channels + c] = v
        }
        return out
    }

    /** RMS of the last half of [pcm] in dBFS (the compressor settled). */
    private fun rmsDb(pcm: ShortArray): Double {
        var sum = 0.0
        val from = pcm.size / 2
        for (i in from until pcm.size) sum += (pcm[i] / 32768.0).let { it * it }
        val rms = sqrt(sum / (pcm.size - from))
        // A sine's RMS is 3 dB under its peak: report the peak level.
        return 20 * log10(rms) + 3.0103
    }

    /** As the sink hands buffers over: in pieces of ~10 ms. */
    private fun run(shape: AudioShape, pcm: ShortArray, channels: Int = 2) {
        val piece = 480 * channels + channels // not a multiple of BLOCK
        var at = 0
        while (at < pcm.size) {
            val n = minOf(piece, pcm.size - at)
            val part = pcm.copyOfRange(at, at + n)
            shape.process(part, n, channels)
            part.copyInto(pcm, at)
            at += n
        }
    }

    @Test
    fun stereoLeavesTheSoundAsItIs() {
        val pcm = shortArrayOf(100, -200, 30000, -30000, 1, 2)
        val shape = AudioShape()
        shape.process(pcm, pcm.size, 2)
        assertContentEquals(shortArrayOf(100, -200, 30000, -30000, 1, 2), pcm)
        assertTrue(!shape.shapes(2))
    }

    @Test
    fun monoGivesBothSidesTheAverage() {
        val pcm = shortArrayOf(100, -200, 32767, 32767, -32768, -32768, 1000, 0)
        val shape = AudioShape().apply { stereo = AudioShape.MONO }
        shape.process(pcm, pcm.size, 2)
        assertContentEquals(shortArrayOf(-50, -50, 32767, 32767, -32768, -32768, 500, 500), pcm)
    }

    @Test
    fun swapExchangesLeftAndRight() {
        val pcm = shortArrayOf(1, 2, 3, 4, -5, 6)
        AudioShape().apply { stereo = AudioShape.SWAP }.process(pcm, pcm.size, 2)
        assertContentEquals(shortArrayOf(2, 1, 4, 3, 6, -5), pcm)
    }

    @Test
    fun stereoModeOnlyActsOnTwoChannels() {
        // 5.1: six samples a frame, left as they are.
        val pcm = shortArrayOf(1, 2, 3, 4, 5, 6)
        val shape = AudioShape().apply { stereo = AudioShape.SWAP }
        shape.process(pcm, pcm.size, 6)
        assertContentEquals(shortArrayOf(1, 2, 3, 4, 5, 6), pcm)
        assertTrue(!shape.shapes(6))
    }

    @Test
    fun nightLiftsQuietSpeech() {
        val shape = AudioShape().apply { night = true; configure(rate) }
        val pcm = tone(-40.0, 1.0)
        run(shape, pcm)
        // Under the threshold: lifted by the makeup gain, 10 dB.
        assertEquals(-30.0, rmsDb(pcm), 0.6)
    }

    @Test
    fun nightBringsLoudMomentsDown() {
        val shape = AudioShape().apply { night = true; configure(rate) }
        val pcm = tone(-6.0, 1.0)
        run(shape, pcm)
        // 22 dB over the threshold at 4:1 is 16.5 dB down, 10 up: -12.5.
        // (The envelope follows the sine's peaks, so a little under.)
        val got = rmsDb(pcm)
        assertTrue(got in -14.5..-11.0, "got $got dBFS")
    }

    @Test
    fun nightNeverClipsAFullScaleBang() {
        val shape = AudioShape().apply { night = true; configure(rate) }
        // Quiet speech for a second (the gain up), then a full-scale bang.
        val pcm = tone(-45.0, 1.0) + tone(0.0, 0.5)
        run(shape, pcm)
        var peak = 0
        for (s in pcm) peak = maxOf(peak, abs(s.toInt()))
        assertTrue(peak <= (32768 * AudioShape.CEILING).toInt() + 1, "peak $peak")
    }

    @Test
    fun theCompressorsCurve() {
        val shape = AudioShape()
        assertEquals(10f, shape.nightGainDb(-60f), 1e-4f)
        assertEquals(10f, shape.nightGainDb(-31f), 1e-4f) // the knee's foot
        assertEquals(10f - 12f * 0.75f, shape.nightGainDb(-16f), 1e-4f)
        // Inside the knee: between the two, and continuous at its ends.
        val mid = shape.nightGainDb(-28f)
        assertTrue(mid < 10f && mid > 10f - 3f * 0.75f)
        assertEquals(shape.nightGainDb(-25.0001f), shape.nightGainDb(-24.9999f), 1e-3f)
    }

    @Test
    fun nightOffAfterOnLeavesTheSoundAsItIs() {
        val shape = AudioShape().apply { night = true; configure(rate) }
        run(shape, tone(-20.0, 0.2))
        shape.night = false
        val pcm = tone(-20.0, 0.1)
        val want = pcm.copyOf()
        run(shape, pcm)
        assertContentEquals(want, pcm)
    }
}
