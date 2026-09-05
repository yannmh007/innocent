import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Thin Dart wrapper over the native `TransferService` foreground service
/// (MethodChannel `mx_clone/transfer_service`).
///
/// The native service keeps the app's process alive while a Wi-Fi transfer
/// runs in the background and shows a progress notification. Every call is
/// wrapped in try/catch on purpose: if the platform side fails (notification
/// permission denied, OS background-start limit, non-Android platform), the
/// transfer must still proceed in the foreground — the service is an
/// enhancement, never a dependency.
class TransferForegroundService {
  TransferForegroundService._();

  static const MethodChannel _channel =
      MethodChannel('mx_clone/transfer_service');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Start the foreground service + notification. [progress] is 0..100, or
  /// negative for an indeterminate bar.
  static Future<void> start({
    required String title,
    String text = '',
    int progress = -1,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('start', {
        'title': title,
        'text': text,
        'progress': progress,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('TransferForegroundService.start: $e');
    }
  }

  /// Update the notification's text + progress while the service runs.
  static Future<void> update({
    String title = 'Transferring files',
    String text = '',
    int progress = -1,
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'text': text,
        'progress': progress,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('TransferForegroundService.update: $e');
    }
  }

  /// Post a one-off, dismissible "done" notification.
  ///
  /// The ongoing notification vanishes with the foreground service, so without
  /// this a user who left the app during a long transfer gets no signal that
  /// it finished — they come back and guess. Separate notification id so it
  /// does not fight with the progress one.
  static Future<void> notifyDone({
    required String title,
    String text = '',
  }) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('notifyDone', {
        'title': title,
        'text': text,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('TransferForegroundService.notifyDone: $e');
    }
  }

  /// Stop the foreground service + remove the notification.
  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod('stop');
    } catch (e) {
      if (kDebugMode) debugPrint('TransferForegroundService.stop: $e');
    }
  }
}
