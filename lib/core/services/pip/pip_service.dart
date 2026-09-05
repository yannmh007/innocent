import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for Android system Picture-in-Picture.
///
/// Phase 45 — this wraps the `mx_clone/pip` MethodChannel exposed by
/// MainActivity.kt. It is *separate* from the in-app floating overlay
/// ([FloatingPipNotifier]); that overlay only works while the app is in
/// the foreground. Real Android PiP keeps playback alive when the user
/// goes back to the launcher or another app, which is the experience
/// MX Player users expect from "Background/PIP mode".
///
/// Notes:
/// - Requires API 26+ (`Build.VERSION_CODES.O`).
/// - Activity needs `android:supportsPictureInPicture="true"`
///   (already set in our manifest).
/// - libmpv via media_kit keeps decoding while the activity is in PiP,
///   so no special `MediaSession` is required for video playback.
class PipService {
  static const _channel = MethodChannel('mx_clone/pip');

  /// Listener for system PiP mode changes. Set this before calling
  /// [enterPip] so the player can react to mode transitions (hide
  /// controls when entering PiP, restore them when leaving).
  ValueChanged<bool>? onPipModeChanged;

  /// Listener for the Android `onUserLeaveHint` callback — fired
  /// right before the activity goes to background because the user
  /// pressed Home / swiped up. Returning `true` from the registered
  /// handler triggers a PiP entry automatically.
  VoidCallback? onUserLeaveHint;

  PipService() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPipModeChanged':
          final inPip = call.arguments?['inPip'] == true;
          onPipModeChanged?.call(inPip);
          break;
        case 'onUserLeaveHint':
          onUserLeaveHint?.call();
          break;
        case 'onPipPlayPause':
          onPipPlayPause?.call();
          break;
        case 'onPipClosed':
          onPipClosed?.call();
          break;
      }
    });
  }

  /// Returns whether the running device + OS supports PiP.
  Future<bool> isSupported() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isPipSupported');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Whether the user has granted the special "Picture-in-picture" permission.
  /// It's ON by default on stock Android but some OEMs ship it OFF (and it can
  /// be revoked), in which case entering system PiP silently does nothing.
  /// Defaults to true on any failure so we never wrongly block the feature.
  Future<bool> isPipAllowed() async {
    try {
      final ok = await _channel.invokeMethod<bool>('isPipAllowed');
      return ok ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Open the system settings page where the user can enable Picture-in-picture
  /// for Innocent (falls back to the app-info screen).
  Future<void> openPipSettings() async {
    try {
      await _channel.invokeMethod('openPipSettings');
    } catch (_) {}
  }

  /// Arm/disarm Android 12+ system auto-enter PiP. Armed while the in-app
  /// floating window is live (so leaving the app hands off to system PiP over
  /// other apps even if the manual onUserLeaveHint path is too late), disarmed
  /// when it closes. No-op below Android 12.
  Future<void> setAutoEnterPip(bool enable, {int width = 16, int height = 9}) async {
    try {
      await _channel.invokeMethod('setAutoEnterPip', {
        'enable': enable,
        'width': width.clamp(1, 9999),
        'height': height.clamp(1, 9999),
      });
    } catch (_) {}
  }

  /// Attempt to enter PiP with the given video aspect (width:height).
  /// Returns true on success. Falls back gracefully to false on
  /// devices that lack PiP support or revoke it (e.g. Android Go).
  /// Fired when the user taps the play/pause control INSIDE the PiP window.
  /// The player should toggle playback and then call [setPipPlaying] so the
  /// little control's icon updates.
  VoidCallback? onPipPlayPause;

  /// Fired when the user DISMISSES the system PiP window with × (as opposed to
  /// expanding it back into the app). Playback should fully stop and the
  /// floating window should tear down.
  VoidCallback? onPipClosed;

  Future<bool> enterPip({
    int width = 16,
    int height = 9,
    bool isPlaying = true,
    Rect? sourceRect,
  }) async {
    try {
      final args = <String, dynamic>{
        'width': width.clamp(1, 9999),
        'height': height.clamp(1, 9999),
        'isPlaying': isPlaying,
      };
      if (sourceRect != null) {
        args['left'] = sourceRect.left.round();
        args['top'] = sourceRect.top.round();
        args['right'] = sourceRect.right.round();
        args['bottom'] = sourceRect.bottom.round();
      }
      final ok = await _channel.invokeMethod<bool>('enterPip', args);
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Keep the PiP window's play/pause action icon in sync with real state.
  /// Safe to call even when not in PiP (native side no-ops).
  Future<void> setPipPlaying(bool isPlaying) async {
    try {
      await _channel.invokeMethod('setPipPlaying', {'isPlaying': isPlaying});
    } catch (_) {}
  }
}
