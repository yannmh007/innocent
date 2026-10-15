import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/services/adb/adb_service.dart';
import 'package:innocent/features/android_data/presentation/android_data_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Hidden files opened without ADB: it says so within seconds, instead of
/// a spinner that waited on two thirty-second reconnects.
const _channel = MethodChannel('mx_clone/adb');

/// Every command the screen sent, and how the fake phone answers.
final List<String> _sent = <String>[];
String _answer = 'ERROR: not connected';
Completer<String>? _hold;

void _fake() {
  _sent.clear();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async {
    switch (call.method) {
      case 'lastConnect':
        return '127.0.0.1:37123';
      case 'adbSetupState':
        return <String, Object>{'wifi': true, 'wirelessDebugging': false};
      case 'shell':
        final cmd = (call.arguments as Map)['command'] as String;
        _sent.add(cmd);
        final hold = _hold;
        if (hold != null) return hold.future;
        if (cmd.startsWith('echo ok')) {
          return _answer.startsWith('ERROR') ? _answer : 'ok';
        }
        return _answer.startsWith('ERROR') ? _answer : '';
      default:
        return null;
    }
  });
}

Future<void> _open(WidgetTester t) async {
  await t.pumpWidget(const ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      home: AndroidDataScreen(),
    ),
  ));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdbService.instance.live.value = null;
    AdbService.instance.pairingNeeded.value = false;
    _answer = 'ERROR: not connected';
    _hold = null;
    _fake();
  });

  testWidgets('no connection: the card, at once, and no folder listing',
      (t) async {
    await _open(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(find.text('Hidden files need ADB'), findsOneWidget);
    expect(find.text('Connect ADB'), findsOneWidget);
    expect(find.text('Check again'), findsOneWidget);
    // Where the phone stands: Wireless debugging is off, with its switch.
    expect(find.text('Wireless debugging'), findsOneWidget);
    expect(find.text('Turn on'), findsOneWidget);
    // Only the short probe was sent — no `find` that waits on a reconnect.
    expect(_sent.where((c) => c.startsWith('find ')), isEmpty);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('while the probe is out, the wait is said in words', (t) async {
    _hold = Completer<String>();
    await _open(t);
    await t.pump();
    expect(find.text('Checking the connection…'), findsOneWidget);
    expect(find.text('Hidden files need ADB'), findsNothing);
    _hold!.complete('ERROR: not connected');
    await t.pump();
    await t.pump();
    expect(find.text('Hidden files need ADB'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('the connection comes back: the files open by themselves',
      (t) async {
    await _open(t);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
    expect(find.text('Hidden files need ADB'), findsOneWidget);

    _answer = 'ok';
    // The card asks every four seconds.
    await t.pump(const Duration(seconds: 4));
    await t.pump();
    await t.pump();
    expect(find.text('Hidden files need ADB'), findsNothing);
    expect(_sent.where((c) => c.startsWith('find ')), isNotEmpty);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('known to be connected: straight to the files, no probe',
      (t) async {
    AdbService.instance.live.value = true;
    _answer = 'ok';
    await _open(t);
    await t.pump();
    expect(find.text('Hidden files need ADB'), findsNothing);
    expect(_sent.first, startsWith('find '));
    await t.pumpWidget(const SizedBox());
  });
}
