import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';

/// The owner, against MX: "a touch has to land exactly on the seek bar".
/// The bar must take a touch anywhere in a band about 44 dp tall.
Widget _bar(ValueChanged<double> onChanged,
        {SliderComponentShape? overlay}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            // As in the player: a Row in a min-size Column, so the slider's
            // height is its own (the tallest of its parts), not the screen's.
            child: Column(mainAxisSize: MainAxisSize.min, children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 2.5,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5.5),
                overlayShape: overlay ?? const SeekBandShape(),
              ),
              child: Slider(value: 0.5, onChanged: onChanged),
            ),
            ]),
          ),
        ),
      ),
    );

void main() {
  testWidgets('the seek bar is 44 dp tall', (tester) async {
    await tester.pumpWidget(_bar((_) {}));
    expect(tester.getSize(find.byType(Slider)).height, 44);
  });

  testWidgets('a touch 18 dp above the line seeks', (tester) async {
    double? got;
    await tester.pumpWidget(_bar((v) => got = v));
    final r = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(r.left + r.width * 0.2, r.center.dy - 18));
    await tester.pump();
    expect(got, isNotNull);
    expect(got, lessThan(0.3));
  });

  testWidgets('a touch 18 dp below the line seeks', (tester) async {
    double? got;
    await tester.pumpWidget(_bar((v) => got = v));
    final r = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(r.left + r.width * 0.8, r.center.dy + 18));
    await tester.pump();
    expect(got, greaterThan(0.7));
  });

  testWidgets('without the band the same touch misses (the old bar)',
      (tester) async {
    double? got;
    await tester.pumpWidget(
        _bar((v) => got = v, overlay: SliderComponentShape.noOverlay));
    final r = tester.getRect(find.byType(Slider));
    await tester.tapAt(Offset(r.left + r.width * 0.2, r.center.dy - 18));
    await tester.pump();
    expect(got, isNull);
  });
}
