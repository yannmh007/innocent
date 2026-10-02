// Album downloads, item by item: which items count as missing, how the shelf
// keys them, and how a photo gets onto the phone.
//
// WHY THIS IS TESTED. The promise the album button makes — "Downloaded", or
// "+2 Video" after the admin adds two clips — is made to somebody who is about
// to go offline and cannot check it. A wrong count either sends them away with
// two clips missing, or fetches the film a second time over mobile data.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/data/poster_cache.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

/// No method of this is called by a PHOTO download; anything that is, fails
/// the test loudly.
class _NoRepo implements ContentRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

AlbumItem _video(String id, {bool main = false, int? bytes, bool free = false}) =>
    AlbumItem(
      id: id,
      kind: MediaKind.video,
      source: MediaRef(provider: 'asset', locator: id),
      isMain: main,
      bytes: bytes,
      isPreview: free,
    );

AlbumItem _photo(String id, {int? bytes}) => AlbumItem(
      id: id,
      kind: MediaKind.photo,
      source: MediaRef(provider: 'url', locator: 'https://cdn.example/p/$id.jpg'),
      bytes: bytes,
    );

void main() {
  group('offlineKeyFor', () {
    test('the film keeps the bare title id', () {
      expect(offlineKeyFor('t1'), 't1');
      expect(offlineKeyFor('t1', assetId: ''), 't1');
    });

    test('an album item is title.asset', () {
      expect(offlineKeyFor('t1', assetId: 'a9'), 't1.a9');
    });

    test("the album's copy of the film shares the film's key", () {
      expect(albumItemKey('t1', _video('m', main: true)), 't1');
      expect(albumItemKey('t1', _video('c')), 't1.c');
      expect(offlineAssetIdOf(_video('m', main: true)), isNull);
    });
  });

  group('albumOfflineStatus', () {
    final album = <AlbumItem>[
      _video('m', main: true, bytes: 1000),
      _video('c1', bytes: 200),
      _photo('p1', bytes: 10),
      _photo('p2', bytes: 20),
    ];

    test('nothing held: everything missing, Download all', () {
      final st = albumOfflineStatus(
        titleId: 't',
        items: album,
        heldKeys: const <String>{},
        canDownload: (_) => true,
      );
      expect(st.missing.length, 4);
      expect(st.held, 0);
      expect(st.complete, isFalse);
      expect(st.hasNew, isFalse);
      expect(st.missingBytes, 1230);
      expect(st.sizeKnown, isTrue);
    });

    test('the downloaded FILM counts as the album item that is the film', () {
      final st = albumOfflineStatus(
        titleId: 't',
        items: album,
        heldKeys: const <String>{'t'},
        canDownload: (_) => true,
      );
      expect(st.held, 1);
      expect(st.missing.map((i) => i.id), <String>['c1', 'p1', 'p2']);
      expect(st.hasNew, isTrue);
    });

    test('everything held: complete, the button dims', () {
      final st = albumOfflineStatus(
        titleId: 't',
        items: album,
        heldKeys: const <String>{'t', 't.c1', 't.p1', 't.p2'},
        canDownload: (_) => true,
      );
      expect(st.complete, isTrue);
      expect(st.missing, isEmpty);
      expect(st.hasNew, isFalse);
    });

    test('the admin adds two clips: +2 Video, and only those two', () {
      final grown = <AlbumItem>[...album, _video('c2'), _video('c3', bytes: 5)];
      final st = albumOfflineStatus(
        titleId: 't',
        items: grown,
        heldKeys: const <String>{'t', 't.c1', 't.p1', 't.p2'},
        canDownload: (_) => true,
      );
      expect(st.hasNew, isTrue);
      expect(st.missingVideos, 2);
      expect(st.missingPhotos, 0);
      expect(st.missing.map((i) => i.id), <String>['c2', 'c3']);
      // c2 has no recorded size, so the total is a lower bound.
      expect(st.sizeKnown, isFalse);
      expect(st.missingBytes, 5);
    });

    test('a replaced photo is a new asset id, so it reads as missing', () {
      final swapped = <AlbumItem>[album[0], album[1], album[2], _photo('p2b')];
      final st = albumOfflineStatus(
        titleId: 't',
        items: swapped,
        heldKeys: const <String>{'t', 't.c1', 't.p1', 't.p2'},
        canDownload: (_) => true,
      );
      expect(st.missing.map((i) => i.id), <String>['p2b']);
      expect(st.missingPhotos, 1);
    });

    test('a locked item is neither missing nor counted', () {
      final st = albumOfflineStatus(
        titleId: 't',
        items: album,
        heldKeys: const <String>{'t.p1'},
        canDownload: (i) => !i.isVideo,
      );
      expect(st.total, 2);
      expect(st.missing.map((i) => i.id), <String>['p2']);
      expect(st.missingVideos, 0);
    });

    test('two items naming the film are one file, not two', () {
      final dup = <AlbumItem>[_video('m', main: true), _video('m2', main: true)];
      final st = albumOfflineStatus(
        titleId: 't',
        items: dup,
        heldKeys: const <String>{'t'},
        canDownload: (_) => true,
      );
      expect(st.total, 1);
      expect(st.complete, isTrue);
    });
  });

  group('shelf keys', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    late Directory temp;
    late OfflineLibrary library;

    setUp(() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      temp = await Directory.systemTemp.createTemp('album_offline_test');
      PathProviderPlatform.instance = _FakePaths(temp.path);
      library = OfflineLibrary();
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    Future<OfflineItem> seed(String titleId,
        {String? assetId, String kind = 'video', String? url}) async {
      final dir = await library.directory();
      final key = offlineKeyFor(titleId, assetId: assetId);
      final f = File('${dir.path}/$key.${kind == 'photo' ? 'jpg' : 'mp4'}');
      await f.writeAsBytes(List<int>.filled(10, 1));
      final item = OfflineItem(
        titleId: titleId,
        key: key,
        kind: kind,
        sourceUrl: url,
        assetId: assetId,
        title: 'T',
        path: f.path,
        bytes: 10,
        addedAt: DateTime.now(),
      );
      await library.put(item);
      return item;
    }

    test('a row from before albums reads as the film, keyed by its title', () {
      final row = OfflineItem.fromJson(<String, dynamic>{
        'titleId': 'old',
        'title': 'Old',
        'path': '/x/old.mp4',
        'bytes': 5,
        'addedAt': DateTime.now().toIso8601String(),
        // Even with an asset id on it — the old key was always the title.
        'assetId': 'zz',
      })!;
      expect(row.key, 'old');
      expect(row.isFilm, isTrue);
      expect(row.isPhoto, isFalse);
      final pending = PendingDownload.fromJson(<String, dynamic>{
        'titleId': 'old',
        'title': 'Old',
        'assetId': 'zz',
      })!;
      expect(pending.key, 'old');
    });

    test('the film and its album items live side by side', () async {
      await seed('t');
      await seed('t', assetId: 'c1');
      await seed('t', assetId: 'p1', kind: 'photo', url: 'https://x/p1.jpg');
      await seed('other');

      expect((await library.find('t'))!.isFilm, isTrue);
      expect((await library.find('t.c1'))!.assetId, 'c1');
      final mine = await library.forTitle('t');
      expect(mine.map((i) => i.key).toSet(), <String>{'t', 't.c1', 't.p1'});
    });

    test('deleting a clip leaves the film, and the film leaves the clips',
        () async {
      await seed('t');
      final clip = await seed('t', assetId: 'c1');
      await library.drop('t.c1');
      expect(await File(clip.path).exists(), isFalse);
      expect(await library.has('t'), isTrue);

      await seed('t', assetId: 'c1');
      await library.drop('t');
      expect(await library.has('t.c1'), isTrue);
      expect(await library.has('t'), isFalse);
    });

    test('dropTitle removes everything of one title only', () async {
      await seed('t');
      await seed('t', assetId: 'c1');
      await seed('u');
      await library.dropTitle('t');
      expect((await library.items()).map((i) => i.key), <String>['u']);
    });

    test('a saved photo is found by its URL, and forgotten when deleted',
        () async {
      final p = await seed('t',
          assetId: 'p1', kind: 'photo', url: 'https://x/p1.jpg');
      expect(OfflineLibrary.photoPathFor('https://x/p1.jpg'), p.path);
      await library.drop(p.key);
      expect(OfflineLibrary.photoPathFor('https://x/p1.jpg'), isNull);
    });

    test('pending rows are keyed per item, so two clips can both be pending',
        () async {
      await library.putPending(PendingDownload(
          titleId: 't', key: 't.c1', assetId: 'c1', title: 'T',
          startedAt: DateTime.now()));
      await library.putPending(PendingDownload(
          titleId: 't', key: 't.c2', assetId: 'c2', title: 'T',
          startedAt: DateTime.now()));
      final dir = await library.directory();
      await File('${dir.path}/t.c1.mp4.part').writeAsBytes(<int>[1, 2, 3]);

      final pending = await library.pending();
      expect(pending.map((p) => p.item.key).toSet(), <String>{'t.c1', 't.c2'});
      expect(pending.firstWhere((p) => p.item.key == 't.c1').received, 3);

      await library.discardPending('t.c1');
      expect(await File('${dir.path}/t.c1.mp4.part').exists(), isFalse);
      expect((await library.pending()).map((p) => p.item.key), <String>['t.c2']);
    });

    test('sign-out stops each premium item by its own key', () async {
      await library.putPending(PendingDownload(
          titleId: 't', key: 't.c1', assetId: 'c1', title: 'T',
          startedAt: DateTime.now()));
      final stopped = <String>[];
      await library.dropEntitled(stop: stopped.add);
      expect(stopped, <String>['t.c1']);
    });

    test('the clip resumes from its own source, not the film', () {
      const content = VideoContent(
        id: 't',
        title: 'T',
        category: ContentCategory.movies,
        source: MediaRef(provider: 'server', locator: 't'),
      );
      expect(OfflineDownloader.sourceFor(content, null).provider, 'server');
      final clip = OfflineDownloader.sourceFor(content, 'c1');
      expect(clip.provider, 'asset');
      expect(clip.locator, 'c1');
    });

    group('photo download', () {
      const content = VideoContent(
        id: 't',
        title: 'T',
        category: ContentCategory.movies,
        accessTier: AccessTier.premium,
      );
      const url = 'https://cdn.example/p/p1.jpg';

      setUp(() => PosterCache.enabled = false);
      tearDown(() => PosterCache.enabled = true);

      test('a complete photo lands on the shelf under its own key', () async {
        final client = MockClient((req) async =>
            http.Response.bytes(List<int>.filled(300, 7), 200,
                headers: <String, String>{'content-length': '300'}));
        final d = OfflineDownloader(_NoRepo(), library, httpClient: client);
        final got =
            await d.downloadPhoto(content: content, assetId: 'p1', url: url);
        expect(got, isNotNull);
        expect(got!.key, 't.p1');
        expect(got.isPhoto, isTrue);
        expect(got.premium, isTrue);
        expect(got.bytes, 300);
        expect(await File(got.path).length(), 300);
        expect(got.path.endsWith('.jpg'), isTrue);
        expect(OfflineLibrary.photoPathFor(url), got.path);
        expect(d.isRunning('t.p1'), isFalse);
      });

      test('a 404 is an answer: one request, nothing kept', () async {
        var calls = 0;
        final client = MockClient((req) async {
          calls++;
          return http.Response('gone', 404);
        });
        final d = OfflineDownloader(_NoRepo(), library, httpClient: client);
        String? error;
        final got = await d.downloadPhoto(
            content: content,
            assetId: 'p1',
            url: url,
            onProgress: (p) => error ??= p.error);
        expect(got, isNull);
        expect(error, 'gave_up');
        expect(calls, 1);
        expect(await library.has('t.p1'), isFalse);
        final dir = await library.directory();
        expect(dir.listSync().whereType<File>(), isEmpty);
      });

      test('refused on mobile data when Wi-Fi only is on', () async {
        final client = MockClient((req) async => http.Response('x', 200));
        final d = OfflineDownloader(_NoRepo(), library,
            httpClient: client,
            allowance: () async => DownloadRefusal.meteredWhileWifiOnly);
        String? error;
        final got = await d.downloadPhoto(
            content: content,
            assetId: 'p1',
            url: url,
            onProgress: (p) => error ??= p.error);
        expect(got, isNull);
        expect(error, 'meteredWhileWifiOnly');
      });
    });
  });

  test('photoExtension', () {
    expect(photoExtension('https://x/a/b.JPG?x=1'), '.jpg');
    expect(photoExtension('https://x/a/b.webp'), '.webp');
    expect(photoExtension('https://x/a/b'), '.img');
  });
}
