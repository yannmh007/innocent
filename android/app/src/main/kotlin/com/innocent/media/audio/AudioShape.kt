package com.innocent.media.audio

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.pow

/**
 * The film's sound shaped on its way to the speaker, for ExoPlayer (a
 * catalogue film): ♪'s Stereo mode and Night mode. libmpv does the same
 * with its own filters (MediaKitPlayerService's `af` chain).
 *
 * WHY (27 Nov 2026, docs/handoff_2026_11_27_beyond_mx.md P4; the owner
 * chose MX's ♪ items Stereo mode, Night mode, Volume boost and Disable).
 * Media3 has no processor for either: ChannelMixingAudioProcessor mixes
 * channels but takes a new matrix only when the sink is configured again
 * (a seek), and Android's DynamicsProcessing differs by phone. This is
 * plain Kotlin on 16-bit PCM — the decoders' output — so what the JVM
 * tests prove (tool/audiojvm) is what the phone runs, and a change takes
 * effect on the next buffer (the fields are read per call).
 *
 *  * Stereo mode on two channels: [STEREO] as it is, [MONO] both sides
 *    the average (one earphone, a film mixed hard left and right), [SWAP]
 *    left and right exchanged.
 *  * Night mode: a compressor — loud moments brought down, quiet speech
 *    lifted — so a film can be heard at night without waking anyone:
 *    above [NIGHT_THRESHOLD_DB] the level rises a quarter as fast (4:1,
 *    a 6 dB soft knee), everything is then lifted by [NIGHT_MAKEUP_DB],
 *    and nothing goes past [CEILING] (no clipping on a full-scale bang).
 *    Attack 5 ms, release 150 ms: fast enough for an explosion, slow
 *    enough not to pump on speech. The gain is worked out every [BLOCK]
 *    frames and moved smoothly between them.
 */
class AudioShape {
    companion object {
        const val STEREO = 0
        const val MONO = 1
        const val SWAP = 2

        const val NIGHT_THRESHOLD_DB = -28f
        const val NIGHT_RATIO = 4f
        const val NIGHT_KNEE_DB = 6f
        const val NIGHT_MAKEUP_DB = 10f
        const val CEILING = 0.89f // -1 dBFS
        const val BLOCK = 16
        private const val ATTACK_S = 0.005f
        private const val RELEASE_S = 0.150f
    }

    @Volatile
    var stereo: Int = STEREO

    @Volatile
    var night: Boolean = false

    private var sampleRate = 48000
    private var attack = 0f
    private var release = 0f
    private var env = 0f
    private var gain = 1f

    init {
        configure(48000)
    }

    /** A new stream: its rate sets the envelope's time constants. */
    fun configure(rate: Int) {
        sampleRate = if (rate > 0) rate else 48000
        // Per frame: the envelope moves (1 - c) of the way each frame.
        attack = exp(-1f / (ATTACK_S * sampleRate))
        release = exp(-1f / (RELEASE_S * sampleRate))
        reset()
    }

    /** A seek or a new stream: no memory of the sound before it. */
    fun reset() {
        env = 0f
        gain = 1f
    }

    /** Whether [process] would change anything with these settings. */
    fun shapes(channels: Int): Boolean = night || (channels == 2 && stereo != STEREO)

    /** The compressor's gain in dB for an envelope level [levelDb]. */
    fun nightGainDb(levelDb: Float): Float {
        val over = levelDb - NIGHT_THRESHOLD_DB
        val half = NIGHT_KNEE_DB / 2
        val slope = 1f - 1f / NIGHT_RATIO
        val reduce = when {
            over <= -half -> 0f
            over >= half -> over * slope
            else -> slope * (over + half) * (over + half) / (2 * NIGHT_KNEE_DB)
        }
        return NIGHT_MAKEUP_DB - reduce
    }

    /**
     * Shapes [count] interleaved samples of [pcm] in place, [channels] to a
     * frame (a partial last frame is left as it is).
     */
    fun process(pcm: ShortArray, count: Int, channels: Int) {
        if (channels <= 0 || count <= 0) return
        val frames = count / channels
        val mode = if (channels == 2) stereo else STEREO
        if (mode != STEREO) {
            var i = 0
            for (f in 0 until frames) {
                val l = pcm[i].toInt()
                val r = pcm[i + 1].toInt()
                if (mode == MONO) {
                    val m = ((l + r) shr 1).toShort()
                    pcm[i] = m
                    pcm[i + 1] = m
                } else {
                    pcm[i] = r.toShort()
                    pcm[i + 1] = l.toShort()
                }
                i += 2
            }
        }
        if (!night) {
            gain = 1f
            env = 0f
            return
        }
        var frame = 0
        while (frame < frames) {
            val n = minOf(BLOCK, frames - frame)
            // The block's peak drives the envelope, frame by frame.
            var blockPeak = 0f
            val start = frame * channels
            for (k in 0 until n) {
                var peak = 0f
                val base = start + k * channels
                for (c in 0 until channels) {
                    val v = abs(pcm[base + c].toFloat()) / 32768f
                    if (v > peak) peak = v
                }
                val coeff = if (peak > env) attack else release
                env = coeff * env + (1 - coeff) * peak
                if (peak > blockPeak) blockPeak = peak
            }
            val levelDb = 20f * log10(max(env, 1e-6f))
            var target = 10f.pow(nightGainDb(levelDb) / 20f)
            // The ceiling: the block's loudest sample never past it.
            if (blockPeak * target > CEILING) target = CEILING / blockPeak
            // From the last block's gain to this one's, a step a frame;
            // straight down when the ceiling needs it (no overshoot).
            val from = if (target < gain && blockPeak * gain > CEILING) target else gain
            for (k in 0 until n) {
                val g = from + (target - from) * (k + 1) / n
                val base = start + k * channels
                for (c in 0 until channels) {
                    val s = pcm[base + c] * g
                    pcm[base + c] = when {
                        s > 32767f -> Short.MAX_VALUE
                        s < -32768f -> Short.MIN_VALUE
                        else -> s.toInt().toShort()
                    }
                }
            }
            gain = target
            frame += n
        }
    }
}
