import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// A thin wrapper over [Image.memory] that renders a graceful
/// fallback when the bytes are corrupt, decode fails, or the codec
/// is unsupported. Without [errorBuilder] Flutter rethrows decode
/// errors up the widget tree and the surrounding list item crashes,
/// which is jarring for the user. The fallback here is a muted icon
/// so the surrounding layout (title, subtitle, progress bar) stays
/// intact.
///
/// Use this everywhere thumbnails are rendered from a byte buffer
/// (folder covers, video list/grid tiles, history, watch-later,
/// favourites, playlists, player preview).
class SafeThumbnail extends StatelessWidget {
  final Uint8List bytes;
  final BoxFit fit;
  final double? width;
  final double? height;
  final IconData fallbackIcon;
  final double fallbackIconSize;

  const SafeThumbnail({
    super.key,
    required this.bytes,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.fallbackIcon = Icons.movie_outlined,
    this.fallbackIconSize = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Image.memory(
      bytes,
      fit: fit,
      width: width,
      height: height,
      // Disable Flutter's default cache hashing on each frame —
      // memory thumbnails are already in memory; an extra cache layer
      // would just duplicate the bytes.
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) {
        return Container(
          width: width,
          height: height,
          color: AppColors.black25,
          alignment: Alignment.center,
          child: Icon(
            fallbackIcon,
            color: AppColors.darkOnSurfaceMuted,
            size: fallbackIconSize,
          ),
        );
      },
    );
  }
}
