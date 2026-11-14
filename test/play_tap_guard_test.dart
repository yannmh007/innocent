// One play at a time (14 Nov 2026): a second tap while the first play
// waits for its grant opened a second player over the first.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/playback.dart';

void main() {
  final t0 = DateTime.utc(2026, 11, 14, 8, 29, 1, 700);

  test('a second tap while the first is on its way is refused', () {
    final g = PlayTapGuard();
    expect(g.begin(t0), isTrue);
    expect(g.begin(t0.add(const Duration(milliseconds: 1400))), isFalse);
  });

  test('once the first is on screen, the next tap plays', () {
    final g = PlayTapGuard();
    expect(g.begin(t0), isTrue);
    g.end();
    expect(g.begin(t0.add(const Duration(milliseconds: 1400))), isTrue);
  });

  test('a play that never ends stops nothing after the window', () {
    final g = PlayTapGuard();
    expect(g.begin(t0), isTrue);
    expect(g.begin(t0.add(PlayTapGuard.window - const Duration(milliseconds: 1))),
        isFalse);
    expect(g.begin(t0.add(PlayTapGuard.window)), isTrue);
  });
}
