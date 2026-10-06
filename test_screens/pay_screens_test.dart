import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/account.dart';
import 'package:innocent/features/video_hub/presentation/account/premium_request_screen.dart';
import 'package:innocent/features/video_hub/presentation/account/receipt_picker.dart';
import 'package:innocent/features/video_hub/presentation/account_provider.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_theme.dart';

import 'harness.dart';

// The payment screen with the receipt screenshot as the proof (migration
// 040), and the picker with a receipt chosen.
void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  pay() => [
        paymentInstructionsProvider.overrideWith((ref) async => const PaymentInstructions(
              payeeName: 'Innocent',
              payeeNumber: '09 123 456 789',
              prices: {'monthly': '10,500 MMK', 'yearly': '100,000 MMK'},
            )),
      ];

  screens('pay', () => const PremiumRequestScreen(planId: 'monthly'),
      overrides: pay, scrolls: 1);

  // After sending: what happens next.
  screens('pay_sent',
      () => const PremiumRequestScreen(planId: 'monthly', startSubmitted: true),
      overrides: pay, phones: const [small]);

  Uint8List? receipt;
  setUpAll(() async {
    // A synthetic receipt: a white card with a green tick band.
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawRect(const Rect.fromLTWH(0, 0, 360, 780), Paint()..color = Colors.white);
    c.drawRect(const Rect.fromLTWH(0, 0, 360, 220), Paint()..color = const Color(0xFF0B63CE));
    c.drawCircle(const Offset(180, 110), 46, Paint()..color = Colors.white);
    final img = await rec.endRecording().toImage(360, 780);
    receipt = (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
  });
  screens(
      'pay_receipt',
      () => Scaffold(
            backgroundColor: VH.canvas,
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 48, 16, 16),
              child: ReceiptPicker(selected: receipt, onChanged: (_) {}),
            ),
          ),
      phones: const [small]);
}
