// The data saver's promise: with it on, an album item that is not on the
// phone is drawn from its blurhash with a download button — and the normal
// tile, which is what fetches the picture, is not built at all.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/album_saver.dart';
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

const _photo = AlbumItem(
  id: 'p1',
  kind: MediaKind.photo,
  source: MediaRef(provider: 'url', locator: 'https://x/p1.jpg'),
  preview: 'LyI5ej3AfQxtz4NKfQnSeXf7fQf7',
);
const _clip = AlbumItem(
  id: 'c1',
  kind: MediaKind.video,
  source: MediaRef(provider: 'asset', locator: 'c1'),
  durationSec: 75,
);
const _content = VideoContent(
  id: 't',
  title: 'T',
  category: ContentCategory.movies,
  items: <AlbumItem>[_photo, _clip],
);

void main() {
  late Directory temp;
  late OfflineLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('album_saver_test');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    library = OfflineLibrary();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> pump(WidgetTester tester,
      {required bool saver,
      required AlbumItem item,
      bool locked = false,
      Future<bool>? answer,
      VoidCallback? onOpen,
      VoidCallback? onPlay}) async {
    await tester.runAsync(() async {
      // The switch itself, which the gate reads before the connection
      // question. Written, not reset, so rows a test put on the shelf stay.
      await (await SharedPreferences.getInstance())
          .setBool('pref_player_albumDataSaver', saver);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          offlineLibraryProvider.overrideWithValue(library),
          offlineDownloaderProvider
              .overrideWithValue(OfflineDownloader(_NoRepo(), library)),
          albumSaverProvider.overrideWith((ref) => answer ?? Future.value(saver)),
        ],
        child: MaterialApp(
          localizationsDelegates: AppStrings.localizationsDelegates,
          supportedLocales: AppStrings.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 200,
              // The album tile's own tap (open the viewer) sits OUTSIDE the
              // gate, as it does in content_detail_screen.
              child: InkWell(
                onTap: onOpen,
                child: AlbumSaverGate(
                  content: _content,
                  item: item,
                  locked: locked,
                  onPlay: onPlay ?? () {},
                  normal: const Text('normal tile'),
                ),
              ),
            ),
          ),
        ),
      ));
      // The saver answer, then the shelf read it leads to: real I/O, so the
      // frames that carry them run on the real clock.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();
      }
    });
    await tester.pump();
  }

  testWidgets('off: the normal tile', (tester) async {
    await pump(tester, saver: false, item: _photo);
    expect(find.text('normal tile'), findsOneWidget);
  });

  testWidgets('on: frost and a download button, and the tile is never built',
      (tester) async {
    await pump(tester, saver: true, item: _photo);
    expect(find.text('normal tile'), findsNothing);
    expect(find.byKey(const ValueKey('saver-dl-p1')), findsOneWidget);
    expect(find.byType(BlurPreview), findsOneWidget);
    expect(find.byType(Image), findsOneWidget); // the blurhash, from memory
  });

  testWidgets('on, a clip: play and download, and its length', (tester) async {
    await pump(tester, saver: true, item: _clip);
    expect(find.byKey(const ValueKey('saver-play-c1')), findsOneWidget);
    expect(find.byKey(const ValueKey('saver-dl-c1')), findsOneWidget);
    expect(find.text('1:15'), findsOneWidget);
    // No blurhash yet: a plain frosted square, still no picture fetched.
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('on, locked: frost and the lock, nothing to download',
      (tester) async {
    await pump(tester, saver: true, item: _photo, locked: true);
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);
    expect(find.byKey(const ValueKey('saver-dl-p1')), findsNothing);
  });

  testWidgets('on, but already on the phone: the real thing', (tester) async {
    await tester.runAsync(() async {
      final dir = await library.directory();
      final f = File('${dir.path}/t.p1.jpg');
      await f.writeAsBytes(<int>[1, 2, 3]);
      await library.put(OfflineItem(
        titleId: 't',
        key: 't.p1',
        kind: 'photo',
        sourceUrl: 'https://x/p1.jpg',
        title: 'T',
        path: f.path,
        bytes: 3,
        addedAt: DateTime.now(),
      ));
    });
    await pump(tester, saver: true, item: _photo);
    expect(find.text('normal tile'), findsOneWidget);
  });

  testWidgets('on, connection not answered yet: frosted, never the real tile',
      (tester) async {
    // The first frame is the one that would start the fetch.
    await pump(tester,
        saver: true, item: _photo, answer: Completer<bool>().future);
    expect(find.text('normal tile'), findsNothing);
    expect(find.byKey(const ValueKey('saver-dl-p1')), findsOneWidget);
  });

  // Telegram, with auto-download off (2026-10-03 report: "the download circle
  // opened the item instead of downloading it, and needed a second tap"):
  testWidgets('a tap anywhere on a frosted photo downloads it, never opens it',
      (tester) async {
    var opened = 0;
    await pump(tester, saver: true, item: _photo, onOpen: () => opened++);
    // The corner, well away from the download circle in the middle.
    await tester.tapAt(tester.getTopLeft(find.byType(AlbumSaverGate)) + const Offset(10, 10));
    await tester.pump();
    expect(opened, 0, reason: 'the viewer opened on an item that is not there');
    await tester.tap(find.byKey(const ValueKey('saver-dl-p1')));
    await tester.pump();
    expect(opened, 0);
  });

  testWidgets('a frosted clip plays from its tile; its arrow only downloads',
      (tester) async {
    var opened = 0, played = 0;
    await pump(tester,
        saver: true, item: _clip, onOpen: () => opened++, onPlay: () => played++);
    await tester.tapAt(tester.getTopLeft(find.byType(AlbumSaverGate)) + const Offset(10, 10));
    await tester.pump();
    expect(played, 1);
    expect(opened, 0);
  });

  testWidgets('once on the phone, the tile opens as normal', (tester) async {
    var opened = 0;
    await tester.runAsync(() async {
      final dir = await library.directory();
      final f = File('${dir.path}/t.p1.jpg');
      await f.writeAsBytes(<int>[1, 2, 3]);
      await library.put(OfflineItem(
        titleId: 't',
        key: 't.p1',
        kind: 'photo',
        sourceUrl: 'https://x/p1.jpg',
        title: 'T',
        path: f.path,
        bytes: 3,
        addedAt: DateTime.now(),
      ));
    });
    await pump(tester, saver: true, item: _photo, onOpen: () => opened++);
    await tester.tap(find.text('normal tile'));
    await tester.pump();
    expect(opened, 1);
    // And the saved photo is found by the address the tile asks for.
    expect(OfflineLibrary.photoPathFor('https://x/p1.jpg'), isNotNull);
  });
}
