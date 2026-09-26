import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/access.dart';
import '../../domain/account.dart';

/// THE SERVER'S LAST ANSWER ABOUT THIS ACCOUNT, kept so a phone with no
/// network still knows whose downloads it is holding.
///
/// ─── WHY THIS EXISTS, AND WHY IT IS NOT "ENTITLEMENT IN THE CLIENT" ──────
///
/// `AccountNotifier.refresh()` asks the server two questions on every launch:
/// who is signed in, and what have they paid for. Both go over the network,
/// and `ApiAccountRepository.currentUser` deliberately RETHROWS a network
/// failure rather than reporting a sign-out — which was right, and was also
/// the end of the story: nothing caught the throw, so with the radio off the
/// account state never left its initial value. That value is
/// `user: null, entitlement: Entitlement.free(), isLoading: true`.
///
/// Which meant `viewerProvider` reported ANONYMOUS, and `playOffline` asks
/// `CapabilityMatrix.allows(tier, Capability.downloadOffline)` before opening
/// a file. So a paying subscriber who had downloaded a film for a bus journey
/// was shown a paywall for their own download, on the one connection state the
/// whole feature exists to serve. That is the bug this file closes.
///
/// What is stored is not a licence the client issues itself. It is the
/// server's own most recent reply, written down, and it is honoured under four
/// conditions, all of which must hold:
///
///   1. ONLY WHEN THE NETWORK FAILED. A real answer — 401, 403, a downgrade to
///      free — always wins and always overwrites this. The snapshot is never
///      consulted while the server can be reached.
///   2. ONLY FOR [grace]. An offline licence with no end date is a permanent
///      bypass for anyone who signs in once and then stays in aeroplane mode.
///      Thirty days is longer than any trip and shorter than a billing cycle.
///   3. ONLY FOR THE SAME ACCOUNT. The user id is stored with it, so a
///      snapshot can never lend one person's subscription to another.
///   4. ONLY WHILE SIGNED IN. [forget] runs inside `signOut`, in the same step
///      that empties the shelf.
///
/// [Entitlement.isActive] still applies on top of all four: a snapshot of a
/// subscription that has since expired reads as expired, because the expiry
/// travelled with it.
///
/// Stored in the Keystore-backed vault rather than SharedPreferences, for the
/// same two reasons [SessionStore] moved there: this decides whether premium
/// content opens, so it should not be a line of editable plaintext, and
/// Android's Auto Backup would otherwise carry one device's entitlement to
/// another handset. The vault is the one store the backup rules already
/// exclude.
class AccountSnapshot {
  const AccountSnapshot._();

  /// How long the server's last answer may stand in for the server.
  static const Duration grace = Duration(days: 30);

  static const String _key = 'vh_account_snapshot';
  static const int _version = 1;

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// Writes the answer a REACHED server just gave.
  ///
  /// A signed-out answer erases the snapshot instead of storing "nobody":
  /// there is nothing to stand in for, and keeping the previous user's
  /// entitlement next to a null user is exactly the stale pair this is meant
  /// to avoid.
  static Future<void> remember(AuthUser? user, Entitlement entitlement) async {
    if (user == null) return forget();
    try {
      await _secure.write(key: _key, value: jsonEncode(encode(user, entitlement)));
    } catch (e) {
      // Best effort. A vault that refuses to write costs the offline case, and
      // must not cost the sign-in that was otherwise successful.
      if (kDebugMode) debugPrint('AccountSnapshot.remember: $e');
    }
  }

  /// The stored answer, or null when there is none, it is too old, or it
  /// cannot be read.
  ///
  /// [now] is injectable so the expiry can be tested without waiting a month.
  static Future<({AuthUser user, Entitlement entitlement, DateTime at})?> recall(
      {DateTime? now}) async {
    String? raw;
    try {
      raw = await _secure.read(key: _key);
    } catch (e) {
      if (kDebugMode) debugPrint('AccountSnapshot.recall: $e');
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    return decode(raw, now: now ?? DateTime.now());
  }

  static Future<void> forget() async {
    try {
      await _secure.delete(key: _key);
    } catch (e) {
      if (kDebugMode) debugPrint('AccountSnapshot.forget: $e');
    }
  }

  // ---- the pure halves, so they can be tested without a Keystore ----------

  @visibleForTesting
  static Map<String, dynamic> encode(AuthUser user, Entitlement entitlement) {
    return <String, dynamic>{
      'v': _version,
      'at': DateTime.now().toUtc().millisecondsSinceEpoch,
      'user': <String, dynamic>{
        'id': user.id,
        'method': user.method.id,
        if (user.phone != null) 'phone': user.phone,
        if (user.email != null) 'email': user.email,
        if (user.displayName != null) 'name': user.displayName,
      },
      'entitlement': <String, dynamic>{
        'premium': entitlement.isPremium,
        // ISO-8601 in UTC with the designator, so the parse on the way back in
        // cannot be read as local time — the same mistake `_parseServerTime`
        // exists to undo, avoided at the source instead.
        if (entitlement.expiresAt != null)
          'expires': entitlement.expiresAt!.toUtc().toIso8601String(),
        if (entitlement.planId != null) 'plan': entitlement.planId,
      },
    };
  }

  /// Parses a stored snapshot, refusing anything it cannot fully trust.
  ///
  /// Every refusal below returns null, which means "no snapshot", which means
  /// the caller reports a signed-out viewer. That is the safe direction: a
  /// malformed entry locks the app out of premium content until it can reach
  /// the server again, never into it.
  @visibleForTesting
  static ({AuthUser user, Entitlement entitlement, DateTime at})? decode(
    String raw, {
    required DateTime now,
  }) {
    try {
      final body = jsonDecode(raw);
      if (body is! Map<String, dynamic>) return null;
      if (body['v'] != _version) return null;

      final atMillis = body['at'];
      if (atMillis is! int) return null;
      final at = DateTime.fromMillisecondsSinceEpoch(atMillis, isUtc: true);
      // A snapshot dated in the FUTURE is refused as well as an old one. The
      // device clock is the only thing this expiry can be measured against, so
      // winding it forward is the obvious way to keep a lapsed entitlement
      // alive; winding it back would make the snapshot look newer than it is,
      // and that is what this test catches.
      if (now.toUtc().isBefore(at)) return null;
      if (now.toUtc().difference(at) > grace) return null;

      final u = body['user'];
      if (u is! Map<String, dynamic>) return null;
      final id = '${u['id'] ?? ''}';
      // No id, no account. Everything downstream keys a subscription on it.
      if (id.isEmpty) return null;

      final e = body['entitlement'];
      if (e is! Map<String, dynamic>) return null;
      final expiresRaw = e['expires'];
      DateTime? expires;
      if (expiresRaw is String && expiresRaw.isNotEmpty) {
        final parsed = DateTime.tryParse(expiresRaw);
        // A premium snapshot whose expiry is unreadable is refused rather than
        // treated as a lifetime one: `Entitlement.premium(expiresAt: null)`
        // never expires, so a corrupted date would become an unlimited pass.
        if (parsed == null) return null;
        expires = parsed.toLocal();
      }

      return (
        user: AuthUser(
          id: id,
          method: u['method'] == 'phone' ? AuthMethod.phone : AuthMethod.google,
          phone: u['phone'] as String?,
          email: u['email'] as String?,
          displayName: u['name'] as String?,
        ),
        entitlement: e['premium'] == true
            ? Entitlement.premium(
                expiresAt: expires,
                planId: e['plan'] as String?,
              )
            : const Entitlement.free(),
        at: at.toLocal(),
      );
    } catch (_) {
      return null;
    }
  }
}
