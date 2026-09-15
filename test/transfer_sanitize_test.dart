import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/file_transfer/file_receiver_service.dart';
import 'package:path/path.dart' as p;

/// The one place a remote peer influences a filesystem path.
///
/// WHY THIS FILE EXISTS. README records a 30,000-case fuzz that found exactly
/// one survivor — a name of precisely `..`, which contains no separator and
/// still resolves to the parent folder — and a 60,000-case re-fuzz that found
/// none. **Neither fuzz is in this repository.** Nothing has re-run them
/// since, and nothing would notice if a refactor reopened the hole. A test
/// that cannot be re-run protects nothing; this is the same idea, in CI, on
/// every push.
///
/// The property asserted is not "the output looks tidy" but the only one that
/// matters: **whatever comes out, joined under a root, stays under that root.**
void main() {
  const String root = '/storage/emulated/0/Innocent';

  /// True when [rel], sanitised and joined under [root], is still inside it.
  bool staysInside(String rel) {
    final String dir = FileReceiverService.sanitizeRelDir(rel);
    final String joined = p.normalize(p.join(root, dir));
    return joined == root || p.isWithin(root, joined);
  }

  group('the survivors the fuzz found', () {
    // Each of these is a real shape from the published research on this app
    // class, or from the project's own fuzz. They are listed rather than
    // generated so a failure names the exact input.
    final List<String> hostile = <String>[
      '../x',
      '../../x',
      '../../../../data/data/com.innocent.media/databases/x',
      '..\\..\\x',
      '/etc/passwd',
      '//etc/passwd',
      'C:\\Windows\\System32\\x',
      '\\\\server\\share\\x',
      './../x',
      '.../....//x',
      'a/../../../x',
      'a/./../../x',
      '..',
      '../',
      '.',
      './',
      'a/../b/../../x',
      '....//....//x',
      '\u0000/x',
      'a\u0000b/x',
      'a\u202e/x',
      '  ../  /x',
      '.\u200d./x',
      'a/'*40 + 'x',
      '../'*40 + 'x',
    ];

    for (final String rel in hostile) {
      test('cannot escape: ${rel.replaceAll('\u0000', r'\0')}', () {
        expect(staysInside(rel), isTrue,
            reason: 'sanitizeRelDir(${rel.codeUnits}) => '
                '"${FileReceiverService.sanitizeRelDir(rel)}"');
      });
    }
  });

  group('the exact survivor', () {
    // "A name of precisely `..` contains no separator, so it passed through
    // untouched and then resolved to the parent folder." Both call sites got
    // the same guard; this pins both.
    test('.. becomes a generated name, not a parent reference', () {
      for (final String name in <String>['..', '.', '   ', '']) {
        final String out = FileReceiverService.safeNameForTest(name);
        expect(out, isNot('..'));
        expect(out, isNot('.'));
        expect(out.trim(), isNotEmpty);
      }
    });

    test('separators and control characters never survive a name', () {
      for (final String name in <String>[
        'a/b',
        'a\\b',
        'a\u0000b',
        'a\u001fb',
        'a"b',
      ]) {
        final String out = FileReceiverService.safeNameForTest(name);
        expect(out, isNot(contains('/')));
        expect(out, isNot(contains('\\')));
        expect(out, isNot(contains('"')));
        expect(out.codeUnits.any((c) => c < 0x20), isFalse);
      }
    });
  });

  test('a 20,000-case fuzz finds no escape', () {
    // Generated rather than listed, so it explores combinations nobody wrote
    // down. Seeded, so a failure is reproducible: the seed is printed with the
    // failing input.
    const int seed = 20260913;
    final Random rnd = Random(seed);
    const List<String> atoms = <String>[
      '..', '.', '/', '\\', 'a', 'ဖ', '..\\', './', '...', '....',
      '\u0000', '\u001f', '"', ' ', '\t', 'C:', '\u202e', '%2e%2e',
    ];
    for (var i = 0; i < 20000; i++) {
      final int len = 1 + rnd.nextInt(8);
      final StringBuffer sb = StringBuffer();
      for (var j = 0; j < len; j++) {
        sb.write(atoms[rnd.nextInt(atoms.length)]);
      }
      final String rel = '${sb}file.mp4';
      expect(staysInside(rel), isTrue,
          reason: 'seed $seed, case $i: ${rel.codeUnits} => '
              '"${FileReceiverService.sanitizeRelDir(rel)}"');
    }
  });

  group('and it still does its ordinary job', () {
    // A sanitiser that refused everything would also pass every test above.
    // These are the cases that must keep WORKING, and they are what stops the
    // fix for a traversal being "return empty string".
    test('an ordinary folder tree is preserved', () {
      expect(FileReceiverService.sanitizeRelDir('Holiday/2026/file.mp4'),
          'Holiday/2026');
    });

    test('a Burmese folder name is preserved', () {
      expect(
        FileReceiverService.sanitizeRelDir('မြန်မာ/ရုပ်ရှင်/a.mp4'),
        'မြန်မာ/ရုပ်ရှင်',
      );
    });

    test('a bare filename has no directory', () {
      expect(FileReceiverService.sanitizeRelDir('a.mp4'), '');
    });

    test('depth is capped rather than the transfer being refused', () {
      final String deep = '${'d/' * 30}a.mp4';
      final String out = FileReceiverService.sanitizeRelDir(deep);
      expect(out.split('/'), hasLength(12));
    });
  });
}
