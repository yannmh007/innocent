import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Phase 45: lightweight wrapper around the Android foreground service
/// that keeps audio playback alive when the app is in background or
/// the screen is off.
///
/// The native `PlaybackService.kt` shows a low-priority ongoing
/// notification ("Playing in background") that prevents the system
/// from killing our process or throttling libmpv's audio thread.
///
/// Usage:
/// - Call [start] when the user toggles the headphone (background-play)
///   icon ON.
/// - Call [stop] when the user toggles it OFF, leaves the player, or
///   the video finishes.
class BackgroundPlaybackService {
  static const _channel = MethodChannel('mx_clone/playback');

  BackgroundPlaybackService() {
    if (!_isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onScreenOff':
          onScreenOff?.call();
          break;
        case 'onScreenOn':
          onScreenOn?.call();
          break;
        case 'onPlaybackAction':
          final action = call.arguments is Map
              ? call.arguments['action']?.toString()
              : null;
          final pos = call.arguments is Map
              ? (call.arguments['positionMs'] as num?)?.toInt() ?? -1
              : -1;
          if (action != null) onPlaybackAction?.call(action, pos);
          break;
      }
      return null;
    });
  }

  /// The display just went off.
  ///
  /// v1.51 — this is the signal the background-play fix is built on.
  /// `AppLifecycleState.inactive` cannot tell a screen-off from a pulled
  /// notification shade, so the player used to wait 1.2 s before deciding —
  /// and by then libmpv has already filled the video buffer queue that
  /// nothing is draining any more and blocked inside it. Android's own
  /// ACTION_SCREEN_OFF arrives immediately and means exactly one thing, so
  /// the video track can be released before the queue can fill at all.
  VoidCallback? onScreenOff;

  /// The display came back on (or the user unlocked). Informational: the
  /// picture is restored on the `resumed` lifecycle callback, not here,
  /// because the screen can be on while the app is still behind the keyguard.
  VoidCallback? onScreenOn;

  /// A transport button on the ongoing notification was tapped.
  /// Values: `play_pause`, `stop`.
  /// `(action, positionMs)`. `positionMs` is -1 for everything except a
  /// MediaSession seek, which is the only command that carries a target.
  void Function(String action, int positionMs)? onPlaybackAction;

  /// Is the display on right now?
  ///
  /// Used to disambiguate `AppLifecycleState.inactive`. Defaults to `true` on
  /// any failure, which preserves the old conservative behaviour (wait and
  /// see) rather than blanking the picture on someone who is still watching.
  Future<bool> isInteractive() async {
    if (!_isAndroid) return true;
    try {
      final on = await _channel.invokeMethod<bool>('isInteractive');
      return on ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Refresh the ongoing notification's title and play/pause button without
  /// restarting the service or re-taking its WakeLock.
  Future<void> update({
    required String title,
    required bool isPlaying,
    Duration? position,
    Duration? duration,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod<bool>(
        'update',
        {
          'title': title,
          'isPlaying': isPlaying,
          // -1 means "unchanged" on the native side, so a caller that does not
          // know the progress cannot blank out what the session already shows.
          'positionMs': position?.inMilliseconds ?? -1,
          'durationMs': duration?.inMilliseconds ?? -1,
        },
      );
    } catch (_) {
      // Service not running — nothing to update.
    }
  }

  /// Start the foreground service. The notification title shows
  /// the current video so the user can identify what's playing.
  /// Returns true on success.
  Future<bool> start({
    String title = 'Innocent',
    Duration? position,
    Duration? duration,
  }) async {
    if (!_isAndroid) return false;
    try {
      final ok =
          await _channel.invokeMethod<bool>('start', {
        'title': title,
        'positionMs': position?.inMilliseconds ?? -1,
        'durationMs': duration?.inMilliseconds ?? -1,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stop the foreground service. Idempotent — safe to call when
  /// the service is not running.
  Future<bool> stop() async {
    if (!_isAndroid) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('stop');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
}
