import 'access.dart';
import 'account.dart';

/// Identity, payment requests and subscription state.
///
/// One contract rather than three, because for a manually-activated product
/// they are one story: you sign in so a payment can be attached to you, you
/// claim a payment, and a human turns that into an entitlement. Splitting them
/// would only spread the same three-step flow across three seams.
///
/// Everything here is a NETWORK operation in production. The local
/// implementation exists so the screens can be built and reviewed first, and
/// it is not a security boundary — see [ContentRepository.requestPlayback] for
/// where enforcement actually lives.
abstract class AccountRepository {
  /// The signed-in user, or null.
  Future<AuthUser?> currentUser();

  /// Starts phone sign-in by sending a one-time code.
  ///
  /// Phone first because KPay is phone-based: the number that pays is almost
  /// always the number that signs in, which is what makes manual matching a
  /// glance rather than an investigation.
  Future<void> startPhoneSignIn(String phoneE164);

  /// Completes phone sign-in.
  Future<AuthUser> verifyPhoneCode({
    required String phoneE164,
    required String code,
  });

  /// Google sign-in, for people who would rather not hand over a number.
  Future<AuthUser> signInWithGoogle();

  Future<void> signOut();

  /// The viewer's entitlement AS THE SERVER SEES IT.
  ///
  /// The client never computes this. It is the answer to "what has this
  /// account paid for", and the only party that can answer honestly is the
  /// one holding the payment records.
  Future<Entitlement> entitlement();

  /// Where to send the money and how much.
  Future<PaymentInstructions> paymentInstructions();

  /// Records a claim that a KPay transfer has been made.
  ///
  /// Returns the queued request. It grants NOTHING on its own — approval is a
  /// separate, human step against the real KPay ledger.
  Future<PremiumRequest> submitPremiumRequest({
    required String planId,
    required String reference,
    String? senderPhone,
  });

  /// This account's requests, newest first, so the user can see that their
  /// claim is queued rather than lost.
  Future<List<PremiumRequest>> myRequests();

  /// Attaches everything done before sign-in to the account just created.
  ///
  /// Called immediately after a successful sign-in with the install id that
  /// anonymous activity was attributed to. Registering must not be the moment
  /// a person's history vanishes - that is the single worst first impression
  /// an account can make, and it is entirely avoidable.
  ///
  /// Best-effort by design: a failure here must never break a sign-in that
  /// otherwise succeeded.
  Future<void> claimAnonymousHistory(String anonymousId);

  /// Records that this viewer confirmed their age and accepted the terms.
  ///
  /// The device already remembers it - that is what stops the prompt
  /// reappearing. This is the copy that can still be PRODUCED in a year, which
  /// is the only kind worth anything if a consent is ever questioned.
  ///
  /// Attributed to the account when signed in, otherwise to the install id,
  /// so an anonymous viewer's acceptance is recorded too. Best-effort: a
  /// logging failure must never keep someone out who has just agreed.
  Future<void> recordAgeConsent({
    required int version,
    required DateTime acceptedAt,
  });
}
