import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/api_content_repository.dart';
import 'package:innocent/features/video_hub/data/api/backend_config.dart';
import 'package:innocent/features/video_hub/data/device_identity.dart';
import 'package:innocent/features/video_hub/data/stream_door.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The install id goes with every fetch of a granted URL, and nowhere else.
///
/// Since 1.64.70 the app asks for bound grants, and the stream Worker plays a
/// bound token only for a request that carries this install's id
/// (docs/security_streaming.md, phase 1). A fetch that forgot it plays while
/// the Worker only logs, and stops the day the check is enforced; an id sent
/// to a stranger's host is an id given away. Both are pinned here.
void main() {
  const worker = 'https://innocent-stream.example.workers.dev';

  setUp(() {
    StreamDoor.reset();
    DeviceIdentity.debugCurrent = 'install-1';
  });

  group('StreamDoor', () {
    test('nothing before a grant has pointed anywhere', () {
      expect(StreamDoor.headersFor('$worker/v/abc'), isEmpty);
    });

    test('a granted URL carries the install id', () {
      StreamDoor.learn('$worker/v/tok1');
      expect(StreamDoor.headersFor('$worker/v/tok1'),
          <String, String>{'X-Innocent-Device': 'install-1'});
      // Any token on the same door: the renewal's fresh URL included.
      expect(StreamDoor.headersFor('$worker/v/tok2'),
          <String, String>{'X-Innocent-Device': 'install-1'});
    });

    test('never to another host, another path, or plain http', () {
      StreamDoor.learn('$worker/v/tok1');
      expect(StreamDoor.headersFor('https://pub.example.r2.dev/v/tok1'), isEmpty);
      expect(StreamDoor.headersFor('$worker/health'), isEmpty);
      expect(StreamDoor.headersFor('$worker/v/a/b'), isEmpty);
      expect(StreamDoor.headersFor('http://innocent-stream.example.workers.dev/v/x'),
          isEmpty);
      // The app's own proxy, which sends the id itself.
      expect(StreamDoor.headersFor('http://127.0.0.1:4242/c/xyz/film'), isEmpty);
    });

    test('a URL that is not a grant is never learned', () {
      StreamDoor.learn('https://evil.example/anything');
      StreamDoor.learn('http://insecure.example/v/tok');
      expect(StreamDoor.headersFor('https://evil.example/v/tok'), isEmpty);
      expect(StreamDoor.headersFor('http://insecure.example/v/tok'), isEmpty);
    });

    test('no id read yet: no header, rather than an empty one', () {
      StreamDoor.learn('$worker/v/tok1');
      DeviceIdentity.debugCurrent = null;
      expect(StreamDoor.headersFor('$worker/v/tok1'), isEmpty);
    });
  });

  group('requestPlayback', () {
    setUp(() {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    const content = VideoContent(
      id: '00000000-0000-0000-0000-000000000001',
      title: 'Sintel',
      category: ContentCategory.movies,
      source: MediaRef(provider: 'r2', locator: ''),
    );

    ApiContentRepository repo(http.Response Function(http.Request) answer,
            {List<Map<String, dynamic>>? sent}) =>
        ApiContentRepository(ApiClient(
          httpClient: MockClient((req) async {
            if (req.url.path.endsWith('/request-playback')) {
              sent?.add(jsonDecode(req.body) as Map<String, dynamic>);
            }
            return answer(req);
          }),
        ));

    test('asks for a bound grant and learns where it points', () async {
      final sent = <Map<String, dynamic>>[];
      final r = repo(
          (_) => http.Response(
              jsonEncode(<String, dynamic>{
                'url': '$worker/v/master',
                'expires_at': '2030-01-01T00:00:00Z',
                'renditions': <Map<String, dynamic>>[
                  <String, dynamic>{'height': 360, 'kbps': 700, 'url': '$worker/v/r360'},
                ],
              }),
              200),
          sent: sent);
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.isGranted, isTrue);
      expect(sent.single['device_id'], 'install-1');
      expect(sent.single['bind'], isTrue);
      expect(StreamDoor.headersFor('$worker/v/master'), isNotEmpty);
      expect(StreamDoor.headersFor('$worker/v/r360'), isNotEmpty);
    });

    test('no install id: not asked to bind', () async {
      final sent = <Map<String, dynamic>>[];
      final r = repo(
          (_) => http.Response(jsonEncode(<String, dynamic>{'url': '$worker/v/m'}), 200),
          sent: sent);
      await r.requestPlayback(content: content, source: content.source);
      expect(sent.single.containsKey('bind'), isFalse);
    });

    test('the budget ran out: rateLimited, not unavailable', () async {
      final r = repo((_) => http.Response(
          jsonEncode(<String, dynamic>{'code': 'rate_limited', 'retry_after': 1200}), 429));
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.denial, AccessDenial.rateLimited);
    });

    test('asked to run beside the database', () async {
      final regions = <String?>[];
      final r = ApiContentRepository(ApiClient(
        httpClient: MockClient((req) async {
          regions.add(req.headers['x-region']);
          return http.Response(jsonEncode(<String, dynamic>{'url': '$worker/v/m'}), 200);
        }),
      ));
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.isGranted, isTrue);
      expect(regions, <String?>[BackendConfig.functionRegion]);
    });

    test('that region down at the gateway: asked once more, unpinned', () async {
      final regions = <String?>[];
      final r = ApiContentRepository(ApiClient(
        httpClient: MockClient((req) async {
          regions.add(req.headers['x-region']);
          if (req.headers['x-region'] != null) {
            return http.Response('{"message":"region unavailable"}', 502);
          }
          return http.Response(jsonEncode(<String, dynamic>{'url': '$worker/v/m'}), 200);
        }),
      ));
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.isGranted, isTrue);
      expect(regions, <String?>[BackendConfig.functionRegion, null]);
    });

    test('the function\'s own 503 is not asked again', () async {
      var asked = 0;
      final r = ApiContentRepository(ApiClient(
        httpClient: MockClient((req) async {
          asked++;
          return http.Response(jsonEncode(<String, dynamic>{'code': 'unavailable'}), 503);
        }),
      ));
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.isGranted, isFalse);
      expect(asked, 1);
    });

    test('a 429 that is not the budget is still "could not ask"', () async {
      final r = repo((_) => http.Response('{}', 429));
      final grant = await r.requestPlayback(
          content: content, source: content.source, deviceId: 'install-1');
      expect(grant.denial, AccessDenial.offline);
    });
  });
}
