import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/access.dart';
import '../../domain/account.dart';
import '../../domain/account_repository.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'session_store.dart';

/// [AccountRepository] over the backend described in
/// `docs/premium_backend_spec.md`.
///
/// Written against that document so the two cannot drift: every path here has
/// a matching table or function there. When the backend is stood up, this
/// class needs no changes - only [BackendConfig] does.
///
/// THE IMPORTANT PROPERTY: nothing in this file decides anything. Entitlement
/// is READ from the server's own subscription rows; the app never computes,
/// caches or infers it. If the server says nothing is active, nothing is
/// active, whatever the device happens to believe.
class ApiAccountRepository implements AccountRepository {
  ApiAccountRepository(this._api, {SessionStore session = const SessionStore()})
      : _session = session;

  final ApiClient _api;
  final SessionStore _session;

  @override
  Future<AuthUser?> currentUser() async {
    final token = await _session.accessToken();
    if (token == null || token.isEmpty) return null;
    try {
      final body = await _api.getJson('/auth/v1/user');
      if (body is! Map<String, dynamic>) return null;
      return _userFrom(body);
    } on ApiException catch (e) {
      // Unauthenticated means the session is gone: report signed out.
      if (e.kind == ApiErrorKind.unauthenticated) {
        await _session.clear();
        return null;
      }
      // A NETWORK failure is not a sign-out. Rethrowing here would log the
      // user out every time they open the app in a tunnel.
      rethrow;
    }
  }

  static AuthUser _userFrom(Map<String, dynamic> m) {
    final meta = m['user_metadata'];
    return AuthUser(
      id: '${m['id']}',
      method: (m['phone'] as String?)?.isNotEmpty == true
          ? AuthMethod.phone
          : AuthMethod.google,
      phone: m['phone'] as String?,
      email: m['email'] as String?,
      displayName:
          meta is Map<String, dynamic> ? meta['full_name'] as String? : null,
    );
  }

  @override
  Future<void> startPhoneSignIn(String phoneE164) async {
    await _api.postJson(
      '/auth/v1/otp',
      body: <String, dynamic>{'phone': phoneE164},
      authenticated: false,
    );
  }

  @override
  Future<AuthUser> verifyPhoneCode({
    required String phoneE164,
    required String code,
  }) async {
    final body = await _api.postJson(
      '/auth/v1/verify',
      body: <String, dynamic>{
        'type': 'sms',
        'phone': phoneE164,
        'token': code,
      },
      authenticated: false,
    );
    if (body is! Map<String, dynamic>) {
      throw const ApiException(ApiErrorKind.server, message: 'bad session');
    }
    await _session.saveFromAuthResponse(body);
    final user = body['user'];
    if (user is Map<String, dynamic>) return _userFrom(user);

    // Some deployments return the session without the user object; ask.
    final me = await currentUser();
    if (me == null) {
      throw const ApiException(ApiErrorKind.server, message: 'no user');
    }
    return me;
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    // Google sign-in needs an OAuth redirect and a platform plugin, which is a
    // native dependency this project cannot verify without a local build.
    // Left unimplemented rather than faked, so whoever wires it sees the gap.
    throw UnimplementedError('Google sign-in not wired yet');
  }

  @override
  Future<void> signOut() async {
    try {
      await _api.postJson('/auth/v1/logout');
    } on ApiException {
      // Best effort. If the server cannot be reached the local session is
      // still cleared: a user who taps Sign out must end up signed out, even
      // offline.
    }
    await _session.clear();
  }

  @override
  Future<Entitlement> entitlement() async {
    final token = await _session.accessToken();
    if (token == null || token.isEmpty) return const Entitlement.free();

    // RLS scopes this to the caller's own rows, so no user id is sent - and
    // sending one would be meaningless anyway, since the server would ignore
    // it in favour of the JWT.
    final rows = await _api.getJson(
      '/rest/v1/subscriptions',
      query: <String, String>{
        'select': 'plan_id,starts_at,expires_at',
        'order': 'expires_at.desc.nullsfirst',
        'limit': '1',
      },
    );
    if (rows is! List || rows.isEmpty) return const Entitlement.free();
    final row = rows.first;
    if (row is! Map<String, dynamic>) return const Entitlement.free();

    final expiresRaw = row['expires_at'] as String?;
    final expiresAt =
        expiresRaw == null ? null : DateTime.tryParse(expiresRaw)?.toLocal();

    // A row can exist and still be dead - an expired subscription is hidden by
    // RLS in some setups and returned in others. Checking here means both
    // behave identically.
    if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
      return const Entitlement.free();
    }
    return Entitlement.premium(
      expiresAt: expiresAt,
      planId: row['plan_id'] as String?,
    );
  }

  /// Where the last successful fetch is kept, so a failed one has something
  /// true to fall back to. Plain SharedPreferences on purpose: a KPay payee
  /// number is public information the operator wants shown, not a secret.
  static const String _kCachedInstructions = 'vh_payment_instructions';

  @override
  Future<PaymentInstructions> paymentInstructions() async {
    // audit_video_hub.md M2. The old version caught ApiException and returned
    // PaymentInstructions.placeholder, under a comment that said "showing the
    // last-known KPay number beats showing an error". It was NOT the
    // last-known number — nothing persisted a successful fetch — it was the
    // bundled constant `09-000-000-000`, rendered identically to real data,
    // with a Copy button beside it, under the words "send the money here".
    //
    // Two failures, in order of cost. Somebody copies a number that is not a
    // KPay account, and the app has just invented a payment instruction. And
    // the PRICES are stale by construction, so raising the yearly plan leaves
    // every user on a bad connection quoted the old figure — and right to be
    // annoyed when told otherwise.
    //
    // So the sentence is made true instead: a successful fetch is saved, and
    // a failed one returns that, marked `cached` so the screen can say the
    // details might be stale. Only when nothing has EVER been fetched does
    // the placeholder come back, and it is marked `placeholder` so the screen
    // refuses to present it as payable at all.
    try {
      final rows = await _api.getJson(
        '/rest/v1/payment_instructions',
        query: <String, String>{
          'select': 'payee_name,payee_number,prices,note',
          'limit': '1',
        },
        authenticated: false,
      );
      if (rows is List && rows.isNotEmpty) {
        final m = rows.first;
        if (m is Map<String, dynamic>) {
          final prices = <String, String>{};
          final raw = m['prices'];
          if (raw is Map) {
            raw.forEach((k, v) => prices['$k'] = '$v');
          }
          final number = '${m['payee_number'] ?? ''}';
          // A row that arrived but carries no payee is not a live answer.
          // Treat it exactly like a failed fetch rather than showing an empty
          // number as though it were one.
          if (number.isNotEmpty && prices.isNotEmpty) {
            final fresh = PaymentInstructions(
              payeeName: '${m['payee_name'] ?? ''}',
              payeeNumber: number,
              prices: prices,
              note: m['note'] as String?,
            );
            await _cacheInstructions(fresh);
            return fresh;
          }
        }
      }
    } on ApiException {
      // Fall through to the cache below.
    }
    return await _cachedInstructions() ?? PaymentInstructions.placeholder;
  }

  static Future<void> _cacheInstructions(PaymentInstructions value) async {
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_kCachedInstructions, jsonEncode(value.toJson()));
    } catch (_) {
      // A cache that cannot be written costs the next offline visit a
      // fallback. It must not cost this visit its answer.
    }
  }

  static Future<PaymentInstructions?> _cachedInstructions() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final raw = sp.getString(_kCachedInstructions);
      if (raw == null || raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return PaymentInstructions.fromJson(decoded);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<PremiumRequest> submitPremiumRequest({
    required String planId,
    required String reference,
    String? senderPhone,
  }) async {
    // `status` is deliberately NOT sent. The insert policy only accepts
    // 'pending', and letting the client name a status is exactly the hole that
    // would let someone submit an approved one.
    final body = await _api.postJson(
      '/rest/v1/premium_requests',
      body: <String, dynamic>{
        'plan_id': planId,
        'reference': reference,
        if (senderPhone != null && senderPhone.isNotEmpty)
          'sender_phone': senderPhone,
      },
      extraHeaders: <String, String>{'Prefer': 'return=representation'},
    );
    if (body is List && body.isNotEmpty) {
      final m = body.first;
      if (m is Map<String, dynamic>) return _requestFrom(m);
    }
    // Accepted but nothing echoed back: report it as queued rather than as a
    // failure, because it IS queued and telling the user otherwise makes them
    // pay twice.
    return PremiumRequest(
      id: '',
      planId: planId,
      reference: reference,
      senderPhone: senderPhone,
      status: PremiumRequestStatus.pending,
      submittedAt: DateTime.now(),
    );
  }

  @override
  Future<List<PremiumRequest>> myRequests() async {
    final rows = await _api.getJson(
      '/rest/v1/premium_requests',
      query: <String, String>{
        'select': 'id,plan_id,reference,sender_phone,status,note,submitted_at',
        'order': 'submitted_at.desc',
        'limit': '20',
      },
    );
    if (rows is! List) return const <PremiumRequest>[];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(_requestFrom)
        .toList();
  }

  @override
  Future<void> recordAgeConsent({
    required int version,
    required DateTime acceptedAt,
  }) async {
    try {
      await _api.postJson(
        '/rest/v1/rpc/record_age_consent',
        body: <String, dynamic>{
          'terms_version': version,
          'accepted_at': acceptedAt.toUtc().toIso8601String(),
        },
        // Anonymous viewers accept too, and their acceptance is exactly the
        // one worth having on file. The install id header identifies them.
        authenticated: true,
      );
    } on ApiException {
      // Never block entry on a logging call.
    }
  }

  @override
  Future<void> claimAnonymousHistory(String anonymousId) async {
    if (anonymousId.isEmpty) return;
    try {
      await _api.postJson(
        '/rest/v1/rpc/claim_anonymous_history',
        body: <String, dynamic>{'anon_id': anonymousId},
      );
    } on ApiException {
      // Swallowed: a sign-in that worked must not be reported as failed
      // because a history merge did not. The merge can be retried later; the
      // sign-in cannot be un-lost.
    }
  }

  static PremiumRequest _requestFrom(Map<String, dynamic> m) {
    return PremiumRequest(
      id: '${m['id']}',
      planId: '${m['plan_id']}',
      reference: '${m['reference']}',
      senderPhone: m['sender_phone'] as String?,
      status: _statusFrom(m['status'] as String?),
      submittedAt:
          DateTime.tryParse('${m['submitted_at']}')?.toLocal() ??
              DateTime.now(),
      note: m['note'] as String?,
    );
  }

  static PremiumRequestStatus _statusFrom(String? raw) {
    switch (raw) {
      case 'approved':
        return PremiumRequestStatus.approved;
      case 'rejected':
        return PremiumRequestStatus.rejected;
      default:
        // Unknown status reads as pending on purpose: a new server-side state
        // must never make an old build claim the user has access.
        return PremiumRequestStatus.pending;
    }
  }
}
