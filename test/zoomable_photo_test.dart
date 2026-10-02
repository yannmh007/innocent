import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/presentation/widgets/zoomable_photo.dart';

/// The album viewer: a PageView of zoomable photos, wired the way
/// album_viewer_screen.dart wires it.
class _Album extends StatefulWidget {
  const _Album();
  @override
  State<_Album> createState() => _AlbumState();
}

class _AlbumState extends State<_Album> {
  final controller = PageController();
  bool locked = false;
  int page = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: PageView.builder(
        controller: controller,
        itemCount: 3,
        physics: locked ? const NeverScrollableScrollPhysics() : null,
        onPageChanged: (i) => setState(() {
          page = i;
          locked = false;
        }),
        itemBuilder: (_, i) => ZoomablePhoto(
          key: ValueKey('p$i'),
          onLockPaging: (l) => setState(() => locked = l),
          child: Container(color: Colors.primaries[i], width: 400, height: 400),
        ),
      ),
    );
  }
}

ZoomablePhotoState _photo(WidgetTester t, int i) =>
    t.state<ZoomablePhotoState>(find.byKey(ValueKey('p$i')));

void main() {
  testWidgets('a pinch zooms the photo and does not turn the page', (t) async {
    await t.pumpWidget(const _Album());
    final album = t.state<_AlbumState>(find.byType(_Album));
    final c = t.getCenter(find.byKey(const ValueKey('p0')));
    // A LOPSIDED PINCH, the way a thumb and finger really do it: the first
    // finger lands and barely moves, the second lands and sweeps sideways.
    // To the page swipe that second finger is a sideways drag — the case
    // that used to turn the page instead of zooming.
    final a = await t.startGesture(c - const Offset(20, 0));
    await a.moveBy(const Offset(-4, 0));
    await t.pump();
    final b = await t.startGesture(c + const Offset(20, 0));
    await t.pump();
    for (var k = 0; k < 10; k++) {
      await a.moveBy(const Offset(-1, 0));
      await b.moveBy(const Offset(14, 0));
      await t.pump();
    }
    await a.up();
    await b.up();
    await t.pumpAndSettle();
    expect(_photo(t, 0).scale, greaterThan(1.5));
    expect(album.page, 0, reason: 'the page must not change during a pinch');
    expect(album.locked, isTrue, reason: 'zoomed: paging stays off');
  });

  testWidgets('a one-finger drag on a zoomed photo pans it; at 100% it pages',
      (t) async {
    await t.pumpWidget(const _Album());
    final album = t.state<_AlbumState>(find.byType(_Album));
    final c = t.getCenter(find.byKey(const ValueKey('p0')));
    // Double-tap to zoom in.
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(c);
    await t.pumpAndSettle();
    expect(_photo(t, 0).scale, closeTo(2.5, 0.01));
    await t.dragFrom(c, const Offset(-300, 0));
    await t.pumpAndSettle();
    expect(album.page, 0, reason: 'zoomed: the drag moved the photo');
    // Double-tap back out, and the same drag turns the page.
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(c);
    await t.pumpAndSettle();
    expect(_photo(t, 0).scale, closeTo(1, 0.01));
    expect(album.locked, isFalse);
    await t.fling(find.byKey(const ValueKey('p0')), const Offset(-400, 0), 2000);
    await t.pumpAndSettle();
    expect(album.page, 1);
  });
}
