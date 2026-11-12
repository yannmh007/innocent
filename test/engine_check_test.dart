// A hanging libmpv call against the film's own clock
// (lib/features/player/domain/engine_check.dart).
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/domain/engine_check.dart';

void main() {
  const ms = Duration(milliseconds: 1);

  test('the film moving while a call hangs is a live engine: no error', () {
    expect(
        judgeSlowEngine(moved: ms * 900, playing: true, waited: ms * 800),
        EngineVerdict.alive);
    // However long the call has hung.
    expect(
        judgeSlowEngine(moved: ms * 5000, playing: true, waited: ms * 9000),
        EngineVerdict.alive);
  });

  test('a playing film standing still is a stuck engine, after 3 s', () {
    expect(judgeSlowEngine(moved: Duration.zero, playing: true, waited: ms * 1500),
        EngineVerdict.wait);
    expect(
        judgeSlowEngine(moved: Duration.zero, playing: true, waited: kStuckWhilePlaying),
        EngineVerdict.stuck);
  });

  test('paused, the clock says nothing: stuck only after 8 s', () {
    expect(judgeSlowEngine(moved: Duration.zero, playing: false, waited: ms * 5000),
        EngineVerdict.wait);
    expect(
        judgeSlowEngine(moved: Duration.zero, playing: false, waited: kStuckWhilePaused),
        EngineVerdict.stuck);
  });

  test('a jump back while it hangs is movement too', () {
    expect(judgeSlowEngine(moved: ms * -10000, playing: true, waited: ms * 4000),
        EngineVerdict.alive);
  });
}
