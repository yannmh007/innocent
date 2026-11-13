// The D-pad leaves a text field (core/ui/tv_focus.dart, DpadLeavesTextFields).
// Flutter keeps a focused single-line field's arrows for its caret, so on a
// TV a search field the remote landed in held the D-pad for good (probed on
// 3.32.8, 13 Nov: ↓ ↑ ← → all stayed in the field).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/tv_focus.dart';

final _field = FocusNode(debugLabel: 'field');
final _above = FocusNode(debugLabel: 'above');
final _below = FocusNode(debugLabel: 'below');
final _left = FocusNode(debugLabel: 'left');
final _right = FocusNode(debugLabel: 'right');

/// A search-shaped screen: a button above, the field between two buttons,
/// a result below; the field [multiLine] or not, on a TV or not.
Future<TextEditingController> _pump(WidgetTester tester,
    {required bool tv, bool multiLine = false}) async {
  final text = TextEditingController(text: 'abc');
  addTearDown(text.dispose);
  await tester.pumpWidget(MaterialApp(
    builder: (context, app) => DpadLeavesTextFields(tv: tv, child: app!),
    home: Scaffold(
      body: Column(children: [
        TextButton(focusNode: _above, onPressed: () {}, child: const Text('A')),
        Row(children: [
          TextButton(focusNode: _left, onPressed: () {}, child: const Text('L')),
          Expanded(
            child: TextField(
              focusNode: _field,
              controller: text,
              maxLines: multiLine ? 3 : 1,
            ),
          ),
          TextButton(
              focusNode: _right, onPressed: () {}, child: const Text('R')),
        ]),
        TextButton(focusNode: _below, onPressed: () {}, child: const Text('B')),
      ]),
    ),
  ));
  _field.requestFocus();
  await tester.pump();
  return text;
}

Future<String?> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
  return FocusManager.instance.primaryFocus?.debugLabel;
}

void main() {
  // One direction a test: the traversal policy remembers the last move, and
  // the opposite key returns to where focus came from.
  testWidgets('↓ leaves a single-line field, on any device', (tester) async {
    await _pump(tester, tv: false);
    expect(await _press(tester, LogicalKeyboardKey.arrowDown), 'below');
  });

  testWidgets('↑ leaves a single-line field, on any device', (tester) async {
    await _pump(tester, tv: false);
    expect(await _press(tester, LogicalKeyboardKey.arrowUp), 'above');
  });

  testWidgets('on a TV ← moves the caret inside, and leaves from the start',
      (tester) async {
    final text = await _pump(tester, tv: true);
    text.selection = const TextSelection.collapsed(offset: 1);
    await tester.pump();
    expect(await _press(tester, LogicalKeyboardKey.arrowLeft), 'field');
    expect(text.selection.baseOffset, 0);
    expect(await _press(tester, LogicalKeyboardKey.arrowLeft), 'left');
  });

  testWidgets('on a TV → leaves from the end', (tester) async {
    final text = await _pump(tester, tv: true);
    text.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();
    expect(await _press(tester, LogicalKeyboardKey.arrowRight), 'right');
  });

  testWidgets('with a keyboard, ← and → stay in the field', (tester) async {
    final text = await _pump(tester, tv: false);
    text.selection = const TextSelection.collapsed(offset: 0);
    await tester.pump();
    expect(await _press(tester, LogicalKeyboardKey.arrowLeft), 'field');
  });

  testWidgets('a multi-line field keeps its arrows', (tester) async {
    await _pump(tester, tv: true, multiLine: true);
    expect(await _press(tester, LogicalKeyboardKey.arrowDown), 'field');
  });
}
