// The album's Download button: "Download all", "+2 Video", and "Downloaded"
// dimmed — drawn from what the phone actually holds.
//
// WHY THIS IS A WIDGET TEST. The three states are worked out by a pure
// function (album_offline_test.dart covers it); what can still go wrong is the
// wiring — the button reading a different key from the one the shelf wrote,
// or the film downloaded from its own button not counting for the album.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/domain/viewer.dart';
import 'package:innocent/features/video_hub/presentation/account_provider.dart';
import 'package:innocent/features/video_hub/presentation/album_downloads.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _NoRepo implements ContentRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

const _content = VideoContent(
  id: 't',
  title: 'T',
  category: ContentCategory.movies,
  items: <AlbumItem>[
    AlbumItem(
        id: 'm',
        kind: MediaKind.video,
        source: MediaRef(provider: 'asset', locator: 'm'),
        isMain: true),
    AlbumItem(
        id: 'c1',
        kind: MediaKind.video,
        source: MediaRef(provider: 'asset', locator: 'c1')),
    AlbumItem(
        id: 'c2',
        kind: MediaKind.video,
        source: MediaRef(provider: 'asset', locator: 'c2')),
    AlbumItem(
        id: 'p1',
        kind: MediaKind.photo,
        source: MediaRef(provider: 'url', locator: 'https://x/p1.jpg')),
  ],
);

void main() {
  late Directory temp;
  late OfflineLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('album_button_test');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    library = OfflineLibrary();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> hold(String key, {String kind = 'video'}) async {
    final dir = await library.directory();
    final f = File('${dir.path}/$key.bin');
    await f.writeAsBytes(<int>[1, 2, 3]);
    await library.put(OfflineItem(
      titleId: 't',
      key: key,
      kind: kind,
      title: 'T',
      path: f.path,
      bytes: 3,
      addedAt: DateTime.now(),
      premium: false,
    ));
  }

  Future<void> pump(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          offlineLibraryProvider.overrideWithValue(library),
          offlineDownloaderProvider
              .overrideWithValue(OfflineDownloader(_NoRepo(), library)),
          viewerProvider.overrideWithValue(const Viewer(
            tier: ViewerTier.anonymous,
            entitlement: Entitlement.free(),
            installId: 'test',
          )),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppStrings.localizationsDelegates,
          supportedLocales: AppStrings.supportedLocales,
          home: Scaffold(body: Center(child: AlbumDownloadButton(content: _content))),
        ),
      ));
      // The shelf read is real file I/O.
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  testWidgets('nothing on the phone: Download all', (tester) async {
    await pump(tester);
    expect(find.text('Download all'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-dl-new')), findsNothing);
  });

  testWidgets('the film from its own button counts; the rest is +2 Video +1 Photo',
      (tester) async {
    await tester.runAsync(() => hold('t'));
    await pump(tester);
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('+2 Video · +1 Photo'), findsOneWidget);
  });

  testWidgets('everything held: Downloaded, and nothing to press',
      (tester) async {
    await tester.runAsync(() async {
      await hold('t');
      await hold('t.c1');
      await hold('t.c2');
      await hold('t.p1', kind: 'photo');
    });
    await pump(tester);
    expect(find.byKey(const ValueKey('album-dl-done')), findsOneWidget);
    expect(find.text('Downloaded'), findsOneWidget);
    expect(find.byKey(const ValueKey('album-dl-start')), findsNothing);
  });

  testWidgets('a clip deleted elsewhere brings the button back as +1 Video',
      (tester) async {
    await tester.runAsync(() async {
      await hold('t');
      await hold('t.c1');
      await hold('t.c2');
      await hold('t.p1', kind: 'photo');
    });
    await pump(tester);
    expect(find.text('Downloaded'), findsOneWidget);

    // The drop ticks the shelf and the button re-reads it — real file I/O,
    // so the frames that carry the re-read run on the real clock.
    await tester.runAsync(() async {
      await library.drop('t.c2');
      for (var i = 0; i < 6; i++) {
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    });
    await tester.pump();
    expect(find.text('+1 Video'), findsOneWidget);
    expect(find.text('Download'), findsOneWidget);
  });
}
