import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/rendition.dart';

Rendition r(int h, int k) => Rendition(height: h, kbps: k, url: 'u$h');

final ladder = [r(360, 600), r(480, 1000), r(720, 2000), r(1080, 3800)];

void main() {
  group('pickRendition', () {
    test('no ladder means play the original', () {
      expect(pickRendition(const []), isNull);
    });

    test('no measurement opens near 720p, never above it', () {
      // The first play of the first film on a new install. Guessing high is
      // how the stutter this pipeline exists to end gets shown to someone on
      // their very first impression of the app.
      expect(pickRendition(ladder)!.height, 720);
    });

    test('a fast link gets the best rung', () {
      // 20 Mbps measured; 60% of it is 12 Mbps and 1080p asks 3.8.
      expect(pickRendition(ladder, measuredKbps: 20000)!.height, 1080);
    });

    test('headroom is real: a link that exactly equals a rung does not get '
        'that rung', () {
      // 3800 measured against a 3800 rung. Taking it guarantees a stall on
      // the first dip, which is the whole failure being designed out.
      final got = pickRendition(ladder, measuredKbps: 3800)!;
      expect(got.height, lessThan(1080));
      expect(got.kbps, lessThanOrEqualTo((3800 * kBandwidthHeadroom).round()));
    });

    test('a slow link gets the smallest rung rather than nothing', () {
      // Worse than 360p. Playing badly beats refusing to play.
      expect(pickRendition(ladder, measuredKbps: 200)!.height, 360);
    });

    test('a ceiling drops exactly one rung', () {
      // How a downgrade after a measured network stall is expressed: the
      // failing rung's own bitrate becomes the ceiling.
      final got = pickRendition(ladder, measuredKbps: 20000, ceilingKbps: 3800);
      expect(got!.height, 720);
    });

    test('a ceiling below everything still returns the smallest rung, never '
        'null', () {
      // Null means "play the original", and the original is the MOST
      // expensive copy there is. A downgrade that falls through to it would
      // make a stall worse, which is how this would have shipped wrong.
      final got = pickRendition(ladder, measuredKbps: 100, ceilingKbps: 100);
      expect(got, isNotNull);
      expect(got!.height, 360);
    });

    test('an unsorted ladder is handled', () {
      final jumbled = [r(1080, 3800), r(360, 600), r(720, 2000)];
      expect(pickRendition(jumbled, measuredKbps: 20000)!.height, 1080);
      expect(pickRendition(jumbled, measuredKbps: 1500)!.height, 360);
    });

    test('a zero or negative measurement is treated as no measurement', () {
      expect(pickRendition(ladder, measuredKbps: 0)!.height, 720);
      expect(pickRendition(ladder, measuredKbps: -1)!.height, 720);
    });
  });

  group('Rendition.fromJson', () {
    test('a well-formed row parses', () {
      final got = Rendition.fromJson(
          {'height': 720, 'kbps': 2000, 'url': 'https://x/y', 'bytes': 12});
      expect(got!.height, 720);
      expect(got.bytes, 12);
    });

    test('a row with no url or no bitrate is refused, not defaulted', () {
      // A rendition with kbps 0 would divide every bandwidth decision by a
      // number that means "free", and a rung with no url is unplayable.
      expect(Rendition.fromJson({'height': 720, 'kbps': 2000}), isNull);
      expect(Rendition.fromJson({'height': 720, 'kbps': 0, 'url': 'u'}), isNull);
      expect(Rendition.fromJson('nonsense'), isNull);
    });
  });
}
