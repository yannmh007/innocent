import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Fills in the length the library shows for videos whose MediaStore value came
/// back zero.
///
/// A freshly downloaded file is indexed by the system before its metadata is
/// ready, so `photo_manager` reports its duration as 0 and every one of those
/// rows read "00:00". This reads the real length straight off the file header
/// through the native `probeDurations` call — the same component the system
/// itself uses, so it works regardless of why MediaStore's value was 0.
///
/// Reads are BATCHED (a scrolling list asks for many at once) and CACHED for
/// the session, so each file is read at most once, and the tiles that asked
/// rebuild when the value arrives. Asking is safe to do from `build`: it only
/// schedules work and never notifies synchronously.
class VideoDurationCache extends ChangeNotifier {
  VideoDurationCache();

  static const MethodChannel _channel = MethodChannel('mx_clone/downloader');

  /// How long to gather requests before a single native round trip, so a
  /// screen's worth of tiles is probed in one call rather than one-by-one.
  static const Duration _batchWindow = Duration(milliseconds: 120);

  final Map<String, Duration> _known = <String, Duration>{};
  final Set<String> _requested = <String>{}; // ever asked — probed or in flight
  final Set<String> _queue = <String>{}; // waiting for the next flush
  Timer? _flushTimer;
  bool _flushing = false;

  /// The probed length for [path], or null when it is not known yet. Asking for
  /// an unknown path schedules it to be read; the notifier fires once it
  /// resolves (or is found unreadable, in which case it simply stays absent and
  /// the row keeps whatever it had). Returns a cached hit immediately and does
  /// not re-queue it, so calling this from `build` cannot loop.
  Duration? durationFor(String path) {
    if (path.isEmpty) return null;
    final Duration? hit = _known[path];
    if (hit != null) return hit;
    if (_requested.add(path)) {
      _queue.add(path);
      _scheduleFlush();
    }
    return null;
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(_batchWindow, _flush);
  }

  Future<void> _flush() async {
    _flushTimer = null;
    if (_flushing) {
      // A call is already in flight; let the leftovers ride behind it.
      if (_queue.isNotEmpty) _scheduleFlush();
      return;
    }
    if (_queue.isEmpty) return;
    final List<String> batch = _queue.toList(growable: false);
    _queue.clear();
    _flushing = true;
    try {
      final Object? raw = await _channel.invokeMethod<Object?>(
        'probeDurations',
        <String, Object?>{'paths': batch},
      );
      if (raw is Map) {
        var changed = false;
        raw.forEach((Object? key, Object? value) {
          // Native sends milliseconds as an int (or long, which arrives as int
          // on the Dart side). Anything else is ignored.
          final int? ms = value is int ? value : null;
          if (key is String && ms != null && ms > 0) {
            _known[key] = Duration(milliseconds: ms);
            changed = true;
          }
        });
        if (changed) notifyListeners();
      }
    } catch (_) {
      // Native side unavailable — leave these unresolved; rows keep 00:00.
    } finally {
      _flushing = false;
      if (_queue.isNotEmpty) _scheduleFlush();
    }
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _flushTimer = null;
    super.dispose();
  }
}

/// Session-wide cache. A single instance so a duration read on one screen is
/// still known on the next.
final videoDurationCacheProvider =
    ChangeNotifierProvider<VideoDurationCache>((ref) => VideoDurationCache());
