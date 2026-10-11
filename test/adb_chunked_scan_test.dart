import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';

/// The Android/data scan goes a handful of app directories at a time, so a
/// wireless-debugging connection that drops a single long `find` (observed on
/// a Samsung SM-S918B, Android 16: `Stream closed.` ~1.7 s in) still returns
/// the media it could reach. These tests drive [scanAndroidDataChunked] with a
/// fake shell.
void main() {
  const exts = ['mp4', 'mkv'];

  bool isDirListing(String cmd) =>
      cmd.contains('-maxdepth 1 -mindepth 1 -type d');
  bool isStatFind(String cmd) => cmd.contains('-exec stat -c');

  test('lists app dirs, then scans them a chunk at a time', () async {
    final dirs = [
      for (var i = 0; i < 5; i++) '/storage/emulated/0/Android/data/app$i',
    ];
    final seen = <String>[];
    final lines = await AdbService.scanAndroidDataChunked(
      chunk: 2,
      exts: exts,
      shell: (cmd) async {
        seen.add(cmd);
        if (isDirListing(cmd)) return dirs.join('\n');
        if (isStatFind(cmd)) {
          // One file per directory named in this chunk.
          final found = <String>[];
          for (final d in dirs) {
            if (cmd.contains("'$d'")) found.add('10|$d/v.mp4');
          }
          return found.join('\n');
        }
        return '';
      },
    );

    expect(lines, hasLength(5), reason: 'one file from each of 5 dirs');
    // 1 dir-listing + ceil(5/2)=3 stat chunks.
    expect(seen.where(isDirListing), hasLength(1));
    expect(seen.where(isStatFind), hasLength(3));
    // Directories are single-quoted in the command.
    expect(seen.firstWhere(isStatFind), contains("'${dirs.first}'"));
  });

  test('a chunk that fails is skipped; the rest still come back', () async {
    final dirs = [
      '/storage/emulated/0/Android/data/good',
      '/storage/emulated/0/Android/obb/bad',
    ];
    final lines = await AdbService.scanAndroidDataChunked(
      chunk: 1,
      exts: exts,
      shell: (cmd) async {
        if (isDirListing(cmd)) return dirs.join('\n');
        if (isStatFind(cmd)) {
          if (cmd.contains('/bad')) {
            return 'ERROR: IOException: Stream closed.';
          }
          return '20|/storage/emulated/0/Android/data/good/a.mkv';
        }
        return '';
      },
    );
    expect(lines, ['20|/storage/emulated/0/Android/data/good/a.mkv']);
  });

  test('every chunk failing throws (connection lost mid-scan)', () async {
    final dirs = ['/storage/emulated/0/Android/data/a'];
    expect(
      () => AdbService.scanAndroidDataChunked(
        chunk: 1,
        exts: exts,
        shell: (cmd) async {
          if (isDirListing(cmd)) return dirs.join('\n');
          return 'ERROR: IOException: Stream closed.';
        },
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('no app dirs: empty result, no throw', () async {
    final lines = await AdbService.scanAndroidDataChunked(
      exts: exts,
      shell: (cmd) async => isDirListing(cmd) ? '' : '',
    );
    expect(lines, isEmpty);
  });

  test('dir listing fails: falls back to the single whole-tree find',
      () async {
    var singleFinds = 0;
    final lines = await AdbService.scanAndroidDataChunked(
      exts: exts,
      shell: (cmd) async {
        if (isDirListing(cmd)) return 'ERROR: not connected';
        if (isStatFind(cmd)) {
          singleFinds++;
          return '30|/storage/emulated/0/Android/data/x/y.mp4';
        }
        return '';
      },
    );
    expect(singleFinds, 1, reason: 'one whole-tree find, not per-chunk');
    expect(lines, ['30|/storage/emulated/0/Android/data/x/y.mp4']);
  });

  test('dir listing fails AND the fallback fails: throws', () async {
    expect(
      () => AdbService.scanAndroidDataChunked(
        exts: exts,
        shell: (cmd) async => 'ERROR: not connected',
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('older toybox without stat -c: bare-path fallback per chunk', () async {
    final dirs = ['/storage/emulated/0/Android/data/old'];
    final lines = await AdbService.scanAndroidDataChunked(
      exts: exts,
      shell: (cmd) async {
        if (isDirListing(cmd)) return dirs.join('\n');
        if (isStatFind(cmd)) {
          // stat form prints an error with no path (no '/').
          return 'stat: unrecognized option';
        }
        // plain find form → bare paths.
        return '/storage/emulated/0/Android/data/old/clip.mp4';
      },
    );
    expect(lines, ['/storage/emulated/0/Android/data/old/clip.mp4']);
  });

  test('empty ext list scans nothing', () async {
    var called = false;
    final lines = await AdbService.scanAndroidDataChunked(
      exts: const [],
      shell: (cmd) async {
        called = true;
        return '';
      },
    );
    expect(lines, isEmpty);
    expect(called, isFalse);
  });
}
