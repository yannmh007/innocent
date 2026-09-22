import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/content_category.dart';
import '../domain/content_filters.dart';
import '../domain/video_content.dart';
import 'account/account_screen.dart';
import 'account_provider.dart';
import 'content_detail_screen.dart';
import 'content_list_screen.dart';
import 'paged_catalogue.dart';
import 'playback.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'video_search_screen.dart';
import 'widgets/category_tab_bar.dart';
import 'widgets/content_row_view.dart';
import 'widgets/featured_hero.dart';
import 'widgets/filter_sheet.dart';
import 'widgets/filter_toolbar.dart';
import 'widgets/hub_states.dart';
import 'widgets/paged_poster_grid.dart';
import 'widgets/sticky_bar.dart';
import 'widgets/vh_insets.dart';

/// The Video Hub: Innocent's remote-content surface.
///
/// LAYOUT, top to bottom:
///   1. a search field that covers the WHOLE catalogue, not the current tab;
///   2. a pinned category bar;
///   3. on "All": a featured title, then curated rows.
///      on a category: a filter toolbar, applied-filter chips, a paged grid.
///
/// The split at (3) is the design decision worth keeping: browsing and
/// searching are different jobs. Someone with nothing particular in mind is
/// served by a feature and rows - one focal point, then cheap glances.
/// Someone who has already decided "a film, 2024, 4K" is served by a grid with
/// filters, and rows would be in the way.
class VideoHubScreen extends ConsumerStatefulWidget {
  const VideoHubScreen({super.key});

  @override
  ConsumerState<VideoHubScreen> createState() => _VideoHubScreenState();
}

class _VideoHubScreenState extends ConsumerState<VideoHubScreen>
    with WidgetsBindingObserver {
  final ScrollController _scroll = ScrollController();

  /// Rate-limits the resume refresh. Android delivers `resumed` for things
  /// that are not a return to the app - a dismissed permission dialog, a
  /// notification shade - and refetching on every one of those is a request
  /// storm for no information.
  DateTime? _lastEntitlementCheck;
  static const Duration _minRecheckGap = Duration(seconds: 20);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // The payment flow leaves the app: pay in KPay, come back. Approval
    // happens while we are in the background, so returning is exactly when
    // the entitlement has most likely changed.
    final last = _lastEntitlementCheck;
    if (last != null && DateTime.now().difference(last) < _minRecheckGap) {
      return;
    }
    _lastEntitlementCheck = DateTime.now();
    ref.read(accountProvider.notifier).refresh();
  }

  /// Fetch the next page BEFORE the bottom arrives, so the grid grows under
  /// the thumb rather than stopping dead and then jerking forward.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (ref.read(selectedCategoryProvider).showsRows) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      ref.read(pagedCatalogueProvider(_categoryKey()).notifier).loadMore();
    }
  }

  CatalogueKey _categoryKey() => CatalogueKey.category(
        ref.read(selectedCategoryProvider),
        filters: ref.read(contentFiltersProvider),
      );

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final selected = ref.watch(selectedCategoryProvider);
    // Order and visibility from the server where it has an opinion, the
    // compiled enum where it does not — including before the first fetch
    // returns and whenever the phone is offline. See CategoryCatalogue.
    final styles = ref.watch(categoryStylesProvider);
    final categories = styles.visible();
    // Watched here so a purchase anywhere in the feature repaints every badge
    // on this screen at once.
    ref.watch(viewerProvider);

    return Scaffold(
      backgroundColor: VH.canvas,
      // NOT SafeArea(bottom: false). Android 15 enforces edge-to-edge for
      // every app targeting API 35, so content is drawn BEHIND the navigation
      // bar by default - which is exactly why the Recent/Home/Back bar was
      // covering the last row of posters.
      //
      // The scroll view still runs edge to edge (that is the modern look and
      // what the platform wants); the fix is that its CONTENT gets bottom
      // padding equal to the system inset, so the last row clears the bar
      // while artwork still scrolls behind it. See VhInsets.
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: () => _refresh(selected),
          backgroundColor: VH.surface2,
          color: VH.textPrimary,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: <Widget>[
              _buildSearchBar(context, s),
              SliverPersistentHeader(
                pinned: true,
                delegate: StickyBar(
                  height: CategoryTabBar.height,
                  child: CategoryTabBar(
                    categories: categories,
                    selected: selected,
                    styles: styles,
                    onSelected: _selectCategory,
                  ),
                ),
              ),
              if (selected.showsRows)
                ..._buildLanding(context, s)
              else
                ..._buildCategoryGrid(context, s),
              // Clears the system navigation bar, which Android 15 draws OVER
              // the content by default.
              SliverToBoxAdapter(
                child: SizedBox(height: VhInsets.bottom(context)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Pull-to-refresh refreshes whatever the current tab is actually showing.
  Future<void> _refresh(ContentCategory selected) async {
    if (selected.showsRows) {
      ref.invalidate(featuredContentProvider);
      ref.invalidate(contentRowsProvider);
      return;
    }
    await ref.read(pagedCatalogueProvider(_categoryKey()).notifier).refresh();
  }

  /// Selecting a category also clears the secondary filters and returns to the
  /// top.
  ///
  /// A genre that exists under Movies may not exist under Reels; carrying the
  /// selection across is how someone lands on an empty grid with no visible
  /// reason. And staying scrolled deep while the content underneath changes
  /// completely is disorienting - the new tab starts at its start.
  void _selectCategory(ContentCategory category) {
    ref.read(selectedCategoryProvider.notifier).state = category;
    ref.read(contentFiltersProvider.notifier).state = const ContentFilters();
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _buildSearchBar(BuildContext context, AppStrings s) {
    return SliverAppBar(
      backgroundColor: VH.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      pinned: false,
      floating: true,
      titleSpacing: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back, color: VH.textPrimary),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: _SearchField(
        hint: s.vhSearchHint,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const VideoSearchScreen()),
        ),
      ),
      actions: <Widget>[
        // A user avatar, not an overflow menu. "⋮" is where features go to be
        // forgotten; a face is a destination people look for by habit, and it
        // can also SHOW state - signed out, signed in, VIP - which a dot
        // column never can.
        Padding(
          padding: const EdgeInsets.only(right: VH.s2),
          child: _AccountButton(onTap: () => _openAccount(context)),
        ),
      ],
    );
  }

  /// Account and subscription status.
  ///
  /// One destination whether or not the viewer has paid: status, expiry and
  /// the queue of payment requests all live there. Branching to a paywall for
  /// free users would hide the one screen that answers "did my payment go
  /// through?" from the people most likely to be asking.
  Future<void> _openAccount(BuildContext context) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const AccountScreen()),
    );
  }

  // ---- landing tab ---------------------------------------------------------

  List<Widget> _buildLanding(BuildContext context, AppStrings s) {
    return <Widget>[
      ..._buildHero(context),
      ..._buildRows(context, s),
    ];
  }

  List<Widget> _buildHero(BuildContext context) {
    final featured = ref.watch(featuredContentProvider).asData?.value;
    if (featured == null) return const <Widget>[];
    return <Widget>[
      SliverToBoxAdapter(
        child: FeaturedHero(
          content: featured,
          // Play PLAYS. Sending it to the detail screen would make the most
          // prominent button on the page a lie about what it does; if there is
          // nothing to play the shared helper says so.
          onPlay: () => playContent(context, ref, featured),
          onInfo: () => _openDetail(context, featured),
        ),
      ),
    ];
  }

  List<Widget> _buildRows(BuildContext context, AppStrings s) {
    final rowsAsync = ref.watch(contentRowsProvider);

    return rowsAsync.when(
      loading: () => <Widget>[
        // Row-shaped, not grid-shaped: this tab is about to show rows.
        const SliverToBoxAdapter(child: RowSkeletonList()),
      ],
      error: (error, _) => <Widget>[
        SliverToBoxAdapter(
          child: HubErrorState(
            detail: error.toString(),
            onRetry: () => ref.invalidate(contentRowsProvider),
          ),
        ),
      ],
      data: (rows) {
        if (rows.isEmpty) {
          return <Widget>[
            SliverToBoxAdapter(
              child: HubEmptyState(
                message: s.vhNoContent,
                icon: Icons.video_library_outlined,
              ),
            ),
          ];
        }
        return <Widget>[
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final row = rows[index];
                return ContentRowView(
                  row: row,
                  title: rowTitle(s, row),
                  onItemTap: (item) => _openDetail(context, item),
                  onSeeAll: _openSeeAll,
                  isPremiumFor: _isPremiumFor,
                );
              },
              childCount: rows.length,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: VH.s6)),
        ];
      },
    );
  }

  // ---- category tab --------------------------------------------------------

  List<Widget> _buildCategoryGrid(BuildContext context, AppStrings s) {
    final category = ref.watch(selectedCategoryProvider);
    final filters = ref.watch(contentFiltersProvider);
    final key = CatalogueKey.category(
      category,
      filters: filters,
    );
    final state = ref.watch(pagedCatalogueProvider(key));
    final facets = ref.watch(categoryFacetsProvider).asData?.value;
    final maxWidth = MediaQuery.of(context).size.width;

    // Filters changed means a different result set, so the old scroll offset
    // points at nothing meaningful - land the user on the new first row
    // rather than halfway down a list they have not seen.
    void setFilters(ContentFilters next) {
      ref.read(contentFiltersProvider.notifier).state = next;
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }

    return <Widget>[
      // Pinned: scrolling deep into a grid and then having to scroll all the
      // way back to change a genre is why people stop using filters.
      if (facets != null && !facets.isEmpty)
        SliverPersistentHeader(
          pinned: true,
          delegate: StickyBar(
            height: FilterToolbar.height,
            child: FilterToolbar(
              filters: filters,
              resultCount: state.isLoadingFirstPage ? null : state.totalCount,
              onSortChanged: (sort) =>
                  setFilters(filters.copyWith(sort: sort)),
              onOpenFilters: () async {
                final next = await FilterSheet.show(
                  context,
                  facets: facets,
                  initial: filters,
                  countFor: (candidate) => _countFor(
                    category: category,
                    filters: candidate,
                  ),
                );
                if (next != null) setFilters(next);
              },
            ),
          ),
        ),
      if (!filters.isEmpty)
        SliverToBoxAdapter(
          child: ActiveFilterChips(filters: filters, onChanged: setFilters),
        ),
      ...PagedPosterGrid.build(
        context: context,
        state: state,
        maxWidth: maxWidth,
        isPremiumFor: _isPremiumFor,
        onItemTap: (item) => _openDetail(context, item),
        onRetry: () =>
            ref.read(pagedCatalogueProvider(key).notifier).refresh(),
        emptyMessage:
            filters.isEmpty ? s.vhNoContent : s.vhNoMatchingContent,
        emptyIcon: filters.isEmpty
            ? Icons.video_library_outlined
            : Icons.filter_alt_off_outlined,
        emptyActionLabel: filters.isEmpty ? null : s.vhClearAll,
        onEmptyAction:
            filters.isEmpty ? null : () => setFilters(filters.cleared()),
      ),
    ];
  }

  /// Counts matches for a candidate filter set, so the filter sheet can say
  /// "Show 24 titles" before anything is applied.
  Future<int> _countFor({
    required ContentCategory category,
    required ContentFilters filters,
  }) async {
    final page = await ref.read(contentRepositoryProvider).getCatalogue(
          category: category,
          filters: filters,
          pageSize: 1,
        );
    return page.totalCount;
  }

  /// Should this title carry a premium marker for the current viewer?
  bool _isPremiumFor(VideoContent content) => ref
      .read(accessPolicyProvider)
      .showsPremiumBadge(content, ref.read(viewerProvider).tier);

  // ---- navigation ----------------------------------------------------------

  void _openSeeAll(ContentRow row, String resolvedTitle) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContentListScreen(
          rowKey: row.key,
          title: resolvedTitle,
          initialSort: row.defaultSort,
          ranked: row.ranked,
        ),
      ),
    );
  }

  static void _openDetail(BuildContext context, VideoContent content) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContentDetailScreen(content: content),
      ),
    );
  }

  /// Row headings are carried as KEYS, resolved here, so a row shipped from a
  /// backend is still shown in the user's language.
  static String rowTitle(AppStrings s, ContentRow row) {
    switch (row.key) {
      case kRowTrending:
        return s.vhRowTrending;
      case kRowNewReleases:
        return s.vhRowNewReleases;
      case kRowMovies:
        return s.vhCategoryMovies;
      case kRowSeries:
        return s.vhCategorySeries;
      case kRowReels:
        return s.vhCategoryReels;
      default:
        return row.fallbackTitle;
    }
  }
}

/// Tap target that looks like a field but opens the search screen.
///
/// A real [TextField] here would raise the keyboard over the content the user
/// came to browse. The search screen owns the keyboard; this owns the
/// affordance.
class _SearchField extends StatelessWidget {
  final String hint;
  final VoidCallback onTap;

  const _SearchField({required this.hint, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: VH.s3),
        decoration: BoxDecoration(
          color: VH.surface1,
          borderRadius: BorderRadius.circular(VH.rControl),
          border: Border.all(color: VH.hairline),
        ),
        child: Row(
          children: <Widget>[
            const Icon(Icons.search_rounded, size: 18, color: VH.textTertiary),
            const SizedBox(width: VH.s2),
            Expanded(
              child: Text(
                hint,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: VH.label.copyWith(
                  color: VH.textTertiary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The account entry point in the app bar.
///
/// Replaced an overflow menu. "⋮" is where features go to be forgotten - it
/// gives no clue what is inside and nobody opens it twice. An avatar is a
/// destination people reach for by habit, and unlike a column of dots it can
/// SHOW state: a hollow outline when signed out, a filled mark when signed in,
/// a VIP ring when paying. The state is the affordance.
class _AccountButton extends ConsumerWidget {
  final VoidCallback onTap;

  const _AccountButton({required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewer = ref.watch(viewerProvider);
    final premium = viewer.isPremium;
    final signedIn = viewer.isSignedIn;

    return Semantics(
      button: true,
      label: AppStrings.of(context).vhAccountTitle,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Center(
            child: Container(
              width: 32,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: signedIn ? VH.surface3 : Colors.transparent,
                shape: BoxShape.circle,
                border: Border.all(
                  // The one place an accent earns its keep on this screen: a
                  // paying viewer's own mark.
                  color: premium ? VH.accent : VH.hairline,
                  width: premium ? 1.5 : 1,
                ),
              ),
              child: Icon(
                signedIn ? Icons.person_rounded : Icons.person_outline_rounded,
                size: 18,
                color: premium ? VH.accent : VH.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
