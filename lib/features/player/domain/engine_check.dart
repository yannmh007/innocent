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
