// Where Android turns the screen as the device does whatever the app asks —
// a TV, a tablet on Android 16 now that the app targets 36 — the player's
// rotate shortcut and its orientation settings do nothing, so they are not
// offered (DeviceProfile.orientationFixed, docs/target_sdk_36.md).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/ui/device_profile.dart';
import 'package:innocent/features/player/presentation/shortcut_item.dart';
import 'package:innocent/features/settings/presentation/player_screen_settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() {
    DeviceProfile.kind = DeviceKind.phone;
    DeviceProfile.sdk = 0;
  });

  test('the rule: a TV; a tablet from Android 16; never a phone', () {
    for (final (kind, sdk, fixed) in <(DeviceKind, int, bool)>[
      (DeviceKind.phone, 36, false),
      (DeviceKind.tablet, 35, false),
      (DeviceKind.tablet, 36, true),
      (DeviceKind.tv, 30, true),
    ]) {
      DeviceProfile.kind = kind;
      DeviceProfile.sdk = sdk;
      expect(DeviceProfile.orientationFixed, fixed, reason: '$kind $sdk');
    }
  });

  test('Screen rotation is offered only where it turns the screen', () {
    expect(ShortcutItem.available(orientationFixed: false),
        contains(ShortcutItem.screenRotation));
    expect(ShortcutItem.available(orientationFixed: true),
        isNot(contains(ShortcutItem.screenRotation)));
    expect(ShortcutItem.available(orientationFixed: true).length,
        ShortcutItem.values.length - 1);
  });

  for (final fixed in [false, true]) {
    testWidgets(
        'Settings → Player → Screen ${fixed ? 'hides' : 'offers'} the '
        'orientation settings', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      DeviceProfile.kind = fixed ? DeviceKind.tv : DeviceKind.phone;
      await tester.pumpWidget(ProviderScope(
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppStrings.localizationsDelegates,
          supportedLocales: AppStrings.supportedLocales,
          home: const PlayerScreenSettingsScreen(),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 300));
      final s = AppStrings.of(
          tester.element(find.byType(PlayerScreenSettingsScreen)));
      expect(find.text(s.pssDefaultOrientation),
          fixed ? findsNothing : findsOneWidget);
      expect(
          find.text(s.pssAutoRotation), fixed ? findsNothing : findsOneWidget);
      // The rest of the page is there either way.
      expect(find.text(s.pssKeepOn), findsOneWidget);
    });
  }
}
