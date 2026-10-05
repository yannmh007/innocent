import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/widgets/telegram_album.dart';

import 'harness.dart';

/// Telegram-layout albums of mixed shapes, drawn with plain tiles that say
/// their shape, to look at the layout itself (the real tiles need the
/// network for their pictures).
const _shapes = <List<int>>[
  [1920, 1080],
  [1080, 1920],
  [1080, 1080],
  [1080, 1350],
  [1280, 720],
  [720, 1280],
  [1200, 900],
  [900, 1200],
  [1080, 1350],
  [1920, 1080],
];

List<AlbumItem> _items(int n, {int shift = 0}) => [
      for (var i = 0; i < n; i++)
        AlbumItem(
          id: 'i$i',
          kind: i % 4 == 1 ? MediaKind.video : MediaKind.photo,
          source: MediaRef.none,
          width: _shapes[(i + shift) % _shapes.length][0],
          height: _shapes[(i + shift) % _shapes.length][1],
          durationSec: i % 4 == 1 ? 15 + i * 7 : null,
        ),
    ];

const _colors = [
  Color(0xFF44546A),
  Color(0xFF5B7065),
  Color(0xFF6A5A4A),
  Color(0xFF4A4F6A),
  Color(0xFF6A4A5E),
  Color(0xFF3E6670),
];

Widget _album(List<List<AlbumItem>> albums) => Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14),
          child: Column(children: [
            for (final items in albums) ...[
              Text('${items.length} items',
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 6),
              TelegramAlbum(
                items: items,
                tileBuilder: (i) {
                  final it = items[i];
                  return ColoredBox(
                    color: _colors[i % _colors.length],
                    child: Stack(fit: StackFit.expand, children: [
                      Center(
                        child: it.isVideo
                            ? const CircleAvatar(
                                radius: 18,
                                backgroundColor: Color(0x73000000),
                                child: Icon(Icons.play_arrow_rounded,
                                    color: Colors.white))
                            : Text('${it.width}x${it.height}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 10)),
                      ),
                      if (it.isVideo)
                        Positioned(
                          left: 5,
                          top: 5,
                          child: Text(it.durationLabel,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 11)),
                        ),
                    ]),
                  );
                },
              ),
              const SizedBox(height: 18),
            ],
          ]),
        ),
      ),
    );

void main() {
  setUpAll(loadScreenFonts);
  screens('album_small_groups',
      () => _album([_items(2), _items(3, shift: 1), _items(4)]),
      phones: const [large], scrolls: 1);
  screens('album_big_groups',
      () => _album([_items(7, shift: 2), _items(10, shift: 3)]),
      phones: const [large], scrolls: 2);
  screens('album_long', () => _album([_items(23, shift: 4)]),
      phones: const [large], scrolls: 3);
}
