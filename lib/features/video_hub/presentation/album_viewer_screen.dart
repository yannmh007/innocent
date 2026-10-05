import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../domain/access_policy.dart';
import '../domain/video_content.dart';
import 'album_downloads.dart';
import 'album_saver.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import 'playback.dart';
import 'video_hub_provider.dart';
import 'video_hub_theme.dart';
import 'widgets/poster_image.dart';
import 'widgets/zoomable_photo.dart';
import 'account_provider.dart';
import 'content_detail_screen.dart' show albumHeroTag;

/// Full-screen, swipeable viewer for a content album.
///
/// Photos are shown inline with pinch-zoom and double-tap zoom ([ZoomablePhoto]). Videos are NOT played here - a tap
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

  /// Opens the viewer the way Telegram does: the tapped cell's picture
  /// flies into place (Hero) over a fading black, and what was underneath
  /// stays drawn — the route is not opaque — so dragging the picture down
  /// to dismiss shows it coming back through the fade.
  static Route<void> route(VideoContent content, int initialIndex) =>
      PageRouteBuilder<void>(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) =>
            AlbumViewerScreen(content: content, initialIndex: initialIndex),
        transitionsBuilder: (_, animation, __, child) =>
            FadeTransition(opacity: animation, child: child),
      );

  @override
  ConsumerState<AlbumViewerScreen> createState() => _AlbumViewerScreenState();
}

class _AlbumViewerScreenState extends ConsumerState<AlbumViewerScreen>
    with SingleTickerProviderStateMixin {
  late final PageController _controller;
  late final List<int> _photoOrdinals;
  late int _index;

  /// True while a photo is being pinched or is zoomed in: the page swipe is
  /// switched off so the fingers move the photo, not the album.
  bool _pagingLocked = false;

  /// Telegram's viewer: a tap hides the bars and the strip, another brings
  /// them back.
  bool _chrome = true;

  /// How far the page has been dragged down (or up) to dismiss it; the
  /// black behind it fades with the distance, as in Telegram.
  double _drag = 0;
  late final AnimationController _settle = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 180))
    ..addListener(() {
      final from = _settleFrom;
      if (from != null) setState(() => _drag = from * (1 - _settle.value));
    });
  double? _settleFrom;

  final ScrollController _strip = ScrollController();

  List<AlbumItem> get _items => widget.content.items;

  @override
  void initState() {
    super.initState();
    _index = _items.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, _items.length - 1).toInt();
    _controller = PageController(initialPage: _index);
    _photoOrdinals = AccessPolicy.photoOrdinalsOf(_items);
    // So a photo that is on the phone is drawn from the phone on the first
    // frame, even when this viewer is the first thing to ask since launch.
    // ignore: discarded_futures
    ref.read(offlineLibraryProvider).warmPhotoIndex();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _centreStrip(jump: true));
  }

  @override
  void dispose() {
    _controller.dispose();
    _settle.dispose();
    _strip.dispose();
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

  /// audit_video_hub.md M5. One place, because four call sites below need
  /// it and a State has `context`.
  String get _shownTitle =>
      widget.content.displayTitle(AppStrings.of(context).locale.languageCode);

  Future<void> _playVideo(AlbumItem item) {
    return playMedia(
      context,
      ref,
      content: widget.content,
      source: item.source,
      titleOverride: _shownTitle,
    );
  }

  // The thumbnail strip's cells: the current one wider, as Telegram's.
  static const double _thumb = 40, _thumbCurrent = 56, _thumbGap = 3;

  void _centreStrip({bool jump = false}) {
    if (!_strip.hasClients) return;
    final x = _index * (_thumb + _thumbGap) +
        _thumbCurrent / 2 -
        _strip.position.viewportDimension / 2;
    final target = x.clamp(0.0, _strip.position.maxScrollExtent);
    if (jump) {
      _strip.jumpTo(target);
    } else {
      // ignore: discarded_futures
      _strip.animateTo(target,
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_pagingLocked) return;
    _settle.stop();
    setState(() => _drag += d.delta.dy);
  }

  void _onDragEnd(DragEndDetails d) {
    if (_pagingLocked) return;
    final v = d.primaryVelocity ?? 0;
    if (_drag.abs() > 110 || v.abs() > 900) {
      Navigator.of(context).maybePop();
      return;
    }
    _settleFrom = _drag;
    _settle.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    // Watched, not read: after a purchase the sheet pops back to this screen
    // and every locked page has to become unlocked without a manual refresh.
    ref.watch(viewerProvider);
    final s = AppStrings.of(context);
    final total = _items.length;
    final fade = (1 - _drag.abs() / 400).clamp(0.0, 1.0);
    final chrome = _chrome && _drag == 0;
    final pad = MediaQuery.paddingOf(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(children: <Widget>[
        Positioned.fill(
          child: ColoredBox(color: Colors.black.withValues(alpha: fade)),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => setState(() => _chrome = !_chrome),
            onVerticalDragUpdate: _onDragUpdate,
            onVerticalDragEnd: _onDragEnd,
            child: Transform.translate(
              offset: Offset(0, _drag),
              child: total == 0
                  ? const SizedBox.shrink()
                  : PageView.builder(
                      controller: _controller,
                      itemCount: total,
                      // Builds the next and previous page off screen, so the
                      // swipe lands on a picture already drawn.
                      allowImplicitScrolling: true,
                      physics: _pagingLocked
                          ? const NeverScrollableScrollPhysics()
                          : null,
                      onPageChanged: (i) {
                        setState(() {
                          _index = i;
                          _pagingLocked = false;
                        });
                        _centreStrip();
                      },
                      itemBuilder: _page,
                    ),
            ),
          ),
        ),
        // Top bar: close, "3 of 10", save this one.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          child: IgnorePointer(
            ignoring: !chrome,
            child: AnimatedOpacity(
              opacity: chrome ? 1 : 0,
              duration: const Duration(milliseconds: 150),
              child: Container(
                padding: EdgeInsets.only(top: pad.top),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0x99000000), Color(0x00000000)],
                  ),
                ),
                child: SizedBox(
                  height: 56,
                  child: Row(children: <Widget>[
                    IconButton(
                      icon: const Icon(Icons.arrow_back_rounded,
                          color: VH.textPrimary),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        total == 0 ? '' : s.vhCountOf(_index + 1, total),
                        style: VH.label.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    // Save THIS one — the manual, one-at-a-time download.
                    // Draws nothing for an item this viewer may not download.
                    if (total > 0 && _canOpen(_index))
                      AlbumItemDownloadButton(
                        key: ValueKey('viewer-dl-${_items[_index].id}'),
                        content: widget.content,
                        item: _items[_index],
                      ),
                  ]),
                ),
              ),
            ),
          ),
        ),
        // Bottom: the caption and Telegram's strip of the album's pictures.
        if (total > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              ignoring: !chrome,
              child: AnimatedOpacity(
                opacity: chrome ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: Container(
                  padding: EdgeInsets.only(bottom: pad.bottom + 8, top: 16),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0x99000000), Color(0x00000000)],
                    ),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                      child: Text(
                        _shownTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: VH.body.copyWith(color: VH.textPrimary),
                      ),
                    ),
                    SizedBox(height: _thumbCurrent, child: _thumbStrip()),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _thumbStrip() {
    return ListView.separated(
      controller: _strip,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(width: _thumbGap),
      itemBuilder: (context, i) {
        final item = _items[i];
        final current = i == _index;
        return GestureDetector(
          onTap: () => _controller.jumpToPage(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: current ? _thumbCurrent : _thumb,
            height: _thumbCurrent,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              border: current
                  ? Border.all(color: VH.textPrimary, width: 1.5)
                  : null,
            ),
            clipBehavior: Clip.antiAlias,
            child: Opacity(
              opacity: current ? 1 : 0.6,
              child: _canOpen(i)
                  ? PosterImage(
                      mediaRef:
                          item.thumbnail.isEmpty ? item.source : item.thumbnail,
                      title: '$_shownTitle ${item.id}',
                      glyph: item.isVideo
                          ? Icons.play_circle_outline
                          : Icons.image_outlined,
                    )
                  : BlurPreview(hash: item.preview),
            ),
          ),
        );
      },
    );
  }

  Widget _page(BuildContext context, int index) {
    final item = _items[index];
    if (!_canOpen(index)) {
      return _LockedPage(
        item: item,
        parentTitle: _shownTitle,
        onUnlock: () => promptUpgrade(context, ref, content: widget.content),
      );
    }
    // THE DATA SAVER: frost and a download button, and nothing fetched,
    // until the viewer asks for this one — see AlbumSaverGate.
    if (item.isVideo) {
      return AlbumSaverGate(
        content: widget.content,
        item: item,
        large: true,
        onPlay: () => _playVideo(item),
        normal: _VideoPage(
          heroTag: albumHeroTag(widget.content, item),
          item: item,
          title: _shownTitle,
          onPlay: () => _playVideo(item),
        ),
      );
    }
    return AlbumSaverGate(
      content: widget.content,
      item: item,
      large: true,
      normal: _photo(item),
    );
  }

  Widget _photo(AlbumItem item) {
    return ZoomablePhoto(
      key: ValueKey('photo-${item.id}'),
      onLockPaging: (lock) {
        if (lock != _pagingLocked && mounted) {
          setState(() => _pagingLocked = lock);
        }
      },
      child: Center(
        child: Hero(
          tag: albumHeroTag(widget.content, item),
          child: PosterImage(
            mediaRef: item.source.isEmpty ? item.thumbnail : item.source,
            title: '$_shownTitle ${item.id}',
            fit: BoxFit.contain,
            glyph: Icons.image_outlined,
          ),
        ),
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
class _LockedPage extends ConsumerWidget {
  final AlbumItem item;
  final String parentTitle;
  final VoidCallback onUnlock;

  const _LockedPage({
    required this.item,
    required this.parentTitle,
    required this.onUnlock,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    // With the data saver on, the frost is the blurhash: fetching the photo
    // only to blur it is the cost the saver exists to avoid.
    // Frosted while the connection question is pending, for the same reason
    // as AlbumSaverGate: the first frame must not fetch.
    final saver =
        ref.watch(playerSettingsProvider).get(PlayerSetting.albumDataSaver) &&
            (ref.watch(albumSaverProvider).valueOrNull ?? true);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (saver)
          BlurPreview(hash: item.preview)
        else
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
  final String heroTag;

  const _VideoPage({
    required this.heroTag,
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
        Hero(
          tag: heroTag,
          child: PosterImage(
            mediaRef: item.thumbnail.isEmpty ? item.source : item.thumbnail,
            title: '$title ${item.id}',
            fit: BoxFit.contain,
            glyph: Icons.play_circle_outline,
          ),
        ),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              IconButton(
                iconSize: 64,
                icon: const Icon(Icons.play_circle_fill, color: VH.textPrimary),
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
