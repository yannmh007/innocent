import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/widgets/telegram_album_layout.dart';

List<AlbumCell> lay(List<double> r, {double w = 400}) =>
    telegramAlbumLayout(ratios: r, maxWidth: w, minWidth: w * 0.25, spacing: 2);

/// Every cell inside the group's width, none overlapping, and each row's
/// right edge flush with the group's.
void expectSound(List<AlbumCell> cells, double w) {
  for (final c in cells) {
    expect(c.rect.left, greaterThanOrEqualTo(-0.5));
    expect(c.rect.right, lessThanOrEqualTo(w + 0.5));
    expect(c.rect.width, greaterThan(0));
    expect(c.rect.height, greaterThan(0));
  }
  for (var i = 0; i < cells.length; i++) {
    for (var j = i + 1; j < cells.length; j++) {
      final o = cells[i].rect.deflate(0.6).overlaps(cells[j].rect.deflate(0.6));
      expect(o, isFalse, reason: 'cells $i and $j overlap');
    }
  }
  expect(
      cells
          .where((c) => c.sides.right)
          .every((c) => (c.rect.right - w).abs() < 1),
      isTrue);
}

void main() {
  test('two squares sit side by side, equal', () {
    final c = lay([1, 1]);
    expect(c[0].rect.width, c[1].rect.width);
    expect(c[0].rect.top, c[1].rect.top);
    expectSound(c, 400);
  });

  test('two very wide photos stack', () {
    final c = lay([2.0, 1.9]);
    // Two wide photos over 2:1 go to the complex layout: two rows.
    expect(c[1].rect.top, greaterThan(c[0].rect.bottom));
    expectSound(c, 400);
  });

  test('three with a narrow first: a tall left column, two on the right', () {
    final c = lay([0.6, 1, 1]);
    expect(c[0].rect.height, greaterThan(c[1].rect.height));
    expect(c[1].rect.left, c[2].rect.left);
    expect(c[0].sides.toString(), 'LTB');
    expectSound(c, 400);
  });

  test('four with a wide first: a banner over three', () {
    final c = lay([1.6, 1, 1, 1]);
    expect(c[0].rect.width, 400);
    expect(c[1].rect.top, c[3].rect.top);
    expectSound(c, 400);
  });

  test('five to ten fill rows near 4:3 of the width, in order', () {
    for (var n = 5; n <= 10; n++) {
      final ratios = [for (var i = 0; i < n; i++) i.isEven ? 0.75 : 1.33];
      final c = lay(ratios);
      expect(c.length, n);
      expectSound(c, 400);
      final h = c.map((x) => x.rect.bottom).reduce((a, b) => a > b ? a : b);
      expect(h, inInclusiveRange(400 * 4 / 3 * 0.55, 400 * 4 / 3 * 1.45),
          reason: '$n items, height $h');
      // Reading order is kept: each cell starts after the one before it.
      for (var i = 1; i < n; i++) {
        final a = c[i - 1].rect, b = c[i].rect;
        expect(
            b.top > a.top + 0.5 ||
                (b.top - a.top).abs() < 0.5 && b.left > a.left,
            isTrue);
      }
    }
  });

  test('only the outer corners are rounded', () {
    final c = lay([1, 1, 1, 1, 1, 1]);
    final r = c.first.sides.corners(12);
    expect(r.topLeft, const Radius.circular(12));
    expect(r.bottomRight, Radius.zero);
  });

  test('long albums split into even groups of at most ten', () {
    expect(albumGroupSizes(10), [10]);
    expect(albumGroupSizes(11), [6, 5]);
    expect(albumGroupSizes(23), [8, 8, 7]);
    expect(albumGroupSizes(0), isEmpty);
  });

  test('a single item is capped at 4:3 tall', () {
    final c = lay([0.5]);
    expect(c.single.rect.height, closeTo(400 * 4 / 3, 0.01));
  });

  test('any mix of shapes, 1 to 10 items, phone to tablet widths', () {
    final rnd = math.Random(7);
    for (var trial = 0; trial < 3000; trial++) {
      final n = 1 + rnd.nextInt(10);
      final w = [320.0, 360.0, 412.0, 600.0][rnd.nextInt(4)];
      final ratios = [
        for (var i = 0; i < n; i++)
          [0.3, 0.5, 0.5625, 0.75, 1.0, 1.33, 1.78, 2.4, 3.5][rnd.nextInt(9)]
      ];
      final c = lay(ratios, w: w);
      expect(c.length, n, reason: '$ratios');
      for (final x in c) {
        expect(x.rect.width, greaterThan(8), reason: '$ratios @ $w: ${x.rect}');
        expect(x.rect.height, greaterThan(8),
            reason: '$ratios @ $w: ${x.rect}');
        expect(x.rect.right, lessThanOrEqualTo(w + 0.5), reason: '$ratios');
        expect(x.rect.left, greaterThanOrEqualTo(-0.5), reason: '$ratios');
      }
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          expect(
              c[i].rect.deflate(0.6).overlaps(c[j].rect.deflate(0.6)), isFalse,
              reason: '$ratios @ $w: $i ${c[i].rect} / $j ${c[j].rect}');
        }
      }
    }
  });
}
