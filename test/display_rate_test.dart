// P3 (27 Nov 2026, docs/handoff_2026_11_27_beyond_mx.md): the display's
// highest rate only while a finger is on the screen and the fling after
// it — one ask per change, never one per pointer event.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/display/display_rate.dart';

void main() {
  late List<bool> sent;
  setUp(() {
    DisplayRate.reset();
    sent = <bool>[];
    DisplayRate.send = sent.add;
  });
  tearDown(DisplayRate.reset);

  testWidgets('a tap asks once, and lets go after the hold', (t) async {
    DisplayRate.pointerDown();
    expect(sent, [true]);
    DisplayRate.pointerUp();
    await t.pump(DisplayRate.hold - const Duration(milliseconds: 1));
    expect(sent, [true]);
    expect(DisplayRate.touching, isTrue);
    await t.pump(const Duration(milliseconds: 2));
    expect(sent, [true, false]);
    expect(DisplayRate.touching, isFalse);
  });

  testWidgets('taps in quick succession keep it up: no ask, no let-go between', (t) async {
    for (var i = 0; i < 5; i++) {
      DisplayRate.pointerDown();
      await t.pump(const Duration(milliseconds: 80));
      DisplayRate.pointerUp();
      await t.pump(const Duration(milliseconds: 600));
    }
    expect(sent, [true]);
    await t.pump(DisplayRate.hold);
    expect(sent, [true, false]);
  });

  testWidgets('two fingers: the rate stays until the last lifts', (t) async {
    DisplayRate.pointerDown();
    DisplayRate.pointerDown();
    DisplayRate.pointerUp();
    await t.pump(DisplayRate.hold * 2);
    expect(sent, [true]);
    DisplayRate.pointerUp();
    await t.pump(DisplayRate.hold);
    expect(sent, [true, false]);
  });

  testWidgets('a stray lift (a cancel after the up) does no harm', (t) async {
    DisplayRate.pointerUp();
    await t.pump(DisplayRate.hold);
    expect(sent, isEmpty);
    DisplayRate.pointerDown();
    DisplayRate.pointerUp();
    DisplayRate.pointerUp();
    await t.pump(DisplayRate.hold);
    expect(sent, [true, false]);
  });
}
