import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/account/account_screen.dart';
import 'dart:convert';

import 'package:innocent/features/video_hub/data/demo_content_datasource.dart';
import 'package:innocent/features/video_hub/presentation/album_viewer_screen.dart';
import 'package:innocent/features/video_hub/presentation/bookmarks_screen.dart';
import 'package:innocent/features/video_hub/presentation/data_saver_panel.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';
import 'package:innocent/features/video_hub/presentation/downloads_screen.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';

import 'fakes.dart';
import 'harness.dart';

/// The data saver and the library: the album frosted and not, the album
/// viewer, where the switches live, and the account screen's shelves.
void main() {
  setUpAll(loadScreenFonts);

  List<Override> hub() => [
        contentRepositoryProvider.overrideWithValue(AlbumDemoRepository()),
        ...libraryOverrides(),
      ];
  const saverOn = <String, Object>{'pref_player_albumDataSaver': true};
  const one = [small];

  screens('album_off', () => ContentDetailScreen(content: albumTitle()),
      overrides: hub, phones: one, scrolls: 1);
  screens('album_saver', () => ContentDetailScreen(content: albumTitle()),
      overrides: hub, prefs: saverOn, scrolls: 1);
  screens('viewer_saver', () => AlbumViewerScreen(content: albumTitle(), initialIndex: 3),
      overrides: hub, prefs: saverOn, phones: one);
  screens('downloads_saver', () => const DownloadsScreen(),
      overrides: hub, prefs: saverOn, phones: one);
  final demo = const DemoContentDataSource().all();
  final saved = <String, Object>{
    'vh_bookmarks_v1': jsonEncode({
      'items': [
        for (final (i, c) in demo.take(7).indexed)
          {'id': c.id, 'at': DateTime.utc(2026, 10, 3, 9, i).toIso8601String()},
      ],
    }),
  };
  screens('account', () => const AccountScreen(), overrides: hub, prefs: {...saverOn, ...saved}, phones: one);
  screens('saver_screen', () => const DataSaverScreen(), prefs: saverOn, phones: one);
  screens('saver_screen_off', () => const DataSaverScreen(), phones: one);
  screens('bookmarks', () => const BookmarksScreen(), overrides: hub, prefs: saved);
  screens('bookmarks_edit', () => const BookmarksScreen(), overrides: hub, prefs: saved, phones: one,
      act: (t) async => t.tap(find.byKey(const ValueKey('bookmarks-edit'))));
  screens('bookmarks_empty', () => const BookmarksScreen(), overrides: hub, phones: one);
}
