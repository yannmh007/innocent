import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../device_identity.dart';
import 'api_exception.dart';
import 'backend_config.dart';
import 'session_store.dart';

/// The one place the app talks to the network.
///
/// Everything routes through here so that four things are true everywhere and
/// cannot be forgotten at a call site: the session header is attached, a
/// timeout is applied, failures become typed [ApiException]s, and nothing
/// sensitive is ever logged.
///
/// It does NOT decide anything about access. It carries a question to the
/// server and brings back the answer, including "no". Any code that reads a
/// field from a response and concludes the user is premium has misunderstood
/// the design - see `docs/premium_backend_spec.md`.
class ApiClient {
  ApiClient({
    http.Client? httpClient,
    SessionStore session = const SessionStore(),
  })  : _http = httpClient ?? http.Client(),
        _session = session;

  final http.Client _http;
  final SessionStore _session;

  /// Serialises refreshes. Without it, six requests failing at once on a stale
  /// token would fire six refreshes, five of which race and lose - and on
  /// rotating-refresh-token setups the losers invalidate the winner, signing
  /// the user out mid-session.
  Future<void>? _refreshInFlight;

  Future<Map<String, String>> _headers({
    required bool authenticated,
    Map<String, String>? extra,
  }) async {
    final headers = <String, String>{
      'apikey': BackendConfig.anonKey,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      // Attached to EVERY request, signed in or not. Anonymous viewers are
      // still viewers; their taps have to attribute to something or they are
      // simply not counted. After sign-in the same value identifies the
      // device for the concurrency cap.
      'x-install-id': await DeviceIdentity.get(),
      if (extra != null) ...extra,
    };
    if (authenticated) {
      final token = await _session.accessToken();
      // The USER's token, not the anon key. Sending the anon key as the bearer
      // would make every request look like an anonymous one to RLS, and the
      // user would silently see nothing that belongs to them.
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    return headers;
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = BackendConfig.baseUrl.endsWith('/')
        ? BackendConfig.baseUrl.substring(0, BackendConfig.baseUrl.length - 1)
        : BackendConfig.baseUrl;
    final normalised = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$base$normalised').replace(queryParameters: query);
  }

  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    bool authenticated = true,
    Duration? timeout,
  }) {
    return _send(
      (headers) => _http.get(_uri(path, query), headers: headers),
      authenticated: authenticated,
      timeout: timeout,
    );
  }

  Future<dynamic> postJson(
    String path, {
    Object? body,
    Map<String, String>? query,
    Map<String, String>? extraHeaders,
    bool authenticated = true,
    Duration? timeout,
  }) {
    return _send(
      (headers) => _http.post(
        _uri(path, query),
        headers: headers,
        body: body == null ? null : jsonEncode(body),
      ),
      authenticated: authenticated,
      extraHeaders: extraHeaders,
      timeout: timeout,
    );
  }

  /// Runs a request, refreshing the session ONCE on a 401.
  ///
  /// Once, not in a loop: if a fresh token is also rejected the session is
  /// genuinely dead, and retrying would spin against the auth server while the
  /// user watches a spinner.
  Future<dynamic> _send(
    Future<http.Response> Function(Map<String, String>) run, {
    required bool authenticated,
    Map<String, String>? extraHeaders,
    Duration? timeout,
    bool allowRefresh = true,
  }) async {
    if (!BackendConfig.isConfigured) {
      throw const ApiException(
        ApiErrorKind.server,
        message: 'backend not configured',
      );
    }

    http.Response response;
    try {
      final headers =
          await _headers(authenticated: authenticated, extra: extraHeaders);
      response = await run(headers).timeout(timeout ?? BackendConfig.timeout);
    } on TimeoutException {
      throw const ApiException(ApiErrorKind.network, message: 'timeout');
    } on SocketException {
      throw const ApiException(ApiErrorKind.network, message: 'no connection');
    } on http.ClientException {
      throw const ApiException(ApiErrorKind.network, message: 'client error');
    }

    if (response.statusCode == 401 && authenticated && allowRefresh) {
      final refreshed = await _refreshSession();
      if (refreshed) {
        return _send(
          run,
          authenticated: authenticated,
          extraHeaders: extraHeaders,
          timeout: timeout,
          allowRefresh: false,
        );
      }
    }

    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) {
      if (response.body.isEmpty) return null;
      try {
        return jsonDecode(response.body);
      } catch (_) {
        throw const ApiException(
          ApiErrorKind.server,
          message: 'malformed response',
        );
      }
    }

    // Server-supplied code, when there is one. This is how `needs_premium`
    // reaches the UI as a paywall instead of as a generic failure.
    String? code;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        code = (decoded['code'] ?? decoded['error'] ?? decoded['error_code'])
            ?.toString();
      }
    } catch (_) {
      // A non-JSON error body is normal from proxies and gateways.
    }

    switch (status) {
      case 401:
        throw ApiException(ApiErrorKind.unauthenticated,
            code: code, statusCode: status);
      case 403:
        throw ApiException(
          code == 'needs_premium'
              ? ApiErrorKind.needsPremium
              : ApiErrorKind.forbidden,
          code: code,
          statusCode: status,
        );
      case 404:
        throw ApiException(ApiErrorKind.notFound,
            code: code, statusCode: status);
      // 409 is the contract's device-conflict status (`wrong_device`). Without
      // this case it fell to `default` and became `server`, which reads as an
      // outage - so the one refusal with a self-service fix was the one the
      // user could not be told about. `forbidden` and not `needsPremium`:
      // paying again does not add a device slot.
      case 409:
        throw ApiException(ApiErrorKind.forbidden,
            code: code, statusCode: status);
      case 429:
        throw ApiException(ApiErrorKind.tooManyRequests,
            code: code, statusCode: status);
      default:
        throw ApiException(
          ApiErrorKind.server,
          code: code,
          statusCode: status,
          // The body is NOT included. Error bodies quote request context and
          // occasionally tokens, and this string ends up in crash reports.
          message: 'http $status',
        );
    }
  }

  Future<bool> _refreshSession() {
    final inFlight = _refreshInFlight;
    if (inFlight != null) {
      return inFlight.then((_) async {
        final token = await _session.accessToken();
        return token != null && token.isNotEmpty;
      });
    }

    final completer = Completer<void>();
    _refreshInFlight = completer.future;
    return _doRefresh().whenComplete(() {
      _refreshInFlight = null;
      if (!completer.isCompleted) completer.complete();
    });
  }

  Future<bool> _doRefresh() async {
    final refresh = await _session.refreshToken();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final response = await _http
          .post(
            _uri('/auth/v1/token', <String, String>{
              'grant_type': 'refresh_token',
            }),
            headers: <String, String>{
              'apikey': BackendConfig.anonKey,
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, String>{'refresh_token': refresh}),
          )
          .timeout(BackendConfig.timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        // The refresh token is dead too. Clear everything: a half-session
        // where requests fail forever is worse than an honest signed-out
        // state the user can act on.
        await _session.clear();
        return false;
      }
      await _session
          .saveFromAuthResponse(SessionStore.decodeBody(response.body));
      return true;
    } catch (_) {
      // A NETWORK failure must not sign the user out - they are offline, not
      // logged out, and clearing here would lose the session over a tunnel.
      return false;
    }
  }

  void close() => _http.close();
}
