import 'package:flutter/material.dart';

import '../video_hub_theme.dart';

/// Pins any fixed-height bar to the top of a [CustomScrollView].
///
/// Written once because two bars need it (the category bar and the filter
/// bar), and a second hand-rolled `SliverPersistentHeaderDelegate` is two
/// places for the elevation rule to drift apart.
///
/// The filter bar in particular HAS to be pinned. Scrolling forty titles deep
/// and then having to scroll all the way back up to change a genre is the
/// reason people stop using filters at all.
class StickyBar extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  final Color background;

  const StickyBar({
    required this.height,
    required this.child,
    this.background = VH.canvas,
  });

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final scrolled = overlapsContent || shrinkOffset > 0;
    return Material(
      color: background,
      // A hairline, NOT an elevation. A shadow cast onto a true-black page is
      // invisible, so the bar would have had no edge at all while content slid
      // underneath it. On dark, separation comes from a border or a luminance
      // step - never from a shadow.
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: scrolled ? VH.hairline : Colors.transparent,
            ),
          ),
        ),
        child: SizedBox(height: height, child: child),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant StickyBar oldDelegate) {
    return oldDelegate.height != height ||
        oldDelegate.child != child ||
        oldDelegate.background != background;
  }
}
