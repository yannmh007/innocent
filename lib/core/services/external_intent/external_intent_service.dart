import 'dart:async';

import 'package:flutter/services.dart';

/// Phase 29: Receives external "open video" intents from the host OS
/// (e.g. file manager taps, share-to-MX, video links from a browser).
///
/// Backed by `MainActivity.kt`'s `mx_clone/intent` channel:
/// - `getInitialVideo` → returns `{uri, title}` for the launch intent (one-shot)
/// - `onNewVideo`      → invoked when a new VIEW intent arrives while running
class ExternalIntentService {
  static const MethodChannel _channel = MethodChannel('mx_clone/intent');

  /// Stream of incoming video open requests (from onNewVideo callback).
  /// First listener will also be replayed the initial intent (if any).
  Stream<ExternalVideoRequest> get videoRequests => _controller.stream;

  /// v0.99.5: links shared into Innocent from another app's share sheet.
  ///
  /// Separate from [videoRequests] because they mean different things: a VIEW
  /// intent is a file to play, a SEND intent is a web link to look up. Sending
  /// the second down the first's pipe would hand the player a page URL.
  Stream<String> get sharedLinks => _linkController.stream;

  final StreamController<ExternalVideoRequest> _controller =
      StreamController<ExternalVideoRequest>.broadcast();

  final StreamController<String> _linkController =
      StreamController<String>.broadcast();

  bool _started = false;

  /// Call once at app startup. Sets up the method handler + replays the
  /// initial launch intent (if Innocent was opened via VIEW action).
  Future<void> start() async {
    if (_started) return;
    _started = true;

    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSharedLink') {
        final args = (call.arguments as Map?)?.cast<Object?, Object?>();
        final url = args?['url'];
        if (url is String && url.startsWith('http')) {
          _linkController.add(url);
        }
        return null;
      }
      if (call.method == 'onNewVideo') {
        final args = (call.arguments as Map?)?.cast<Object?, Object?>();
        if (args != null) {
          final req = _parse(args);
          if (req != null) {
            _controller.add(req);
          }
        }
      }
      return null;
    });

    // Pull the initial launch intent (if any)
    try {
      final result = await _channel.invokeMethod<Map?>('getInitialVideo');
      if (result != null) {
        final req = _parse(result.cast<Object?, Object?>());
        if (req != null) {
          // Delay slightly so listeners can subscribe before the event fires.
          Future.microtask(() => _controller.add(req));
        }
      }
    } on MissingPluginException catch (_) {
      // Non-Android platforms: channel may not exist.
    } on PlatformException catch (_) {
      // Best-effort.
    }

    // And the initial shared link, if Innocent was launched from a share sheet.
    try {
      final String? link =
          await _channel.invokeMethod<String>('getInitialSharedLink');
      if (link != null && link.startsWith('http')) {
        Future.microtask(() => _linkController.add(link));
      }
    } on MissingPluginException catch (_) {
    } on PlatformException catch (_) {}
  }

  ExternalVideoRequest? _parse(Map<Object?, Object?> map) {
    final uri = map['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;
    final title = (map['title'] as String?) ?? _basename(uri);
    return ExternalVideoRequest(uri: uri, title: title);
  }

  String _basename(String uri) {
    final i = uri.lastIndexOf('/');
    if (i < 0 || i == uri.length - 1) return uri;
    return uri.substring(i + 1);
  }

  void dispose() {
    _controller.close();
    _linkController.close();
  }
}

class ExternalVideoRequest {
  final String uri;
  final String title;
  const ExternalVideoRequest({required this.uri, required this.title});
}
