import 'api_client.dart';

/// Where a rights holder, or a person in a film, writes to have something
/// taken down (docs/security_review_2026_11.md P6). Shown in About and in
/// the report sheet; the owner's Telegram notice names it too
/// (migration 076). One place, so it cannot drift.
const String kTakedownEmail = 'innocentmail69@gmail.com';

/// Why a viewer reports a title. The names are the server's
/// (`content_reports.reason`, migration 076).
enum ReportReason {
  rights('rights'),
  illegal('illegal'),
  minor('minor'),
  consent('consent'),
  other('other');

  const ReportReason(this.id);
  final String id;

  /// "Something else" says nothing on its own: it needs words.
  bool get needsDetail => this == ReportReason.other;
}

enum ReportOutcome { sent, tooMany, invalid, failed }

/// Sends a viewer's report to `report_content` (migration 076): open to
/// anyone with the app, five a day per phone, and nothing about the sender
/// is kept beyond what that limit needs (hashes, never an address).
class ContentReporter {
  ContentReporter(this._api);

  final ApiClient _api;

  static const int maxDetail = 1000;
  static const int maxContact = 200;

  /// The RPC's body, trimmed and cut to what the server keeps. Null when
  /// it cannot be sent at all (no reason; "something else" with no words).
  static Map<String, dynamic>? bodyFor({
    String? titleId,
    required ReportReason? reason,
    String detail = '',
    String contact = '',
  }) {
    if (reason == null) return null;
    final d = detail.trim();
    final c = contact.trim();
    if (reason.needsDetail && d.isEmpty) return null;
    return <String, dynamic>{
      'p_title': (titleId == null || titleId.isEmpty) ? null : titleId,
      'p_reason': reason.id,
      'p_detail': d.length > maxDetail ? d.substring(0, maxDetail) : d,
      'p_contact': c.isEmpty ? null : (c.length > maxContact ? c.substring(0, maxContact) : c),
    };
  }

  Future<ReportOutcome> send({
    String? titleId,
    required ReportReason? reason,
    String detail = '',
    String contact = '',
  }) async {
    final body = bodyFor(titleId: titleId, reason: reason, detail: detail, contact: contact);
    if (body == null) return ReportOutcome.invalid;
    try {
      final r = await _api.postJson('/rest/v1/rpc/report_content', body: body);
      return switch (r) {
        'ok' => ReportOutcome.sent,
        'too_many' => ReportOutcome.tooMany,
        'bad' => ReportOutcome.invalid,
        _ => ReportOutcome.failed,
      };
    } catch (_) {
      // No network, a timeout, a refusal: all "not sent", said plainly.
      return ReportOutcome.failed;
    }
  }
}
