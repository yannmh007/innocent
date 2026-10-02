import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/media_kit_player_service.dart';

/// Software decoding must leave the UI two cores. On a four-core phone, four
/// decode threads plus libmpv's renderer starved the UI thread: the film kept
/// playing while Android reported the app as not responding (2026-10-02).
void main() {
  test('two cores are always left for the UI, and never more than four threads', () {
    expect(softwareDecodeThreads(1), 1);
    expect(softwareDecodeThreads(2), 1);
    expect(softwareDecodeThreads(3), 1);
    expect(softwareDecodeThreads(4), 2);
    expect(softwareDecodeThreads(6), 4);
    expect(softwareDecodeThreads(8), 4);
    expect(softwareDecodeThreads(12), 4);
  });
}
