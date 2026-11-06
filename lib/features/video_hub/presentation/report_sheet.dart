import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/ui/app_sheet.dart';
import '../data/api/content_report.dart';
import 'account_provider.dart';

/// The viewer's way to tell us something is wrong with a title, and the
/// rights holder's way to ask for a takedown (docs/security_review_2026_11.md
/// P6). A complaint should reach the people who can act on it first.
final contentReporterProvider =
    Provider<ContentReporter>((ref) => ContentReporter(ref.watch(apiClientProvider)));

const Color _sheet = Color(0xFF1A1A1A);
const Color _muted = Color(0xFF9A9A9F);
const Color _accent = Color(0xFFE50914);

bool _burmese(BuildContext c) => Localizations.localeOf(c).languageCode == 'my';

/// Report [titleId], or the app in general when it is null.
Future<void> showReportSheet(BuildContext context, {String? titleId}) {
  return showAppModalBottomSheet<void>(
    context: context,
    backgroundColor: _sheet,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => ReportSheet(titleId: titleId),
  );
}

class ReportSheet extends ConsumerStatefulWidget {
  const ReportSheet({super.key, this.titleId});

  final String? titleId;

  @override
  ConsumerState<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends ConsumerState<ReportSheet> {
  ReportReason? _reason;
  final _detail = TextEditingController();
  final _contact = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _detail.dispose();
    _contact.dispose();
    super.dispose();
  }

  bool get _ready =>
      _reason != null && !(_reason!.needsDetail && _detail.text.trim().isEmpty);

  Future<void> _send() async {
    final s = AppStrings.of(context);
    if (!_ready) {
      setState(() => _error = s.reportNeedsDetail);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final outcome = await ref.read(contentReporterProvider).send(
          titleId: widget.titleId,
          reason: _reason,
          detail: _detail.text,
          contact: _contact.text,
        );
    if (!mounted) return;
    switch (outcome) {
      case ReportOutcome.sent:
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(s.reportSent),
          ));
      case ReportOutcome.tooMany:
        setState(() {
          _sending = false;
          _error = '${s.reportTooMany} $kTakedownEmail';
        });
      case ReportOutcome.invalid:
        setState(() {
          _sending = false;
          _error = s.reportNeedsDetail;
        });
      case ReportOutcome.failed:
        setState(() {
          _sending = false;
          _error = s.reportFailed;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final my = _burmese(context);
    final body = TextStyle(color: Colors.white, fontSize: 15, height: my ? 1.6 : 1.3);
    final small = TextStyle(color: _muted, fontSize: 13, height: my ? 1.6 : 1.35);
    final reasons = <(ReportReason, String)>[
      (ReportReason.rights, s.reportReasonRights),
      (ReportReason.illegal, s.reportReasonIllegal),
      (ReportReason.minor, s.reportReasonMinor),
      (ReportReason.consent, s.reportReasonConsent),
      (ReportReason.other, s.reportReasonOther),
    ];
    return Padding(
      // Above the keyboard when a field is focused.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(widget.titleId == null ? s.reportAppTitle : s.reportSheetTitle,
                style: const TextStyle(
                    color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700, height: 1.4)),
            const SizedBox(height: 6),
            Text(s.reportIntro, style: small),
            const SizedBox(height: 8),
            for (final (r, label) in reasons)
              RadioListTile<ReportReason>(
                key: ValueKey('report-${r.id}'),
                value: r,
                groupValue: _reason,
                onChanged: (v) => setState(() {
                  _reason = v;
                  _error = null;
                }),
                contentPadding: EdgeInsets.zero,
                activeColor: _accent,
                title: Text(label, style: body),
              ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('report-detail'),
              controller: _detail,
              maxLength: ContentReporter.maxDetail,
              minLines: 2,
              maxLines: 5,
              style: body,
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                hintText: s.reportDetailHint,
                hintStyle: small,
                counterStyle: small,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('report-contact'),
              controller: _contact,
              maxLength: ContentReporter.maxContact,
              keyboardType: TextInputType.emailAddress,
              style: body,
              decoration: InputDecoration(
                hintText: s.reportContactHint,
                hintStyle: small,
                counterText: '',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            Text(s.reportPrivacy, style: small),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(_error!, key: const ValueKey('report-error'),
                  style: TextStyle(color: const Color(0xFFFF6B6B), fontSize: 14, height: my ? 1.6 : 1.3)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                key: const ValueKey('report-send'),
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: _sending || _reason == null ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(s.reportSend),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Copyright & takedown: who to write to, and what to put in it.
Future<void> showTakedownSheet(BuildContext context) {
  final s = AppStrings.of(context);
  final my = _burmese(context);
  return showAppModalBottomSheet<void>(
    context: context,
    backgroundColor: _sheet,
    showDragHandle: true,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(s.takedownTitle,
              style: const TextStyle(
                  color: Colors.white, fontSize: 19, fontWeight: FontWeight.w700, height: 1.4)),
          const SizedBox(height: 14),
          Text(s.takedownBody,
              style: TextStyle(color: const Color(0xFFD6D6DA), fontSize: 14.5, height: my ? 1.75 : 1.5)),
          const SizedBox(height: 16),
          const SelectableText(kTakedownEmail,
              key: ValueKey('takedown-email'),
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              FilledButton.icon(
                key: const ValueKey('takedown-copy'),
                style: FilledButton.styleFrom(backgroundColor: _accent),
                onPressed: () async {
                  await Clipboard.setData(const ClipboardData(text: kTakedownEmail));
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx)
                    ..hideCurrentSnackBar()
                    ..showSnackBar(SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(s.takedownCopied),
                    ));
                },
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(s.takedownCopy),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: TextButton(
                  key: const ValueKey('takedown-report'),
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    showReportSheet(context);
                  },
                  child: Text(s.takedownReportInApp, overflow: TextOverflow.ellipsis),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}
