import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/mpv_link.dart';

/// A libmpv stand-in: answers at once, or hangs the way a core stuck in a
/// hardware decoder does, until [release] is called.
class _FakeMpv {
  final Map<String, String> props = <String, String>{'pause': 'no'};
  final List<List<Object?>> seen = <List<Object?>>[];
  Completer<void>? _hang;

  void hang() => _hang = Completer<void>();
  void release() {
    _hang?.complete();
    _hang = null;
  }

  Future<Object?> call(List<Object?> r) async {
    seen.add(r);
    final h = _hang;
    if (h != null) await h.future;
    if (r[0] == 'get') return props[r[2]];
    props[r[2] as String] = r[3] as String;
    return (r[2] as String).startsWith('bad') ? -5 : 0;
  }
}

void main() {
  test('reads and writes pass straight through, with libmpv\'s verdict', () async {
    final mpv = _FakeMpv();
    final link = MpvLink(runner: mpv.call);
    expect(await link.get(1, 'pause'), 'no');
    expect(await link.set(1, 'pause', 'yes'), isTrue);
    expect(mpv.props['pause'], 'yes');
    expect(await link.set(1, 'bad-option', 'x'), isFalse,
        reason: 'a refused write is not reported as applied');
    expect(link.wedged, isFalse);
  });

  const t = Duration(milliseconds: 120);
  Future<void> wait([int ms = 200]) => Future<void>.delayed(Duration(milliseconds: ms));

  test('a call that hangs marks the engine stuck, and nothing else is sent', () async {
    final mpv = _FakeMpv()..hang();
    final link = MpvLink(timeout: t, runner: mpv.call);
    final changes = <bool>[];
    link.wedgedChanges.listen(changes.add);
    String? got = 'unset';
    final pending = link.get(1, 'pause').then((v) => got = v);
    await wait(40);
    expect(link.wedged, isFalse, reason: 'slow is not stuck yet');
    await wait();
    expect(link.wedged, isTrue);
    expect(link.wedgedOn, 'get pause');
    // While stuck, a write is refused here instead of joining the queue.
    expect(await link.set(1, 'volume', '50'), isFalse);
    expect(mpv.seen.length, 1);
    expect(changes, <bool>[true]);
    mpv.release();
    await pending;
    expect(got, isNull, reason: 'a timed-out answer is not used');
  });

  test('a stuck call that comes back clears the alarm by itself', () async {
    final mpv = _FakeMpv()..hang();
    final link = MpvLink(timeout: t, runner: mpv.call);
    final pending = link.get(1, 'pause');
    await wait();
    expect(link.wedged, isTrue);
    mpv.release();
    await pending;
    expect(link.wedged, isFalse);
    expect(await link.get(1, 'pause'), 'no', reason: 'and it is used again');
  });

  test('reset forgets the old engine; its late answer does not clear the new one',
      () async {
    final old = _FakeMpv()..hang();
    final fresh = _FakeMpv()..hang();
    var engine = old;
    final link = MpvLink(timeout: t, runner: (r) => engine.call(r));
    final a = link.get(1, 'pause');
    await wait();
    expect(link.wedged, isTrue);
    link.reset();
    expect(link.wedged, isFalse);
    engine = fresh;
    final b = link.get(2, 'pause');
    await wait();
    expect(link.wedged, isTrue, reason: 'the new engine is stuck too');
    old.release();
    await a;
    expect(link.wedged, isTrue,
        reason: 'the old engine coming back says nothing about the new one');
    fresh.release();
    await b;
    expect(link.wedged, isFalse);
  });
}
