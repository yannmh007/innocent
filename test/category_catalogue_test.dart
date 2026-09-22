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
}
