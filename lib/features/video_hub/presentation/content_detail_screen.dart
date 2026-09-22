import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/access_policy.dart';
import '../data/api/event_sender.dart';
import '../domain/video_content.dart';
import 'album_viewer_screen.dart';
import 'widgets/media_mosaic.dart';
import 'playback.dart';
import 'video_hub_provider.dart';
import 'widgets/download_action.dart';
import 'widgets/poster_image.dart';
import 'widgets/vh_insets.dart';
import 'widgets/view_count_badge.dart';
import 'video_hub_theme.dart';
import 'account_provider.dart';

/// One catalogue entry in full: artwork, facts, and the mixed photo/video
/// album behind it.
///
/// The album is the Telegram-style part of the brief — stills and clips in one
/// grid, opened into a swipeable viewer. Playback itself is handed straight to
/// Innocent's EXISTING player via [Routes.player]; this feature deliberately
/// does not gain a second video surface. The player already handles gestures,
/// subtitles, decoders, PiP, background audio and resume, and a parallel
/// implementation would inherit none of it.
class ContentDetailScreen extends ConsumerStatefulWidget {
  final VideoContent content;

  const ContentDetailScreen({super.key, required this.content});

  /// Whether the big button above the grid is drawn at all.
  ///
  /// THE BRIEF WAS "HIDE PLAY", AND THIS IS THE HONEST READING OF IT. The
  /// album is meant to be the way into a title — a Telegram-style grid where
  /// every video tile carries its own play glyph — so a second, larger Play
  /// button above it is a duplicate that also implies there is only one video
  /// to watch. When there is a grid, the grid is the control.
  ///
  /// THREE CASES, AND THE THIRD IS THE ONE WORTH ARGUING:
  ///
  ///   no album              -> SHOWN. There is no other way in. A detail
  ///                            screen with nothing to tap is not a cleaner
  ///                            design, it is a dead end.
  ///   album, unlocked       -> HIDDEN. This is the case the brief is about.
  ///   album, LOCKED         -> SHOWN, saying Upgrade.
  ///
  /// The third is a deliberate departure from "hide the button", because the
  /// button in that state is not a Play button — it is the route to the
  /// paywall, and it is the only unmissable one on the screen. A locked tile
  /// does lead there, but only after the viewer decides to tap something they
  /// can see is locked. Removing the explicit offer to keep the grid tidy
  /// trades a sale for a layout, and this screen exists to make the sale.
  ///
  /// Static and pure so the rule can be tested without building a widget, and
  /// so there is exactly one statement of it. A condition inlined into
  /// `build()` is a condition that gets a second, slightly different copy the
  /// first time another surface needs the same answer.
  static bool showsHeaderButton({
    required bool hasAlbum,
    required bool locked,
  }) =>
      !hasAlbum || locked;

  @override
  ConsumerState<ContentDetailScreen> createState() =>
      _ContentDetailScreenState();
}

class _ContentDetailScreenState extends ConsumerState<ContentDetailScreen> {
  VideoContent get content => widget.content;

  @override
  void initState() {
    super.initState();
    // THIS is the view. Opening the detail screen, by anyone, free or
    // premium - not a scroll past the card, and not twice in one session.
    // Deferred one frame so it never competes with the screen's first build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      recordViewOnce(ref, content.id);
      // The same moment, recorded twice on purpose and NOT duplication.
      // `recordViewOnce` maintains `titles.view_count`, which is a lifetime
      // total the card draws; this is a row in the event log, which is what
      // a ranking reads. One is a number on screen, the other is history —
      // and unlike the counter, the event carries when, from which session,
      // and beside what else.
      logEvent(ref, Ev.detailView, titleId: content.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // audit_video_hub.md M5.
    final shownTitle = content.displayTitle(s.locale.languageCode);
    final policy = ref.watch(accessPolicyProvider);
    // Watched: a purchase made from this screen must unlock it in place.
    final tier = ref.watch(viewerProvider).tier;
    final ordinals = AccessPolicy.photoOrdinalsOf(content.items);
    final lockedCount = policy.lockedCountFor(content, tier);
    final locked = !policy.canPlayTitle(content, tier);

    return Scaffold(
      backgroundColor: VH.canvas,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            backgroundColor: VH.canvas,
            surfaceTintColor: Colors.transparent,
            pinned: true,
            expandedHeight: 260,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            flexibleSpace: FlexibleSpaceBar(
              background: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  PosterImage(
                    mediaRef: content.poster,
                    title: shownTitle,
                  ),
                  // Scrim so the pinned title and back arrow stay legible over
                  // whatever the artwork happens to be.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: <Color>[
                          VH.canvas,
                          VH.canvas.withOpacity(0.15),
                          Colors.transparent,
                        ],
                        stops: const <double>[0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: _Header(
              content: content,
              locked: locked,
              lockedCount: lockedCount,
              // Hidden once the grid below can do the job. See
              // ContentDetailScreen.showsHeaderButton.
              showButton: ContentDetailScreen.showsHeaderButton(
                hasAlbum: content.hasAlbum,
                locked: locked,
              ),
              onPlay: () => _play(context, ref),
            ),
          ),
          if (content.hasAlbum) ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 10),
                child: Row(
                  children: <Widget>[
                    Text(s.vhAlbum, style: VH.heading),
                    const SizedBox(width: 8),
                    Text(
                      '${content.items.length}',
                      style: VH.meta.copyWith(fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ),
            // The mosaic, not a grid. A folder holds portrait clips and
            // landscape stills together, and a three-column square grid gave
            // both the same square hole - a 9:16 clip lost about 44% of its
            // frame to the crop. MediaMosaic sizes each row from the items in
            // it, so nothing is forced into a shape it does not have.
            //
            // SliverToBoxAdapter with a LayoutBuilder rather than a SliverGrid:
            // the row heights are computed from the content, which no
            // SliverGridDelegate can express. The album is one title's folder,
            // so there is nothing here worth virtualising.
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                  14, 0, 14, VhInsets.scrollBottom(context)),
              sliver: SliverToBoxAdapter(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return MediaMosaic.build(
                      items: content.items,
                      width: constraints.maxWidth,
                      tileBuilder: (index) {
                        final item = content.items[index];
                        final unlocked = policy.canOpenItem(
                          parent: content,
                          item: item,
                          photoOrdinal: ordinals[index],
                          tier: tier,
                        );
                        return _AlbumTile(
                          item: item,
                          parentTitle: shownTitle,
                          locked: !unlocked,
                          // A locked tile still opens the viewer rather than
                          // jumping straight to the paywall: landing on the
                          // locked page in context, surrounded by what is
                          // unlocked, makes the offer concrete instead of
                          // abrupt.
                          onTap: () => _openAlbum(context, index),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          ] else
            const SliverToBoxAdapter(child: SizedBox(height: 28)),
        ],
      ),
    );
  }

  void _openAlbum(BuildContext context, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumViewerScreen(
          content: content,
          initialIndex: index,
        ),
      ),
    );
  }

  /// Hands the entry's primary source to the app's player.
  ///
  /// Delegates to [playContent] so the hero button, this screen and the album
  /// viewer cannot drift apart about what "Play" does.
  Future<void> _play(BuildContext context, WidgetRef ref) =>
      playContent(context, ref, content);
}

class _Header extends StatelessWidget {
  final VideoContent content;
  final VoidCallback onPlay;

  /// False once the album grid below is the way into the title.
  final bool showButton;

  /// True when this viewer cannot play the title. Changes the button LABEL,
  /// never disables it - a dead Play button teaches nothing, while a button
  /// that says Upgrade both explains the state and offers the way out.
  final bool locked;

  final int lockedCount;

  const _Header({
    required this.content,
    required this.onPlay,
    required this.locked,
    required this.lockedCount,
    required this.showButton,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    // audit_video_hub.md M5. Its own local: _Header is a separate widget and
    // does not see the one in the screen's build.
    final shownTitle = content.displayTitle(s.locale.languageCode);
    final meta = <String>[
      if (content.year != null) '${content.year}',
      if (content.qualityLabel != null) content.qualityLabel!,
      if (content.episodeCount != null) s.vhEpisodesCount(content.episodeCount!),
      ...content.genres,
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(shownTitle, style: VH.title),
          if (content.viewCount != null) ...<Widget>[
            const SizedBox(height: 6),
            // Full label here - there is room for the word, and "12K views"
            // says what the number is where a bare "12K" on a card cannot.
            ViewCountBadge(views: content.viewCount!, compactOnly: false),
          ],
          if (meta.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: meta
                  .map((m) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: VH.surface1,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          m,
                          style: VH.label.copyWith(
                            color: VH.textSecondary,
                            fontSize: 11.5,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
          // Under the metadata chips and above the synopsis: a secondary
          // action, next to the facts about the title rather than competing
          // with the primary control below. Draws nothing at all for a viewer
          // who cannot download — see DownloadAction.
          const SizedBox(height: VH.s2),
          Align(
            alignment: Alignment.centerLeft,
            child: DownloadAction(content: content),
          ),
          if (locked && lockedCount > 0) ...<Widget>[
            const SizedBox(height: VH.s3),
            Row(
              children: <Widget>[
                const Icon(Icons.lock_outline_rounded,
                    size: 14, color: VH.textTertiary),
                const SizedBox(width: 5),
                Text(
                  s.vhLockedCountShort(lockedCount),
                  style: VH.meta.copyWith(fontSize: 12),
                ),
              ],
            ),
          ],
          if (content.synopsis != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(content.synopsis!, style: VH.body),
          ],
          if (showButton) ...<Widget>[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: onPlay,
                icon: Icon(
                  locked ? Icons.lock_rounded : Icons.play_arrow_rounded,
                  size: locked ? 18 : 22,
                ),
                label: Text(
                  locked ? s.vhUpgrade : s.vhPlay,
                  style: VH.label.copyWith(
                    color: VH.textInverse,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: VH.textPrimary,
                  foregroundColor: VH.textInverse,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(VH.rControl),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Marks the one clip a free viewer CAN watch. Without it a preview looks
/// identical to the locked clips beside it and nobody discovers it.
class _PreviewTag extends StatelessWidget {
  const _PreviewTag();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: VH.textPrimary,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        AppStrings.of(context).vhFreePreview,
        style: VH.badge.copyWith(color: VH.textInverse),
      ),
    );
  }
}

/// Wraps [child] in a blur when [on], and returns it untouched otherwise.
///
/// A free function so the tile and the full-page viewer blur by exactly the
/// same amount. Two hand-tuned sigmas would drift apart the first time either
/// was adjusted, and a preview that is crisper in one place than the other
/// reads as a bug.
Widget _blurred(bool on, Widget child) {
  if (!on) return child;
  return ImageFiltered(
    imageFilter: ui.ImageFilter.blur(
      sigmaX: 14,
      sigmaY: 14,
      tileMode: TileMode.decal,
    ),
    child: child,
  );
}

class _AlbumTile extends StatelessWidget {
  final AlbumItem item;
  final String parentTitle;
  final bool locked;
  final VoidCallback onTap;

  const _AlbumTile({
    required this.item,
    required this.parentTitle,
    required this.onTap,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // Locked tiles are BLURRED, not blacked out.
          //
          // A flat 62% scrim hid the picture completely, which left a free
          // viewer looking at a grey square: it says something is missing but
          // nothing about what. A blur keeps the shape, the colour and the
          // composition and withholds only the detail - so the offer becomes
          // "there is more of THIS" rather than "there is more of something".
          // Feature-preview paywalls work for exactly that reason: people
          // judge what they can see far more readily than what they have to
          // imagine.
          //
          // HONEST ABOUT WHAT THIS IS: a presentation choice, not a control.
          // These photos live in the PUBLIC bucket and their URLs are already
          // reachable. The blur exists to sell, not to protect. Anything that
          // genuinely must not be seen belongs in the private bucket behind
          // request-playback, like the video.
          //
          // TileMode.decal, not the default clamp: clamping smears the edge
          // pixels outward and paints a dirty border around every locked tile.
          _blurred(
            locked,
            PosterImage(
              mediaRef: item.thumbnail.isEmpty ? item.source : item.thumbnail,
              title: '$parentTitle ${item.id}',
              glyph: item.isVideo
                  ? Icons.play_circle_outline
                  : Icons.image_outlined,
            ),
          ),
          if (locked) ...<Widget>[
            // A much lighter scrim than before. The blur already removes the
            // detail; this only darkens enough for the lock glyph to read.
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(color: Colors.black.withOpacity(0.22)),
              ),
            ),
            const Center(
              child: Icon(Icons.lock_rounded, size: 18, color: VH.textPrimary),
            ),
          ] else if (item.isPreview && item.isVideo) ...<Widget>[
            const Center(
              child: Icon(Icons.play_circle_fill,
                  size: 30, color: VH.textPrimary),
            ),
            const Positioned(
              left: 4,
              top: 4,
              child: _PreviewTag(),
            ),
          ] else if (item.isVideo) ...<Widget>[
            const Center(
              child: Icon(Icons.play_circle_fill,
                  size: 30, color: VH.textPrimary),
            ),
            if (item.durationLabel.isNotEmpty)
              Positioned(
                right: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.65),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    item.durationLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
