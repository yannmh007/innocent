import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Reasons the system tells us we're losing or gaining audio focus.
enum AudioFocusEvent {
  /// We just got focus back (e.g. phone call ended).
  gain,

  /// We lost focus permanently. Drop everything cleanly.
  loss,

  /// Short interruption (notification, navigation prompt). Pause but
  /// remember the state so we can resume on `gain`.
  lossTransient,

  /// Short interruption where the system wants us to LOWER volume
  /// instead of pausing (e.g. a navigation voice prompt). MX Player's
  /// behavior is to keep playing at full volume — many users complain
  /// about ducking, so we ignore this by default.
  lossTransientCanDuck,
}

/// Phase 45: Android audio focus management.
///
/// On Android, when another app starts playing audio (phone call,
/// notification, navigation prompt, another video app), the system
/// notifies us via `AudioManager.OnAudioFocusChangeListener`. Without
/// handling this, our app keeps playing audio over the phone call,
/// which is unacceptable.
///
/// Powerful video players (MX Player, VLC, Just Player) all integrate
/// with this system. This service wraps the `mx_clone/audio_focus`
/// MethodChannel exposed by MainActivity.kt.
///
/// Multiple consumers (PlayerController, MusicPlayingNotifier) can
/// subscribe to focus events simultaneously via the [events] broadcast
/// stream. Each one decides whether to act based on its own state.
class AudioFocusService {
  static const _channel = MethodChannel('mx_clone/audio_focus');

  final StreamController<AudioFocusEvent> _controller =
      StreamController<AudioFocusEvent>.broadcast();

  /// Broadcast stream of focus events. Both video and music subscribers
  /// listen — each filters by their own playback state.
  Stream<AudioFocusEvent> get events => _controller.stream;

  /// Track outstanding focus claims. We only request once (on first
  /// `request()` call) and only abandon when ALL claimants release.
  int _claims = 0;

  AudioFocusService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onFocusChange') return;
      final action = call.arguments?['action'];
      AudioFocusEvent? event;
      switch (action) {
        case 'gain':
          event = AudioFocusEvent.gain;
          break;
        case 'loss':
          event = AudioFocusEvent.loss;
          break;
        case 'lossTransient':
          event = AudioFocusEvent.lossTransient;
          break;
        case 'lossTransientCanDuck':
          event = AudioFocusEvent.lossTransientCanDuck;
          break;
      }
      if (event != null && !_controller.isClosed) {
        _controller.add(event);
      }
    });
  }

  /// Request audio focus for media playback. Returns true on success.
  /// Idempotent across multiple claimants — only the first call
  /// actually makes the system request.
  Future<bool> request() async {
    _claims++;
    if (!_isAndroid) return true;
    if (_claims > 1) return true; // Already requested.
    try {
      final granted = await _channel.invokeMethod<bool>('request');
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Release this claim. When ALL claimants have released, the system
  /// focus is actually abandoned. Calling abandon without a matching
  /// request is harmless.
  Future<void> abandon() async {
    if (_claims > 0) _claims--;
    if (_claims > 0) return;
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('abandon');
    } catch (e) { if (kDebugMode) debugPrint('audio_focus_service.best-effort: $e'); }
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;

  void dispose() {
    _controller.close();
  }
}
