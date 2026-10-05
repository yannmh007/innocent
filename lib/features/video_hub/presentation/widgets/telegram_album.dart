import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../domain/video_content.dart';
import 'media_mosaic.dart';
import 'telegram_album_layout.dart';

/// An album drawn the way Telegram draws a media group: groups of up to ten,
/// each laid out by Telegram's own rules (telegram_album_layout.dart), outer
/// corners rounded, inner edges square, a hairline between cells, a little
/// more between groups — what a channel post of thirty photos looks like.
///
/// Telegram's bubble is never wider than about 420 dp; a group as wide as a
/// tablet would make every cell a poster, so the groups are capped at
/// [maxGroupWidth] and centred.
class TelegramAlbum extends StatelessWidget {
  const TelegramAlbum({
    super.key,
    required this.items,
    required this.tileBuilder,
    this.spacing = 2,
    this.groupGap = 8,
    this.radius = 12,
    this.maxGroupWidth = 560,
  });

  final List<AlbumItem> items;
  final Widget Function(int index) tileBuilder;
  final double spacing;
  final double groupGap;
  final double radius;
  final double maxGroupWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final width = math.min(c.maxWidth, maxGroupWidth);
      if (items.isEmpty || width <= 0) return const SizedBox.shrink();
      final children = <Widget>[];
      var offset = 0;
      for (final size in albumGroupSizes(items.length)) {
        final slice = items.sublist(offset, offset + size);
        final cells = telegramAlbumLayout(
          ratios: [for (final i in slice) MediaMosaic.ratioOf(i)],
          maxWidth: width,
          minWidth: width * 0.25,
          spacing: spacing,
        );
        final height =
            cells.fold<double>(0, (h, cell) => math.max(h, cell.rect.bottom));
        // Some of Telegram's layouts come out narrower than the width (a
        // tall first item of three); Telegram shrinks the bubble, here the
        // group is centred.
        final groupWidth =
            cells.fold<double>(0, (w, cell) => math.max(w, cell.rect.right));
        final first = offset;
        if (children.isNotEmpty) children.add(SizedBox(height: groupGap));
        children.add(SizedBox(
          width: groupWidth,
          height: height,
          child: Stack(children: [
            for (var i = 0; i < cells.length; i++)
              Positioned.fromRect(
                rect: cells[i].rect,
                child: ClipRRect(
                  borderRadius: cells[i].sides.corners(radius),
                  child: tileBuilder(first + i),
                ),
              ),
          ]),
        ));
        offset += size;
      }
      return Center(
        child: SizedBox(
          width: width,
          child: Column(mainAxisSize: MainAxisSize.min, children: children),
        ),
      );
    });
  }
}
