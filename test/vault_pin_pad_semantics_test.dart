import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/features/private_folder/presentation/vault_pin_pad.dart';

/// The vault's PIN pad as TalkBack reads it: one key, one digit.
///
/// Each key carried the digit as its label AND its own Text children, so a
/// screen reader announced "1, 1" and "2, 2, ABC", and a UI test looking for
/// the key "1" found none (device lab run 41101805278).
void main() {
  testWidgets('every digit key is a button named by its digit alone',
      (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      home: Scaffold(
          body: VaultPinPad(title: 'T', subtitle: 'S', onSubmit: (_) {})),
    ));
    await tester.pump(const Duration(seconds: 1));
    for (final d in <String>[
      '0',
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9'
    ]) {
      final node = find.bySemanticsLabel(d);
      expect(node, findsOneWidget, reason: 'key $d');
      final data = tester.getSemantics(node).getSemanticsData();
      expect(data.label, d);
      expect(data.hasFlag(SemanticsFlag.isButton), isTrue, reason: 'key $d');
    }
    handle.dispose();
  });

  testWidgets('a key still types its digit', (tester) async {
    String? submitted;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      home: Scaffold(
          body: VaultPinPad(
              title: 'T',
              subtitle: 'S',
              autoSubmitLengths: const <int>{4},
              onSubmit: (v) => submitted = v)),
    ));
    await tester.pump(const Duration(seconds: 1));
    for (final d in <String>['1', '3', '5', '7']) {
      await tester.tap(find.bySemanticsLabel(d));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 500));
    expect(submitted, '1357');
  });
}
