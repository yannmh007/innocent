// One play at a time (14 Nov 2026): a second tap while the first play
// waits for its grant opened a second player over the first.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/playback.dart';

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  test('a second tap while the first is on its way is refused', () {
    final g = PlayTapGuard();
    expect(g.begin(Duration.zero), isNotNull);
    expect(g.begin(_ms(1400)), isNull);
  });

  test('once the first is on screen, the next tap plays', () {
    final g = PlayTapGuard();
    final a = g.begin(Duration.zero)!;
    g.end(a);
    expect(g.begin(_ms(1400)), isNotNull);
  });

  test('a play that never ends stops nothing after the window', () {
    final g = PlayTapGuard();
    expect(g.begin(Duration.zero), isNotNull);
    expect(g.begin(PlayTapGuard.window - _ms(1)), isNull);
    expect(g.begin(PlayTapGuard.window), isNotNull);
  });

  test("an older play's end leaves a newer play's window alone", () {
    final g = PlayTapGuard();
    final a = g.begin(Duration.zero)!;
    // A's grant is slower than the window: B is let through at 11 s.
    final b = g.begin(_ms(11000))!;
    g.end(a);
    // C, a moment later, while B is still on its way: refused.
    expect(g.begin(_ms(12000)), isNull);
    g.end(b);
    expect(g.begin(_ms(12500)), isNotNull);
  });

  test('without a time given, its own clock: a tap at once is refused', () {
    final g = PlayTapGuard();
    expect(g.begin(), isNotNull);
    expect(g.begin(), isNull);
  });
}
