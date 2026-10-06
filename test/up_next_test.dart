import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/up_next.dart';
import 'package:innocent/features/player/presentation/widgets/up_next_card.dart';

UpNextOffer _offer() => UpNextOffer(title: 'Next', play: () async {});

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  test('an offer belongs to the video it was registered for, once', () {
    UpNext.register('u1', _offer());
    expect(UpNext.offerFor('u2'), isNull);
    expect(UpNext.take('u1'), isNotNull);
    expect(UpNext.take('u1'), isNull);
  });

  test('three unattended in a row and the next one asks first', () {
    UpNext.noteChosen();
    for (var i = 0; i < UpNext.askAfter - 1; i++) {
      UpNext.noteUnattended();
    }
    expect(UpNext.askStillWatching, isFalse);
    UpNext.noteUnattended();
    expect(UpNext.askStillWatching, isTrue);
    UpNext.noteChosen();
    expect(UpNext.askStillWatching, isFalse);
  });

  testWidgets('countdown: plays by itself when it runs out', (t) async {
    bool? auto;
    await t.pumpWidget(_host(UpNextCard(
      title: 'Episode 2',
      countdown: const Duration(seconds: 3),
      onPlay: ({required bool byItself}) => auto = byItself,
      onClose: () {},
    )));
    expect(find.text('Episode 2'), findsOneWidget);
    await t.pump(const Duration(seconds: 2));
    expect(auto, isNull);
    await t.pump(const Duration(seconds: 2));
    expect(auto, isTrue);
  });

  testWidgets('a tap plays it as a choice', (t) async {
    bool? auto;
    await t.pumpWidget(_host(UpNextCard(
      title: 'Episode 2',
      onPlay: ({required bool byItself}) => auto = byItself,
      onClose: () {},
    )));
    await t.tap(find.byIcon(Icons.play_arrow_rounded));
    expect(auto, isFalse);
  });

  testWidgets('"Still watching?" and autoplay off never count down', (t) async {
    for (final w in [
      UpNextCard(
        title: 'E',
        askFirst: true,
        countdown: const Duration(seconds: 1),
        onPlay: ({required bool byItself}) => fail('played by itself'),
        onClose: () {},
      ),
      UpNextCard(
        title: 'E',
        autoplay: false,
        countdown: const Duration(seconds: 1),
        onPlay: ({required bool byItself}) => fail('played by itself'),
        onClose: () {},
      ),
    ]) {
      await t.pumpWidget(_host(w));
      await t.pump(const Duration(seconds: 3));
      await t.pumpWidget(const SizedBox());
    }
  });
}
