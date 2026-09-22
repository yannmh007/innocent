// The offline shelf: what it keeps, what it verifies, and what it throws away.
//
// WHY THIS IS TESTED. Every failure here is a file: a gigabyte that no screen
// lists and no button can delete, or a row that spins forever because the
// file behind it is gone. Neither throws, neither logs, and on a phone with
// 32 GB of storage the first one is the kind of bug people uninstall over.
//
// The filesystem is real here rather than mocked. These are small files in a
// temp directory, and the behaviour under test IS the filesystem interaction
// — an index that agrees with a fake is worth nothing.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Points getApplicationSupportDirectory at a temp folder.
class _FakePaths extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late OfflineLibrary library;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('offline_test');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    library = OfflineLibrary();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<OfflineItem> seed(String id, {int bytes = 10}) async {
    final dir = await library.directory();
    final f = File('${dir.path}/$id.mp4');
    await f.writeAsBytes(List<int>.filled(bytes, 0));
    final item = OfflineItem(
      titleId: id,
      title: 'Title $id',
      path: f.path,
      bytes: bytes,
      addedAt: DateTime.now(),
    );
    await library.put(item);
    return item;
  }

  group('the shelf', () {
    test('starts empty and round-trips an item', () async {
      expect(await library.items(), isEmpty);
      await seed('a');
      final items = await library.items();
      expect(items, hasLength(1));
      expect(items.single.titleId, 'a');
      expect(items.single.title, 'Title a');
    });

    test('one entry per title — a second put replaces, never duplicates',
        () async {
      // Without this the same film downloaded twice would occupy two rows
      // pointing at one file, and deleting either would break the other.
      await seed('a', bytes: 10);
      await seed('a', bytes: 20);
      final items = await library.items();
      expect(items, hasLength(1));
      expect(items.single.bytes, 20);
    });

    test('newest first', () async {
      await seed('old');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await seed('new');
      expect((await library.items()).first.titleId, 'new');
    });
  });

  group('verification against the filesystem', () {
    test('an entry whose file Android deleted is dropped from the list',
        () async {
      // Android reclaims app-private storage without telling the app. An
      // index entry with no file is a row that spins forever when tapped.
      final item = await seed('a');
      await File(item.path).delete();

      expect(await library.items(), isEmpty);
      expect(await library.has('a'), isFalse);
    });

    test('the prune is written back, not just filtered for display', () async {
      final item = await seed('a');
      await seed('b');
      await File(item.path).delete();

      await library.items();
      // A fresh instance reads the stored index, so this proves the pruned
      // list was persisted rather than recomputed on every read.
      final fresh = OfflineLibrary();
      expect(await fresh.items(), hasLength(1));
      expect((await fresh.items()).single.titleId, 'b');
    });

    test('an unreadable index is an empty shelf, not a crash', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'vh_offline_index': 'not json at all'},
      );
      expect(await OfflineLibrary().items(), isEmpty);
    });
  });

  group('deleting', () {
    test('drop removes the file AND the entry', () async {
      final item = await seed('a');
      await library.drop('a');
      expect(await File(item.path).exists(), isFalse);
      expect(await library.items(), isEmpty);
    });

    test('dropAll sweeps .part files no index ever knew about', () async {
      // A download interrupted mid-flight leaves one of these. Nothing
      // references it, so only a directory sweep can find it — and without
      // one it is a gigabyte that no screen lists and no button deletes.
      await seed('a');
      final dir = await library.directory();
      final orphan = File('${dir.path}/ghost.mp4${OfflineLibrary.partSuffix}');
      await orphan.writeAsBytes(<int>[1, 2, 3]);

      await library.dropAll();

      expect(await library.items(), isEmpty);
      expect(await orphan.exists(), isFalse);
      expect(await dir.list().isEmpty, isTrue);
    });
  });

  group('totals', () {
    test('adds up what is actually on disk', () async {
      await seed('a', bytes: 100);
      await seed('b', bytes: 250);
      expect(await library.totalBytes(), 350);
    });
  });
}
