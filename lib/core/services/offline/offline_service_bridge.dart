import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Tells Android that a "watch offline" download is in progress.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE BUG THIS CLOSES, WHICH WAS THE WHOLE FEATURE
/// ═══════════════════════════════════════════════════════════════════════
///
/// Most viewers of this app are on Myanmar mobile data, and on a connection
/// that cannot stream a film without stopping the thing people do — here and
/// everywhere else with connections like it — is download first and watch
/// later. So the download is not a convenience beside streaming; for a large
/// part of the audience it IS how they watch.
///
/// And it stopped when they put the phone down. The downloader is Dart code
/// writing a file, which Android has no way to see: press Home or let the
/// screen sleep and the process is an ordinary backgrounded app, to be
/// deprioritised, then frozen, then reclaimed. A 900 MB film forty per cent
/// downloaded just stopped — silently, after spending forty per cent of
/// somebody's data allowance.
///
/// A foreground service is the only thing Android accepts as a statement that
/// work the user asked for is happening. This class is the three-verb bridge
/// to it. It holds no state worth protecting and every call is best-effort:
/// a platform that refuses leaves the download running exactly as it did
/// before, in the foreground only, which is the position this app was in
/// until now rather than a new failure.
class OfflineServiceBridge {
  const OfflineServiceBridge._();

  static const MethodChannel _channel =
      MethodChannel('mx_clone/offline_service');

  /// Raise the notification and take the locks.
  static Future<void> start(String title, String text) =>
      _call('start', title, text, -1);

  /// Refresh the notification, and with it the WakeLock's safety cap — which
  /// is why this must keep being called on a long download and not only when
  /// the number on screen changes.
  static Future<void> update(String title, String text, int percent) =>
      _call('update', title, text, percent);

  /// Stop the service and post the dismissible "it is on your phone" notice.
  ///
  /// ONE CALL, NOT TWO. The notice has to be posted after the service is told
  /// to go, and doing that across two platform calls from Dart leaves a window
  /// in which the app can be killed between them — the ongoing notification
  /// gone, the finished one never posted, and the viewer with no way to learn
  /// that the film they were waiting for is ready.
  static Future<void> done(String title, String text) =>
      _call('done', title, text, 100);

  /// Stop without a notice: a cancellation, or a download that gave up and has
  /// already said so on screen.
  static Future<void> stop() => _call('stop', '', '', -1);

  /// True when the Pause button in the notification shade has been pressed
  /// since the last time this was asked.
  ///
  /// A POLL RATHER THAN A CALLBACK, and that is the robust direction. The
  /// button arrives in a service that may have been recreated with no Activity
  /// attached, and the channel that would carry a call INTO Dart belongs to the
  /// Activity's Flutter engine — so a push could be delivered to nothing. The
  /// downloader is already talking to the service every couple of seconds while
  /// it refreshes the notification, and if it is not talking then it is not
  /// downloading and there is nothing to pause.
  ///
  /// Read-and-clear on the native side, so one press pauses one download.
  static Future<bool> takePauseRequest() async {
    if (!_supported) return false;
    try {
      return await _channel.invokeMethod<bool>('takePauseRequest') ?? false;
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineServiceBridge.takePauseRequest: $e');
      return false;
    }
  }

  static Future<void> _call(
      String method, String title, String text, int progress) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>(method, <String, dynamic>{
        'title': title,
        'text': text,
        'progress': progress,
      });
    } catch (e) {
      // Includes MissingPluginException on a platform with no such service.
      if (kDebugMode) debugPrint('OfflineServiceBridge.$method: $e');
    }
  }

  /// Android only. Written as a getter rather than checked at each call site
  /// so a desktop test run never touches a channel that cannot answer.
  static bool get _supported =>
      defaultTargetPlatform == TargetPlatform.android && !kIsWeb;
}
