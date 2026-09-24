/// The valid range of every numeric libmpv option this app writes.
///
/// WHY THIS FILE EXISTS, stated as the failure it is here to prevent.
///
/// v1.64.21 shipped with this line in the local-file branch of the buffer
/// profile:
///
///     await _setMpvProperty('demuxer-lavf-probesize', '0');
///
/// The intent was "put it back to libavformat's own default", and `0` is
/// indeed the value mpv carries internally for that. But the option is
/// declared with a MINIMUM OF 32, and mpv does not validate its own defaults
/// — it validates what you write. So every local file opened after that
/// change made libmpv log
///
///     The demuxer-lavf-probesize option must be >= 32: 0
///
/// at error level. `_setMpvProperty` saw no Dart exception and reported
/// success; media_kit forwarded the log line to its error stream; and the
/// player drew "Playback failed" across a film that was playing perfectly.
/// A viewer's only evidence was a red box quoting an option name.
///
/// THE LESSON IS NOT "BE CAREFUL". libmpv rejects a bad value by LOGGING,
/// not by failing the call, so there is no return value to check and nothing
/// to catch. The only moment the mistake is visible is while the line is
/// being written — which is what this table makes possible, in a pure
/// function with tests, on a machine with no phone attached.
///
/// Only options with a documented numeric range are listed. An option not in
/// the table is not checked, which is honest: a partial guard that says so
/// beats a complete-looking one that quietly passes everything.
library;

/// The range of one numeric option, and where the number came from.
class MpvRange {
  const MpvRange(this.min, {this.max, required this.why});

  final num min;
  final num? max;

  /// What breaks outside the range. Carried so a failure message can say
  /// something more useful than "out of range".
  final String why;
}

/// Ranges taken from mpv's own option declarations (`demux_lavf.c`,
/// `demux.c`, `stream.c`). Where mpv's internal DEFAULT sits outside the
/// range it accepts — which is the trap that produced the regression — the
/// note says so, because that is precisely the value a reader is tempted to
/// write back when they mean "undo this".
const Map<String, MpvRange> kMpvNumericOptions = <String, MpvRange>{
  // mpv's internal default is 0, meaning "let libavformat choose", and 0 is
  // REFUSED when written. To restore the default behaviour, write
  // libavformat's own default (5,000,000) rather than 0.
  'demuxer-lavf-probesize': MpvRange(
    32,
    why: 'libmpv refuses anything below 32 and logs it as an error, which '
        'the player then shows the viewer as a playback failure',
  ),
  // Seconds, float. 0 is legal here and does mean "libavformat's default",
  // which is why the two neighbouring options behave differently.
  'demuxer-lavf-analyzeduration': MpvRange(
    0,
    why: 'a negative analyze duration is meaningless',
  ),
  'demuxer-max-bytes': MpvRange(0, why: 'a negative byte ceiling is refused'),
  'demuxer-max-back-bytes':
      MpvRange(0, why: 'a negative byte ceiling is refused'),
  'cache-secs': MpvRange(0, why: 'a negative cache length is refused'),
  'demuxer-readahead-secs':
      MpvRange(0, why: 'a negative read-ahead is refused'),
  'network-timeout': MpvRange(0, why: 'a negative timeout is refused'),
  'audio-delay': MpvRange(-600, max: 600, why: 'mpv clamps beyond ten minutes'),
  'sub-delay': MpvRange(-600, max: 600, why: 'mpv clamps beyond ten minutes'),
  'volume': MpvRange(0, max: 1000, why: 'mpv refuses a volume above 1000'),
  'speed': MpvRange(0.01, max: 100, why: 'mpv refuses a speed outside 0.01-100'),
};

/// Why this write would be refused, or null when it is fine.
///
/// Returns null for an option with no listed range and for any value that is
/// not a number — a non-numeric option is not this function's business, and
/// reporting one as invalid would make the guard cry wolf on `hwdec=auto-safe`.
String? mpvValueProblem(String key, String value) {
  final range = kMpvNumericOptions[key];
  if (range == null) return null;

  final n = num.tryParse(value.trim());
  if (n == null) {
    return 'libmpv expects a number for $key, and "$value" is not one.';
  }
  if (n < range.min) {
    return '$key must be at least ${_plain(range.min)} — ${range.why}. '
        'Writing ${_plain(n)} makes libmpv log an error that reaches the '
        'viewer as a playback failure.';
  }
  final max = range.max;
  if (max != null && n > max) {
    return '$key must be at most ${_plain(max)} — ${range.why}.';
  }
  return null;
}

/// `768.0` reads as a mistake next to `768`; trim the decimal when it is one.
String _plain(num n) =>
    n is int || n == n.roundToDouble() ? n.toInt().toString() : n.toString();

/// True when a libmpv error line is a complaint about CONFIGURATION rather
/// than a report that playback failed.
///
/// libmpv has one error channel for two unrelated things: "this file will not
/// decode", which the viewer needs to know about, and "the option you set is
/// not valid", which is a bug in this app and means nothing to them. Both
/// arrive as the same stream of strings, so the player showed both — and the
/// second one arrives while a film is playing perfectly, which makes it worse
/// than useless: a red "Playback failed" box over a working picture teaches
/// people to distrust the box that matters.
///
/// Matched on mpv's own wordings, listed rather than guessed at, and
/// deliberately narrow. Everything this returns true for is still written to
/// [PlaybackLog] by the caller, so nothing disappears — it moves from the
/// viewer's screen to the developer's trail, which is where it belongs.
bool isMpvConfigComplaint(String line) {
  final t = line.toLowerCase();
  return t.contains('option must be') ||
      t.contains('error parsing option') ||
      t.contains('option is not') ||
      t.contains('no such property') ||
      t.contains('property is not available') ||
      t.contains('unknown option') ||
      t.contains('is not a valid value for');
}
