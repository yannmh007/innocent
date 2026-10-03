import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/video_hub/data/cache/catalogue_cache.dart';
import 'package:innocent/features/video_hub/data/demo_content_datasource.dart';
import 'package:innocent/features/video_hub/data/demo_content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/content_detail_screen.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_screen.dart';
import 'package:innocent/features/video_hub/presentation/widgets/featured_hero.dart';
import 'package:innocent/features/video_hub/presentation/widgets/hub_states.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE FLICKER (reported 2026-10-03): entering Movies, and opening a card's
/// album, the screen flashed — twice in a row, mostly on the first visit.
///
/// The catalogue answers from its saved copy at once and refreshes behind it;
/// when the refresh brings anything new it bumps a revision every catalogue
/// provider watches. Those providers re-ran, and while they did the screens
/// drew their LOADING state: the hero vanished (`asData` is null while
/// reloading), the rows became skeletons, the album grid emptied back to the
/// card. Then the new data drew. Two refreshes landing a moment apart (the
/// hero's key and the rows' key) made it two flashes.
///
/// A refresh must replace what is on screen in place, never take it away.

/// The demo catalogue, slowed so a reload has a visible middle.
class _SlowRepo extends DemoContentRepository {
  @override
  Future<List<ContentRow>> getRows() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return super.getRows();
  }

  @override
  Future<VideoContent?> getFeatured() async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    return super.getFeatured();
  }

  @override
  Future<VideoContent?> getById(String id) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final c = await super.getById(id);
    return c?.withAlbum(const <AlbumItem>[
      AlbumItem(id: 'p1', kind: MediaKind.photo, source: MediaRef(provider: 'url', locator: 'x'), width: 100, height: 100),
      AlbumItem(id: 'p2', kind: MediaKind.photo, source: MediaRef(provider: 'url', locator: 'y'), width: 100, height: 100),
    ]);
  }
}

void _plugins() {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final dir = Directory.systemTemp.createTempSync('flicker');
  final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  m.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'), (_) async => dir.path);
  m.setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'), (_) async => null);
}

Widget _app(Widget home) => ProviderScope(
      overrides: [contentRepositoryProvider.overrideWithValue(_SlowRepo())],
      child: MaterialApp(
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: home,
      ),
    );

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 12; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_plugins);

  testWidgets('a background refresh keeps the hero and the rows on screen', timeout: const Timeout(Duration(seconds: 60)), (t) async {
    await t.pumpWidget(_app(const VideoHubScreen()));
    await _settle(t);
    expect(find.byType(FeaturedHero), findsOneWidget);
    expect(find.byType(RowSkeletonList), findsNothing);

    CatalogueCache.noteRefreshed(); // what a changed refresh does
    CatalogueCache.noteRefreshed(); // and a second key landing just after
    // Through the whole reload, frame by frame: never a missing hero, never
    // a skeleton where the rows were.
    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 60));
      expect(find.byType(FeaturedHero), findsOneWidget, reason: 'frame $i');
      expect(find.byType(RowSkeletonList), findsNothing, reason: 'frame $i');
    }
    await _settle(t);
  });

  testWidgets('a background refresh keeps an open album on screen', timeout: const Timeout(Duration(seconds: 60)), (t) async {
    // Synchronously: the repository's simulated latency is a timer, and a
    // timer does not fire inside a widget test unless the test pumps.
    final card = const DemoContentDataSource().all().first;
    await t.pumpWidget(_app(ContentDetailScreen(content: card)));
    await _settle(t);
    final tiles = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_AlbumTile');
    final before = tiles.evaluate().length;
    expect(before, greaterThan(0));

    CatalogueCache.noteRefreshed();
    for (var i = 0; i < 16; i++) {
      await t.pump(const Duration(milliseconds: 60));
      expect(tiles.evaluate().length, before, reason: 'frame $i: the album emptied');
    }
    await _settle(t);
  });
}
