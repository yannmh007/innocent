import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/local_browser/data/library_local_datasource.dart';

/// What every row in the Videos tab is called.
///
/// WHY THIS FILE EXISTS. `_stripIdTag`'s entire design is a set of deliberate
/// near-misses: it must remove the downloader's `[ph64a3f2c1]` and must NOT
/// remove `[Official Video]`, `[HD]` or `[Remastered]`. A rule made of
/// exceptions is exactly the rule that decays when somebody widens it "just a
/// little" — and it had no tests. Both directions are pinned here, and the
/// negatives matter more than the positives.
String stripId(String s) => LibraryLocalDataSource.stripIdTagForTest(s);
String stripExt(String s) => LibraryLocalDataSource.stripExtForTest(s);

void main() {
  group('the downloader id tag is removed', () {
    // Written by the output template `%(title).80B [%(id)s].%(ext)s`. See
    // docs/filename_audit.md.
    const List<List<String>> cases = <List<String>>[
      <String>['Sunset Drive [dQw4w9WgXcQ]', 'Sunset Drive'],
      <String>['Clip [ph64a3f2c1]', 'Clip'],
      <String>['A [xy77zz11aa]', 'A'],
      <String>['မြန်မာ သီချင်း [ab12cd34]', 'မြန်မာ သီချင်း'],
      <String>['With-Dashes [a1b2-c3d4_e5]', 'With-Dashes'],
    ];
    for (final List<String> c in cases) {
      test('"${c[0]}" -> "${c[1]}"', () => expect(stripId(c[0]), c[1]));
    }
  });

  group('an ordinary bracket in a title is left alone', () {
    // THE POINT OF THE DIGIT REQUIREMENT. These are the titles the sites this
    // app targets actually use, and stripping them would silently rewrite the
    // user's library.
    const List<String> keep = <String>[
      'Song Name [Official Video]',
      'Movie [HD]',
      'Album [Remastered]',
      'Track [Live]',
      'Thing [Bonus]',
      'Show [Subbed]',
    ];
    for (final String s in keep) {
      test('"$s" is unchanged', () => expect(stripId(s), s));
    }
  });

  group('the shape of the tag is what qualifies it', () {
    test('too short is not a tag', () {
      // Under six characters. `[HD1]` is a label, not an id.
      expect(stripId('Clip [HD1]'), 'Clip [HD1]');
    });

    test('too long is not a tag', () {
      final String long = 'a1' * 13; // 26 chars, past the 24 cap
      expect(stripId('Clip [$long]'), 'Clip [$long]');
    });

    test('no digit is not a tag', () {
      expect(stripId('Clip [abcdefgh]'), 'Clip [abcdefgh]');
    });

    test('a space inside is not a tag', () {
      expect(stripId('Clip [ab 12cd]'), 'Clip [ab 12cd]');
    });

    test('not at the very end is not a tag', () {
      expect(stripId('Clip [ab12cd34] part 2'), 'Clip [ab12cd34] part 2');
    });

    test('no space before the bracket is not a tag', () {
      // The template writes "title [id]", with a space. Without one this is
      // part of the name.
      expect(stripId('Clip[ab12cd34]'), 'Clip[ab12cd34]');
    });

    test('only the last tag is considered', () {
      expect(stripId('Clip [Official] [ab12cd34]'), 'Clip [Official]');
    });
  });

  group('the extension', () {
    test('a normal one goes', () => expect(stripExt('Clip.mp4'), 'Clip'));

    test('a long trailing word is not an extension', () {
      // Over five characters, so it is part of the name.
      expect(stripExt('Clip.something'), 'Clip.something');
    });

    test('a non-alphanumeric tail is not an extension', () {
      expect(stripExt('Clip.a-b'), 'Clip.a-b');
    });

    test('a leading dot is not an extension', () {
      // A hidden file's name IS the dotted part; stripping it would leave an
      // empty title. docs/filename_audit.md F6 is about how such files get
      // created in the first place.
      expect(stripExt('.hidden'), '.hidden');
    });

    test('only the last dot counts', () {
      expect(stripExt('Clip.2026.final.mp4'), 'Clip.2026.final');
    });
  });

  test('the two compose the way the datasource uses them', () {
    // Exactly the call the Videos tab makes: strip the extension, then the id.
    expect(stripId(stripExt('မြန်မာ့ရိုးရာ ချက်ပြ [ph64a3f2c1].mp4')),
        'မြန်မာ့ရိုးရာ ချက်ပြ');
  });
}
