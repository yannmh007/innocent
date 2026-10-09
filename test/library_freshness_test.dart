import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/cache/library_cache.dart';
import 'package:innocent/core/services/cache/scan_gate.dart';
import 'package:innocent/features/local_browser/data/library_local_datasource.dart';
import 'package:innocent/features/local_browser/domain/folder.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// MediaStore in miniature: what a scan would return right now.
class _Phone extends LibraryLocalDataSource {
  final Map<String, List<Video>> folders = <String, List<Video>>{};
  int scans = 0;

  void add(String folder, String name) {
    (folders[folder] ??= <Video>[]).add(Video(
      id: '$folder/$name',
      uri: '$folder/$name',
      title: name,
      folderPath: folder,
      duration: const Duration(minutes: 1),
      sizeBytes: 1,
      width: 1280,
      height: 720,
      dateAdded: DateTime.now(),
    ));
  }

  @override
  Future<List<Folder>> getFolders() async {
    scans++;
    return [
      for (final e in folders.entries)
        Folder(path: e.key, name: e.key.split('/').last, videoCount: e.value.length),
    ];
  }

  @override
  Future<List<Video>> getAllVideos() async {
    scans++;
    return [for (final v in folders.values) ...v];
  }

  @override
  Future<List<Video>> getVideosInFolder(String folderPath) async {
    scans++;
    return List<Video>.of(folders[folderPath] ?? const <Video>[]);
  }
}

/// The disk cache, in memory.
class _Cache extends LibraryCache {
  List<Folder>? f;
  List<Video>? all;
  final Map<String, List<Video>> byFolder = <String, List<Video>>{};

  @override
  Future<void> saveFolders(List<Folder> folders) async => f = folders;
  @override
  Future<List<Folder>?> loadFolders() async => f;
  @override
  Future<void> saveAllVideos(List<Video> videos) async => all = videos;
  @override
  Future<List<Video>?> loadAllVideos() async => all;
  @override
  Future<void> saveVideosInFolder(String folderPath, List<Video> videos) async =>
      byFolder[folderPath] = videos;
  @override
  Future<List<Video>?> loadVideosInFolder(String folderPath) async => byFolder[folderPath];
}

final _rescan = Provider<void Function()>((ref) => () => rescanLibrary(ref));

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Phone phone;
  late _Cache cache;
  late ProviderContainer c;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ScanGate.resetForTest();
    var gen = 0;
    ScanGate.readStamp = () async => 'v1|external_primary:v1:${gen++}|p:1';
    phone = _Phone()..add('/sdcard/Download', 'a.mp4');
    cache = _Cache();
    c = ProviderContainer(overrides: [
      libraryDataSourceProvider.overrideWithValue(phone),
      libraryCacheProvider.overrideWithValue(cache),
    ]);
  });

  tearDown(() => c.dispose());

  test('a video added to a folder that already exists reaches the folder list '
      'on the next rescan', () async {
    final sub = c.listen(foldersProvider, (_, __) {});
    expect((await c.read(foldersProvider.future)).single.videoCount, 1);

    phone.add('/sdcard/Download', 'b.mp4'); // same folder, one more video
    c.read(_rescan)();
    final after = await c.read(foldersProvider.future);
    expect(after.single.videoCount, 2,
        reason: 'the rescan must scan, not hand back the one-video cache');
    sub.close();
  });

  test('a rescan scans the flat list and an open folder too', () async {
    final s1 = c.listen(allVideosProvider, (_, __) {});
    final s2 = c.listen(videosInFolderProvider('/sdcard/Download'), (_, __) {});
    expect(await c.read(allVideosProvider.future), hasLength(1));
    expect(await c.read(videosInFolderProvider('/sdcard/Download').future), hasLength(1));

    phone.add('/sdcard/Download', 'new.mp4');
    c.read(_rescan)();
    expect((await c.read(allVideosProvider.future)).map((v) => v.title), contains('new.mp4'));
    expect((await c.read(videosInFolderProvider('/sdcard/Download').future)).map((v) => v.title),
        contains('new.mp4'));
    s1.close();
    s2.close();
  });

  test('on a cold start the background check sees a new video in an existing '
      'folder (it used to compare folder names only)', () async {
    // Yesterday's cache: one video. Today the phone has two.
    cache.f = [const Folder(path: '/sdcard/Download', name: 'Download', videoCount: 1)];
    phone.add('/sdcard/Download', 'b.mp4');
    final seen = <int>[];
    final sub = c.listen<AsyncValue<List<Folder>>>(foldersProvider, (_, next) {
      final v = next.valueOrNull;
      if (v != null) seen.add(v.single.videoCount);
    }, fireImmediately: true);
    await c.read(foldersProvider.future); // the cache, at once
    for (var i = 0; i < 20 && !seen.contains(2); i++) {
      await _settle();
    }
    expect(seen, contains(2), reason: 'saw $seen');
    sub.close();
  });

  test('ScanGate.changedSince: moved, unmoved, never scanned', () async {
    ScanGate.readStamp = () async => 'g1';
    expect(await ScanGate.changedSince('all'), isTrue, reason: 'never scanned');
    await ScanGate.record('all', 'g1');
    expect(await ScanGate.changedSince('all'), isFalse);
    ScanGate.readStamp = () async => 'g2';
    expect(await ScanGate.changedSince('all'), isTrue);
    ScanGate.readStamp = () async => null;
    expect(await ScanGate.changedSince('all'), isTrue, reason: 'no stamp: scan');
  });
}
