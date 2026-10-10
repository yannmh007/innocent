import 'package:flutter/material.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';

/// A small amber "Hidden" pill for videos/folders that live where normal
/// galleries hide them — Android/data caches (reached over ADB), dot-files, and
/// dot-folders. Used in the Local list and in the Private-Folder / Transfer
/// pickers so it's always clear an item isn't in the usual media locations.
///
/// The word is the app's language ("ဝှက်ထား" in Burmese); it used to be
/// English on every phone.
class HiddenBadge extends StatelessWidget {
  const HiddenBadge({super.key, this.label});

  /// Overrides the word; null is the app's own "Hidden".
  final String? label;

  @override
  Widget build(BuildContext context) {
    final strings = AppStrings.of(context);
    // Burmese stacks marks above and below the line: a tight line height
    // clips them inside a pill this small.
    final mm = strings.locale.languageCode == 'my';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.visibility_off_rounded,
            size: 11,
            color: AppColors.warning,
          ),
          const SizedBox(width: 3),
          Text(
            label ?? strings.hiddenBadge,
            style: TextStyle(
              color: AppColors.warning,
              fontSize: 10,
              height: mm ? 1.45 : 1.2,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact icon-only variant for grid thumbnail corners, where a full pill
/// would crowd the tile. A dark rounded chip keeps it legible over any cover.
class HiddenCornerBadge extends StatelessWidget {
  const HiddenCornerBadge({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xC7000000),
        borderRadius: BorderRadius.circular(3),
      ),
      child: const Icon(
        Icons.visibility_off_rounded,
        size: 12,
        color: AppColors.warning,
      ),
    );
  }
}
