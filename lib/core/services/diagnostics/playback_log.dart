/// A tiny in-memory record of what the background-playback path actually did.
///
/// WHY THIS EXISTS
///
/// Background play dying at screen-off has now been diagnosed four times from
/// reading code, and four times the fix has been aimed at something that
/// turned out not to be the thing. Each round cost a build, a test and a
/// guess. The problem is not the reasoning — it is that the one moment that
/// matters happens with the screen off, where nothing can be observed.
///
/// So this records it. No dependencies, no I/O, no isolate: a static list of
/// short lines, capped, safe to call from anywhere including the service layer
/// where a Ref is not available. [PlayerStatsOverlay] renders the tail of it,
/// so turning on Settings → Player → Debug and looking after the fact is
/// enough to answer the questions that have been guessed at until now:
///
///  * did the detach actually FIRE, or was its gate false the whole time?
///  * did libmpv ACCEPT the writes, or did they throw and get swallowed?
///  * did the playback position ADVANCE while backgrounded? That single
///    number separates "the renderer blocked" from "something paused us" from
///    "the process was frozen" — three causes that look identical from the
///    outside and have nothing else in common.
class PlaybackLog {
  PlaybackLog._();

  static const int _cap = 40;
  static final List<String> _lines = <String>[];
  static DateTime? _epoch;

  /// v1.61: an optional second destination for every line.
  ///
  /// This list is in memory, so it dies with the process — which is exactly
  /// the wrong property when the process dying IS the thing being
  /// investigated. `CrashBreadcrumbs` installs itself here at startup and
  /// persists each line, so every existing call site below becomes evidence
  /// that survives a crash without any of them changing.
  ///
  /// Left as a plain field so this class keeps its no-dependency promise: it
  /// is still safe to call from the service layer where no Ref exists.
  static void Function(String line)? sink;

  /// Seconds since the first entry, so the lines read as a timeline rather
  /// than as wall-clock stamps nobody can line up by eye.
  static String _stamp() {
    final now = DateTime.now();
    _epoch ??= now;
    final ms = now.difference(_epoch!).inMilliseconds;
    return (ms / 1000).toStringAsFixed(1).padLeft(6);
  }

  /// Record one event. Keep [message] short — this is read on a phone screen
  /// on top of a video.
  static void add(String message) {
    _lines.add('${_stamp()}  $message');
    if (_lines.length > _cap) {
      _lines.removeRange(0, _lines.length - _cap);
    }
    try {
      sink?.call(message);
    } catch (_) {
      // A logger must never throw into the code it is observing.
    }
  }

  /// Most recent entries, oldest first, at most [count].
  static List<String> tail(int count) {
    if (_lines.length <= count) return List<String>.unmodifiable(_lines);
    return List<String>.unmodifiable(_lines.sublist(_lines.length - count));
  }

  /// Everything, for copying out.
  static String get text => _lines.join('\n');

  static void clear() {
    _lines.clear();
    _epoch = null;
  }
}
