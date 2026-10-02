import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_screen.dart';

/// The landing page's category rows (migration 034): "All" used to end after
/// Trending and Recently added. A row per category now follows, and its
/// heading is the category's CURRENT name — renamed in the console, renamed
/// in the app — in the viewer's language.
void main() {
  const row = ContentRow(
    key: 'cat:movies',
    fallbackTitle: 'Movies',
    fallbackTitleMm: 'ရုပ်ရှင်',
    categoryId: 'movies',
    items: <VideoContent>[],
  );
  final en = AppStrings(const Locale('en'));
  final my = AppStrings(const Locale('my'));

  test('a renamed category renames its row, in both languages', () {
    const styles = CategoryCatalogue(<String, CategoryStyle>{
      'movies': CategoryStyle(id: 'movies', label: 'Films', labelMm: 'ဇာတ်ကား'),
    });
    expect(contentRowTitle(en, row, styles: styles), 'Films');
    expect(contentRowTitle(my, row, styles: styles), 'ဇာတ်ကား');
  });

  test('before the category list arrives, the row says what the server sent', () {
    expect(contentRowTitle(en, row), 'Movies');
    expect(contentRowTitle(my, row), 'ရုပ်ရှင်');
  });

  test('a blank Burmese name falls back to English, never to nothing', () {
    const blank = ContentRow(
      key: 'cat:reels',
      fallbackTitle: 'Reels',
      fallbackTitleMm: '  ',
      categoryId: 'reels',
      items: <VideoContent>[],
    );
    expect(contentRowTitle(my, blank), 'Reels');
  });

  test('the built-in rows keep their compiled, translated headings', () {
    const trending = ContentRow(
        key: kRowTrending, fallbackTitle: 'x', items: <VideoContent>[]);
    expect(contentRowTitle(en, trending), en.vhRowTrending);
    expect(contentRowTitle(my, trending), my.vhRowTrending);
  });
}
