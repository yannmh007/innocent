import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'device_profile.dart';

/// On a TV, the overscan margins Google's TV quality guidelines keep clear
/// (5 %: 48 dp at the sides, 27 dp at the top and bottom of a 960x540 dp
/// screen), handed to the whole app as system insets.
///
/// WHY AS INSETS. Everything already keeps clear of the status and
/// navigation bars through MediaQuery's padding — app bars, the rail,
/// SafeArea, the player's controls (`_controlsInsets`). On a TV there are
/// no bars, so it all ran to the edge: the top bar, the rail and the
/// player's back arrow sat 0–16 dp from it, where a TV that overscans cuts
/// (12 Nov 2026, docs/devices_2026_11.md). Backgrounds — the film itself, a
/// hero image — still fill the screen, as the guidelines want.
class TvSafeArea extends StatelessWidget {
  const TvSafeArea({super.key, required this.child, this.isTv});

  final Widget child;

  /// Overrides [DeviceProfile.isTv] (tests).
  final bool? isTv;

  /// The margins on a screen of [size]: 5 % of each side.
  static EdgeInsets marginsFor(Size size) => EdgeInsets.symmetric(
      horizontal: size.width * 0.05, vertical: size.height * 0.05);

  @override
  Widget build(BuildContext context) {
    if (!(isTv ?? DeviceProfile.isTv)) return child;
    final mq = MediaQuery.of(context);
    final m = marginsFor(mq.size);
    EdgeInsets atLeast(EdgeInsets e) => EdgeInsets.fromLTRB(
          math.max(e.left, m.left),
          math.max(e.top, m.top),
          math.max(e.right, m.right),
          math.max(e.bottom, m.bottom),
        );
    return MediaQuery(
      data: mq.copyWith(
        padding: atLeast(mq.padding),
        viewPadding: atLeast(mq.viewPadding),
      ),
      child: child,
    );
  }
}
