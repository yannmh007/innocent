import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/subtitles/player_subtitles.dart';

// While a finger holds the subtitle (a move, a line swipe, a pinch) its line
// sits on a grey box, as MX greys it (reference lab 46047544023, 27 Nov
// 2026); the box hugs the words, not the subtitle's whole width.
void main() {
  testWidgets('the held line sits on a grey box the size of its words',
      (t) async {
    final held = ValueNotifier<bool>(false);
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(children: [
        Positioned(
          left: 0,
          width: 400,
          bottom: 20,
          child: SubtitleHeldBox(
            held: held,
            child: const Text('Line', style: TextStyle(fontSize: 20)),
          ),
        ),
      ]),
    ));
    BoxDecoration deco() => t
        .widget<DecoratedBox>(find.descendant(
            of: find.byType(SubtitleHeldBox), matching: find.byType(DecoratedBox)))
        .decoration as BoxDecoration;
    expect(deco().color, isNull);

    held.value = true;
    await t.pump();
    expect(deco().color, SubtitleHeldBox.grey);
    final box = t.getRect(find.descendant(
        of: find.byType(SubtitleHeldBox), matching: find.byType(DecoratedBox)));
    expect(box.width, lessThan(200));
    expect(box.center.dx, closeTo(200, 1));

    held.value = false;
    await t.pump();
    expect(deco().color, isNull);
    held.dispose();
  });
}
