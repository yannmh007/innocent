// The regression this file exists to make impossible a second time.
//
// v1.64.21 wrote `demuxer-lavf-probesize: 0` when opening a local file,
// meaning "put it back to libavformat's default". mpv declares that option
// with a minimum of 32 and validates what you WRITE, not what it ships with,
// so libmpv logged
//
//     The demuxer-lavf-probesize option must be >= 32: 0
//
// at error level. Nothing threw. The setter returned true. media_kit
// forwarded the log line to its error stream, and the player drew "Playback
// failed" across a film that was playing perfectly — on local files, which
// have nothing to do with the network change that introduced it.
//
// Both halves of the fix are pure functions precisely so they can be tested
// here, in seconds, with no device and no libmpv.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/mpv_option_range.dart';

void main() {
  group('mpvValueProblem — what libmpv would have refused', () {
    test('the exact value that shipped is refused', () {
      // The regression, written as the assertion it should always have been.
      final problem = mpvValueProblem('demuxer-lavf-probesize', '0');
      expect(problem, isNotNull);
      expect(problem, contains('at least 32'));
    });

    test('libavformat\'s own default is accepted', () {
      // What the fix writes instead. Same behaviour, a value mpv will take.
      expect(mpvValueProblem('demuxer-lavf-probesize', '5000000'), isNull);
    });

    test('the network cap is accepted', () {
      expect(mpvValueProblem('demuxer-lavf-probesize', '786432'), isNull);
    });

    test('the minimum itself is accepted, not rejected', () {
      // An off-by-one here would refuse a legal value and silently leave the
      // option at whatever it was, which is the quietest possible failure.
      expect(mpvValueProblem('demuxer-lavf-probesize', '32'), isNull);
      expect(mpvValueProblem('demuxer-lavf-probesize', '31'), isNotNull);
    });

    test('zero IS legal for analyzeduration, and the two must not be merged',
        () {
      // The trap that produced the bug: two options sitting on adjacent
      // lines, named almost identically, with different rules about zero.
      expect(mpvValueProblem('demuxer-lavf-analyzeduration', '0'), isNull);
      expect(mpvValueProblem('demuxer-lavf-analyzeduration', '-1'), isNotNull);
    });

    test('an option with no listed range is not second-guessed', () {
      // A partial guard that says so beats a complete-looking one that
      // passes everything. `hwdec` is not numeric and must not be reported.
      expect(mpvValueProblem('hwdec', 'auto-safe'), isNull);
      expect(mpvValueProblem('cache', 'yes'), isNull);
    });

    test('a non-number for a numeric option is caught', () {
      expect(mpvValueProblem('cache-secs', 'yes'), isNotNull);
    });

    test('an upper bound is enforced where mpv has one', () {
      expect(mpvValueProblem('speed', '1.0'), isNull);
      expect(mpvValueProblem('speed', '0'), isNotNull);
      expect(mpvValueProblem('speed', '400'), isNotNull);
    });

    test('the message names the option, so a log line is actionable', () {
      expect(mpvValueProblem('cache-secs', '-5'), contains('cache-secs'));
    });
  });

  group('isMpvConfigComplaint — what the viewer must never be shown', () {
    test('the line that reached a viewer over a working film', () {
      expect(
        isMpvConfigComplaint(
            'The demuxer-lavf-probesize option must be >= 32: 0'),
        isTrue,
      );
    });

    test('other option wordings mpv uses', () {
      for (final line in <String>[
        'Error parsing option demuxer-lavf-probesize (option could not be parsed)',
        'Unknown option: demuxer-lavf-nonsense',
        'No such property: demuxer-lavf-nope',
      ]) {
        expect(isMpvConfigComplaint(line), isTrue, reason: line);
      }
    });

    test('a REAL playback failure still reaches the viewer', () {
      // The half that matters more. A filter that swallowed these would
      // leave a black screen with no explanation at all, which is the one
      // outcome worse than a wrong message.
      for (final line in <String>[
        'Failed to open file:///sdcard/Movies/a.mp4.',
        'Could not open codec.',
        'Failed to recognize file format.',
        'HTTP error 403 Forbidden',
        'Connection timed out',
      ]) {
        expect(isMpvConfigComplaint(line), isFalse, reason: line);
      }
    });
  });
}
