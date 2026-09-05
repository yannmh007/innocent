import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';

import '../../domain/content_category.dart';
import '../../domain/video_content.dart';
import '../video_hub_theme.dart';
import 'poster_image.dart';
import 'media_count_badge.dart';
import 'view_count_badge.dart';
import 'poster_metrics.dart';

/// One catalogue entry, drawn as a poster tile.
///
/// Deliberately the SAME widget in the rows, the category grid, the see-all
/// screen and the search results. Four lookalike cards drift apart within a
/// few releases; one card means a change to the badge rules lands everywhere.
///
/// BADGE RESTRAINT: the first cut could stamp four things on one 108dp tile -
/// quality, rank, rating and episode count. Every one of them was defensible
/// and together they buried the artwork, which is the only thing on the card
/// that actually sells the title. Now at most TWO appear: one marker top-left
/// (rank where the list is ranked, otherwise quality) and the rating
/// bottom-right. Episode count moved to the detail screen, where there is room
/// to say "12 episodes" instead of "EP 12".
class PosterCard extends StatelessWidget {
  final VideoContent content;
  final VoidCallback? onTap;

  /// Fixed width when used inside a horizontal row. Null lets the parent grid
  /// decide.
  final double? width;

  /// 1-based position, drawn as a corner numeral. Used by ranked lists
  /// (trending); null everywhere else.
  final int? rank;

  /// Draw the premium marker. Decided by the caller from AccessPolicy, so the
  /// card never has to know what a policy is.
  final bool premium;

  const PosterCard({
    super.key,
    required this.content,
    this.onTap,
    this.width,
    this.rank,
    this.premium = false,
  });

  @override
  Widget build(BuildContext context) {
    final textBlock = PosterMetrics.textBlock(context);

    // Rank supersedes quality in the top-left slot: in a ranked list the
    // position IS the information, and two badges in one corner is clutter.
    final String? cornerLabel = rank != null
        ? '$rank'
        : (content.qualityLabel != null ? content.qualityLabel : null);
    final bool cornerIsRank = rank != null;

    final art = AspectRatio(
      aspectRatio: PosterMetrics.aspect,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(VH.rCard),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            PosterImage(
              mediaRef: content.poster,
              title: content.title,
              glyph: _glyphFor(content.category),
            ),
            // Scrim only where a badge sits, and only strong enough to carry
            // it. A full-width bar across every poster dulls the artwork on
            // the cards that have no badge at all.
            if (content.viewCount != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 34,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: <Color>[
                        Colors.black.withOpacity(0.5),
                        Colors.transparent,
                      ],
                    ),
                  ),
                ),
              ),
            if (cornerLabel != null)
              Positioned(
                top: VH.s1,
                left: VH.s1,
                child: _Marker(
                  label: cornerLabel,
                  prominent: cornerIsRank,
                ),
              ),
            if (content.viewCount != null)
              Positioned(
                right: VH.s1,
                bottom: VH.s1,
                child: ViewCountBadge(views: content.viewCount!),
              ),
            // Opposite corner from the views, on the same baseline: two facts
            // of equal weight, balanced rather than stacked. Absent counts
            // draw nothing - "0 photos" and "we were not told" look identical
            // to a reader and only one of them is true.
            if (content.displayPhotoCount != null ||
                content.displayVideoCount != null)
              Positioned(
                left: VH.s1,
                bottom: VH.s1,
                child: MediaCountBadge(
                  photos: content.displayPhotoCount,
                  videos: content.displayVideoCount,
                ),
              ),
            // Top-right, opposite the rank/quality marker, so the two can
            // never collide in the same corner.
            if (premium)
              Positioned(
                top: VH.s1,
                right: VH.s1,
                child: _PremiumTag(),
              ),
            // Hairline: on a true-black page a dark poster has no edge at all
            // and the grid stops looking like a grid.
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(VH.rCard),
                    border: Border.all(color: VH.hairline, width: 0.5),
                  ),
                ),
              ),
            ),
            // The ripple, ABOVE the artwork. An InkWell wrapping the card
            // splashes on the Material ancestor, which is behind the poster —
            // so every tap on a card was completely silent. Feedback on touch
            // is most of what separates an app that feels responsive from one
            // that feels like it missed the tap.
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: onTap,
                  splashColor: Colors.white.withOpacity(0.10),
                  highlightColor: Colors.white.withOpacity(0.05),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    // The text is positioned over reserved space rather than laid out in the
    // Column, so a long title can never push the card past the height the grid
    // delegate was told to expect.
    final body = Stack(
      children: <Widget>[
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[art, SizedBox(height: textBlock)],
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: textBlock,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                content.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VH.cardTitle,
              ),
              if (content.year != null)
                Text('${content.year}', maxLines: 1, style: VH.meta),
            ],
          ),
        ),
      ],
    );

    final tappable = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rCard),
      child: body,
    );

    if (width == null) return tappable;
    return SizedBox(width: width, child: tappable);
  }

  static IconData _glyphFor(ContentCategory c) {
    switch (c) {
      case ContentCategory.series:
        return Icons.live_tv_outlined;
      case ContentCategory.reels:
        return Icons.smart_display_outlined;
      default:
        return Icons.movie_outlined;
    }
  }
}

/// Top-left marker. A rank reads as a light chip (it is the point of the
/// list); a quality tag reads as a dark one (it is a footnote).
class _Marker extends StatelessWidget {
  final String label;
  final bool prominent;

  const _Marker({required this.label, required this.prominent});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: prominent
            ? Colors.white.withOpacity(0.92)
            : Colors.black.withOpacity(0.62),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: VH.badge.copyWith(
          color: prominent ? VH.textInverse : VH.textPrimary,
        ),
      ),
    );
  }
}

/// The VIP marker. Small and monochrome on purpose - it is a fact about the
/// title, not an advertisement, and a gold badge on every other poster turns
/// the grid into a billboard.
class _PremiumTag extends StatelessWidget {
  const _PremiumTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: VH.textPrimary.withOpacity(0.92),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        AppStrings.of(context).vhPremiumBadge,
        style: VH.badge.copyWith(color: VH.textInverse),
      ),
    );
  }
}
