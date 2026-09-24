/// Why playback stopped — decided from numbers, not from a guess.
///
/// THE PROBLEM THIS EXISTS FOR. A viewer reports that some videos play two
/// seconds, stall, play two seconds, stall, while others on the same
/// connection are perfect. On screen the two causes are indistinguishable,
/// and they want opposite fixes:
///
///   * NETWORK-LIMITED — the bytes are not arriving as fast as the file
///     needs. A phone camera writes tens of megabits per second; a link
///     doing 6 MB/s has 48 of them and loses the margin the moment anything
///     else on the phone uses the connection. No player setting fixes this.
///     The file has to be smaller, or it has to be downloaded first.
///   * DECODE-LIMITED — the bytes arrived and the chip cannot turn them into
///     frames in real time. 4K60 is a different workload from 480p. Here the
///     buffer is FULL while the picture stops, which is the giveaway.
///
/// And the third answer matters as much as the first two: UNKNOWN. A stall
/// that does not clearly match either pattern must be reported as neither,
/// because a confident wrong diagnosis sends the next day's work in the wrong
/// direction — and this is exactly the class of bug this project has been
/// paying for: a caption that said "slow connection" on a 13 MB/s link,
/// believed for weeks because it was stated with confidence.
///
/// PURE, AND SEPARATE FROM THE PLAYER, so the rule can be tested without a
/// libmpv, a network or a device — and so there is one statement of it.
library;

/// What a stall was caused by.
enum StallCause {
  /// The demuxer ran dry: bytes are not arriving fast enough.
  network,

  /// The demuxer was holding data and the picture stopped anyway.
  decode,

  /// Neither pattern fits. Reported as such.
  unknown,
}

/// A reading taken at the moment playback stopped.
///
/// Every field is nullable because every one of them is a libmpv property
/// read that can legitimately come back empty — an audio-only file has no
/// frame counters, a local file has no cache speed, and a property this build
/// of libmpv does not carry returns nothing at all. A diagnosis built on
/// absent numbers is exactly what [StallCause.unknown] is for.
class StallReading {
  const StallReading({
    this.cacheSeconds,
    this.haveBitsPerSecond,
    this.needBitsPerSecond,
    this.droppedFrames,
    this.hwdec,
    this.width,
    this.height,
  });

  /// `demuxer-cache-duration`: seconds of playable data held ahead of the
  /// play position. The single most informative number here.
  final double? cacheSeconds;

  /// `cache-speed`: how fast bytes are currently arriving, in bits per second
  /// (libmpv reports bytes; the caller converts once, here it is bits so that
  /// it compares directly against a bitrate).
  final int? haveBitsPerSecond;

  /// `video-bitrate` + `audio-bitrate`: what the file needs, in bits/s.
  final int? needBitsPerSecond;

  /// `decoder-frame-drop-count` — frames the decoder threw away because it
  /// was behind. Cumulative, so the caller passes the DELTA since the last
  /// reading; a total would call every late stall a decode problem forever.
  final int? droppedFrames;

  /// `hwdec-current`. Not part of the decision, carried because "software
  /// decoding a 4K file" is the answer an operator can act on.
  final String? hwdec;

  final int? width;
  final int? height;
}

/// The verdict, with the numbers that justify it.
class StallDiagnosis {
  const StallDiagnosis(this.cause, this.reading);

  final StallCause cause;
  final StallReading reading;

  /// The wire form. Short keys because this travels in every stall event, and
  /// kilobits because a bits-per-second integer in JSON is noise at both ends.
  Map<String, dynamic> toMeta() {
    final m = <String, dynamic>{'reason': cause.name};
    final c = reading.cacheSeconds;
    if (c != null) m['cache_s'] = c.isFinite ? c.round() : 0;
    final have = reading.haveBitsPerSecond;
    if (have != null) m['have_kbps'] = have ~/ 1000;
    final need = reading.needBitsPerSecond;
    if (need != null) m['need_kbps'] = need ~/ 1000;
    final d = reading.droppedFrames;
    if (d != null) m['dropped'] = d;
    final hw = reading.hwdec;
    if (hw != null && hw.isNotEmpty) m['hwdec'] = hw;
    final w = reading.width, h = reading.height;
    if (w != null && h != null) m['res'] = '${w}x$h';
    return m;
  }
}

/// A buffer this empty means the demuxer has nothing left to give the
/// decoder. One second rather than zero: the property is sampled while the
/// cache is actively refilling, so an exactly-zero reading is the exception
/// rather than the rule even when starvation is total.
const double kStarvedCacheSeconds = 1.0;

/// A buffer this full means the bytes are not the problem. Three seconds is
/// well above the refill threshold libmpv resumes at and well below the
/// read-ahead the network profile asks for, so it separates "recovering from
/// starvation" from "holding plenty and still not drawing".
const double kHealthyCacheSeconds = 3.0;

/// Decide why playback stopped.
///
/// THE ORDER OF THESE TESTS IS THE RULE. Starvation is checked first because
/// it is the only one of the two that can also produce dropped frames: a
/// decoder handed a truncated packet stream drops frames as a CONSEQUENCE of
/// the network, and testing drops first would file every slow connection as a
/// slow chip.
StallDiagnosis diagnoseStall(StallReading r) {
  final cache = r.cacheSeconds;

  if (cache != null && cache <= kStarvedCacheSeconds) {
    return StallDiagnosis(StallCause.network, r);
  }

  if (cache != null && cache >= kHealthyCacheSeconds) {
    // Data in hand and the picture stopped. Dropped frames make it certain;
    // without them it is still the more likely of the two, but "likely" is
    // not a diagnosis, so it is only claimed when the counter moved.
    final dropped = r.droppedFrames ?? 0;
    if (dropped > 0) return StallDiagnosis(StallCause.decode, r);
    return StallDiagnosis(StallCause.unknown, r);
  }

  // No cache reading at all, or a middling one. If the throughput and the
  // requirement were both measured and the link is clearly short, that is
  // still a network answer — it is the same fact arrived at from the other
  // side, and it is the case a local file cannot reach because a local file
  // has no cache speed.
  final have = r.haveBitsPerSecond, need = r.needBitsPerSecond;
  if (have != null && need != null && need > 0 && have < need) {
    return StallDiagnosis(StallCause.network, r);
  }

  return StallDiagnosis(StallCause.unknown, r);
}
