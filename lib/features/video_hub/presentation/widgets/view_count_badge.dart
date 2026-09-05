import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../video_hub_theme.dart';

/// How a view count is written, everywhere.
///
/// One definition, because a number that reads `1.2K` on a card and `1,234` in
/// the detail screen looks like two different numbers about two different
/// things.
///
/// The thresholds are the ones every video platform converged on, and the
/// reason is width, not style: a poster card corner has room for four or five
/// characters, and `1234567` is not four characters. Compacting starts at
/// 1,000 because below that the exact number still fits and is more useful.
class ViewCount {
  ViewCount._();

  /// 0..999 exact, then K, then M.
  ///
  /// One decimal only under 10 units (`1.2K`, `9.9K`) and none above (`12K`,
  /// `340K`) - the decimal stops carrying information once the integer part is
  /// two digits, and it costs the two characters that make the label wrap.
  static String compact(int views) {
    if (views < 0) return '0';
    if (views < 1000) return '$views';
    if (views < 1000000) return _scaled(views, 1000, 'K');
    return _scaled(views, 1000000, 'M');
  }

  static String _scaled(int value, int unit, String suffix) {
    final scaled = value / unit;
    if (scaled < 10) {
      final one = (value * 10 / unit).floor() / 10;
      // Truncated, not rounded: 999,999 must not become "1.0M" while the
      // catalogue still says it is under a million.
      final text = one == one.roundToDouble()
          ? one.toStringAsFixed(0)
          : one.toStringAsFixed(1);
      return '$text$suffix';
    }
    return '${scaled.floor()}$suffix';
  }
}

/// The eye + count pair shown on a poster corner.
///
/// Replaced a star rating. A rating answers "was it good?", which needs enough
/// people to have voted before it means anything - and a new catalogue has
/// nobody. A view count answers "are people watching this?", which is true
/// from the first tap and is the question a browsing user is actually asking.
class ViewCountBadge extends StatelessWidget {
  final int views;

  /// Compact form for a card corner; the full label with the word "views" for
  /// places with room.
  final bool compactOnly;

  const ViewCountBadge({
    super.key,
    required this.views,
    this.compactOnly = true,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final text = compactOnly
        ? ViewCount.compact(views)
        : s.vhViewsCount(ViewCount.compact(views));

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          Icons.visibility_outlined,
          size: compactOnly ? 11 : 14,
          color: compactOnly ? VH.textPrimary : VH.textSecondary,
        ),
        const SizedBox(width: 3),
        Text(
          text,
          style: compactOnly
              ? VH.badge.copyWith(letterSpacing: 0)
              : VH.label.copyWith(
                  color: VH.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
        ),
      ],
    );
  }
}
