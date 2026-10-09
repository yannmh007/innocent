// Auto steps back UP a rung mid-film only on evidence: enough buffered to
// spend on a reopen, quiet since the last switch and the last stall, a minute
// between asks, three climbs a film at most.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/domain/climb_rule.dart';
import 'package:innocent/features/video_hub/domain/rendition.dart';

void main() {
  bool allows({
    int open = 120,
    int? sw,
    int? stall,
    int? tried,
    double? buffered = 20,
    int climbs = 0,
  }) =>
      ClimbRule.allows(
        sinceOpen: Duration(seconds: open),
        sinceSwitch: sw == null ? null : Duration(seconds: sw),
        sinceStall: stall == null ? null : Duration(seconds: stall),
        sinceTry: tried == null ? null : Duration(seconds: tried),
        bufferedSeconds: buffered,
        climbs: climbs,
      );

  test('a settled film with a full buffer may climb', () {
    expect(allows(), isTrue);
  });

  test('not in the first half-minute: the start is a burst, not the link', () {
    expect(allows(open: 20), isFalse);
    expect(allows(open: 30), isTrue);
  });

  test('a reopen spends the buffer, so it must be there', () {
    expect(allows(buffered: 10), isFalse);
    expect(allows(buffered: null), isFalse);
    expect(allows(buffered: 15), isTrue);
  });

  test('quiet after a switch and after a stall', () {
    expect(allows(sw: 30), isFalse);
    expect(allows(sw: 61), isTrue);
    expect(allows(stall: 60), isFalse);
    expect(allows(stall: 91), isTrue);
  });

  test('a minute between asks, three climbs a film', () {
    expect(allows(tried: 20), isFalse);
    expect(allows(tried: 61), isTrue);
    expect(allows(climbs: 3), isFalse);
    expect(allows(climbs: 2), isTrue);
  });

  group('the first copy, nothing measured', () {
    final ladder = <Rendition>[
      const Rendition(height: 360, kbps: 612, url: 'a'),
      const Rendition(height: 480, kbps: 912, url: 'b'),
      const Rendition(height: 720, kbps: 1684, url: 'c'),
    ];

    test('on Wi-Fi it opens near 720p, on mobile data at 480p', () {
      expect(pickRendition(ladder)!.height, 720);
      expect(pickRendition(ladder, defaultHeight: kMeteredStartHeight)!.height, 480);
    });

    test('a measurement wins over the starting guess', () {
      expect(pickRendition(ladder, measuredKbps: 5000, defaultHeight: 480)!.height, 720);
    });
  });
}
