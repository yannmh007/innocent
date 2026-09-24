import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/seek_math.dart';

void main() {
  group('clampSeekTarget', () {
    test('an ordinary forward skip lands where it was asked to', () {
      expect(
        clampSeekTarget(
          current: const Duration(minutes: 3),
          delta: const Duration(seconds: 10),
          duration: const Duration(minutes: 90),
        ),
        const Duration(minutes: 3, seconds: 10),
      );
    });

    test('a backward skip past the start lands on the start', () {
      expect(
        clampSeekTarget(
          current: const Duration(seconds: 4),
          delta: const Duration(seconds: -10),
          duration: const Duration(minutes: 90),
        ),
        Duration.zero,
      );
    });

    test('a forward skip past the end lands on the end', () {
      expect(
        clampSeekTarget(
          current: const Duration(minutes: 89, seconds: 55),
          delta: const Duration(seconds: 10),
          duration: const Duration(minutes: 90),
        ),
        const Duration(minutes: 90),
      );
    });

    // THE BUG. A duration of zero means "not known yet", which is what every
    // file reports for the first moments after it is opened, and what a live
    // stream reports for ever. Clamping against it sent a forward skip to the
    // start of the film.
    test('an unknown duration does not drag a forward skip to zero', () {
      expect(
        clampSeekTarget(
          current: const Duration(seconds: 30),
          delta: const Duration(seconds: 10),
          duration: Duration.zero,
        ),
        const Duration(seconds: 40),
      );
    });

    test('an unknown duration still refuses a negative position', () {
      expect(
        clampSeekTarget(
          current: const Duration(seconds: 3),
          delta: const Duration(seconds: -10),
          duration: Duration.zero,
        ),
        Duration.zero,
      );
    });

    test('a negative duration is treated as unknown, not as a ceiling', () {
      expect(
        clampSeekTarget(
          current: const Duration(seconds: 30),
          delta: const Duration(seconds: 10),
          duration: const Duration(seconds: -1),
        ),
        const Duration(seconds: 40),
      );
    });

    test('landing exactly on the end is allowed', () {
      expect(
        clampSeekTarget(
          current: const Duration(minutes: 89, seconds: 50),
          delta: const Duration(seconds: 10),
          duration: const Duration(minutes: 90),
        ),
        const Duration(minutes: 90),
      );
    });

    test('a zero delta is the identity', () {
      expect(
        clampSeekTarget(
          current: const Duration(seconds: 42),
          delta: Duration.zero,
          duration: const Duration(minutes: 90),
        ),
        const Duration(seconds: 42),
      );
    });
  });
}
