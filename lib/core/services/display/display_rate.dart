import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The display's highest rate while a finger is on the screen, and a
/// moment after it lifts for the fling it started (27 Nov 2026, docs/
/// handoff_2026_11_27_beyond_mx.md P3; the owner: "120 Hz only while
/// touching — battery"). Flutter asks for nothing above what the system
/// gives it (flutter/flutter#35162); DisplayVote.kt votes the highest rate
/// on Flutter's own surface while [touching], and the film's rate or none
/// otherwise. One call per change, not per pointer event.
class DisplayRate {
  DisplayRate._();

  static const MethodChannel _channel = MethodChannel('innocent/display');

  /// How long after the last finger lifts the high rate stays: a fling's
  /// glide (Android's is ~1-2 s at full speed; most are well under).
  static const Duration hold = Duration(milliseconds: 1500);

  static int _down = 0;
  static bool _asked = false;
  static Timer? _release;

  /// Whether the high rate is asked now.
  static bool get touching => _asked;

  /// What each change sends; the channel by default (a test listens).
  @visibleForTesting
  static void Function(bool on) send = _send;

  static void pointerDown() {
    _down++;
    _release?.cancel();
    _release = null;
    if (!_asked) {
      _asked = true;
      send(true);
    }
  }

  static void pointerUp() {
    if (_down > 0) _down--;
    if (_down > 0) return;
    _release?.cancel();
    _release = Timer(hold, () {
      _release = null;
      if (_down == 0 && _asked) {
        _asked = false;
        send(false);
      }
    });
  }

  @visibleForTesting
  static void reset() {
    _down = 0;
    _asked = false;
    _release?.cancel();
    _release = null;
    send = _send;
  }

  static void _send(bool on) {
    if (kIsWeb || !Platform.isAndroid) return;
    // ignore: discarded_futures
    _channel.invokeMethod<String>('touch', <String, Object?>{'on': on}).catchError((Object _) => null);
  }
}
