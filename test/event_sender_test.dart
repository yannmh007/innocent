// Tests for the event log's client half.
//
// This file is worth more than it looks, because [EventSender] is the one
// class in the app whose failures are SILENT BY DESIGN. It swallows every
// network error, returns void from everything, and nothing on screen changes
// whether it works perfectly or not at all. A bug in it would not produce a
// crash, a toast, or a wrong number — it would produce an empty table that
// nobody looks at for three months, by which point the data it should have
// collected does not exist and cannot be recreated.
//
// So the properties pinned here are the ones no screen can demonstrate:
// that events are buffered rather than posted one at a time, that they go to
// the right RPC in the right shape, that a dead network costs a batch and not
// the app, and that an offline device cannot grow the buffer forever.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/event_sender.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // DeviceIdentity falls back to SharedPreferences when the keystore plugin
    // is absent, which it is in a test binary. Without this the install id
    // lookup behind every request has nowhere to write.
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  /// A client that records every request body it is given.
  (ApiClient, List<Map<String, dynamic>>) recording({int status = 200}) {
    final seen = <Map<String, dynamic>>[];
    final client = ApiClient(
      httpClient: MockClient((http.Request request) async {
        seen.add(<String, dynamic>{
          'path': request.url.path,
          'body': jsonDecode(request.body),
        });
        return http.Response(status == 200 ? '3' : '{"message":"nope"}', status);
      }),
    );
    return (client, seen);
  }

  group('buffering', () {
    test('logging alone sends nothing', () async {
      final (client, seen) = recording();
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      sender.log(Ev.detailView, titleId: 'a');
      sender.log(Ev.cardClick, titleId: 'b');

      // No await on log(), and none should be needed: a tap must not wait for
      // a network request, so nothing can have been sent yet.
      expect(seen, isEmpty);
      expect(sender.pending, 2);
    });

    test('a full buffer flushes itself without waiting for the timer',
        () async {
      final (client, seen) = recording();
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      for (var i = 0; i < EventSender.flushAt; i++) {
        sender.log(Ev.impression, titleId: 't$i');
      }
      // The flush is started synchronously inside log() but completes on the
      // microtask queue, so the test has to let it run.
      await Future<void>.delayed(Duration.zero);

      expect(seen, hasLength(1),
          reason: 'a heavy session should not sit on 30 seconds of data');
      expect(sender.pending, 0);
    });

    test('a stalled request cannot grow the buffer without bound', () async {
      // THE CASE THAT ACTUALLY THREATENS THE CAP, and it is not "offline".
      // A failed flush empties the buffer on its way out, so failures cannot
      // accumulate. What accumulates is a flush that has STARTED and not
      // finished: `_sending` is true, every later flush returns early, and the
      // user keeps scrolling. That is a mobile connection that accepted the
      // request and went quiet — the normal Myanmar failure, which is a hang
      // rather than a refusal.
      final gate = Completer<http.Response>();
      final client = ApiClient(
        httpClient: MockClient((http.Request request) => gate.future),
      );
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      // Enough to start one flush and then overflow the buffer behind it.
      for (var i = 0; i < EventSender.flushAt + EventSender.maxBuffered + 50; i++) {
        sender.log(Ev.impression, titleId: 't$i');
      }
      await Future<void>.delayed(Duration.zero);

      expect(sender.pending, EventSender.maxBuffered,
          reason: 'the buffer must stop at the cap, not follow the session');

      // Let the stalled request finish so no timer outlives the test.
      gate.complete(http.Response('0', 200));
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('the request', () {
    test('posts one batch to record_events with the context fields attached',
        () async {
      final (client, seen) = recording();
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      sender.log(Ev.search, meta: <String, dynamic>{'q': 'solar', 'results': 0});
      sender.log(Ev.playStart, titleId: 'abc', durationS: 600);
      await sender.flush();

      expect(seen, hasLength(1), reason: 'two events, ONE request');
      expect(seen.single['path'], '/rest/v1/rpc/record_events');

      final body = seen.single['body'] as Map<String, dynamic>;
      final batch = (body['batch'] as List).cast<Map<String, dynamic>>();
      expect(batch, hasLength(2));

      final search = batch.first;
      expect(search['kind'], Ev.search);
      expect(search['meta'], <String, dynamic>{'q': 'solar', 'results': 0});
      // Session, so a journey can be reassembled; app version, so a
      // regression can be attributed to the build that caused it.
      expect(search['session_id'], sender.sessionId);
      expect(search['app_version'], isNotEmpty);
      // The two fields a VPN cannot change, which is why they are sent at
      // all — see the note in event_sender.dart and the event_geo view.
      expect(search['locale'], isNotEmpty);
      expect(search['tz_offset_min'], isA<int>());
      // Every event carries its own timestamp rather than inheriting the
      // moment the batch happened to be posted.
      expect(DateTime.tryParse('${search['at']}'), isNotNull);

      expect(batch.last['title_id'], 'abc');
      expect(batch.last['duration_s'], 600);
    });

    test('never carries anything that could name a person', () async {
      final (client, seen) = recording();
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      sender.log(Ev.detailView, titleId: 'abc');
      await sender.flush();

      // The server attributes an event to auth.uid() or the install id and
      // ignores anything the client claims. This asserts the client does not
      // even offer it: there is no viewer_key here to be believed.
      final batch = ((seen.single['body'] as Map<String, dynamic>)['batch']
              as List)
          .cast<Map<String, dynamic>>();
      expect(batch.single.containsKey('viewer_key'), isFalse);
      expect(batch.single.containsKey('email'), isFalse);
      expect(batch.single.containsKey('phone'), isFalse);
    });
  });

  group('failure', () {
    test('a server error does not throw and does not re-queue', () async {
      final (client, seen) = recording(status: 500);
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      sender.log(Ev.appOpen);
      // Must not throw. An analytics outage is invisible; an exception
      // propagating out of here would reach whatever UI code called log().
      await sender.flush();

      expect(seen, hasLength(1));
      // Dropped, not retried. A retry queue for analytics is how one dead
      // network becomes a buffer that never drains.
      expect(sender.pending, 0);
    });

    test('flushing an empty buffer is a no-op', () async {
      final (client, seen) = recording();
      final sender = EventSender(client);
      addTearDown(sender.dispose);

      await sender.flush();
      expect(seen, isEmpty);
    });
  });
}
