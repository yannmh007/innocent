import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/api_exception.dart';
import 'package:innocent/features/video_hub/data/api/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tokens in memory, so the test sees exactly what the client kept or threw
/// away.
class _MemSession extends SessionStore {
  _MemSession({this.access, this.refresh, this.expired = false});
  String? access;
  String? refresh;
  bool expired;
  int clears = 0;

  @override
  Future<String?> accessToken() async => access;
  @override
  Future<String?> refreshToken() async => refresh;
  @override
  Future<bool> isExpired() async => expired;
  @override
  Future<void> clear() async {
    clears++;
    access = null;
    refresh = null;
  }

  @override
  Future<void> saveFromAuthResponse(Map<String, dynamic> body) async {
    access = body['access_token'] as String?;
    refresh = (body['refresh_token'] as String?) ?? refresh;
    expired = false;
  }
}

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

/// The exact refusal Supabase Auth gave on 2026-10-03 for an expired token.
final _expired403 = _json(403, {
  'code': 403,
  'error_code': 'bad_jwt',
  'msg': 'invalid JWT: unable to parse or verify signature, token has invalid claims: token is expired',
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('an expired-token 403 refreshes and retries instead of signing out', () async {
    final s = _MemSession(access: 'old', refresh: 'r1');
    final seen = <String>[];
    final client = ApiClient(
      session: s,
      httpClient: MockClient((req) async {
        seen.add('${req.url.path} ${req.headers['Authorization'] ?? ''}');
        if (req.url.path.endsWith('/token')) {
          return _json(200, {'access_token': 'new', 'refresh_token': 'r2', 'expires_in': 3600});
        }
        return req.headers['Authorization'] == 'Bearer new'
            ? _json(200, {'id': 'u1'})
            : _expired403;
      }),
    );
    final body = await client.getJson('/auth/v1/user');
    expect(body, {'id': 'u1'});
    expect(s.access, 'new');
    expect(s.refresh, 'r2');
    expect(s.clears, 0);
    expect(seen.where((l) => l.contains('/token')).length, 1);
  });

  test('a token known to be expired is refreshed before the request goes out', () async {
    final s = _MemSession(access: 'old', refresh: 'r1', expired: true);
    final seen = <String>[];
    final client = ApiClient(
      session: s,
      httpClient: MockClient((req) async {
        seen.add(req.url.path);
        if (req.url.path.endsWith('/token')) {
          return _json(200, {'access_token': 'new', 'expires_in': 3600});
        }
        expect(req.headers['Authorization'], 'Bearer new');
        return _json(200, {'id': 'u1'});
      }),
    );
    await client.getJson('/auth/v1/user');
    expect(seen.first, endsWith('/token'));
    expect(seen.where((p) => p.endsWith('/user')).length, 1);
  });

  test('a real 403 is still a refusal, and nobody is refreshed or signed out', () async {
    final s = _MemSession(access: 'ok', refresh: 'r1');
    var refreshes = 0;
    final client = ApiClient(
      session: s,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/token')) refreshes++;
        return _json(403, {'code': 'needs_premium'});
      }),
    );
    await expectLater(
      client.getJson('/rest/v1/rpc/request_playback'),
      throwsA(isA<ApiException>()
          .having((e) => e.kind, 'kind', ApiErrorKind.needsPremium)),
    );
    expect(refreshes, 0);
    expect(s.clears, 0);
  });

  test('Auth being down does not throw the session away', () async {
    final s = _MemSession(access: 'old', refresh: 'r1');
    final client = ApiClient(
      session: s,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/token')) return http.Response('bad gateway', 502);
        return _json(401, {'msg': 'expired'});
      }),
    );
    await expectLater(client.getJson('/auth/v1/user'), throwsA(isA<ApiException>()));
    expect(s.clears, 0);
    expect(s.refresh, 'r1');
  });

  test('a refresh token Auth rejects does end the session', () async {
    final s = _MemSession(access: 'old', refresh: 'dead');
    final client = ApiClient(
      session: s,
      httpClient: MockClient((req) async {
        if (req.url.path.endsWith('/token')) {
          return _json(400, {'error_code': 'refresh_token_not_found'});
        }
        return _json(401, {'msg': 'expired'});
      }),
    );
    await expectLater(
      client.getJson('/auth/v1/user'),
      throwsA(isA<ApiException>()
          .having((e) => e.kind, 'kind', ApiErrorKind.unauthenticated)),
    );
    expect(s.clears, 1);
  });
}
