import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../../../core/services/video_player/media_kit_player_service.dart'
    show EqualizerSessionBinder;

/// Phase 32: Audio playback service for music.
/// Backed by media_kit (libmpv) — the same engine used for video,
/// so a single libmpv install supports both video & audio in Innocent.
class MusicAudioService {
  /// Audit fix (real-bug repro: Music tab blank on mount): `_player`
  /// used to be `late final` initialized lazily inside `_ensureInit()`,
  /// only the first time a call site invoked `open()`/`play()`. But
  /// the `MusicPlayingNotifier` constructor subscribes to
  /// `positionStream`/`durationStream`/etc. *immediately* on creation
  /// — long before the user has tapped a song. Those getters reach
  /// into `_player.stream.X`, which threw `LateInitializationError`
  /// and silently aborted the whole Music tab (Tracks list never
  /// rendered). Initialising eagerly keeps lifetime tied to the
  /// service's lifetime — disposed via Riverpod's `ref.onDispose`
  /// in `musicAudioServiceProvider`.
  final Player _player = Player(
    configuration: const PlayerConfiguration(
      // BATTERY/RAM FIX — was 32 MB, which at a typical music bitrate is over
      // ten minutes of audio held in RAM at all times. This player instance is
      // built at app start, before the user has opened the Music tab, so that
      // ceiling applied to every session whether or not a song ever played.
      // 8 MB still covers several minutes of MP3 and a comfortable stretch of
      // lossless, which is far more than a local file or a LAN share needs.
      bufferSize: 8 * 1024 * 1024,
      title: 'Innocent Music',
    ),
  );
  bool _initialized = true;

  // Audit fix (M3): expose libmpv's error stream so the music
  // controller can surface playback failures to the UI. Without this
  // every failure ended up silently caught in `_playAt`, leaving
  // the user staring at a "selected, not playing" state with no
  // explanation. Backed by a broadcast controller so multiple
  // subscribers (controller + a future logger) can listen.
  final StreamController<String> _errorCtrl =
      StreamController<String>.broadcast();
  Stream<String> get errorStream => _errorCtrl.stream;
  StreamSubscription? _errorSub;

  Stream<Duration> get positionStream => _player.stream.position;
  Stream<Duration> get durationStream => _player.stream.duration;
  Stream<bool> get playingStream => _player.stream.playing;
  Stream<bool> get completedStream => _player.stream.completed;

  Duration get position => _player.state.position;
  Duration get duration => _player.state.duration;
  bool get isPlaying => _player.state.playing;
  bool get isInitialized => _initialized;

  /// Subscribe to libmpv error events on construction. Eager init
  /// means error stream is hooked from the start, so even failed
  /// `open()` calls surface in `errorStream`.
  MusicAudioService() {
    _errorSub = _player.stream.error.listen(
      (e) => _errorCtrl.add(e),
      onError: (_) {},
    );
    // Fire-and-forget audio tuning. Non-throwing and applied as soon as
    // the libmpv handle is ready, so it never delays the first open().
    // Local files barely touch the cache, but it costs nothing and keeps
    // network/SMB music glitch-free; hr-seek=absolute keeps scrub-bar
    // landings exact while ±skip stays instant (keyframe).
    // ignore: discarded_futures
    _applyAudioBaseline();
  }

  Future<void> _applyAudioBaseline() async {
    // BATTERY FIX — was 'yes', which forces the read-ahead cache on for local
    // files too. mpv's default 'auto' caches network and SMB sources (where it
    // genuinely prevents drop-outs) and leaves local files alone, which is
    // right: a local track is read far faster than it is decoded, so a cache
    // thread on top of it only adds storage wake-ups.
    await _setProp('cache', 'auto');
    await _setProp('cache-secs', '20');
    await _setProp('demuxer-readahead-secs', '5');
    await _setProp('hr-seek', 'absolute');
    // Bind libmpv's AudioTrack output to the shared audio-session id — the same
    // one the Equalizer / BassBoost / Virtualizer attach to natively — so audio
    // effects actually process music playback (session 0 / the global mix is
    // ignored by modern Android for app-owned AudioTracks). Must be set before
    // the AO is created, i.e. before the first open(); this runs at
    // construction. Best-effort.
    await _bindAudioSession();
  }

  Future<void> _bindAudioSession() async {
    try {
      final sid = await EqualizerSessionBinder.sessionIdProvider?.call();
      if (sid == null || sid == 0) return;
      await _setProp('ao', 'audiotrack');
      await _setProp('audiotrack-session-id', '$sid');
    } catch (_) {
      // No session / libmpv ignores the option — music still plays, just
      // without a guaranteed EQ session.
    }
  }

  Future<void> _setProp(String key, String value) async {
    try {
      await (_player.platform as dynamic)?.setProperty(key, value);
    } catch (_) {
      // libmpv handle not ready / unknown property — safe to ignore.
    }
  }

  /// Retained as a no-op for compatibility with existing call sites
  /// (open / play / pause / seek). Eager construction means it never
  /// needs to do work.
  void _ensureInit() {}

  Future<void> open(String uri) async {
    _ensureInit();
    await _player.open(Media(uri));
  }

  Future<void> play() async {
    _ensureInit();
    await _player.play();
  }

  Future<void> pause() async {
    if (!_initialized) return;
    await _player.pause();
  }

  Future<void> playOrPause() async {
    _ensureInit();
    await _player.playOrPause();
  }

  Future<void> seek(Duration to) async {
    if (!_initialized) return;
    // Audit fix (M1 reinforce): clamp at the boundary too, defence
    // in depth — controller already clamps but this stops a future
    // caller from sneaking in a negative or past-end value.
    final dur = duration;
    final clamped = to < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && to > dur ? dur : to);
    await _player.seek(clamped);
  }

  Future<void> setVolume(double volume) async {
    _ensureInit();
    // media_kit takes 0-100
    await _player.setVolume((volume.clamp(0.0, 1.0)) * 100);
  }

  Future<void> setRate(double rate) async {
    _ensureInit();
    await _player.setRate(rate);
  }

  /// Phase 45: full stop — pauses AND drops the loaded media. Needed
  /// so that when the user switches off music entirely we release
  /// libmpv's resources, not just pause the playhead.
  Future<void> stop() async {
    if (!_initialized) return;
    await _player.stop();
  }

  Future<void> dispose() async {
    // Audit hygiene: cancel error sub + close broadcast controller
    // BEFORE disposing the player.
    await _errorSub?.cancel();
    _errorSub = null;
    await _errorCtrl.close();
    if (_initialized) {
      await _player.dispose();
      _initialized = false;
    }
  }
}
