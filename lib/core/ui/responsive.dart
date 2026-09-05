import 'package:flutter/widgets.dart';

/// Phase 45 (audit): responsive layout helpers for Innocent.
///
/// MX Player V3 works on phones (320–480 dp wide), small tablets
/// (600–720 dp), and large tablets / foldables (840+ dp). Hardcoded
/// 2-column or 3-column grids look sparse on tablets and cramped on
/// foldables. This helper provides one place to make those decisions.
///
/// Breakpoints follow Material Design's accepted tablet boundary:
///   - phone:        <  600 dp (shortest side)
///   - small tablet: ≥ 600 dp
///   - large tablet: ≥ 840 dp
class Responsive {
  Responsive._();

  /// True when the device's shortest side is at least 600 dp — the
  /// canonical "this is a tablet" threshold used by Android, iPadOS,
  /// and Material Design.
  static bool isTablet(BuildContext context) =>
      MediaQuery.of(context).size.shortestSide >= 600;

  /// True when the shortest side is at least 840 dp — large tablets
  /// and unfolded foldables (Galaxy Z Fold, Pixel Fold).
  static bool isLargeTablet(BuildContext context) =>
      MediaQuery.of(context).size.shortestSide >= 840;

  /// Number of columns for the folder GRID view.
  /// - Phone portrait: 2
  /// - Phone landscape: 3
  /// - Tablet portrait: 3
  /// - Tablet landscape / large tablet: 4
  static int folderGridColumns(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 1100) return 5;
    if (width >= 840) return 4;
    if (width >= 600) return 3;
    if (width >= 480) return 3; // phone landscape
    return 3; // phone portrait — 3-up grid (Folders spec)
  }

  /// Number of columns for the VIDEO GRID view (used in folder detail
  /// and Files-mode library). Wider columns since each thumb is 16:9.
  /// - Phone portrait: 2
  /// - Phone landscape: 3
  /// - Tablet portrait: 3
  /// - Tablet landscape / large tablet: 4
  static int videoGridColumns(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 1100) return 5;
    if (width >= 840) return 4;
    if (width >= 600) return 3;
    if (width >= 480) return 3; // phone landscape
    return 2;
  }
}
