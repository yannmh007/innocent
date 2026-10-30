import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pattern the Local Network browser's "Media only" filter uses
/// (net_browser_screen.dart): an IconButton whose on/off state was shown
/// only by its icon. TalkBack must hear one control — the button's name,
/// that it is a button, and whether it is on.
void main() {
  testWidgets('a toggled icon button is one node: name, button, on/off',
      (tester) async {
    var on = false;
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(
        builder: (context, setState) => Scaffold(
          appBar: AppBar(actions: <Widget>[
            MergeSemantics(
              child: Semantics(
                toggled: on,
                child: IconButton(
                  tooltip: 'Media only',
                  icon: const Icon(Icons.video_library_outlined),
                  onPressed: () => setState(() => on = !on),
                ),
              ),
            ),
          ]),
        ),
      ),
    ));
    // What TalkBack gets: the merged node's data, the button folded in.
    final node = tester
        .getSemantics(find.byType(MergeSemantics).last)
        .getSemanticsData();
    // Tooltip names a button through the tooltip property, which TalkBack
    // reads as its name.
    expect('${node.label}${node.tooltip}', contains('Media only'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    expect(node.hasFlag(SemanticsFlag.isToggled), isFalse);

    await tester.tap(find.byType(IconButton));
    await tester.pump();
    final after = tester
        .getSemantics(find.byType(MergeSemantics).last)
        .getSemanticsData();
    expect(after.hasFlag(SemanticsFlag.isToggled), isTrue);
    handle.dispose();
  });
}
