package com.innocent.media

import android.content.Context
import android.media.audiofx.LoudnessEnhancer
import android.os.Handler
import android.os.Looper
import androidx.annotation.OptIn
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.Format
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.common.TrackGroup
import androidx.media3.common.Tracks
import androidx.media3.common.VideoSize
import androidx.media3.common.util.Clock
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.exoplayer.DecoderReuseEvaluation
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsMediaSource
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaSource
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.media3.exoplayer.source.MediaLoadData
import androidx.media3.exoplayer.source.chunk.Chunk
import androidx.media3.exoplayer.source.chunk.MediaChunk
import androidx.media3.exoplayer.source.chunk.MediaChunkIterator
import androidx.media3.exoplayer.trackselection.AdaptiveTrackSelection
import androidx.media3.exoplayer.trackselection.DefaultTrackSelector
import androidx.media3.exoplayer.upstream.BandwidthMeter
import androidx.media3.exoplayer.upstream.DefaultLoadErrorHandlingPolicy
import com.google.common.collect.ImmutableList
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry

/**
 * Catalogue films that have a ladder, played by Media3's ExoPlayer as HLS.
 *
 * WHY A SECOND ENGINE. libmpv cannot change rung inside one stream on this
 * ladder (FFmpeg ticket #7359), so a change of quality reopened the film:
 * 4 to 7 s on real phones before the picture moved again, and Auto stepped
 * down only after the film had stalled. ExoPlayer — the engine YouTube's
 * Android app is built on — reads the same files as HLS
 * (StreamCacheServer.hlsUrlFor) and changes rung at a segment boundary with
 * the picture still moving, and drops a rung before the buffer runs dry.
 * Everything else stays on libmpv: local files, the vault, music, network
 * streams, an Original. docs/streaming_pro_plan.md.
 *
 * THE BYTES STILL COME THROUGH THE PROXY: the bind header, the sealed cache,
 * the renewal of an expired link and the measurement of the line all stay
 * where they were. ExoPlayer only ever talks to 127.0.0.1.
 *
 * WHAT THE CHANNEL CARRIES
 *   methods `innocent/exo`: create, open, play, pause, seek, scrubbing,
 *     rate, volume, quality, maxHeight, bandwidth, stop, release
 *   events `innocent/exo/events`: state, pos, size, rung, first, tracks,
 *     dropped, error — each with the engine's `id`.
 */
@OptIn(UnstableApi::class)
class ExoStreamEngine private constructor(
    private val context: Context,
    val id: Int,
    private val surface: TextureRegistry.SurfaceProducer,
    private val emit: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val steer = Steer()
    private val meter = ProxyMeter()
    private val factory = SteeredFactory(steer)
    private val selector = DefaultTrackSelector(context, factory)
    private var player: ExoPlayer? = null
    private var lastRung = -1

    private val ticker = object : Runnable {
        override fun run() {
            val p = player ?: return
            emit(mapOf(
                "id" to id, "e" to "pos",
                "pos" to p.currentPosition,
                "buf" to p.bufferedPosition,
                "dur" to (if (p.duration == C.TIME_UNSET) 0L else p.duration),
            ))
            main.postDelayed(this, 250)
        }
    }

    init {
        surface.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
            // The surface comes and goes with the app's window (a trip to the
            // home screen, picture-in-picture on some phones). The film keeps
            // playing without a picture meanwhile — the sound is what a
            // viewer who stepped away is still listening to.
            override fun onSurfaceAvailable() {
                player?.setVideoSurface(surface.surface)
                emit(mapOf("id" to id, "e" to "surface", "on" to true))
            }

            override fun onSurfaceCleanup() {
                player?.clearVideoSurface()
                emit(mapOf("id" to id, "e" to "surface", "on" to false))
            }
        })
        // Every rung is a choice: the screen's size is no reason to hide a
        // 1080p the viewer picks on a 720p phone. Auto is capped by [Steer].
        selector.setParameters(
            selector.buildUponParameters().clearViewportSizeConstraints().build())
    }

    fun open(
        url: String, startMs: Long, autoplay: Boolean,
        target: Int?, maxHeight: Int?, bps: Long?, start: Int?,
        rungs: Map<Int, Int>, progressive: Boolean = false,
    ) {
        release(keepSurface = true)
        steer.target = target
        steer.maxHeight = maxHeight
        steer.start = start
        steer.heightByRate = rungs
        if (bps != null && bps > 0) meter.seed(bps)
        val http = DefaultHttpDataSource.Factory()
            .setUserAgent("Innocent")
            .setConnectTimeoutMs(15_000)
            // A segment the proxy is still fetching can be quiet for a
            // while on a slow line; the proxy gives up on its own reads at
            // twenty seconds.
            .setReadTimeoutMs(30_000)
            .setAllowCrossProtocolRedirects(false)
        val load = DefaultLoadControl.Builder()
            // Start on one second of film, as YouTube does; after a stall,
            // two. Keep up to a minute ahead, and thirty seconds behind so a
            // step back is played from memory.
            .setBufferDurationsMs(30_000, 60_000, 1_000, 2_000)
            .setBackBuffer(30_000, true)
            // A minute of 240p and a minute of 1080p are both a minute.
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val p = ExoPlayer.Builder(context)
            .setTrackSelector(selector)
            .setBandwidthMeter(meter)
            .setLoadControl(load)
            .setMediaSourceFactory(sourcesFor(http, progressive))
            .setSeekParameters(SeekParameters.EXACT)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setHandleAudioBecomingNoisy(true)
            .build()
        // The app keeps audio focus itself (AudioFocusService), as for
        // libmpv; two owners would fight over it.
        p.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            false)
        p.setVideoSurface(surface.surface)
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) = sendState()
            override fun onIsPlayingChanged(isPlaying: Boolean) = sendState()

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    surface.setSize(videoSize.width, videoSize.height)
                }
                emit(mapOf("id" to id, "e" to "size",
                    "w" to videoSize.width, "h" to videoSize.height))
            }

            override fun onRenderedFirstFrame() {
                emit(mapOf("id" to id, "e" to "first"))
            }

            override fun onTracksChanged(tracks: Tracks) {
                val heights = mutableListOf<Int>()
                var selected = 0
                var adaptive = false
                for (g in tracks.groups) {
                    if (g.type != C.TRACK_TYPE_VIDEO) continue
                    adaptive = adaptive || g.isAdaptiveSupported
                    for (i in 0 until g.length) {
                        val h = steer.heightOf(g.getTrackFormat(i))
                        if (h > 0 && !heights.contains(h)) heights.add(h)
                        if (g.isTrackSelected(i)) selected++
                    }
                }
                emit(mapOf("id" to id, "e" to "tracks", "heights" to heights,
                    "selected" to selected, "adaptive" to adaptive))
            }

            override fun onPlayerError(error: PlaybackException) {
                emit(mapOf("id" to id, "e" to "error",
                    "code" to error.errorCodeName, "msg" to (error.message ?: "")))
            }
        })
        p.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                decoderReuseEvaluation: DecoderReuseEvaluation?,
            ) {
                if (format.height == lastRung) return
                lastRung = format.height
                emit(mapOf("id" to id, "e" to "rung", "h" to format.height,
                    "kbps" to (if (format.bitrate > 0) format.bitrate / 1000 else 0)))
            }

            override fun onLoadError(
                eventTime: AnalyticsListener.EventTime,
                loadEventInfo: LoadEventInfo,
                mediaLoadData: MediaLoadData,
                error: java.io.IOException,
                wasCanceled: Boolean,
            ) {
                // The file asked for (a playlist's name or a rung's cache id;
                // never the token, which is the path's middle) and why.
                emit(mapOf("id" to id, "e" to "loaderr",
                    "what" to (loadEventInfo.uri.lastPathSegment ?: "-"),
                    "type" to mediaLoadData.dataType,
                    "err" to error.javaClass.simpleName))
            }

            override fun onDroppedVideoFrames(
                eventTime: AnalyticsListener.EventTime, droppedFrames: Int, elapsedMs: Long,
            ) {
                emit(mapOf("id" to id, "e" to "dropped", "n" to droppedFrames))
            }
        })
        player = p
        p.volume = gainWanted.coerceAtMost(1.0).toFloat()
        if (gainWanted > 1.0) applyBoost(p)
        // A single file (a film's Original, through the proxy) is read by
        // byte range like any MP4; the ladder is HLS.
        val item = if (progressive) {
            MediaItem.Builder().setUri(url).setMimeType(MimeTypes.VIDEO_MP4).build()
        } else {
            MediaItem.Builder().setUri(url).setMimeType(MimeTypes.APPLICATION_M3U8).build()
        }
        p.setMediaItem(item, startMs.coerceAtLeast(0))
        p.playWhenReady = autoplay
        p.prepare()
        main.removeCallbacks(ticker)
        main.post(ticker)
    }

    /**
     * How the film is read: the ladder as HLS, or one file (an Original) as a
     * progressive MP4. Either way a line that drops out for half a minute —
     * a lift, a dead spot — is waited for with the buffer playing on: ten
     * tries, where three (the default) stopped the film with an error.
     */
    private fun sourcesFor(http: DefaultHttpDataSource.Factory, progressive: Boolean): MediaSource.Factory {
        val retry = DefaultLoadErrorHandlingPolicy(10)
        if (progressive) {
            return ProgressiveMediaSource.Factory(http).setLoadErrorHandlingPolicy(retry)
        }
        return HlsMediaSource.Factory(http)
            // The master names every rung's codecs and size, so the player
            // starts from it without reading a segment first.
            .setAllowChunklessPreparation(true)
            .setLoadErrorHandlingPolicy(retry)
    }

    private fun sendState() {
        val p = player ?: return
        emit(mapOf(
            "id" to id, "e" to "state",
            "playing" to p.isPlaying,
            "ready" to p.playWhenReady,
            "buffering" to (p.playbackState == Player.STATE_BUFFERING),
            "ended" to (p.playbackState == Player.STATE_ENDED),
        ))
    }

    fun play() { player?.play() }
    fun pause() { player?.pause() }

    /**
     * [fast]: land on the keyframe nearest [ms] (at most a second off, two
     * seconds apart on the ladder) — a far jump then needs one segment from
     * its first byte and no decoding up to the frame. Near jumps are exact.
     */
    fun seek(ms: Long, fast: Boolean) {
        val p = player ?: return
        p.setSeekParameters(if (fast) SeekParameters.CLOSEST_SYNC else SeekParameters.EXACT)
        p.seekTo(ms.coerceAtLeast(0))
        emit(mapOf("id" to id, "e" to "pos", "pos" to p.currentPosition,
            "buf" to p.bufferedPosition, "dur" to (if (p.duration == C.TIME_UNSET) 0L else p.duration)))
    }

    /** While a finger drags the bar: frames as fast as the decoder can show them. */
    fun scrubbing(on: Boolean) {
        player?.setScrubbingModeEnabled(on)
    }

    fun rate(r: Double) { player?.playbackParameters = PlaybackParameters(r.toFloat()) }
    fun volume(v: Double) = gain(v)

    /**
     * The viewer's volume, up to 4x: to 1.0 it is the player's volume,
     * above it the sound is lifted with the platform's LoudnessEnhancer on
     * the player's audio session, as libmpv's volume-max does for files.
     */
    fun gain(multiplier: Double) {
        gainWanted = multiplier.coerceIn(0.0, 4.0)
        val p = player ?: return
        p.volume = gainWanted.coerceAtMost(1.0).toFloat()
        applyBoost(p)
    }

    private var gainWanted = 1.0
    private var enhancer: LoudnessEnhancer? = null
    private var enhancerSession = 0

    private fun applyBoost(p: ExoPlayer) {
        try {
            if (gainWanted <= 1.0) {
                enhancer?.enabled = false
                return
            }
            val session = p.audioSessionId
            if (session == C.AUDIO_SESSION_ID_UNSET) return
            if (enhancer == null || enhancerSession != session) {
                enhancer?.release()
                enhancer = LoudnessEnhancer(session)
                enhancerSession = session
            }
            // Millibels: 20 * log10(gain) dB.
            val mB = (2000.0 * Math.log10(gainWanted)).toInt()
            enhancer?.setTargetGain(mB)
            enhancer?.enabled = true
        } catch (_: Throwable) {
            // No enhancer on this phone: full volume is the most there is.
        }
    }

    /**
     * A rung by height, or Auto (null). Applied at once to what is loaded
     * next, and to what is buffered past the next two seconds ([Steer]) —
     * the picture never stops: what is already decoded plays out while the
     * new rung's segments arrive.
     */
    fun quality(height: Int?) {
        steer.target = height
        nudge()
        report("quality")
    }

    /**
     * What the steering is acting on, in the trail: how many steered
     * selections the player has made, the rungs the latest one holds, and
     * the rung it picks now. A pick nobody acts on shows up here.
     */
    private fun report(why: String) {
        val sel = factory.last
        val heights = mutableListOf<Int>()
        var picks = -1
        if (sel != null) {
            for (i in 0 until sel.length()) heights.add(steer.heightOf(sel.getFormat(i)))
            picks = steer.heightOf(sel.getFormat(sel.selectedIndex))
        }
        emit(mapOf("id" to id, "e" to "steer", "why" to why,
            "target" to steer.target, "made" to factory.made,
            "heights" to heights, "picks" to picks))
    }

    /** What the picture is doing: frames drawn and dropped so far. */
    fun stats(): Map<String, Any?> {
        val p = player ?: return emptyMap()
        val c = p.videoDecoderCounters
        c?.ensureUpdated()
        return mapOf(
            "rendered" to (c?.renderedOutputBufferCount ?: -1),
            "dropped" to (c?.droppedBufferCount ?: -1),
            "playing" to p.isPlaying,
            "pos" to p.currentPosition,
        )
    }

    /** The data saver's ceiling for Auto, or none. */
    fun maxHeight(height: Int?) {
        steer.maxHeight = height
        nudge()
    }

    /** The line's speed, from the proxy's reads of the Worker (bits a second). */
    fun bandwidth(bps: Long) {
        if (bps > 0) meter.add(bps)
    }

    /** Makes the track selection look again now, not at the next chunk. */
    private fun nudge() {
        selector.setParameters(selector.buildUponParameters().build())
    }

    fun stop() {
        player?.stop()
        main.removeCallbacks(ticker)
    }

    fun release(keepSurface: Boolean = false) {
        main.removeCallbacks(ticker)
        try {
            enhancer?.release()
        } catch (_: Throwable) {
        }
        enhancer = null
        enhancerSession = 0
        player?.release()
        player = null
        lastRung = -1
        if (!keepSurface) {
            surface.setCallback(null)
            surface.release()
        }
    }

    /** What the viewer asked for: a rung, a ceiling, and how much to keep. */
    class Steer {
        @Volatile var target: Int? = null
        @Volatile var maxHeight: Int? = null
        /**
         * Auto's first rung: the one the app chose and warmed (its opening
         * seconds may already be on the phone), until a little film of it
         * is buffered and the player's own choice takes over.
         */
        @Volatile var start: Int? = null

        /**
         * Each rung's height by its average rate (the master's
         * AVERAGE-BANDWIDTH, bits a second), for a master written before
         * any rung's size was read: without it every rung's height is
         * unknown, and a pick of 240p matched the first, best rung
         * (device-lab run 40079651806).
         */
        @Volatile var heightByRate: Map<Int, Int> = emptyMap()

        fun heightOf(f: Format): Int =
            if (f.height > 0) f.height else heightByRate[f.averageBitrate] ?: Format.NO_VALUE
        /** Film kept in the old rung after a change: the next segment or so. */
        val keepUs = 2_000_000L
    }

    /**
     * The player's measure of the line, fed by the proxy (its own transfers
     * are loopback reads, which arrive at flash speed when cached and would
     * read as a line that can carry anything).
     */
    @OptIn(UnstableApi::class)
    class ProxyMeter : BandwidthMeter {
        // Two averages of the proxy's readings, a quick one and a slow one,
        // and the lower of them (as Shaka Player does): a line that drops is
        // believed at once, one that recovers only once it has held. The
        // last reading alone kept 720p through a dip to 2.7 Mbit/s right
        // after a seek, and the film stopped (run 40079651806).
        private var fast = 0.0
        private var slow = 0.0
        @Volatile var estimate: Long = 1_500_000L

        /** A first value: what the line was last measured at. */
        fun seed(bps: Long) {
            fast = bps.toDouble()
            slow = bps.toDouble()
            estimate = bps
        }

        fun add(bps: Long) {
            if (fast == 0.0) return seed(bps)
            fast = 0.5 * bps + 0.5 * fast
            slow = 0.2 * bps + 0.8 * slow
            estimate = minOf(fast, slow).toLong()
        }

        override fun getBitrateEstimate(): Long = estimate
        override fun getTransferListener(): TransferListener? = null
        override fun addEventListener(eventHandler: Handler, eventListener: BandwidthMeter.EventListener) {}
        override fun removeEventListener(eventListener: BandwidthMeter.EventListener) {}
    }

    @OptIn(UnstableApi::class)
    class SteeredFactory(private val steer: Steer) : AdaptiveTrackSelection.Factory() {
        /** The selections made, and the latest, for [report]. */
        @Volatile var made = 0
        @Volatile var last: SteeredSelection? = null

        override fun createAdaptiveTrackSelection(
            group: TrackGroup,
            tracks: IntArray,
            type: Int,
            bandwidthMeter: BandwidthMeter,
            adaptationCheckpoints: ImmutableList<AdaptiveTrackSelection.AdaptationCheckpoint>,
        ): AdaptiveTrackSelection {
            val s = SteeredSelection(group, tracks, type, bandwidthMeter, adaptationCheckpoints, steer)
            if (group.type == C.TRACK_TYPE_VIDEO) {
                made++
                last = s
            }
            return s
        }
    }

    /**
     * ExoPlayer's own adaptive choice, steered: a rung the viewer picked
     * wins, Auto stays under the data saver's ceiling, and what is buffered
     * in a rung no longer wanted is let go past the next two seconds, so a
     * change shows within a couple of seconds instead of after the buffer.
     */
    @OptIn(UnstableApi::class)
    class SteeredSelection(
        group: TrackGroup,
        tracks: IntArray,
        type: Int,
        meter: BandwidthMeter,
        checkpoints: List<AdaptiveTrackSelection.AdaptationCheckpoint>,
        private val steer: Steer,
    ) : AdaptiveTrackSelection(
        group, tracks, type, meter,
        AdaptiveTrackSelection.DEFAULT_MIN_DURATION_FOR_QUALITY_INCREASE_MS.toLong(),
        AdaptiveTrackSelection.DEFAULT_MAX_DURATION_FOR_QUALITY_DECREASE_MS.toLong(),
        AdaptiveTrackSelection.DEFAULT_MIN_DURATION_TO_RETAIN_AFTER_DISCARD_MS.toLong(),
        AdaptiveTrackSelection.DEFAULT_MAX_WIDTH_TO_DISCARD,
        AdaptiveTrackSelection.DEFAULT_MAX_HEIGHT_TO_DISCARD,
        AdaptiveTrackSelection.DEFAULT_BANDWIDTH_FRACTION,
        AdaptiveTrackSelection.DEFAULT_BUFFERED_FRACTION_TO_LIVE_EDGE_FOR_QUALITY_INCREASE,
        checkpoints,
        Clock.DEFAULT,
    ) {
        /** The track of [height], else the tallest below it, else the smallest. */
        private fun indexFor(height: Int): Int {
            var below = -1
            var belowH = -1
            var smallest = 0
            var smallestH = Int.MAX_VALUE
            for (i in 0 until length()) {
                val h = steer.heightOf(getFormat(i))
                if (h == height) return i
                if (h in (belowH + 1)..height) { below = i; belowH = h }
                if (h < smallestH) { smallest = i; smallestH = h }
            }
            return if (below >= 0) below else smallest
        }

        private fun fits(f: Format): Boolean {
            val t = steer.target
            if (t != null) return steer.heightOf(f) == steer.heightOf(getFormat(indexFor(t)))
            val cap = steer.maxHeight ?: return true
            return steer.heightOf(f) <= cap
        }

        private val steering: Boolean get() = steer.target != null || steer.maxHeight != null

        override fun getSelectedIndex(): Int {
            val t = steer.target
            if (t != null) return indexFor(t)
            steer.start?.let { return indexFor(it) }
            val i = super.getSelectedIndex()
            val cap = steer.maxHeight ?: return i
            return if (steer.heightOf(getFormat(i)) <= cap) i else indexFor(cap)
        }

        override fun updateSelectedTrack(
            playbackPositionUs: Long,
            bufferedDurationUs: Long,
            availableDurationUs: Long,
            queue: List<MediaChunk>,
            mediaChunkIterators: Array<out MediaChunkIterator>,
        ) {
            super.updateSelectedTrack(
                playbackPositionUs, bufferedDurationUs, availableDurationUs, queue, mediaChunkIterators)
            // Two segments of the start rung in hand: Auto is the player's.
            if (steer.start != null && queue.size >= 2) steer.start = null
        }

        override fun getSelectionReason(): Int =
            if (steer.target != null) C.SELECTION_REASON_MANUAL else super.getSelectionReason()

        override fun evaluateQueueSize(playbackPositionUs: Long, queue: List<MediaChunk>): Int {
            if (!steering) return super.evaluateQueueSize(playbackPositionUs, queue)
            val keepUntil = playbackPositionUs + steer.keepUs
            for (i in queue.indices) {
                val c = queue[i]
                if (c.startTimeUs >= keepUntil && !fits(c.trackFormat)) return i
            }
            return queue.size
        }

        override fun shouldCancelChunkLoad(
            playbackPositionUs: Long, loadingChunk: Chunk, queue: List<MediaChunk>,
        ): Boolean {
            if (!steering) return false
            return loadingChunk.startTimeUs >= playbackPositionUs + steer.keepUs &&
                !fits(loadingChunk.trackFormat)
        }
    }

    companion object {
        /** `[[height, averageBps], …]` as the channel carries it. */
        private fun rungsArg(raw: List<Any?>?): Map<Int, Int> {
            val out = mutableMapOf<Int, Int>()
            for (pair in raw ?: emptyList()) {
                val p = pair as? List<*> ?: continue
                val h = (p.getOrNull(0) as? Number)?.toInt() ?: continue
                val bps = (p.getOrNull(1) as? Number)?.toInt() ?: continue
                out[bps] = h
            }
            return out
        }

        private const val METHODS = "innocent/exo"
        private const val EVENTS = "innocent/exo/events"
        private val engines = mutableMapOf<Int, ExoStreamEngine>()
        private var nextId = 1
        private var sink: EventChannel.EventSink? = null

        fun register(flutterEngine: FlutterEngine, context: Context) {
            val messenger = flutterEngine.dartExecutor.binaryMessenger
            EventChannel(messenger, EVENTS).setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) { sink = events }
                override fun onCancel(arguments: Any?) { sink = null }
            })
            MethodChannel(messenger, METHODS).setMethodCallHandler { call, result ->
                try {
                    if (call.method == "create") {
                        val producer = flutterEngine.renderer.createSurfaceProducer()
                        val id = nextId++
                        engines[id] = ExoStreamEngine(context.applicationContext, id, producer) { m ->
                            sink?.success(m)
                        }
                        result.success(mapOf("id" to id, "texture" to producer.id()))
                        return@setMethodCallHandler
                    }
                    val id = (call.argument<Number>("id"))?.toInt() ?: -1
                    val e = engines[id]
                    if (e == null) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    if (call.method == "stats") {
                        result.success(e.stats())
                        return@setMethodCallHandler
                    }
                    when (call.method) {
                        "open" -> e.open(
                            call.argument<String>("url") ?: "",
                            (call.argument<Number>("startMs"))?.toLong() ?: 0L,
                            call.argument<Boolean>("autoplay") ?: true,
                            (call.argument<Number>("target"))?.toInt(),
                            (call.argument<Number>("maxHeight"))?.toInt(),
                            (call.argument<Number>("bps"))?.toLong(),
                            (call.argument<Number>("start"))?.toInt(),
                            rungsArg(call.argument<List<Any?>>("rungs")),
                            call.argument<Boolean>("progressive") ?: false,
                        )
                        "play" -> e.play()
                        "pause" -> e.pause()
                        "seek" -> e.seek(
                            (call.argument<Number>("ms"))?.toLong() ?: 0L,
                            call.argument<Boolean>("fast") ?: false,
                        )
                        "scrubbing" -> e.scrubbing(call.argument<Boolean>("on") ?: false)
                        "rate" -> e.rate((call.argument<Number>("rate"))?.toDouble() ?: 1.0)
                        "volume" -> e.volume((call.argument<Number>("volume"))?.toDouble() ?: 1.0)
                        "quality" -> e.quality((call.argument<Number>("height"))?.toInt())
                        "maxHeight" -> e.maxHeight((call.argument<Number>("height"))?.toInt())
                        "bandwidth" -> e.bandwidth((call.argument<Number>("bps"))?.toLong() ?: 0L)
                        "stop" -> e.stop()
                        "release" -> {
                            e.release()
                            engines.remove(id)
                        }
                        else -> {
                            result.notImplemented()
                            return@setMethodCallHandler
                        }
                    }
                    result.success(true)
                } catch (t: Throwable) {
                    // A player that cannot do what it was asked says so; it
                    // never takes the app down with it.
                    result.error("exo", t.message, null)
                }
            }
        }
    }
}
