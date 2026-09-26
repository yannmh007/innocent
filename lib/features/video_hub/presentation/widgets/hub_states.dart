import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/theme/app_colors.dart';
import '../../data/api/api_exception.dart';
import '../../data/cache/catalogue_cache.dart';
import 'poster_metrics.dart';
import '../video_hub_theme.dart';

/// A poster-shaped skeleton grid shown while the catalogue loads.
///
/// Skeletons rather than a centred spinner: the layout that is about to
/// appear is already on screen, so the arrival of real data does not shift
/// everything. A spinner in the middle of a grid teaches nothing about what is
/// coming and makes the wait feel longer.
///
/// The pulse is a hand-rolled [AnimationController] — the effect is eight
/// lines, and a dependency added for eight lines is a dependency to maintain
/// forever.
class PosterSkeletonGrid extends StatefulWidget {
  final int count;
  final int crossAxisCount;

  const PosterSkeletonGrid({
    super.key,
    this.count = 9,
    this.crossAxisCount = 3,
  });

  @override
  State<PosterSkeletonGrid> createState() => _PosterSkeletonGridState();
}

class _PosterSkeletonGridState extends State<PosterSkeletonGrid>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
      physics: const NeverScrollableScrollPhysics(),
      shrinkWrap: true,
      itemCount: widget.count,
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: widget.crossAxisCount,
        crossAxisSpacing: PosterMetrics.gridSpacing,
        mainAxisSpacing: 14,
        // Same extent as the real grid, so nothing shifts when data lands.
        mainAxisExtent: PosterMetrics.gridExtent(
            context, MediaQuery.of(context).size.width),
      ),
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            final t = 0.35 + (_pulse.value * 0.25);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: VH.surface3.withOpacity(t),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 10,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: VH.surface3.withOpacity(t),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  height: 8,
                  width: 34,
                  decoration: BoxDecoration(
                    color: VH.surface3.withOpacity(t * 0.8),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}

/// Row-shaped skeleton for the landing tab.
///
/// The "All" tab shows ROWS, so a grid-shaped skeleton there promises a layout
/// that never arrives — the screen visibly rearranges itself the moment data
/// lands. A skeleton is only useful if it is the shape of the thing it is
/// standing in for.
class RowSkeletonList extends StatelessWidget {
  final int rows;

  const RowSkeletonList({super.key, this.rows = 3});

  @override
  Widget build(BuildContext context) {
    const cardWidth = PosterMetrics.rowCardWidth;
    const posterHeight = cardWidth / PosterMetrics.aspect;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List<Widget>.generate(rows, (r) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 9),
              child: Container(
                width: 120 + (r * 18),
                height: 15,
                decoration: BoxDecoration(
                  color: VH.surface3.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            SizedBox(
              height: PosterMetrics.rowHeight(context),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: 4,
                separatorBuilder: (_, __) =>
                    const SizedBox(width: PosterMetrics.rowGap),
                itemBuilder: (_, __) => SizedBox(
                  width: cardWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: cardWidth,
                        height: posterHeight,
                        decoration: BoxDecoration(
                          color: VH.surface3.withOpacity(0.45),
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Container(
                        width: cardWidth * 0.8,
                        height: 9,
                        decoration: BoxDecoration(
                          color: VH.surface3.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }
}

/// Nothing matched — a normal outcome, not a failure.
///
/// Kept visually distinct from [HubErrorState] on purpose: showing a retry
/// button for an empty filter invites the user to retry something that will
/// never change, and showing "no results" for an outage hides a real problem.
class HubEmptyState extends StatelessWidget {
  final String message;
  final IconData icon;

  /// Offered only when there is something to undo, e.g. active filters.
  final String? actionLabel;
  final VoidCallback? onAction;

  const HubEmptyState({
    super.key,
    required this.message,
    this.icon = Icons.search_off,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 56),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 44, color: VH.textTertiary),
          const SizedBox(height: 14),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: VH.textSecondary,
              fontSize: 14,
              height: 1.35,
            ),
          ),
          if (actionLabel != null && onAction != null) ...<Widget>[
            const SizedBox(height: 16),
            TextButton(
              onPressed: onAction,
              child: Text(
                actionLabel!,
                style: const TextStyle(
                  color: VH.accent,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// A slim line saying what is on screen was saved earlier, not fetched now.
///
/// ─── WHY A BANNER AND NOT AN ERROR ───────────────────────────────────────
///
/// With no connection the hub used to draw an error card INSTEAD OF its rows,
/// so the whole layout disappeared and the app looked broken rather than
/// offline. [CatalogueCache] fixed the disappearing half: the rows, the grid
/// and a title's album now come off the disk. This is the other half — saying
/// so. Telegram and Facebook both keep showing the last thing they had and
/// mark it; an app that shows month-old data as if it were current is the one
/// people stop trusting.
///
/// Listens to [CatalogueCache.servedFromCache] rather than probing the network:
/// the honest question is not "is there a signal" but "is what you are reading
/// current", and only the thing that answered the request knows that. It also
/// means the banner disappears by itself the moment a live answer arrives, with
/// nothing to poll and nothing to invalidate.
class OfflineNotice extends StatelessWidget {
  const OfflineNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: CatalogueCache.servedFromCache,
      builder: (context, stale, _) {
        if (!stale) return const SizedBox.shrink();
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: VH.gutter, vertical: 8),
          color: VH.surface2,
          child: Row(
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 15, color: VH.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.vhOfflineBanner,
                  style: const TextStyle(
                    color: VH.textSecondary,
                    fontSize: 12,
                    height: 1.3,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Something actually broke. Always offers a retry.
///
/// TELLS "NO INTERNET" APART FROM "SOMETHING WENT WRONG", because they call for
/// different things from the reader: one is fixed by turning the radio on, the
/// other by tapping retry or telling somebody. It used to print
/// `error.toString()` in both cases, which on a phone with no signal read
/// `ApiException(network)` — a sentence that means nothing to the person
/// holding it and hides the one thing they could act on.
class HubErrorState extends StatelessWidget {
  final VoidCallback onRetry;

  /// Shown small, under the friendly line. Users rarely read it; the person
  /// they forward a screenshot to always does.
  final String? detail;

  /// What was thrown, when the caller has it.
  ///
  /// Given the error rather than a boolean so the decision is made in ONE
  /// place, by [isUnreachableError], which is the same test the repository uses
  /// to decide whether to serve its cache. A boolean here would let a screen
  /// disagree with the layer that produced the failure.
  final Object? error;

  const HubErrorState({
    super.key,
    required this.onRetry,
    this.detail,
    this.error,
  });

  bool get _offline => isUnreachableError(error);

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.cloud_off, size: 44, color: AppColors.specBadge),
          const SizedBox(height: 14),
          Text(
            _offline ? s.vhOfflineNothingSaved : s.vhLoadFailed,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          // Offline gets the sentence that tells the user what will happen
          // next; a real failure gets the raw detail, which is worth nothing to
          // them and everything to whoever they forward the screenshot to.
          if (_offline || detail != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              _offline ? s.vhOfflineHint : detail!,
              textAlign: TextAlign.center,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: VH.textTertiary,
                fontSize: 11.5,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: onRetry,
            style: FilledButton.styleFrom(
              backgroundColor: VH.accent,
            ),
            child: Text(s.vhRetry),
          ),
        ],
      ),
    );
  }
}
