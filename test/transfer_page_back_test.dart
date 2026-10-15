import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/transfer/presentation/transfer_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Transfer opened as its own page (from Me): system Back from Receive goes
/// to Transfer's home first, as the arrow in the corner does, and only then
/// leaves the page. It used to leave the page at once.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets('Back on the Transfer page: Receive → home → out', (t) async {
    // Every plugin the page touches answers nothing.
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final c in <String>[
      'mx_clone/transfer',
      'mx_clone/wifi_direct',
      'mx_clone/pip',
      'plugins.flutter.io/path_provider',
      'dev.fluttercommunity.plus/network_info',
      'dev.fluttercommunity.plus/connectivity',
    ]) {
      m.setMockMethodCallHandler(MethodChannel(c), (_) async => null);
    }
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(ProviderScope(
      child: MaterialApp(
        navigatorKey: nav,
        localizationsDelegates: AppStrings.localizationsDelegates,
        supportedLocales: AppStrings.supportedLocales,
        home: const Scaffold(body: Text('Me')),
      ),
    ));
    nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const TransferScreen()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    await t.tap(find.byKey(const ValueKey('transfer-receive')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('transfer-receive')), findsNothing);

    // System Back: home of the page, not out of it.
    await t.binding.handlePopRoute();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(TransferScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('transfer-receive')), findsOneWidget);

    // Again: now it leaves.
    await t.binding.handlePopRoute();
    await t.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.byType(TransferScreen), findsNothing);
    expect(find.text('Me'), findsOneWidget);
  });
}
