import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/transfer/presentation/qr_scan_screen.dart';

/// The QR scanner on a phone whose camera cannot be started.
///
/// Until 1.64.70 that crashed the whole app: CameraX 1.4 fails its start-up
/// when it finds no usable camera, and mobile_scanner rethrew it on the main
/// thread (device lab, 2026-10-23). The plugin copy in third_party/ now sends
/// it to the scanner's error callback as `NoCamera`, which reaches Dart as a
/// failed `start`. This is that answer, and what the screen must then show:
/// a sentence that says what to do, and no viewfinder to aim with.
const _method = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

void _phoneWithoutCamera() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_method, (call) async {
    switch (call.method) {
      case 'state':
        return 1; // camera permission already granted
      case 'start':
        // What MobileScannerHandler answers for NoCamera().
        throw PlatformException(
          code: 'MobileScanner',
          message: 'No camera found or failed to open camera!',
        );
      default:
        return null;
    }
  });
}

Future<void> _open(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    supportedLocales: AppStrings.supportedLocales,
    localizationsDelegates: AppStrings.localizationsDelegates,
    home: const QrScanScreen(),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(_phoneWithoutCamera);
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_method, null));

  for (final locale in const [Locale('en'), Locale('my'), Locale('th')]) {
    testWidgets('no camera (${locale.languageCode}): says so, and nothing to aim with',
        (tester) async {
      await _open(tester, locale);
      final s = AppStrings(locale);
      expect(tester.takeException(), isNull);
      expect(find.text(s.scanCameraUnavailable), findsOneWidget);
      expect(find.text(s.scanQrHint), findsNothing);
      expect(find.byIcon(Icons.no_photography_outlined), findsOneWidget);
      // The screen itself is still there: its title, and a way back.
      expect(find.text(s.scanSenderQr), findsOneWidget);
      expect(find.byType(BackButton), findsNothing); // pushed as home here
    });
  }
}
