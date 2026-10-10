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

    test('a downgrade from the only rung returns that rung, and the caller '
        'must notice it did not change', () {
      // The player treats "same url back" as "there is nothing smaller" and
      // does not reopen. That contract lives across two files, so it is
      // pinned here: with one rung, a ceiling at its own bitrate returns it.
      final one = [r(360, 600)];
      final got = pickRendition(one, measuredKbps: 5000, ceilingKbps: 600);
      expect(got!.url, 'u360');
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

  group('chooseRendition — the viewer\'s choice in the Quality menu', () {
    test('Auto is the measured rule, unchanged', () {
      expect(chooseRendition(ladder, 'auto', measuredKbps: 20000)!.height, 1080);
      expect(chooseRendition(ladder, 'auto')!.height, 720);
    });

    test('Original means the master, even on a slow link', () {
      // The whole point of the choice: somebody on good wifi who wants the
      // film exactly as it was uploaded.
      expect(chooseRendition(ladder, 'original', measuredKbps: 500), isNull);
    });

    test('a fixed height is that rung, whatever was measured', () {
      expect(chooseRendition(ladder, '1080', measuredKbps: 500)!.height, 1080);
      expect(chooseRendition(ladder, '360', measuredKbps: 50000)!.height, 360);
    });

    test('a height this film lacks is the nearest BELOW, never heavier', () {
      // Chose 1080p on another film; this one tops out at 720p.
      final small = [r(360, 600), r(720, 2000)];
      expect(chooseRendition(small, '1080')!.height, 720);
      // Chose 480p to save data: 360p, not 720p.
      expect(chooseRendition(small, '480')!.height, 360);
      // Everything above the choice: the smallest is the closest.
      expect(chooseRendition([r(720, 2000), r(1080, 3800)], '480')!.height, 720);
    });

    test('no ladder: there is only the original', () {
      expect(chooseRendition(const [], '720'), isNull);
      expect(chooseRendition(const [], 'auto'), isNull);
    });

    test('anything unreadable in storage is Auto, never a crash', () {
      expect(QualityChoice.normalise(null), 'auto');
      expect(QualityChoice.normalise(''), 'auto');
      expect(QualityChoice.normalise('banana'), 'auto');
      expect(QualityChoice.normalise('-5'), 'auto');
      expect(QualityChoice.normalise('720'), '720');
      expect(QualityChoice.normalise('original'), 'original');
      expect(chooseRendition(ladder, 'banana')!.height, 720);
    });
  });

  group('qualityMenuFor', () {
    test('Auto, every rung from the top, then Original', () {
      final m = qualityMenuFor(ladder, originalHeight: 2160);
      expect(m.map((o) => o.id).toList(),
          ['auto', '1080', '720', '480', '360', 'original']);
      expect(m.last.detail, '4K');
      expect(m[1].label, '1080p');
      expect(m[1].detail, '3.8 Mbps');
    });

    test('no ladder, no menu — one copy has nothing to choose between', () {
      expect(qualityMenuFor(const []), isEmpty);
    });

    test('two rungs of one height are one line', () {
      final m = qualityMenuFor([r(720, 2000), r(720, 2100), r(360, 600)]);
      expect(m.where((o) => o.id == '720').length, 1);
    });
  });

  group('data saver — Auto capped at 480p', () {
    final ladder = [r(240, 360), r(360, 700), r(480, 1000), r(720, 2000), r(1080, 3800)];

    test('a fast line still gets no more than 480p while saving', () {
      expect(pickRendition(ladder, measuredKbps: 50000, maxHeight: kDataSaverMaxHeight)!.height, 480);
      expect(chooseRendition(ladder, 'auto', measuredKbps: 50000, maxHeight: 480)!.height, 480);
    });

    test('a slow line is still matched to what it carries', () {
      expect(pickRendition(ladder, measuredKbps: 700, maxHeight: 480)!.height, 240);
    });

    test('a height picked by hand is not capped', () {
      expect(chooseRendition(ladder, '720', measuredKbps: 50000, maxHeight: 480)!.height, 720);
    });

    test('a ladder that starts above the cap gives its smallest rung', () {
      expect(pickRendition([r(720, 2000), r(1080, 3800)], measuredKbps: 50000, maxHeight: 480)!.height, 720);
    });

    test('the 240p rung serves a 0.6 Mbps line that 360p would stall on', () {
      expect(pickRendition(ladder, measuredKbps: 600)!.height, 240);
    });
  });
}
