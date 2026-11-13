import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// GRIDS THAT ADD COLUMNS AS THE WINDOW WIDENS (docs/devices_2026_11.md,
/// Phase 2).
///
/// A phone's grid keeps its count; a tablet, a foldable, a Chromebook window
/// or a TV gets more columns of about the same size, not the phone's three
/// stretched across the screen — on a tablet the catalogue's posters were
/// 384 dp wide, two to a screen's height: a phone app blown up. By the
/// width the grid has, never "is it a tablet".
///
/// (This file held phone/tablet column counts nothing used; the folder and
/// video grids size by a maximum cell width already.)
class Responsive {
  Responsive._();

  /// Columns for a grid [width] dp wide (its own padding taken off): at
  /// least [min] — the phone's count — and as many more as keep a cell no
  /// wider than [maxCell], cells [spacing] apart.
  static int gridColumns(
    double width, {
    int min = 3,
    double maxCell = 170,
    double spacing = 0,
  }) {
    if (!width.isFinite || width <= 0) return min;
    return math.max(min, ((width + spacing) / (maxCell + spacing)).ceil());
  }
}

/// A grid's width to build with, a TV's side margins kept clear: on a TV the
/// overscan margins are insets (TvSafeArea), and a full-screen grid ran its
/// first and last columns into them. A phone upright has no side insets.
class SafeGridWidth extends StatelessWidget {
  const SafeGridWidth({super.key, required this.builder});

  /// Builds the grid for [width], the room it has.
  final Widget Function(BuildContext context, double width) builder;

  @override
  Widget build(BuildContext context) => SafeArea(
        top: false,
        bottom: false,
        child: LayoutBuilder(
          builder: (context, box) => builder(context, box.maxWidth),
        ),
      );
}

