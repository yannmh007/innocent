// Server-controlled category names, order and visibility.
//
// WHY THIS IS TESTED AND THE TAB BAR IS NOT. Both rules here fail SILENTLY
// and look deliberate when they fail: a wrong order reads as a design choice,
// a wrongly hidden tab reads as an empty catalogue, and a missing label reads
// as a translation nobody got round to. None of them throws, and none of them
// is visible in a screenshot of the case somebody thought to check.
//
// The decisions are therefore pure functions on a value object, testable
// without a network, a provider or a widget.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';

CategoryStyle style(
  String id, {
  String? label,
  String? labelMm,
  int sortOrder = 0,
  bool isVisible = true,
}) =>
    CategoryStyle(
      id: id,
      label: label ?? id,
      labelMm: labelMm,
      sortOrder: sortOrder,
      isVisible: isVisible,
    );

CategoryCatalogue catalogue(List<CategoryStyle> styles) =>
    CategoryCatalogue(<String, CategoryStyle>{for (final s in styles) s.id: s});

void main() {
  group('no opinion from the server', () {
    test('empty falls back to the compiled enum, in enum order', () {
      // NOT AN ERROR STATE. This is what every build shows before the first
      // fetch returns, what it shows offline, and what a build with no
      // backend has always shown.
      expect(CategoryCatalogue.empty.visible(), ContentCategoryX.visible());
      expect(CategoryCatalogue.empty.visible().first, ContentCategory.all);
    });

    test('labelFor returns null so the caller keeps its compiled string', () {
      // Null rather than a default: AppStrings carries three languages and
      // `public.categories` carries two, so inventing a label here would hand
      // a Thai user an English one.
      expect(
        CategoryCatalogue.empty.labelFor(ContentCategory.movies, 'en'),
        isNull,
      );
    });
  });

  group('labels', () {
    test('the server label wins — this is the whole feature', () {
      // "Movies" to "Video" without shipping an app.
      final c = catalogue(<CategoryStyle>[style('movies', label: 'Video')]);
      expect(c.labelFor(ContentCategory.movies, 'en'), 'Video');
    });

    test('Burmese is used when the app is in Burmese, English otherwise', () {
      final c = catalogue(
        <CategoryStyle>[style('movies', label: 'Video', labelMm: 'ဗီဒီယို')],
      );
      expect(c.labelFor(ContentCategory.movies, 'my'), 'ဗီဒီယို');
      expect(c.labelFor(ContentCategory.movies, 'en'), 'Video');
      // Thai has no column of its own, and it still gets the RENAME rather
      // than the compiled Thai word for "Movies". After a rename the compiled
      // string is the old name, and showing one audience the old name is
      // worse than showing them a new one in another language.
      expect(c.labelFor(ContentCategory.movies, 'th'), 'Video',
          reason: 'a rename must reach every language, translated or not');
    });

    test('a blank label_mm falls back instead of drawing an empty pill', () {
      // Somebody will save one by accident. `titles.title_mm` has the same
      // guard for the same reason.
      final c = catalogue(
        <CategoryStyle>[style('movies', label: 'Video', labelMm: '   ')],
      );
      expect(c.labelFor(ContentCategory.movies, 'my'), 'Video');
    });

    test('a category the server never mentions keeps its compiled string', () {
      final c = catalogue(<CategoryStyle>[style('movies', label: 'Video')]);
      expect(c.labelFor(ContentCategory.reels, 'en'), isNull);
    });
  });

  group('order and visibility', () {
    test('the server reorders the bar', () {
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 0),
        style('reels', sortOrder: 1),
        style('movies', sortOrder: 2),
        style('series', sortOrder: 3),
      ]);
      expect(c.visible(), <ContentCategory>[
        ContentCategory.all,
        ContentCategory.reels,
        ContentCategory.movies,
        ContentCategory.series,
      ]);
    });

    test('is_visible = false hides a tab', () {
      final c = catalogue(<CategoryStyle>[style('series', isVisible: false)]);
      expect(c.visible(), isNot(contains(ContentCategory.series)));
      expect(c.visible(), contains(ContentCategory.movies));
    });

    test('ALL is never hidden, whatever the row says', () {
      // It is the landing tab and the default of selectedCategoryProvider.
      // Hiding it would open the hub on a tab that is not in the bar — which
      // is not what an operator expects from setting one boolean.
      final c = catalogue(<CategoryStyle>[style('all', isVisible: false)]);
      expect(c.visible(), contains(ContentCategory.all));
    });

    test('hiding everything leaves All, and never an empty bar', () {
      // The reason `visible()` needs no empty-list guard: All is kept
      // unconditionally, so the worst an operator can do with is_visible is
      // a bar of one pill — which is a legitimate thing to want while a
      // catalogue is being rebuilt, and is navigable.
      final c = catalogue(<CategoryStyle>[
        style('movies', isVisible: false),
        style('series', isVisible: false),
        style('reels', isVisible: false),
      ]);
      expect(c.visible(), <ContentCategory>[ContentCategory.all]);
    });

    test('a category the server never mentions keeps its place', () {
      // The normal state for the first minutes after a release adds a tab.
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 0),
        style('movies', sortOrder: 1),
      ]);
      expect(c.visible(), contains(ContentCategory.reels));
      expect(c.visible(), contains(ContentCategory.series));
    });

    test('equal sort orders keep enum order rather than shuffling', () {
      // An unstable sort here would make the bar reorder itself between
      // launches, which reads as the app being broken.
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 5),
        style('movies', sortOrder: 5),
        style('series', sortOrder: 5),
        style('reels', sortOrder: 5),
      ]);
      expect(c.visible(), ContentCategoryX.visible());
    });
  });

  group('a category the build has never heard of', () {
    // THE POINT OF CategoryRef. Until this existed, `visible()` could only ever
    // return values from a compiled enum, so an operator adding a category got
    // rows the app stored, queried and refused to draw a tab for. Migration 020
    // removed the two database obstacles; this is the third.

    test('a server-only category becomes a tab', () {
      final c = catalogue(<CategoryStyle>[
        style('all', label: 'All', sortOrder: 0),
        style('movies', label: 'Movies', sortOrder: 1),
        style('documentary', label: 'Documentary', sortOrder: 9),
      ]);
      final ids = <String>[for (final r in c.refs()) r.id];
      expect(ids, contains('documentary'));
      // And it knows it is not compiled, which is what decides whether it can
      // have a glyph or curated rows.
      final extra = c.refs().firstWhere((r) => r.id == 'documentary');
      expect(extra.builtIn, isNull);
      expect(extra.showsRows, isFalse);
    });

    test('sort_order places it among the built-ins, not merely at the end', () {
      // An operator dropping a new section between two old ones is the ordinary
      // case; appending is the special one.
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 0),
        style('movies', sortOrder: 1),
        style('documentary', sortOrder: 2),
        style('series', sortOrder: 3),
        style('reels', sortOrder: 4),
      ]);
      expect(<String>[for (final r in c.refs()) r.id],
          <String>['all', 'movies', 'documentary', 'series', 'reels']);
    });

    test('a hidden server-only category is not drawn at all', () {
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 0),
        style('documentary', sortOrder: 9, isVisible: false),
      ]);
      expect(<String>[for (final r in c.refs()) r.id],
          isNot(contains('documentary')));
    });

    test('two extras with the same sort_order keep a stable order', () {
      // Equal orders that swapped between launches would read as the app
      // shuffling its own tab bar.
      final c = catalogue(<CategoryStyle>[
        style('all', sortOrder: 0),
        style('zebra', sortOrder: 5),
        style('alpaca', sortOrder: 5),
      ]);
      final ids = <String>[for (final r in c.refs()) r.id];
      expect(ids.indexOf('alpaca'), lessThan(ids.indexOf('zebra')));
      expect(<String>[for (final r in c.refs()) r.id], ids);
    });

    test('no opinion from the server still yields every built-in tab', () {
      expect(
        <String>[for (final r in CategoryCatalogue.empty.refs()) r.id],
        <String>[for (final c in ContentCategoryX.visible()) c.id],
      );
      expect(CategoryCatalogue.empty.refs().first, CategoryRef.all);
    });

    test('labelForId reads the server row, and says nothing when it cannot',
        () {
      final c = catalogue(<CategoryStyle>[
        style('documentary', label: 'Documentary', labelMm: 'မှတ်တမ်း'),
        style('blank', label: '   '),
      ]);
      expect(c.labelForId('documentary', 'en'), 'Documentary');
      expect(c.labelForId('documentary', 'my'), 'မှတ်တမ်း');
      // A blank label is "nothing usable to say", not a label — otherwise the
      // bar draws an empty pill, which reads as a rendering bug.
      expect(c.labelForId('blank', 'en'), isNull);
      expect(c.labelForId('never-heard-of-it', 'en'), isNull);
    });

    test('fromId keeps an unknown id instead of collapsing it to All', () {
      // Collapsing is what made a new category invisible, and it would now
      // reinterpret a link into somebody's new section as the front page.
      expect(CategoryRef.fromId('movies').builtIn, ContentCategory.movies);
      expect(CategoryRef.fromId('documentary').builtIn, isNull);
      expect(CategoryRef.fromId('documentary').id, 'documentary');
      expect(CategoryRef.fromId('all'), CategoryRef.all);
    });

    test('refs are equal by id, so a rebuilt ref still matches the selection',
        () {
      // The selected tab is compared against a list rebuilt on every frame. If
      // two refs for one category were not equal, no pill would ever look
      // chosen.
      expect(CategoryRef.fromId('movies'), CategoryRef.of(ContentCategory.movies));
      expect(CategoryRef.serverOnly('documentary'),
          CategoryRef.fromId('documentary'));
      expect(CategoryRef.serverOnly('a') == CategoryRef.serverOnly('b'), isFalse);
    });
  });
}
