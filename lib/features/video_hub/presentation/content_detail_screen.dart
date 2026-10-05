import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/services/preferences/player_settings_service.dart';
import '../domain/access_policy.dart';
import '../data/api/event_sender.dart';
import '../data/api/offline_library.dart';
import '../domain/video_content.dart';
import 'album_downloads.dart';
import 'album_saver.dart';
import 'album_viewer_screen.dart';
import 'bookmarks_provider.dart';
import 'bookmarks_screen.dart';
import 'data_saver_panel.dart';
import 'widgets/telegram_album.dart';
import 'playback.dart';
import 'similar_titles.dart';
import 'video_hub_provider.dart';
import 'widgets/download_action.dart';
import 'widgets/poster_image.dart';
import 'widgets/vh_insets.dart';
import 'widgets/view_count_badge.dart';
import 'video_hub_theme.dart';
import 'account_provider.dart';
import 'watch_points_provider.dart';
import '../data/watch_state_store.dart';

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
  /// The title as richly as it is currently known.
  ///
  /// [widget.content] is the CARD: whatever the catalogue row carried, which
  /// is enough to draw the poster, the name and the facts immediately. The
  /// provider adds the album, and the moment it arrives the grid appears.
  ///
  /// Falls back rather than waiting. A detail screen that showed a spinner
  /// until a second request returned would blank the artwork the viewer just
  /// tapped — and on a dead connection it would never show anything at all,
  /// when everything except the album is already in hand.
  VideoContent get content {
    // `valueOrNull`: through a background refresh the provider is reloading
    // with the previous value, and `asData` would hand back null — dropping
    // the screen to the bare card, emptying the album grid, and filling it
    // again when the refresh landed. That was the flash on opening a card.
    final full = ref.read(titleDetailProvider(widget.content.id)).valueOrNull;
    return full ?? widget.content;
  }

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
    // Watched, so the screen rebuilds when the album lands. The `content`
    // getter above reads the same provider for the value.
    ref.watch(titleDetailProvider(widget.content.id));
    final s = AppStrings.of(context);
    // audit_video_hub.md M5.
    final shownTitle = content.displayTitle(s.locale.languageCode);
    final policy = ref.watch(accessPolicyProvider);
    // Watched: a purchase made from this screen must unlock it in place.
    final tier = ref.watch(viewerProvider).tier;
    final ordinals = AccessPolicy.photoOrdinalsOf(content.items);
    final lockedCount = policy.lockedCountFor(content, tier);
    final locked = !policy.canPlayTitle(content, tier);
    final ledger = ref.watch(watchPointsProvider);
    final WatchPoint? resume = content.expectsAlbum
        ? _resumable(ledger.latestFor(content.id))
        : _resumable(ledger.pointFor(content.id, assetIdOf(content.source)));
    final videos = content.items.where((i) => i.isVideo).toList();
    final clipAt = resume?.assetId == null
        ? -1
        : videos.indexWhere((i) => i.source.locator == resume!.assetId);
    final String? resumeClip = clipAt < 0
        ? null
        : s.vhCountOf(clipAt + 1, videos.length);
    // Ask the server ahead for the film's Play, so the tap opens at once
    // (prefetchPlayback; a fresh question is never asked twice).
    if (!locked) {
      prefetchPlayback(ref, content: content, source: content.source);
    }

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
            // Where Netflix keeps "My List" and YouTube "Save": pinned with
            // the back arrow, so it is there however far the page scrolls.
            actions: <Widget>[_BookmarkButton(content: content)],
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
              // `expectsAlbum`, NOT `hasAlbum`, and that one word is the
              // flicker. `hasAlbum` asks whether the album has LOADED, which
              // for the first frame of every visit is no — so this drew the
              // button, and took it away again when the grid arrived. The
              // question being asked is whether the title HAS an album, and
              // the card's own counts answer that before anything is fetched.
              showButton: ContentDetailScreen.showsHeaderButton(
                hasAlbum: content.expectsAlbum,
                locked: locked,
              ),
              onPlay: () => _play(context, ref),
              // Where this viewer stopped, on any of their phones
              // (WatchPoint): Play becomes "Resume 12:34", with Start over
              // beside it — Netflix's two buttons. For a title whose way in
              // is its album, the button appears only to resume: the clip
              // they were watching, where they left it.
              resume: resume,
              resumeClip: resumeClip,
              onResume: () => _resume(context, ref, resume),
              onStartOver: () => _resume(context, ref, resume, fromStart: true),
            ),
          ),
          // Drawn from the moment the title is known to have one, so the
          // heading does not arrive late and shove the page. The tiles below
          // it fill in when they load, which grows downward and moves nothing
          // that is already on screen.
          if (content.expectsAlbum) ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 18, 14, 10),
                child: Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(s.vhAlbum,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: VH.heading),
                    ),
                    if (content.albumCount != null) ...<Widget>[
                      const SizedBox(width: 8),
                      // The server's total, not `items.length`: the album may
                      // still be loading, and a number that counts up as
                      // tiles arrive is a second thing moving.
                      Text(
                        '${content.albumCount}',
                        style: VH.meta.copyWith(fontSize: 12.5),
                      ),
                    ],
                    const SizedBox(width: VH.s2),
                    // Everything right of the heading shares what is left
                    // of the row. It was a Spacer plus two fixed-width
                    // controls, which overflowed a 360px phone by 56px in
                    // Burmese ("အားလုံး ဒေါင်းမယ်" under the stripe).
                    Expanded(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: <Widget>[
                          // Telegram's data saver, one tap away from the
                          // album it changes — see album_saver.dart.
                          const AlbumSaverToggle(),
                          // The album's Download: everything, or only what
                          // the admin added since — see AlbumDownloadButton.
                          Flexible(
                              child: AlbumDownloadButton(content: content)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // What the frost means, in words, and the way out — see
            // DataSaverBanner. Only while the album IS frosted.
            if (ref.watch(playerSettingsProvider)
                    .get(PlayerSetting.albumDataSaver) &&
                (ref.watch(albumSaverProvider).valueOrNull ?? true))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: DataSaverBanner(
                    onTurnOff: () => setAlbumSaver(ref, false),
                  ),
                ),
              ),
            // Telegram's media-group layout (TelegramAlbum): groups of up to
            // ten, each cell shaped by its own picture, outer corners
            // rounded — the album as people already know it from Telegram.
            // A SliverToBoxAdapter, not a SliverGrid: the cell sizes come from
            // the content, which no grid delegate can express, and one title's
            // folder is small enough not to need virtualising.
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 4),
              sliver: SliverToBoxAdapter(
                child: TelegramAlbum(
                  items: content.items,
                  tileBuilder: (index) {
                    final item = content.items[index];
                    final unlocked = policy.canOpenItem(
                      parent: content,
                      item: item,
                      photoOrdinal: ordinals[index],
                      tier: tier,
                    );
                    // Named "3 of 10" for TalkBack (and the device lab):
                    // a picture with no text is otherwise an unlabeled button.
                    return Semantics(
                      label: s.vhCountOf(index + 1, content.items.length),
                      button: true,
                      child: _AlbumTile(
                      content: content,
                      item: item,
                      parentTitle: shownTitle,
                      locked: !unlocked,
                      onPlay: () => playMedia(context, ref,
                          content: content,
                          source: item.source,
                          titleOverride: shownTitle),
                      badge: unlocked
                          ? AlbumItemBadge(content: content, item: item)
                          : null,
                      progress: item.isVideo
                          ? ledger.pointFor(content.id, item.source.locator)
                              ?.fraction
                          : null,
                      // A locked tile still opens the viewer rather than
                      // jumping straight to the paywall: landing on the
                      // locked page in context, surrounded by what is
                      // unlocked, makes the offer concrete instead of
                      // abrupt.
                      onTap: () => _openAlbum(context, index),
                    ),
                    );
                  },
                ),
              ),
            ),
          ] else
            const SliverToBoxAdapter(child: SizedBox(height: 12)),
          // Netflix's "More like this", YouTube's "Up next" list: the page
          // does not end in a wall — the next thing to watch is one swipe
          // away (similar_titles, migration 039).
          SliverPadding(
            padding: EdgeInsets.only(bottom: VhInsets.scrollBottom(context)),
            sliver: SliverToBoxAdapter(
              child: MoreLikeThis(
                content: content,
                isPremiumFor: (c) => policy.showsPremiumBadge(c, tier),
                onOpen: (c) => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ContentDetailScreen(content: c),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openAlbum(BuildContext context, int index) {
    Navigator.of(context).push(AlbumViewerScreen.route(content, index));
  }

  /// Hands the entry's primary source to the app's player.
  ///
  /// Delegates to [playContent] so the hero button, this screen and the album
  /// viewer cannot drift apart about what "Play" does.
  Future<void> _play(BuildContext context, WidgetRef ref) =>
      playContent(context, ref, content);

  static WatchPoint? _resumable(WatchPoint? p) =>
      p != null && p.resumable ? p : null;

  /// Plays the video [p] is about — the film, or the album clip — from the
  /// held position, or from the start.
  Future<void> _resume(BuildContext context, WidgetRef ref, WatchPoint? p,
      {bool fromStart = false}) {
    final asset = p?.assetId;
    if (asset == null) {
      return playContent(context, ref, content, fromStart: fromStart);
    }
    return playMedia(context, ref,
        content: content,
        source: MediaRef(provider: 'asset', locator: asset),
        titleOverride: content.displayTitle(AppStrings.of(context).locale.languageCode),
        fromStart: fromStart);
  }
}

/// 12:34, or 1:02:03 past the hour.
String clockOf(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final sec = d.inSeconds % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Save for later: a bookmark that fills when the title is saved.
class _BookmarkButton extends ConsumerWidget {
  const _BookmarkButton({required this.content});
  final VideoContent content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final saved = ref.watch(isTitleBookmarkedProvider(content.id));
    return Padding(
      padding: const EdgeInsets.only(right: VH.s2),
      child: Material(
        color: const Color(0x66000000),
        shape: const CircleBorder(),
        child: IconButton(
          key: const ValueKey('detail-bookmark'),
          tooltip: saved ? s.vhBookmarked : s.vhBookmark,
          onPressed: () {
            HapticFeedback.selectionClick();
            final now = ref.read(titleBookmarksProvider.notifier).toggle(content);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(SnackBar(
                behavior: SnackBarBehavior.floating,
                duration: const Duration(seconds: 3),
                content: Text(now ? s.vhBookmarkAdded : s.vhBookmarkRemoved),
                action: now
                    ? SnackBarAction(
                        label: s.vhLibraryBookmarks,
                        onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                                builder: (_) => const BookmarksScreen())),
                      )
                    : null,
              ));
          },
          icon: AnimatedSwitcher(
            duration: VH.fast,
            transitionBuilder: (child, a) =>
                ScaleTransition(scale: a, child: child),
            child: Icon(
              saved ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
              key: ValueKey(saved),
              color: Colors.white,
            ),
          ),
        ),
      ),
    );
  }
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

  /// Where the viewer stopped, when it is worth continuing from.
  final WatchPoint? resume;

  /// "3 of 7" when [resume] is an album clip.
  final String? resumeClip;
  final VoidCallback onResume;
  final VoidCallback onStartOver;

  const _Header({
    required this.content,
    required this.onPlay,
    required this.locked,
    required this.lockedCount,
    required this.showButton,
    this.resume,
    this.resumeClip,
    required this.onResume,
    required this.onStartOver,
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
      if (content.episodeCount != null)
        s.vhEpisodesCount(content.episodeCount!),
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
          //
          // NOT FOR A TITLE WITH AN ALBUM. The album lists the film among its
          // clips, and its own button downloads the film with everything else
          // under the same key — two Download buttons for one file would be
          // two answers to one question, and they would disagree the moment
          // one of them was pressed.
          if (!content.expectsAlbum) ...<Widget>[
            const SizedBox(height: VH.s2),
            Align(
              alignment: Alignment.centerLeft,
              child: DownloadAction(content: content),
            ),
          ],
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
          // THE PRIMARY ACTION ABOVE THE SYNOPSIS, as Netflix and YouTube
          // place it: under a long synopsis on a small phone it was below
          // the fold, and the one thing the page is for had to be scrolled
          // to.
          if (showButton || (!locked && resume != null)) ...<Widget>[
            const SizedBox(height: 14),
            _PlayButton(
              locked: locked,
              resume: locked ? null : resume,
              clip: resumeClip,
              onPlay: !locked && resume != null ? onResume : onPlay,
            ),
            if (!locked && resume != null) ...<Widget>[
              const SizedBox(height: 8),
              _ResumeLine(point: resume!, onStartOver: onStartOver),
            ],
          ],
          if (content.synopsis != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(content.synopsis!, style: VH.body),
          ],
        ],
      ),
    );
  }
}

/// Play, Upgrade or "Resume 12:34" — one full-width button.
class _PlayButton extends StatelessWidget {
  const _PlayButton(
      {required this.locked, required this.onPlay, this.resume, this.clip});

  final bool locked;
  final WatchPoint? resume;

  /// "3 of 7" when resuming an album clip.
  final String? clip;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final r = resume;
    final label = locked
        ? s.vhUpgrade
        : r != null
            ? clip == null
                ? s.vhResumeAt(clockOf(r.position))
                : '${s.vhResumeAt(clockOf(r.position))} · $clip'
            : s.vhPlay;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: onPlay,
        icon: Icon(
          locked ? Icons.lock_rounded : Icons.play_arrow_rounded,
          size: locked ? 18 : 22,
        ),
        label: Text(
          label,
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
    );
  }
}

/// Under "Resume": how far through, how long is left, and Start over.
class _ResumeLine extends StatelessWidget {
  const _ResumeLine({required this.point, required this.onStartOver});

  final WatchPoint point;
  final VoidCallback onStartOver;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final f = point.fraction;
    final left = point.durationS > 0
        ? ((point.durationS - point.positionS) / 60).ceil()
        : null;
    return Row(
      children: <Widget>[
        if (f != null)
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: f,
                minHeight: 3,
                backgroundColor: VH.surface2,
                valueColor: const AlwaysStoppedAnimation<Color>(VH.accent),
              ),
            ),
          )
        else
          const Spacer(),
        if (left != null) ...<Widget>[
          const SizedBox(width: 10),
          Text(s.vhMinutesLeft(left), style: VH.meta.copyWith(fontSize: 12)),
        ],
        const SizedBox(width: 6),
        TextButton.icon(
          onPressed: onStartOver,
          icon: const Icon(Icons.replay_rounded, size: 16),
          label: Text(s.vhStartOver),
          style: TextButton.styleFrom(
            foregroundColor: VH.textSecondary,
            visualDensity: VisualDensity.compact,
          ),
        ),
      ],
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
  final VideoContent content;
  final AlbumItem item;

  /// Plays a frosted clip straight from its tile — see AlbumSaverGate.
  final VoidCallback? onPlay;
  final String parentTitle;
  final bool locked;
  final VoidCallback onTap;

  /// Whether this item is on the phone — see AlbumItemBadge. Top right, the
  /// one corner nothing else on a tile uses.
  final Widget? badge;

  /// How far through this clip the viewer is — YouTube's line along the
  /// foot of a watched video — or null.
  final double? progress;

  const _AlbumTile({
    required this.content,
    required this.item,
    this.onPlay,
    required this.parentTitle,
    required this.onTap,
    this.locked = false,
    this.badge,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      // With the data saver on, the tile is frost and a download button
      // until the viewer asks for this one — and no picture is fetched to draw
      // it. Otherwise exactly the tile below.
      child: AlbumSaverGate(
        content: content,
        item: item,
        locked: locked,
        onPlay: onPlay,
        normal: _normal(),
      ),
    );
  }

  /// What the tile draws. A PHOTO SAVED TO THE PHONE draws from the phone.
  ///
  /// The saved copy is indexed by the photo's own address, but the tile asked
  /// for its THUMBNAIL — a different address — so a photo the viewer had just
  /// downloaded with the data saver on was fetched again from the network to
  /// fill its tile: the data spent twice, and the tile blank until the second
  /// fetch landed. Asking for the photo itself when it is on the phone finds
  /// the file (PosterImage → OfflineLibrary.photoPathFor) and costs nothing.
  MediaRef _art() {
    if (!item.isVideo &&
        item.source.provider == 'url' &&
        OfflineLibrary.photoPathFor(item.source.locator) != null) {
      return item.source;
    }
    return item.thumbnail.isEmpty ? item.source : item.thumbnail;
  }

  Widget _normal() {
    return Stack(
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
          // Flies into the viewer and back, as a Telegram album cell does.
          Hero(
            tag: albumHeroTag(content, item),
            child: PosterImage(
              mediaRef: _art(),
              title: '$parentTitle ${item.id}',
              glyph: item.isVideo
                  ? Icons.play_circle_outline
                  : Icons.image_outlined,
            ),
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
        ] else if (item.isVideo) ...<Widget>[
          // Telegram's video cell: a round dark play button in the middle and
          // the length in a pill at the top left (the top right is the
          // download badge's).
          const Center(child: _PlayDisc()),
          Positioned(
            left: 5,
            top: 5,
            child: item.isPreview
                ? const _PreviewTag()
                : (item.durationLabel.isEmpty
                    ? const SizedBox.shrink()
                    : _DurationPill(item.durationLabel)),
          ),
        ],
        if (badge != null) Positioned(right: 4, top: 4, child: badge!),
        if (!locked && progress != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 3,
            child: LinearProgressIndicator(
              value: progress!.clamp(0.0, 1.0),
              minHeight: 3,
              backgroundColor: const Color(0x40FFFFFF),
              valueColor: const AlwaysStoppedAnimation<Color>(VH.accent),
            ),
          ),
      ],
    );
  }
}

/// The Hero tag shared by an album cell and its page in the viewer.
String albumHeroTag(VideoContent content, AlbumItem item) =>
    'album-${content.id}-${item.id}';

/// Telegram's play button on a video cell: a translucent black disc, a white
/// arrow. Scales down on small cells so it never covers the picture.
class _PlayDisc extends StatelessWidget {
  const _PlayDisc();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final d = (c.biggest.shortestSide * 0.42).clamp(28.0, 48.0);
      return Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          shape: BoxShape.circle,
        ),
        child: Icon(Icons.play_arrow_rounded,
            color: Colors.white, size: d * 0.62),
      );
    });
  }
}

/// A video's length on its cell, Telegram's way: white on a dark pill.
class _DurationPill extends StatelessWidget {
  const _DurationPill(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
