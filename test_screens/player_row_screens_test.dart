import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/presentation/player_provider.dart';
import 'package:innocent/features/player/presentation/shortcut_item.dart';
import 'package:innocent/features/player/presentation/widgets/shortcut_row.dart';
import 'package:innocent/features/player/presentation/widgets/more_menu_panel.dart';
import 'package:innocent/features/player/presentation/widgets/sleep_timer_dialog.dart';
import 'package:innocent/features/player/presentation/widgets/decoder_dialog.dart';

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
                // As the player's top bar: the title takes what is left.
                const Expanded(
                  child: Text('5_6280325781230984315',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                ),
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
  screens('player_more', () => _more(), phones: [large]);
  screens('player_decoder', () => Scaffold(
        backgroundColor: Colors.black,
        body: DecoderDialog(
            current: DecoderType.values.first,
            onSelect: (_) {},
            onDismiss: () {}),
      ), phones: [large]);
  screens('player_sleep', () => Scaffold(
        backgroundColor: Colors.black,
        body: SleepTimerDialog(
            currentRemaining: const Duration(minutes: 44),
            onSelect: (_, __) {},
            onDismiss: () {}),
      ), phones: [large]);
}

Widget _more() {
  MoreMenuItemData i(String l, IconData ic, {bool dot = false}) =>
      MoreMenuItemData(label: l, icon: ic, onTap: () {}, hasNotificationDot: dot);
  return Scaffold(
    backgroundColor: Colors.black,
    body: Stack(children: <Widget>[
      Positioned(
          top: 300,
          left: 0,
          right: 0,
          height: 230,
          child: Container(color: const Color(0xFF6B5A3A))),
      MoreMenuPanel(
        items: <MoreMenuItemData>[
          i('Audio Track', Icons.music_note_outlined),
          i('Subtitle', Icons.subtitles_outlined),
          i('Playing Queue', Icons.queue_music),
          i('Aspect Ratio', Icons.aspect_ratio),
          i('Display Settings', Icons.tune),
          i('Bookmark', Icons.bookmarks_outlined),
          i('Cut', Icons.content_cut),
          i('Favourite', Icons.favorite_border, dot: true),
          i('Add To Playlist', Icons.playlist_add, dot: true),
          i('Information', Icons.list),
          i('Share', Icons.share),
          i('Tutorial', Icons.lightbulb_outline),
        ],
        videoDisplayEnabled: true,
        visibleShortcuts: const PlayerState().visibleShortcuts,
        onVideoDisplayToggle: (_) {},
        onShortcutsToggle: (_) {},
        onShortcutToggle: (_) {},
        onDismiss: () {},
      ),
    ]),
  );
}
