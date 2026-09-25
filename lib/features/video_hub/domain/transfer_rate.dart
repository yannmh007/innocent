/// How fast a download is going, and therefore how long it has left.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE NUMBER THAT WAS MISSING, AND WHY IT IS THE IMPORTANT ONE
/// ═══════════════════════════════════════════════════════════════════════
///
/// The download showed "412 MB of 1.8 GB". That is a fact about the file. The
/// question the person holding the phone is actually asking is "can I watch
/// this tonight" — and the answer is a number nothing in the app computed.
///
/// Telegram, which is what this audience already uses for films, shows the
/// speed and the time remaining, and it is the single reason its downloads
/// feel manageable on a bad connection: twenty minutes is something you decide
/// to wait for, and "412 MB" is something you stare at. Chrome, Netflix and
/// every podcast app do the same.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY A WINDOW AND NOT AN AVERAGE
/// ═══════════════════════════════════════════════════════════════════════
///
/// The average over the whole download is the wrong answer on exactly the
/// connection this feature exists for. A film that spent ten minutes stalled
/// and is now running at 3 MB/s has a lifetime average of a few hundred
/// kilobytes, so the estimate would say two hours when the truth is four
/// minutes — and the viewer, who is deciding whether to keep waiting, decides
/// on the wrong number. A rolling window answers "how fast is it going NOW",
/// which is the question.
///
/// Pure, and the clock is passed in, so all of this is testable without
/// waiting for real seconds to pass.
library;

/// One (bytes, time) observation.
class _Sample {
  const _Sample(this.bytes, this.at);
  final int bytes;
  final DateTime at;
}

/// A rolling estimate of a transfer's speed.
class TransferRate {
  TransferRate({
    this.window = const Duration(seconds: 20),
    this.minimumSpan = const Duration(seconds: 2),
  });

  /// How far back observations are kept. Long enough to ride out the
  /// second-to-second lumpiness of a mobile link, short enough that a stall
  /// which has ended stops dragging the estimate down.
  final Duration window;

  /// The shortest span that may be used to compute a speed.
  ///
  /// Below this the arithmetic is dominated by when the chunks happened to
  /// arrive: two samples 80 ms apart can say 40 MB/s on a link doing two, and
  /// an estimate that swings by a factor of twenty is worse than no estimate,
  /// because people read the first number they see.
  final Duration minimumSpan;

  final List<_Sample> _samples = <_Sample>[];

  /// Record where the transfer has got to. Out-of-order or backwards readings
  /// are ignored rather than trusted: a resume restarts the byte count, and a
  /// negative speed is not a speed.
  void observe(int bytes, DateTime at) {
    if (_samples.isNotEmpty) {
      final last = _samples.last;
      if (bytes < last.bytes || at.isBefore(last.at)) {
        // A restart. Everything before this describes a different attempt.
        _samples.clear();
      }
    }
    _samples.add(_Sample(bytes, at));
    final cutoff = at.subtract(window);
    // Keep one sample older than the cutoff so a short window still has a
    // span to measure across.
    while (_samples.length > 2 && _samples[1].at.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  /// Bytes per second over the window, or null when there is not yet enough to
  /// say anything honest.
  int? get bytesPerSecond {
    if (_samples.length < 2) return null;
    final first = _samples.first;
    final last = _samples.last;
    final span = last.at.difference(first.at);
    if (span < minimumSpan) return null;
    final gained = last.bytes - first.bytes;
    if (gained <= 0) return 0;
    return (gained / (span.inMicroseconds / 1000000)).round();
  }

  /// How long the rest of [totalBytes] will take at the current speed, or null
  /// when that cannot be answered.
  ///
  /// A speed of zero returns null rather than infinity: "stalled" is a
  /// different thing to say than "4 million hours", and only one of them is
  /// information.
  Duration? remaining(int receivedBytes, int? totalBytes) {
    final speed = bytesPerSecond;
    if (speed == null || speed <= 0) return null;
    if (totalBytes == null || totalBytes <= 0) return null;
    final left = totalBytes - receivedBytes;
    if (left <= 0) return Duration.zero;
    return Duration(seconds: (left / speed).ceil());
  }

  /// Forget everything. Called when a download stops, so the next one does not
  /// inherit the speed of the last.
  void reset() => _samples.clear();
}
