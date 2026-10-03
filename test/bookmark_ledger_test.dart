import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/session_store.dart';
import 'package:innocent/features/video_hub/data/bookmark_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final t0 = DateTime.utc(2026, 10, 3, 9);
DateTime at(int min) => t0.add(Duration(minutes: min));

class _Session extends SessionStore {
  @override
  Future<String?> accessToken() async => 'tok';
  @override
  Future<String?> refreshToken() async => 'r';
  @override
  Future<bool> isExpired() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('ledger', () {
    test('a save is newest first and owed to the server', () {
      final l = BookmarkLedger.empty.add('a', at(0)).add('b', at(1));
      expect(l.ids, ['b', 'a']);
      expect(l.pendingAdd, {'a', 'b'});
      expect(l.add('a', at(5)).ids, ['b', 'a'], reason: 'saving twice is a no-op');
    });

    test('removing an unsent save sends nothing; removing a synced one does', () {
      final local = BookmarkLedger.empty.add('a', at(0)).remove('a');
      expect(local.ids, isEmpty);
      expect(local.pendingRemove, isEmpty);
      final synced = BookmarkLedger.empty.mergeServer([BookmarkEntry('a', at(0))]).remove('a');
      expect(synced.pendingRemove, {'a'});
    });

    test('undo puts it back in its place, with its date', () {
      final l = BookmarkLedger.empty
          .mergeServer([BookmarkEntry('a', at(0)), BookmarkEntry('b', at(2))]);
      final entry = l.items.firstWhere((e) => e.id == 'a');
      final undone = l.remove('a').restore(entry);
      expect(undone.ids, ['b', 'a']);
      expect(undone.pendingRemove, isEmpty, reason: 'the unsent delete is just cancelled');
      expect(undone.pendingAdd, isEmpty);
    });

    test('a pull never undoes a change made offline', () {
      final offline = BookmarkLedger.empty
          .mergeServer([BookmarkEntry('a', at(0)), BookmarkEntry('b', at(1))])
          .remove('a') // removed here, server does not know yet
          .add('c', at(5)); // saved here, server does not know yet
      final merged = offline.mergeServer(
          [BookmarkEntry('a', at(0)), BookmarkEntry('b', at(1)), BookmarkEntry('d', at(3))]);
      expect(merged.ids, ['c', 'd', 'b'],
          reason: 'd came from another phone; a stays removed; c stays saved');
    });

    test('survives a round trip through storage', () async {
      final l = BookmarkLedger.empty.add('a', at(0)).ownedBy('u1');
      await const BookmarkStore().save(l);
      final back = await const BookmarkStore().load();
      expect(back.ids, ['a']);
      expect(back.pendingAdd, {'a'});
      expect(back.owner, 'u1');
      expect(BookmarkLedger.fromJson('garbage').ids, isEmpty);
    });
  });

  group('remote', () {
    test('push sends adds and removes, then the outbox is empty', () async {
      final calls = <String>[];
      final api = ApiClient(
        session: _Session(),
        httpClient: MockClient((req) async {
          calls.add('${req.method} ${req.url.path}?${req.url.query} ${req.body}');
          return http.Response('', 201);
        }),
      );
      final l = BookmarkLedger.empty
          .mergeServer([BookmarkEntry('11111111-1111-1111-1111-111111111111', at(0))])
          .remove('11111111-1111-1111-1111-111111111111')
          .add('22222222-2222-2222-2222-222222222222', at(1));
      final out = await BookmarkRemote(api).push(l);
      expect(out.hasPending, isFalse);
      expect(calls.where((c) => c.startsWith('POST')).single,
          contains('"title_id":"22222222-2222-2222-2222-222222222222"'));
      expect(calls.where((c) => c.startsWith('DELETE')).single,
          contains('title_id=eq.11111111-1111-1111-1111-111111111111'));
    });

    test('a failure keeps the rest in the outbox', () async {
      final api = ApiClient(
        session: _Session(),
        httpClient: MockClient((req) async => http.Response('down', 503)),
      );
      final l = BookmarkLedger.empty.add('x', at(0));
      final out = await BookmarkRemote(api).push(l);
      expect(out.pendingAdd, {'x'});
    });

    test('a title that no longer exists leaves the outbox instead of retrying forever', () async {
      final api = ApiClient(
        session: _Session(),
        httpClient: MockClient((req) async =>
            http.Response(jsonEncode({'code': '23503'}), 409)),
      );
      final out = await BookmarkRemote(api).push(BookmarkLedger.empty.add('gone', at(0)));
      expect(out.pendingAdd, isEmpty);
    });

    test('pull reads the server list newest first', () async {
      final api = ApiClient(
        session: _Session(),
        httpClient: MockClient((req) async => http.Response(
            jsonEncode([
              {'title_id': 'b', 'added_at': at(2).toIso8601String()},
              {'title_id': 'a', 'added_at': at(1).toIso8601String()},
            ]),
            200)),
      );
      final list = await BookmarkRemote(api).pull();
      expect(list.map((e) => e.id), ['b', 'a']);
    });
  });
}
