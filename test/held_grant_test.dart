import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/held_grant.dart';
import 'package:innocent/features/video_hub/domain/rendition.dart';

void main() {
  final now = DateTime.utc(2026, 10, 22, 12);
  PlaybackGrant granted({DateTime? expiresAt, bool ladder = true}) =>
      PlaybackGrant.granted('https://cdn.example/top',
          expiresAt: expiresAt,
          renditions: ladder
              ? const <Rendition>[
                  Rendition(height: 240, kbps: 300, url: 'https://cdn.example/240'),
                  Rendition(height: 720, kbps: 1700, url: 'https://cdn.example/720'),
                ]
              : const <Rendition>[]);

  test('a young grant with a ladder is chosen from again', () {
    final h = HeldGrant(granted(expiresAt: now.add(const Duration(minutes: 10))));
    expect(h.reusable(now: now), isTrue);
  });

  test('a grant held past four minutes is asked for again', () {
    final h = HeldGrant(granted(), age: HeldGrant.reuseFor);
    expect(h.reusable(now: now), isFalse);
    expect(HeldGrant(granted(), age: const Duration(minutes: 3)).reusable(now: now),
        isTrue);
  });

  test('one asked ahead of the tap counts its forty seconds', () {
    final h = HeldGrant(granted(), age: const Duration(seconds: 40));
    expect(h.age, greaterThanOrEqualTo(const Duration(seconds: 40)));
  });

  test("the phone's clock may only say no", () {
    // Nearly out by the phone's clock: asked again.
    expect(
        HeldGrant(granted(expiresAt: now.add(const Duration(seconds: 90))))
            .reusable(now: now),
        isFalse);
    // Already out by a clock running fast: asked again.
    expect(
        HeldGrant(granted(expiresAt: now.subtract(const Duration(minutes: 3))))
            .reusable(now: now),
        isFalse);
    // A clock running slow reads hours left; the stopwatch still decides.
    expect(
        HeldGrant(granted(expiresAt: now.add(const Duration(hours: 5))),
                age: const Duration(minutes: 5))
            .reusable(now: now),
        isFalse);
  });

  test('a refusal, or a title with one copy, is never reused', () {
    expect(HeldGrant(const PlaybackGrant.denied(AccessDenial.needsPremium))
        .reusable(now: now), isFalse);
    expect(HeldGrant(granted(ladder: false)).reusable(now: now), isFalse);
  });
}
