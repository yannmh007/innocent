import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' as mk;
import 'package:media_kit_video/media_kit_video.dart' as mkv;

import 'models/audio_track_info.dart';
import 'models/subtitle_track_info.dart';
import 'models/video_track_info.dart';
import '../diagnostics/playback_log.dart';
import 'video_player_service.dart';

/// Decouples the video player from the equalizer service. The EQ service
/// registers a callback here that returns the shared audio-session id; the
/// player calls it at startup to bind libmpv's AudioTrack output to that
/// same id, so the native effects actually process the sound. Kept as a
/// tiny static hook to avoid a hard dependency between the two services.
class EqualizerSessionBinder {
  EqualizerSessionBinder._();
  static Future<int> Function()? sessionIdProvider;
}

/// media_kit (libmpv) implementation of [VideoPlayerService].
///
/// Phase 45 — powerful-video-player rewrite. The previous implementation
/// only set a buffer size and a title; everything else used libmpv
/// defaults. That's fine for happy-path local files but falls over on
/// network streams, large MKV files, hardware-decode-capable devices,
/// and detailed subtitle styling. This version exposes the libmpv
/// properties MX Player and similar players rely on, with safe defaults
/// that work on any Android version from 7.0 up.
class MediaKitPlayerService implements VideoPlayerService {
  // NOT `late final`: dropping `final` makes a second assignment legal, which
  // matters because initialize() can now be re-entered after dispose(). The
  // real protection against double-init is [_initFuture] below.
  late mk.Player _player;
  late mkv.VideoController _videoController;
  bool _initialized = false;

  /// In-flight (or completed) initialisation.
  ///
  /// AUDIT FIX — this was a genuine first-play crash. Two callers race on the
  /// very first video: `videoPlayerServiceProvider` calls `initialize()`
  /// fire-and-forget the moment the service is constructed, and a few
  /// milliseconds later `_doOpenVideo` runs `if (!svc.isInitialized) await
  /// svc.initialize();`. `_initialized` only flips to true at the END of
  /// `_applyBaseline()` — roughly 25 async libmpv property writes plus one
  /// native round-trip for the audio-session id — so the second caller saw
  /// `false`, re-entered the body, and assigned the `late final _player` a
  /// SECOND time. Dart throws `LateInitializationError: Field '_player' has
  /// already been initialized` for that, which surfaces as a black player and
  /// "playback failed" on a perfectly good file, intermittently, depending on
  /// how fast the device is. Memoising the Future makes the second caller
  /// simply await the first.
  Future<void>? _initFuture;

  /// True whenever a video [MediaKitPlayerService] has been initialized
  /// (and not yet disposed). Lets other features — notably the music
  /// controller — decide whether the heavy video stack actually exists
  /// *without* reading the provider and thereby creating it. A music-only
  /// session leaves this false, so starting a song never spins up
  /// libmpv's video pipeline just to "pause nothing".
  static bool anyInitialized = false;

  // Cached current values
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;

  // Audit fix: track the cached-value subscriptions so dispose() can
  // cancel them. Without this every call to initialize() + dispose()
  // leaks three listener closures (a real concern when the user opens
  // many files in one session — each open() through the wrapper kept
  // building up listeners against the same _player). media_kit's
  // own dispose probably closes its streams cleanly, but defensive
  // cancellation is cheap and removes any ambiguity.
  StreamSubscription? _positionSub;
  StreamSubscription? _durationSub;
  StreamSubscription? _playingSub;

  // Track which decoder strategy is currently active so we can avoid
  // re-applying the same chain on every open() call.
  String _currentHwdec = 'auto-safe';

  /// The user's Settings → Player → "Fast seeking" preference.
  ///
  /// MX Player's switch of the same name trades exactness for speed: seeks
  /// land on the nearest keyframe instead of decoding forward to the requested
  /// frame. It is the right choice on a slow device or a long file, and the
  /// wrong one when you are trying to land on a specific frame — which is why
  /// it is a preference rather than a fixed behaviour.
  ///
  /// It is held here rather than pushed once because the scrub session
  /// temporarily forces keyframe seeking of its own; without a preference to
  /// return to, releasing the seek bar would have quietly re-enabled precise
  /// seeking for a user who had asked for the opposite.
  bool _fastSeek = false;

  /// The `hr-seek` value that reflects the user's preference right now.
  String get _restingSeekMode => _fastSeek ? 'no' : 'absolute';

  Future<void> setFastSeeking(bool enabled) async {
    _fastSeek = enabled;
    await _setMpvProperty('hr-seek', _restingSeekMode);
  }

  @override
  Future<void> initialize() => _initFuture ??= _initializeOnce();

  Future<void> _initializeOnce() async {
    if (_initialized) return;
    _player = mk.Player(
      configuration: const mk.PlayerConfiguration(
        // BATTERY/HEAT FIX — was 64 MB. This is the demuxer's byte ceiling
        // before [_applyBaseline] refines it per-file, and a phone does not
        // need a desktop-sized one: RAM held here is RAM the system takes back
        // from somewhere else, and the churn costs CPU. The real per-file
        // sizing now happens in [setStreamBufferProfile], which gives network
        // streams the generous buffer they genuinely need and local files the
        // small one they genuinely need.
        bufferSize: 24 * 1024 * 1024, // 24 MB
        title: 'Innocent',
      ),
    );
    // Phase 45: enable hardware acceleration on the texture path. The
    // VideoControllerConfiguration ctor's other knobs (width, height,
    // hwdec) have varying signatures across media_kit_video versions,
    // so we use only the most stable one.
    _videoController = mkv.VideoController(
      _player,
      configuration: const mkv.VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    // Wire cached values — assign to tracked fields so dispose can cancel.
    _positionSub = _player.stream.position.listen((p) => _position = p);
    _durationSub = _player.stream.duration.listen((d) => _duration = d);
    _playingSub = _player.stream.playing.listen((p) => _isPlaying = p);

    // Phase 45: apply a sensible decoder + subtitle baseline so even
    // before [PlayerProvider] pushes user preferences the file plays
    // correctly. These are cheap "set the once, libmpv remembers" calls.
    await _applyBaseline();

    _initialized = true;
    anyInitialized = true;
  }

  /// One-time libmpv property baseline. Idempotent; safe to call again.
  Future<void> _applyBaseline() async {
    // Hardware acceleration with software fallback. `auto-safe` tries the
    // platform decoder (MediaCodec on Android) and silently falls back to
    // software when the codec isn't supported — exactly what MX Player
    // does. The user can override this through Settings → Decoder.
    await _setMpvProperty('hwdec', 'auto-safe');
    // BATTERY/HEAT FIX — this used to be `yes`, which forces the stream cache
    // on for LOCAL files as well. mpv's default is `auto` (cache network
    // streams, leave local files uncached) and it is the default for a good
    // reason: reading a local file is already an order of magnitude faster
    // than decoding it, so a read-ahead thread on top of that buys nothing and
    // costs continuous storage wake-ups plus tens of megabytes of resident
    // RAM. Network streams still get the cache, because there it is the whole
    // point.
    await _setMpvProperty('cache', 'auto');
    // Conservative starting point; [setStreamBufferProfile] sizes these
    // properly per file once we know whether it is local or streamed.
    await _setMpvProperty('demuxer-max-bytes', '${32 * 1024 * 1024}');
    await _setMpvProperty('demuxer-max-back-bytes', '${16 * 1024 * 1024}');
    await _setMpvProperty('cache-secs', '10');
    await _setMpvProperty('demuxer-readahead-secs', '5');
    // Keep the back buffer seekable so a short scrub backwards is served from
    // RAM instead of re-reading and re-parsing. 16 MB covers several seconds
    // even at high bitrates, which is the range people actually scrub back
    // into.
    await _setMpvProperty('demuxer-seekable-cache', 'yes');
    // Network reads — 5 s timeout, 5 retries. Mirrors VLC defaults.
    await _setMpvProperty('network-timeout', '5');
    await _setMpvProperty('stream-lavf-o', 'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5');
    // Subtitle baseline — MX Player uses white + thin black border.
    await _setMpvProperty('sub-font', 'sans-serif');
    await _setMpvProperty('sub-color', '#FFFFFFFF');
    await _setMpvProperty('sub-border-color', '#FF000000');
    await _setMpvProperty('sub-border-size', '1.5');
    await _setMpvProperty('sub-shadow-color', '#80000000');
    await _setMpvProperty('sub-shadow-offset', '1');
    // Seeking strategy tuned so the user never waits on a spinner:
    //  • absolute seeks (scrub-bar release, chapter jumps) stay
    //    frame-precise so the final landing is exact;
    //  • relative seeks (±10 s skip, double-tap) use keyframe seeking,
    //    landing instantly instead of decoding to the exact frame.
    // During an active scrub *drag*, PlayerProvider temporarily drops
    // this to 'no' (keyframe everything) for an instant live preview,
    // then restores 'absolute' for the precise final seek on release.
    await _setMpvProperty('hr-seek', 'absolute');
    await _setMpvProperty('hr-seek-framedrop', 'yes');
    // Software-decode fallback speedups. This is now owned by Settings →
    // Decoder → "Use speedup tricks" (see setSpeedupTricks), which the open
    // path applies per file; the baseline just matches that setting's default
    // so the very first frame is decoded the same way as every later one.
    await _setMpvProperty('vd-lavc-fast', 'yes');
    await _setMpvProperty('vd-lavc-skiploopfilter', 'nonkey');
    // BATTERY/HEAT FIX — was '0', which means "one decode thread per CPU
    // core". On an eight-core phone that lights up every core the moment
    // libmpv falls back to software decoding, and a phone under full
    // multi-core load throttles, gets hot, and empties its battery fast. Four
    // threads decode 1080p comfortably while leaving headroom, which keeps the
    // SoC in its efficient range. Users who want the old behaviour can still
    // raise it in Settings → Decoder (videoDecoderThreads), which is applied
    // after this baseline.
    await _setMpvProperty('vd-lavc-threads', '4');
    // Keep last frame on EOF instead of going black — matches MX Player.
    await _setMpvProperty('keep-open', 'yes');
    // Bind libmpv's Android audio output to a known audio-session id so the
    // Equalizer / BassBoost / Virtualizer effects (attached to that same id
    // natively) actually process this playback. Without this, libmpv opens
    // its AudioTrack on an arbitrary session and the effects — which modern
    // Android no longer applies to the global mix (session 0) — do nothing.
    // Best-effort: if the id can't be obtained, or a libmpv build ignores
    // the option, playback still works (just without guaranteed EQ).
    await _bindAudioSession();
  }

  /// Fetch the shared audio-session id and hand it to libmpv's AudioTrack
  /// output. Uses the `audiotrack-session-id` option (honoured by the
  /// AudioTrack AO); we also force the audiotrack AO on Android so the session
  /// id is actually used (opensles ignores it).
  ///
  /// These must be set BEFORE libmpv opens its audio output for the first
  /// media — which is why this runs from [_applyBaseline] during init, ahead of
  /// any [open]. If binding fails, playback still works (just without a
  /// guaranteed session for the EQ to attach to).
  Future<void> _bindAudioSession() async {
    try {
      final sid = await EqualizerSessionBinder.sessionIdProvider?.call();
      if (sid == null || sid == 0) return;
      // Force the AudioTrack output FIRST (it's the only Android AO that
      // honours a caller-supplied session id), then bind the id. Order
      // matters: the id option is read when the AO is created.
      await _setMpvProperty('ao', 'audiotrack');
      await _setMpvProperty('audiotrack-session-id', '$sid');
    } catch (e) {
      if (kDebugMode) debugPrint('media_kit_player_service.audio-session: $e');
    }
  }

  /// Set a libmpv property without throwing. media_kit's platform handle
  /// is `dynamic` because the type differs between native and web
  /// implementations, so we have to use `dynamic` here.
  /// Returns true when libmpv accepted the write.
  ///
  /// The result matters for properties we cache locally: libmpv verifies
  /// option changes at runtime and rejects ones it cannot apply, keeping its
  /// previous value. Caching a value it rejected would make us skip the next
  /// attempt to set the same thing, believing it was already applied.
  Future<bool> _setMpvProperty(String key, String value) async {
    try {
      await (_player.platform as dynamic)?.setProperty(key, value);
      return true;
    } catch (_) {
      // libmpv refuses unknown properties on some platforms. Ignore.
      return false;
    }
  }

  /// Read one libmpv property back. Always-non-throwing: returns null when
  /// the platform object has no `getProperty` (it does on NativePlayer, but
  /// the signature has moved between media_kit versions) or libmpv refuses.
  Future<String?> _getMpvProperty(String key) async {
    try {
      final value = await (_player.platform as dynamic)?.getProperty(key);
      if (value is String && value.isNotEmpty) return value;
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Audit fix (standard high-quality): public version of
  /// [_setMpvProperty]. The player_provider live-apply paths need
  /// to set subtitle layout properties without going through a
  /// dedicated method per knob. Always-non-throwing.
  Future<void> setMpvProperty(String key, String value) async {
    await _setMpvProperty(key, value);
  }

  /// Audit fix (Phase 4 #15): apply or clear a loudness-normalization
  /// audio filter. libmpv exposes the `af` (audio filters) property
  /// which accepts an ffmpeg filter graph; `dynaudnorm` is the
  /// classic real-time loudness normalizer that doesn't need
  /// look-ahead (so it works on streams). Setting `af` to empty
  /// removes any filter chain.
  ///
  /// NOTE: this is best-effort. media_kit's libmpv build may not
  /// include all ffmpeg filters; setProperty silently fails when a
  /// filter is unsupported. The caller should treat the toggle as
  /// "tried" rather than "guaranteed working".
  Future<void> setLoudnessNormalization(bool enabled) async {
    if (enabled) {
      // dynaudnorm parameters tuned for music + speech:
      //   g=15 → 15-sample sliding window (~300 ms at 48 kHz)
      //   p=0.95 → target peak 95 % of max
      //   m=10.0 → max gain factor 10 dB
      //   r=0.0 → no RMS coupling between channels
      //   s=20 → 20 ms compress/release smoothing
      // These are conservative; users who need aggressive levelling
      // can chain a stronger filter in a future setting.
      await _setMpvProperty('af', 'dynaudnorm=g=15:p=0.95:m=10.0:r=0.0:s=20');
    } else {
      await _setMpvProperty('af', '');
    }
  }

  @override
  bool get isInitialized => _initialized;

  // === Streams ===
  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<bool> get bufferingStream => _player.stream.buffering;

  @override
  Stream<Duration> get bufferedStream =>
      _player.stream.buffer.map((d) => d);

  @override
  Stream<List<AudioTrackInfo>> get audioTracksStream =>
      _player.stream.tracks.map(
        (tracks) => tracks.audio.map(_mapAudio).toList(),
      );

  @override
  Stream<List<SubtitleTrackInfo>> get subtitleTracksStream =>
      _player.stream.tracks.map(
        (tracks) => tracks.subtitle.map(_mapSubtitle).toList(),
      );

  @override
  Stream<List<VideoTrackInfo>> get videoTracksStream =>
      _player.stream.tracks.map(
        (tracks) => tracks.video.map(_mapVideo).toList(),
      );

  @override
  Stream<double> get volumeStream =>
      _player.stream.volume.map((v) => v / 100.0);

  @override
  Stream<double> get rateStream => _player.stream.rate;

  /// Called with whatever libmpv says went wrong, if anyone is listening.
  ///
  /// TikTok playback has now been "fixed" four times without anybody once
  /// reading the player's own account of the failure — it went to a snackbar
  /// that vanishes and nowhere else. Unmasking the extractor's warnings found
  /// the JavaScript runtime in a single round; this is the same instrument
  /// one layer further down.
  static void Function(String message)? onPlaybackError;

  @override
  Stream<String?> get errorStream =>
      _player.stream.error.map<String?>((e) {
        if (e.isEmpty) return null;
        // v1.63: into the persistent trail as well. Every libmpv error was
        // going only to whatever UI happened to be listening, so an error
        // that arrived just before a crash left no record at all — and the
        // moment right before a crash is the only moment that matters.
        PlaybackLog.add('mpv error: ${e.length > 160 ? e.substring(0, 160) : e}');
        try {
          onPlaybackError?.call(e);
        } catch (_) {
          // Reporting a failure must never become one.
        }
        return e;
      });

  @override
  Stream<bool> get completedStream => _player.stream.completed;

  // === Sync getters ===
  @override
  Duration get position => _position;

  @override
  Duration get duration => _duration;

  @override
  bool get isPlaying => _isPlaying;

  // === Lifecycle ===
  /// Headers to attach to the next open of one specific URL.
  ///
  /// A deliberate handoff rather than another parameter threaded through the
  /// player UI: opening a video passes through the route, the screen, the
  /// provider and two controllers, and widening all of them for a case that
  /// only the downloader produces would put a rarely-used argument into the
  /// most-used path in the app. Claimed by the first playback that matches
  /// and released when playback moves on, so it cannot leak onto an
  /// unrelated file — which the previous single-stage version described
  /// but did not actually do.
  /// PENDING arming: set by [attachHeaders], cleared the moment a playback
  /// claims it. Host-matched inside a short window, purely to survive a
  /// redirect between the URL the downloader resolved and the one libmpv
  /// actually opens.
  static String? _headerHost;
  static Map<String, String>? _headerValues;
  static DateTime? _headerAt;

  /// LIVE headers: the arming above, once a playback has claimed it, bound to
  /// the exact URI that claimed it.
  ///
  /// The two-stage design fixes two faults the single-stage one had, both of
  /// which the doc above already claimed were handled:
  ///
  ///   * **Leakage.** A host match with no consumption meant any OTHER video
  ///     opened from the same host within the window inherited the
  ///     downloader's headers — cookies included. Claiming the arming ends it,
  ///     so a second playback gets nothing.
  ///   * **Silent loss on retry.** The window expired on wall-clock time, so a
  ///     reconnect more than a minute into a film reopened the URL with no
  ///     headers and failed for a reason nothing reported. Live headers are
  ///     keyed on the URI, not the clock, so a retry of the SAME stream keeps
  ///     them for as long as it is the thing playing.
  static String? _liveHeaderUri;
  static Map<String, String>? _liveHeaderValues;

  /// How long a PENDING arming survives before a playback claims it.
  static const Duration _headerWindow = Duration(seconds: 60);

  /// Called just before handing a streamed URL to the player.
  ///
  /// Matched on HOST inside a short window rather than on the exact URL
  /// string. Exact matching looked tidier and was too brittle: the string that
  /// reaches [open] has travelled through a route, a screen and two
  /// controllers, and any one of them normalising a character means the
  /// headers are silently dropped — which is indistinguishable from never
  /// having attached them. Host plus a one-minute window cannot leak onto an
  /// unrelated file and cannot miss the one it was meant for.
  static void attachHeaders(String uri, Map<String, String> headers) {
    if (headers.isEmpty) {
      _headerHost = null;
      _headerValues = null;
      _headerAt = null;
      return;
    }
    _headerHost = Uri.tryParse(uri)?.host;
    _headerValues = Map<String, String>.of(headers);
    _headerAt = DateTime.now();
  }

  /// Headers for [uri], claiming a pending arming if one applies.
  ///
  /// Order matters: the live binding is checked FIRST, so a reconnect of the
  /// stream that is already playing keeps its headers however long the film
  /// has been running. Only then is a pending arming considered — and taking
  /// it clears it, so it can never be applied to a second video.
  static Map<String, String>? _claimHeadersFor(String uri) {
    if (_liveHeaderUri == uri) return _liveHeaderValues;

    final Map<String, String>? values = _headerValues;
    final String? host = _headerHost;
    final DateTime? at = _headerAt;
    if (values == null || host == null || at == null) return null;
    if (DateTime.now().difference(at) > _headerWindow) {
      _headerHost = null;
      _headerValues = null;
      _headerAt = null;
      return null;
    }
    if (Uri.tryParse(uri)?.host != host) return null;

    // Claim it: the arming becomes this stream's live headers and stops being
    // available to anything else.
    _liveHeaderUri = uri;
    _liveHeaderValues = values;
    _headerHost = null;
    _headerValues = null;
    _headerAt = null;
    return values;
  }

  /// Drops the live binding when playback moves to a different stream.
  ///
  /// Called from [open] rather than from a caller, because [open] is the only
  /// place that knows a different video has started.
  static void _releaseLiveHeadersUnless(String uri) {
    if (_liveHeaderUri != null && _liveHeaderUri != uri) {
      _liveHeaderUri = null;
      _liveHeaderValues = null;
    }
  }

  @override
  Future<void> open(String uri, {Duration? startAt, bool autoplay = true}) async {
    // v1.61 — the single most valuable breadcrumb there is. The process has
    // been dying during playback, and the scheme of what is being opened
    // (file / adb / content / http) is the first thing that separates the
    // candidates. The full path is NOT recorded: it can name a private file
    // and the trail is copied out to be shared.
    PlaybackLog.add(
      'open scheme=${_schemeOf(uri)} len=${uri.length} '
      'hwdec=${_currentHwdec ?? "-"} start=${startAt?.inSeconds ?? 0}s '
      'autoplay=$autoplay',
    );
    // Release a binding held for a DIFFERENT stream before claiming, so
    // headers never outlive the playback they were armed for.
    _releaseLiveHeadersUnless(uri);
    final Map<String, String>? headers = _claimHeadersFor(uri);
    // Always reattach video before loading anything.
    //
    // Without this, a file opened while the player happened to be in
    // background-audio mode would load with `vid=no` still in force and play
    // with no picture at all — and nothing in the foreground path would ever
    // put it back, because the reattach is driven by a lifecycle transition
    // that already happened.
    // v1.52: this used to restore only `vid`, which left `vo=null` in force —
    // a file opened out of background-audio mode would then play with sound
    // and no picture, permanently. [_reattachVideo] restores both.
    await _reattachVideo(seekToResync: false);
    // mpv's own "begin this file at time T" mechanism.
    //
    // Seeking after open() is a race: Player.open() issues `loadfile` and
    // returns before the demuxer has the file open, so a seek sent right
    // afterwards can arrive too early and be dropped. `start` is read by mpv
    // as part of LOADING the file, so the demuxer begins there — no race, and
    // no window where frame 0 is decoded and shown before the jump.
    //
    // Written on every open, including the plain case, so a value set for one
    // file can never leak into the next one.
    await _setMpvProperty(
      'start',
      (startAt != null && startAt > Duration.zero)
          ? (startAt.inMilliseconds / 1000).toStringAsFixed(3)
          : '0',
    );
    // v1.63 — the open is bracketed so a crash can be placed on one side of
    // it or the other. `open` returned but no `open ok` line means the
    // process died INSIDE libmpv's load, which is a completely different
    // suspect from dying afterwards during decode or render. Without the
    // bracket both look identical in the trail.
    try {
      await _player.open(mk.Media(uri, httpHeaders: headers), play: autoplay);
      PlaybackLog.add('open ok');
    } catch (e) {
      PlaybackLog.add('open FAILED: $e');
      rethrow;
    }
    // Audit fix: tolerate initial-seek failure. Some poorly-muxed
    // files open fine but throw on seek to a non-keyframe position.
    // Industry behaviour (ExoPlayer's MediaSession bridge, VLC's
    // resume) is to fall back to position 0 silently rather than
    // present the file as unplayable. The user can scrub manually
    // once playback starts.
    if (startAt != null && startAt > Duration.zero) {
      // Belt and braces. `start` above should already have landed us here,
      // making this a no-op onto the same keyframe. It stays as a fallback for
      // the case where the property write did not take, because silently
      // resuming a two-hour film from the beginning is a far worse failure
      // than one redundant keyframe seek.
      //
      // Keyframe seeking (hr-seek=no) so the first frame appears instantly
      // rather than waiting for libmpv to decode forward to an exact
      // timestamp nobody can perceive. Restored straight after.
      await _setMpvProperty('hr-seek', 'no');
      try {
        await _player.seek(startAt);
      } catch (_) {
        // Not seekable this early — `start` is the primary mechanism anyway.
      }
      await _setMpvProperty('hr-seek', _restingSeekMode);
    }
  }

  @override
  Future<void> dispose() async {
    // Audit fix: cancel cached-value subscriptions BEFORE disposing
    // _player, so onDone callbacks (if any) don't fire on an
    // already-disposed instance.
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _playingSub?.cancel();
    _positionSub = null;
    _durationSub = null;
    _playingSub = null;
    // AUDIT FIX (v1.55) — the detach watchdog added in v1.54 was never
    // cancelled here, so a service torn down while backgrounded left a
    // periodic timer writing properties to a disposed player.
    _bgReassertTimer?.cancel();
    _bgReassertTimer = null;
    // Invalidate any surface transition still part-way through its awaits, so
    // it abandons itself instead of writing into a player that is about to be
    // destroyed. Same reasoning as the fade generation below.
    _surfaceGen++;
    _videoDetached = false;
    // Kill any in-flight volume ramp so it can't write to a dead player.
    _fadeGen++;
    await _player.dispose();
    _initialized = false;
    anyInitialized = false;
    // Allow a later initialize() to rebuild the engine instead of handing
    // back the resolved Future of the instance we just tore down.
    _initFuture = null;
  }

  // === Playback control ===
  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration to) => _player.seek(to);

  /// See [VideoPlayerService.frameStep].
  ///
  /// Playback is paused first because a frame-step on a playing file is
  /// meaningless — mpv pauses anyway, and doing it here keeps our own
  /// `isPlaying` state honest instead of letting it drift out of sync with
  /// the engine.
  @override
  Future<void> frameStep({bool forward = true}) async {
    try {
      await _player.pause();
    } catch (_) {}
    final ok = await _sendMpvCommand(
      forward ? ['frame-step'] : ['frame-back-step'],
    );
    if (!ok) {
      PlaybackLog.add('frameStep unsupported by this media_kit build');
    }
  }

  /// Send a raw libmpv command.
  ///
  /// media_kit exposes `NativePlayer` behind a `dynamic` platform object and
  /// the exact signature has moved between versions, so this is written the
  /// same defensive way as [_setMpvProperty]: try, and report false rather
  /// than throw into the caller. Nothing in the app depends on the command
  /// succeeding.
  Future<bool> _sendMpvCommand(List<String> args) async {
    try {
      await (_player.platform as dynamic)?.command(args);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> seekRelative(Duration delta) async {
    final target = _position + delta;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    await _player.seek(clamped);
  }

  // === Audio ===
  /// The volume libmpv is *supposed* to be at, on libmpv's own 0..400 scale.
  ///
  /// AUDIT FIX — this used to be implicit, and three callers disagreed about
  /// it. `setAudioGain(2.0)` writes volume=200 for the audio booster, but
  /// `fadeInVolume()` hard-coded a ramp to 100, so the first seek after
  /// enabling the booster silently halved the sound and never restored it.
  /// Tracking the intended level in one place means every ramp ends exactly
  /// where the user's settings say it should.
  double _volumePct = 100.0;

  /// Generation counter for [fadeInVolume]. Each new ramp invalidates the
  /// previous one. Without this, scrubbing the seek bar with "fade in on
  /// seek" enabled spawned one 12-step ramp per throttled seek — up to ~16 a
  /// second — all writing `volume` in interleaved order, which is audible as
  /// a wobble rather than a fade.
  int _fadeGen = 0;

  @override
  Future<void> setVolume(double volume) {
    _volumePct = volume.clamp(0.0, 1.0) * 100;
    _fadeGen++; // an explicit volume set wins over any running ramp
    return _player.setVolume(_volumePct);
  }

  /// Mute without disturbing the volume level.
  ///
  /// AUDIT FIX — muting used to be implemented by writing 0 to BOTH the
  /// device's system media volume and libmpv's volume. That changed the
  /// phone's global media volume (it stayed changed after leaving the app)
  /// and, because unmute restored a 0..1 value, it also wiped any audio
  /// boost. libmpv's own `mute` property is the correct primitive: it is
  /// instant, scoped to this player, and leaves `volume` untouched.
  Future<void> setMuted(bool muted) =>
      _setMpvProperty('mute', muted ? 'yes' : 'no');

  /// Phase 45 (audit refined, build 63): MX Player V3's
  /// `audio_fade_in_on_start` + `audio_fade_in_on_seek`. Actual
  /// implementation: ramp the libmpv volume from 0 → [targetPct] over
  /// ~600 ms using small periodic steps. Called from the player
  /// provider AFTER play() / seek() so the audio softly comes in
  /// instead of slamming on at full volume.
  ///
  /// [targetPct] is 0..100 (libmpv's native scale). 100 = current
  /// system master volume (libmpv volume is independent of system).
  Future<void> fadeInVolume({
    double? targetPct,
    Duration duration = const Duration(milliseconds: 600),
  }) async {
    // Default to the level the user's settings actually call for (which is
    // >100 when the audio booster is on), never a hard-coded 100.
    final target = (targetPct ?? _volumePct).clamp(0.0, 400.0);
    final gen = ++_fadeGen;
    const steps = 12;
    final stepMs = (duration.inMilliseconds / steps).round();
    for (var i = 1; i <= steps; i++) {
      // A newer ramp (or an explicit setVolume / setAudioGain) started —
      // abandon this one instead of fighting it.
      if (gen != _fadeGen) return;
      final pct = (target * i / steps).clamp(0.0, 400.0);
      try {
        await _player.setVolume(pct);
      } catch (_) {
        // If libmpv isn't ready, abort the ramp and let the user hear
        // audio at full volume — better than silent failure.
        return;
      }
      await Future.delayed(Duration(milliseconds: stepMs));
    }
    // Land exactly on the intended level; the stepped arithmetic above can
    // leave a rounding gap on the final step.
    if (gen == _fadeGen) {
      try {
        await _player.setVolume(target);
      } catch (_) {}
    }
  }

  @override
  Future<void> setAudioTrack(AudioTrackInfo track) async {
    final tracks = _player.state.tracks.audio;
    final mkTrack = tracks.firstWhere(
      (t) => t.id == track.id,
      orElse: () => mk.AudioTrack.auto(),
    );
    await _player.setAudioTrack(mkTrack);
  }

  // === Speed ===
  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  // === Subtitle ===
  @override
  Future<void> setSubtitleTrack(SubtitleTrackInfo? track) async {
    if (track == null) {
      await _player.setSubtitleTrack(mk.SubtitleTrack.no());
      return;
    }
    final tracks = _player.state.tracks.subtitle;
    final mkTrack = tracks.firstWhere(
      (t) => t.id == track.id,
      orElse: () => mk.SubtitleTrack.auto(),
    );
    await _player.setSubtitleTrack(mkTrack);
  }

  @override
  Future<void> loadExternalSubtitle(String path) async {
    await _player.setSubtitleTrack(mk.SubtitleTrack.uri(path));
  }

  @override
  Future<void> setSubtitleDelay(Duration delay) async {
    final seconds = delay.inMilliseconds / 1000.0;
    await _setMpvProperty('sub-delay', seconds.toString());
  }

  @override
  Future<void> setSubtitleSize(double size) async {
    // libmpv sub-font-size is in points (default 55).
    await _setMpvProperty('sub-font-size', size.toStringAsFixed(0));
  }

  // === Phase 45: powerful-player extensions ===

  /// Switch the libmpv hardware-decoder strategy.
  ///
  /// Valid values:
  /// * `'auto-safe'` (default) — HW with safe SW fallback. Recommended.
  /// * `'auto'` — HW with eager fallback. Faster on flagship devices.
  /// * `'no'` — pure software. Highest compatibility, more CPU.
  /// * `'mediacodec'` — Android MediaCodec only.
  /// * `'mediacodec-copy'` — MediaCodec + frame copy (rare codecs).
  /// Scheme only, never the path — see the note in [open].
  static String _schemeOf(String uri) {
    final i = uri.indexOf(':');
    if (i <= 0 || i > 12) return 'path';
    return uri.substring(0, i);
  }

  Future<void> setHardwareDecoder(String mode) async {
    if (_currentHwdec == mode) return;
    PlaybackLog.add('hwdec -> $mode');
    // Cache only on success. A device whose driver refuses `auto` leaves
    // libmpv on its previous decoder; recording the requested value anyway
    // would make every later attempt at the same mode a no-op, so the user
    // could never get back to it — the switch would appear permanently stuck.
    if (await _setMpvProperty('hwdec', mode)) {
      _currentHwdec = mode;
    }
  }

  /// Snappy-scrub support. While the user is dragging the seek bar,
  /// PlayerProvider calls this with [precise]=false to switch libmpv to
  /// keyframe-only seeking, so each throttled preview jump lands
  /// instantly (no decode-to-exact-frame work that would otherwise show
  /// a buffering spinner). On release it calls [precise]=true to restore
  /// the 'absolute' baseline and then performs one exact seek to the
  /// final position. Cheap single-property writes; always non-throwing.
  Future<void> setPreciseSeek(bool precise) => _setMpvProperty(
      'hr-seek', precise ? _restingSeekMode : 'no');

  /// Update the subtitle border + shadow + color baseline. Each parameter
  /// is optional so the caller can change just one without disturbing
  /// the others.
  Future<void> setSubtitleStyle({
    String? color, // #AARRGGBB
    String? borderColor,
    double? borderSize,
    String? shadowColor,
    double? shadowOffset,
    String? font,
  }) async {
    if (color != null) await _setMpvProperty('sub-color', color);
    if (borderColor != null) {
      await _setMpvProperty('sub-border-color', borderColor);
    }
    if (borderSize != null) {
      await _setMpvProperty('sub-border-size', borderSize.toStringAsFixed(1));
    }
    if (shadowColor != null) {
      await _setMpvProperty('sub-shadow-color', shadowColor);
    }
    if (shadowOffset != null) {
      await _setMpvProperty(
          'sub-shadow-offset', shadowOffset.toStringAsFixed(1));
    }
    if (font != null) await _setMpvProperty('sub-font', font);
  }

  /// Phase 45 (audit refined, build 63): subtitle scale (size multiplier).
  /// MX Player V3 `tune_subtitle_scale` slider value. libmpv's
  /// `sub-scale` property accepts a float (1.0 = base size).
  Future<void> setSubtitleScale(double scale) async {
    final clamped = scale.clamp(0.1, 2.0);
    await _setMpvProperty('sub-scale', clamped.toStringAsFixed(2));
  }

  /// v1.63: subtitle vertical position, 0 (top) … 100 (bottom).
  ///
  /// Exposed at RUNTIME, not only as a startup setting. Moving a subtitle out
  /// from under a hardcoded caption burned into the video is something you
  /// discover you need in the middle of a scene, and until now it meant
  /// leaving the player for Settings and coming back.
  ///
  /// libmpv's `sub-pos` is a percentage measured from the TOP, which is the
  /// same convention as `IntSetting.subtitleVerticalPos`, so no inversion is
  /// needed here.
  Future<void> setSubtitleVerticalPos(int percent) async {
    final clamped = percent.clamp(0, 150);
    await _setMpvProperty('sub-pos', clamped.toString());
  }

  /// Phase 45 (audit refined, build 63): subtitle shadow intensity.
  /// [level]: 0=None, 1=Subtle, 2=Default, 3=Strong. Maps to libmpv's
  /// `sub-shadow-color` (alpha) and `sub-shadow-offset`.
  Future<void> setSubtitleShadow(int level) async {
    switch (level.clamp(0, 3)) {
      case 0:
        await _setMpvProperty('sub-shadow-offset', '0');
        await _setMpvProperty('sub-shadow-color', '#00000000');
        break;
      case 1:
        await _setMpvProperty('sub-shadow-offset', '1');
        await _setMpvProperty('sub-shadow-color', '#40000000');
        break;
      case 2:
        await _setMpvProperty('sub-shadow-offset', '2');
        await _setMpvProperty('sub-shadow-color', '#80000000');
        break;
      case 3:
        await _setMpvProperty('sub-shadow-offset', '3');
        await _setMpvProperty('sub-shadow-color', '#C0000000');
        break;
    }
  }

  /// Phase 45 (audit refined, build 63): subtitle background opacity.
  /// [level]: 0=Transparent, 1=Translucent, 2=Opaque. Maps to libmpv's
  /// `sub-back-color` alpha channel.
  Future<void> setSubtitleBackgroundOpacity(int level) async {
    switch (level.clamp(0, 2)) {
      case 0:
        await _setMpvProperty('sub-back-color', '#00000000');
        break;
      case 1:
        await _setMpvProperty('sub-back-color', '#80000000');
        break;
      case 2:
        await _setMpvProperty('sub-back-color', '#FF000000');
        break;
    }
  }

  /// Phase 45 (audit refined, build 63): subtitle bottom margin as
  /// percent of screen height (0..20). libmpv's `sub-margin-y` is in
  /// pixels relative to a 720p reference, so we scale roughly:
  /// percent * 7.2 ≈ y-pixels at 720p.
  Future<void> setSubtitleBottomMargin(int percent) async {
    final clamped = percent.clamp(0, 20);
    final pixels = (clamped * 7.2).round();
    await _setMpvProperty('sub-margin-y', pixels.toString());
  }

  /// Phase 45 (audit refined, build 63): subtitle text colour preset
  /// (0..5). Maps to libmpv's `sub-color` property (ARGB hex). MX
  /// Player V3 ships a 6-colour fixed palette; we mirror it.
  static const _subColorPalette = <String>[
    '#FFFFFFFF', // White (default)
    '#FFFFFF00', // Yellow
    '#FF00FFFF', // Cyan
    '#FF00FF00', // Green
    '#FFFF0000', // Red
    '#FF000000', // Black
  ];

  Future<void> setSubtitleTextColor(int preset) async {
    final hex = _subColorPalette[preset.clamp(0, 5)];
    await _setMpvProperty('sub-color', hex);
  }

  Future<void> setSubtitleBorderColor(int preset) async {
    final hex = _subColorPalette[preset.clamp(0, 5)];
    await _setMpvProperty('sub-border-color', hex);
  }

  /// Subtitle background colour preset. Combined with the user's
  /// chosen opacity ([setSubtitleBackgroundOpacity]) to produce a
  /// proper ARGB. We OR the colour's RGB onto the existing alpha so
  /// both controls compose cleanly.
  Future<void> setSubtitleBackgroundColor(int preset, int opacityLevel) async {
    if (opacityLevel == 0) {
      // Transparent — clear alpha regardless of chosen colour.
      await _setMpvProperty('sub-back-color', '#00000000');
      return;
    }
    final rgb = _subColorPalette[preset.clamp(0, 5)].substring(3); // strip alpha+#
    final alpha = opacityLevel == 1 ? '80' : 'FF';
    await _setMpvProperty('sub-back-color', '#$alpha$rgb');
  }

  /// Subtitle horizontal alignment (0=Left, 1=Center, 2=Right). libmpv
  /// `sub-align-x` accepts the literal strings.
  Future<void> setSubtitleAlignment(int level) async {
    final value = switch (level.clamp(0, 2)) {
      0 => 'left',
      1 => 'center',
      _ => 'right',
    };
    await _setMpvProperty('sub-align-x', value);
  }

  /// Phase 45 (audit refined, build 64): subtitle border style.
  /// [style]: 0=None, 1=Outline, 2=Drop shadow, 3=Raised, 4=Depressed.
  /// Maps to combinations of libmpv `sub-border-size` +
  /// `sub-shadow-offset` + `sub-shadow-color`. Raised/Depressed are
  /// approximated since libmpv lacks true 3D outline modes.
  Future<void> setSubtitleBorderStyle(int style) async {
    switch (style.clamp(0, 4)) {
      case 0: // None
        await _setMpvProperty('sub-border-size', '0');
        await _setMpvProperty('sub-shadow-offset', '0');
        break;
      case 1: // Outline (default)
        await _setMpvProperty('sub-border-size', '2');
        await _setMpvProperty('sub-shadow-offset', '0');
        break;
      case 2: // Drop shadow
        await _setMpvProperty('sub-border-size', '0');
        await _setMpvProperty('sub-shadow-offset', '3');
        break;
      case 3: // Raised — light shadow above-left to simulate "lifted"
        await _setMpvProperty('sub-border-size', '1');
        await _setMpvProperty('sub-shadow-offset', '2');
        await _setMpvProperty('sub-shadow-color', '#80FFFFFF');
        break;
      case 4: // Depressed — dark shadow below-right to simulate "sunken"
        await _setMpvProperty('sub-border-size', '1');
        await _setMpvProperty('sub-shadow-offset', '2');
        await _setMpvProperty('sub-shadow-color', '#A0000000');
        break;
    }
  }

  /// Phase 45 (audit refined, build 64): subtitle font size preset.
  /// [preset]: 0=Tiny (50%), 1=Small (75%), 2=Medium (100%),
  /// 3=Large (125%), 4=Huge (150%). Combined with the user's [scale]
  /// multiplier — base preset × user scale = final size.
  Future<void> setSubtitleFontSize(int preset, double userScale) async {
    const presets = [0.5, 0.75, 1.0, 1.25, 1.5];
    final base = presets[preset.clamp(0, 4)];
    final final_ = base * userScale;
    await _setMpvProperty('sub-scale', final_.toStringAsFixed(2));
  }

  /// Phase 45 (audit refined, build 64): subtitle stroke quality.
  /// When ON, force libmpv to use its high-quality ASS renderer with
  /// `sub-ass-override=force` so border + shadow look crisper. When
  /// OFF, leave the file's own ASS/SSA styling alone (`no`).
  Future<void> setSubtitleImproveStroke(bool enabled) async {
    // AUDIT FIX — the OFF branch used to be 'strip', which does not mean
    // "render more cheaply": it tells libmpv to throw away all ASS/SSA
    // formatting. Signs, karaoke, positioned captions and styled dialogue in
    // anime and Blu-ray rips all collapse to plain centred text. 'no' is the
    // correct neutral value — honour the file's own styling, apply none of
    // ours.
    await _setMpvProperty('sub-ass-override', enabled ? 'force' : 'no');
  }

  /// Settings → Decoder → "Deinterlace".
  ///
  /// Interlaced sources — DVD rips, TV captures, older camcorder footage —
  /// show comb-shaped tearing on horizontal motion without this. libmpv's
  /// `deinterlace` property applies its filter when the stream is flagged
  /// interlaced and costs nothing when it is not, which is why leaving the
  /// switch on is safe even for a library that is mostly progressive.
  Future<void> setDeinterlace(bool enabled) =>
      _setMpvProperty('deinterlace', enabled ? 'yes' : 'no');

  /// Settings → Decoder → "Use speedup tricks".
  ///
  /// Two software-decode shortcuts, both no-ops while hardware decoding is
  /// doing the work: `vd-lavc-fast` allows decoding that is not strictly
  /// spec-compliant but visually equivalent, and skipping the loop filter on
  /// non-keyframes drops the single most expensive step in H.264 decoding.
  /// Together they are the difference between watching and stuttering on a
  /// weak device with an unsupported codec; on a strong one they simply save
  /// battery. Turning the switch off restores strict decoding.
  Future<void> setSpeedupTricks(bool enabled) async {
    await _setMpvProperty('vd-lavc-fast', enabled ? 'yes' : 'no');
    await _setMpvProperty(
        'vd-lavc-skiploopfilter', enabled ? 'nonkey' : 'none');
  }

  /// Settings → Subtitle → "Italic effect". libmpv's own `sub-italic`.
  Future<void> setSubtitleItalic(bool enabled) =>
      _setMpvProperty('sub-italic', enabled ? 'yes' : 'no');

  /// Subtitle bold, using libmpv's own `sub-bold` flag.
  ///
  /// AUDIT FIX — "bold" used to be faked by thickening `sub-border-size`,
  /// which is the exact property `setSubtitleBorderStyle` writes. Whichever
  /// ran last won, so turning bold on silently cancelled the user's chosen
  /// border style (and vice-versa). They are now independent properties and
  /// compose the way the settings screen implies they do.
  Future<void> setSubtitleBold(bool bold) =>
      _setMpvProperty('sub-bold', bold ? 'yes' : 'no');

  /// Tune the network read timeout (seconds). Useful for spotty Wi-Fi.
  Future<void> setNetworkTimeout(int seconds) =>
      _setMpvProperty('network-timeout', seconds.toString());

  /// Set the demuxed-packet cache ceiling in MB. Larger = smoother
  /// playback on long-form files at the cost of memory.
  Future<void> setDemuxerCacheMb(int mb) =>
      _setMpvProperty('demuxer-max-bytes', '${mb * 1024 * 1024}');

  /// Size the whole buffering group coherently for the kind of source we are
  /// about to play.
  ///
  /// BATTERY/HEAT FIX — the old code changed only `demuxer-max-bytes` per file
  /// (150 MB local / 250 MB network) and left the seconds-based limits at
  /// desktop values, so a local film sat behind a read-ahead thread holding
  /// well over a hundred megabytes for no benefit. The two cases genuinely
  /// want opposite things:
  ///
  ///  * LOCAL — storage is far faster than the decoder, so a few seconds of
  ///    read-ahead is all that is ever consumed. Small buffers mean fewer
  ///    storage wake-ups, a much smaller resident heap, and no cache thread
  ///    competing with the decoder for cores.
  ///  * NETWORK — read-ahead IS the feature; it is what absorbs a lift-shaft
  ///    or a congested cell. Keep it generous in SECONDS, but cap the bytes at
  ///    something a phone can hold without the system trimming other apps.
  Future<void> setStreamBufferProfile({required bool network}) async {
    if (network) {
      await _setMpvProperty('cache', 'yes');
      await _setMpvProperty('demuxer-max-bytes', '${96 * 1024 * 1024}');
      await _setMpvProperty('demuxer-max-back-bytes', '${32 * 1024 * 1024}');
      await _setMpvProperty('cache-secs', '30');
      await _setMpvProperty('demuxer-readahead-secs', '20');
    } else {
      await _setMpvProperty('cache', 'auto');
      await _setMpvProperty('demuxer-max-bytes', '${32 * 1024 * 1024}');
      await _setMpvProperty('demuxer-max-back-bytes', '${16 * 1024 * 1024}');
      await _setMpvProperty('cache-secs', '10');
      await _setMpvProperty('demuxer-readahead-secs', '5');
    }
  }

  /// Phase 45 (audit): apply a global audio delay in milliseconds.
  /// Positive values delay audio (helpful when video is ahead);
  /// negative values advance it. libmpv's `audio-delay` property takes
  /// SECONDS so we convert. Range matches MX Player V3 (-2000..+2000 ms).
  Future<void> setAudioDelayMs(int ms) async {
    final clamped = ms.clamp(-2000, 2000);
    await _setMpvProperty(
        'audio-delay', (clamped / 1000.0).toStringAsFixed(3));
  }

  /// Phase 45 (audit): apply a global subtitle delay in milliseconds.
  /// libmpv's `sub-delay` property is also in seconds. Range
  /// (-10000..+10000 ms) matches MX Player V3's
  /// `subtitle_default_sync` setting.
  Future<void> setSubtitleDelayMs(int ms) async {
    final clamped = ms.clamp(-10000, 10000);
    await _setMpvProperty(
        'sub-delay', (clamped / 1000.0).toStringAsFixed(3));
  }

  /// Phase 45 (audit): subtitle encoding override. When empty,
  /// libmpv auto-detects. When set (e.g. 'UTF-8', 'EUC-KR'), libmpv
  /// uses that for all subsequent subtitle loads.
  Future<void> setSubtitleCharset(String charset) async {
    if (charset.isEmpty) {
      await _setMpvProperty('sub-codepage', 'auto');
    } else {
      await _setMpvProperty('sub-codepage', charset);
    }
  }

  /// Phase 45 (audit): preferred audio language ISO code. libmpv's
  /// `alang` property picks the matching audio track on file open.
  /// Empty string clears the preference.
  Future<void> setPreferredAudioLanguage(String code) =>
      _setMpvProperty('alang', code);

  /// Phase 45 (audit): preferred subtitle language. libmpv's `slang`
  /// property auto-selects the matching subtitle.
  Future<void> setPreferredSubtitleLanguage(String code) =>
      _setMpvProperty('slang', code);

  /// Phase 45 (audit): custom HTTP User-Agent for network streams.
  /// libmpv's `user-agent` property is consulted on every HTTP open.
  Future<void> setHttpUserAgent(String userAgent) async {
    if (userAgent.isNotEmpty) {
      await _setMpvProperty('user-agent', userAgent);
    }
  }

  /// Phase 45 (audit refined): override the video aspect ratio. MX
  /// Player V3 exposes 12 explicit ratios (1:1 / 4:3 / 16:9 / etc.)
  /// in addition to the 4 behavior modes (fit/crop/stretch/original).
  /// Passing [aspect] = null restores libmpv's default behavior (use
  /// the file's intrinsic SAR/DAR). Mapped to libmpv's
  /// `video-aspect-override` property which is consulted continuously
  /// during playback so the change takes effect immediately.
  Future<void> setAspectRatioOverride(double? aspect) async {
    if (aspect == null || aspect <= 0) {
      // -1 in libmpv means "use the file's intrinsic aspect ratio"
      await _setMpvProperty('video-aspect-override', '-1');
    } else {
      await _setMpvProperty(
          'video-aspect-override', aspect.toStringAsFixed(4));
    }
  }

  @override
  Future<void> setPanscan(double value) async {
    // libmpv `panscan` (0.0–1.0) zooms the video to progressively fill the
    // window while KEEPING its aspect ratio — 0.0 letterboxes (fit), 1.0
    // fills the screen (zoom, minimal symmetric crop). This is exactly how
    // MX Player's "Fit to Screen"/zoom behaves: a smooth scale, not a hard
    // rectangular crop of the texture. It composes with the pinch-zoom
    // (Flutter Transform.scale) applied on top.
    final v = value.clamp(0.0, 1.0);
    await _setMpvProperty('panscan', v.toStringAsFixed(3));
  }

  /// Boost (or quiet) the audio output gain. Values > 1.0 amplify the
  /// signal beyond 100 %, like MX Player's "audio booster". Hard-capped
  /// at 4× to avoid clipping damage.
  Future<void> setAudioGain(double multiplier) async {
    _volumePct = multiplier.clamp(0.0, 4.0) * 100;
    _fadeGen++; // a gain change wins over any running fade
    final pct = _volumePct.toStringAsFixed(0);
    await _setMpvProperty('volume-max', '400');
    await _setMpvProperty('volume', pct);
  }

  /// Phase 45 (audit refined, build 63): MX Player V3 `audio_device`.
  /// libmpv's `audio-device` property selects the AAudio / OpenSL
  /// output route. Pass an empty / 'auto' string to let libmpv pick.
  /// Android does not let an app choose its output route from here.
  ///
  /// The previous version had an if/else whose two branches did exactly the
  /// same thing — set `audio-device` to 'auto' — which made the setting look
  /// wired up while doing nothing at all. On Android, libmpv's device list is
  /// effectively just the AudioTrack sink; which physical output it reaches
  /// (speaker, wired, Bluetooth) is decided by the system's routing policy and
  /// changes when the user connects or disconnects a device, not when an app
  /// asks. Anything else here would be a lie with extra steps.
  ///
  /// A non-'auto' value is still passed through, so if a future libmpv build
  /// on Android does expose real devices the setting starts working rather
  /// than needing to be rediscovered.
  Future<void> setAudioDevice(String device) async {
    final d = device.trim();
    await _setMpvProperty('audio-device', d.isEmpty ? 'auto' : d);
  }

  /// Phase 45 (audit refined, build 63): MX Player V3
  /// `prefer_audio_passthrough_mode`. When ON, libmpv passes the
  /// Dolby/DTS bitstream untouched to the AV receiver (no PCM
  /// re-encode). Mapped to libmpv's `ad-lavc-ac3drc` / `audio-spdif`
  /// properties. Disable on devices without HDMI/SPDIF or with
  /// internal speakers.
  Future<void> setAudioPassthrough(bool enabled) async {
    if (enabled) {
      // Pass Dolby AC3 + DTS + EAC3 + TrueHD bitstreams.
      await _setMpvProperty('audio-spdif', 'ac3,dts,eac3,truehd');
    } else {
      await _setMpvProperty('audio-spdif', '');
    }
  }

  /// True while the video output is released for background audio.
  ///
  /// (The `@override` that used to sit on this line was a leftover: a private
  /// field cannot override anything, and the annotation belonged to
  /// [setBackgroundAudioMode] below, which really does implement the
  /// [VideoPlayerService] member.)
  bool _videoDetached = false;

  /// Bumped by EVERY detach and EVERY reattach.
  ///
  /// ─── THE RACE THIS EXISTS TO CLOSE (v1.55.16) ─────────────────────────
  ///
  /// Detaching and reattaching the video output are each several awaited
  /// property writes, and nothing used to stop one from running inside the
  /// other. Two reachable orderings, both leaving the app broken until the
  /// next `open()`:
  ///
  ///   1. `Timer.cancel()` does NOT abort a callback that is already running.
  ///      The watchdog checked `_videoDetached` once, at the top, then awaited
  ///      twice. A reattach landing between those awaits was immediately
  ///      undone by the tail of the tick writing `vo=null` — audio in the
  ///      foreground over a black picture.
  ///
  ///   2. Screen off then straight back on. The detach had written `vo=null`
  ///      and was still awaiting; the reattach ran to completion; the detach's
  ///      remaining writes (`force-window=no`, `vid=no`) then landed on top of
  ///      it, and armed a watchdog whose flag had already been cleared.
  ///
  /// A generation counter is the smallest thing that fixes both: every write
  /// that is part of a transition checks that its generation is still the
  /// current one, so a superseded transition abandons itself instead of
  /// finishing on top of the one that replaced it. The `_surfaceOp` chain
  /// then serialises whole transitions so they cannot interleave in the first
  /// place — the counter is what makes the ones already in flight harmless.
  int _surfaceGen = 0;

  /// Serialises whole detach/reattach transitions. Each waits for the previous
  /// to finish rather than racing it.
  Future<void> _surfaceOp = Future<void>.value();

  /// Runs [action] after any surface transition already in flight, and returns
  /// the generation it was given so the body can tell whether it still owns
  /// the surface after each await.
  Future<void> _runSurfaceOp(Future<void> Function(int gen) action) {
    final next = _surfaceOp.then((_) {
      final gen = ++_surfaceGen;
      return action(gen);
    }).catchError((Object e) {
      if (kDebugMode) debugPrint('media_kit_player_service.surface-op: $e');
    });
    // The chain must never end in an error state, or every later transition
    // would be skipped.
    _surfaceOp = next;
    return next;
  }

  /// Re-assert timer for the detach; see [_armDetachWatchdog].
  Timer? _bgReassertTimer;
  int _bgReassertTicks = 0;

  /// Playback position at the moment of the last detach, so the reattach can
  /// report whether anything actually played while the screen was off.
  Duration _detachPosition = Duration.zero;

  /// The `vo` that was in force before the last detach, so the reattach can
  /// put back exactly what was there rather than a guess.
  ///
  /// ─── ROOT CAUSE, FOUND AT THE FOURTH ATTEMPT (v1.52) ───────────────────
  ///
  /// Background play died the moment the screen went off. Three fixes aimed
  /// at `vid` (v0.97, v1.45, v1.51) and none of them worked, because `vid`
  /// was never the property that could fix it.
  ///
  /// On Android, media_kit does NOT use libmpv's render API. It hands libmpv
  /// a raw `android.view.Surface` through `--wid`, taken from a Flutter
  /// texture entry, and renders with `--vo=gpu --gpu-context=android`. The
  /// consumer of that surface is Flutter's raster thread. Screen-off stops
  /// that thread, nothing drains the buffer queue any more, it fills in a
  /// frame or three, and mpv blocks in `eglSwapBuffers` — which stalls the
  /// core, which stops refilling the audio ring, which is the second or two
  /// of sound you hear before silence.
  ///
  /// The part that defeated every previous attempt: **AndroidVideoController
  /// sets `force-window: 'yes'` when it creates the controller.** With
  /// force-window on, mpv keeps the video output alive even with no video
  /// track selected — so `vid=no` deselected the track and left the VO
  /// exactly where it was, still holding the surface, still swapping buffers,
  /// still blocking. The medicine was real; it was aimed at the wrong organ.
  ///
  /// `vo` is what owns the surface, and writing it is media_kit's own way of
  /// letting go: `AndroidVideoController.widListener` sets `vo=null` first on
  /// every single surface change, and its own comment says `vo=null` is
  /// REQUIRED when the surface pointer is gone. So this is the sanctioned
  /// path on this stack, not a workaround — and the v1.45 note that avoided
  /// `vo=null` on the strength of mpv-android #1076 was reading advice for a
  /// different architecture (mpv-android drives the surface itself with
  /// attachSurface/detachSurface and `vo=mediacodec_embed`).
  ///
  /// Restoring re-seeks, because media_kit re-seeks after every VO re-init
  /// too — without it the picture can sit black until the next keyframe.
  ///
  /// FOLLOW-UP WORTH DOING: media_kit_video 1.3.0 migrated Android from
  /// SurfaceTextureEntry to Flutter's SurfaceProducer, whose `onSurfaceCleanup`
  /// fires when the app is backgrounded — so on 1.3.0+ the library releases
  /// the output by itself and none of this would be needed. This app is
  /// pinned to ^1.2.4, which predates that migration and therefore never
  /// learns that the surface stopped being drained. Upgrading is the real
  /// cure; this is the fix that does not require one.
  String? _voForRestore;

  /// Keep the detach detached through the engine's own start-up writes.
  ///
  /// COLD-START RACE (v1.55) — reported symptom: open the app, go straight
  /// into a folder, start a video while the folder is still scanning, turn the
  /// screen off, and background audio dies. Wait a moment first and it is
  /// fine, and every later video is fine.
  ///
  /// That shape is an initialisation race, and here is the mechanism.
  /// `AndroidVideoController.create()` writes its own batch —
  /// `force-window: 'yes'`, `vid: 'auto'`, `vo`, and the rest — and the
  /// library re-writes `vo` again from `widListener` on the first surface and
  /// size it is given. None of that is awaited by anything on our side. Worse,
  /// media_kit's own writes pass `waitForInitialization: false` while ours
  /// take the default `true`, so during start-up the library's writes
  /// overtake ours by design. A detach that lands in that window is simply
  /// overwritten a moment later, and the output is rebuilt against a surface
  /// nobody is draining — the original stall, from a different direction.
  ///
  /// Once the engine has settled there is nothing left to overwrite it, which
  /// is exactly why a few seconds of patience "fixed" it and why the second
  /// video was never affected.
  ///
  /// So the detach re-states itself for a few seconds instead of assuming it
  /// won. Both writes are idempotent — setting a property to the value it
  /// already holds does not reinitialise anything in mpv — so the cost is a
  /// couple of dozen cheap FFI calls, only ever while backgrounded, and the
  /// whole thing stops the instant the picture is wanted again.
  /// [gen] is the generation of the detach that armed this watchdog. Every
  /// write re-checks it, because `timer.cancel()` cannot abort a tick that is
  /// already part-way through its awaits — and such a tick writing `vo=null`
  /// after a reattach has restored the output is exactly the foreground black
  /// screen this whole subsystem exists to avoid.
  void _armDetachWatchdog(int gen) {
    _bgReassertTimer?.cancel();
    _bgReassertTicks = 0;
    _bgReassertTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (timer) async {
        if (!_videoDetached || gen != _surfaceGen) {
          timer.cancel();
          if (_bgReassertTimer == timer) _bgReassertTimer = null;
          return;
        }
        _bgReassertTicks++;
        await _setMpvProperty('force-window', 'no');
        // RE-CHECK BETWEEN THE WRITES. The await above is a real suspension
        // point: a reattach can run to completion inside it, and without this
        // line the next statement would undo it.
        if (!_videoDetached || gen != _surfaceGen) {
          timer.cancel();
          if (_bgReassertTimer == timer) _bgReassertTimer = null;
          return;
        }
        await _setMpvProperty('vo', 'null');
        // ~5 s of cover. Long enough for a cold start on a phone that is also
        // scanning a folder; short enough to be free for the rest of the film.
        if (_bgReassertTicks >= 20) {
          timer.cancel();
          if (_bgReassertTimer == timer) _bgReassertTimer = null;
          PlaybackLog.add('watchdog done x$_bgReassertTicks '
              'pos=${_position.inSeconds}s');
        }
      },
    );
  }

  /// Put the video output back. Split out because [open] needs the reattach
  /// WITHOUT the resync seek (it is about to load a file and seek anyway),
  /// while a return to the foreground needs the seek to get a frame on screen.
  Future<void> _reattachVideo({required bool seekToResync}) {
    return _runSurfaceOp((gen) => _reattachVideoLocked(gen, seekToResync));
  }

  Future<void> _reattachVideoLocked(int gen, bool seekToResync) async {
    if (!_videoDetached) return;
    _videoDetached = false;
    _bgReassertTimer?.cancel();
    _bgReassertTimer = null;
    // The one number that settles what actually happened while we were away:
    // if the position did not move, playback was stalled or frozen; if it
    // moved with the clock, the audio path was alive and something else took
    // the sound. Guessing between those three has cost four releases.
    final advanced = (_position - _detachPosition).inSeconds;
    PlaybackLog.add('reattach pos=${_position.inSeconds}s advanced=${advanced}s');
    // Reverse order of the detach: standing orders, then track, then output.
    await _setMpvProperty('force-window', 'yes');
    if (gen != _surfaceGen) return;
    await _setMpvProperty('vid', 'auto');
    if (gen != _surfaceGen) return;
    // SAFETY GATE — do not hand a video output to a surface that is not there.
    //
    // media_kit's own comment is blunt about this: "When --wid is 0, vo=null
    // is required to avoid SIGSEGV." On media_kit_video 1.3.0+ the library
    // pushes `wid=0` itself the moment Flutter reports the surface cleaned up
    // (the SurfaceProducer migration), so a blind `vo=gpu` here could land
    // while the pointer is still zero and take the whole app down. Asking
    // first costs one round trip on a path that is not time-critical, and it
    // makes this method correct on BOTH library versions: on 1.2.x `wid`
    // never goes to zero while backgrounded and the restore proceeds, and on
    // 1.3.0+ we simply stand aside and let widListener restore `vo` when the
    // surface really does come back.
    final wid = await _getMpvProperty('wid');
    if (gen != _surfaceGen) return;
    if (wid == null || wid != '0') {
      await _setMpvProperty('vo', _voForRestore ?? 'gpu');
    }
    if (!seekToResync || gen != _surfaceGen) return;
    try {
      await _player.seek(_position);
    } catch (_) {
      // A resync seek is a nicety; never let it take the reattach down.
    }
  }

  /// Harmless preparation, safe to call while the user is still watching.
  ///
  /// Kept separate from [setBackgroundAudioMode] on purpose: enabling the
  /// background-play toggle must NOT detach the video, or the picture would
  /// vanish the moment someone flips the switch mid-film. Only an actual
  /// transition to the background detaches.
  Future<void> prepareBackgroundAudio() async {
    await _setMpvProperty('stop-playback-on-init-failure', 'no');
    await _setMpvProperty('idle', 'yes');
    // Remember which video output is in force so [setBackgroundAudioMode] can
    // put back exactly what was there. Read HERE — this method is pre-armed
    // when the user flips the background-play toggle, so the round trip is
    // paid at a calm moment instead of during the screen-off race. `??=`
    // keeps it to one read for the life of the player.
    _voForRestore ??= await _getMpvProperty('vo');
    // NOTE: deliberately not touching `audio-wait-open`. libmpv treats it as a
    // floating-point ratio, so a boolean-like 'no' is rejected and surfaces as
    // "Playback failed" to the user.
  }

  /// Detach or reattach the video track for background audio playback.
  ///
  /// BUG FIX — background play stopped when the screen turned off, while the
  /// same setup kept playing inside the pop-up window. That difference is the
  /// whole explanation: the pop-up keeps a live surface, and screen-off
  /// destroys it. A player still bound to a video surface stalls when the
  /// surface goes, and the couple of seconds of audio heard afterwards is just
  /// the hardware audio buffer draining. A partial WakeLock cannot help,
  /// because nothing is waiting on the CPU.
  ///
  /// The previous code chose not to deselect the video track so that returning
  /// to the foreground would show a frame instantly. That trade is upside
  /// down: it bought a fraction of a second on return by giving up background
  /// audio entirely.
  ///
  /// `vid=no` and not `vo=null`: mpv-android #1076 documents `vo=null` putting
  /// MediaCodec into a deadloop on Android 14/15 that hangs the app on return.
  /// Deselecting the track shuts the decoder down cleanly instead of leaving
  /// it waiting on a surface that is never coming back. mpv reinitialises the
  /// video chain and re-syncs to the audio clock when the track is selected
  /// again, so the picture returns at the right place by itself.
  @override
  Future<void> setBackgroundAudioMode(bool enabled) async {
    if (!enabled) {
      await _reattachVideo(seekToResync: true);
      return;
    }
    await _runSurfaceOp(_detachVideoLocked);
  }

  Future<void> _detachVideoLocked(int gen) async {
    try {
      if (_videoDetached) return;
      _videoDetached = true;
      _detachPosition = _position;
      // THE load-bearing write. `vo` — not `vid`. See the long note above
      // [_voForRestore] for why the first three attempts at this bug failed.
      final okVo = await _setMpvProperty('vo', 'null');
      // EVERY step re-checks the generation. A reattach that arrives while
      // this one is mid-flight (screen off, then straight back on) takes
      // ownership of the surface, and the rest of this detach must abandon
      // itself rather than write `force-window=no` / `vid=no` on top of the
      // restore — which left the app playing sound with no picture until the
      // next `open()`.
      if (gen != _surfaceGen) return;
      // AND THE HALF v1.52 LEFT ON THE TABLE.
      //
      // Finding that media_kit sets `force-window: 'yes'` was the right
      // finding, and then only half of it got used: `vo` was released while
      // force-window stayed on. That leaves mpv under standing orders to
      // have a window — so the instant ANYTHING re-asserts `vo`, the output
      // is rebuilt against a surface nobody is draining and the stall comes
      // straight back. And something does re-assert it:
      // `AndroidVideoController.widListener` writes `vo` on every surface or
      // size change, which is exactly the kind of event a backgrounding
      // relayout produces.
      //
      // With force-window off AND no video track selected, mpv has no
      // grounds to build a window at all, so a stray `vo=gpu` from the
      // library becomes harmless instead of fatal. This is the property that
      // makes the detach STAY detached.
      final okFw = await _setMpvProperty('force-window', 'no');
      if (gen != _surfaceGen) return;
      final okVid = await _setMpvProperty('vid', 'no');
      if (gen != _surfaceGen) return;
      await prepareBackgroundAudio();
      if (gen != _surfaceGen) return;
      PlaybackLog.add('detach vo=$okVo fw=$okFw vid=$okVid '
          'pos=${_detachPosition.inSeconds}s');
      _armDetachWatchdog(gen);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('media_kit_player_service.bg-audio: $e');
      }
    }
  }

  // === UI ===
  @override
  Widget buildVideoWidget({BoxFit fit = BoxFit.contain}) {
    // Guard the late-final controller: if a surface (e.g. the floating PiP
    // overlay, which lives on every tab) rebuilds before initialize() has
    // assigned `_videoController`, touching it would throw a
    // LateInitializationError mid-build — which trips the global
    // ErrorWidget and blanks the whole screen until an app restart. Show a
    // neutral black placeholder until the controller is ready instead.
    if (!_initialized) {
      return const ColoredBox(color: Color(0xFF000000));
    }
    return mkv.Video(
      controller: _videoController,
      fit: fit,
      controls: mkv.NoVideoControls,
    );
  }

  // === Defensive type converters ===
  // media_kit Track properties may be int OR String depending on version.
  // These helpers safely handle either case.
  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    if (v is double) return v.toInt();
    return null;
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  // === Mappers ===
  AudioTrackInfo _mapAudio(mk.AudioTrack t) => AudioTrackInfo(
        id: t.id,
        title: t.title,
        language: t.language,
        codec: t.codec,
        channels: _toInt(t.channels),
      );

  SubtitleTrackInfo _mapSubtitle(mk.SubtitleTrack t) => SubtitleTrackInfo(
        id: t.id,
        title: t.title,
        language: t.language,
        isExternal: t.id.startsWith('external'),
      );

  VideoTrackInfo _mapVideo(mk.VideoTrack t) => VideoTrackInfo(
        id: t.id,
        width: _toInt(t.w),
        height: _toInt(t.h),
        frameRate: _toDouble(t.fps),
        bitrate: _toInt(t.bitrate),
        codec: t.codec,
      );
}
