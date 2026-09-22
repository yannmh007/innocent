import '../domain/access.dart';
import '../domain/access_policy.dart';
import '../domain/content_category.dart';
import '../domain/viewer.dart';
import '../domain/content_filters.dart';
import '../domain/content_repository.dart';
import '../domain/video_content.dart';
import '../domain/account_repository.dart';
import 'demo_content_datasource.dart';
import 'local_account_repository.dart';

/// [ContentRepository] backed by the bundled demo catalogue.
///
/// This is the FIRST adapter, not the only one. When a backend arrives, add a
/// sibling (e.g. `ApiContentRepository`) and change the one provider that
/// picks between them — every screen, widget and provider above this line
/// stays exactly as it is.
///
/// All the query logic (filter, sort, facet, search) lives HERE rather than in
/// the widgets, so a future remote adapter can push the same work to the
/// server without the UI noticing the difference.
class DemoContentRepository implements ContentRepository {
  DemoContentRepository({
    DemoContentDataSource? source,
    AccountRepository? account,
  })  : _source = source ?? const DemoContentDataSource(),
        _account = account ?? const LocalAccountRepository();

  final DemoContentDataSource _source;

  /// The repository owns the access decision, not the UI. See
  /// [ContentRepository.requestPlayback] for why that placement is the whole
  /// point of the design.
  final AccountRepository _account;

  /// Simulated latency. Real enough that loading states get exercised during
  /// review — a UI only ever tested against instant data ships with untested
  /// spinners.
  static const Duration _latency = Duration(milliseconds: 220);

  /// The whole catalogue, with any views recorded this session folded in.
  ///
  /// No filtering left to do: the adult CATEGORY is gone because the whole
  /// catalogue is adult now, and the 18+ decision happens at the door.
  List<VideoContent> _visible() => _source.all().map(_withViews).toList();

  @override
  Future<VideoContent?> getFeatured() async {
    await Future<void>.delayed(_latency);
    final pool = _visible()
        .where((e) => e.category != ContentCategory.reels)
        .toList();
    if (pool.isEmpty) return null;
    // Most popular of the full-length titles. A 30-second clip in the hero
    // would undercut the whole point of presenting one thing large.
    pool.sort(_byViews);
    return pool.first;
  }

  @override
  Future<List<ContentRow>> getRows() async {
    await Future<void>.delayed(_latency);
    final pool = _visible();

    List<VideoContent> byCategory(ContentCategory c) =>
        pool.where((e) => e.category == c).toList();

    final newest = pool.toList()
      ..sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));

    final trending = pool.toList()..sort(_byViews);

    final rows = <ContentRow>[
      ContentRow(
        key: kRowTrending,
        fallbackTitle: 'Trending now',
        items: trending.take(12).toList(),
        defaultSort: ContentSort.popular,
        // Numbered, because the ordering IS the content of this row.
        ranked: true,
      ),
      ContentRow(
        key: kRowNewReleases,
        fallbackTitle: 'New releases',
        items: newest.take(12).toList(),
        defaultSort: ContentSort.newest,
      ),
      ContentRow(
        key: kRowMovies,
        fallbackTitle: 'Movies',
        items: byCategory(ContentCategory.movies).take(12).toList(),
        defaultSort: ContentSort.popular,
      ),
      ContentRow(
        key: kRowSeries,
        fallbackTitle: 'Series',
        items: byCategory(ContentCategory.series).take(12).toList(),
        defaultSort: ContentSort.popular,
      ),
      ContentRow(
        key: kRowReels,
        fallbackTitle: 'Reels',
        items: byCategory(ContentCategory.reels).take(12).toList(),
        defaultSort: ContentSort.popular,
      ),
    ];

    // An empty row is worse than no row: it reads as a broken screen.
    return rows.where((r) => !r.isEmpty).toList();
  }

  /// Views first, then title, so a row of equally-watched titles has a stable
  /// order instead of an arbitrary one that reshuffles on every fetch.
  static int _byViews(VideoContent a, VideoContent b) {
    final c = (b.viewCount ?? 0).compareTo(a.viewCount ?? 0);
    if (c != 0) return c;
    return a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  /// Which entries a landing row covers.
  ///
  /// Trending, New releases and Top rated deliberately span EVERY category —
  /// films, series and clips compete in one list, which is what a user means
  /// by "what is popular right now".
  List<VideoContent> _rowScope(String rowKey) {
    final pool = _visible();
    switch (rowKey) {
      case kRowMovies:
        return pool
            .where((e) => e.category == ContentCategory.movies)
            .toList();
      case kRowSeries:
        return pool
            .where((e) => e.category == ContentCategory.series)
            .toList();
      case kRowReels:
        return pool
            .where((e) => e.category == ContentCategory.reels)
            .toList();
      default:
        return pool;
    }
  }

  List<VideoContent> _applyFilters(
      List<VideoContent> list, ContentFilters filters) {
    var out = list;
    if (filters.genres.isNotEmpty) {
      out = out.where((e) => e.genres.any(filters.genres.contains)).toList();
    }
    if (filters.year != null) {
      out = out.where((e) => e.year == filters.year).toList();
    }
    if (filters.quality != null) {
      out = out.where((e) => e.qualityLabel == filters.quality).toList();
    }
    return out;
  }

  void _applySort(List<VideoContent> list, ContentSort sort) {
    switch (sort) {
      case ContentSort.popular:
        list.sort(_byViews);
        break;
      case ContentSort.newest:
        list.sort((a, b) => (b.year ?? 0).compareTo(a.year ?? 0));
        break;
      case ContentSort.titleAsc:
        list.sort((a, b) =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
    }
  }

  static ContentPage _page(List<VideoContent> list, int page, int pageSize) {
    final total = list.length;
    final start = page * pageSize;
    if (start >= total) {
      return ContentPage(
          items: const <VideoContent>[], hasMore: false, totalCount: total);
    }
    final end = (start + pageSize) > total ? total : (start + pageSize);
    return ContentPage(
      items: list.sublist(start, end),
      hasMore: end < total,
      totalCount: total,
    );
  }

  static ContentFacets _facetsOf(List<VideoContent> list) {
    final genres = <String>{};
    final years = <int>{};
    final qualities = <String>{};
    for (final e in list) {
      genres.addAll(e.genres);
      if (e.year != null) years.add(e.year!);
      if (e.qualityLabel != null) qualities.add(e.qualityLabel!);
    }
    final g = genres.toList()..sort();
    final y = years.toList()..sort((a, b) => b.compareTo(a));
    final q = qualities.toList()..sort();
    return ContentFacets(genres: g, years: y, qualities: q);
  }

  @override
  Future<ContentPage> getRowCatalogue({
    required String rowKey,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  }) async {
    await Future<void>.delayed(_latency);
    final list = _applyFilters(_rowScope(rowKey), filters);
    _applySort(list, filters.sort);
    return _page(list, page, pageSize);
  }

  @override
  Future<ContentFacets> getRowFacets({required String rowKey}) async {
    return _facetsOf(_rowScope(rowKey));
  }

  @override
  Future<ContentPage> getCatalogue({
    required ContentCategory category,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  }) async {
    await Future<void>.delayed(_latency);

    // The catalogue call is category-scoped, so restricted content is only
    // reachable by explicitly asking for that category — which the tab bar
    // only offers once the gate has been passed.
    var list = _source
        .all()
        .where((e) =>
            category == ContentCategory.all || e.category == category)
        .toList();

    list = _applyFilters(list, filters);
    _applySort(list, filters.sort);
    return _page(list, page, pageSize);
  }

  /// The bundled catalogue has no server to have an opinion, so it has none.
  /// Every caller then falls back to the enum and the compiled strings, which
  /// is exactly what this build has always shown.
  @override
  Future<CategoryCatalogue> getCategories() async => CategoryCatalogue.empty;

  @override
  Future<ContentFacets> getFacets({required ContentCategory category}) async {
    final list = _source
        .all()
        .where((e) =>
            category == ContentCategory.all || e.category == category)
        .toList();

    return _facetsOf(list);
  }

  @override
  Future<List<VideoContent>> search(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const <VideoContent>[];
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final pool = _visible();

    final hits = pool
        .where((e) {
          final hay = e.searchHaystack;
          // Every term must appear: "demo 2024" should narrow, not widen.
          return terms.every(hay.contains);
        })
        .toList();

    // Title matches before incidental genre/year matches.
    hits.sort((a, b) {
      final at = a.title.toLowerCase().contains(terms.first) ? 0 : 1;
      final bt = b.title.toLowerCase().contains(terms.first) ? 0 : 1;
      if (at != bt) return at - bt;
      return a.title.compareTo(b.title);
    });
    return hits;
  }

  /// Local increments, so opening a title visibly moves its count during
  /// review. The real counter lives on the server - a client-authored one
  /// would be a number the user could type.
  static final Map<String, int> _viewDelta = <String, int>{};

  @override
  Future<void> recordView(String contentId, {ViewerTier? tier}) async {
    _viewDelta[contentId] = (_viewDelta[contentId] ?? 0) + 1;
  }

  static VideoContent _withViews(VideoContent c) {
    final extra = _viewDelta[c.id];
    if (extra == null) return c;
    return c.copyWithViews((c.viewCount ?? 0) + extra);
  }

  @override
  Future<VideoContent?> getById(String id) async {
    for (final e in _source.all()) {
      if (e.id == id) return e;
    }
    return null;
  }

  @override
  Future<PlaybackGrant> requestPlayback({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
  }) async {
    // ORDER MATTERS. Entitlement is checked BEFORE availability, so a free
    // viewer is told they need premium rather than that the title is broken.
    // Answering "unavailable" to someone who simply has not paid loses a sale
    // and reads as a bug.
    final e = await _account.entitlement();
    if (!AccessPolicy.standard
        .canPlayTitle(content, ViewerTierX.fromEntitlement(e))) {
      return const PlaybackGrant.denied(AccessDenial.needsPremium);
    }
    // The demo catalogue holds no real media. Refusing is the honest answer
    // and drives the same path a dead backend would.
    return const PlaybackGrant.denied(AccessDenial.unavailable);
  }

  @override
  Future<String?> resolveImageUrl(MediaRef ref) async =>
      resolveImageUrlSync(ref);

  @override
  String? resolveImageUrlSync(MediaRef ref) {
    // The bundled catalogue ships no artwork, so every tile is a generated
    // placeholder. Answering synchronously means it is drawn once instead of
    // being replaced a frame later.
    return '';
  }
}
