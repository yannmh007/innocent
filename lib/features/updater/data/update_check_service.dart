import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../video_hub/data/api/backend_config.dart';
import '../domain/app_release.dart';

/// Reads the one row of `public.app_releases`.
///
/// Deliberately NOT routed through `ApiClient`. That client attaches the
/// user's session, refreshes tokens on a 401 and understands the paywall's
/// error codes — none of which apply here. The version check has to work
/// before anyone signs in, so it sends the publishable key as `apikey` and no
/// `Authorization` header at all, which is also the one shape the new
/// `sb_publishable_` keys are documented to work in.
///
/// See `docs/updater_plan.md` §2.
class UpdateCheckService {
  const UpdateCheckService({this.httpClient});

  /// Injectable for tests. Null means a client is created per call and closed.
  final http.Client? httpClient;

  /// The columns the app reads. MUST match `docs/migrations/012_app_releases.sql`.
  ///
  /// PostgREST rejects the WHOLE request when one name here is unknown, so a
  /// single typo reads as "the update check is broken", not as a bad column.
  /// If you add a column to the migration, add it here and to
  /// [AppRelease.fromJson] in the same edit.
  static const String _columns = 'version_name,version_code,'
      'apk_url,apk_sha256,apk_bytes,'
      'notes_en,notes_mm,released_at';

  /// The newest published release, or null when the table holds no row.
  ///
  /// Null means "nothing published", which the screen shows as up to date.
  /// Throws [UpdateCheckFailure] when the answer could not be obtained at all
  /// — those are different states and the screen says different things.
  Future<AppRelease?> fetchLatest() async {
    if (!BackendConfig.isConfigured) {
      throw const UpdateCheckFailure.notConfigured();
    }

    final base = BackendConfig.baseUrl.endsWith('/')
        ? BackendConfig.baseUrl
            .substring(0, BackendConfig.baseUrl.length - 1)
        : BackendConfig.baseUrl;

    // No `id=eq.1` filter. The table's own `check (id = 1)` already makes it a
    // single row, and a filter that disagrees with the data returns nothing at
    // all — which would look exactly like "no release published".
    final uri = Uri.parse('$base/rest/v1/app_releases').replace(
      queryParameters: <String, String>{
        'select': _columns,
        'limit': '1',
      },
    );

    final client = httpClient ?? http.Client();
    try {
      final response = await client.get(
        uri,
        headers: <String, String>{
          'apikey': BackendConfig.anonKey,
          'Accept': 'application/json',
        },
      ).timeout(BackendConfig.timeout);

      if (response.statusCode < 200 || response.statusCode >= 300) {
        // The body is not carried into the message. Error bodies from
        // PostgREST quote the request, and this string can end up in a log.
        throw UpdateCheckFailure.server(response.statusCode);
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! List || decoded.isEmpty) return null;
      final first = decoded.first;
      if (first is! Map) return null;

      return AppRelease.fromJson(Map<String, dynamic>.from(first));
    } on TimeoutException {
      throw const UpdateCheckFailure.network();
    } on SocketException {
      throw const UpdateCheckFailure.network();
    } on http.ClientException {
      throw const UpdateCheckFailure.network();
    } on FormatException {
      throw const UpdateCheckFailure.malformed();
    } finally {
      if (httpClient == null) client.close();
    }
  }
}

/// Why a version check could not be answered.
///
/// Not an [Exception] subclass by accident: the screen catches this and shows
/// one honest line. It carries no server text, because none of it would mean
/// anything to the person reading it.
class UpdateCheckFailure implements Exception {
  const UpdateCheckFailure.notConfigured()
      : kind = UpdateFailureKind.notConfigured,
        statusCode = null;
  const UpdateCheckFailure.network()
      : kind = UpdateFailureKind.network,
        statusCode = null;
  const UpdateCheckFailure.malformed()
      : kind = UpdateFailureKind.malformed,
        statusCode = null;
  const UpdateCheckFailure.server(this.statusCode)
      : kind = UpdateFailureKind.server;

  final UpdateFailureKind kind;
  final int? statusCode;

  @override
  String toString() => 'UpdateCheckFailure(${kind.name}, $statusCode)';
}

enum UpdateFailureKind { notConfigured, network, malformed, server }
