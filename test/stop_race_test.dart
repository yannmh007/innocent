// A screen's stop never ends the next screen's film (14 Nov 2026).
//
// The screen checks the open generation before it stops the player as it
// closes (PlayerScreen.dispose), but the stop pauses first and the pause is
// awaited: the next screen's open (an Up next whose answer was asked ahead, a
// quick second play) could start inside it, and the stop then ended the new
// film — on the ladder it also unbound the new film's listeners and stopped
// its ExoPlayer (MediaKitPlayerService._leaveLadder). The stop now looks
// again after the pause.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

const _phone = Phone('360x800', 360, 800, 2.0);

/// An engine whose pause takes as long as the test says.
class _SlowPause extends FakePlayerService {
  Completer<void>? gate;

  @override
  Future<void> pause() async {
    await super.pause();
    final g = gate;
    if (g != null) await g.future;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
      'a stop overtaken by a newer video during its pause stops nothing',
      (WidgetTester tester) async {
    final engine = _SlowPause();
    await pumpPlayer(tester,
        phone: _phone, landscape: false, lang: 'en', engine: engine);
    final c = playerContainer!.read(playerControllerProvider.notifier);

    engine
      ..gate = Completer<void>()
      ..calls.clear();
    final stopping = c.stopPlayback();
    await tester.pump();
    expect(engine.calls, <String>['pause']);
    // The next screen's open begins while the pause is on its way.
    c.openGeneration++;
    engine.gate!.complete();
    await stopping;
    expect(engine.calls, isNot(contains('stop')),
        reason: "the newer video's engine was stopped");

    // No newer video: the stop stops.
    engine
      ..gate = null
      ..calls.clear();
    await c.stopPlayback();
    expect(engine.calls, <String>['pause', 'stop']);
    await leavePlayer(tester);
  });
}
