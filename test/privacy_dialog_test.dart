// The Privacy dialog says what the app sends, in every language, and fits.
//
// WHY. Until 7 Nov 2026 it said the app "runs entirely offline" and sends
// nothing, while it sends usage records, playback requests and the account
// (docs/architecture.md). The text is longer now, so the dialog scrolls: at
// 200 % text on a small phone a plain Text is cut off, silently, on the
// one screen that must read in full.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/local_browser/presentation/local_screen.dart';

Future<void> _open(WidgetTester tester, Locale locale) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  var closed = false;
  await tester.pumpWidget(MaterialApp(
    locale: locale,
    localizationsDelegates: AppStrings.localizationsDelegates,
    supportedLocales: AppStrings.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: const TextScaler.linear(2.0)),
      child: child!,
    ),
    home: Builder(
        builder: (context) => Scaffold(
              body: privacyDialog(context, onClose: () => closed = true),
            )),
  ));
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: 'no overflow in $locale');
  // A Text too tall for its box is CLIPPED, silently: no overflow error. So
  // the check is that the whole text is laid out, which only a scroll view
  // allows on a screen this small (without it, this fails in every language).
  final body = AppStrings(locale).privacyBody;
  final rp = tester.renderObject<RenderParagraph>(find.text(body));
  expect(rp.size.height,
      greaterThanOrEqualTo(rp.getMaxIntrinsicHeight(rp.size.width) - 0.5),
      reason: 'the whole text is laid out, not cut off, in $locale');
  await tester.tap(find.byType(TextButton));
  expect(closed, isTrue);
}

void main() {
  for (final code in ['en', 'my', 'th']) {
    testWidgets('$code: it fits a small phone at 200 % text, and closes',
        (WidgetTester tester) async {
      await _open(tester, Locale(code));
    });
  }

  test('no language still says the app sends nothing', () {
    for (final code in ['en', 'my', 'th']) {
      final body = AppStrings(Locale(code)).privacyBody;
      expect(body.contains('offline'), isFalse, reason: code);
      expect(body.contains('90') || body.contains('၉၀'), isTrue,
          reason: '$code names the 90 days (Myanmar digits in my)');
    }
    expect(
        AppStrings(const Locale('en')).privacyBody, contains('usage records'));
  });

  test('every language says a record waits on the phone, and no network type',
      () {
    // A play_summary is kept on the phone until a send is known to have gone,
    // at most 7 days (SummaryOutbox, 14 Nov 2026); the network type is never
    // sent (EventSender.build: no `network_kind`).
    const waits = <String, List<String>>{
      'en': <String>['kept on this phone until it can be sent', '7 days'],
      'my': <String>['ဤဖုန်းထဲတွင် ခဏ', '၇ ရက်'],
      'th': <String>['เก็บไว้ในโทรศัพท์เครื่องนี้ชั่วคราว', '7 วัน'],
    };
    for (final MapEntry(key: code, value: words) in waits.entries) {
      final body = AppStrings(Locale(code)).privacyBody;
      for (final w in words) {
        expect(body, contains(w), reason: code);
      }
    }
    expect(AppStrings(const Locale('en')).privacyBody.contains('network type'),
        isFalse);
    expect(
        AppStrings(const Locale('my'))
            .privacyBody
            .contains('network အမျိုးအစား'),
        isFalse);
    expect(AppStrings(const Locale('th')).privacyBody.contains('เครือข่าย'),
        isFalse);
  });
}
