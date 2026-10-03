import '../diagnostics/playback_log.dart';

/// Whether the viewer is watching something over the network right now, and
/// how much a background download should hold back while they are.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT THE VIEWER IS DOING COMES FIRST
/// ═══════════════════════════════════════════════════════════════════════
///
/// Reported 2026-10-03: with a download running, a film opened to stream sat
/// on the spinner. Both pulled from the same line, the download as fast as it
/// could, and the film the viewer was LOOKING AT lost. Telegram's loader gives
/// the file on screen the highest priority and lets background downloads take
/// what is left; that is the behaviour wanted here, for the plain reason that
/// waiting for something you are watching feels broken in a way a download
/// finishing a few minutes later never does.
///
/// So the stream proxy [touch]es this on every chunk it relays from the
/// network, and a download checks [active] between batches: while it is true
/// the download is paced down to [yieldBytesPerSecond] — enough to keep it
/// visibly moving, small enough that the film's own buffer fills first. A
/// few seconds after the last chunk (the film paused, closed, or fully
/// buffered) the download is back at full speed on its own.
///
/// Playing a film that is still DOWNLOADING (watch-while-downloading) does
/// not touch this: there the download is what feeds the player, and slowing
/// it would starve the very thing being watched.
class ForegroundStream {
  ForegroundStream._();

  static DateTime? _last;

  /// How long after the last relayed chunk the viewer still counts as
  /// watching. libmpv reads ahead in bursts with gaps between them; this
  /// spans the gaps.
  static const Duration linger = Duration(seconds: 8);

  /// The pace a background download keeps while the viewer is streaming:
  /// 192 KB/s, about 1.5 Mbit/s — a minority share of a 3 MB/s line, and
  /// still a gigabyte an hour and a half.
  static const int yieldBytesPerSecond = 192 * 1024;

  static void touch() {
    // The edge, not every chunk: whether a download yielded, and when it
    // stopped, is what a trace needs to answer.
    if (!active) PlaybackLog.add('fg stream: watching');
    _last = DateTime.now();
  }

  static bool get active {
    final t = _last;
    return t != null && DateTime.now().difference(t) < linger;
  }

  /// For tests.
  static void reset() => _last = null;

  /// How long to wait after moving [bytes] in [elapsed] so the average stays
  /// at or under [capBytesPerSecond]. Zero when already slow enough.
  static Duration paceDelay({
    required int bytes,
    required Duration elapsed,
    int capBytesPerSecond = yieldBytesPerSecond,
  }) {
    if (bytes <= 0 || capBytesPerSecond <= 0) return Duration.zero;
    final wantMicros = bytes * 1000000 ~/ capBytesPerSecond;
    final left = wantMicros - elapsed.inMicroseconds;
    return left > 0 ? Duration(microseconds: left) : Duration.zero;
  }
}
