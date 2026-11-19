// The seek bar's pictures on the ladder: how many fetches are on their way
// (19 Nov 2026). One at a time, the picture of where the finger stopped
// waited behind the fetch before it; two let it start as soon as one is
// free. Either way the newest moment replaces any that waited.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/ladder_preview_loader.dart';

void main() {
  late List<int> asked;
  late Map<int, Completer<Uint8List?>> pending;

  Future<Uint8List?> fetch(Duration at) {
    asked.add(at.inSeconds);
    return (pending[at.inSeconds] = Completer<Uint8List?>()).future;
  }

  setUp(() {
    asked = <int>[];
    pending = <int, Completer<Uint8List?>>{};
  });

  test(
      'two on their way: the second starts at once, the newest waits for a slot',
      () async {
    final l = LadderPreviewLoader(fetch, maxInFlight: 2);
    final shown = <int>[];
    l.request(100, (b) => shown.add(b.first));
    l.request(110, (b) => shown.add(b.first));
    l.request(120, (b) => shown.add(b.first));
    l.request(130, (b) => shown.add(b.first)); // replaces 120
    expect(asked, [100, 110]);
    pending[110]!.complete(Uint8List.fromList([11]));
    await Future<void>.delayed(Duration.zero);
    expect(asked, [100, 110, 130],
        reason: 'the newest, not the one it replaced');
    pending[100]!.complete(Uint8List.fromList([10]));
    pending[130]!.complete(Uint8List.fromList([13]));
    await Future<void>.delayed(Duration.zero);
    expect(shown, contains(13));
    l.dispose();
  });

  test('one at a time, as before: the next waits for the one on its way',
      () async {
    final l = LadderPreviewLoader(fetch);
    l.request(100, (_) {});
    l.request(110, (_) {});
    l.request(120, (_) {});
    expect(asked, [100]);
    pending[100]!.complete(Uint8List.fromList([1]));
    await Future<void>.delayed(Duration.zero);
    expect(asked, [100, 120]);
    pending[120]!.complete(null);
    await Future<void>.delayed(Duration.zero);
    l.dispose();
  });

  test('the same two-second fragment again is given, not fetched', () async {
    final l = LadderPreviewLoader(fetch, maxInFlight: 2);
    final shown = <int>[];
    l.request(100, (b) => shown.add(b.first));
    pending[100]!.complete(Uint8List.fromList([5]));
    await Future<void>.delayed(Duration.zero);
    l.request(101, (b) => shown.add(b.first));
    await Future<void>.delayed(Duration.zero);
    expect(asked, [100]);
    expect(shown, [5, 5]);
    l.dispose();
  });
}
