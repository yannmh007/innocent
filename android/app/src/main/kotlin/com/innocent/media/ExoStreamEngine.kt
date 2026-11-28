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

    // ♪ on a catalogue film (ExoAudio.kt): the sound shaped (Stereo mode,
    // Night mode), the audio clock moved (Synchronization), the tracks the
    // ladder offers (an HLS rendition each, or the one muxed in).
    private val shape = com.innocent.media.audio.AudioShape()
    @Volatile
    private var audioDelayUs = 0L
    private var tracksNow: Tracks? = null

    /** The film's frame rate as its video declares it (P2), 0 unknown. */
    private var filmFps = 0f

    /** Scrubbing mode as last asked ([scrubbing]): what a suppressed playback is put down to. */
    private var scrubOn = false
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
                // The film on its own SurfaceView keeps it.
                if (!filmOn) player?.setVideoSurface(surface.surface)
                emit(mapOf("id" to id, "e" to "surface", "on" to true))
            }

            override fun onSurfaceCleanup() {
                if (!filmOn) player?.clearVideoSurface()
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
            // two. TRIED FIVE (ExoPlayer's default) on 7 Nov 2026 and put
            // back: in the device lab's A/B (runs 42358540751 and
            // 42360760676, same flow) five turned what had been 3-14 ms
            // blips after a stall into one more stop a viewer sees (1.26 s):
            // waiting for five seconds of film is a longer stop every time,
            // and the stops it was meant to prevent were blips, not stops.
            // Keep up to a minute ahead, and thirty seconds behind so a step
            // back is played from memory.
            .setBufferDurationsMs(30_000, 60_000, 1_000, 2_000)
            .setBackBuffer(30_000, true)
            // A minute of 240p and a minute of 1080p are both a minute.
            .setPrioritizeTimeOverSizeThresholds(true)
            .build()
        val p = ExoPlayer.Builder(context, ExoAudio.renderers(context, shape) { audioDelayUs })
            .setTrackSelector(selector)
            .setBandwidthMeter(meter)
            .setLoadControl(load)
            .setMediaSourceFactory(sourcesFor(http, progressive))
            .setSeekParameters(SeekParameters.EXACT)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setHandleAudioBecomingNoisy(true)
            // LAB (SmoothLab `sched`): off, Media3's default, unless a lab
            // asked — the playback loop then sleeps until a renderer can
            // make progress instead of waking every 10 ms.
            .experimentalSetDynamicSchedulingEnabled(labSched)
            .build()
        // The app keeps audio focus itself (AudioFocusService), as for
        // libmpv; two owners would fight over it.
        p.setAudioAttributes(
            AudioAttributes.Builder()
                .setUsage(C.USAGE_MEDIA)
                .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
                .build(),
            false)
        // The film where the player put it: its own SurfaceView, or the texture.
        val fv = filmView
        if (filmOn && fv != null) {
            filmAwait = "view"
            p.setVideoSurfaceHolder(fv.holder)
        } else {
            p.setVideoSurface(surface.surface)
        }
        reopen = { at, play ->
            open(url, at, play, target, maxHeight, bps, start, rungs, progressive)
        }
        p.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) = sendState()
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                sendState()
                // P2: the display at the film's rate while it plays.
                DisplayVote.film(if (isPlaying) filmFps else 0f)
            }
            override fun onPlaybackSuppressionReasonChanged(reason: Int) = sendState()

            override fun onVideoSizeChanged(videoSize: VideoSize) {
                if (videoSize.width > 0 && videoSize.height > 0) {
                    surface.setSize(videoSize.width, videoSize.height)
                    videoNow = videoSize
                    filmView?.holder?.setFixedSize(videoSize.width, videoSize.height)
                    layoutFilm()
                }
                emit(mapOf("id" to id, "e" to "size",
                    "w" to videoSize.width, "h" to videoSize.height))
            }

            override fun onRenderedFirstFrame() {
                emit(mapOf("id" to id, "e" to "first"))
            }

            override fun onTracksChanged(tracks: Tracks) {
                tracksNow = tracks
                emitAudio(tracks)
                val heights = mutableListOf<Int>()
                // What Auto weighs each rung by (the master's BANDWIDTH, its
                // fastest 20 s: HlsLadder.peakWindowMs), for the trail:
                // whether a rung fits a line is this over 0.7, not its
                // average.
                val peaks = mutableListOf<Int>()
                var selected = 0
                var adaptive = false
                for (g in tracks.groups) {
                    if (g.type != C.TRACK_TYPE_VIDEO) continue
                    adaptive = adaptive || g.isAdaptiveSupported
                    for (i in 0 until g.length) {
                        val f = g.getTrackFormat(i)
                        val h = steer.heightOf(f)
                        if (h > 0 && !heights.contains(h)) {
                            heights.add(h)
                            peaks.add(if (f.bitrate > 0) f.bitrate / 1000 else 0)
                        }
                        if (g.isTrackSelected(i)) selected++
                    }
                }
                emit(mapOf("id" to id, "e" to "tracks", "heights" to heights, "peaks" to peaks,
                    "selected" to selected, "adaptive" to adaptive))
            }

            override fun onPlayerError(error: PlaybackException) {
                emit(mapOf("id" to id, "e" to "error",
                    "code" to error.errorCodeName, "msg" to (error.message ?: "")))
            }
        })
        p.addAnalyticsListener(object : AnalyticsListener {
            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long,
            ) = filmFirstFrame(output)

            override fun onVideoInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: Format,
                decoderReuseEvaluation: DecoderReuseEvaluation?,
            ) {
                if (format.frameRate > 0f) {
                    filmFps = format.frameRate
                    if (player?.isPlaying == true) DisplayVote.film(filmFps)
                }
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
        // A new player starts out of scrubbing mode.
        scrubOn = false
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
            // Ready and asked to play, and not playing: why (14 Nov 2026, a
            // film left in scrubbing mode said it played and did not move).
            "held" to held(p.playbackSuppressionReason),
            "buffering" to (p.playbackState == Player.STATE_BUFFERING),
            "ended" to (p.playbackState == Player.STATE_ENDED),
            // At the moment it changes, not up to 250 ms late as the ticker's:
            // how much film was in hand when a stall began says whether the
            // line (none) or the phone (plenty) stopped it.
            "pos" to p.currentPosition,
            "buf" to p.bufferedPosition,
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
        scrubOn = on
        player?.setScrubbingModeEnabled(on)
    }

    /** A playback suppression in a word for the trail; empty for none. */
    private fun held(reason: Int): String = when {
        reason == Player.PLAYBACK_SUPPRESSION_REASON_NONE -> ""
        scrubOn -> "scrubbing"
        reason == Player.PLAYBACK_SUPPRESSION_REASON_TRANSIENT_AUDIO_FOCUS_LOSS -> "audio focus"
        else -> "reason $reason"
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

    // ── THE FILM ON ITS OWN SURFACE (P1 in production, 28 Nov 2026) ─────
    // The film on Android's own SurfaceView under Flutter's see-through
    // surface (PlayerWindow.kt), as MX draws it: MediaCodec renders into a
    // surface the display composes itself, and Flutter is not woken by each
    // frame (Test Lab 46124628533: app CPU realme 61 → 39 %, OPPO 52 → ~42 %
    // of a core; Flutter 0 frames while nothing changes). The player places
    // it ([filmPlace]: video_geometry.dart's rectangle in pixels — fit,
    // zoom, pan, crop, stretch, 100 %) and moves the film between it and the
    // texture ([filmSurface]): an effect only Flutter can draw (a colour
    // filter, a mirror), the in-app picture-in-picture window. Each move
    // waits for the film's first frame on the new surface before the old
    // one goes (`film` events), so no black frame shows between; the
    // texture keeps its last picture meanwhile, and the SurfaceView its own.
    private var filmView: android.view.SurfaceView? = null
    private var filmRoot: android.view.ViewGroup? = null

    /** ExoPlayer renders into [filmView] (asked; its first frame may be on its way). */
    private var filmOn = false

    /** Whose first frame is awaited: "view", "texture" or none. */
    private var filmAwait: String? = null

    /** The film's frame is on the SurfaceView: what Dart was told last. */
    private var filmShown = false

    /** Where the player wants the film (px in the FlutterView: l, t, w, h), for a view of [filmFor]. */
    private var filmRect: IntArray? = null
    private var filmFor: IntArray? = null
    private var videoNow: VideoSize? = null

    /** The SurfaceView was made secure (the window's FLAG_SECURE then). */
    private var filmSecure = false
    private val filmRelayout = android.view.View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        layoutFilm()
    }
    private val filmRemove = Runnable { dropFilmView() }

    /**
     * Paused, Media3 still releases a frame to a new surface
     * (VideoFrameReleaseControl.setOutputSurface: FIRST_FRAME_NOT_RENDERED
     * is force-released while not started), but its loop runs once a
     * second then and may hold no decoded frame: a seek to where it is
     * makes one.
     */
    private val filmNudge = Runnable {
        val p = player ?: return@Runnable
        if (filmAwait != null && !p.playWhenReady) {
            emit(mapOf("id" to id, "e" to "film", "note" to "paused switch, nudged"))
            p.seekTo(p.currentPosition)
        }
    }
    private var reopen: ((Long, Boolean) -> Unit)? = null

    /**
     * The film on its own SurfaceView ([on]) or back on the texture. False
     * when it cannot be (Flutter's surface opaque: PlayerWindow.seeThrough;
     * no Activity): the film stays where it is.
     */
    fun filmSurface(on: Boolean): Boolean {
        if (on) {
            if (filmOn) return true
            if (!PlayerWindow.seeThrough) return false
            val a = PlayerWindow.current() ?: return false
            val root = a.findViewById<android.view.ViewGroup>(android.R.id.content) ?: return false
            main.removeCallbacks(filmRemove)
            var v = filmView
            if (v == null || v.parent !== root) {
                dropFilmView()
                v = android.view.SurfaceView(a)
                // A paid film or a vault one (FLAG_SECURE on the window): its
                // own surface kept out of screenshots and recordings too —
                // set before it is in the window.
                filmSecure = windowSecure()
                v.setSecure(filmSecure)
                root.addView(v, 0, android.widget.FrameLayout.LayoutParams(
                    1, 1, android.view.Gravity.TOP or android.view.Gravity.START))
                root.addOnLayoutChangeListener(filmRelayout)
                filmRoot = root
                filmView = v
            }
            videoNow?.let { vs ->
                if (vs.width > 0 && vs.height > 0) v.holder.setFixedSize(vs.width, vs.height)
            }
            layoutFilm()
            filmOn = true
            filmAwait = "view"
            player?.setVideoSurfaceHolder(v.holder)
            main.removeCallbacks(filmNudge)
            main.postDelayed(filmNudge, 1600)
            return true
        }
        if (!filmOn) return true
        filmOn = false
        DisplayVote.filmSurface(false)
        val p = player
        if (p == null || p.playbackState == Player.STATE_IDLE) {
            // Nothing renders (released, stopped): no frame to wait for.
            p?.setVideoSurface(surface.surface)
            dropFilmView()
            return true
        }
        filmAwait = "texture"
        p.setVideoSurface(surface.surface)
        main.removeCallbacks(filmRemove)
        // At the latest: a film that renders nothing (stopped, ended).
        main.postDelayed(filmRemove, 2500)
        main.removeCallbacks(filmNudge)
        main.postDelayed(filmNudge, 1600)
        return true
    }

    /** A first frame on [output]: the move [filmSurface] began has landed. */
    private fun filmFirstFrame(output: Any) {
        val onView = filmView?.holder?.surface?.let { it === output } == true
        when (filmAwait) {
            "view" -> if (onView) {
                filmAwait = null
                main.removeCallbacks(filmNudge)
                DisplayVote.filmSurface(true)
                if (!filmShown) {
                    filmShown = true
                    emit(mapOf("id" to id, "e" to "film", "on" to true))
                }
            }
            "texture" -> if (!onView) {
                filmAwait = null
                main.removeCallbacks(filmNudge)
                if (filmShown) {
                    filmShown = false
                    emit(mapOf("id" to id, "e" to "film", "on" to false))
                }
                // The SurfaceView goes once Flutter has drawn the texture's
                // frame over it (an event, a rebuild, a vsync).
                main.removeCallbacks(filmRemove)
                main.postDelayed(filmRemove, 300)
            }
        }
    }

    /** The SurfaceView out of the window; the film (if it was there) on the texture. */
    private fun dropFilmView() {
        main.removeCallbacks(filmRemove)
        main.removeCallbacks(filmNudge)
        val v = filmView
        if (filmOn) {
            filmOn = false
            DisplayVote.filmSurface(false)
            if (v != null) player?.clearVideoSurfaceHolder(v.holder)
            player?.setVideoSurface(surface.surface)
        }
        filmAwait = null
        filmRoot?.removeOnLayoutChangeListener(filmRelayout)
        filmRoot = null
        filmView = null
        if (v != null) (v.parent as? android.view.ViewGroup)?.removeView(v)
        if (filmShown) {
            filmShown = false
            emit(mapOf("id" to id, "e" to "film", "on" to false))
        }
    }

    /** The Activity was made again: its window holds no SurfaceView of ours. */
    fun filmLost() {
        if (filmView != null) dropFilmView()
    }

    /**
     * The window's FLAG_SECURE changed (the next film is paid, or not): a
     * SurfaceView takes its secure flag only before it is in a window, so
     * one made otherwise goes; the player asks for a new one.
     */
    fun filmSecureCheck() {
        if (filmView != null && filmSecure != windowSecure()) dropFilmView()
    }

    private fun windowSecure(): Boolean {
        val flags = PlayerWindow.current()?.window?.attributes?.flags ?: 0
        return (flags and android.view.WindowManager.LayoutParams.FLAG_SECURE) != 0
    }

    /** Where the film goes: [l], [t], [w], [h] px in Flutter's view of [vw]×[vh]. */
    fun filmPlace(l: Int, t: Int, w: Int, h: Int, vw: Int, vh: Int) {
        filmRect = intArrayOf(l, t, w, h)
        filmFor = intArrayOf(vw, vh)
        layoutFilm()
    }

    /**
     * The SurfaceView where the player asked, in the root's pixels (Flutter's
     * view may sit inside it); while the window's size is not the one the
     * player measured (a turn, picture-in-picture, before Flutter's next
     * frame), the whole film centred in it.
     */
    private fun layoutFilm() {
        val v = filmView ?: return
        val root = filmRoot ?: return
        val fv = PlayerWindow.flutterSurface(root)
        val vw = fv?.width ?: root.width
        val vh = fv?.height ?: root.height
        if (vw <= 0 || vh <= 0) return
        var dx = 0
        var dy = 0
        if (fv != null) {
            val a = IntArray(2)
            val b = IntArray(2)
            fv.getLocationInWindow(a)
            root.getLocationInWindow(b)
            dx = a[0] - b[0]
            dy = a[1] - b[1]
        }
        val r = filmRect
        val f = filmFor
        val l: Int
        val t: Int
        val w: Int
        val h: Int
        if (r != null && f != null && f[0] == vw && f[1] == vh) {
            l = r[0]; t = r[1]; w = r[2]; h = r[3]
        } else {
            val vs = videoNow ?: return
            if (vs.width <= 0 || vs.height <= 0) return
            val aspect = vs.width * vs.pixelWidthHeightRatio / vs.height
            var fw = vw
            var fh = Math.round(vw / aspect)
            if (fh > vh) {
                fh = vh
                fw = Math.round(vh * aspect)
            }
            w = fw; h = fh; l = (vw - fw) / 2; t = (vh - fh) / 2
        }
        val lp = v.layoutParams as android.widget.FrameLayout.LayoutParams
        val nw = w.coerceAtLeast(1)
        val nh = h.coerceAtLeast(1)
        if (lp.width == nw && lp.height == nh && lp.leftMargin == l + dx && lp.topMargin == t + dy) return
        lp.width = nw
        lp.height = nh
        lp.leftMargin = l + dx
        lp.topMargin = t + dy
        lp.gravity = android.view.Gravity.TOP or android.view.Gravity.START
        v.layoutParams = lp
    }

    /**
     * The Screenshot shortcut while the film is on its SurfaceView (a
     * RepaintBoundary of Flutter's holds nothing of it then): the frame by
     * PixelCopy, the part of it on screen (Crop and zoom cut it as the
     * viewer sees it), at the film's own resolution, as a PNG. Null when
     * it cannot.
     */
    fun filmShot(result: MethodChannel.Result) {
        val v = filmView
        val vs = videoNow
        val root = filmRoot
        if (v == null || !filmShown || vs == null || root == null || !v.holder.surface.isValid ||
            vs.width <= 0 || vs.height <= 0 || v.width <= 0 || v.height <= 0) {
            result.success(null)
            return
        }
        // The SurfaceView's part inside Flutter's view, in its own pixels.
        val fv = PlayerWindow.flutterSurface(root)
        val vw = fv?.width ?: root.width
        val vh = fv?.height ?: root.height
        val lp = v.layoutParams as android.widget.FrameLayout.LayoutParams
        val l = lp.leftMargin
        val t = lp.topMargin
        val visL = maxOf(0, -l)
        val visT = maxOf(0, -t)
        val visR = minOf(v.width, vw - l)
        val visB = minOf(v.height, vh - t)
        if (visR <= visL || visB <= visT) {
            result.success(null)
            return
        }
        val sx = vs.width.toDouble() / v.width
        val sy = vs.height.toDouble() / v.height
        val src = android.graphics.Rect(
            Math.floor(visL * sx).toInt(), Math.floor(visT * sy).toInt(),
            Math.ceil(visR * sx).toInt().coerceAtMost(vs.width),
            Math.ceil(visB * sy).toInt().coerceAtMost(vs.height))
        // The film's horizontal resolution; the height as the screen shows
        // it (Stretch, a non-square pixel).
        val outW = src.width().coerceAtLeast(1)
        val outH = Math.round(outW * (visB - visT).toDouble() / (visR - visL)).toInt().coerceAtLeast(1)
        val bmp = android.graphics.Bitmap.createBitmap(outW, outH, android.graphics.Bitmap.Config.ARGB_8888)
        try {
            android.view.PixelCopy.request(v, src, bmp, { code ->
                if (code != android.view.PixelCopy.SUCCESS) {
                    bmp.recycle()
                    result.success(null)
                    return@request
                }
                Thread {
                    val out = java.io.ByteArrayOutputStream()
                    val ok = bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
                    bmp.recycle()
                    main.post { result.success(if (ok) out.toByteArray() else null) }
                }.start()
            }, main)
        } catch (t: Throwable) {
            bmp.recycle()
            result.success(null)
        }
    }

    /** The same film opened again where it is (a Builder switch to apply). */
    fun labReopen(): Boolean {
        val p = player ?: return false
        val r = reopen ?: return false
        r(p.currentPosition, p.playWhenReady)
        return true
    }

    // ── ♪ (P4) ────────────────────────────────────────────────────────────
    /**
     * The audio tracks as ♪ lists them: `id` is "group:track" in the
     * player's Tracks, `on` the one playing; `off` when audio is disabled.
     */
    private fun emitAudio(tracks: Tracks) {
        val list = mutableListOf<Map<String, Any?>>()
        tracks.groups.forEachIndexed { gi, g ->
            if (g.type != C.TRACK_TYPE_AUDIO) return@forEachIndexed
            for (i in 0 until g.length) {
                val f = g.getTrackFormat(i)
                list.add(mapOf(
                    "id" to "$gi:$i",
                    "title" to f.label,
                    "lang" to f.language,
                    "codec" to (f.codecs ?: f.sampleMimeType),
                    "ch" to (if (f.channelCount > 0) f.channelCount else null),
                    "on" to g.isTrackSelected(i),
                    "ok" to g.isTrackSupported(i),
                ))
            }
        }
        val off = player?.trackSelectionParameters?.disabledTrackTypes?.contains(C.TRACK_TYPE_AUDIO) == true
        emit(mapOf("id" to id, "e" to "audio", "tracks" to list, "off" to off))
    }

    /** Plays the audio track [trackId] ("group:track"); false when unknown. */
    fun audioTrack(trackId: String): Boolean {
        val p = player ?: return false
        val t = tracksNow ?: return false
        val parts = trackId.split(':')
        val gi = parts.getOrNull(0)?.toIntOrNull() ?: return false
        val ti = parts.getOrNull(1)?.toIntOrNull() ?: return false
        val g = t.groups.getOrNull(gi) ?: return false
        if (g.type != C.TRACK_TYPE_AUDIO || ti !in 0 until g.length) return false
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, false)
            .setOverrideForType(androidx.media3.common.TrackSelectionOverride(g.mediaTrackGroup, ti))
            .build()
        return true
    }

    /** MX's Disable: no audio track at all ([off]), or back. */
    fun audioOff(off: Boolean) {
        val p = player ?: return
        p.trackSelectionParameters = p.trackSelectionParameters.buildUpon()
            .setTrackTypeDisabled(C.TRACK_TYPE_AUDIO, off)
            .build()
        tracksNow?.let { emitAudio(it) }
    }

    /** Synchronization: the sound [ms] later than the picture (negative: sooner). */
    fun audioDelay(ms: Long) {
        audioDelayUs = ms.coerceIn(-10_000L, 10_000L) * 1000L
    }

    /** Stereo mode: 0 stereo, 1 mono, 2 left and right swapped. */
    fun stereo(mode: Int) {
        shape.stereo = mode.coerceIn(0, 2)
    }

    /** Night mode: loud moments down, quiet ones up. */
    fun night(on: Boolean) {
        shape.night = on
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
            // ♪ (P4): what the sound goes through now, for the lab's check.
            "stereo" to shape.stereo,
            "night" to shape.night,
            "framesMono" to shape.framesMono,
            "framesSwap" to shape.framesSwap,
            "framesNight" to shape.framesNight,
            "gainDb" to shape.gainDb.toDouble(),
            "delayMs" to audioDelayUs / 1000L,
            "audioOff" to p.trackSelectionParameters.disabledTrackTypes.contains(C.TRACK_TYPE_AUDIO),
            "volume" to p.volume.toDouble(),
            "boostOn" to (enhancer?.enabled == true),
            "boostMb" to (if (enhancer?.enabled == true) (enhancer?.targetGain?.toDouble() ?: 0.0) else 0.0),
            // P1: where the film is drawn.
            "film" to (if (filmShown) "view" else if (filmOn) "to view" else "texture"),
            // Where its SurfaceView is, in the window's pixels (the lab's shots).
            "filmRect" to filmView?.let { "${it.left},${it.top} ${it.width}x${it.height}" },
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
        DisplayVote.film(0f)
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
            dropFilmView()
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

        /** A reading of the line has come in (or a remembered one was seeded). */
        @Volatile var measured = false
            private set

        /** A first value: what the line was last measured at. */
        fun seed(bps: Long) {
            fast = bps.toDouble()
            slow = bps.toDouble()
            estimate = bps
            measured = true
        }

        /**
         * No reading yet: a value that keeps the rung the app opened on.
         * Not a measurement — the first reading moves it like any other.
         */
        fun guess(bps: Long) {
            if (measured) return
            fast = bps.toDouble()
            slow = bps.toDouble()
            estimate = bps
        }

        fun add(bps: Long) {
            measured = true
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
            // NOTHING MEASURED YET: Auto keeps the rung the app opened on
            // until a reading of the line says otherwise. The meter's own
            // default (1.5 Mbit/s, 70 % of it usable) is below a 480p rung's
            // peak, so with no evidence at all Auto stepped down to 360p as
            // soon as the start rung's two segments were in, and that change
            // on a four-second buffer cost a 1 s stop (device lab run
            // 42370839630, on a line that carried 480p). HERE, before the
            // selection exists: it settles its own first choice from the
            // meter as it is built, and a guess made later (on the tracks,
            // run 42373118426) changed nothing — the 360p choice was already
            // inside it, held back only while the start rung was forced.
            val start = steer.start
            val m = bandwidthMeter as? ProxyMeter
            if (start != null && m != null && !m.measured && group.type == C.TRACK_TYPE_VIDEO) {
                var peak = 0
                for (i in tracks) {
                    val f = group.getFormat(i)
                    if (steer.heightOf(f) == start && f.bitrate > peak) peak = f.bitrate
                }
                if (peak > 0) m.guess((peak / AdaptiveTrackSelection.DEFAULT_BANDWIDTH_FRACTION * 1.1).toLong())
            }
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
            // (Holding its first climb until 10 s were in hand was A/B'd on
            // 19 Nov 2026, device lab S3 44565023092, on a remembered
            // 3000 kbps line: the picture 36 ms apart, stops alike — taken
            // out.)
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

        /** A new Activity (PlayerWindow): no film keeps a SurfaceView of the old one. */
        fun windowChanged() {
            for (e in engines.values) e.filmLost()
        }

        /** The window's FLAG_SECURE changed: each film's SurfaceView follows. */
        fun secureChanged() {
            for (e in engines.values) e.filmSecureCheck()
        }

        /** LAB ONLY: dynamic scheduling for the players opened from now on. */
        @Volatile
        var labSched = false
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
                    // The film on its own SurfaceView (P1): see the members above.
                    if (call.method == "filmSurface") {
                        result.success(e.filmSurface(call.argument<Boolean>("on") ?: false))
                        return@setMethodCallHandler
                    }
                    if (call.method == "filmPlace") {
                        e.filmPlace(
                            (call.argument<Number>("l"))?.toInt() ?: 0,
                            (call.argument<Number>("t"))?.toInt() ?: 0,
                            (call.argument<Number>("w"))?.toInt() ?: 0,
                            (call.argument<Number>("h"))?.toInt() ?: 0,
                            (call.argument<Number>("vw"))?.toInt() ?: 0,
                            (call.argument<Number>("vh"))?.toInt() ?: 0,
                        )
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    if (call.method == "filmShot") {
                        e.filmShot(result)
                        return@setMethodCallHandler
                    }
                    // LAB ONLY (SmoothLab `sched`).
                    if (call.method == "labSched") {
                        labSched = call.argument<Boolean>("on") ?: false
                        result.success(e.labReopen())
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
                        "audioTrack" -> {
                            result.success(e.audioTrack(call.argument<String>("track") ?: ""))
                            return@setMethodCallHandler
                        }
                        "audioOff" -> e.audioOff(call.argument<Boolean>("off") ?: false)
                        "audioDelay" -> e.audioDelay((call.argument<Number>("ms"))?.toLong() ?: 0L)
                        "stereo" -> e.stereo((call.argument<Number>("mode"))?.toInt() ?: 0)
                        "night" -> e.night(call.argument<Boolean>("on") ?: false)
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
                    // never takes the app down with it. The class too: a
                    // message alone is often null, and the trail then said
                    // nothing (ExoEngine._refused, 14 Nov 2026).
                    result.error("exo", "${t.javaClass.simpleName}: ${t.message ?: ""}", null)
                }
            }
        }
    }
}
