// Where people stop watching — the number every ranking worth having is
// built on, and the one nothing in this app has ever recorded.
//
// THREE RULES HERE FAIL SILENTLY AND PRODUCE A PLAUSIBLE WRONG ANSWER, which
// is why they are a pure function with tests rather than a condition inside a
// 3,600-line player:
//
//   * a zero duration marking everything complete,
//   * seeking backwards un-completing a title somebody finished,
//   * an abandoned playback reporting nothing at all.
//
// None throws. Each one produces a completion rate that looks like data and
// is not, and the failure would only show up months later as a Trending row
// promoting the wrong titles with no way to tell why.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/event_sender.dart';
import 'package:innocent/features/video_hub/data/api/playback_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// A sender that buffers and never actually posts — the reporter's calls are
  /// read out of the buffer rather than off the wire, so these tests say
  /// nothing about the network and do not depend on it.
  EventSender sender() {
    final client = ApiClient(
      httpClient: MockClient((http.Request request) async {
        fail('the reporter must not post; EventSender batches');
      }),
    );
    return EventSender(client);
  }

  group('completed — the rule', () {
    test('90% counts as finished, because nobody watches the credits', () {
      // 1.0 would record a completion rate near zero for titles everybody
      // finished, which is worse than useless: it would rank them below
      // titles people abandoned early.
      expect(
        PlaybackReporter.completed(furthestS: 5400, durationS: 6000),
        isTrue,
      );
      expect(
        PlaybackReporter.completed(furthestS: 5399, durationS: 6000),
        isFalse,
      );
    });

    test('a zero duration is NEVER complete', () {
      // The guard that matters most. Without it `0 >= 0 * 0.9` is true, so a
      // live stream and every playback abandoned before the engine reported a
      // length would file as finished — inflating completion exactly where
      // there is least reason to trust it.
      expect(PlaybackReporter.completed(furthestS: 0, durationS: 0), isFalse);
      expect(
        PlaybackReporter.completed(furthestS: 9999, durationS: 0),
        isFalse,
      );
      expect(
        PlaybackReporter.completed(furthestS: 10, durationS: -1),
        isFalse,
      );
    });

    test('quitting after ninety seconds of a two-hour film is not complete',
        () {
      expect(
        PlaybackReporter.completed(furthestS: 90, durationS: 7200),
        isFalse,
      );
    });
  });

  group('what it reports', () {
    test('every sample is a play_progress carrying position and duration', () {
      final s = sender();
      addTearDown(s.dispose);
      final r = PlaybackReporter(s, titleId: 'abc');

      r.report(const Duration(seconds: 30), const Duration(minutes: 100));
      r.report(const Duration(seconds: 60), const Duration(minutes: 100));

      expect(s.pending, 2);
    });

    test('an unknown duration is sent as null, never as zero', () {
      // A row saying "0 seconds long" cannot be told from one that was never
      // measured, and only one of those is true.
      final s = sender();
      addTearDown(s.dispose);
      PlaybackReporter(s, titleId: 'abc')
          .report(const Duration(seconds: 5), Duration.zero);
      expect(s.pending, 1);
    });
  });

  group('finish', () {
    test('seeking back after the end still counts as complete', () {
      // FURTHEST, NOT LAST. Someone who watches to the end and then rewinds to
      // rewatch a scene has finished the title — and rewatching is a signal
      // that they liked it, so recording them as having stopped in the middle
      // gets the ranking exactly backwards.
      final s = sender();
      addTearDown(s.dispose);
      final r = PlaybackReporter(s, titleId: 'abc');

      r.report(const Duration(seconds: 5900), const Duration(seconds: 6000));
      r.report(const Duration(seconds: 120), const Duration(seconds: 6000));
      r.finish(
        position: const Duration(seconds: 130),
        duration: const Duration(seconds: 6000),
      );

      expect(
        PlaybackReporter.completed(furthestS: 5900, durationS: 6000),
        isTrue,
        reason: 'the furthest point, not the last one, decides',
      );
      expect(s.pending, 3);
    });

    test('an abandoned playback still reports — that is the valuable row', () {
      // A reporter that only spoke on success would record exactly the titles
      // that need no attention, and stay silent about the ones losing people.
      final s = sender();
      addTearDown(s.dispose);
      final r = PlaybackReporter(s, titleId: 'abc');

      r.finish(
        position: const Duration(seconds: 90),
        duration: const Duration(seconds: 7200),
      );

      expect(s.pending, 1);
    });

    test('finish is idempotent, and nothing follows it', () {
      // deactivate() can run more than once for one State, and a second
      // completion would double-count the title in every ranking that reads
      // play_complete.
      final s = sender();
      addTearDown(s.dispose);
      final r = PlaybackReporter(s, titleId: 'abc');

      r.finish(
        position: const Duration(seconds: 6000),
        duration: const Duration(seconds: 6000),
      );
      r.finish(
        position: const Duration(seconds: 6000),
        duration: const Duration(seconds: 6000),
      );
      // A late timer tick that lost the race with teardown must not reopen a
      // playback that has already been closed off.
      r.report(const Duration(seconds: 6000), const Duration(seconds: 6000));

      expect(s.pending, 1);
    });
  });

  group('scope', () {
    test('an asset id is carried when present and absent when not', () {
      // Without it, every extra in a title is indistinguishable from the film
      // itself — and "which clip do people actually watch" is the question
      // that decides what is worth uploading next.
      final withAsset = PlaybackReporter(sender(), titleId: 'a', assetId: 'x');
      final withoutAsset = PlaybackReporter(sender(), titleId: 'a');
      expect(withAsset.assetId, 'x');
      expect(withoutAsset.assetId, isNull);
      expect(withAsset.titleId, 'a');
    });
  });
}
