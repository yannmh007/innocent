import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/api_content_repository.dart';
import 'package:innocent/features/video_hub/data/device_identity.dart';
import 'package:innocent/features/video_hub/data/stream_door.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The grant's `trickplay` field (request-playback v44, migration 083):
/// additive — a grant without it is the grant as before; one this build
/// does not take is no pack, never a refusal.
void main() {
  const worker = 'https://innocent-stream.example.workers.dev';
  const content = VideoContent(
    id: '00000000-0000-0000-0000-000000000001',
    title: 'Sintel',
    category: ContentCategory.movies,
    source: MediaRef(provider: 'r2', locator: ''),
  );

  setUp(() {
    StreamDoor.reset();
    DeviceIdentity.debugCurrent = 'install-1';
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Map<String, Object?> pack() => <String, Object?>{
        'url': '$worker/v/pack',
        'bytes': 180000,
        'interval_ms': 4000,
        'width': 320,
        'height': 134,
        'count': 222,
        'codec': 'jpeg',
      };

  Map<String, Object?> body({Object? trickplay, bool withField = true, bool ladder = true}) =>
      <String, Object?>{
        'url': '$worker/v/master',
        'expires_at': '2030-01-01T00:00:00Z',
        if (ladder)
          'renditions': <Map<String, Object?>>[
            <String, Object?>{'height': 240, 'kbps': 300, 'url': '$worker/v/r240'},
            <String, Object?>{'height': 720, 'kbps': 1500, 'url': '$worker/v/r720'},
          ],
        if (withField) 'trickplay': trickplay,
      };

  Future<PlaybackGrant> grantFor(Map<String, Object?> answer) {
    final repo = ApiContentRepository(ApiClient(
      httpClient: MockClient((req) async => http.Response(jsonEncode(answer), 200)),
    ));
    return repo.requestPlayback(content: content, source: content.source, deviceId: 'install-1');
  }

  test('a grant with the field: the pack, and its address learned for the install header', () async {
    final g = await grantFor(body(trickplay: pack()));
    expect(g.isGranted, isTrue);
    expect(g.renditions, hasLength(2));
    expect(g.trickplay, isNotNull);
    expect(g.trickplay!.count, 222);
    expect(g.trickplay!.intervalMs, 4000);
    expect(g.trickplay!.height, 134);
    expect(StreamDoor.headersFor('$worker/v/pack'), <String, String>{'X-Innocent-Device': 'install-1'});
  });

  test('an old grant (no field) is the grant as before: no pack', () async {
    final g = await grantFor(body(withField: false));
    expect(g.isGranted, isTrue);
    expect(g.renditions, hasLength(2));
    expect(g.trickplay, isNull);
  });

  test('a field this build does not take: granted, no pack', () async {
    for (final bad in <Object?>[
      null,
      'x',
      pack()..['codec'] = 'webp',
      pack()..['count'] = 0,
      pack()..['interval_ms'] = -4000,
      pack()..['bytes'] = 0,
      pack()..remove('url'),
    ]) {
      final g = await grantFor(body(trickplay: bad));
      expect(g.isGranted, isTrue, reason: '$bad');
      expect(g.renditions, hasLength(2));
      expect(g.trickplay, isNull, reason: '$bad');
    }
  });

  test('no ladder: no pack (it is made from the smallest rung)', () async {
    final g = await grantFor(body(trickplay: pack(), ladder: false));
    expect(g.isGranted, isTrue);
    expect(g.trickplay, isNull);
  });
}
