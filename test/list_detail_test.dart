// Settings on a wide window: the list and the open page side by side
// (core/ui/list_detail.dart, docs/devices_2026_11.md Phase 2), and a phone
// exactly as before.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/localization/app_strings.dart';
import 'package:innocent/core/theme/app_theme.dart';
import 'package:innocent/core/ui/list_detail.dart';
import 'package:innocent/features/me/presentation/app_theme_screen.dart';
import 'package:innocent/features/settings/presentation/player_controls_screen.dart';
import 'package:innocent/features/settings/presentation/settings_player_screen.dart';
import 'package:innocent/features/settings/presentation/settings_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Settings pushed over a first page, as Me and the Video tab open it, on a
/// window [size] dp.
Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      theme: AppTheme.dark,
      locale: const Locale('en'),
      localizationsDelegates: AppStrings.localizationsDelegates,
      supportedLocales: AppStrings.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen())),
              child: const Text('open settings'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open settings'));
  await _settle(tester);
}

/// Frames, not pumpAndSettle: some settings pages animate for ever.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Focus on the first focusable thing inside [area], as a D-pad press
/// would put it there.
void _focusInside(Finder area) {
  final inside = area.evaluate().first;
  for (final node in FocusManager.instance.rootScope.descendants) {
    final c = node.context;
    if (c == null || !node.canRequestFocus || node.skipTraversal) continue;
    var found = false;
    c.visitAncestorElements((e) {
      if (e == inside) found = true;
      return !found;
    });
    if (found) {
      node.requestFocus();
      return;
    }
  }
  fail('nothing focusable inside $area');
}

/// Whether the primary focus is inside [area].
bool _focusedIn(Finder area) {
  final c = FocusManager.instance.primaryFocus?.context;
  if (c == null) return false;
  final targets = area.evaluate().toSet();
  if (targets.contains(c)) return true;
  var found = false;
  c.visitAncestorElements((e) {
    if (targets.contains(e)) found = true;
    return !found;
  });
  if (found) return true;
  // The row's text sits beside, not above, its InkWell's focus: look down
  // from the focused element too.
  var below = false;
  void visit(Element e) {
    if (below) return;
    if (targets.contains(e)) {
      below = true;
      return;
    }
    e.visitChildren(visit);
  }
  (c as Element).visitChildren(visit);
  return below;
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('two panes from 840 dp: Material expanded width', () {
    expect(ListDetail.minWidth, 840);
    expect(
        ListDetail.listWidth(761), 360); // a foldable turned, beside the rail
    expect(ListDetail.listWidth(1280), 400);
    expect(ListDetail.listWidth(1050), closeTo(378, 0.01));
  });

  testWidgets('a phone: the list, and a page pushed over it', (tester) async {
    await _pump(tester, const Size(400, 800));
    expect(find.byType(DetailNavigator), findsNothing);
    expect(find.byType(AppThemeScreen), findsNothing);

    await tester.tap(find.text('Player'));
    await _settle(tester);
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);
    // Over the list, not beside it.
    expect(find.text('App Theme'), findsNothing);

    await _back(tester);
    expect(find.byType(SettingsPlayerScreen), findsNothing);
    expect(find.text('App Theme'), findsOneWidget);
  });

  testWidgets('839 dp is still one pane, 840 is two', (tester) async {
    await _pump(tester, const Size(839, 800));
    expect(find.byType(DetailNavigator), findsNothing);
    tester.view.physicalSize = const Size(840, 800);
    await _settle(tester);
    expect(find.byType(DetailNavigator), findsOneWidget);
  });

  testWidgets(
      'wide: the first page beside the list; a row opens its page there, '
      'a page opened from it opens in the pane, Back closes it first',
      (tester) async {
    await _pump(tester, const Size(1280, 800));
    // The first page is open beside the list.
    expect(find.byType(AppThemeScreen), findsOneWidget);
    expect(find.text('Player'), findsOneWidget);

    await tester.tap(find.text('Player'));
    await _settle(tester);
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);
    expect(find.byType(AppThemeScreen), findsNothing);
    // The list is still there beside it.
    expect(find.text('Decoder'), findsOneWidget);
    // The page at the bottom of the pane has no back arrow; the list's
    // bar has Settings' own.
    expect(
        find.descendant(
            of: find.byType(SettingsPlayerScreen),
            matching: find.byType(BackButton)),
        findsNothing);

    // Player → Controls opens in the pane, with its back arrow.
    await tester.tap(find.text('Controls'));
    await _settle(tester);
    expect(find.byType(PlayerControlsScreen), findsOneWidget);
    expect(find.text('Decoder'), findsOneWidget);
    expect(
        find.descendant(
            of: find.byType(PlayerControlsScreen),
            matching: find.byType(BackButton)),
        findsOneWidget);

    // Back closes Controls, not Settings.
    await _back(tester);
    expect(find.byType(PlayerControlsScreen), findsNothing);
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);

    // Then Back leaves Settings.
    await _back(tester);
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.text('open settings'), findsOneWidget);
  });

  testWidgets('wide: the open row tapped again takes its pane back to its top',
      (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.text('Player'));
    await _settle(tester);
    await tester.tap(find.text('Controls'));
    await _settle(tester);
    expect(find.byType(PlayerControlsScreen), findsOneWidget);
    await tester.tap(find.text('Player').first);
    await _settle(tester);
    expect(find.byType(PlayerControlsScreen), findsNothing);
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);
  });

  testWidgets(
      'wide: a choice dialog from a page in the pane closes itself, '
      'not the page under it', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.text('Player'));
    await _settle(tester);
    final row = find.text('Controls auto-hide delay');
    await tester.scrollUntilVisible(row, 200,
        scrollable: find
            .descendant(
                of: find.byType(SettingsPlayerScreen),
                matching: find.byType(Scrollable))
            .first);
    await tester.tap(row);
    await _settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('8'));
    await _settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets(
      'a window narrowed to one pane keeps the page the person opened; '
      'the first page shown by default is not pushed', (tester) async {
    await _pump(tester, const Size(1280, 800));
    // Nothing picked yet: narrowing shows the list.
    tester.view.physicalSize = const Size(700, 800);
    await _settle(tester);
    expect(find.byType(AppThemeScreen), findsNothing);
    expect(find.text('Player'), findsOneWidget);

    tester.view.physicalSize = const Size(1280, 800);
    await _settle(tester);
    await tester.tap(find.text('Player'));
    await _settle(tester);
    tester.view.physicalSize = const Size(700, 800);
    await _settle(tester);
    // The Player page, over the list as on a phone.
    expect(find.byType(SettingsPlayerScreen), findsOneWidget);
    expect(find.byType(DetailNavigator), findsNothing);
    await _back(tester);
    expect(find.byType(SettingsPlayerScreen), findsNothing);
    expect(find.text('Player'), findsOneWidget);
  });

  testWidgets(
      'wide, by D-pad: Back from the page goes to its row, then leaves; '
      'by touch it leaves at once', (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.text('Player'));
    await _settle(tester);
    // A key press: Flutter's focus is the D-pad's from here (traditional).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    _focusInside(find.byType(SettingsPlayerScreen));
    await _settle(tester);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.traditional);

    await _back(tester);
    expect(find.byType(SettingsScreen), findsOneWidget,
        reason: 'Back from the page left Settings');
    expect(_focusedIn(find.byType(SettingsPlayerScreen)), isFalse);
    expect(_focusedIn(find.text('Player').first), isTrue,
        reason: 'focus is not on the open row');

    await _back(tester);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('wide, by touch: Back from the page leaves Settings',
      (tester) async {
    await _pump(tester, const Size(1280, 800));
    await tester.tap(find.text('Player'));
    await _settle(tester);
    _focusInside(find.byType(SettingsPlayerScreen));
    await _settle(tester);
    expect(FocusManager.instance.highlightMode, FocusHighlightMode.touch);
    await _back(tester);
    expect(find.byType(SettingsScreen), findsNothing);
  });

  testWidgets('wide: TalkBack reaches the list beside the page',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, const Size(1280, 800));
    expect(find.bySemanticsLabel('Decoder'), findsOneWidget);
    expect(find.bySemanticsLabel('Diagnostics'), findsOneWidget);
    semantics.dispose();
  });
}
