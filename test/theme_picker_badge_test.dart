// The Light card must say "Coming soon", and must keep saying it.
//
// WHY THIS IS A TEST AND NOT JUST A STRING. `AppTheme.light` returns the dark
// theme (see app_theme.dart), so choosing Light changes nothing on screen.
// That is the correct behaviour — the alternative is ~388 invisible strings —
// but it is only *honest* while the card says so. The badge is the entire
// user-facing half of that decision, and it is one line of UI that a future
// refactor of this screen would drop without noticing.
//
// The width case is here because the badge is positioned inside a card that is
// one third of the row: "Coming soon" is materially longer than the "Using"
// and "NEW" the card was built for, and a RenderFlex overflow would be a
// yellow-and-black stripe across a settings screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/services/preferences/preferences_service.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/features/me/presentation/app_theme_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pumpPicker(WidgetTester tester, {required Size size}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: AppTheme.dark,
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: const AppThemeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('the Light card is badged "Coming soon"',
      (WidgetTester tester) async {
    await _pumpPicker(tester, size: const Size(400, 900));
    expect(find.text('Coming soon'), findsOneWidget);
  });

  testWidgets('it still says so once Light is the selected mode',
      (WidgetTester tester) async {
    // The regression this guards: swapping the badge for 'Using' when
    // selected. That would hide the explanation at exactly the moment the
    // user has chosen Light, seen nothing change, and wants to know why.
    // Selection stays legible without it — the card draws a blue border.
    SharedPreferences.setMockInitialValues(
        <String, Object>{'theme_mode': AppThemeMode.light.name});
    await _pumpPicker(tester, size: const Size(400, 900));

    expect(find.text('Coming soon'), findsOneWidget);
    expect(find.text('Light Theme'), findsOneWidget);
  });

  testWidgets('the badge does not overflow a narrow phone',
      (WidgetTester tester) async {
    // 320dp is the narrowest Android phone width still in the wild. The card
    // is one third of that minus padding and two gaps.
    await _pumpPicker(tester, size: const Size(320, 800));

    expect(find.text('Coming soon'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
