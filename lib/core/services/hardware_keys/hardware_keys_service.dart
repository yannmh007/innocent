import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Media key actions sent from Android headset / Bluetooth media keys.
/// Volume keys are NOT intercepted - they always control system volume.
enum MediaKeyAction {
  playPause,
  play,
  pause,
  next,
  previous,
  forward,
  rewind,
  /// Phase 45: Android ACTION_AUDIO_BECOMING_NOISY — fired when the user
  /// unplugs headphones or disconnects a Bluetooth headset. Powerful
  /// video players pause on this signal so audio doesn't suddenly come
  /// out the loudspeaker.
  headphonesDisconnected,
}

/// Service for Bluetooth / headset media-button events when player is foregrounded.
class HardwareKeysService {
  static const _channel = MethodChannel('mx_clone/keys');

  void Function(MediaKeyAction action)? _onMediaKey;

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  HardwareKeysService() {
    if (_isAndroid) {
      _channel.setMethodCallHandler(_dispatch);
    }
  }

  Future<dynamic> _dispatch(MethodCall call) async {
    if (call.method == 'onMediaKey') {
      final action = call.arguments['action'] as String? ?? '';
      final mapped = _parseAction(action);
      if (mapped != null) _onMediaKey?.call(mapped);
    }
    return null;
  }

  MediaKeyAction? _parseAction(String s) {
    switch (s) {
      case 'playPause':
        return MediaKeyAction.playPause;
      case 'play':
        return MediaKeyAction.play;
      case 'pause':
        return MediaKeyAction.pause;
      case 'next':
        return MediaKeyAction.next;
      case 'previous':
        return MediaKeyAction.previous;
      case 'forward':
        return MediaKeyAction.forward;
      case 'rewind':
        return MediaKeyAction.rewind;
      case 'headphonesDisconnected':
        return MediaKeyAction.headphonesDisconnected;
      default:
        return null;
    }
  }

  /// Enable media key capture (Bluetooth / headset)
  Future<void> enable({
    void Function(MediaKeyAction action)? onMediaKey,
  }) async {
    _onMediaKey = onMediaKey;
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setCaptureVolumeKeys', {'capture': true});
    } catch (e) { if (kDebugMode) debugPrint('hardware_keys_service.best-effort: $e'); }
  }

  /// Disable media key capture
  Future<void> disable() async {
    _onMediaKey = null;
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setCaptureVolumeKeys', {'capture': false});
    } catch (e) { if (kDebugMode) debugPrint('hardware_keys_service.best-effort: $e'); }
  }
}
