import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The signed-in session's tokens.
///
/// ─── WHY THESE ARE KEYSTORE-BACKED (v1.55.16) ────────────────────────────
///
/// These lived in plain SharedPreferences, on the argument that the access
/// token is short-lived and the server re-checks the subscription on every
/// playback request — so a stolen one buys minutes of the victim's own access
/// rather than a permanent bypass.
///
/// That argument was sound about the ACCESS token and silent about the one
/// stored beside it. **A refresh token is not short-lived; mints new access
/// tokens is its entire job.** And Android's Auto Backup uploads an app's
/// SharedPreferences to the user's Google Drive by default, while the
/// device-transfer flow copies it to a new handset — so the long-lived half of
/// the session was leaving the phone by two channels nobody had looked at. The
/// vault's own backup rules already exclude exactly one file:
/// `FlutterSecureStorage`. Putting the tokens there fixes the storage and the
/// backup exposure in the same move, with no manifest change.
///
/// `flutter_secure_storage` was previously ruled out here as "a new native
/// dependency this project cannot compile locally to verify". That is no
/// longer true — it is already a dependency, already shipping, and already
/// holding the Private Folder's PIN material.
///
/// Reads migrate a value written by an older build exactly once, then delete
/// the plaintext copy. Keystore reads can fail transiently (notably just after
/// the user changes their lock screen), so a failure falls back to the legacy
/// store rather than signing the user out.
///
/// What must NEVER be stored anywhere, in either store: a signed media URL.
/// Tokens are re-checked on use; a media URL is not.
class SessionStore {
  const SessionStore();

  static const String _kAccess = 'vh_session_access';
  static const String _kRefresh = 'vh_session_refresh';
  static const String _kExpiry = 'vh_session_expiry';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Read a secured value, migrating a legacy plaintext copy once.
  static Future<String?> _read(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null) return v;
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.read: $e');
    }
    final sp = await SharedPreferences.getInstance();
    final legacy = sp.getString(key);
    if (legacy == null) return null;
    try {
      await _secure.write(key: key, value: legacy);
      await sp.remove(key); // drop the plaintext copy after migration
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.migrate: $e');
    }
    return legacy;
  }

  static Future<void> _write(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.write: $e');
    }
    // Belt and braces against a half-migrated install: if a plaintext copy of
    // this key survives from an older build, it must not outlive the new one.
    try {
      final sp = await SharedPreferences.getInstance();
      if (sp.containsKey(key)) await sp.remove(key);
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.write-cleanup: $e');
    }
  }

  static Future<void> _delete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.delete: $e');
    }
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.remove(key);
    } catch (e) {
      if (kDebugMode) debugPrint('SessionStore.delete-legacy: $e');
    }
  }

  Future<String?> accessToken() => _read(_kAccess);

  Future<String?> refreshToken() => _read(_kRefresh);

  /// True when the access token is past its expiry, with a safety margin.
  ///
  /// The margin matters: a token that is valid when the request is built can
  /// expire while it is in flight on a slow network, and the user sees a
  /// spurious sign-out.
  Future<bool> isExpired() async {
    final raw = await _read(_kExpiry);
    final millis = raw == null ? null : int.tryParse(raw);
    if (millis == null) return false;
    final expiry = DateTime.fromMillisecondsSinceEpoch(millis);
    return DateTime.now().add(const Duration(seconds: 30)).isAfter(expiry);
  }

  Future<void> save({
    required String accessToken,
    String? refreshToken,
    int? expiresInSeconds,
  }) async {
    await _write(_kAccess, accessToken);
    if (refreshToken != null) await _write(_kRefresh, refreshToken);
    if (expiresInSeconds != null) {
      await _write(
        _kExpiry,
        DateTime.now()
            .add(Duration(seconds: expiresInSeconds))
            .millisecondsSinceEpoch
            .toString(),
      );
    }
  }

  Future<void> clear() async {
    await _delete(_kAccess);
    await _delete(_kRefresh);
    await _delete(_kExpiry);
  }

  /// Reads whatever the auth endpoint returned and keeps the parts that matter.
  ///
  /// Tolerant of shape: a session body that is missing `expires_in` is stored
  /// without an expiry rather than rejected, because a token that works but
  /// whose lifetime is unknown is still a working token.
  Future<void> saveFromAuthResponse(Map<String, dynamic> body) async {
    final access = body['access_token'];
    if (access is! String || access.isEmpty) return;
    await save(
      accessToken: access,
      refreshToken: body['refresh_token'] as String?,
      expiresInSeconds: body['expires_in'] is int
          ? body['expires_in'] as int
          : int.tryParse('${body['expires_in']}'),
    );
  }

  /// Debug helper that deliberately does NOT return the token itself.
  String describe(String? token) =>
      token == null ? 'none' : 'present(${token.length} chars)';

  static Map<String, dynamic> decodeBody(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }
}
