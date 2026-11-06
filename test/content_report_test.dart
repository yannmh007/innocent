// Report a title, and the takedown address (docs/security_review_2026_11.md P6).
//
// WHY. With no way to complain to us, a complaint goes straight to the host.
// Pinned here: what is sent is what the server keeps (trimmed, cut to its
// limits, a blank contact sent as none); "Something else" with nothing said
// is not sent; the sheet sends only with a reason, says so when it could not
// send, closes with a thank-you when it did; and the takedown sheet shows
// the address.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/api_client.dart';
import 'package:innocent/features/video_hub/data/api/content_report.dart';
import 'package:innocent/features/video_hub/presentation/report_sheet.dart';

class _FakeReporter extends ContentReporter {
  _FakeReporter(this.answer) : super(ApiClient());
  final ReportOutcome answer;
  final sent = <Map<String, dynamic>?>[];

  @override
  Future<ReportOutcome> send({
    String? titleId,
    required ReportReason? reason,
    String detail = '',
    String contact = '',
  }) async {
    sent.add(ContentReporter.bodyFor(titleId: titleId, reason: reason, detail: detail, contact: contact));
    return answer;
  }
}

Future<void> _open(WidgetTester tester, _FakeReporter fake, {String? titleId = 't1', bool takedown = false}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [contentReporterProvider.overrideWithValue(fake)],
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => takedown
                  ? showTakedownSheet(context)
                  : showReportSheet(context, titleId: titleId),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  group('ContentReporter.bodyFor', () {
    test('trimmed, cut to the server\'s limits, a blank contact sent as none', () {
      final b = ContentReporter.bodyFor(
        titleId: 't1', reason: ReportReason.rights,
        detail: '  ${'x' * 1500}  ', contact: '   ');
      expect(b!['p_title'], 't1');
      expect(b['p_reason'], 'rights');
      expect((b['p_detail'] as String).length, ContentReporter.maxDetail);
      expect(b['p_contact'], isNull);
    });

    test('no reason, or "something else" with nothing said: not sent', () {
      expect(ContentReporter.bodyFor(reason: null), isNull);
      expect(ContentReporter.bodyFor(reason: ReportReason.other, detail: '   '), isNull);
      expect(ContentReporter.bodyFor(reason: ReportReason.other, detail: 'wrong year'), isNotNull);
    });

    test('a report about the app in general names no title', () {
      expect(ContentReporter.bodyFor(titleId: '', reason: ReportReason.illegal)!['p_title'], isNull);
    });

    test('the reasons are the server\'s names', () {
      expect(ReportReason.values.map((r) => r.id).toList(),
          <String>['rights', 'illegal', 'minor', 'consent', 'other']);
    });
  });

  group('the report sheet', () {
    testWidgets('Send waits for a reason; "something else" needs words', (tester) async {
      final fake = _FakeReporter(ReportOutcome.sent);
      await _open(tester, fake);
      final send = find.byKey(const ValueKey('report-send'));
      expect(tester.widget<FilledButton>(send).onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('report-other')));
      await tester.pump();
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump();
      expect(find.byKey(const ValueKey('report-error')), findsOneWidget);
      expect(fake.sent, isEmpty);
    });

    testWidgets('sent: the sheet closes with a thank-you', (tester) async {
      final fake = _FakeReporter(ReportOutcome.sent);
      await _open(tester, fake);
      await tester.tap(find.byKey(const ValueKey('report-rights')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('report-detail')), 'This is my film.');
      await tester.enterText(find.byKey(const ValueKey('report-contact')), 'me@example.com');
      final send = find.byKey(const ValueKey('report-send'));
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(fake.sent.single, <String, dynamic>{
        'p_title': 't1', 'p_reason': 'rights', 'p_detail': 'This is my film.', 'p_contact': 'me@example.com',
      });
      expect(find.byType(ReportSheet), findsNothing);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('not sent: the sheet stays, and says why (with the address when over the limit)',
        (tester) async {
      final fake = _FakeReporter(ReportOutcome.tooMany);
      await _open(tester, fake);
      await tester.tap(find.byKey(const ValueKey('report-minor')));
      await tester.pump();
      final send = find.byKey(const ValueKey('report-send'));
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(find.byType(ReportSheet), findsOneWidget);
      final error = tester.widget<Text>(find.byKey(const ValueKey('report-error')));
      expect(error.data, contains(kTakedownEmail));
    });
  });

  testWidgets('the takedown sheet shows where to write', (tester) async {
    await _open(tester, _FakeReporter(ReportOutcome.sent), takedown: true);
    expect(find.text(kTakedownEmail), findsOneWidget);
    expect(find.byKey(const ValueKey('takedown-copy')), findsOneWidget);
  });
}
