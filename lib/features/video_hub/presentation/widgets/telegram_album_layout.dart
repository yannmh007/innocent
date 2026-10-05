import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Which outer edges of the album a tile touches — its outer corners are
/// the ones that get rounded, as in Telegram's bubbles.
class AlbumSides {
  const AlbumSides({
    this.left = false,
    this.top = false,
    this.right = false,
    this.bottom = false,
  });

  final bool left, top, right, bottom;

  /// The rounded corners for a group whose outer radius is [r].
  BorderRadius corners(double r) {
    final rad = Radius.circular(r);
    return BorderRadius.only(
      topLeft: top && left ? rad : Radius.zero,
      topRight: top && right ? rad : Radius.zero,
      bottomLeft: bottom && left ? rad : Radius.zero,
      bottomRight: bottom && right ? rad : Radius.zero,
    );
  }

  @override
  String toString() =>
      '${left ? 'L' : ''}${top ? 'T' : ''}${right ? 'R' : ''}${bottom ? 'B' : ''}';
}

/// One tile's place inside its group.
class AlbumCell {
  const AlbumCell(this.rect, this.sides);
  final Rect rect;
  final AlbumSides sides;
}

/// Telegram's media-group ("album") layout, ported from Telegram Desktop's
/// `ui/grouped_layout.cpp` (Layouter / ComplexLayouter), which Telegram
/// Android's `MessageObject.GroupedMessages.calculate()` mirrors.
/// See docs/telegram_albums.md.
///
/// * Each item is classed by its shape: `w` wide (ratio > 1.2), `n` narrow
///   (< 0.8), `q` square-ish.
/// * Two, three and four items use hand-made layouts chosen by those
///   classes — e.g. two wide photos stack, a narrow first photo of three
///   takes the left column, a wide first of four takes the top row.
/// * Five or more (or any item wider than 2:1) try every split into two,
///   three or four rows of at most three (four in a narrow middle row) and
///   keep the one whose total height is closest to 4/3 of the width,
///   penalising rows thinner than the minimum and rows that hold more items
///   than the row below.
/// * Order is never changed, pictures are cropped to their cell, never
///   stretched.
///
/// [maxWidth] is the group's width; [minWidth] the narrowest a cell should
/// be; [spacing] the gap between cells.
List<AlbumCell> telegramAlbumLayout({
  required List<double> ratios,
  required double maxWidth,
  required double minWidth,
  required double spacing,
}) {
  final count = ratios.length;
  if (count == 0 || maxWidth <= 0) return const [];
  // Degenerate shapes (a 0x0 size, a 40:1 strip) would make the arithmetic
  // below divide by almost nothing; Telegram's inputs are photos.
  final r = [for (final x in ratios) x.isFinite ? x.clamp(0.25, 4.0) : 1.0];
  return _Layouter(r, maxWidth, minWidth, spacing).layout();
}

class _Layouter {
  _Layouter(this.ratios, this.maxWidth, this.minWidth, this.spacing)
      : count = ratios.length,
        maxHeight = maxWidth,
        proportions = ratios
            .map((r) => r > 1.2
                ? 'w'
                : r < 0.8
                    ? 'n'
                    : 'q')
            .join(),
        // As in tdesktop: the sum starts at 1 (so the average leans square).
        averageRatio =
            (ratios.fold<double>(1, (a, b) => a + b)) / ratios.length;

  final List<double> ratios;
  final double maxWidth, minWidth, spacing;
  final int count;
  // "All apps currently use square max size first."
  final double maxHeight;
  final String proportions;
  final double averageRatio;
  double get maxSizeRatio => maxWidth / maxHeight;

  List<AlbumCell> layout() {
    if (count == 1) return _one();
    if (count >= 5 || ratios.any((x) => x > 2)) {
      return _ComplexLayouter(ratios, averageRatio, maxWidth, minWidth, spacing)
          .layout();
    }
    if (count == 2) return _two();
    if (count == 3) return proportions[0] == 'n' ? _threeLeft() : _threeTop();
    return proportions[0] == 'w' ? _fourTop() : _fourLeft();
  }

  static const _all =
      AlbumSides(left: true, top: true, right: true, bottom: true);

  List<AlbumCell> _one() {
    final w = maxWidth;
    // tdesktop draws a single item at its own height; on a full-width
    // phone column a tall portrait would fill two screens, so it is capped
    // at the complex layout's 4:3 and cropped.
    final h = math.min(w / ratios[0], w * 4 / 3);
    return [AlbumCell(Rect.fromLTWH(0, 0, w, h), _all)];
  }

  List<AlbumCell> _two() {
    if (proportions == 'ww' &&
        averageRatio > 1.4 * maxSizeRatio &&
        ratios[1] - ratios[0] < 0.2) {
      // Top and bottom.
      final w = maxWidth;
      final h = math
          .min(
              w / ratios[0], math.min(w / ratios[1], (maxHeight - spacing) / 2))
          .roundToDouble();
      return [
        AlbumCell(Rect.fromLTWH(0, 0, w, h),
            const AlbumSides(left: true, top: true, right: true)),
        AlbumCell(Rect.fromLTWH(0, h + spacing, w, h),
            const AlbumSides(left: true, bottom: true, right: true)),
      ];
    }
    if (proportions == 'ww' || proportions == 'qq') {
      // Side by side, equal widths.
      final w = (maxWidth - spacing) / 2;
      final h = math
          .min(w / ratios[0], math.min(w / ratios[1], maxHeight))
          .roundToDouble();
      return [
        AlbumCell(Rect.fromLTWH(0, 0, w, h),
            const AlbumSides(top: true, left: true, bottom: true)),
        AlbumCell(Rect.fromLTWH(w + spacing, 0, w, h),
            const AlbumSides(top: true, right: true, bottom: true)),
      ];
    }
    // Side by side, widths by shape.
    final minimalWidth = (minWidth * 1.5).roundToDouble();
    final secondWidth = math.min(
        math
            .max(
                0.4 * (maxWidth - spacing),
                (maxWidth - spacing) /
                    ratios[0] /
                    (1 / ratios[0] + 1 / ratios[1]))
            .roundToDouble(),
        maxWidth - spacing - minimalWidth);
    final firstWidth = maxWidth - secondWidth - spacing;
    final h = math.min(
        maxHeight,
        math
            .min(firstWidth / ratios[0], secondWidth / ratios[1])
            .roundToDouble());
    return [
      AlbumCell(Rect.fromLTWH(0, 0, firstWidth, h),
          const AlbumSides(top: true, left: true, bottom: true)),
      AlbumCell(Rect.fromLTWH(firstWidth + spacing, 0, secondWidth, h),
          const AlbumSides(top: true, right: true, bottom: true)),
    ];
  }

  List<AlbumCell> _threeLeft() {
    final firstHeight = maxHeight;
    final thirdHeight = math
        .min((maxHeight - spacing) / 2,
            ratios[1] * (maxWidth - spacing) / (ratios[2] + ratios[1]))
        .roundToDouble();
    final secondHeight = firstHeight - thirdHeight - spacing;
    final rightWidth = math.max(
        minWidth,
        math
            .min((maxWidth - spacing) / 2,
                math.min(thirdHeight * ratios[2], secondHeight * ratios[1]))
            .roundToDouble());
    final leftWidth = math.min((firstHeight * ratios[0]).roundToDouble(),
        maxWidth - spacing - rightWidth);
    return [
      AlbumCell(Rect.fromLTWH(0, 0, leftWidth, firstHeight),
          const AlbumSides(top: true, left: true, bottom: true)),
      AlbumCell(Rect.fromLTWH(leftWidth + spacing, 0, rightWidth, secondHeight),
          const AlbumSides(top: true, right: true)),
      AlbumCell(
          Rect.fromLTWH(leftWidth + spacing, secondHeight + spacing, rightWidth,
              thirdHeight),
          const AlbumSides(bottom: true, right: true)),
    ];
  }

  List<AlbumCell> _threeTop() {
    final firstWidth = maxWidth;
    final firstHeight = math
        .min(firstWidth / ratios[0], (maxHeight - spacing) * 0.66)
        .roundToDouble();
    final secondWidth = (maxWidth - spacing) / 2;
    final secondHeight = math.min(
        maxHeight - firstHeight - spacing,
        math
            .min(secondWidth / ratios[1], secondWidth / ratios[2])
            .roundToDouble());
    final thirdWidth = firstWidth - secondWidth - spacing;
    return [
      AlbumCell(Rect.fromLTWH(0, 0, firstWidth, firstHeight),
          const AlbumSides(left: true, top: true, right: true)),
      AlbumCell(
          Rect.fromLTWH(0, firstHeight + spacing, secondWidth, secondHeight),
          const AlbumSides(bottom: true, left: true)),
      AlbumCell(
          Rect.fromLTWH(secondWidth + spacing, firstHeight + spacing,
              thirdWidth, secondHeight),
          const AlbumSides(bottom: true, right: true)),
    ];
  }

  List<AlbumCell> _fourTop() {
    final w = maxWidth;
    final h0 =
        math.min(w / ratios[0], (maxHeight - spacing) * 0.66).roundToDouble();
    final h = ((maxWidth - 2 * spacing) / (ratios[1] + ratios[2] + ratios[3]))
        .roundToDouble();
    final w0 = math.max(
        minWidth,
        math
            .min((maxWidth - 2 * spacing) * 0.4, h * ratios[1])
            .roundToDouble());
    final w2 = math
        .max(math.max(minWidth, (maxWidth - 2 * spacing) * 0.33), h * ratios[3])
        .roundToDouble();
    final w1 = w - w0 - w2 - 2 * spacing;
    final h1 = math.min(maxHeight - h0 - spacing, h);
    return [
      AlbumCell(Rect.fromLTWH(0, 0, w, h0),
          const AlbumSides(left: true, top: true, right: true)),
      AlbumCell(Rect.fromLTWH(0, h0 + spacing, w0, h1),
          const AlbumSides(bottom: true, left: true)),
      AlbumCell(Rect.fromLTWH(w0 + spacing, h0 + spacing, w1, h1),
          const AlbumSides(bottom: true)),
      AlbumCell(
          Rect.fromLTWH(w0 + spacing + w1 + spacing, h0 + spacing, w2, h1),
          const AlbumSides(right: true, bottom: true)),
    ];
  }

  List<AlbumCell> _fourLeft() {
    final h = maxHeight;
    final w0 =
        math.min(h * ratios[0], (maxWidth - spacing) * 0.6).roundToDouble();
    final w = ((maxHeight - 2 * spacing) /
            (1 / ratios[1] + 1 / ratios[2] + 1 / ratios[3]))
        .roundToDouble();
    final h0 = (w / ratios[1]).roundToDouble();
    final h1 = (w / ratios[2]).roundToDouble();
    final h2 = h - h0 - h1 - 2 * spacing;
    final w1 = math.max(minWidth, math.min(maxWidth - w0 - spacing, w));
    return [
      AlbumCell(Rect.fromLTWH(0, 0, w0, h),
          const AlbumSides(top: true, left: true, bottom: true)),
      AlbumCell(Rect.fromLTWH(w0 + spacing, 0, w1, h0),
          const AlbumSides(top: true, right: true)),
      AlbumCell(Rect.fromLTWH(w0 + spacing, h0 + spacing, w1, h1),
          const AlbumSides(right: true)),
      AlbumCell(Rect.fromLTWH(w0 + spacing, h0 + h1 + 2 * spacing, w1, h2),
          const AlbumSides(bottom: true, right: true)),
    ];
  }
}

class _ComplexLayouter {
  _ComplexLayouter(List<double> ratios, this.averageRatio, this.maxWidth,
      this.minWidth, this.spacing)
      : ratios = [
          for (final r in ratios)
            averageRatio > 1.1 ? r.clamp(1.0, 2.75) : r.clamp(0.6667, 1.0)
        ],
        // "In complex case they use maxWidth * 4 / 3 as maxHeight."
        maxHeight = maxWidth * 4 / 3;

  final List<double> ratios;
  final double averageRatio, maxWidth, minWidth, spacing, maxHeight;
  int get count => ratios.length;

  double _lineHeight(int offset, int n) {
    final sum =
        ratios.sublist(offset, offset + n).fold<double>(0, (a, b) => a + b);
    return (maxWidth - (n - 1) * spacing) / sum;
  }

  List<AlbumCell> layout() {
    final attempts = <List<int>>[];
    for (var first = 1; first != count; first++) {
      final second = count - first;
      if (first > 3 || second > 3) continue;
      attempts.add([first, second]);
    }
    for (var first = 1; first < count - 1; first++) {
      for (var second = 1; second < count - first; second++) {
        final third = count - first - second;
        if (first > 3 || second > (averageRatio < 0.85 ? 4 : 3) || third > 3) {
          continue;
        }
        attempts.add([first, second, third]);
      }
    }
    for (var first = 1; first < count - 1; first++) {
      for (var second = 1; second < count - first; second++) {
        for (var third = 1; third < count - first - second; third++) {
          final fourth = count - first - second - third;
          if (first > 3 || second > 3 || third > 3 || fourth > 3) continue;
          attempts.add([first, second, third, fourth]);
        }
      }
    }
    // Ten items cannot always be split into four rows of three; one row per
    // three is then the honest fallback rather than nothing.
    if (attempts.isEmpty) {
      final lines = <int>[];
      for (var left = count; left > 0; left -= 3) {
        lines.add(math.min(3, left));
      }
      attempts.add(lines);
    }

    List<int>? best;
    List<double>? bestHeights;
    var bestDiff = 0.0;
    for (final counts in attempts) {
      final heights = <double>[];
      var offset = 0;
      for (final n in counts) {
        heights.add(_lineHeight(offset, n));
        offset += n;
      }
      final total = heights.fold<double>(0, (a, b) => a + b) +
          spacing * (counts.length - 1);
      final minLine = heights.reduce(math.min);
      final bad1 = minLine < minWidth ? 1.5 : 1.0;
      var bad2 = 1.0;
      for (var line = 1; line < counts.length; line++) {
        if (counts[line - 1] > counts[line]) {
          bad2 = 1.5;
          break;
        }
      }
      final diff = (total - maxHeight).abs() * bad1 * bad2;
      if (best == null || diff < bestDiff) {
        best = counts;
        bestHeights = heights;
        bestDiff = diff;
      }
    }

    final out = <AlbumCell>[];
    var index = 0;
    var y = 0.0;
    for (var row = 0; row < best!.length; row++) {
      final cols = best[row];
      final lineHeight = bestHeights![row];
      final height = lineHeight.roundToDouble();
      var x = 0.0;
      for (var col = 0; col < cols; col++) {
        final width = col == cols - 1
            ? maxWidth - x
            : (ratios[index] * lineHeight).roundToDouble();
        out.add(AlbumCell(
          Rect.fromLTWH(x, y, width, height),
          AlbumSides(
            top: row == 0,
            bottom: row == best.length - 1,
            left: col == 0,
            right: col == cols - 1,
          ),
        ));
        x += width + spacing;
        index++;
      }
      y += height + spacing;
    }
    return out;
  }
}

/// Telegram sends at most ten media in one group; a longer album is several
/// groups, one after another. Split [count] items into groups of at most
/// [maxPerGroup], as even as possible (23 → 8, 8, 7, never 10, 10, 3), so no
/// group ends in a lone banner-sized item.
List<int> albumGroupSizes(int count, {int maxPerGroup = 10}) {
  if (count <= 0) return const [];
  final groups = (count + maxPerGroup - 1) ~/ maxPerGroup;
  final base = count ~/ groups;
  final extra = count % groups;
  return [for (var i = 0; i < groups; i++) base + (i < extra ? 1 : 0)];
}
