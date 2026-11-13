/// What a slow libmpv answer means for the viewer.
///
/// MpvLink calls the engine stuck when one property call has not come back
/// for four seconds. That alone is not a dead engine: a hardware decoder
/// being set up for a large camera video, or a busy phone, can hold libmpv's
/// lock that long while the film plays on — and the viewer was shown
/// "The player stopped responding on this file. It may be damaged…" over a
/// local video that was playing perfectly (owner's screenshot, 12 Nov 2026).
///
/// So the film's own clock decides. It comes from libmpv's events, not from
/// the call that is hanging: a clock that moves is an engine that works.
enum EngineVerdict {
  /// Not enough seen yet: look again shortly.
  wait,

  /// The film moved while the call hung: slow, not dead. Say nothing.
  alive,

  /// It should have moved and did not, or a paused engine has not answered
  /// for long: say so, and offer Retry.
  stuck,
}

/// An engine whose calls can hang (libmpv, through MpvLink). The player
/// watches one ([EngineVerdict], every 750 ms) while a call hangs; a test's
/// fake engine implements it to hang on purpose (13 Nov: the check had no
/// test that drove it).
abstract interface class SlowEngine {
  /// True while a call has not come back (MpvLink's 4 s), false again when
  /// it does.
  Stream<bool> get engineWedgedChanges;
  bool get engineWedged;

  /// The call that hangs, for the trail.
  String? get engineWedgedReason;

  /// Listen to the engine anew (once a film, when it moves on regardless).
  void relink();
}

/// How long a playing film may stand still while a call hangs before the
/// engine is called stuck.
const Duration kStuckWhilePlaying = Duration(seconds: 3);

/// How long a call may hang on a paused engine (whose clock says nothing)
/// before it is called stuck. An idle core answers at once.
const Duration kStuckWhilePaused = Duration(seconds: 8);

/// [moved]: how far the film's clock went since the call was found hanging;
/// [playing]: whether it was meant to move; [waited]: how long since then.
EngineVerdict judgeSlowEngine({
  required Duration moved,
  required bool playing,
  required Duration waited,
}) {
  if (moved.abs() >= const Duration(milliseconds: 400)) {
    return EngineVerdict.alive;
  }
  if (playing) {
    return waited >= kStuckWhilePlaying ? EngineVerdict.stuck : EngineVerdict.wait;
  }
  return waited >= kStuckWhilePaused ? EngineVerdict.stuck : EngineVerdict.wait;
}
