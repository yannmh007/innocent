/// What to do with one libmpv error line.
enum ErrorVerdict {
  /// Log it and act on it, as before.
  pass,

  /// The same line again within the repeat window: counted, not acted on.
  repeat,

  /// Too many errors too fast: the decoder is chewing through bad data.
  /// Reported once per file.
  storm,
}

/// Turns a flood of identical decoder errors into one line and one decision.
///
/// WHY. Diagnostics from a Galaxy S23 on 2026-10-03: the ANR trace had the
/// Android main thread inside `mpv_wait_event`, and the playback log was
/// hundreds of "Error decoding audio." with the same timestamp. A decoder fed
/// bad data (a zero-filled hole in a half-downloaded file) fails on every
/// packet; with no output to pace it, libmpv pulls packets as fast as the CPU
/// allows and logs one error per packet. media_kit drains libmpv's events on
/// the UI thread, and each error ran the player's handler — the trail, the
/// error state, a rebuild of the player screen — so the UI thread never got
/// to the tap and Android declared the app not responding.
///
/// This decides, per line, cheaply: the first of a kind passes, repeats are
/// counted (and summarised as `×N` when something else arrives), and a burst
/// past [stormAt] in [window] is a [ErrorVerdict.storm] — the cue to stop the
/// file at the source rather than keep draining its errors.
class ErrorFloodGate {
  ErrorFloodGate({
    this.repeatWindow = const Duration(seconds: 3),
    this.window = const Duration(seconds: 2),
    this.stormAt = 30,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Duration repeatWindow;
  final Duration window;
  final int stormAt;
  final DateTime Function() _now;

  String? _last;
  DateTime? _lastAt;
  int _repeats = 0;
  final List<DateTime> _recent = <DateTime>[];
  bool _stormed = false;

  String? _summary;

  /// The `×N` line for the repeats swallowed before the line just admitted,
  /// or null. Read it after [admit] returns [ErrorVerdict.pass].
  String? takeSummary() {
    final s = _summary;
    _summary = null;
    return s;
  }

  ErrorVerdict admit(String message) {
    // Judged already: the cheapest possible answer, because this is the
    // path the rest of a flood takes, thousands of times a second.
    if (_stormed) {
      if (message == _last) _repeats++;
      return ErrorVerdict.repeat;
    }
    final now = _now();
    _recent.add(now);
    // Only the last [stormAt] times matter for the count.
    if (_recent.length > stormAt) _recent.removeAt(0);
    final cutoff = now.subtract(window);
    while (_recent.isNotEmpty && _recent.first.isBefore(cutoff)) {
      _recent.removeAt(0);
    }
    if (!_stormed && _recent.length >= stormAt) {
      _stormed = true;
      _last = message;
      _lastAt = now;
      return ErrorVerdict.storm;
    }
    final same = message == _last &&
        _lastAt != null &&
        now.difference(_lastAt!) <= repeatWindow;
    _lastAt = now;
    if (same) {
      _repeats++;
      return ErrorVerdict.repeat;
    }
    _summary = _repeats > 0 ? '(previous line ×${_repeats + 1})' : null;
    _repeats = 0;
    _last = message;
    return ErrorVerdict.pass;
  }

  /// A new file: nothing from the last one counts.
  void reset() {
    _last = null;
    _lastAt = null;
    _repeats = 0;
    _summary = null;
    _recent.clear();
    _stormed = false;
  }
}
