import 'package:flutter/material.dart';

import '../video_hub_theme.dart';
import 'view_count_badge.dart';

/// "how much is in here" - stills and clips, with their own glyphs.
///
/// The single most asked question about a gallery title, and the one a poster
/// cannot answer: is this two photos or two hundred? A card that says
/// `24 · 3` settles it before the tap, which is worth more than any amount of
/// synopsis.
///
/// Either count may be absent and each is drawn independently, because a title
/// can legitimately be all stills or all clips. Absent is drawn as NOTHING,
/// never as zero - the reader cannot tell an honest zero from a field the
/// backend has not filled in yet, and one of those is a lie.
///
/// Counts use the same compact form as views, so `1.2K` means the same thing
/// wherever it appears on the card.
class MediaCountBadge extends StatelessWidget {
  final int? photos;
  final int? videos;

  /// Larger, with a bit more air, for the detail screen.
  final bool expanded;

  const MediaCountBadge({
    super.key,
    this.photos,
    this.videos,
    this.expanded = false,
  });

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[
      if (photos != null && photos! > 0)
        _Pair(
          icon: Icons.photo_library_outlined,
          value: ViewCount.compact(photos!),
          expanded: expanded,
        ),
      if (videos != null && videos! > 0)
        _Pair(
          icon: Icons.videocam_outlined,
          value: ViewCount.compact(videos!),
          expanded: expanded,
        ),
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < parts.length; i++) ...<Widget>[
          if (i > 0) SizedBox(width: expanded ? VH.s3 : 6),
          parts[i],
        ],
      ],
    );
  }
}

class _Pair extends StatelessWidget {
  final IconData icon;
  final String value;
  final bool expanded;

  const _Pair({
    required this.icon,
    required this.value,
    required this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: expanded ? 15 : 11,
          color: expanded ? VH.textSecondary : VH.textPrimary,
        ),
        const SizedBox(width: 3),
        Text(
          value,
          style: expanded
              ? VH.label.copyWith(
                  color: VH.textSecondary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                )
              : VH.badge.copyWith(letterSpacing: 0),
        ),
      ],
    );
  }
}
