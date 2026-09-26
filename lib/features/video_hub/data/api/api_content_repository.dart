import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../domain/access.dart';
import '../../domain/rendition.dart';
import '../../domain/content_category.dart';
import '../../domain/content_filters.dart';
import '../../domain/content_repository.dart';
import '../../domain/viewer.dart';
import '../../domain/video_content.dart';
import '../../../../core/services/network/connection_kind.dart';
import '../cache/catalogue_cache.dart';
import 'api_client.dart';
import 'api_exception.dart';

/// [ContentRepository] over the backend described in
/// `docs/premium_backend_spec.md`.
///
/// Two halves with very different rules.
///
/// The CATALOGUE half is ordinary data: titles, posters, genres. It is read
/// straight from the REST endpoint with RLS scoping it to signed-in users, and
/// nothing here is confidential - it is the shop window.
///
/// The PLAYBACK half is the enforcement point. [requestPlayback] does not
/// fetch a URL and check whether the user may use it; it ASKS THE SERVER TO
/// DECIDE, and receives either a signed link or a refusal with a reason. There
/// is deliberately no code path in this class that can produce a playable URL
/// on its own - not a fallback, not a cache, not a retry with different
/// arguments. If the server says no, the answer is no.
///
/// THE CATALOGUE HALF IS CACHED TO DISK and the PLAYBACK HALF IS NOT, and the
/// two helpers below are where that line is drawn. [_cachedGet] and
/// [_cachedPost] remember what the server said and replay it when the server
/// cannot be reached, which is what lets a phone with no signal still draw its
/// rows, its grid and a title's album — see [CatalogueCache]. Neither is used
/// by [requestPlayback], which must ask every single time, and
/// `tool/security_invariants.py` fails the build if that ever changes.
class ApiContentRepository implements ContentRepository {
  ApiContentRepository(this._api);

  final ApiClient _api;

  /// Columns the client is allowed to see. Never `*`.
  ///
  /// The storage locator is NOT in this list and must not be selectable at all
  /// (the spec keeps it in a separate table with no read policy). A `select=*`
  /// here would hand out the real media address and make every other measure
  /// decoration.
  static const String _titleColumns =
      'id,title,title_mm,synopsis,category,poster_url,year,rating,'
      'quality_label,genres,episode_count,view_count,access_tier,'
      'photo_count,video_count';

  // ---- the network, remembered ---------------------------------------------

  /// A catalogue GET whose answer is kept, and replayed when the server cannot
  /// be reached.
  ///
  /// THE FALLBACK IS FOR "COULD NOT ASK", NEVER FOR "WAS TOLD NO". Only a
  /// retryable failure — no connection, a timeout, a 5xx, a 429 — reaches the
  /// cache. A 401, 403 or 404 is the server's actual answer and is rethrown
  /// untouched: serving a remembered catalogue to a session the server has just
  /// rejected would show one account's listing to whoever is holding the phone,
  /// which is the one thing row-level security is there to prevent.
  ///
  /// The write is not awaited. A slow disk must not add latency to a screen
  /// that already has its data.
  Future<dynamic> _cachedGet(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
  }) {
    return _serve(
      CatalogueCache.keyFor(path, query),
      () => _api.getJson(path, query: query, authenticated: authenticated),
    );
  }

  /// Same, for the RPCs. The body is part of the key — `row_catalogue` and
  /// `catalogue_facets` are the same path with different arguments.
  Future<dynamic> _cachedPost(
    String path, {
    required Map<String, dynamic> body,
  }) {
    return _serve(
      CatalogueCache.keyFor(path, body),
      () => _api.postJson(path, body: body),
    );
  }

  /// How long a saved answer will wait for a fresh one before it is shown.
  ///
  /// ═══════════════════════════════════════════════════════════════════════
  /// THIS NUMBER IS THE WHOLE DIFFERENCE BETWEEN "OFFLINE" AND "BROKEN"
  /// ═══════════════════════════════════════════════════════════════════════
  ///
  /// The first version of this waited for the request to FAIL and only then
  /// looked in the cache. That is correct and it is unusable: `BackendConfig
  /// .timeout` is twenty seconds, and a phone with no signal does not always
  /// fail fast — a dead connection frequently hangs rather than refusing, which
  /// is the reason that timeout exists at all. So the landing tab sat on its
  /// skeletons for up to twenty seconds before showing anything, and twenty
  /// seconds of grey rectangles is indistinguishable from an app that does not
  /// work. That is exactly what a viewer reported, with a screenshot.
  ///
  /// Telegram and Facebook do not wait. They draw the last thing they had,
  /// immediately, and quietly replace it when the network answers. So: the
  /// request still goes out, and it still updates the cache when it lands, but
  /// the SAVED copy is shown the moment this much time has passed without an
  /// answer.
  ///
  /// Not zero, because on a working connection showing a saved copy and then
  /// replacing it a moment later is a flicker nobody asked for. The number is
  /// therefore a bet on how long a GOOD request takes, and the first bet was
  /// wrong in the expensive direction.
  ///
  /// TWO AND A HALF SECONDS WAS A GUESS, AND IT WAS FELT. It was chosen to be
  /// comfortably longer than a healthy round trip, which it is — and that is
  /// the mistake: the case it governs is not the healthy one. A healthy
  /// request answers in two or three hundred milliseconds and this timeout
  /// never runs. It runs when the connection is attached and NOT WORKING — a
  /// Wi-Fi with nothing behind it, a SIM out of credit, a cell that holds the
  /// socket open rather than refusing it — which in Myanmar is not an edge
  /// case, it is an afternoon. Every one of those paid the full two and a
  /// half seconds, per screen, with the answer already on the disk. Reported
  /// as "it works, but it is slower than Facebook", which is precisely what
  /// it was.
  ///
  /// Seven hundred milliseconds still clears a good request with room to
  /// spare, and it is under the threshold where waiting reads as the app
  /// thinking rather than the app being stuck. The stale copy is never wrong
  /// for long either way: the request carries on and refreshes the cache
  /// whenever it lands.
  static const Duration _staleAfter = Duration(milliseconds: 700);

  /// Answers from the network, or from what was saved, whichever can answer.
  ///
  /// THE FALLBACK IS FOR "COULD NOT ASK" AND FOR "HAS NOT ANSWERED YET", NEVER
  /// FOR "WAS TOLD NO". A 401, 403 or 404 is the server's actual answer and is
  /// rethrown untouched: serving a remembered catalogue to a session the server
  /// has just rejected would show one account's listing to whoever is holding
  /// the phone, which is the one thing row-level security is there to prevent.
  Future<dynamic> _serve(String key, Future<dynamic> Function() fetch) async {
    // The local answer first, because whether there IS one changes what the
    // network attempt is allowed to cost. A small JSON file off flash: single
    // digit milliseconds, and it is the price of never showing a blank screen.
    final cached = await CatalogueCache.read(key, quiet: true);

    // ─── NO RADIO, NO WAIT ───────────────────────────────────────────────
    //
    // Asking the platform what is attached is a synchronous lookup with no DNS
    // and no socket in it, and it answers the one question a timeout can only
    // guess at. Without this the no-cache path below still spent the full
    // twenty seconds on a phone in aeroplane mode before admitting there was
    // no connection — twenty seconds of skeletons, which is what a viewer
    // photographed and reported as "it does not work".
    //
    // `none` is the only value that skips the attempt. An unreadable platform
    // reports `other`, so a phone this cannot measure still tries the network
    // exactly as before — the safe direction, because the alternative is
    // refusing to load a catalogue on a device that is perfectly online.
    final kind = await ConnectionInfo.read();
    if (kind.isOffline) {
      if (cached != null) {
        CatalogueCache.noteServedFromCache();
        return cached;
      }
      throw const ApiException(
        ApiErrorKind.network,
        message: 'no connection',
      );
    }

    if (cached == null) {
      // Nothing saved, so the network is the only answer there is and it gets
      // the full timeout: a slow connection that WILL answer must not be cut
      // off, because there is nothing to show instead.
      final body = await fetch();
      unawaited(CatalogueCache.write(key, body));
      CatalogueCache.noteServedLive();
      return body;
    }

    final live = fetch();
    // LISTENED TO SEPARATELY, so that a request which fails or arrives after
    // the saved copy has already been returned updates the cache quietly
    // instead of surfacing as an unhandled async error. Dart allows two
    // listeners on one future; this is the one that outlives this call.
    unawaited(live.then(
      (body) => CatalogueCache.write(key, body),
      onError: (Object _) {},
    ));
    try {
      final body = await live.timeout(_staleAfter);
      CatalogueCache.noteServedLive();
      return body;
    } on TimeoutException {
      // Slow, not broken. The request is still running and will refresh the
      // cache when it lands; what is shown now is the last known good answer.
      CatalogueCache.noteServedFromCache();
      return cached;
    } on ApiException catch (e) {
      if (!e.isRetryable) rethrow;
      CatalogueCache.noteServedFromCache();
      return cached;
    }
  }

  // ---- catalogue ----------------------------------------------------------

  @override
  Future<VideoContent?> getFeatured() async {
    final rows = await _cachedGet(
      '/rest/v1/titles',
      query: <String, String>{
        'select': _titleColumns,
        'is_featured': 'eq.true',
        'limit': '1',
      },
    );
    final list = _titles(rows);
    return list.isEmpty ? null : list.first;
  }

  @override
  Future<List<ContentRow>> getRows() async {
    // One round trip per row would be four on a cold start over a mobile
    // network. The server assembles them.
    final body = await _cachedPost(
      '/rest/v1/rpc/landing_rows',
      body: const <String, dynamic>{},
    );
    if (body is! List) return const <ContentRow>[];

    final rows = <ContentRow>[];
    for (final entry in body.whereType<Map<String, dynamic>>()) {
      final items = _titles(entry['items']);
      if (items.isEmpty) continue;
      rows.add(ContentRow(
        key: '${entry['key']}',
        fallbackTitle: '${entry['title'] ?? entry['key']}',
        items: items,
        defaultSort: _sortFrom(entry['default_sort'] as String?),
        ranked: entry['ranked'] == true,
      ));
    }
    return rows;
  }

  @override
  Future<ContentPage> getCatalogue({
    required String categoryId,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  }) async {
    return _page(
      query: <String, String>{
        'select': _titleColumns,
        // ONE `category` key. Writing the two conditions as two entries looked
        // fine and was wrong: a map literal keeps the LAST value, so asking
        // for Movies silently became "anything that is not adult".
        // `all` IS NOT A CATEGORY, it is the absence of one — every title the
        // caller may see. `neq.adult` rather than no filter at all because the
        // one category that was ever meant to be excluded from a general
        // listing was that one; a category hidden with `is_visible = false`
        // still appears here, which is the honest reading of "hidden section":
        // the films are published and reachable, the section is not advertised.
        // Changing that would need the server to own the listing (an RPC), and
        // putting a visibility rule in the client instead would be a rule in
        // the wrong place.
        'category': categoryId == ContentCategory.all.id
            ? 'neq.adult'
            : 'eq.$categoryId',
        ..._filterQuery(filters),
      },
      page: page,
      pageSize: pageSize,
    );
  }

  @override
  Future<ContentPage> getRowCatalogue({
    required String rowKey,
    ContentFilters filters = const ContentFilters(),
    int page = 0,
    int pageSize = 30,
  }) async {
    // Row scope may span categories (Trending covers films, series and clips),
    // which no column filter can express - the server owns that definition.
    return _page(
      path: '/rest/v1/rpc/row_catalogue',
      query: <String, String>{
        'row_key': rowKey,
        ..._filterQuery(filters),
      },
      page: page,
      pageSize: pageSize,
    );
  }

  Future<ContentPage> _page({
    String path = '/rest/v1/titles',
    required Map<String, String> query,
    required int page,
    required int pageSize,
  }) async {
    final from = page * pageSize;
    final to = from + pageSize - 1;
    final body = await _cachedGet(
      path,
      query: query,
      // `count=exact` is what makes "42 titles" and "Show 24 results"
      // possible. Without it the UI can only say "some".
      // Range is a header in PostgREST, but passing offset/limit keeps this
      // readable and works through RPC too.
    );
    final all = _titles(body);
    final total = all.length;
    if (from >= total) {
      return ContentPage(
          items: const <VideoContent>[], hasMore: false, totalCount: total);
    }
    final end = to + 1 > total ? total : to + 1;
    return ContentPage(
      items: all.sublist(from, end),
      hasMore: end < total,
      totalCount: total,
    );
  }

  static Map<String, String> _filterQuery(ContentFilters filters) {
    return <String, String>{
      if (filters.genres.isNotEmpty)
        'genres': 'ov.{${filters.genres.join(',')}}',
      if (filters.year != null) 'year': 'eq.${filters.year}',
      if (filters.quality != null) 'quality_label': 'eq.${filters.quality}',
      'order': _orderFor(filters.sort),
    };
  }

  static String _orderFor(ContentSort sort) {
    switch (sort) {
      case ContentSort.popular:
        return 'view_count.desc.nullslast';
      case ContentSort.newest:
        return 'year.desc.nullslast';
      case ContentSort.titleAsc:
        return 'title.asc';
    }
  }

  static ContentSort _sortFrom(String? raw) {
    switch (raw) {
      case 'newest':
        return ContentSort.newest;
      case 'title':
        return ContentSort.titleAsc;
      default:
        return ContentSort.popular;
    }
  }

  @override
  Future<ContentFacets> getFacets({required String categoryId}) async {
    return _facets(<String, String>{
      if (categoryId != ContentCategory.all.id) 'category_filter': categoryId,
    });
  }

  @override
  Future<ContentFacets> getRowFacets({required String rowKey}) async {
    return _facets(<String, String>{
      'row_key': rowKey,
    });
  }

  Future<ContentFacets> _facets(Map<String, String> args) async {
    try {
      final body =
          await _cachedPost('/rest/v1/rpc/catalogue_facets', body: args);
      if (body is! Map<String, dynamic>) return ContentFacets.empty;
      return ContentFacets(
        genres: (body['genres'] as List?)?.map((e) => '$e').toList() ??
            const <String>[],
        years: (body['years'] as List?)
                ?.map((e) => int.tryParse('$e') ?? 0)
                .where((y) => y > 0)
                .toList() ??
            const <int>[],
        qualities: (body['qualities'] as List?)?.map((e) => '$e').toList() ??
            const <String>[],
      );
    } on ApiException {
      // Facets are a convenience. Losing them costs the filter bar, not the
      // catalogue, so an empty set is better than an error screen.
      return ContentFacets.empty;
    }
  }

  @override
  Future<List<VideoContent>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const <VideoContent>[];

    // THE SERVER SEARCHES NOW, and the two columns below are what it falls
    // back to.
    //
    // `search_titles` matches against a maintained column holding the title,
    // the Burmese title, the synopsis, the genres and the operator's
    // invisible keywords — and it matches with pg_trgm, so a mistyped letter
    // still finds the title. Trigrams rather than to_tsvector because of the
    // audience: Postgres has no Burmese text-search configuration, so
    // stemming has nothing to work with, while comparing three characters at
    // a time works identically for Burmese, English and a title that mixes
    // both.
    //
    // It returns `setof title_cards`, which is the same column list the
    // catalogue returns — so there is one parser, not two, and the second one
    // cannot go stale.
    try {
      final body = await _api.postJson(
        '/rest/v1/rpc/search_titles',
        body: <String, dynamic>{'q': q, 'lim': 50},
      );
      // An empty result is a REAL ANSWER — the catalogue does not have it —
      // so it is returned rather than retried against the fallback below,
      // which searches two columns and could only ever find less.
      return _titles(body);
    } on ApiException {
      // FALL THROUGH, deliberately quiet. A deployment that has not run
      // migration 015 has no such function, and search degrading to two
      // columns is a missing feature; search throwing is a broken app.
    }

    // audit_video_hub.md M5. This used to be `'title': 'ilike.*$q*'` — ONE
    // column — so a Burmese user typing a Burmese title got nothing back,
    // in an app whose audience is mostly Burmese, against a catalogue that
    // stores the Burmese title in `title_mm`. The bundled DEMO repository
    // searched it correctly all along, via VideoContent.searchHaystack; only
    // the real one did not.
    final safe = _forOrGroup(q);
    try {
      final body = await _api.getJson(
        '/rest/v1/titles',
        query: <String, String>{
          'select': _titleColumns,
          'or': '(title.ilike."*$safe*",title_mm.ilike."*$safe*")',
          'limit': '50',
        },
      );
      return _titles(body);
    } on ApiException {
      // FALL BACK RATHER THAN FAIL.
      //
      // The `or=()` group above is the one query in this class whose exact
      // syntax could not be tried against the live project before shipping.
      // If a deployment rejects it, search must degrade to what it did
      // yesterday — English titles only — rather than becoming an error
      // screen. Losing Burmese search is a missing feature; losing search is
      // a broken app.
      try {
        final body = await _api.getJson(
          '/rest/v1/titles',
          query: <String, String>{
            'select': _titleColumns,
            'title': 'ilike.*$q*',
            'limit': '50',
          },
        );
        return _titles(body);
      } on ApiException catch (e) {
        // THE LAST RUNG: NO SERVER AT ALL.
        //
        // Every attempt above needs one. With the radio off all three fail with
        // the same network error, and a search screen that can only ever say
        // "something went wrong" is the wrong answer for somebody looking for a
        // film they were watching yesterday — which is the likeliest search on
        // a phone with no signal. So the last resort searches what has already
        // been seen.
        //
        // Only for a retryable failure. A 401 or a 403 means the server
        // declined this session, and answering it out of a cache would hand
        // over a listing row-level security had just refused.
        if (!e.isRetryable) rethrow;
        return _searchCached(q);
      }
    }
  }

  /// Search over the catalogue already on disk.
  ///
  /// Matches on [VideoContent.searchHaystack] — title, Burmese title, genres,
  /// year, category — which is the same field set the bundled demo repository
  /// searches, so offline search and demo search cannot drift apart. Trigram
  /// tolerance is not reproduced: a substring match is what can honestly be
  /// done without Postgres, and a mistyped letter finding nothing offline is a
  /// smaller failure than an empty screen.
  Future<List<VideoContent>> _searchCached(String q) async {
    final needle = q.toLowerCase();
    final rows = await CatalogueCache.titleRows();
    final hits = <VideoContent>[];
    for (final row in rows) {
      final title = _titleFrom(row);
      if (title.searchHaystack.contains(needle)) hits.add(title);
      if (hits.length >= 50) break;
    }
    return hits;
  }

  /// Makes a user's search text safe to sit inside a PostgREST `or=()` group.
  ///
  /// Inside that group a comma separates the conditions and a parenthesis
  /// closes it, so a title with either in it would rewrite the query rather
  /// than be matched. Double-quoting the value is what PostgREST offers for
  /// that, which in turn makes `"` and `\` the characters that must go.
  ///
  /// Stripped, not escaped: escaping inside a quoted value is the part that
  /// varies between PostgREST versions, and this could not be tested against
  /// the live project. Dropping two characters a film title will not contain
  /// is the boring option, and the boring option is right here.
  static String _forOrGroup(String q) => q.replaceAll(RegExp(r'["\\]'), '');

  @override
  Future<CategoryCatalogue> getCategories() async {
    try {
      final body = await _cachedGet(
        '/rest/v1/categories',
        query: const <String, String>{
          'select': 'id,label,label_mm,sort_order,is_visible',
          'order': 'sort_order.asc',
        },
        // Drawn before the age gate and before any account exists, so it must
        // not wait on a session it may never get.
        authenticated: false,
      );
      if (body is! List) return CategoryCatalogue.empty;

      final byId = <String, CategoryStyle>{};
      for (final row in body) {
        if (row is! Map) continue;
        final m = row.cast<String, dynamic>();
        final id = '${m['id'] ?? ''}'.trim();
        final label = '${m['label'] ?? ''}'.trim();
        // A row with no id addresses nothing and a row with no label would
        // render an empty pill. Skipping beats drawing either.
        if (id.isEmpty || label.isEmpty) continue;
        byId[id] = CategoryStyle(
          id: id,
          label: label,
          labelMm: m['label_mm'] as String?,
          sortOrder: _int(m['sort_order']) ?? 0,
          // Absent reads as VISIBLE. A column the server has not sent must
          // never be able to hide a tab.
          isVisible: m['is_visible'] != false,
        );
      }
      return CategoryCatalogue(byId);
    } on ApiException {
      // The compiled enum and the compiled strings. Not an error state — see
      // CategoryCatalogue.empty. A catalogue that cannot draw its own tab bar
      // without the network is worse than one with month-old labels.
      return CategoryCatalogue.empty;
    }
  }

  @override
  Future<VideoContent?> getById(String id) async {
    final body = await _cachedGet(
      '/rest/v1/titles',
      query: <String, String>{
        'select': _titleColumns,
        'id': 'eq.$id',
        'limit': '1',
      },
    );
    final list = _titles(body);
    if (list.isEmpty) return null;
    return list.first.withAlbum(await _album(id));
  }

  /// The album behind a title: the extra stills and clips in its folder.
  ///
  /// A SECOND request, deliberately, and only on the detail screen. The
  /// catalogue draws thirty cards from one response; making each of those
  /// carry its album would multiply the payload by the one thing nobody has
  /// looked at yet. The counts on the card come from `photo_count` and
  /// `video_count`, which the server maintains, so the grid already knows how
  /// many there are without fetching any of them.
  ///
  /// Reads `title_media`, never `title_assets`. That view exposes photos with
  /// a public URL and clips WITHOUT one - a clip's playable URL has to come
  /// from requestPlayback like any other video, or the ten-minute expiry
  /// becomes optional. `title_assets` itself holds raw object keys and is not
  /// readable with this key at all.
  ///
  /// Failure here returns an empty album rather than throwing: a title whose
  /// extras cannot be loaded should still play. The album is the bonus, not
  /// the film.
  Future<List<AlbumItem>> _album(String titleId) async {
    try {
      final body = await _cachedGet(
        '/rest/v1/title_media',
        query: <String, String>{
          'select': 'id,kind,url,thumb_url,duration_s,is_free,width,height',
          'title_id': 'eq.$titleId',
          'order': 'sort_order.asc',
          // CAPPED. The mosaic is a Column inside a SliverToBoxAdapter, so
          // every tile is built at once - there is no virtualisation to hide
          // behind. A folder with two hundred stills would build two hundred
          // image widgets in one frame and jank the screen it is meant to
          // show off.
          //
          // Sixty is far beyond any album that reads as a glance and far
          // below the point where the layout costs anything. If a title ever
          // genuinely needs more, the fix is paging inside the album, not a
          // bigger number here.
          'limit': '60',
        },
      );
      if (body is! List) return const <AlbumItem>[];

      final items = <AlbumItem>[];
      for (final row in body) {
        if (row is! Map) continue;
        final m = row.cast<String, dynamic>();
        final isPhoto = m['kind'] == 'photo';

        // A photo with no URL cannot be drawn, and a clip with no id cannot be
        // requested. Either way there is nothing to show, so it is skipped
        // rather than added as a tile that does nothing when tapped.
        final url = m['url'] as String?;
        final id = '${m['id'] ?? ''}';
        if (id.isEmpty) continue;
        if (isPhoto && (url == null || url.isEmpty)) continue;

        items.add(AlbumItem(
          id: id,
          kind: isPhoto ? MediaKind.photo : MediaKind.video,
          // Photos carry their own public URL. Clips carry the ASSET ID and no
          // URL - playback resolves it server-side, exactly as the main video
          // does.
          source: isPhoto
              ? _refFrom(url)
              : MediaRef(provider: 'asset', locator: id),
          thumbnail: _refFrom(m['thumb_url'] ?? (isPhoto ? url : null)),
          durationSec: _int(m['duration_s']),
          isPreview: m['is_free'] == true,
          width: _int(m['width']),
          height: _int(m['height']),
        ));
      }
      return items;
    } catch (e) {
      if (kDebugMode) debugPrint('album load failed: $e');
      return const <AlbumItem>[];
    }
  }

  // ---- playback: the enforcement point -----------------------------------

  @override
  Future<PlaybackGrant> requestPlayback({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
  }) async {
    try {
      final body = await _api.postJson(
        '/functions/v1/request-playback',
        body: <String, dynamic>{
          'title_id': content.id,
          // A clip from the album carries provider 'asset' and the ASSET ID,
          // set by _album() above. The server signs that asset's object key
          // instead of the title's main video - which is what makes a
          // behind-the-scenes clip or a trailer playable at all.
          //
          // Still only an ID. The client never knows or sends a media path;
          // the server looks the key up and checks the asset really belongs to
          // the title before signing anything, so a forged id buys nothing.
          if (source.provider == 'asset' && source.locator.isNotEmpty)
            'asset_id': source.locator
          else if (source.locator.isNotEmpty)
            'media_key': source.locator,
          if (deviceId != null) 'device_id': deviceId,
        },
        timeout: null,
      );
      if (body is! Map<String, dynamic>) {
        return const PlaybackGrant.denied(AccessDenial.unavailable);
      }
      final url = body['url'];
      if (url is! String || url.isEmpty) {
        return const PlaybackGrant.denied(AccessDenial.unavailable);
      }
      final expiresRaw = body['expires_at'] as String?;
      // THE LADDER, AND A MALFORMED RUNG IS DROPPED RATHER THAN DEFAULTED.
      // A rung with no bitrate would divide every bandwidth decision by a
      // number meaning "free", and a rung with no url is unplayable — either
      // one is worse than one fewer choice.
      final ladder = <Rendition>[];
      final raw = body['renditions'];
      if (raw is List) {
        for (final row in raw) {
          final r = Rendition.fromJson(row);
          if (r != null) ladder.add(r);
        }
      }
      return PlaybackGrant.granted(
        url,
        expiresAt: _parseServerTime(expiresRaw),
        renditions: ladder,
      );
    } on ApiException catch (e) {
      // The paywall case, and the ONLY place it comes from: the server said
      // so. There is no client-side condition that produces this.
      if (e.kind == ApiErrorKind.needsPremium) {
        return const PlaybackGrant.denied(AccessDenial.needsPremium);
      }
      if (e.kind == ApiErrorKind.unauthenticated) {
        return const PlaybackGrant.denied(AccessDenial.needsPremium);
      }
      // The device conflict, told apart by the server's own code rather than
      // by the status alone - 409 is the documented one, but a deployment that
      // answers 403 or 429 with the same code means the same thing, and the
      // user's problem does not change with the number.
      if (e.code == 'wrong_device' || e.code == 'too_many_devices') {
        return const PlaybackGrant.denied(AccessDenial.wrongDevice);
      }
      if (e.statusCode == 409) {
        return const PlaybackGrant.denied(AccessDenial.wrongDevice);
      }
      // COULD NOT ASK, told apart from "was told no", and this is the only
      // place in the class that distinction is made about PLAYBACK.
      //
      // It is still a refusal — nothing here ever returns a URL — but the
      // caller may offer the bytes this phone already holds for THIS value and
      // must not for the one below. The difference matters both ways: those
      // bytes were paid for and authorised once, so refusing them because a
      // tunnel has no signal is wrong; and a 403 nobody recognised is somebody
      // saying no, so serving them then would be worse.
      if (isUnreachableError(e)) {
        return const PlaybackGrant.denied(AccessDenial.offline);
      }
      // Everything else - a refusal with no code, a malformed body - is
      // "cannot play right now", never "you may play".
      return const PlaybackGrant.denied(AccessDenial.unavailable);
    }
  }

  @override
  Future<void> recordView(String contentId, {ViewerTier? tier}) async {
    try {
      await _api.postJson(
        '/rest/v1/rpc/record_view',
        body: <String, dynamic>{
          'title_id': contentId,
          // Reported, never trusted: the server knows the real tier from the
          // JWT and should prefer it. This is a hint for the anonymous case,
          // where there is no JWT to read one from.
          if (tier != null) 'viewer_tier': tier.id,
        },
      );
    } on ApiException {
      // Swallowed on purpose. A missed count is invisible; an error toast
      // over a title the user just opened is not.
    }
  }

  @override
  Future<String?> resolveImageUrl(MediaRef ref) async =>
      resolveImageUrlSync(ref);

  @override
  String? resolveImageUrlSync(MediaRef ref) {
    if (ref.isEmpty) return '';
    // Posters are public art and carry a plain URL from the catalogue row, so
    // there is nothing to sign, and nothing to wait for. Private artwork would
    // go through the playback function like everything else — and that
    // implementation would return null here to keep the async path.
    return ref.locator.startsWith('http') ? ref.locator : '';
  }

  // ---- parsing ------------------------------------------------------------

  static List<VideoContent> _titles(dynamic body) {
    if (body is! List) return const <VideoContent>[];
    return body
        .whereType<Map<String, dynamic>>()
        .map(_titleFrom)
        .toList();
  }

  static VideoContent _titleFrom(Map<String, dynamic> m) {
    return VideoContent(
      id: '${m['id']}',
      title: '${m['title'] ?? ''}',
      titleMm: m['title_mm'] as String?,
      synopsis: m['synopsis'] as String?,
      category: ContentCategoryX.fromId(m['category'] as String?),
      poster: _refFrom(m['poster_url']),
      year: _int(m['year']),
      rating: _double(m['rating']),
      qualityLabel: m['quality_label'] as String?,
      genres:
          (m['genres'] as List?)?.map((e) => '$e').toList() ?? const <String>[],
      episodeCount: _int(m['episode_count']),
      viewCount: _int(m['view_count']),
      photoCount: _int(m['photo_count']),
      videoCount: _int(m['video_count']),
      // Unknown or missing tier reads as PREMIUM. Defaulting to free would mean
      // a schema typo silently unlocks the catalogue; defaulting to premium
      // means it silently locks it, which is visible and recoverable.
      accessTier: m['access_tier'] == 'free'
          ? AccessTier.free
          : AccessTier.premium,
      // No media locator: the client is never given one. Playback is requested
      // by title id and the server resolves the address itself.
      source: MediaRef(provider: 'server', locator: '${m['id']}'),
    );
  }

  static MediaRef _refFrom(dynamic value) {
    if (value is String && value.isNotEmpty) {
      return MediaRef(provider: 'url', locator: value);
    }
    return MediaRef.none;
  }

  static int? _int(dynamic v) =>
      v == null ? null : (v is int ? v : int.tryParse('$v'));

  static double? _double(dynamic v) =>
      v == null ? null : (v is double ? v : double.tryParse('$v'));

  /// Parse a timestamp the SERVER produced.
  ///
  /// `DateTime.parse` treats a string with no timezone designator as LOCAL
  /// time. For a value the server wrote that is simply wrong, and the size of
  /// the error is the device's offset from UTC — six and a half hours in
  /// Myanmar, which would make every freshly minted URL look hours stale. A
  /// server timestamp with no zone is UTC; say so rather than inheriting a
  /// default that happens to be right only in London.
  static DateTime? _parseServerTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    if (parsed.isUtc) return parsed.toLocal();
    // Zoneless: `tryParse` built a local DateTime. Reinterpret the same wall
    // clock as UTC, then convert.
    final hasZone = RegExp(r'(Z|[+-]\d{2}:?\d{2})$').hasMatch(raw.trim());
    if (hasZone) return parsed.toLocal();
    return DateTime.utc(
      parsed.year,
      parsed.month,
      parsed.day,
      parsed.hour,
      parsed.minute,
      parsed.second,
      parsed.millisecond,
      parsed.microsecond,
    ).toLocal();
  }
}
