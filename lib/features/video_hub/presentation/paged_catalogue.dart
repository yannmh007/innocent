import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/content_category.dart';
import '../domain/content_filters.dart';
import '../domain/content_repository.dart';
import '../domain/video_content.dart';
import 'video_hub_provider.dart';

/// Identity of one paged query.
///
/// A Riverpod family argument, so `==` and `hashCode` are load-bearing: two
/// keys that compare equal share a notifier (and its already-loaded pages),
/// two that differ get a fresh list. Filters are compared by
/// [ContentFilters.signature] because the same filter set built in a different
/// order must not be treated as a different query and re-fetch everything.
@immutable
class CatalogueKey {
  /// Exactly one of these is set. [rowKey] means a landing row's full list
  /// (which may span categories); [category] means one category's catalogue.
  final String? rowKey;
  final ContentCategory? category;

  final ContentFilters filters;
  const CatalogueKey.row(this.rowKey, {required this.filters})
      : category = null;

  const CatalogueKey.category(this.category, {required this.filters})
      : rowKey = null;

  @override
  bool operator ==(Object other) =>
      other is CatalogueKey &&
      other.rowKey == rowKey &&
      other.category == category &&
      other.filters.signature == filters.signature;

  @override
  int get hashCode => Object.hash(
        rowKey,
        category,
        filters.signature,
      );

  @override
  String toString() =>
      'CatalogueKey(${rowKey ?? category?.id}, ${filters.signature})';
}

/// What the grid needs to draw itself at any moment.
///
/// One object rather than several providers: "loading the first page",
/// "loading more" and "nothing left" are mutually constraining states, and
/// splitting them is how a screen ends up showing a spinner under an empty
/// list.
@immutable
class PagedCatalogueState {
  final List<VideoContent> items;
  final bool isLoadingFirstPage;
  final bool isLoadingMore;
  final bool hasMore;
  final int totalCount;

  /// Set only for a real failure. An empty result is NOT an error.
  final Object? error;

  const PagedCatalogueState({
    this.items = const <VideoContent>[],
    this.isLoadingFirstPage = true,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.totalCount = 0,
    this.error,
  });

  bool get isEmpty =>
      items.isEmpty && !isLoadingFirstPage && error == null;

  PagedCatalogueState copyWith({
    List<VideoContent>? items,
    bool? isLoadingFirstPage,
    bool? isLoadingMore,
    bool? hasMore,
    int? totalCount,
    Object? error,
    bool clearError = false,
  }) {
    return PagedCatalogueState(
      items: items ?? this.items,
      isLoadingFirstPage: isLoadingFirstPage ?? this.isLoadingFirstPage,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      totalCount: totalCount ?? this.totalCount,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

/// Loads a catalogue one page at a time.
///
/// Paging is not optional at catalogue scale. Fetching four hundred posters to
/// show nine is slow on a good connection and a wall on a bad one, and this
/// app is built for phones where the connection is the constraint.
class PagedCatalogueNotifier extends StateNotifier<PagedCatalogueState> {
  PagedCatalogueNotifier(this._repo, this._key)
      : super(const PagedCatalogueState()) {
    _loadFirstPage();
  }

  final ContentRepository _repo;
  final CatalogueKey _key;

  static const int _pageSize = 30;

  int _nextPage = 0;

  /// Guards against a second fetch while one is in flight. The scroll listener
  /// fires on every pixel, so without this a single flick at the bottom of the
  /// list queues a dozen identical requests.
  bool _busy = false;

  Future<ContentPage> _fetch(int page) {
    final rowKey = _key.rowKey;
    if (rowKey != null) {
      return _repo.getRowCatalogue(
        rowKey: rowKey,
        filters: _key.filters,
        page: page,
        pageSize: _pageSize,
      );
    }
    return _repo.getCatalogue(
      category: _key.category ?? ContentCategory.all,
      filters: _key.filters,
      page: page,
      pageSize: _pageSize,
    );
  }

  Future<void> _loadFirstPage() async {
    _busy = true;
    try {
      final page = await _fetch(0);
      // autoDispose: the user can leave before this resolves, and writing to
      // `state` after that throws.
      if (!mounted) return;
      _nextPage = 1;
      state = PagedCatalogueState(
        items: page.items,
        isLoadingFirstPage: false,
        hasMore: page.hasMore,
        totalCount: page.totalCount,
      );
    } catch (e) {
      if (!mounted) return;
      state = PagedCatalogueState(isLoadingFirstPage: false, error: e);
    } finally {
      _busy = false;
    }
  }

  Future<void> loadMore() async {
    if (_busy || !state.hasMore || state.isLoadingFirstPage) return;
    _busy = true;
    state = state.copyWith(isLoadingMore: true);
    try {
      final page = await _fetch(_nextPage);
      if (!mounted) return;
      _nextPage += 1;
      state = state.copyWith(
        items: <VideoContent>[...state.items, ...page.items],
        isLoadingMore: false,
        hasMore: page.hasMore,
        totalCount: page.totalCount,
      );
    } catch (e) {
      if (!mounted) return;
      // A failed NEXT page must not discard the pages already on screen —
      // stop paging, keep what the user is looking at.
      state = state.copyWith(isLoadingMore: false, hasMore: false, error: e);
    } finally {
      _busy = false;
    }
  }

  Future<void> refresh() async {
    if (!mounted) return;
    _nextPage = 0;
    state = const PagedCatalogueState();
    await _loadFirstPage();
  }
}

final pagedCatalogueProvider = StateNotifierProvider.autoDispose
    .family<PagedCatalogueNotifier, PagedCatalogueState, CatalogueKey>(
  (ref, key) => PagedCatalogueNotifier(
    ref.watch(contentRepositoryProvider),
    key,
  ),
);
