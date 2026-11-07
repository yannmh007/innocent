/// What one playback was like for the viewer, in numbers: how long until the
/// picture, how often and how long it froze, how long a jump made them wait,
/// how the quality moved, and what failed.
///
/// WHY (7 Nov 2026). Stalls on the ladder engine — the main streaming path —
/// were written only to the phone's own trail, so the server saw none after
/// 24 Oct and "no stalls" looked like smoothness. A viewer's experience is
/// these few numbers per playback (the same ones YouTube's and Netflix's
/// quality reports use: join time, rebuffer ratio, rebuffer count, quality),
/// and they are what tells a fix that worked from one that did not.
///
/// Pure: no clock of its own, no player, no network — the controller feeds
/// it, the screen sends [toMeta] once, and tests drive it directly.
class PlaybackQoe {
  /// `ladder` (ExoPlayer, HLS) or `mpv` (libmpv, one file), known at the
  /// first frame; null before.
  String? engine;

  /// Black screen from the hand-over to the first frame (ms).
  int? openMs;

  /// Refills after the first frame that were not a jump's: what reads as
  /// "it stuttered". A stop under [visibleMs] is a BLIP — a frame or two, no
  /// spinner — counted apart: in the device lab 27 of 28 refills were blips
  /// of 2-67 ms and one was a 2 s stop, and counting them together hid the
  /// stop a viewer saw (7 Nov 2026). Frozen time counts both.
  static const int visibleMs = 250;
  int stalls = 0;
  int blips = 0;
  int frozenMs = 0;
  int longestMs = 0;

  /// Refills right after a seek or skip: what reads as "a jump is slow".
  int jumpFills = 0;
  int jumpMs = 0;

  /// Time actually playing, so frozen time can be read as a share of it.
  int playingMs = 0;
  DateTime? _playingSince;

  /// The ladder's rungs seen on screen (heights), and how often it moved.
  int rungChanges = 0;
  int? rungLow;
  int? rungHigh;
  int? _lastRung;

  /// What went wrong, as fixed codes (never a message: those can carry an
  /// address).
  final Set<String> errors = <String>{};

  /// A new file: everything starts again.
  void reset() {
    engine = null;
    openMs = null;
    stalls = blips = frozenMs = longestMs = jumpFills = jumpMs = playingMs = 0;
    rungChanges = 0;
    rungLow = rungHigh = _lastRung = null;
    _playingSince = null;
    errors.clear();
  }

  void firstFrame({required int ms, required String engineName}) {
    openMs ??= ms;
    engine ??= engineName;
  }

  void stallEnded(int ms) {
    if (ms < 0) return;
    if (ms < visibleMs) {
      blips++;
    } else {
      stalls++;
    }
    frozenMs += ms;
    if (ms > longestMs) longestMs = ms;
  }

  void jumpFillEnded(int ms) {
    if (ms < 0) return;
    jumpFills++;
    jumpMs += ms;
  }

  void playing(bool on, DateTime now) {
    if (on) {
      _playingSince ??= now;
    } else {
      final since = _playingSince;
      if (since != null) playingMs += now.difference(since).inMilliseconds;
      _playingSince = null;
    }
  }

  void rung(int? height) {
    if (height == null || height <= 0) return;
    if (_lastRung != null && _lastRung != height) rungChanges++;
    _lastRung = height;
    if (rungLow == null || height < rungLow!) rungLow = height;
    if (rungHigh == null || height > rungHigh!) rungHigh = height;
  }

  void error(String code) => errors.add(code);

  /// One event's worth, at the end. Playing time still running is counted up
  /// to [now]. Null fields are left out, so a playback that never reached a
  /// picture says so by what it lacks.
  Map<String, dynamic> toMeta(DateTime now) {
    var played = playingMs;
    final since = _playingSince;
    if (since != null) played += now.difference(since).inMilliseconds;
    return <String, dynamic>{
      if (engine != null) 'engine': engine,
      if (openMs != null) 'open_ms': openMs,
      'played_s': played ~/ 1000,
      'stalls': stalls,
      if (blips > 0) 'blips': blips,
      'frozen_ms': frozenMs,
      if (stalls + blips > 0) 'longest_ms': longestMs,
      'jumps': jumpFills,
      if (jumpFills > 0) 'jump_ms': jumpMs,
      if (rungLow != null) 'rung_low': rungLow,
      if (rungHigh != null) 'rung_high': rungHigh,
      if (rungLow != null) 'rung_changes': rungChanges,
      if (errors.isNotEmpty) 'errors': (errors.toList()..sort()).join(','),
    };
  }
}
