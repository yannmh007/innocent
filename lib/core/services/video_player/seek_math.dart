/// Where a relative skip should land, given what the engine currently knows.
///
/// ─── THE BUG THIS FILE IS THE FIX FOR ────────────────────────────────────
///
/// `seekRelative` clamped the target against the cached duration:
///
///     final clamped = target > _duration ? _duration : target;
///
/// which is correct only when the duration is known. It is NOT known in two
/// ordinary situations:
///
///   * **The first moment of every file.** `Player.open()` returns before the
///     demuxer has read the header, and media_kit's duration stream reports
///     `0` until it has. A viewer who taps +10 s in that window asked to skip
///     forward and was sent to 00:00 — the one place they were trying to
///     leave.
///   * **Anything with no duration at all** — a live stream, a growing file,
///     a container whose header does not carry one. There the duration stays
///     zero for the whole playback, so *every* forward skip went to the
///     start, permanently.
///
/// An unknown duration is not a duration of zero, and the difference is the
/// whole bug. With nothing to clamp against, the honest answer is to pass the
/// request through and let the demuxer decide — seeking past the end of a
/// file is something every engine already handles, and handles better than a
/// guess made here.
///
/// Pure, so it can be tested without a phone or an engine.
library;

/// The position a skip of [delta] from [current] should land on.
///
/// [duration] is treated as UNKNOWN when it is zero or negative; only a
/// positive duration is used as a ceiling. The floor is always zero, because
/// a negative position is meaningless whatever the engine knows.
Duration clampSeekTarget({
  required Duration current,
  required Duration delta,
  required Duration duration,
}) {
  final target = current + delta;
  if (target < Duration.zero) return Duration.zero;
  if (duration > Duration.zero && target > duration) return duration;
  return target;
}
