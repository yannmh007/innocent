import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/widgets/account_mark.dart';

/// The account's code on a paid film (widgets/account_mark.dart).
///
/// What must hold: the code is the first 8 digits of the `u` the Worker
/// logs, so a copy can be traced; it stays on the picture, never on a black
/// bar or off a zoomed screen; it moves; and it never takes a tap or a
/// TalkBack focus from the film. That it is drawn on every paid film at all
/// is tool/security_invariants.py rule 14.
const _user = '6c679480-3387-4442-ad3d-4423b8aceb71';

/// SHA-256 of [_user], as request-playback's sha256Hex(user.id, 16) gives it
/// for `u` (python3: hashlib.sha256(b'<id>').hexdigest()[:16]).
const _workerU = '93101325112230b9';

Future<void> _pump(WidgetTester tester,
    {String? code = '93101325', Rect? picture, VoidCallback? onTapBelow}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [accountMarkProvider.overrideWithValue(code)],
    child: MaterialApp(
      home: Center(
        child: SizedBox(
          width: 400,
          height: 300,
          child: Stack(children: <Widget>[
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTapBelow,
                child: const ColoredBox(color: Colors.black),
              ),
            ),
            Positioned.fill(child: AccountMark(picture: picture)),
          ]),
        ),
      ),
    ),
  ));
}

Rect _markRect(WidgetTester tester) =>
    tester.getRect(find.byKey(const ValueKey<String>('account-mark')));

Rect _box(WidgetTester tester) => tester.getRect(find.byType(AccountMark));

void main() {
  test("the code is the first 8 digits of the Worker's u", () {
    expect(accountMarkCode(_user), _workerU.substring(0, 8));
  });

  test("an account's code, never the install's, once signed in", () {
    expect(accountMarkFor(_user, 'install-123'), accountMarkCode(_user));
    expect(accountMarkFor(null, 'install-123'), accountMarkCode('install-123'));
    expect(accountMarkFor('', ''), isNull);
  });

  test('the code is placed on the picture, never on its outer tenth', () {
    final random = math.Random(7);
    for (var i = 0; i < 1000; i++) {
      final a = accountMarkSpot(random);
      expect(a.x.abs(), lessThanOrEqualTo(0.8));
      expect(a.y.abs(), lessThanOrEqualTo(0.8));
    }
  });

  test('the area is the part of the picture on screen', () {
    const view = Size(400, 300);
    // Letterboxed: the picture, not the bars.
    const boxed = Rect.fromLTWH(0, 37.5, 400, 225);
    expect(accountMarkArea(view, boxed), boxed);
    // Zoomed past the screen: only what is on it.
    expect(accountMarkArea(view, const Rect.fromLTWH(-200, -100, 800, 500)),
        const Rect.fromLTWH(0, 0, 400, 300));
    // Unknown: the whole box.
    expect(accountMarkArea(view, null), Offset.zero & view);
  });

  testWidgets('drawn on the picture, not on the bars', (tester) async {
    const picture = Rect.fromLTWH(0, 37.5, 400, 225);
    await _pump(tester, picture: picture);
    expect(find.text('93101325'), findsOneWidget);
    final on = picture.shift(_box(tester).topLeft);
    final mark = _markRect(tester);
    expect(on.contains(mark.topLeft) && on.contains(mark.bottomRight), isTrue,
        reason: '$mark is outside the picture $on');
  });

  testWidgets('fades out, moves, and fades back in', (tester) async {
    await _pump(tester);
    final box = _box(tester);
    final seen = <Offset>{_markRect(tester).center};
    // To each tick exactly: past it, the code is already back.
    var toTick = AccountMark.hold;
    for (var i = 0; i < 3; i++) {
      await tester.pump(toTick);
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 0,
          reason: 'it leaves before it moves');
      await tester.pump(AccountMark.fade);
      await tester.pump(AccountMark.fade);
      expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity, 1);
      final mark = _markRect(tester);
      expect(box.contains(mark.topLeft) && box.contains(mark.bottomRight), isTrue);
      seen.add(mark.center);
      toTick = AccountMark.hold - AccountMark.fade * 2;
    }
    expect(seen.length, greaterThan(1), reason: 'it never moved');
  });

  testWidgets('a tap on the code is a tap on the film', (tester) async {
    var taps = 0;
    await _pump(tester, onTapBelow: () => taps++);
    await tester.tapAt(_markRect(tester).center);
    expect(taps, 1);
  });

  testWidgets('TalkBack is not read the code', (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester);
    expect(find.bySemanticsLabel('93101325'), findsNothing);
    handle.dispose();
  });

  testWidgets('no code known, nothing drawn', (tester) async {
    await _pump(tester, code: null);
    expect(find.byKey(const ValueKey<String>('account-mark')), findsNothing);
  });
}
