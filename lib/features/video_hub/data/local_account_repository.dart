import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/access.dart';
import '../domain/account.dart';
import '../domain/account_repository.dart';

/// On-device stand-in for the account backend. **DEVELOPMENT ONLY.**
///
/// ⚠️ ENFORCES NOTHING, AND CANNOT. Everything here is SharedPreferences on a
/// device the user controls: the "signed-in" account, the request queue, and
/// the entitlement. Anyone with a rooted phone or a patched build can set all
/// three, and no obfuscation changes that.
///
/// It exists so the sign-in, payment-request and account screens can be built,
/// reviewed and demonstrated before a backend exists — and so both sides of
/// the paywall can be walked through on a real device.
///
/// The real implementation is a thin HTTP adapter over the schema in
/// `docs/premium_backend_spec.md`. When it lands, this class is deleted rather
/// than kept as a fallback: a fallback that grants premium offline is a
/// bypass with a friendly name.
class LocalAccountRepository implements AccountRepository {
  const LocalAccountRepository();

  static const String _kUser = 'vh_account_user';
  static const String _kRequests = 'vh_account_requests';
  static const String _kEntitlement = 'vh_account_entitlement';

  /// The code the local stub accepts. Real phone auth sends a code the device
  /// cannot predict; this one is fixed and printed on the screen, because a
  /// dev stub that pretends to be secure teaches the wrong lesson.
  static const String devCode = '000000';

  @override
  Future<AuthUser?> currentUser() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kUser);
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return AuthUser(
      id: m['id'] as String,
      method: m['method'] == 'google' ? AuthMethod.google : AuthMethod.phone,
      phone: m['phone'] as String?,
      email: m['email'] as String?,
      displayName: m['name'] as String?,
    );
  }

  Future<void> _saveUser(AuthUser user) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kUser,
      jsonEncode(<String, dynamic>{
        'id': user.id,
        'method': user.method.id,
        'phone': user.phone,
        'email': user.email,
        'name': user.displayName,
      }),
    );
  }

  @override
  Future<void> startPhoneSignIn(String phoneE164) async {
    // A real backend sends an SMS here. The stub does nothing, on purpose:
    // silently "succeeding" at sending is the same shape as the real call.
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Future<AuthUser> verifyPhoneCode({
    required String phoneE164,
    required String code,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    if (code.trim() != devCode) {
      throw const FormatException('invalid code');
    }
    final user = AuthUser(
      id: 'local:$phoneE164',
      method: AuthMethod.phone,
      phone: phoneE164,
    );
    await _saveUser(user);
    return user;
  }

  @override
  Future<AuthUser> signInWithGoogle() async {
    // Native Google sign-in needs a plugin and a configured OAuth client, and
    // faking it here would hide that from whoever wires the backend.
    throw UnimplementedError('Google sign-in requires backend configuration');
  }

  @override
  Future<void> signOut() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kUser);
    // Entitlement and requests belong to the ACCOUNT, not the device. Leaving
    // them behind would hand the next person to sign in someone else's
    // subscription.
    await sp.remove(_kEntitlement);
    await sp.remove(_kRequests);
  }

  @override
  Future<Entitlement> entitlement() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kEntitlement);
    if (raw == null) return const Entitlement.free();
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final millis = m['expiresAt'] as int?;
    return Entitlement.premium(
      expiresAt:
          millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis),
      planId: m['planId'] as String?,
    );
  }

  @override
  Future<PaymentInstructions> paymentInstructions() async {
    // Served by the backend in production so a number or a price can change
    // without a release.
    return PaymentInstructions.placeholder;
  }

  @override
  Future<PremiumRequest> submitPremiumRequest({
    required String planId,
    required String reference,
    String? senderPhone,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final req = PremiumRequest(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      planId: planId,
      reference: reference,
      senderPhone: senderPhone,
      status: PremiumRequestStatus.pending,
      submittedAt: DateTime.now(),
    );
    final all = await myRequests();
    await _saveRequests(<PremiumRequest>[req, ...all]);
    return req;
  }

  @override
  Future<List<PremiumRequest>> myRequests() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_kRequests);
    if (raw == null) return const <PremiumRequest>[];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) {
      final m = e as Map<String, dynamic>;
      return PremiumRequest(
        id: m['id'] as String,
        planId: m['planId'] as String,
        reference: m['reference'] as String,
        senderPhone: m['senderPhone'] as String?,
        status: PremiumRequestStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => PremiumRequestStatus.pending,
        ),
        submittedAt:
            DateTime.fromMillisecondsSinceEpoch(m['submittedAt'] as int),
        note: m['note'] as String?,
      );
    }).toList();
  }

  Future<void> _saveRequests(List<PremiumRequest> requests) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kRequests,
      jsonEncode(requests
          .map((r) => <String, dynamic>{
                'id': r.id,
                'planId': r.planId,
                'reference': r.reference,
                'senderPhone': r.senderPhone,
                'status': r.status.name,
                'submittedAt': r.submittedAt.millisecondsSinceEpoch,
                'note': r.note,
              })
          .toList()),
    );
  }

  @override
  Future<void> recordAgeConsent({
    required int version,
    required DateTime acceptedAt,
  }) async {
    // The stub keeps only the device copy, which AgeConsentStore already
    // wrote. There is nothing else here to record it to.
  }

  @override
  Future<void> claimAnonymousHistory(String anonymousId) async {
    // Nothing to merge on-device: the stub keeps no per-viewer history. The
    // real adapter posts the id so the server can re-key the events.
  }

  /// DEV ONLY — stands in for the operator approving a payment.
  ///
  /// In production this happens in the admin dashboard against the real KPay
  /// statement, and the app only ever READS the result. Nothing equivalent to
  /// this method exists in the HTTP adapter.
  Future<void> devApproveLatest({Duration validFor = const Duration(days: 30)}) async {
    final all = await myRequests();
    if (all.isEmpty) return;
    final head = all.first;
    final approved = PremiumRequest(
      id: head.id,
      planId: head.planId,
      reference: head.reference,
      senderPhone: head.senderPhone,
      status: PremiumRequestStatus.approved,
      submittedAt: head.submittedAt,
      note: 'approved locally (dev)',
    );
    await _saveRequests(<PremiumRequest>[approved, ...all.skip(1)]);

    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      _kEntitlement,
      jsonEncode(<String, dynamic>{
        'planId': head.planId,
        'expiresAt': DateTime.now().add(validFor).millisecondsSinceEpoch,
      }),
    );
  }
}
