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
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/offline_crypto.dart';
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

  Future<OfflineItem> seed(String id,
      {int bytes = 10, bool premium = true}) async {
    final dir = await library.directory();
    final f = File('${dir.path}/$id.mp4');
    await f.writeAsBytes(List<int>.filled(bytes, 0));
    final item = OfflineItem(
      titleId: id,
      title: 'Title $id',
      path: f.path,
      bytes: bytes,
      addedAt: DateTime.now(),
      premium: premium,
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

    // BOTH DIRECTIONS OF A LENGTH MISMATCH, because they mean opposite things
    // and the first version of the check treated them the same — and deleted a
    // film at the instant it finished downloading.
    test('a truncated file is dropped, and the file goes with it', () async {
      // "Downloaded" is a promise made offline, where the app cannot go back
      // and look. A film that stops in the middle is not a shorter film.
      final item = await seed('a', bytes: 100);
      await File(item.path).writeAsBytes(List<int>.filled(40, 0));

      expect(await library.items(), isEmpty);
      expect(await File(item.path).exists(), isFalse);
    });

    test('a file LONGER than its row is a stale row, not a broken file',
        () async {
      // A re-download renames `<id>.mp4.part` over `<id>.mp4`, so between the
      // rename and the index write the file is the new one and the row still
      // describes the old. Deleting here destroyed a good download.
      final item = await seed('a', bytes: 100);
      await File(item.path).writeAsBytes(List<int>.filled(250, 0));

      final items = await library.items();
      expect(items, hasLength(1));
      expect(await File(item.path).exists(), isTrue);
      // And the row is corrected rather than left disagreeing with the disk.
      expect(items.single.bytes, 250);
    });

    test('a second put of the same title does not destroy its own file',
        () async {
      // The regression this whole split exists for: `put` used to read the
      // shelf through the verifying path, so writing the new row ran the
      // damage check against the file it had just replaced.
      await seed('a', bytes: 10);
      await seed('a', bytes: 20);
      final items = await library.items();
      expect(items, hasLength(1));
      expect(items.single.bytes, 20);
      expect(await File(items.single.path).exists(), isTrue);
    });

    test('an unreadable index is an empty shelf, not a crash', () async {
      SharedPreferences.setMockInitialValues(
        <String, Object>{'vh_offline_index': 'not json at all'},
      );
      expect(await OfflineLibrary().items(), isEmpty);
    });
  });

  group('a sealed download', () {
    // A sealed film is the object's bytes plus a thirty-two byte trailer, and
    // the row says so. Every test here is about the shelf's verification
    // reading that length correctly: the first version compared a sealed file
    // against the object's length, called every one of them a stale row, and
    // recorded a size that was not the film's.

    Future<OfflineItem> seedSealed(String id, {int bytes = 100}) async {
      final dir = await library.directory();
      final f = File('${dir.path}/$id.mp4');
      await f.writeAsBytes(<int>[
        ...List<int>.filled(bytes, 0),
        ...OfflineCrypto.composeTrailer(
          iv: Uint8List(16),
          plainLength: bytes,
        ),
      ]);
      final item = OfflineItem(
        titleId: id,
        title: 'Title $id',
        path: f.path,
        bytes: bytes,
        addedAt: DateTime.now(),
        sealed: true,
      );
      await library.put(item);
      return item;
    }

    test('survives verification, and its size stays the object\'s', () async {
      final item = await seedSealed('a', bytes: 100);
      expect(await File(item.path).length(), 132);
      final items = await library.items();
      expect(items, hasLength(1));
      expect(items.single.sealed, isTrue);
      // NOT 132. `bytes` is what the viewer paid data for and what the shelf
      // shows; the trailer is the app's own overhead.
      expect(items.single.bytes, 100);
    });

    test('a sealed film that lost its trailer is damage, not a short film',
        () async {
      // The one case a plain-file shelf could not tell apart. Without the row
      // saying the film is sealed, this file is thirty-two bytes shorter than
      // it should be and passes for a legitimate MP4 — which is then handed to
      // the player and drawn as noise.
      final item = await seedSealed('a', bytes: 100);
      await File(item.path).writeAsBytes(List<int>.filled(100, 0));

      expect(await library.items(), isEmpty);
      expect(await File(item.path).exists(), isFalse);
    });

    test('a truncated sealed film goes, like any other truncated film',
        () async {
      final item = await seedSealed('a', bytes: 100);
      await File(item.path).writeAsBytes(List<int>.filled(40, 0));
      expect(await library.items(), isEmpty);
    });

    test('a stale row is still corrected, and by the object\'s length',
        () async {
      // A re-download of a sealed film, caught between the rename and the index
      // write. The correction has to subtract the trailer, or the row records a
      // size thirty-two bytes larger than the film and never agrees with the
      // disk again.
      final item = await seedSealed('a', bytes: 100);
      await File(item.path).writeAsBytes(<int>[
        ...List<int>.filled(250, 0),
        ...OfflineCrypto.composeTrailer(
          iv: Uint8List(16),
          plainLength: 250,
        ),
      ]);
      final items = await library.items();
      expect(items, hasLength(1));
      expect(items.single.bytes, 250);
    });

    test('a row written before sealing existed reads as a plain file',
        () async {
      // Every download on every phone today. Reading one as sealed would hand
      // libmpv a decryptor it does not need and draw noise over a film that was
      // fine.
      final item = OfflineItem.fromJson(<String, dynamic>{
        'titleId': 'old',
        'title': 'Old',
        'path': '/x/old.mp4',
        'bytes': 10,
        'addedAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(item!.sealed, isFalse);
    });

    test('sealed-ness survives a write and a reread', () async {
      await seedSealed('a', bytes: 64);
      final fresh = OfflineLibrary();
      final items = await fresh.items();
      expect(items.single.sealed, isTrue);
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

  group('free downloads are not the account\'s to take back', () {
    // THE BUG. The Downloads screen opened every item as premium, so a FREE
    // film downloaded on an anonymous account showed the paywall — an hour of
    // mobile data spent on something the app then refused to open, with no way
    // past it but paying for what was free.
    test('a free download round-trips as free', () async {
      await seed('free', premium: false);
      await seed('paid');
      final items = await library.items();
      expect(items.firstWhere((i) => i.titleId == 'free').premium, isFalse);
      expect(items.firstWhere((i) => i.titleId == 'paid').premium, isTrue);
    });

    test('a row written before the field existed reads as premium', () async {
      // The unknown case has to be the PROTECTED one: getting it wrong the
      // other way strips capture protection from paid content, and unlike a
      // lockout that is not recoverable by watching the film again online.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'vh_offline_index': '[{"titleId":"old","title":"Old",'
            '"path":"/nope","bytes":0,"addedAt":"2026-01-01T00:00:00Z"}]',
      });
      final lib = OfflineLibrary();
      // The file is missing so the shelf prunes it; what matters is the parse.
      final parsed = OfflineItem.fromJson(<String, dynamic>{
        'titleId': 'old',
        'title': 'Old',
        'path': '/nope',
        'bytes': 0,
        'addedAt': '2026-01-01T00:00:00Z',
      });
      expect(parsed!.premium, isTrue);
      expect(await lib.items(), isEmpty);
    });

    test('signing out takes the paid downloads and leaves the free ones',
        () async {
      final free = await seed('free', premium: false);
      final paid = await seed('paid');

      await library.dropEntitled();

      final left = await library.items();
      expect(left, hasLength(1));
      expect(left.single.titleId, 'free');
      expect(await File(free.path).exists(), isTrue);
      expect(await File(paid.path).exists(), isFalse);
    });

    test('the entitled sweep collects litter without eating a free download',
        () async {
      final free = await seed('free', premium: false);
      final dir = await library.directory();
      final orphan = File('${dir.path}/ghost.mp4${OfflineLibrary.partSuffix}');
      await orphan.writeAsBytes(<int>[1, 2, 3]);

      await library.dropEntitled();

      expect(await orphan.exists(), isFalse);
      expect(await File(free.path).exists(), isTrue);
    });

    test('a running premium download is STOPPED before its file is deleted',
        () async {
      // THE BUG THIS PINS. Deleting a part file does not stop the downloader
      // writing to it: on POSIX an open handle outlives its name, so the
      // transfer carries on spending the viewer's mobile data into a file
      // nothing can reach, and then either fails to rename or recreates the
      // part file empty and finishes a film that is mostly missing. Signing
      // out mid-download is uncommon; paying for the rest of a film afterwards
      // is not a thing to do to anybody.
      final dir = await library.directory();
      final part = File('${dir.path}/paid.mp4${OfflineLibrary.partSuffix}');
      await part.writeAsBytes(List<int>.filled(64, 0));
      await library.putPending(PendingDownload(
        titleId: 'paid',
        title: 'Paid',
        startedAt: DateTime.now(),
      ));

      // Recorded AT THE MOMENT it is called, so the order can be asserted and
      // not merely the fact.
      final stopped = <String>[];
      var fileWasThere = false;
      await library.dropEntitled(stop: (id) {
        stopped.add(id);
        fileWasThere = part.existsSync();
      });

      expect(stopped, <String>['paid']);
      expect(fileWasThere, isTrue,
          reason: 'stop must be called BEFORE the part file is deleted');
      expect(await part.exists(), isFalse);
    });

    test('a running FREE download is left alone, and keeps its bytes',
        () async {
      // A free title needs no account to watch and no entitlement to download.
      // Interrupting one on sign-out would cost data for a rule that does not
      // exist — and marking it paused, which stopping does, would stop it
      // resuming by itself ever again.
      final dir = await library.directory();
      final part = File('${dir.path}/free.mp4${OfflineLibrary.partSuffix}');
      await part.writeAsBytes(List<int>.filled(64, 0));
      await library.putPending(PendingDownload(
        titleId: 'free',
        title: 'Free',
        startedAt: DateTime.now(),
        premium: false,
      ));

      final stopped = <String>[];
      await library.dropEntitled(stop: stopped.add);

      expect(stopped, isEmpty);
      expect(await part.exists(), isTrue);
      expect(await part.length(), 64);
    });

    test('no stop function is not an error — the sweep still runs', () async {
      // Every existing call site passes nothing, and a test of the library
      // should not need a downloader to exist.
      final paid = await seed('paid');
      await library.dropEntitled();
      expect(await File(paid.path).exists(), isFalse);
    });

    test('dropAll still empties everything, free included', () async {
      await seed('free', premium: false);
      await seed('paid');
      await library.dropAll();
      expect(await library.items(), isEmpty);
      final dir = await library.directory();
      expect(await dir.list().isEmpty, isTrue);
    });
  });

  group('paused by the viewer, or interrupted', () {
    // THE LINE AUTOMATIC RESUMING IS DRAWN ON. Interrupted and paused look
    // identical on disk, so the pause has to be recorded when it happens —
    // otherwise the app either abandons downloads it should finish or overrules
    // people who deliberately stopped one, and spends their data doing it.
    Future<void> seedPending(String id, {int bytes = 5}) async {
      final dir = await library.directory();
      await File('${dir.path}/$id.mp4${OfflineLibrary.partSuffix}')
          .writeAsBytes(List<int>.filled(bytes, 0));
      await library.putPending(PendingDownload(
        titleId: id,
        title: 'Title $id',
        startedAt: DateTime.now(),
      ));
    }

    test('a fresh pending download is not paused', () async {
      await seedPending('a');
      final rows = await library.pending();
      expect(rows, hasLength(1));
      expect(rows.single.item.pausedByUser, isFalse);
    });

    test('markPaused records it, and it survives a reread', () async {
      await seedPending('a');
      await library.markPaused('a');
      expect((await OfflineLibrary().pending()).single.item.pausedByUser,
          isTrue);
    });

    test('marking a title with no row does not invent one', () async {
      await library.markPaused('never-existed');
      expect(await library.pending(), isEmpty);
    });

    test('starting again clears the pause, because it is being asked for',
        () async {
      await seedPending('a');
      await library.markPaused('a');
      await library.putPending(PendingDownload(
        titleId: 'a',
        title: 'Title a',
        startedAt: DateTime.now(),
      ));
      expect((await library.pending()).single.item.pausedByUser, isFalse);
    });

    test('a row shows what is on disk, and 0 when nothing is there yet',
        () async {
      // putPending runs BEFORE the first byte, so a row with no part file is
      // the ordinary state for the first seconds of a download. It must be
      // listed, not pruned — pruning it deleted the record of a live download.
      await library.putPending(PendingDownload(
        titleId: 'fresh',
        title: 'Fresh',
        startedAt: DateTime.now(),
      ));
      final rows = await library.pending();
      expect(rows, hasLength(1));
      expect(rows.single.received, 0);
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
