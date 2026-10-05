import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/device_profile.dart';
import 'package:innocent/core/ui/tv_focus.dart';

Widget _app(Widget body) => MaterialApp(
      builder: (_, child) => FocusRingLayer(child: child!),
      home: Scaffold(body: Center(child: body)),
    );

DecoratedBox? _ring(WidgetTester t) {
  final f = find.descendant(
    of: find.byType(IgnorePointer),
    matching: find.byType(DecoratedBox),
  );
  return f.evaluate().isEmpty ? null : t.widget<DecoratedBox>(f.first);
}

void main() {
  testWidgets('a D-pad reaches a RemoteTappable and select taps it',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_app(Row(mainAxisSize: MainAxisSize.min, children: [
      RemoteTappable(onTap: () => taps++, child: const SizedBox(width: 80, height: 60)),
      RemoteTappable(onTap: () => taps += 10, child: const SizedBox(width: 80, height: 60)),
    ])));
    // Nothing focused yet: Tab (or the D-pad) moves to the first one.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(taps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(taps, 11);
  });

  testWidgets('menu key long-presses; RemoteFocusable keeps the touch handler',
      (tester) async {
    var taps = 0, menus = 0, downs = 0;
    await tester.pumpWidget(_app(Row(mainAxisSize: MainAxisSize.min, children: [
      RemoteTappable(
          onTap: () => taps++,
          onLongPress: () => menus++,
          child: const SizedBox(width: 80, height: 60)),
      RemoteFocusable(
        onActivate: () => taps += 10,
        onMenu: () => menus += 10,
        child: GestureDetector(
          key: const Key('pressable'),
          onTapDown: (_) => downs++,
          onTap: () => taps += 100,
          child: const ColoredBox(
              color: Colors.red, child: SizedBox(width: 80, height: 60)),
        ),
      ),
    ])));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(menus, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    await tester.pump();
    expect(taps, 10);
    expect(menus, 11);
    // Touch still goes through the original detector, pressed state and all.
    await tester.tap(find.byKey(const Key('pressable')));
    await tester.pump();
    expect(downs, 1);
    expect(taps, 110);
  });

  testWidgets('the ring follows remote focus and never shows for touch',
      (tester) async {
    await tester.pumpWidget(_app(Column(mainAxisSize: MainAxisSize.min, children: [
      IconButton(onPressed: () {}, icon: const Icon(Icons.play_arrow)),
      RemoteTappable(onTap: () {}, child: const SizedBox(width: 80, height: 60)),
    ])));
    // Touch first: no ring.
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(_ring(tester), isNull);
    // A key press switches to remote mode: the focused button gets a ring.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_ring(tester), isNotNull);
  });

  test('600 dp is where a phone becomes a tablet', () {
    expect(DeviceProfile.classify(411), DeviceKind.phone);
    expect(DeviceProfile.classify(599.9), DeviceKind.phone);
    expect(DeviceProfile.classify(600), DeviceKind.tablet);
    expect(DeviceProfile.classify(null), DeviceKind.phone);
  });

  test('only phones are portrait-locked', () {
    DeviceProfile.kind = DeviceKind.phone;
    expect(DeviceProfile.appOrientations, [DeviceOrientation.portraitUp]);
    DeviceProfile.kind = DeviceKind.tablet;
    expect(DeviceProfile.appOrientations, isEmpty);
    DeviceProfile.kind = DeviceKind.tv;
    expect(DeviceProfile.appOrientations, isEmpty);
    DeviceProfile.kind = DeviceKind.phone;
  });
}
