import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';

import '../../domain/video_content.dart';
import '../paged_catalogue.dart';
import 'hub_states.dart';
import 'poster_card.dart';
import 'vh_insets.dart';
import 'poster_metrics.dart';

/// Slivers that draw a paged poster grid, plus whatever footer the current
/// state calls for.
///
/// Returned as a LIST OF SLIVERS rather than one widget so the caller can put
/// its own slivers above them in the same scroll view. A self-scrolling grid
/// nested inside another scroll view is the classic way to end up with two
/// scrollbars and a grid that will not reach its own end.
///
/// Shared by the hub's category tab and the See-all screen: the two are the
/// same grid with a different query, and keeping one implementation is what
/// stops "load more" from being fixed in one of them and not the other.
class PagedPosterGrid {
  const PagedPosterGrid._();

  static List<Widget> build({
    required BuildContext context,
    required PagedCatalogueState state,
    required double maxWidth,
    required void Function(VideoContent content) onItemTap,

    /// Titles for which a premium marker should be drawn. Resolved by the
    /// caller from AccessPolicy.
    bool Function(VideoContent)? isPremiumFor,
    required VoidCallback onRetry,
    required String emptyMessage,
    IconData emptyIcon = Icons.video_library_outlined,
    String? emptyActionLabel,
    VoidCallback? onEmptyAction,

    /// Draw 1..n numerals. Used by ranked lists (trending).
    bool ranked = false,
  }) {
    if (state.isLoadingFirstPage) {
      return <Widget>[
        const SliverToBoxAdapter(child: PosterSkeletonGrid(count: 12)),
      ];
    }

    // An error with nothing on screen is a dead end and gets the retry
    // treatment. An error AFTER some pages loaded is handled in the footer —
    // throwing away what the user is already reading would be worse than the
    // failure itself.
    if (state.error != null && state.items.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: HubErrorState(
            error: state.error,
            detail: state.error.toString(),
            onRetry: onRetry,
          ),
        ),
      ];
    }

    if (state.isEmpty) {
      return <Widget>[
        SliverToBoxAdapter(
          child: HubEmptyState(
            message: emptyMessage,
            icon: emptyIcon,
            actionLabel: emptyActionLabel,
            onAction: onEmptyAction,
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(
          PosterMetrics.gridPadding,
          8,
          PosterMetrics.gridPadding,
          0,
        ),
        sliver: SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: PosterMetrics.gridColumns,
            crossAxisSpacing: PosterMetrics.gridSpacing,
            mainAxisSpacing: 14,
            // Absolute height, derived from the poster aspect — see
            // poster_metrics.dart for why this is not childAspectRatio.
            mainAxisExtent: PosterMetrics.gridExtent(context, maxWidth),
          ),
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = state.items[index];
              return PosterCard(
                content: item,
                rank: ranked ? index + 1 : null,
                premium: isPremiumFor?.call(item) ?? false,
                onTap: () => onItemTap(item),
              );
            },
            childCount: state.items.length,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: _GridFooter(state: state, onRetry: onRetry),
      ),
      // Clears the system navigation bar. Without it the last row of posters
      // ends underneath the Recent/Home/Back buttons on every phone running
      // Android 15 or later.
      SliverToBoxAdapter(
        child: SizedBox(height: VhInsets.scrollBottom(context, extra: 8)),
      ),
    ];
  }
}

class _GridFooter extends StatelessWidget {
  final PagedCatalogueState state;
  final VoidCallback onRetry;

  const _GridFooter({required this.state, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    if (state.isLoadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 22),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (state.error != null && state.items.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: Text(AppStrings.of(context).vhRetry),
          ),
        ),
      );
    }
    // No "you have reached the end" banner: the grid simply stops, which is
    // what running out of results looks like everywhere else.
    return const SizedBox(height: 24);
  }
}
