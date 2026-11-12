// Grids that add columns as the window widens (core/ui/responsive.dart,
// docs/devices_2026_11.md Phase 2): a phone keeps its three; a tablet gets
// more posters of about a phone's size, not three of 384 dp.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/responsive.dart';
import 'package:innocent/features/video_hub/presentation/widgets/poster_metrics.dart';

void main() {
  test('a phone keeps the grid it was drawn with', () {
    for (final phone in [320.0, 360.0, 411.0, 480.0]) {
      expect(PosterMetrics.gridColumnsFor(phone), 3, reason: '$phone dp');
      expect(Responsive.gridColumns(phone - 16, spacing: 8), 3,
          reason: '$phone dp');
    }
  });

  test('a wider window adds columns; a poster stays about a phone\'s size', () {
    // A tablet upright beside the rail, a TV beside the rail, a tablet or a
    // Chromebook window sideways.
    expect(PosterMetrics.gridColumnsFor(720), 4);
    expect(PosterMetrics.gridColumnsFor(784), 5);
    expect(PosterMetrics.gridColumnsFor(1200), 7);
    expect(PosterMetrics.gridColumnsFor(1280), 8);
    for (final w in [600.0, 720.0, 840.0, 960.0, 1200.0, 1280.0, 1600.0]) {
      final cell = PosterMetrics.gridCellWidth(w);
      expect(cell, lessThanOrEqualTo(PosterMetrics.gridMaxCell),
          reason: '$w dp');
      expect(cell, greaterThan(110), reason: '$w dp');
    }
  });

  test('no width yet: the phone\'s count', () {
    expect(Responsive.gridColumns(0), 3);
    expect(Responsive.gridColumns(double.infinity), 3);
    expect(Responsive.gridColumns(double.nan), 3);
  });
}
