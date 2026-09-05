import 'package:flutter/material.dart';

import '../../../../core/localization/app_strings.dart';
import '../../domain/video_content.dart';
import '../video_hub_theme.dart';
import 'poster_image.dart';
import 'view_count_badge.dart';

/// The featured item at the top of the landing tab.
///
/// WHY THIS EXISTS: the hub opened straight into a row of small posters, and
/// that is the real reason it felt unfinished. Every catalogue app worth
/// copying — Netflix, Disney+, Prime — opens with ONE title presented large,
/// and it is not decoration. It does three jobs a row of thumbnails cannot:
///
///   * it gives the page a focal point, so the eye has somewhere to land
///     instead of scanning twelve equal rectangles;
///   * it sets the scale for everything below it, which is what makes the
///     rows read as deliberate rather than as all the app has;
///   * it puts a real action on screen immediately, so the first tap can be
///     "watch this" rather than "go looking".
///
/// The artwork bleeds off the top and fades into the page rather than sitting
/// in a rounded box. A framed banner reads as an advertisement inside the app;
/// a bleeding one reads as the app.
class FeaturedHero extends StatelessWidget {
  final VideoContent content;
  final VoidCallback onPlay;
  final VoidCallback onInfo;

  const FeaturedHero({
    super.key,
    required this.content,
    required this.onPlay,
    required this.onInfo,
  });

  /// Portrait-leaning, because a phone is portrait and a 16:9 still would
  /// waste the height that makes this read as a feature rather than a header.
  static const double _aspect = 0.86;

  /// Ceiling for tall/large screens: past this the hero stops being a feature
  /// and becomes the whole page, and the rows below it stop being discoverable.
  static const double _maxHeight = 460;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final width = MediaQuery.of(context).size.width;
    final height = (width / _aspect).clamp(0.0, _maxHeight);

    final meta = <String>[
      if (content.year != null) '${content.year}',
      ...content.genres.take(2),
      if (content.episodeCount != null)
        s.vhEpisodesCount(content.episodeCount!),
    ];

    return SizedBox(
      height: height,
      width: width,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          PosterImage(mediaRef: content.poster, title: content.title),

          // Two scrims, not one. A single top-to-bottom wash either leaves the
          // text unreadable or greys out the artwork; separating them lets the
          // middle of the image stay clean.
          const _Scrim(
            begin: Alignment.bottomCenter,
            end: Alignment.center,
            colors: <Color>[VH.canvas, Colors.transparent],
          ),
          _Scrim(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: <Color>[
              VH.canvas.withOpacity(0.72),
              Colors.transparent,
            ],
          ),

          Positioned(
            left: VH.gutter,
            right: VH.gutter,
            bottom: VH.s4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  content.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: VH.display,
                ),
                if (meta.isNotEmpty) ...<Widget>[
                  const SizedBox(height: VH.s2),
                  _MetaLine(parts: meta, views: content.viewCount),
                ],
                const SizedBox(height: VH.s4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: _HeroButton(
                        icon: Icons.play_arrow_rounded,
                        label: s.vhPlay,
                        primary: true,
                        onTap: onPlay,
                      ),
                    ),
                    const SizedBox(width: VH.s2),
                    Expanded(
                      child: _HeroButton(
                        icon: Icons.info_outline_rounded,
                        label: s.vhMoreInfo,
                        primary: false,
                        onTap: onInfo,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  final Alignment begin;
  final Alignment end;
  final List<Color> colors;

  const _Scrim({
    required this.begin,
    required this.end,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(begin: begin, end: end, colors: colors),
        ),
      ),
    );
  }
}

/// Metadata as dot-separated parts, with the rating leading if present.
///
/// One line, not a row of boxed chips: chips here would compete with the
/// buttons directly underneath, and a hero has room for exactly one loud
/// element.
class _MetaLine extends StatelessWidget {
  final List<String> parts;
  final int? views;

  const _MetaLine({required this.parts, this.views});

  @override
  Widget build(BuildContext context) {
    final style = VH.label.copyWith(
      color: VH.textSecondary,
      fontWeight: FontWeight.w500,
      fontSize: 12.5,
    );

    return Row(
      children: <Widget>[
        if (views != null) ...<Widget>[
          const Icon(Icons.visibility_outlined,
              size: 14, color: VH.textSecondary),
          const SizedBox(width: 3),
          Text(ViewCount.compact(views!), style: style),
          const SizedBox(width: VH.s2),
        ],
        Expanded(
          child: Text(
            parts.join('  ·  '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
      ],
    );
  }
}

class _HeroButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _HeroButton({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color fg = primary ? VH.textInverse : VH.textPrimary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(VH.rControl),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // The primary action is the ONLY solid-white surface on the page.
          // That is what makes it read as the primary action without a colour.
          color: primary ? VH.textPrimary : Colors.white.withOpacity(0.14),
          borderRadius: BorderRadius.circular(VH.rControl),
          border: primary
              ? null
              : Border.all(color: Colors.white.withOpacity(0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: primary ? 22 : 18, color: fg),
            const SizedBox(width: 6),
            Text(
              label,
              style: VH.label.copyWith(
                color: fg,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
