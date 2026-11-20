// A playback's summary reaches the server once, even when the app is left —
// or ended — right after the player closes (14 Nov 2026).
//
// THE BUG. 1.64.84 and 1.64.85 on the owner's phone: the last playback of
// each session sent no `play_summary`. The summary was queued in memory as
// the screen closed and its kept copy deleted at once; the post that should
// have carried it (the background's flush, or the 30 s timer) never got
// through, and nothing was left to send again. The first tests below use
// only what the app had before the fix (reportSummary, sendStashed, flush),
// so they run against that code too — and fail there.
//
// "A run" here is one EventSender: one app start. A run "ended" is a sender
// dropped without its buffer ever posting, as when Android ends the app.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/event_sender.dart';
import 'package:innocent/features/video_hub/data/api/playback_reporter.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The server as far as these tests need one: it takes a batch or refuses
/// it, and keeps the summaries it took.
class _Server {
  bool up = true;
  int posts = 0;
  final List<Map<String, dynamic>> summaries = <Map<String, dynamic>>[];

  /// Held open while set: a post on its way.
  Completer<void>? hold;

  ApiClient client() => ApiClient(
        httpClient: MockClient((http.Request r) async {
          posts++;
          final h = hold;
          if (h != null) await h.future;
          if (!up) return http.Response('{"message":"down"}', 503);
          final batch =
              ((jsonDecode(r.body) as Map<String, dynamic>)['batch'] as List)
                  .cast<Map<String, dynamic>>();
          summaries.addAll(batch.where((e) => e['kind'] == Ev.playSummary));
          return http.Response('${batch.length}', 200);
        }),
      );

  /// How many rows the server holds for one title.
  int rowsFor(String titleId) =>
      summaries.where((e) => e['title_id'] == titleId).length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  /// Lets the platform-channel turns behind SharedPreferences and the install
  /// id run (see event_sender_test.dart's `until`).
  Future<void> turns([int n = 200]) async {
    for (var i = 0; i < n; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// One playback that ends with its summary queued, as the player screen's
  /// deactivate does it.
  PlaybackReporter played(EventSender s, String titleId) {
    final r = PlaybackReporter(s, titleId: titleId)
      ..report(const Duration(seconds: 120), const Duration(seconds: 600));
    r.reportSummary(<String, dynamic>{'played_s': 118, 'stalls': 0});
    r.finish(
        position: const Duration(seconds: 120),
        duration: const Duration(seconds: 600));
    return r;
  }

  /// The next start: the app's own order (eventSenderProvider) — a sender,
  /// then what an earlier run kept — and the first flush.
  Future<EventSender> start(_Server server) async {
    final s = EventSender(server.client());
    addTearDown(s.dispose);
    await PlaybackReporter.sendStashed(s);
    await turns();
    await s.flush();
    await turns();
    return s;
  }

  group('works on the old code too, and failed there', () {
    test('the app ended before any post: sent at the next start, once',
        () async {
      final server = _Server();
      final run1 = EventSender(server.client());
      addTearDown(run1.dispose);
      played(run1, 'ended');
      await turns();
      // Run 1 ends here: nothing it queued was ever posted.
      expect(server.posts, 0);

      await start(server);
      expect(server.rowsFor('ended'), 1,
          reason: 'the copy on the phone goes out at the next start');

      await start(server);
      await start(server);
      expect(server.rowsFor('ended'), 1, reason: 'and only once');
    });

    test('the post that carried it failed: sent at the next start, once',
        () async {
      final server = _Server()..up = false;
      final run1 = EventSender(server.client());
      addTearDown(run1.dispose);
      played(run1, 'failed');
      // The background's flush, and the ones after it in the same run.
      for (var i = 0; i < 4; i++) {
        await run1.flush();
        await turns();
      }
      expect(server.rowsFor('failed'), 0);

      server.up = true;
      await start(server);
      expect(server.rowsFor('failed'), 1);
      await start(server);
      expect(server.rowsFor('failed'), 1, reason: 'and only once');
    });

    test('a flush that meets a post on its way does not leave the rest',
        () async {
      // The background's flush often meets the timer's post: it used to
      // return at once, and what came after waited for a 30 s timer that a
      // frozen app never runs.
      final server = _Server()..hold = Completer<void>();
      final s = EventSender(server.client());
      addTearDown(s.dispose);
      s.log(Ev.detailView, titleId: 'a');
      unawaited(s.flush()); // the timer's post, held on its way
      await turns(20);
      s.log(Ev.cardClick, titleId: 'b');
      final background = s.flush();
      server.hold!.complete();
      server.hold = null;
      await background;
      await turns(20);
      expect(server.posts, 2, reason: 'the rest went at once, not later');
      expect(s.pending, 0);
    });
  });

  group('the copy on the phone', () {
    test('is there before the send, and goes when the send is taken', () async {
      final server = _Server();
      final s = EventSender(server.client());
      addTearDown(s.dispose);
      final r = played(s, 'kept');
      await turns();
      final sp = await SharedPreferences.getInstance();
      final kept = jsonDecode(sp.getString('play_summary_outbox')!) as List;
      expect(kept, hasLength(1));
      expect((kept.single as Map)['meta']['summary_id'], r.summaryId);

      expect(await s.flush(), isTrue);
      await turns();
      expect(sp.getString('play_summary_outbox'), isNull);
      expect(server.summaries.single['meta']['summary_id'], r.summaryId);
    });

    test('a failed send is tried again in the same run, then kept', () async {
      final server = _Server()..up = false;
      final s = EventSender(server.client());
      addTearDown(s.dispose);
      final r = played(s, 'retry');
      await turns();
      expect(await s.flush(), isFalse);
      await turns();
      expect(s.pending, 1, reason: 'queued again for the next flush');

      server.up = true;
      expect(await s.flush(), isTrue);
      await turns();
      expect(server.rowsFor('retry'), 1);
      expect(server.summaries.single['meta']['summary_id'], r.summaryId);
      expect(server.summaries.single['meta'].containsKey('stashed'), isFalse,
          reason: 'sent in its own run');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('play_summary_outbox'), isNull);

      // A dead line: three posts in the run, then it waits for a start.
      server.up = false;
      played(s, 'dead');
      await turns();
      for (var i = 0; i < 5; i++) {
        await s.flush();
        await turns();
      }
      expect(s.pending, 0, reason: 'no retry queue that never drains');
      expect(sp.getString('play_summary_outbox'), contains('dead'));
    });

    test('sent at a later start: stashed, the same id, its own time and run',
        () async {
      final server = _Server();
      final run1 = EventSender(server.client());
      addTearDown(run1.dispose);
      final r = played(run1, 'later');
      await turns();

      final run2 = await start(server);
      final row = server.summaries.single;
      expect(row['meta']['summary_id'], r.summaryId);
      expect(row['meta']['stashed'], 1);
      expect(row['meta']['played_s'], 118);
      expect(row['session_id'], run1.sessionId);
      expect(row['session_id'], isNot(run2.sessionId));
      expect(row['position_s'], 120);
    });

    test('the background keeps it as it stands; the close replaces it',
        () async {
      final server = _Server()..up = false;
      final s = EventSender(server.client());
      addTearDown(s.dispose);
      final r = PlaybackReporter(s, titleId: 'bg')
        ..report(const Duration(seconds: 60), const Duration(seconds: 600));
      await r.stashSummary(<String, dynamic>{'played_s': 50});
      expect(s.pending, 1, reason: 'kept, not sent: only the progress row');
      r.reportSummary(<String, dynamic>{'played_s': 90});
      r.finish();
      await turns();
      final sp = await SharedPreferences.getInstance();
      final kept = jsonDecode(sp.getString('play_summary_outbox')!) as List;
      expect(kept, hasLength(1), reason: 'one playback, one copy');
      expect((kept.single as Map)['meta']['played_s'], 90);
      // A background after the summary keeps nothing more.
      await r.stashSummary(<String, dynamic>{'played_s': 99});
      expect(jsonDecode(sp.getString('play_summary_outbox')!) as List,
          hasLength(1));
    });

    test('an earlier run is sent once per start, this run never', () async {
      final server = _Server()..up = false;
      final run1 = EventSender(server.client());
      addTearDown(run1.dispose);
      played(run1, 'once');
      await turns();
      final run2 = EventSender(server.client());
      addTearDown(run2.dispose);
      // This run's own playback, kept before the start's read is done.
      await PlaybackReporter(run2, titleId: 'mine')
          .stashSummary(<String, dynamic>{'played_s': 5});
      await PlaybackReporter.sendStashed(run2);
      await PlaybackReporter.sendStashed(run2);
      await turns();
      expect(run2.pending, 1,
          reason: "the earlier run's, once; not this run's own");
    });

    test("an older version's kept summary is adopted with a stable id",
        () async {
      final made = DateTime.now().toUtc().toIso8601String();
      SharedPreferences.setMockInitialValues(<String, Object>{
        'play_summary_kept': jsonEncode(<String, dynamic>{
          'kind': Ev.playSummary,
          'at': made,
          'session_id': 'old-run',
          'title_id': 'legacy',
          'meta': <String, dynamic>{'played_s': 30, 'stashed': 1},
        }),
      });
      final server = _Server()..up = false;
      // Two starts that fail, then one that is taken: one id throughout.
      for (var i = 0; i < 2; i++) {
        final s = EventSender(server.client());
        addTearDown(s.dispose);
        await PlaybackReporter.sendStashed(s);
        await turns();
        for (var j = 0; j < 4; j++) {
          await s.flush();
          await turns();
        }
      }
      server.up = true;
      await start(server);
      await start(server);
      expect(server.rowsFor('legacy'), 1);
      expect(server.summaries.single['meta']['summary_id'], hasLength(16));
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('play_summary_kept'), isNull);
      expect(sp.getString('play_summary_outbox'), isNull);
    });

    test('older than a week: dropped, not sent at the wrong time', () async {
      final old = DateTime.now().toUtc().subtract(const Duration(days: 8));
      SharedPreferences.setMockInitialValues(<String, Object>{
        'play_summary_outbox': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'kind': Ev.playSummary,
            'at': old.toIso8601String(),
            'session_id': 'old-run',
            'title_id': 'stale',
            'meta': <String, dynamic>{'summary_id': '0123456789abcdef'},
          },
        ]),
      });
      final server = _Server();
      await start(server);
      expect(server.rowsFor('stale'), 0);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('play_summary_outbox'), isNull);
    });

    test('at most eight kept: the oldest go first', () async {
      final server = _Server()..up = false;
      final s = EventSender(server.client());
      addTearDown(s.dispose);
      for (var i = 0; i < 11; i++) {
        played(s, 'film$i');
      }
      await turns();
      final sp = await SharedPreferences.getInstance();
      final kept = (jsonDecode(sp.getString('play_summary_outbox')!) as List)
          .map((e) => (e as Map)['title_id'])
          .toList();
      expect(kept, <String>[for (var i = 3; i < 11; i++) 'film$i']);
    });
  });
}
