// The first frame of a libmpv playback is its first picture (14 Nov 2026).
//
// THE BUG. On the owner's phone every libmpv open read 32-43 ms to a picture
// and then a stall of 881-1559 ms: media_kit's open() stops the file before
// it and says "not buffering" as it resets, 30 ms in, before a byte of the
// new one, and the controller took that for the end of the black screen.
// The real wait was then counted as a "rebuffer" — so the summary's open_ms
// was wrong and frozen time a minute, the number to lower, was wrong for
// every libmpv playback. The engine here opens as libmpv does
// (FakePlayerService pictureOnOpen: false): "not buffering" and the start at
// once, then the wait, then the picture. The controller's clocks are real,
// so the wait is a real 900 ms.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_player_service.dart';
import 'support/player_harness.dart';

const _phone = Phone('360x800', 360, 800, 2.0);

Map<String, dynamic> _summary() => playerContainer!
    .read(playerControllerProvider.notifier)
    .qoe
    .toMeta(DateTime.now());

Future<void> _realWait(WidgetTester tester, int ms) =>
    tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
      'libmpv: "not buffering" at the open is not a picture; the open is '
      'the wait, not a stall', (WidgetTester tester) async {
    final engine = FakePlayerService(pictureOnOpen: false);
    await pumpPlayer(tester,
        phone: _phone, landscape: false, lang: 'en', engine: engine);
    expect(_summary().containsKey('open_ms'), isFalse,
        reason: 'no picture yet: still opening');

    // The demuxer waits for bytes.
    engine.buffer(true);
    await tester.pump();
    await _realWait(tester, 900);
    // The bytes are in: the decoder's first picture, and enough to play.
    engine.showPicture();
    engine.buffer(false);
    await tester.pump();

    final m = _summary();
    expect(m['open_ms'], greaterThanOrEqualTo(850), reason: '$m');
    expect(m['engine'], 'mpv');
    expect(m['stalls'], 0, reason: 'the open was counted as a stall: $m');
    expect(m['frozen_ms'], 0, reason: '$m');
    await leavePlayer(tester);
  });

  testWidgets(
      'libmpv: the start it was given is not playback; a position that '
      'moves is', (WidgetTester tester) async {
    final engine = FakePlayerService(pictureOnOpen: false);
    await pumpPlayer(tester,
        phone: _phone, landscape: false, lang: 'en', engine: engine);
    // The resume point, reported before a frame (open() already did), then
    // a jump the viewer asked for: neither is playback.
    engine.playTo(const Duration(minutes: 47));
    await tester.pump();
    expect(_summary().containsKey('open_ms'), isFalse);
    await _realWait(tester, 300);
    // Playing: a quarter of a second further on.
    engine.playTo(const Duration(minutes: 47, milliseconds: 250));
    await tester.pump();
    expect(_summary()['open_ms'], greaterThanOrEqualTo(250));
    await leavePlayer(tester);
  });

  testWidgets('a file on the phone: its picture is there at once',
      (WidgetTester tester) async {
    await pumpPlayer(tester, phone: _phone, landscape: false, lang: 'en');
    final m = _summary();
    expect(m['open_ms'], isNotNull, reason: '$m');
    expect(m['open_ms'], lessThan(850));
    expect(m['stalls'], 0);
    await leavePlayer(tester);
  });
}
