import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';

/// Tests for the two pure parsers every ADB scan and every Files-browser
/// listing passes through (audit_adb.md A12).
///
/// Nothing under `test/` imported anything from `lib/core/services/adb/`
/// before this file. These two functions are string → record, have documented
/// tolerance rules, and are exactly the kind of code that decays without
/// anyone noticing — a scan that silently drops half a library looks like an
/// empty folder, not like a bug.
void main() {
  group('parseAdbScanLine', () {
    test('reads the size-aware "<bytes>|<path>" shape', () {
      final r = parseAdbScanLine('1048576|/storage/emulated/0/Android/a.mp4');
      expect(r.path, '/storage/emulated/0/Android/a.mp4');
      expect(r.sizeBytes, 1048576);
    });

    test('accepts a bare path from the older-device fallback', () {
      final r = parseAdbScanLine('/storage/emulated/0/Android/b.mkv');
      expect(r.path, '/storage/emulated/0/Android/b.mkv');
      expect(r.sizeBytes, 0);
    });

    test('keeps the video when the size is not a number', () {
      // The documented tolerance: degrade to "path, size 0" rather than drop
      // the file. A user losing a video to a stat quirk is the worse failure.
      final r = parseAdbScanLine('n/a|/x/c.mp4');
      expect(r.path, 'n/a|/x/c.mp4');
      expect(r.sizeBytes, 0);
    });

    test('a path containing a bar survives', () {
      final r = parseAdbScanLine('12|/x/we | are.mp4');
      expect(r.path, '/x/we | are.mp4');
      expect(r.sizeBytes, 12);
    });

    test('a zero size is a size, not a missing one', () {
      final r = parseAdbScanLine('0|/x/d.mp4');
      expect(r.path, '/x/d.mp4');
      expect(r.sizeBytes, 0);
    });

    test('trims surrounding whitespace', () {
      final r = parseAdbScanLine('  7|/x/e.mp4  ');
      expect(r.path, '/x/e.mp4');
      expect(r.sizeBytes, 7);
    });

    test('a leading bar is not a separator', () {
      // bar > 0 is required, so "|/x/f.mp4" has no size field at all.
      final r = parseAdbScanLine('|/x/f.mp4');
      expect(r.path, '|/x/f.mp4');
      expect(r.sizeBytes, 0);
    });
  });

  group('parseAdbDirLine', () {
    test('reads a regular file', () {
      final e = parseAdbDirLine('regular file|2048|/x/Android/data/a/f.mp4')!;
      expect(e.isDir, isFalse);
      expect(e.sizeBytes, 2048);
      expect(e.path, '/x/Android/data/a/f.mp4');
      expect(e.name, 'f.mp4');
    });

    test('reads a directory and reports no size for it', () {
      final e = parseAdbDirLine('directory|4096|/x/Android/data/a')!;
      expect(e.isDir, isTrue);
      expect(e.sizeBytes, 0);
      expect(e.name, 'a');
    });

    test('a path containing a bar keeps all of it', () {
      final e = parseAdbDirLine('regular file|9|/x/we | are.mp4')!;
      expect(e.path, '/x/we | are.mp4');
      expect(e.name, 'we | are.mp4');
      expect(e.sizeBytes, 9);
    });

    test('an unparseable size becomes zero rather than dropping the entry', () {
      final e = parseAdbDirLine('regular file|?|/x/g.mp4')!;
      expect(e.sizeBytes, 0);
      expect(e.path, '/x/g.mp4');
    });

    test('a trailing slash does not produce an empty name', () {
      final e = parseAdbDirLine('directory|4096|/x/Android/data/a/')!;
      expect(e.name, 'a');
    });

    test('rejects a line with fewer than two bars', () {
      expect(parseAdbDirLine('regular file|2048'), isNull);
      expect(parseAdbDirLine('/x/no-bars-at-all.mp4'), isNull);
    });

    test('rejects a blank line and a bar-only line', () {
      expect(parseAdbDirLine(''), isNull);
      expect(parseAdbDirLine('   '), isNull);
      expect(parseAdbDirLine('||'), isNull);
    });

    test('rejects an empty path', () {
      expect(parseAdbDirLine('regular file|10|   '), isNull);
    });

    test('a leading bar is not a type field', () {
      expect(parseAdbDirLine('|4096|/x/h.mp4'), isNull);
    });

    test('a symbolic link is a file, not a directory', () {
      final e = parseAdbDirLine('symbolic link|12|/x/link.mp4')!;
      expect(e.isDir, isFalse);
    });

    test('a negative size is clamped rather than shown', () {
      final e = parseAdbDirLine('regular file|-1|/x/i.mp4')!;
      expect(e.sizeBytes, 0);
    });
  });
}
