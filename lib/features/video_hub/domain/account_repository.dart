import 'dart:typed_data';

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
  ///
  /// Throws [SignInCancelled] when the person dismissed the account chooser.
  /// That is not a failure and must not be shown as one — see the type's own
  /// note for why it is an exception rather than a null return.
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
  ///
  /// [proof] is the receipt's screenshot (migration 040), the proof people
  /// actually have; [reference] (the transaction id) is optional when it is
  /// given. At least one of the two. [priceShown] is the price as this screen
  /// showed it, for the operator to compare with the receipt.
  Future<PremiumRequest> submitPremiumRequest({
    required String planId,
    String reference = '',
    String? senderPhone,
    Uint8List? proof,
    String? priceShown,
    String? message,
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

  /// Deletes this account on the server, for good (docs/edge/delete-account.ts,
  /// migration 048) — and only if it is [expectUserId], the account the
  /// screen showed.
  ///
  /// The server insists on a sign-in from the last ten minutes, so the caller
  /// signs in again just before ([signInWithGoogle]); an account other than
  /// the expected one, picked at that prompt, is refused rather than deleted.
  /// Payments are kept, with nothing in them that names the person; watch
  /// history is kept as nobody's.
  ///
  /// Throws [AccountDeletionRefused] with the reason. On success this
  /// phone's session is gone as well.
  Future<void> deleteAccount({required String expectUserId});
}

/// The server did not delete the account, and why.
///
/// [reason] is one of: `sign_in_again` (the sign-in is too old, or the
/// session is gone), `other_account` (a different account than the one the
/// screen showed), `admin` (an admin account; the owner removes those, in
/// the console), `offline` (the server could not be reached), `failed`
/// (anything else — nothing that can be undone has happened that a retry
/// cannot finish).
class AccountDeletionRefused implements Exception {
  const AccountDeletionRefused(this.reason);

  final String reason;

  @override
  String toString() => 'AccountDeletionRefused($reason)';
}

/// The person dismissed a sign-in flow that had already opened.
///
/// Its own type because "cancelled" and "failed" need opposite UI. Google's
/// account chooser is a full-screen system sheet, and backing out of it is
/// the most ordinary thing a person can do there - they tapped the wrong
/// button, or changed their mind. Showing "Sign-in failed" for that accuses
/// the app of breaking when nothing broke.
///
/// AN EXCEPTION RATHER THAN A NULL RETURN, on purpose. A nullable
/// `Future<AuthUser?>` invites `final user = await signIn(); pop(true);` -
/// which compiles, ignores the null, and closes the sheet on a cancel. A
/// throw cannot be ignored: a caller either names this type above its generic
/// `catch` or lands in it, and "lands in it" is visible the first time
/// anybody taps Back.
class SignInCancelled implements Exception {
  const SignInCancelled();

  @override
  String toString() => 'SignInCancelled';
}

/// A sign-in method the build cannot perform.
///
/// Distinct from a failure: nothing went wrong at runtime, the app was simply
/// built without the credentials this method needs (for Google, the web OAuth
/// client ID - see `BackendConfig.googleServerClientId`). The sheet hides such
/// methods rather than offering them, so this exists as the backstop for a
/// caller that offers one anyway.
class SignInNotConfigured implements Exception {
  const SignInNotConfigured(this.method);

  /// `google`, `phone`, `email` - the method, not the reason.
  final String method;

  @override
  String toString() => 'SignInNotConfigured($method)';
}
