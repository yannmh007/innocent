// What leaves the device, and what must not.
//
// These test the redactor directly rather than through Sentry, because the
// thing worth proving is the OUTPUT — "does this string still contain the name
// of someone's video" is answerable, "is Sentry configured correctly" is not.
//
// The negative cases matter as much as the positive ones. A redactor that eats
// stack frames produces reports nobody can act on, which is its own kind of
// failure: the feature gets switched off and then the crashes are invisible
// again.
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/crash_redaction.dart';

void main() {
  group('removes what identifies a person', () {
    test('a filename in a FileSystemException', () {
      const String real =
          "PathNotFoundException: Cannot open file, path = "
          "'/storage/emulated/0/Innocent/Private/holiday in phuket.mp4' "
          "(OS Error: No such file or directory, errno = 2)";
      final String out = redactSensitive(real);

      expect(out, isNot(contains('holiday in phuket')));
      expect(out, isNot(contains('Private')));
      expect(out, isNot(contains('Innocent/')));
      // …but the report is still worth reading.
      expect(out, contains('PathNotFoundException'));
      expect(out, contains('/storage/emulated'));
      expect(out, contains('.mp4'));
      expect(out, contains('errno = 2'));
    });

    test('a SAF document id, keeping the provider', () {
      const String real =
          'content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FMy%20Kids';
      final String out = redactSensitive(real);

      expect(out, isNot(contains('DCIM')));
      expect(out, isNot(contains('My%20Kids')));
      expect(out, contains('com.android.externalstorage.documents'));
    });

    test('a video URL, keeping the host', () {
      const String real =
          'DownloaderException(TIMEOUT): https://www.youtube.com/watch?v=SECRET123';
      final String out = redactSensitive(real);

      expect(out, isNot(contains('SECRET123')));
      expect(out, isNot(contains('watch?v=')));
      expect(out, contains('youtube.com'));
      expect(out, contains('TIMEOUT'));
    });

    test('a file:// URL', () {
      final String out =
          redactSensitive('file:///storage/emulated/0/Download/payslip.pdf');
      expect(out, isNot(contains('payslip')));
      expect(out, isNot(contains('Download')));
      expect(out, contains('.pdf'));
    });

    test('app-private storage, which names the package and the cache entry',
        () {
      final String out = redactSensitive(
          '/data/user/0/com.innocent.media/cache/thumb_4471_wedding.jpg');
      expect(out, isNot(contains('wedding')));
      expect(out, contains('/data/user'));
      expect(out, contains('.jpg'));
    });

    test('several in one string, all of them', () {
      final String out = redactSensitive(
          'copy /storage/emulated/0/A/one.mp4 -> /sdcard/B/two.mkv failed');
      expect(out, isNot(contains('one')));
      expect(out, isNot(contains('two')));
      expect(out, isNot(contains('/A/')));
      expect(out, contains('.mp4'));
      expect(out, contains('.mkv'));
    });
  });

  group('keeps what makes a report usable', () {
    test('a Dart stack frame is untouched', () {
      // THE REGRESSION THIS GUARDS. An over-eager path pattern would eat
      // these, and a stack trace is the entire reason to send a crash at all.
      const String frame = '''
#0      _PlayerScreenState._teardown (package:innocent/features/player/presentation/player_screen.dart:902:5)
#1      _rootRunUnary (dart:async/zone.dart:1407:13)
#2      MediaKitPlayerService.dispose (package:innocent/core/services/video_player/media_kit_player_service.dart:1497:7)''';
      expect(redactSensitive(frame), frame);
    });

    test('structural breadcrumbs are untouched', () {
      for (final String line in <String>[
        'AudioService.init ok',
        'player teardown done keepPlaying=true',
        'SCREEN_OFF mounted=true',
        'TEARDOWN step surface failed: Bad state: no controller',
      ]) {
        expect(redactSensitive(line), line, reason: line);
      }
    });

    test('empty and ordinary text pass straight through', () {
      expect(redactSensitive(''), '');
      expect(redactSensitive('Bad state: Stream has already been listened to.'),
          'Bad state: Stream has already been listened to.');
    });
  });

  group('edge cases that would otherwise crash the redactor', () {
    test('a root path with too few segments is left alone', () {
      expect(redactSensitive('/storage'), '/storage');
      expect(redactSensitive('/data/user'), '/data/user');
    });

    test('a dotfile is not mistaken for an extension', () {
      final String out = redactSensitive('/storage/emulated/0/x/.nomedia');
      expect(out, isNot(endsWith('.nomedia')));
      expect(out, contains('<redacted>'));
    });

    test('a trailing dot is not an extension', () {
      final String out = redactSensitive('/storage/emulated/0/x/weird.');
      expect(out, isNot(contains('weird')));
    });

    test('it is idempotent — redacting twice changes nothing further', () {
      const String real = "path = '/storage/emulated/0/Movies/a.mp4'";
      final String once = redactSensitive(real);
      expect(redactSensitive(once), once);
    });
  });
}
