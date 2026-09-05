import 'package:flutter/material.dart';

import '../../domain/video_content.dart';

/// One tile's place in the mosaic.
class MosaicTile {
  final int index;
  final double width;
  final double height;

  const MosaicTile({
    required this.index,
    required this.width,
    required this.height,
  });
}

/// A Telegram-style album layout: rows of varying height that always fill the
/// width exactly.
///
/// WHY NOT THE FIXED GRID IT REPLACES
///
/// The album was a three-column grid of squares. A 9:16 portrait clip and a
/// 16:9 still were given the same square hole, so the portrait clip lost about
/// 44% of its frame. That is a poster grid, and a mixed folder of stills and
/// clips is not a poster screen.
///
/// THE RULE THIS OBEYS
///
/// Telegram's own maintainers state it plainly: the layout may crop however it
/// likes, but the pixel aspect ratio is sacred and must never be stretched or
/// squeezed. Every tile here is drawn with `BoxFit.cover`, which crops. Nothing
/// is ever scaled unevenly.
///
/// THE ALGORITHM
///
///  1. each item gets an aspect ratio: `width / height` when the server knows
///     them, otherwise a default by kind;
///  2. the ideal number of rows is `round(totalRatio / _targetRowRatio)` -
///     four square items become two rows of two, three become one row of
///     three;
///  3. items are split into that many CONTIGUOUS groups of roughly equal
///     ratio-sum;
///  4. each row is scaled so its widths plus gaps exactly equal the available
///     width. Row height falls out as `available / sumOfRatios`.
///
/// Contiguous on purpose. Telegram reorders items to pack them tighter, which
/// is right for a chat message nobody curated. Here `sort_order` was chosen by
/// the operator, and silently resequencing their album would be the app
/// overruling an editorial decision.
class MediaMosaic {
  const MediaMosaic._();

  /// How much horizontal "aspect" one row should hold before it is closed.
  ///
  /// 2.2 on a phone: roughly two landscape items, or three portrait ones.
  /// Higher packs more per row and makes everything smaller.
  static const double _targetRowRatio = 2.2;

  static const double gap = 3;

  /// Nothing may be taller than this multiple of the container width.
  ///
  /// Without it a single 9:16 item becomes 1.78x the screen width tall and
  /// pushes everything else off the page - the album stops being glanceable,
  /// which is the entire point of it.
  static const double _maxRowHeightFactor = 1.15;

  /// Ratio used when the server has no dimensions for an item.
  ///
  /// Uploading through the R2 dashboard supplies no width or height, so on day
  /// one EVERY item lands here. The layout is built to look right in that
  /// case and merely get better when the numbers arrive - it must never
  /// require them.
  static double ratioOf(AlbumItem item) {
    final w = item.width;
    final h = item.height;
    if (w != null && h != null && w > 0 && h > 0) {
      // Clamped: one freakishly wide panorama would otherwise flatten its
      // whole row to a few pixels of height.
      return (w / h).clamp(0.4, 2.6);
    }
    // Photos tend to be square-ish stills; clips in this catalogue are
    // overwhelmingly portrait. A wrong guess costs a crop, never a stretch.
    return item.isVideo ? 0.75 : 1.0;
  }

  /// Groups [items] into rows and sizes every tile.
  ///
  /// Returns rows in order; each row's tile widths plus gaps sum to [width].
  static List<List<MosaicTile>> layout({
    required List<AlbumItem> items,
    required double width,
  }) {
    if (items.isEmpty || width <= 0) return const <List<MosaicTile>>[];

    final ratios = items.map(ratioOf).toList(growable: false);
    final total = ratios.fold<double>(0, (a, b) => a + b);

    // At least one row, and never more rows than items.
    var rows = (total / _targetRowRatio).round();
    if (rows < 1) rows = 1;
    if (rows > items.length) rows = items.length;

    final groups = _partition(ratios, rows);

    final out = <List<MosaicTile>>[];
    var cursor = 0;
    for (final group in groups) {
      final count = group.length;
      final sum = group.fold<double>(0, (a, b) => a + b);
      final available = width - gap * (count - 1);
      if (available <= 0 || sum <= 0) {
        cursor += count;
        continue;
      }

      var height = available / sum;
      final maxHeight = width * _maxRowHeightFactor;
      final clamped = height > maxHeight;
      if (clamped) height = maxHeight;

      // When the height is clamped, `ratio * height` no longer fills the row -
      // the shortfall has to go somewhere. Giving it all to the last tile made
      // that one tile visibly wider than its neighbours; spreading it in
      // PROPORTION keeps every tile the same relative size it would have had.
      //
      // Reachable with two very tall items (both at the 0.4 ratio floor), so
      // it is a real case rather than a theoretical one.
      final scale = clamped ? available / (sum * height) : 1.0;

      final tiles = <MosaicTile>[];
      var used = 0.0;
      for (var i = 0; i < count; i++) {
        // The last tile takes whatever is left rather than its computed width.
        // Rounding across three or four tiles otherwise leaves a one-pixel
        // seam down the right edge of every row.
        final w = i == count - 1
            ? available - used
            : group[i] * height * scale;
        used += w;
        tiles.add(MosaicTile(index: cursor + i, width: w, height: height));
      }
      out.add(tiles);
      cursor += count;
    }
    return out;
  }

  /// Splits [ratios] into [rows] contiguous groups of roughly equal sum.
  ///
  /// LOOK-AHEAD, NOT GREEDY. The obvious version closes a row as soon as its
  /// sum reaches the average, which front-loads: nine square items came out as
  /// 3+3+2+1, and that trailing single tile is drawn full width, so the ninth
  /// photo became a banner twice the height of the eight above it.
  ///
  /// This version asks a better question at each item - *would stopping here
  /// land closer to the average than taking one more?* - and stops only when
  /// the answer is yes. The same nine items become 2+2+2+3.
  ///
  /// The `remaining <= rowsLeft` guard is what stops a row ending up empty:
  /// once there are exactly as many items left as rows left, every remaining
  /// row takes exactly one.
  static List<List<double>> _partition(List<double> ratios, int rows) {
    final out = <List<double>>[];
    if (rows <= 1) return <List<double>>[List<double>.from(ratios)];

    final total = ratios.fold<double>(0, (a, b) => a + b);
    final perRow = total / rows;

    var current = <double>[];
    var acc = 0.0;
    for (var i = 0; i < ratios.length; i++) {
      current.add(ratios[i]);
      acc += ratios[i];

      final remaining = ratios.length - i - 1;
      final rowsLeft = rows - out.length - 1;
      if (rowsLeft <= 0) continue;

      // Out of items to spare: every remaining row must take one each.
      if (remaining <= rowsLeft) {
        out.add(current);
        current = <double>[];
        acc = 0;
        continue;
      }

      final next = ratios[i + 1];
      final stopError = (acc - perRow).abs();
      final goOnError = (acc + next - perRow).abs();
      if (stopError <= goOnError) {
        out.add(current);
        current = <double>[];
        acc = 0;
      }
    }
    if (current.isNotEmpty) out.add(current);
    return out;
  }

  /// Builds the mosaic as a plain Column of Rows.
  ///
  /// A bounded set - one title's folder - so there is nothing to virtualise;
  /// a Column is what a Sliver would collapse to anyway.
  static Widget build({
    required List<AlbumItem> items,
    required double width,
    required Widget Function(int index) tileBuilder,
  }) {
    final rows = layout(items: items, width: width);
    if (rows.isEmpty) return const SizedBox.shrink();

    final children = <Widget>[];
    for (var r = 0; r < rows.length; r++) {
      if (r > 0) children.add(const SizedBox(height: gap));
      final row = rows[r];
      children.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (var i = 0; i < row.length; i++) ...<Widget>[
            if (i > 0) const SizedBox(width: gap),
            SizedBox(
              width: row[i].width,
              height: row[i].height,
              child: tileBuilder(row[i].index),
            ),
          ],
        ],
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}
