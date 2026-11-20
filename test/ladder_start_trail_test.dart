import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/playback_log.dart';
import 'package:innocent/features/video_hub/data/cache/ladder_start_trail.dart';

void main() {
  setUp(() {
    LadderStartTrail.resetForTest();
    PlaybackLog.clear();
  });

  test(
      'a start is kept in ms from the registration, first of each kind in its line',
      () {
    LadderStartTrail.begin();
    LadderStartTrail.mark('480p index');
    LadderStartTrail.mark('480p segment asked');
    LadderStartTrail.mark('480p segment asked');
    LadderStartTrail.firstSegmentIn();
    LadderStartTrail.firstSegmentIn();
    final lines = PlaybackLog.text
        .split('\n')
        .where((l) => l.contains('hls start'))
        .toList();
    expect(lines, hasLength(1));
    expect(lines.single, contains('480p index '));
    expect(RegExp('segment asked').allMatches(lines.single), hasLength(1));
    expect(LadderStartTrail.at('480p index'), isNotNull);
  });

  test('nothing is kept before a ladder registers', () {
    LadderStartTrail.mark('master asked');
    expect(LadderStartTrail.active, isFalse);
    expect(LadderStartTrail.at('master asked'), isNull);
    LadderStartTrail.firstSegmentIn();
    expect(PlaybackLog.text, isNot(contains('hls start')));
  });
}
