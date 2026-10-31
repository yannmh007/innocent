// Categories and genres by CODE (migration 058): what the app sends, what it
// shows, and what it falls back to when the names have not arrived.
//
// The database stores `category_code` (C01) and `genre_codes` (G001); the
// words live in `public.categories` / `public.genres` and reach the app through
// `rpc/taxonomy`. These tests hold the three promises the app makes about that:
//
//   * a query filters by the code whenever the code is known, and by the old
//     word only when it is not (first launch offline, a server before 058);
//   * a screen never shows a raw code — an unknown code sends the chip, the
//     card and the filter sheet back to the words the server sent beside it;
//   * a name is chosen by the phone's language, with English as the fallback
//     for a blank translation, and a merged code shows the surviving name.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/api_content_repository.dart';
import 'package:innocent/features/video_hub/data/cache/catalogue_cache.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_filters.dart';
import 'package:innocent/features/video_hub/domain/genre_names.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';

Map<String, dynamic> _taxonomy({List<Map<String, dynamic>>? genres}) =>
    <String, dynamic>{
      'version': '2026-10-31T07:01:36Z',
      'categories': <Map<String, dynamic>>[
        {'id': 'all', 'code': 'C00', 'label': 'All', 'sort_order': 0},
        {
          'id': 'movies',
          'code': 'C01',
          'label': 'Movies',
          'label_mm': 'ရုပ်ရှင်',
          'label_th': 'ภาพยนตร์',
          'sort_order': 1,
        },
        {'id': 'series', 'code': 'C02', 'label': 'Series', 'sort_order': 2},
        {
          'id': 'reels',
          'code': 'C03',
          'label': 'Reels',
          'sort_order': 3,
          'retired': true,
        },
      ],
      'genres': genres ??
          <Map<String, dynamic>>[
            {'code': 'G001', 'label': 'Open Movie', 'sort_order': 3},
            {
              'code': 'G002',
              'label': 'Animation',
              'label_mm': 'ကာတွန်း',
              'label_th': 'แอนิเมชัน',
              'sort_order': 1,
            },
            {
              'code': 'G003',
              'label': 'Fantasy',
              'label_mm': '   ',
              'sort_order': 2,
            },
            {
              'code': 'G004',
              'label': 'Cartoon',
              'merged_into': 'G002',
              'sort_order': 4,
            },
            {
              'code': 'G005',
              'label': 'Old',
              'retired': true,
              'sort_order': 5,
            },
            {
              'code': 'G006',
              'label': 'Hidden',
              'visible': false,
              'sort_order': 6,
            },
          ],
    };

const _sintel = <String, dynamic>{
  'id': '0839dacb-59ae-4c95-9279-4901b925965d',
  'title': 'Sintel',
  'category': 'movies',
  'category_code': 'C01',
  'genres': <String>['Animation', 'Fantasy'],
  'genre_codes': <String>['G002', 'G003'],
  'access_tier': 'free',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GenreNames', () {
    final names = GenreNames.fromJson(_taxonomy()['genres']);

    test('names a code in the phone\'s language, English when blank', () {
      expect(names.labelOf('G002', 'en'), 'Animation');
      expect(names.labelOf('G002', 'my'), 'ကာတွန်း');
      expect(names.labelOf('G002', 'th'), 'แอนิเมชัน');
      // A whitespace-only translation is somebody's accident, not a name.
      expect(names.labelOf('G003', 'my'), 'Fantasy');
      expect(names.labelOf('G001', 'th'), 'Open Movie');
    });

    test('a word is its own name; an unknown code has none', () {
      expect(names.labelOf('Thriller', 'my'), 'Thriller');
      expect(names.labelOf('G999', 'en'), isNull);
      expect(names.knowsAll(<String>['G001', 'G002']), isTrue);
      expect(names.knowsAll(<String>['G001', 'G999']), isFalse);
    });

    test('a merged code shows the genre it was merged into, once', () {
      expect(names.labelOf('G004', 'my'), 'ကာတွန်း');
      expect(names.labelsOf(<String>['G002', 'G004', 'G003'], 'en'),
          <String>['Animation', 'Fantasy']);
    });

    test('half a list is never shown: one unknown code and it is null', () {
      expect(names.labelsOf(<String>['G002', 'G999'], 'en'), isNull);
    });

    test('the filter sheet offers live genres in the console\'s order', () {
      expect(
        names.offered(<String>['G001', 'G003', 'G004', 'G005', 'G006', 'G002']),
        // G004 resolves to G002 (once); retired G005 and hidden G006 are not
        // offered; the order is sort_order, not code.
        <String>['G002', 'G003', 'G001'],
      );
    });

    test('rows that cannot be filed or shown are skipped', () {
      final odd = GenreNames.fromJson(<Object?>[
        {'code': 'Action', 'label': 'Action'},
        {'code': 'G010', 'label': '  '},
        {'code': 'G011', 'label': 'Drama', 'merged_into': 'nonsense'},
        'not a row',
      ]);
      expect(odd.byCode.keys, <String>['G011']);
      expect(odd.byCode['G011']!.mergedInto, isNull);
      expect(GenreNames.fromJson(null).isEmpty, isTrue);
    });

    test('a merge loop does not hang', () {
      final loop = GenreNames.fromJson(<Object?>[
        {'code': 'G020', 'label': 'A', 'merged_into': 'G021'},
        {'code': 'G021', 'label': 'B', 'merged_into': 'G020'},
      ]);
      expect(loop.labelOf('G020', 'en'), isNotNull);
    });
  });

  group('VideoContent.genreLabels', () {
    final names = GenreNames.fromJson(_taxonomy()['genres']);
    const card = VideoContent(
      id: 'x',
      title: 'Sintel',
      category: ContentCategory.movies,
      genres: <String>['Animation', 'Fantasy'],
      genreCodes: <String>['G002', 'G003'],
    );

    test('codes named in the phone\'s language', () {
      expect(card.genreLabels(names, 'my'), <String>['ကာတွန်း', 'Fantasy']);
    });

    test('the words when the names have not arrived', () {
      expect(card.genreLabels(GenreNames.empty, 'my'),
          <String>['Animation', 'Fantasy']);
    });

    test('the words when one code is unknown', () {
      const newer = VideoContent(
        id: 'y',
        title: 'Y',
        category: ContentCategory.movies,
        genres: <String>['Animation', 'Noir'],
        genreCodes: <String>['G002', 'G077'],
      );
      expect(newer.genreLabels(names, 'en'), <String>['Animation', 'Noir']);
    });
  });

  group('CategoryStyle', () {
    test('Thai label, with the English one for a blank translation', () {
      const s = CategoryStyle(
          id: 'movies', code: 'C01', label: 'Movies', labelTh: 'ภาพยนตร์');
      expect(s.displayLabel('th'), 'ภาพยนตร์');
      expect(s.displayLabel('my'), 'Movies');
      const blank = CategoryStyle(id: 'x', label: 'X', labelTh: ' ');
      expect(blank.displayLabel('th'), 'X');
    });
  });

  group('ApiContentRepository by code', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      CatalogueCache.enabled = false;
      ApiContentRepository.forgetRefreshTimes();
    });
    tearDown(() => CatalogueCache.enabled = true);

    ({ApiContentRepository repo, List<http.Request> seen}) build({
      bool taxonomyFails = false,
      Map<String, dynamic>? taxonomy,
      Map<String, dynamic>? facets,
    }) {
      final seen = <http.Request>[];
      final repo = ApiContentRepository(ApiClient(
        httpClient: MockClient((req) async {
          seen.add(req);
          final path = req.url.path;
          if (path.endsWith('/rpc/taxonomy')) {
            if (taxonomyFails) return http.Response('{"message":"x"}', 404);
            return http.Response(jsonEncode(taxonomy ?? _taxonomy()), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          if (path.endsWith('/rpc/catalogue_facets')) {
            return http.Response(
                jsonEncode(facets ??
                    <String, dynamic>{
                      'genres': ['Animation', 'Fantasy', 'Open Movie'],
                      'genre_codes': ['G001', 'G002', 'G003'],
                      'years': [2010],
                      'qualities': ['HD'],
                    }),
                200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          if (path.endsWith('/titles')) {
            return http.Response(jsonEncode([_sintel]), 200,
                headers: {'content-type': 'application/json; charset=utf-8'});
          }
          return http.Response('[]', 200);
        }),
      ));
      return (repo: repo, seen: seen);
    }

    test('categories come from rpc/taxonomy, with codes and Thai', () async {
      final b = build();
      final cat = await b.repo.getCategories();
      expect(b.seen.single.method, 'GET');
      expect(b.seen.single.url.path, endsWith('/rest/v1/rpc/taxonomy'));
      expect(cat.byId['movies']!.code, 'C01');
      expect(cat.byId['movies']!.displayLabel('th'), 'ภาพยนตร์');
      expect(cat.codeFor('series'), 'C02');
      // Retired: hidden, not dropped (a dropped built-in would be drawn).
      expect(cat.byId['reels']!.isVisible, isFalse);
      expect(cat.refs().map((r) => r.id), isNot(contains('reels')));
    });

    test('a category is asked for by its code', () async {
      final b = build();
      await b.repo.getCatalogue(categoryId: 'movies');
      final q = b.seen.last.url.queryParameters;
      expect(q['category_code'], 'eq.C01');
      expect(q.containsKey('category'), isFalse);
      expect(q['select'], contains('genre_codes'));
      expect(q['select'], contains('category_code'));
    });

    test('by the word when the taxonomy cannot be read', () async {
      final b = build(taxonomyFails: true);
      await b.repo.getCatalogue(categoryId: 'movies');
      final q = b.seen.last.url.queryParameters;
      expect(q['category'], 'eq.movies');
      expect(q.containsKey('category_code'), isFalse);
    });

    test('All is still everything but adult, with no code needed', () async {
      final b = build();
      await b.repo.getCatalogue(categoryId: ContentCategory.all.id);
      final q = b.seen.last.url.queryParameters;
      expect(q['category'], 'neq.adult');
    });

    test('genre filters: codes to genre_codes, words to genres', () async {
      final b = build();
      await b.repo.getCatalogue(
        categoryId: 'movies',
        filters: const ContentFilters(genres: <String>{'G002', 'G003'}),
      );
      expect(b.seen.last.url.queryParameters['genre_codes'],
          anyOf('ov.{G002,G003}', 'ov.{G003,G002}'));
      expect(b.seen.last.url.queryParameters.containsKey('genres'), isFalse);

      await b.repo.getCatalogue(
        categoryId: 'movies',
        filters: const ContentFilters(genres: <String>{'Animation'}),
      );
      expect(b.seen.last.url.queryParameters['genres'], 'ov.{Animation}');
      expect(
          b.seen.last.url.queryParameters.containsKey('genre_codes'), isFalse);
    });

    test('titles carry their codes', () async {
      final b = build();
      final page = await b.repo.getCatalogue(categoryId: 'movies');
      expect(page.items.single.genreCodes, <String>['G002', 'G003']);
      expect(page.items.single.genres, <String>['Animation', 'Fantasy']);
    });

    test('facets are codes, in the console\'s order, asked by code', () async {
      final b = build();
      final f = await b.repo.getFacets(categoryId: 'movies');
      expect(f.genres, <String>['G002', 'G003', 'G001']);
      final facetCall =
          b.seen.firstWhere((r) => r.url.path.endsWith('/catalogue_facets'));
      expect(jsonDecode(facetCall.body), <String, dynamic>{
        'category_filter': 'C01',
      });
    });

    test('facets fall back to words when a code cannot be named', () async {
      final b = build(facets: <String, dynamic>{
        'genres': ['Animation', 'Noir'],
        'genre_codes': ['G002', 'G077'],
      });
      final f = await b.repo.getFacets(categoryId: 'movies');
      expect(f.genres, <String>['Animation', 'Noir']);
    });

    test('facets from a server before 058 are words', () async {
      final b = build(facets: <String, dynamic>{
        'genres': ['Animation'],
      });
      final f = await b.repo.getFacets(categoryId: 'movies');
      expect(f.genres, <String>['Animation']);
    });

    test('one taxonomy request serves the tab bar and the names', () async {
      final b = build();
      final both = await Future.wait<Object>(
          <Future<Object>>[b.repo.getCategories(), b.repo.getGenreNames()]);
      expect(b.seen.where((r) => r.url.path.endsWith('/rpc/taxonomy')).length,
          1);
      expect((both[1] as GenreNames).labelOf('G002', 'my'), 'ကာတွန်း');
    });
  });
}
