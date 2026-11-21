import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:innocent/features/video_hub/data/api/api_account_repository.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE SERVER ENDED A GOOGLE SESSION THE VIEWER DID NOT END (21 Nov 2026).
///
/// Supabase Auth deletes every session of an account below aal2 each time
/// that account completes MFA anywhere. The owner's console sign-in is
/// Google + MFA; the phone's Google session is aal1: on 14 Nov the console's
/// MFA (08:11:53 UTC) ended it, the app's refresh was refused (400, 08:16:20)
/// and the app — just updated — asked to sign in again. Now such a session is
/// renewed with Google ONCE, without a tap; anything the viewer ended stays
/// ended.

/// Tokens in memory, so the test sees exactly what was kept or thrown away.
class _MemSession extends SessionStore {
  _MemSession({this.access, this.refresh, this.expired = false, this.mfa});
  String? access;
  String? refresh;
  bool expired;
  int clears = 0;

  /// The account with a verified MFA factor, as SessionStore keeps it.
  String? mfa;

  @override
  Future<void> rememberMfaUser(String? userId) async => mfa = userId;
  @override
  Future<String?> mfaUser() async => mfa;

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

/// An access token's shape with made-up claims, built at run time (a
/// JWT-shaped literal in the source is a scanner finding, even a fake one).
String _token(List<String> providers) {
  String part(Object o) => base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return [
    part({'alg': 'none'}),
    part({
      'sub': 'u1',
      'aal': 'aal1',
      'app_metadata': {'provider': providers.first, 'providers': providers},
    }),
    'x',
  ].join('.');
}

http.Response _json(int status, Object body) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

/// What the auth server answers for a session MFA deleted elsewhere.
final _refused = _json(400, {
  'code': 400,
  'error_code': 'refresh_token_not_found',
  'msg': 'Invalid Refresh Token: Refresh Token Not Found',
});

Map<String, dynamic> _newSession(String userId) => {
      'access_token': 'renewed-access',
      'refresh_token': 'renewed-refresh',
      'expires_in': 3600,
      'user': {'id': userId, 'email': 'someone@example.com', 'user_metadata': <String, dynamic>{}},
    };

/// The auth server in miniature: refresh refused, a user call without a
/// live token refused, an ID token exchanged for [_newSession] (or
/// [exchangeStatus]).
class _Auth {
  _Auth({this.exchangeStatus = 200, this.userId = 'u1'});
  final int exchangeStatus;
  final String userId;
  final List<String> seen = <String>[];
  Map<String, dynamic>? exchanged;

  late final MockClient client = MockClient((req) async {
    final grant = req.url.queryParameters['grant_type'];
    seen.add('${req.url.path}${grant == null ? '' : ' $grant'}');
    if (req.url.path.endsWith('/token') && grant == 'refresh_token') return _refused;
    if (req.url.path.endsWith('/token') && grant == 'id_token') {
      exchanged = jsonDecode(req.body) as Map<String, dynamic>;
      return exchangeStatus == 200 ? _json(200, _newSession(userId)) : _json(exchangeStatus, {'msg': 'down'});
    }
    if (req.url.path.endsWith('/logout')) return _json(204, <String, dynamic>{});
    if (req.headers['Authorization'] == 'Bearer renewed-access') {
      return req.url.path.endsWith('/user') ? _json(200, _newSession(userId)['user']!) : _json(200, <Object>[]);
    }
    return _json(401, {'msg': 'no session'});
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SessionStore.forgetRefused();
  });

  test('the console\'s MFA ended the Google session: renewed once, without a tap — still signed in', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    final auth = _Auth();
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: auth.client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    final user = await repo.currentUser();
    expect(user?.id, 'u1');
    expect(asked, 1, reason: 'one silent sign-in');
    expect(s.access, 'renewed-access');
    expect(s.refresh, 'renewed-refresh');
    expect(auth.exchanged?['provider'], 'google');
    expect(auth.exchanged?['id_token'], 'google-id-token');
    expect(auth.seen.first, '/auth/v1/token refresh_token');
    expect(SessionStore.refusedProvider, isNull);
  });

  test('refused by another request first (the token already gone): renewed all the same', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    final auth = _Auth();
    final client = ApiClient(session: s, httpClient: auth.client);
    var asked = 0;
    final repo = ApiAccountRepository(client, session: s, silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    // A screen's request meets the refusal before the account is read.
    await expectLater(client.getJson('/rest/v1/bookmarks'), throwsA(anything));
    expect(s.access, isNull);
    expect(SessionStore.refusedProvider, 'google');
    expect((await repo.currentUser())?.id, 'u1');
    expect(asked, 1);
  });

  test('a phone session refused: signed out, Google never asked', () async {
    final s = _MemSession(access: _token(['phone']), refresh: 'r1', expired: true);
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth().client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    expect(await repo.currentUser(), isNull);
    expect(asked, 0);
  });

  test('the viewer\'s own sign-out is never undone', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth().client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    // The logout's own refresh is refused (the session is old): still the
    // viewer's sign-out, not the server's.
    await repo.signOut();
    expect(await repo.currentUser(), isNull);
    expect(asked, 0);
    expect(SessionStore.refusedProvider, isNull);
    expect(s.mfa, isNull, reason: 'the mark goes with the viewer\'s own sign-out');
  });

  test('a fresh install, or a plain signed-out start, never asks Google', () async {
    final s = _MemSession();
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth().client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    expect(await repo.currentUser(), isNull);
    expect(await repo.currentUser(), isNull);
    expect(asked, 0);
  });

  test('no account Google can sign in silently: signed out, and asked once only', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth().client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return null;
    });
    expect(await repo.currentUser(), isNull);
    expect(await repo.currentUser(), isNull);
    expect(asked, 1, reason: 'the refusal is renewed once, never again and again');
  });

  test('Google gives ANOTHER account than the one the server ended: not signed in, its session ended', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    final auth = _Auth(userId: 'someone-else');
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: auth.client), session: s,
        silentGoogleIdToken: () async => 'google-id-token');
    expect(await repo.currentUser(), isNull,
        reason: 'another account would inherit the first one\'s downloads, unasked');
    expect(s.access, isNull);
    expect(auth.seen, contains('/auth/v1/logout'));
  });

  test('the exchange fails (the auth server down): signed out, nothing thrown', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth(exchangeStatus: 503).client),
        session: s, silentGoogleIdToken: () async => 'google-id-token');
    expect(await repo.currentUser(), isNull);
    expect(s.access, isNull);
  });

  test('a silent sign-in that throws is a signed-out start, not a crash', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: _Auth().client), session: s,
        silentGoogleIdToken: () async => throw StateError('no Play services'));
    expect(await repo.currentUser(), isNull);
  });

  test('an ordinary account (no MFA) refused — deleted or signed out on another phone — is never renewed', () async {
    // An ID token exchanged for a deleted account would sign up a new one.
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true);
    final auth = _Auth();
    var asked = 0;
    final repo = ApiAccountRepository(ApiClient(session: s, httpClient: auth.client), session: s,
        silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    expect(await repo.currentUser(), isNull);
    expect(asked, 0);
    expect(auth.exchanged, isNull, reason: 'no exchange, so no account made');
  });

  test('the MFA mark comes from the user\'s own factors, and goes when they do', () async {
    final s = _MemSession(access: 'live', refresh: 'r1');
    var factors = <Object>[
      {'id': 'f1', 'factor_type': 'totp', 'status': 'verified'},
    ];
    final client = ApiClient(
        session: s,
        httpClient: MockClient((req) async => _json(200, {
              'id': 'u1',
              'app_metadata': {'provider': 'google'},
              'factors': factors,
            })));
    final repo = ApiAccountRepository(client, session: s, silentGoogleIdToken: () async => null);
    expect((await repo.currentUser())?.id, 'u1');
    expect(s.mfa, 'u1');
    factors = <Object>[
      {'id': 'f2', 'factor_type': 'totp', 'status': 'unverified'},
    ];
    await repo.currentUser();
    expect(s.mfa, isNull, reason: 'an unverified factor is no MFA');
  });

  test('deleting the account here: nothing renewed after it, the mark gone', () async {
    final s = _MemSession(access: 'live', refresh: 'r1', mfa: 'u1');
    var asked = 0;
    final client = ApiClient(
        session: s,
        httpClient: MockClient((req) async =>
            req.url.path.endsWith('/delete-account') ? _json(200, {'ok': true}) : _json(401, {'msg': 'gone'})));
    final repo = ApiAccountRepository(client, session: s, silentGoogleIdToken: () async {
      asked++;
      return 'google-id-token';
    });
    SessionStore.noteRefused(_token(['google']));
    await repo.deleteAccount(expectUserId: 'u1');
    expect(SessionStore.refusedProvider, isNull);
    expect(s.mfa, isNull);
    expect(await repo.currentUser(), isNull);
    expect(asked, 0);
  });

  test('an exchange whose user must be read again, and refused: one exchange, never a loop', () async {
    final s = _MemSession(access: _token(['google']), refresh: 'r1', expired: true, mfa: 'u1');
    var exchanges = 0;
    final client = ApiClient(
        session: s,
        httpClient: MockClient((req) async {
          final grant = req.url.queryParameters['grant_type'];
          if (grant == 'refresh_token') return _refused;
          if (grant == 'id_token') {
            exchanges++;
            // A session with no user in it: the user is read, and refused.
            return _json(200, {'access_token': _token(['google']), 'refresh_token': 'r9', 'expires_in': 3600});
          }
          return _json(401, {'msg': 'no session'});
        }));
    final repo = ApiAccountRepository(client, session: s, silentGoogleIdToken: () async => 'google-id-token');
    expect(await repo.currentUser(), isNull);
    expect(exchanges, 1);
  });

  test('the provider read from a token\'s claims; anything unreadable is none', () {
    expect(SessionStore.providerOf(_token(['google'])), 'google');
    expect(SessionStore.providerOf(_token(['phone', 'google'])), 'google', reason: 'a phone account that linked Google');
    expect(SessionStore.providerOf(_token(['phone'])), 'phone');
    expect(SessionStore.providerOf('not-a-token'), isNull);
    expect(SessionStore.providerOf('a.%%%.c'), isNull);
    expect(SessionStore.providerOf(null), isNull);
    expect(SessionStore.userOf(_token(['google'])), 'u1');
    expect(SessionStore.userOf('a.%%%.c'), isNull);
  });
}
