import '../../../../core/services/diagnostics/playback_log.dart';

/// WHERE A LADDER'S START SPENDS ITS TIME, step by step (19 Nov 2026).
///
/// 1.64.85 on the owner's phone took 2078 ms from opening a ladder at 579 s
/// to its picture, and the trail could only say that the 480p, 360p and
/// 720p indexes landed 0.5 s apart (BACKLOG §0, "1.64.85's first look",
/// weak point 5). Which of them the picture waited for — the start rung's
/// index, the master, its playlist, the first segment's answer or its
/// bytes, a neighbour's index read beside it on the same line — was not
/// in it. This keeps the moments, in ms from the ladder's registration:
///
///  * in a lab build, each as it happens (`hls start +N ms: …`), for
///    test_device/ladderstart_summary.py to set beside the tap, the grant
///    and the picture (logcat's own times);
///  * in every build, one line once the first film segment is in, for the
///    diagnostics report (whose 40 lines cannot take a dozen).
///
/// Only the first [window] of a ladder, at most [_cap] moments: a start,
/// not a playback.
class LadderStartTrail {
  LadderStartTrail._();

  static const Duration window = Duration(seconds: 20);
  static const int _cap = 48;

  static Stopwatch? _clock;
  static final List<(String, int)> _marks = <(String, int)>[];
  static bool _summed = false;

  /// A ladder is being registered: the clock starts here.
  static void begin() {
    _clock = Stopwatch()..start();
    _marks.clear();
    _summed = false;
    _print('register');
  }

  /// Whether moments are still being kept.
  static bool get active {
    final c = _clock;
    return c != null && c.elapsed < window && _marks.length < _cap;
  }

  /// A moment of the start, by name.
  static void mark(String what) {
    if (!active) return;
    final ms = _clock!.elapsedMilliseconds;
    _marks.add((what, ms));
    _print(what, ms);
  }

  /// The ms of the first moment named [what], or null.
  static int? at(String what) {
    for (final (w, ms) in _marks) {
      if (w == what) return ms;
    }
    return null;
  }

  /// The first film segment is in: the start as one line, once.
  static void firstSegmentIn() {
    if (_summed || _clock == null) return;
    _summed = true;
    PlaybackLog.add(summary());
  }

  /// "hls start: 480p index 412, master 15, 480p playlist 430, …".
  static String summary() {
    final seen = <String>{};
    final parts = <String>[];
    for (final (w, ms) in _marks) {
      // The first of each kind only: the trail has the rest.
      if (!seen.add(w)) continue;
      parts.add('$w $ms');
    }
    return 'hls start (ms): ${parts.join(', ')}';
  }

  static void _print(String what, [int ms = 0]) {
    if (!PlaybackLog.labTrace) return;
    // The lab's own line, beside PlaybackLog's (which rounds to 0.1 s).
    print('LAB hls start +$ms ms: $what'); // ignore: avoid_print
  }

  /// For tests.
  static void resetForTest() {
    _clock = null;
    _marks.clear();
    _summed = false;
  }
}
