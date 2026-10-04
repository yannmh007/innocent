import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/cache/library_cache.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart'
    show isAppPrivateMedia;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePaths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

Video _v(int i, String folder) => Video(
      id: '$i',
      uri: 'file:///storage/emulated/0/$folder/v$i.mp4',
      title: 'v$i.mp4',
      folderPath: '/storage/emulated/0/$folder',
      duration: Duration(seconds: i),
      sizeBytes: i * 1000,
      width: 1280,
      height: 720,
      dateAdded: DateTime.fromMillisecondsSinceEpoch(1700000000000 + i),
    );

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('libcache');
    PathProviderPlatform.instance = _FakePaths(temp.path);
    SharedPreferences.setMockInitialValues(<String, Object>{
      // A cache written by an older build: a 2000-video copy in preferences.
      'lib_cache_all_videos_v1': '[]',
      'lib_cache_folder_v1:/x': '[]',
    });
  });

  tearDown(() => temp.delete(recursive: true));

  // The loop on the owner's phone (report HKUND9RY): the cache kept the first
  // 2000 videos, a library of more could never match it, and every refresh
  // found a "change" and scanned again — forever.
  test('more than 2000 videos come back whole', () async {
    final cache = LibraryCache();
    final all = [for (var i = 0; i < 2600; i++) _v(i, 'DCIM/Camera')];
    await cache.saveFolders(const []); // stamps the cache as fresh
    await cache.saveAllVideos(all);
    final back = await cache.loadAllVideos();
    expect(back, isNotNull);
    expect(back!.length, 2600);
    expect(back.last.uri, all.last.uri);
    expect(back.last.duration, all.last.duration);
  });

  test('a folder with more than 2000 videos comes back whole', () async {
    final cache = LibraryCache();
    final vids = [for (var i = 0; i < 2100; i++) _v(i, 'Movies')];
    await cache.saveVideosInFolder('/storage/emulated/0/Movies', vids);
    final back =
        await cache.loadVideosInFolder('/storage/emulated/0/Movies');
    expect(back!.length, 2100);
    expect(await cache.loadVideosInFolder('/elsewhere'), isNull);
  });

  test('the old preferences copies are dropped, and clear empties the files',
      () async {
    final cache = LibraryCache();
    await cache.saveFolders(const []);
    await cache.saveAllVideos([_v(1, 'A')]);
    final sp = await SharedPreferences.getInstance();
    expect(sp.containsKey('lib_cache_all_videos_v1'), isFalse);
    expect(sp.getKeys().where((k) => k.startsWith('lib_cache_folder_v1:')),
        isEmpty);
    await cache.clear();
    expect(await cache.loadAllVideos(), isNull);
  });

  test("the app's own files never count as the phone's library", () {
    expect(isAppPrivateMedia('/data/user/0/com.innocent.media/files/offline/k.mp4'), isTrue);
    expect(isAppPrivateMedia('file:///storage/emulated/0/Android/data/com.innocent.media/files/a.mp4'), isTrue);
    expect(isAppPrivateMedia('/storage/emulated/0/DCIM/Camera/VID_1.mp4'), isFalse);
  });
}
