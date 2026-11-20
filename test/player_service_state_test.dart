// What the player service keeps between files and around a scrub (14 Nov
// 2026), without an engine: no libmpv or ExoPlayer is started here.
//
//   * A STALE START. A libmpv open after ExoPlayer films read "open began at
//     650s, not 491s - jumping there": the position and length were the
//     ladder film's, which libmpv's idle player never writes over until the
//     new file reports its own, and the start check (_confirmStart) believed
//     them — a needless seek inside the open, and a resume save that could
//     write 650 s against the new film.
//   * A SCRUB'S END. Leaving ExoPlayer's scrubbing mode refills for 25-106 ms
//     with a minute in hand; a drag held still left its last seek outside the
//     player's 2 s jump window, so the refill was counted a blip of a film
//     playing on. The end of a scrub is the viewer's jump.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/media_kit_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a libmpv open forgets the film before it', () async {
    final s = MediaKitPlayerService()
      ..debugLadderPlayed(
          position: const Duration(seconds: 650),
          duration: const Duration(minutes: 90));
    expect(s.position, const Duration(seconds: 650));
    try {
      // No engine here: the open fails once it reaches libmpv, after the
      // part under test.
      await s.open('http://127.0.0.1:9/one-rung.mp4',
          startAt: const Duration(seconds: 491));
    } catch (_) {}
    expect(s.position, Duration.zero,
        reason: "the start check would read the ladder film's 650 s");
    expect(s.duration, Duration.zero);
  });

  test("a scrub's end starts the jump clock, as a seek does", () async {
    final s = MediaKitPlayerService();
    expect(s.sinceLastSeek, isNull);
    await s.setPreciseSeek(false); // a drag begins
    expect(s.sinceLastSeek, isNull, reason: 'nothing has jumped yet');
    await s.setPreciseSeek(true); // and ends
    expect(s.sinceLastSeek, isNotNull);
    expect(s.sinceLastSeek!, lessThan(const Duration(seconds: 1)));
  });

  test("ExoPlayer's scrubbing mode closed by the play button: the same",
      () async {
    final s = MediaKitPlayerService();
    await s.setScrubbing(true);
    expect(s.sinceLastSeek, isNull);
    await s.setScrubbing(false);
    expect(s.sinceLastSeek, isNotNull);
  });

  test('no scrub open, no jump: a fresh precise-seek setting is not one',
      () async {
    final s = MediaKitPlayerService();
    await s.setPreciseSeek(true);
    await s.setScrubbing(false);
    expect(s.sinceLastSeek, isNull);
  });
}
