// The stream proxy's arithmetic for sealed objects (media seal v1) against the
// shared vectors (test/fixtures/media_seal_vectors.json; Google Tink opens them, see
// tool/media_seal_test.py) and against itself at every boundary.

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal_layout.dart';

void main() {
  test('sealed sizes match the reference vectors', () {
    final vectors = (jsonDecode(File('test/fixtures/media_seal_vectors.json').readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    expect(vectors, hasLength(9));
    for (final v in vectors) {
      final n = v['plain_size'] as int;
      expect(MediaSealLayout.sealedSize(n), v['sealed_size'], reason: 'size $n');
      expect(MediaSealLayout.plainSize(v['sealed_size'] as int), n, reason: 'back $n');
    }
  });

  test('sizes invert at every boundary and past 4 GB', () {
    final r = Random(3);
    final sizes = <int>[0, 1, MediaSealLayout.firstPlain - 1, MediaSealLayout.firstPlain, MediaSealLayout.firstPlain + 1];
    for (var k = 1; k < 6; k++) {
      final b = MediaSealLayout.firstPlain + k * MediaSealLayout.plainSegment;
      sizes.addAll([b - 1, b, b + 1]);
    }
    for (var i = 0; i < 500; i++) {
      sizes.add(r.nextInt(1 << 32) * 2 + r.nextInt(2)); // up to 8 GB
    }
    for (final n in sizes) {
      expect(MediaSealLayout.plainSize(MediaSealLayout.sealedSize(n)), n, reason: 'size $n');
    }
    expect(MediaSealLayout.plainSize(MediaSealLayout.header + MediaSealLayout.tag - 1), isNull);
    for (var i = 1; i < 60; i++) {
      expect(MediaSealLayout.sealedStart(i), i * MediaSealLayout.segment);
    }
  });

  test('a byte range maps to the whole segments that hold it', () {
    const total = MediaSealLayout.firstPlain + 9 * MediaSealLayout.plainSegment + 123;
    final r = Random(11);
    for (var k = 0; k < 2000; k++) {
      final a = r.nextInt(total);
      final b = min(total - 1, a + [0, 1, 65519, 65520, 65521, 400000][k % 6]);
      final s = MediaSealLayout.spanFor(a, b, total);
      // The first segment holds a; the last holds b; nothing outside them.
      expect(MediaSealLayout.plainStart(s.first) <= a, isTrue);
      expect(a < MediaSealLayout.plainStart(s.first + 1), isTrue);
      expect(MediaSealLayout.plainStart(s.last) <= b, isTrue);
      final lastEnd = s.last + 1 < MediaSealLayout.segmentCount(total)
          ? MediaSealLayout.plainStart(s.last + 1)
          : total;
      expect(b < lastEnd, isTrue);
      expect(s.start, MediaSealLayout.sealedStart(s.first));
      expect(s.skipFor(a), a - MediaSealLayout.plainStart(s.first));
      // Opened, the run is its sealed length less one tag per segment.
      final opened = (s.end - s.start) - (s.last - s.first + 1) * MediaSealLayout.tag;
      expect(opened, (s.last + 1 < MediaSealLayout.segmentCount(total) ? MediaSealLayout.plainStart(s.last + 1) : total) -
          MediaSealLayout.plainStart(s.first));
    }
    final end = MediaSealLayout.spanFor(total - 1, total - 1, total);
    expect(end.end, MediaSealLayout.sealedSize(total));
    expect(() => MediaSealLayout.spanFor(5, 4, total), throwsRangeError);
    expect(() => MediaSealLayout.spanFor(0, total, total), throwsRangeError);
  });
}
