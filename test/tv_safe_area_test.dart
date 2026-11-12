import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/tv_safe_area.dart';

/// docs/devices_2026_11.md: on a TV the app keeps out of the 5 % overscan
/// margins Google's TV quality guidelines name.
void main() {
  Future<EdgeInsets> paddingSeen(WidgetTester t, {required bool tv}) async {
    late EdgeInsets seen;
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(960, 540)),
      child: TvSafeArea(
        isTv: tv,
        child: Builder(builder: (c) {
          seen = MediaQuery.paddingOf(c);
          return const SizedBox();
        }),
      ),
    ));
    return seen;
  }

  testWidgets('a 960x540 TV keeps 48 dp at the sides and 27 at top and bottom',
      (t) async {
    final p = await paddingSeen(t, tv: true);
    expect(p.left, 48);
    expect(p.right, 48);
    expect(p.top, 27);
    expect(p.bottom, 27);
  });

  testWidgets('a phone or tablet is left as it is', (t) async {
    expect(await paddingSeen(t, tv: false), EdgeInsets.zero);
  });
}
