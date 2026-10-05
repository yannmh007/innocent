import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/subtitle_look.dart';
import 'package:innocent/features/player/presentation/gestures/subtitle_band.dart';
import 'package:innocent/features/player/presentation/subtitles/player_subtitles.dart';

// What TalkBack is told about the player. On the lab phone every loose text
// in the player — the subtitle (twice: outline and fill), the title, the
// clock, the times — and the screen button's name and id had gone up into
// one full-screen node (run 37308309328).
void main() {
  testWidgets('a subtitle is one node of its own, its text read once',
      (t) async {
    final h = t.ensureSemantics();
    const view = Size(411, 914);
    const text = 'စာတန်းထိုး 1\nSubtitle line 1';
    final g = subtitleGeometry(
      view: view,
      picture: const Rect.fromLTWH(0, 342, 411, 231),
      look: const SubtitleLook(),
    );
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(children: [
          // A sibling with its own label, as the player's other layers.
          const Positioned(top: 0, left: 0, child: Text('aaa_play_720p')),
          Positioned(
            left: g.box.left,
            width: g.box.width,
            bottom: view.height - g.bottom,
            child: SubtitleText(text, look: const SubtitleLook(), geometry: g),
          ),
        ]),
      ),
    ));
    final node = t.getSemantics(find.byType(SubtitleText));
    expect(node.label, text, reason: 'the outline copy is not read');
    expect(node.rect.height, lessThan(200),
        reason: 'the node is the text, not the screen');
    expect(find.bySemanticsLabel('aaa_play_720p'), findsOneWidget);
    h.dispose();
  });
}
