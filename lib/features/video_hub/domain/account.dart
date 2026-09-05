import 'package:flutter/foundation.dart';

/// How someone proved who they are.
enum AuthMethod { phone, google }

extension AuthMethodX on AuthMethod {
  String get id => this == AuthMethod.phone ? 'phone' : 'google';
}

/// A signed-in account.
///
/// Identity exists for ONE operational reason before it is a feature: with
/// manual KPay activation, somebody has to be able to look at a payment and
/// say which account it belongs to. An anonymous app cannot be told "this
/// person paid" — there is nothing to attach the answer to.
///
/// [id] is the server's identifier and the only thing that should ever key a
/// subscription. Phone numbers get recycled and Google addresses get changed;
/// neither is a stable primary key.
@immutable
class AuthUser {
  final String id;
  final AuthMethod method;

  /// E.164 where known. The KPay sender number usually matches this, which is
  /// what makes manual matching quick.
  final String? phone;

  final String? email;
  final String? displayName;

  const AuthUser({
    required this.id,
    required this.method,
    this.phone,
    this.email,
    this.displayName,
  });

  /// What to show in the account header, in order of how recognisable it is.
  String get label => displayName ?? phone ?? email ?? id;

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.id == id &&
      other.method == method &&
      other.phone == phone &&
      other.email == email &&
      other.displayName == displayName;

  @override
  int get hashCode => Object.hash(id, method, phone, email, displayName);
}

/// Where a manual payment request has got to.
enum PremiumRequestStatus {
  /// Submitted, waiting for a human to check the KPay transfer.
  pending,

  /// Approved — a subscription now exists.
  approved,

  /// Rejected. [PremiumRequest.note] carries the reason.
  rejected,
}

/// A user's claim that they have paid.
///
/// The app CANNOT verify a KPay transfer, and pretending otherwise would be
/// the worst possible design: a client that decides for itself that it has
/// been paid is a client that always has. So this is exactly what it looks
/// like — a claim, recorded and queued for a person to check against the real
/// KPay ledger. Approval happens outside the app entirely.
@immutable
class PremiumRequest {
  final String id;
  final String planId;

  /// Whatever the payer can give that ties the request to a real transfer —
  /// the KPay transaction id, or the sending number.
  final String reference;

  /// The number the money was sent FROM. The single most useful field for
  /// matching, because it appears on the recipient's KPay statement.
  final String? senderPhone;

  final PremiumRequestStatus status;
  final DateTime submittedAt;

  /// Reviewer's message — the reason on a rejection, a note on an approval.
  final String? note;

  const PremiumRequest({
    required this.id,
    required this.planId,
    required this.reference,
    required this.status,
    required this.submittedAt,
    this.senderPhone,
    this.note,
  });

  bool get isPending => status == PremiumRequestStatus.pending;
}

/// What the operator needs the payer to see and do.
///
/// Data, not hard-coded strings: a KPay number changes, a price changes, and
/// neither should need a release. Served from the backend in production;
/// bundled defaults exist only so the screen renders before there is one.
@immutable
class PaymentInstructions {
  final String payeeName;
  final String payeeNumber;

  /// planId -> display price. Keyed so the request records which plan was
  /// bought without the UI passing a formatted string around.
  final Map<String, String> prices;

  /// Free-form operator note — hours, expected turnaround, contact.
  final String? note;

  const PaymentInstructions({
    required this.payeeName,
    required this.payeeNumber,
    required this.prices,
    this.note,
  });

  static const PaymentInstructions placeholder = PaymentInstructions(
    payeeName: 'Innocent',
    payeeNumber: '09-000-000-000',
    prices: <String, String>{
      'yearly': 'MMK 34,000',
      'monthly': 'MMK 3,500',
    },
  );
}
