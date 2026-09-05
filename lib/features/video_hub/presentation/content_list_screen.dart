import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/content_filters.dart';
import 'content_detail_screen.dart';
import 'paged_catalogue.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'widgets/filter_sheet.dart';
import 'widgets/filter_toolbar.dart';
import 'widgets/paged_poster_grid.dart';
import 'widgets/sticky_bar.dart';
import 'account_provider.dart';

/// The full list behind one landing row.
///
/// Reached from any row's "See all". Trending, New releases and Top rated span
/// EVERY category here - films, series and clips in one ranked list, which is
/// what someone means by "show me what is popular", not "show me popular films
/// and make me repeat that for series".
///
/// Opens in the row's own ordering ([ContentRow.defaultSort]) so the first
/// screenful continues the row the user tapped, then lets them re-sort.
class ContentListScreen extends ConsumerStatefulWidget {
  final String rowKey;
  final String title;
  final ContentSort initialSort;

  /// Draw 1..n numerals - true for rows whose ordering is the point.
  final bool ranked;

  const ContentListScreen({
    super.key,
    required this.rowKey,
    required this.title,
    this.initialSort = ContentSort.popular,
    this.ranked = false,
  });

  @override
  ConsumerState<ContentListScreen> createState() => _ContentListScreenState();
}

class _ContentListScreenState extends ConsumerState<ContentListScreen> {
  final ScrollController _scroll = ScrollController();
  late ContentFilters _filters;

  @override
  void initState() {
    super.initState();
    _filters = ContentFilters(sort: widget.initialSort);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Fetch the next page BEFORE the user reaches the bottom, so the grid keeps
  /// growing under the thumb instead of stopping dead and then jerking.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      ref.read(pagedCatalogueProvider(_key()).notifier).loadMore();
    }
  }

  CatalogueKey _key() => CatalogueKey.row(
        widget.rowKey,
        filters: _filters,
      );

  /// Counts matches for a candidate filter set, so the filter sheet can say
  /// "Show 24 titles" before anything is applied.
  Future<int> _countFor(ContentFilters candidate) async {
    final page = await ref.read(contentRepositoryProvider).getRowCatalogue(
          rowKey: widget.rowKey,
          filters: candidate,
          pageSize: 1,
        );
    return page.totalCount;
  }

  void _setFilters(ContentFilters next) {
    setState(() => _filters = next);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // Watched so a purchase made from a detail screen repaints these badges
    // when the user comes back.
    final tier = ref.watch(viewerProvider).tier;
    final key = CatalogueKey.row(
      widget.rowKey,
      filters: _filters,
    );
    final state = ref.watch(pagedCatalogueProvider(key));
    final facets = ref
        .watch(rowFacetsProvider(RowFacetsArg(widget.rowKey)))
        .asData
        ?.value;
    final maxWidth = MediaQuery.of(context).size.width;

    return Scaffold(
      backgroundColor: VH.canvas,
      appBar: AppBar(
        backgroundColor: VH.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(widget.title, style: VH.heading),
      ),
      body: RefreshIndicator(
        onRefresh: () =>
            ref.read(pagedCatalogueProvider(key).notifier).refresh(),
        backgroundColor: VH.surface2,
        color: VH.textPrimary,
        child: CustomScrollView(
          controller: _scroll,
          // Without this, a result set shorter than the screen cannot be
          // pulled, so refresh silently stops working exactly when the list
          // looks wrong and the user most wants to retry.
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: <Widget>[
            if (facets != null && !facets.isEmpty)
              SliverPersistentHeader(
                pinned: true,
                delegate: StickyBar(
                  height: FilterToolbar.height,
                  child: FilterToolbar(
                    filters: _filters,
                    resultCount:
                        state.isLoadingFirstPage ? null : state.totalCount,
                    onSortChanged: (sort) =>
                        _setFilters(_filters.copyWith(sort: sort)),
                    onOpenFilters: () async {
                      final next = await FilterSheet.show(
                        context,
                        facets: facets,
                        initial: _filters,
                        countFor: _countFor,
                      );
                      if (next != null) _setFilters(next);
                    },
                  ),
                ),
              ),
            if (!_filters.isEmpty)
              SliverToBoxAdapter(
                child: ActiveFilterChips(
                  filters: _filters,
                  onChanged: _setFilters,
                ),
              ),
            ...PagedPosterGrid.build(
              context: context,
              state: state,
              maxWidth: maxWidth,
              isPremiumFor: (item) => ref
                  .read(accessPolicyProvider)
                  .showsPremiumBadge(item, tier),
              // Numerals only while the row's own ordering still holds. A rank
              // that survives a re-sort is a lie about the ordering.
              ranked: widget.ranked && _filters.sort == widget.initialSort,
              onItemTap: (item) => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ContentDetailScreen(content: item),
                ),
              ),
              onRetry: () =>
                  ref.read(pagedCatalogueProvider(key).notifier).refresh(),
              emptyMessage:
                  _filters.isEmpty ? s.vhNoContent : s.vhNoMatchingContent,
              emptyIcon: _filters.isEmpty
                  ? Icons.video_library_outlined
                  : Icons.filter_alt_off_outlined,
              emptyActionLabel: _filters.isEmpty ? null : s.vhClearAll,
              onEmptyAction: _filters.isEmpty
                  ? null
                  : () => _setFilters(_filters.cleared()),
            ),
          ],
        ),
      ),
    );
  }
}
