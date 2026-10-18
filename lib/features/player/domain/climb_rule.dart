/// When Auto may step back UP a rung mid-film.
///
/// THE GAP THIS CLOSES. Auto used to pick a copy when the film opened and
/// then only ever step DOWN, after a stall. A viewer who started on a bad
/// minute — a lift, a crowded tower, the first measurement of a new phone —
/// watched the whole film in 360p on a link that recovered to carry 720p
/// thirty seconds later. Every adaptive player climbs back: ExoPlayer, Shaka,
/// hls.js, YouTube, Netflix.
///
/// THE NUMBERS ARE THEIRS, MADE MORE CAUTIOUS FOR A REOPEN. ExoPlayer climbs
/// once 10 s are buffered (`DEFAULT_MIN_DURATION_FOR_QUALITY_INCREASE_MS`);
/// Shaka waits 8 s between switches. Their switch is seamless — the next
/// segment simply comes from another rung. Here a switch is a reopen of the
/// film at the same moment (libmpv's HLS demuxer cannot change variant).
/// Since 1.64.68 the better copy's next seconds are fetched first, while the
/// old one plays on (the warm switch), so the reopen costs a blink rather
/// than a second of frozen picture — but the fetch is a viewer's data, and a
/// climb still asks for evidence first: 15 s buffered,
/// a minute since the last switch, a minute and a half since the last stall,
/// a minute between asks, and at most three climbs in a film. Whether a
/// better copy FITS is not decided here: the playback code answers that from
/// the ladder and what the connection measures (60 % headroom, the same rule
/// that picks the first copy).
library;

class ClimbRule {
  ClimbRule._();

  /// How often the player looks. Cheap: a yes from the phone's own check is
  /// needed before anything is measured or asked of the server.
  static const Duration tick = Duration(seconds: 5);

  /// Nothing in the first half-minute of a film: the first measurements are
  /// the start's burst, not the link.
  static const Duration notBefore = Duration(seconds: 30);

  /// A minute since the last change of copy, either way.
  static const Duration afterSwitch = Duration(seconds: 60);

  /// A minute and a half since the picture last stopped to buffer.
  static const Duration afterStall = Duration(seconds: 90);

  /// A minute between asks of the server, yes or no.
  static const Duration betweenTries = Duration(seconds: 60);

  /// A wait this soon after a copy's first picture is that copy FILLING
  /// ITS BUFFER, not the line failing: libmpv shows the first frame and
  /// then holds for its cache to reach `cache-pause-wait`. Counted as a
  /// stall, it held every first climb back a minute and a half (device lab
  /// run 38018583863: Sintel's step from 360p to 720p came at 94 s, on a
  /// line measured at 4 to 22 Mbit/s from the twelfth second).
  static const Duration startFill = Duration(seconds: 5);

  /// Whether a wait for the buffer, [sinceFirstFrame] after this copy's
  /// first picture, counts as a stall for [afterStall].
  static bool isStall(Duration sinceFirstFrame) => sinceFirstFrame >= startFill;

  /// Seconds of film that must be buffered ahead: a reopen spends them.
  static const double minBufferedSeconds = 15;

  /// Climbs in one film. With at most two automatic steps down, a link that
  /// swings cannot turn the film into a slide show of reopens.
  static const int maxClimbs = 3;

  /// A CLIMB CALLED OFF IS A MEASUREMENT. The better copy was fetched from
  /// the moment it would open at and did not arrive 1.25 times faster than
  /// it plays: this line, now, cannot carry it. Asking again a minute later
  /// would spend up to 8 MB of the viewer's data to learn the same thing, so
  /// after one the next waits three minutes, and after two the film stays
  /// where it is.
  static const Duration afterAbandon = Duration(minutes: 3);
  static const int maxAbandons = 2;

  /// The margin the better copy's bytes must arrive by: the 1.25 a rung
  /// needs to be watched without stalls, over its own bitrate.
  static const double climbPace = 1.25;

  /// Whether, after [abandons] climbs called off in this film, the last
  /// [sinceAbandon] ago (null: none), another may be tried.
  static bool abandonAllows({required int abandons, required Duration? sinceAbandon}) {
    if (abandons >= maxAbandons) return false;
    if (sinceAbandon != null && sinceAbandon < afterAbandon) return false;
    return true;
  }

  /// Whether the player may try a better copy now. Durations are "how long
  /// ago", null meaning "never in this film".
  static bool allows({
    required Duration sinceOpen,
    required Duration? sinceSwitch,
    required Duration? sinceStall,
    required Duration? sinceTry,
    required double? bufferedSeconds,
    required int climbs,
  }) {
    if (climbs >= maxClimbs) return false;
    if (sinceOpen < notBefore) return false;
    if (sinceSwitch != null && sinceSwitch < afterSwitch) return false;
    if (sinceStall != null && sinceStall < afterStall) return false;
    if (sinceTry != null && sinceTry < betweenTries) return false;
    final b = bufferedSeconds;
    if (b == null || b < minBufferedSeconds) return false;
    return true;
  }
}
