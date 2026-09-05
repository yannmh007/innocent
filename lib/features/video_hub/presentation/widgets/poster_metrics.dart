import 'package:flutter/material.dart';

/// One place that decides how a poster card is shaped.
///
/// WHY THIS FILE EXISTS: the row and the grid used to size cards
/// independently — the row let a Column's `Expanded` absorb whatever was left
/// over, the grid used `childAspectRatio` on the whole cell. The two arrived
/// at different answers (1:1.57 in the row, 1:1.45 in the grid), so the SAME
/// card was a different shape depending on where it appeared, and both were
/// taller than intended. Nothing in the code said what the shape was supposed
/// to be, so nothing could be wrong.
///
/// Now the poster is pinned to [aspect] with an `AspectRatio` in both places,
/// and the grid's cell height is DERIVED from it. Changing the look of every
/// card is a one-line change here.
///
/// [aspect] is 0.72 rather than the 2:3 (0.667) of printed poster art: it
/// matches the density comparable apps use, it fits noticeably more per
/// screen, and real 2:3 artwork loses about 7% off the top and bottom under
/// `BoxFit.cover` — invisible on posters, which keep their subject centred.
class PosterMetrics {
  PosterMetrics._();

  /// width / height of the artwork.
  static const double aspect = 0.72;

  static const int gridColumns = 3;
  static const double gridSpacing = 10;
  static const double gridPadding = 14;

  /// Width of a card inside a horizontally-scrolling row.
  static const double rowCardWidth = 108;
  static const double rowGap = 10;

  static const double titleSize = 12;
  static const double yearSize = 10.5;
  static const double _titleLeading = 1.2;
  static const double _yearLeading = 1.15;
  static const double _gapAboveTitle = 5;
  static const double _gapAboveYear = 1;

  /// Height of the two text lines under the artwork.
  ///
  /// Scaled by the user's text-size setting. A fixed 30dp block looks right at
  /// the default and clips the year at 130% — and an accessibility setting is
  /// exactly the thing a hard-coded layout breaks first.
  static double textBlock(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    return _gapAboveTitle +
        scaler.scale(titleSize) * _titleLeading +
        _gapAboveYear +
        scaler.scale(yearSize) * _yearLeading;
  }

  /// Width of one grid cell, given the width available to the grid.
  static double gridCellWidth(double maxWidth) {
    final usable =
        maxWidth - gridPadding * 2 - gridSpacing * (gridColumns - 1);
    return usable / gridColumns;
  }

  /// Absolute cell height for the grid delegate.
  ///
  /// Passed as `mainAxisExtent`, not `childAspectRatio`: an aspect ratio makes
  /// the cell height depend on the cell width, so the text block would grow
  /// with the screen and the artwork would drift away from [aspect] on wide
  /// devices. An absolute extent keeps the artwork exactly [aspect] on every
  /// screen and gives the text the space it actually needs.
  static double gridExtent(BuildContext context, double maxWidth) =>
      gridCellWidth(maxWidth) / aspect + textBlock(context);

  /// Height a horizontally-scrolling row needs.
  static double rowHeight(BuildContext context) =>
      rowCardWidth / aspect + textBlock(context);
}
