import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/shortcut_item.dart';
import 'package:innocent/features/player/presentation/widgets/shortcut_row.dart';

import 'harness.dart';

/// The player's shortcut row on its own, placed the way player_screen.dart
/// places it under a back arrow, to measure against MX (the player itself
/// needs libmpv and cannot be pumped here).
Widget _row({required bool expanded, bool loopOn = true}) => Builder(
      builder: (context) {
        final top = MediaQuery.of(context).padding.top;
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(children: <Widget>[
            Positioned(
              top: top,
              left: 0,
              right: 0,
              height: 56,
              child: Row(children: <Widget>[
                IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.arrow_back, color: Colors.white)),
                const Text('5_6280325781230984315',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
              ]),
            ),
            Positioned(
              top: top + 59,
              left: 0,
              right: 0,
              child: ShortcutRow(
                visibleItems: const PlayerState().visibleShortcuts.toList()
                  ..sort((a, b) => a.index.compareTo(b.index)),
                activeItems: {if (loopOn) ShortcutItem.loop},
                expanded: expanded,
                onItemTap: (_) {},
                onToggleExpand: () {},
                isPortrait: true,
                loopMode: loopOn ? LoopMode.one : LoopMode.off,
              ),
            ),
          ]),
        );
      },
    );

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  screens('player_row', () => _row(expanded: false), phones: [large]);
  screens('player_row_expanded', () => _row(expanded: true), phones: [large]);
}
