import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/video_content.dart';
import '../video_hub_theme.dart';
import 'poster_card.dart';
import 'poster_metrics.dart';

/// One horizontally-scrolling row of posters, with its heading and a
/// "See all" link.
///
/// This is the pattern the whole streaming category converged on, and for a
/// documented reason: it turns one impossible decision (pick from thousands)
/// into a series of cheap ones (glance at a row, swipe, move on). The page
/// stays finite vertically while each row runs on horizontally.
///
/// EVERY row carries a See-all affordance. A row is a sample, not an
/// inventory - if some rows lead somewhere and others silently do not, the
/// user has to learn which is which by tapping, and a row that shows twelve of
/// four hundred titles with no way through is a dead end.
class ContentRowView extends StatelessWidget {
  final ContentRow row;

  /// Localized heading. The row itself carries only a key, so the caller
  /// resolves it - a heading shipped from a server would be stuck in whatever
  /// language that server chose.
  final String title;

  final void Function(VideoContent content) onItemTap;

  /// Opens the full list behind this row.
  final void Function(ContentRow row, String resolvedTitle) onSeeAll;

  /// Whether a premium marker belongs on a given title.
  final bool Function(VideoContent)? isPremiumFor;

  const ContentRowView({
    super.key,
    required this.row,
    required this.title,
    required this.onItemTap,
    required this.onSeeAll,
    this.isPremiumFor,
  });

  @override
  Widget build(BuildContext context) {
    if (row.isEmpty) return const SizedBox.shrink();
    final s = AppStrings.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // The whole header is one tap target, not just the word: a small word
        // at the far edge of the screen is the hardest thing on the row to
        // hit, and the heading beside it does nothing otherwise.
        InkWell(
          onTap: () => onSeeAll(row, title),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                VH.gutter, VH.s5, VH.s3, VH.s3),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: VH.heading,
                  ),
                ),
                const SizedBox(width: VH.s2),
                Text(
                  s.vhSeeAll,
                  style: VH.label.copyWith(
                    color: VH.textTertiary,
                    fontWeight: FontWeight.w500,
                    fontSize: 12.5,
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  size: 17,
                  color: VH.textTertiary,
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          height: PosterMetrics.rowHeight(context),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: VH.gutter),
            itemCount: row.items.length,
            separatorBuilder: (_, __) =>
                const SizedBox(width: PosterMetrics.rowGap),
            itemBuilder: (context, index) {
              final item = row.items[index];
              return PosterCard(
                content: item,
                width: PosterMetrics.rowCardWidth,
                rank: row.ranked ? index + 1 : null,
                premium: isPremiumFor?.call(item) ?? false,
                onTap: () => onItemTap(item),
              );
            },
          ),
        ),
      ],
    );
  }
}
