import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/updater/data/update_download_service.dart';

/// After an update has gone through, its APK (~90 MB) must not stay in the
/// app's storage until the next release.
void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('updates'));
  tearDown(() async => dir.delete(recursive: true));

  Future<void> touch(String name) => File('${dir.path}/$name').writeAsString('x');
  List<String> left() =>
      dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('the installed build and older ones go; a newer download stays', () async {
    await touch('innocent-356.apk');
    await touch('innocent-357.apk.part');
    await touch('innocent-358.apk'); // the build now running
    await touch('innocent-359.apk.part'); // a newer download, resumable
    await touch('notes.txt'); // not ours
    final removed =
        await UpdateDownloadService.pruneInstalled(358, dirOverride: () async => dir);
    expect(removed, 3);
    expect(left(), ['innocent-359.apk.part', 'notes.txt']);
  });

  test('a missing folder is not an error', () async {
    final gone = Directory('${dir.path}/nope');
    expect(await UpdateDownloadService.pruneInstalled(358, dirOverride: () async => gone), 0);
  });
}
