import 'event_sender.dart';

/// Turns a running player into the two numbers a ranking is built on.
///
/// WHY THIS IS NOT JUST TWO `log()` CALLS IN THE PLAYER. `play_start` says
/// somebody pressed play, which every catalogue already knows. What nothing
/// knows yet is WHERE THEY STOPPED — and that single fact is what separates a
/// title people click and quit from one fewer people finish. Ranking on view
/// count alone cannot tell those apart, which is why `landing_rows()` has
/// been promoting whatever got views first since the day it was written.
///
/// Its own class, in the video_hub feature rather than in the player, for two
/// reasons. The player is 3,600 lines and plays local files, music and vault
/// content as well as the catalogue — none of which has a title id, and none
/// of which should ever be reported. And the rules below fail silently: a
/// wrong completion threshold produces a plausible number that is quietly
/// untrue, which is worse than a crash and far harder to notice.
class PlaybackReporter {
  PlaybackReporter(
    this._events, {
    required this.titleId,
    this.assetId,
  });

  final EventSender _events;

  /// The catalogue title being watched. Present only for hub playback.
  final String titleId;

  /// The album clip, when this is one rather than the main film.
  ///
  /// Without it every extra in a title would be indistinguishable from the
  /// film itself, and "which clip do people actually watch" — the question
  /// that decides what is worth uploading — could not be asked.
  final String? assetId;

  /// How often a progress event goes out while playing.
  ///
  /// Thirty seconds, matching the design note. Fine enough to see where a
  /// two-hour film loses people, coarse enough that a full film is four
  /// dozen rows rather than four thousand.
  static const Duration reportEvery = Duration(seconds: 30);

  /// The fraction watched that counts as finished.
  ///
  /// 0.9, not 1.0, and the difference matters: almost nobody sits through the
  /// closing credits, so requiring the last frame would record a completion
  /// rate near zero for titles everybody finished.
  static const double completeAt = 0.9;

  bool _openReported = false;

  /// Records how long the black screen lasted.
  ///
  /// Once per playback, and only for a real measurement: a second call is
  /// ignored so a mid-film re-buffer, a seek or a silent reconnect can never
  /// be counted as another start. Without that guard the median would drift
  /// downwards every time someone scrubbed, and the metric would look like it
  /// was improving while nothing had changed.
  void reportOpen(Duration took) {
    if (_openReported || _finished) return;
    _openReported = true;
    _events.log(
      Ev.playOpen,
      titleId: titleId,
      assetId: assetId,
      meta: <String, dynamic>{'open_ms': took.inMilliseconds},
    );
  }

  int _stallsSent = 0;

  /// Records a stall, with the measured reason.
  ///
  /// THIS IS THE EVENT THAT ANSWERS "WHY DOES IT STUTTER". Until now the only
  /// thing recorded about a stall was that the app had nothing to draw, and
  /// the two causes of that — a link too slow for the file's bitrate, and a
  /// device too slow to decode it — want opposite fixes. The client measures
  /// which at the moment it happens; this carries it.
  ///
  /// CAPPED AT SIX PER PLAYBACK, and the cap is the point rather than a
  /// detail. The failure being diagnosed repeats every couple of seconds, so
  /// an uncapped reporter would answer a struggling connection by making
  /// hundreds more requests on it — turning a measurement into a cause.
  void reportStall(Map<String, dynamic> reason) {
    if (_finished || _stallsSent >= 6) return;
    _stallsSent++;
    _events.log(
      Ev.playStall,
      titleId: titleId,
      assetId: assetId,
      positionS: _furthestS,
      meta: <String, dynamic>{...reason, 'n': _stallsSent},
    );
  }

  int _furthestS = 0;
  int _durationS = 0;
  bool _finished = false;

  /// Records a progress point.
  ///
  /// FURTHEST, NOT LAST. Someone who watches to the end and then seeks back to
  /// rewatch a scene has finished the title; keying on the last position seen
  /// would record them as having stopped in the middle, and rewatching is a
  /// signal of a title people LIKE. The event still carries the live position,
  /// because where people are is the histogram; the furthest point is only
  /// what decides [completed].
  void report(Duration position, Duration duration) {
    if (_finished) return;
    final p = position.inSeconds;
    final d = duration.inSeconds;
    if (d > 0) _durationS = d;
    if (p > _furthestS) _furthestS = p;

    _events.log(
      Ev.playProgress,
      titleId: titleId,
      assetId: assetId,
      positionS: p,
      // Null rather than 0 while the engine is still working it out. A zero
      // duration would make every completion ratio 0/0, and a row that says
      // "0 seconds long" cannot be told from one that was never measured.
      durationS: d > 0 ? d : null,
    );
  }

  /// Called once, when playback ends or the screen goes away.
  ///
  /// Always emits something. A viewer who quit at ninety seconds is the most
  /// valuable row in the table — it is the one that says the title is not
  /// holding people — and a reporter that only spoke on success would record
  /// exactly the titles that need no attention.
  void finish({Duration? position, Duration? duration}) {
    if (_finished) return;
    _finished = true;

    if (position != null && position.inSeconds > _furthestS) {
      _furthestS = position.inSeconds;
    }
    if (duration != null && duration.inSeconds > 0) {
      _durationS = duration.inSeconds;
    }

    _events.log(
      completed(furthestS: _furthestS, durationS: _durationS)
          ? Ev.playComplete
          : Ev.playProgress,
      titleId: titleId,
      assetId: assetId,
      positionS: _furthestS,
      durationS: _durationS > 0 ? _durationS : null,
      // Marks the last event of a playback, so a query can find where each
      // viewing ENDED without having to find the maximum id per session.
      meta: const <String, dynamic>{'final': true},
    );
  }

  /// Whether this counts as watched.
  ///
  /// Static and pure so the rule can be tested without a player, an event
  /// sender or a network — and so there is exactly one statement of it.
  ///
  /// A ZERO OR UNKNOWN DURATION IS NEVER COMPLETE. Without this guard
  /// `0 >= 0 * 0.9` is true, so every playback of a live stream, and every
  /// playback abandoned before the engine reported a length, would be filed
  /// as finished — inflating completion rate exactly where there is least
  /// reason to trust it.
  static bool completed({required int furthestS, required int durationS}) {
    if (durationS <= 0) return false;
    return furthestS >= durationS * completeAt;
  }
}
