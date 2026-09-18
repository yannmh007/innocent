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

/// Where a [PaymentInstructions] actually came from.
///
/// audit_video_hub.md M2. This exists because the screen used to render all
/// three identically — payee in bold, a Copy button beside the number, "send
/// the money here" above it — and one of the three is a number that has never
/// received a Kyat.
///
/// The UI must branch on this. A payee nobody can pay is not a degraded
/// version of a payee; it is a wrong instruction given with confidence.
enum PaymentSource {
  /// The server answered just now. Safe to act on.
  live,

  /// The server could not be reached, and this is the last answer it gave,
  /// saved on this device. Real digits, possibly stale prices — so it is
  /// shown, with a warning, rather than withheld.
  cached,

  /// Nothing has ever been fetched on this install. The values are the
  /// bundled constants below and are NOT payable. Never present these as
  /// payment instructions.
  placeholder,
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

  /// Where these values came from. Defaults to [PaymentSource.live] so that
  /// any repository returning its own authoritative answer needs no change.
  final PaymentSource source;

  const PaymentInstructions({
    required this.payeeName,
    required this.payeeNumber,
    required this.prices,
    this.note,
    this.source = PaymentSource.live,
  });

  /// True when these values may be shown as something to pay.
  ///
  /// [PaymentSource.cached] counts: the digits are real, they are just
  /// possibly stale, and the screen says so. [PaymentSource.placeholder] does
  /// not, and that is the whole point of this getter.
  bool get isPayable => source != PaymentSource.placeholder;

  PaymentInstructions copyWith({PaymentSource? source}) => PaymentInstructions(
        payeeName: payeeName,
        payeeNumber: payeeNumber,
        prices: prices,
        note: note,
        source: source ?? this.source,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'payee_name': payeeName,
        'payee_number': payeeNumber,
        'prices': prices,
        'note': note,
      };

  /// Rebuilds a cached copy. Returns null rather than a half-filled object if
  /// the stored shape is not what this build expects — a wrong payee number
  /// is worse than no payee number.
  static PaymentInstructions? fromJson(Map<String, dynamic> m) {
    final name = m['payee_name'];
    final number = m['payee_number'];
    if (name is! String || number is! String || number.isEmpty) return null;
    final prices = <String, String>{};
    final raw = m['prices'];
    if (raw is Map) raw.forEach((k, v) => prices['$k'] = '$v');
    if (prices.isEmpty) return null;
    return PaymentInstructions(
      payeeName: name,
      payeeNumber: number,
      prices: prices,
      note: m['note'] as String?,
      source: PaymentSource.cached,
    );
  }

  /// NOT PAYABLE. `09-000-000-000` is not a real KPay account; it exists so
  /// the screen has something to lay out before a fetch has ever succeeded.
  /// It carries [PaymentSource.placeholder] so nothing can show it by
  /// accident — see [isPayable].
  static const PaymentInstructions placeholder = PaymentInstructions(
    payeeName: 'Innocent',
    payeeNumber: '09-000-000-000',
    prices: <String, String>{
      'yearly': 'MMK 34,000',
      'monthly': 'MMK 3,500',
    },
    source: PaymentSource.placeholder,
  );
}
