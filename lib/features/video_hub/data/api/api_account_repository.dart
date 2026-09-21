import 'dart:convert';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/access.dart';
import '../../domain/account.dart';
import '../../domain/account_repository.dart';
import 'api_client.dart';
import 'api_exception.dart';
import 'backend_config.dart';
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
    return _adoptSession(body);
  }

  /// Stores the session a token endpoint returned, and names its user.
  ///
  /// Shared by every sign-in method, because the tail of all of them is
  /// identical: whatever proved who you are - an SMS code, a Google ID token,
  /// an emailed link later - GoTrue answers with the same session envelope.
  /// Keeping one copy is what stops a second method from quietly skipping the
  /// save and leaving a signed-in user with no token on disk.
  Future<AuthUser> _adoptSession(dynamic body) async {
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

  /// The one-time plugin init, shared by every caller.
  ///
  /// The FUTURE is kept, not a boolean: two taps in quick succession then
  /// await the same initialisation instead of racing two of them through a
  /// singleton. A failure is deliberately NOT remembered - see below.
  static Future<void>? _googleInit;

  static Future<void> _ensureGoogleReady() async {
    final pending = _googleInit;
    if (pending != null) return pending;

    final started = GoogleSignIn.instance.initialize(
      serverClientId: BackendConfig.googleServerClientId,
    );
    _googleInit = started;
    try {
      await started;
    } catch (_) {
      // Forget a failed init, or the first failure becomes permanent for the
      // life of the process: every later tap would replay the cached error
      // without ever retrying. Play Services updating in the background is
      // exactly the kind of thing that fails once and then works.
      _googleInit = null;
      rethrow;
    }
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    // The button is hidden when this is false, so reaching here means a caller
    // offered a method this build cannot perform. Say so rather than failing
    // deep inside the plugin with a message about a missing client ID.
    if (!BackendConfig.googleEnabled) {
      throw const SignInNotConfigured('google');
    }

    await _ensureGoogleReady();

    // False only where sign-in must be started by a button the Google SDK
    // itself renders, which today means web. This app ships to Android, so
    // treat it as "this build cannot" rather than inventing a web fallback
    // that has never been run.
    if (!GoogleSignIn.instance.supportsAuthenticate()) {
      throw const SignInNotConfigured('google');
    }

    final String idToken;
    try {
      final account = await GoogleSignIn.instance.authenticate();

      // 7.x carries ONLY an ID token here - there is no access token to pass
      // on, and Google does not need one for this exchange.
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        // Google accepted the user but issued no ID token. In practice that
        // means serverClientId names a client Google will not mint a token
        // for, which is a setup fault rather than a runtime one.
        throw const ApiException(
          ApiErrorKind.server,
          message: 'google returned no id token',
        );
      }
      idToken = token;
    } on GoogleSignInException catch (e) {
      switch (e.code) {
        case GoogleSignInExceptionCode.canceled:
          // A TRAP WORTH KNOWING ABOUT, documented by the plugin itself:
          // some configuration errors make Android's CredentialManager report
          // "canceled" after an account has already been picked, and the
          // plugin cannot tell that apart from a real cancel. So during a
          // first Google Cloud setup the symptom of a wrong SHA-1 or a wrong
          // package name is a button that does NOTHING AT ALL - no error, no
          // spinner, nothing.
          //
          // Treated as a cancel anyway, because once the setup is right that
          // is what it always is, and the alternative is showing a failure
          // message to everyone who taps Back. If the button ever seems dead
          // on a fresh install, read this comment first and check the SHA-1
          // before looking anywhere else.
          throw const SignInCancelled();
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          // The SHA-1 does not match a registered Android client, or the
          // package name does not, or the client was never created. This is
          // THE failure of a first Google Cloud setup, and it is worth being
          // able to tell apart from a network blip while that setup is still
          // being got right.
          throw const SignInNotConfigured('google');
        case GoogleSignInExceptionCode.unknownError:
        case GoogleSignInExceptionCode.interrupted:
        case GoogleSignInExceptionCode.uiUnavailable:
        case GoogleSignInExceptionCode.userMismatch:
          // The code, never e.description: descriptions are free text from
          // Play Services and this string can reach a crash report.
          throw ApiException(
            ApiErrorKind.server,
            message: 'google ${e.code.name}',
          );
      }
    }

    // The same exchange the official client performs, spelled out because this
    // app talks to GoTrue over its REST surface rather than through the SDK:
    // POST /auth/v1/token?grant_type=id_token with the provider and token.
    // Unauthenticated by definition - this request is what creates the
    // session, so there is none to send.
    final body = await _api.postJson(
      '/auth/v1/token',
      query: const <String, String>{'grant_type': 'id_token'},
      body: <String, dynamic>{'provider': 'google', 'id_token': idToken},
      authenticated: false,
    );
    return _adoptSession(body);
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

    // Sign out of Google too, or the next tap on the Google button silently
    // re-signs in as the same person with no chooser - and the account is
    // still remembered, so "Sign out" would not have signed anyone out. On a
    // phone two people share, that hands the second one the first one's
    // subscription.
    //
    // Only when this process actually initialised the plugin: calling into an
    // uninitialised singleton is a different failure, and signing out of
    // Google is not worth risking a sign-out that otherwise works.
    if (_googleInit != null) {
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {
        // Same best-effort rule as the logout above.
      }
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
