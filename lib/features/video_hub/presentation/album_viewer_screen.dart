import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/access_policy.dart';
import '../domain/video_content.dart';
import 'playback.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'widgets/poster_image.dart';
import 'account_provider.dart';

/// Full-screen, swipeable viewer for a content album.
///
/// Photos are shown inline with pinch-zoom. Videos are NOT played here - a tap
/// hands them to Innocent's existing player, which is the only video surface
/// in the app. Two players would mean two sets of gesture handling, two resume
/// stores and two background-audio behaviours to keep in step.
///
/// Takes the PARENT title rather than a bare item list, because access is a
/// property of the title: whether a still may be opened depends on the tier of
/// the thing it belongs to and how many of its siblings came before it.
class AlbumViewerScreen extends ConsumerStatefulWidget {
  final VideoContent content;
  final int initialIndex;

  const AlbumViewerScreen({
    super.key,
    required this.content,
    required this.initialIndex,
  });

  @override
  ConsumerState<AlbumViewerScreen> createState() => _AlbumViewerScreenState();
}

class _AlbumViewerScreenState extends ConsumerState<AlbumViewerScreen> {
  late final PageController _controller;
  late final List<int> _photoOrdinals;
  late int _index;

  List<AlbumItem> get _items => widget.content.items;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, _items.length - 1);
    _controller = PageController(initialPage: _index);
    _photoOrdinals = AccessPolicy.photoOrdinalsOf(_items);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _canOpen(int index) {
    return ref.read(accessPolicyProvider).canOpenItem(
          parent: widget.content,
          item: _items[index],
          photoOrdinal: _photoOrdinals[index],
          tier: ref.read(viewerProvider).tier,
        );
  }

  Future<void> _playVideo(AlbumItem item) {
    return playMedia(
      context,
      ref,
      content: widget.content,
      source: item.source,
      titleOverride: widget.content.title,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: after a purchase the sheet pops back to this screen
    // and every locked page has to become unlocked without a manual refresh.
    ref.watch(viewerProvider);
    final total = _items.length;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, color: VH.textPrimary),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          '${_index + 1} / $total',
          style: VH.label.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: total,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, index) {
          final item = _items[index];
          if (!_canOpen(index)) {
            return _LockedPage(
              item: item,
              parentTitle: widget.content.title,
              onUnlock: () =>
                  promptUpgrade(context, ref, content: widget.content),
            );
          }
          if (item.isVideo) {
            return _VideoPage(
              item: item,
              title: widget.content.title,
              onPlay: () => _playVideo(item),
            );
          }
          return InteractiveViewer(
            minScale: 1,
            maxScale: 4,
            child: Center(
              child: PosterImage(
                mediaRef:
                    item.source.isEmpty ? item.thumbnail : item.source,
                title: '${widget.content.title} ${item.id}',
                fit: BoxFit.contain,
                glyph: Icons.image_outlined,
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A page the viewer has not paid for.
///
/// Shows the lock and the offer rather than skipping the item. Swiping past
/// locked pages silently would hide exactly the thing that justifies paying.
///
/// And now shows the PICTURE, blurred, behind the offer. The previous version
/// was a lock glyph on an empty background: it proved something existed and
/// said nothing about what. Swiping through a premium album should feel like
/// looking at frosted glass - the shape and the colour are there, the detail
/// is not - which is the difference between "there is more" and "there is
/// more OF THIS".
///
/// The blur is a presentation choice, not a control: these photos sit in the
/// public bucket and their URLs are already reachable. It exists to sell.
class _LockedPage extends StatelessWidget {
  final AlbumItem item;
  final String parentTitle;
  final VoidCallback onUnlock;

  const _LockedPage({
    required this.item,
    required this.parentTitle,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Same sigma as the grid tile, deliberately: a preview that is
        // crisper in one place than the other reads as a bug.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: 14,
            sigmaY: 14,
            tileMode: TileMode.decal,
          ),
          child: PosterImage(
            mediaRef: item.thumbnail.isEmpty ? item.source : item.thumbnail,
            title: '$parentTitle ${item.id}',
            glyph: item.isVideo
                ? Icons.play_circle_outline
                : Icons.image_outlined,
          ),
        ),
        // Enough scrim for white text to hold against any photo underneath.
        Positioned.fill(
          child: IgnorePointer(
            child: ColoredBox(color: Colors.black.withOpacity(0.45)),
          ),
        ),
        _lockedOffer(context, s),
      ],
    );
  }

  Widget _lockedOffer(BuildContext context, AppStrings s) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: VH.s6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(Icons.lock_rounded, size: 40, color: VH.textSecondary),
            const SizedBox(height: VH.s4),
            Text(
              s.vhPaywallGeneric,
              textAlign: TextAlign.center,
              style: VH.body.copyWith(color: VH.textSecondary),
            ),
            const SizedBox(height: VH.s5),
            FilledButton(
              onPressed: onUnlock,
              style: FilledButton.styleFrom(
                backgroundColor: VH.textPrimary,
                foregroundColor: VH.textInverse,
                padding: const EdgeInsets.symmetric(
                    horizontal: VH.s5, vertical: VH.s3),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(VH.rControl),
                ),
              ),
              child: Text(
                s.vhUpgrade,
                style: VH.label.copyWith(
                  color: VH.textInverse,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A video page: still frame plus a play affordance that hands off to the
/// app's player.
class _VideoPage extends StatelessWidget {
  final AlbumItem item;
  final String title;
  final VoidCallback onPlay;

  const _VideoPage({
    required this.item,
    required this.title,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        PosterImage(
          mediaRef: item.thumbnail.isEmpty ? item.source : item.thumbnail,
          title: '$title ${item.id}',
          fit: BoxFit.contain,
          glyph: Icons.play_circle_outline,
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                iconSize: 64,
                icon: const Icon(Icons.play_circle_fill,
                    color: VH.textPrimary),
                onPressed: onPlay,
              ),
              if (item.durationLabel.isNotEmpty)
                Text(
                  item.durationLabel,
                  style: VH.label.copyWith(color: VH.textSecondary),
                ),
              const SizedBox(height: VH.s1),
              Text(
                item.isPreview ? s.vhFreePreview : s.vhPlay,
                style: VH.meta.copyWith(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
