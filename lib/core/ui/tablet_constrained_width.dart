import 'package:flutter/material.dart';

import 'responsive.dart';

/// Phase 45 (audit): on tablets and foldables, list-based screens
/// (Settings, History, Favourites, etc.) look sparse if they stretch
/// edge-to-edge. MX Player handles this by capping the content width
/// to ~640 dp and centering it in the viewport.
///
/// Wrap a body widget with [TabletConstrainedWidth] inside the
/// Scaffold body to get the same effect. On phones the wrapper is a
/// no-op so the layout stays identical to before.
class TabletConstrainedWidth extends StatelessWidget {
  final Widget child;

  /// Maximum width applied on tablets and larger. Defaults to 640 dp,
  /// which is comfortable for reading list rows without being so wide
  /// that the eye has to swing across the screen.
  final double maxWidth;

  const TabletConstrainedWidth({
    super.key,
    required this.child,
    this.maxWidth = 640,
  });

  @override
  Widget build(BuildContext context) {
    if (!Responsive.isTablet(context)) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
