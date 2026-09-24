import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/range_set.dart';

void main() {
  group('RangeSet', () {
    test('an empty set holds nothing and admits it', () {
      final s = RangeSet();
      expect(s.isEmpty, isTrue);
      expect(s.bytes, 0);
      // The safe answer: "starting here, none". A caller cannot misread it.
      expect(s.contiguousEndFrom(0), 0);
      expect(s.covers(0, 1), isFalse);
    });

    test('adjacent ranges merge into one run', () {
      // THE CASE THAT MATTERS MOST. Two writes that meet exactly describe one
      // unbroken run; left as two entries the server would re-fetch from the
      // network at every boundary, forever.
      final s = RangeSet()
        ..add(0, 10)
        ..add(10, 20);
      expect(s.ranges.length, 1);
      expect(s.contiguousEndFrom(0), 20);
      expect(s.bytes, 20);
    });

    test('overlapping ranges merge and are not double-counted', () {
      final s = RangeSet()
        ..add(0, 100)
        ..add(50, 150);
      expect(s.ranges.length, 1);
      expect(s.bytes, 150);
    });

    test('a hole is never reported as held', () {
      // A sparse file reads a hole back as zeros — not an error, not a short
      // read, just silence. If this ever says the hole is held, the viewer
      // gets a green screen and the player cannot tell why.
      final s = RangeSet()
        ..add(0, 100)
        ..add(200, 300);
      expect(s.contiguousEndFrom(0), 100);
      expect(s.contiguousEndFrom(100), 100);
      expect(s.contiguousEndFrom(150), 150);
      expect(s.covers(0, 101), isFalse);
      expect(s.covers(0, 100), isTrue);
      expect(s.covers(200, 300), isTrue);
      expect(s.bytes, 200);
    });

    test('a range added out of order lands in the right place', () {
      final s = RangeSet()
        ..add(300, 400)
        ..add(0, 100)
        ..add(150, 200);
      expect(s.toString(), '0-100,150-200,300-400');
    });

    test('a range that bridges two islands joins all three', () {
      final s = RangeSet()
        ..add(0, 100)
        ..add(200, 300)
        ..add(100, 200);
      expect(s.ranges.length, 1);
      expect(s.contiguousEndFrom(0), 300);
    });

    test('an empty or backwards range is ignored, not stored', () {
      final s = RangeSet()
        ..add(10, 10)
        ..add(20, 5)
        ..add(-5, 3);
      expect(s.isEmpty, isTrue);
    });

    test('covers of an empty span is vacuously true', () {
      expect(RangeSet().covers(5, 5), isTrue);
    });

    test('firstGapFrom finds where the network is needed again', () {
      final s = RangeSet()
        ..add(0, 100)
        ..add(200, 300);
      expect(s.firstGapFrom(0, 300), 100);
      expect(s.firstGapFrom(200, 300), isNull);
      expect(s.firstGapFrom(200, 400), 300);
    });

    test('json survives a round trip exactly', () {
      final s = RangeSet()
        ..add(0, 100)
        ..add(200, 300);
      final back = RangeSet(s.toJson());
      expect(back.toString(), s.toString());
      expect(back.bytes, s.bytes);
    });

    test('a malformed json row is dropped rather than trusted', () {
      // Metadata is read back from a file a crash may have truncated. A row
      // that is not a pair is not a range, and guessing at it would put a
      // hole in the map of what is held.
      final s = RangeSet(<List<int>>[
        <int>[0, 100],
        <int>[5],
        <int>[],
      ]);
      expect(s.toString(), '0-100');
    });
  });
}
