import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/preferences_provider.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/services/media/video_duration_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../user_data/user_data_providers.dart';
import '../domain/folder.dart';
import '../domain/video.dart';
import 'new_badge_providers.dart';
import 'hidden_badge.dart';
import 'library_provider.dart';
import 'selection_provider.dart';
import '../../player/presentation/floating_pip_provider.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
import 'folder_list_item.dart' show VideoCover, FolderShapePainter, FolderTick;
/// Phase 15: Grid tile for a folder (MX Player grid layout parity).
class FolderGridTile extends ConsumerWidget {
  final Folder folder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  const FolderGridTile({
    super.key,
    required this.folder,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Real NEW count for this folder, narrowed with `.select` so finishing one
    // video does not rebuild every folder tile on screen.
    final newCount = ref.watch(
        folderNewCountsProvider.select((m) => m[folder.path] ?? 0));
    final showThumbs = ref.watch(preferencesProvider).showThumbnails;
    final coverPaths = ref.watch(folderCoverPathsProvider);
    // Phase 44: prefer the cover path from the fast bucket scan; fall
    // back to the map (which lazily fills from allVideosProvider).
    final coverUri = folder.coverThumbnailPath ?? coverPaths[folder.path];
    final Widget silhouette = CustomPaint(
      painter: const FolderShapePainter(),
      child: _gridFolderIcon(folder.name) == Icons.folder
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Icon(
                  _gridFolderIcon(folder.name),
                  color: const Color(0xFF7D8790),
                  size: 22,
                ),
              ),
            ),
    );

    // Selected-folder highlight (innocent_folders_grid_spec): the folder
    // containing the currently-playing / PiP video gets its name tinted.
    // Same matching logic as the list tile so both views agree.
    final pipUri = ref.watch(floatingPipProvider).activeUri;
    bool isActiveFolder = false;
    if (pipUri != null) {
      try {
        if (pipUri.startsWith('file://')) {
          isActiveFolder =
              Uri.parse(pipUri).toFilePath().startsWith(folder.path);
        } else {
          isActiveFolder = pipUri.contains(folder.name);
        }
      } catch (_) {
        isActiveFolder = false;
      }
    }

    return InkWell(
      onTap: selectionMode ? onLongPress : onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // MX PLAYER'S GRID FOLDER: the same 72 x 54 dp silhouette as the
          // list (FolderShapePainter), three to a row, measured from MX's
          // screenshots on a 411 dp phone. The badge floats at (-2,-2).
          Stack(
            clipBehavior: Clip.none,
            children: [
              SizedBox(
                width: 72,
                height: 54,
                child: (showThumbs && coverUri != null)
                    ? VideoCover(
                        videoUri: coverUri,
                        assetId: ref.watch(folderCoverAssetIdsProvider)[folder.path],
                        placeholder: silhouette,
                      )
                    : silhouette,
              ),
              // Unread count badge — 18 dp red bubble, white bold number.
              // Reads the real count (see folderNewCountsProvider); the
              // folder's own `newCount` was a data-source guess that could
              // only ever be 0 or 1 and never checked playback records.
              if (newCount > 0)
                Positioned(
                  top: -2,
                  right: -2,
                  child: Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: AppColors.specBadge,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      newCount > 99 ? '99+' : '$newCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              // Mark hidden folders (dot-folders + Android/data|obb caches
              // surfaced over ADB/iADB).
              if (_gridFolderHidden(folder))
                const Positioned(
                  bottom: 2,
                  left: 2,
                  child: HiddenCornerBadge(),
                ),
              // Selection (grid): the same pale disc and tick MX draws on a
              // selected folder in the list.
              if (selected) const Positioned.fill(child: FolderTick()),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            folder.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isActiveFolder
                  ? AppColors.specSelectedLabel
                  : Colors.white,
              fontSize: 15.5,
              fontWeight: FontWeight.w400,
            ),
          ),
          Text(
            // Localised: this was English for everyone ("96 videos" on a
            // Burmese phone). The list view already said it in Burmese.
            AppStrings.of(context).vhAlbumVideos(folder.videoCount),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppColors.specTextSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// True when a folder lives where normal galleries hide media — Android/data
/// or Android/obb caches (surfaced over ADB/iADB) or dot-folders. Mirrors the
/// list view's rule so both stay consistent.
bool _gridFolderHidden(Folder folder) {
  final cover = folder.coverThumbnailPath ?? '';
  if (cover.startsWith('adb://')) return true;
  final path = folder.path;
  if (path.contains('/Android/data/') || path.contains('/Android/obb/')) {
    return true;
  }
  return folder.name.startsWith('.');
}

/// Folder-type glyph shown inside the grid thumbnail when no cover is
/// available. Mirrors the list view's mapping so both stay consistent.
IconData _gridFolderIcon(String name) {
  final n = name.toLowerCase();
  if (n.contains('movie') || n == 'full movies') return Icons.movie_outlined;
  if (n.contains('camera')) return Icons.photo_camera_outlined;
  if (n.contains('screen recording') || n.contains('screen rec')) {
    return Icons.videocam_outlined;
  }
  if (n.contains('telegram')) return Icons.send_outlined;
  if (n.contains('messenger') || n.contains('whatsapp')) {
    return Icons.chat_outlined;
  }
  if (n.contains('download')) return Icons.download_outlined;
  if (n.contains('youtube') || n.contains('snaptube')) {
    return Icons.play_circle_outline;
  }
  if (n.contains('music') || n.contains('karaoke')) {
    return Icons.music_note_outlined;
  }
  if (n.contains('tiktok')) return Icons.video_collection_outlined;
  return Icons.folder;
}

/// Phase 15: Grid tile for a video.
class VideoGridTile extends ConsumerWidget {
  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onMoreTap;
  final VoidCallback? onLongPress;
  final bool showNewBadge;

  const VideoGridTile({
    super.key,
    required this.video,
    required this.onTap,
    this.onMoreTap,
    this.onLongPress,
    this.showNewBadge = false,
  });

  String _fmtDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String? _localPath() {
    if (video.uri.startsWith('file://')) {
      try {
        return Uri.parse(video.uri).toFilePath();
      } catch (_) {
        return null;
      }
    }
    if (video.uri.startsWith('/')) return video.uri;
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final selectionActive = selection.isNotEmpty;
    final isSelected = selection.contains(video.uri);
    // Code-quality audit: `.select` so unrelated preference changes
    // don't rebuild every grid tile during scroll.
    final showThumbs = ref.watch(
        preferencesProvider.select((p) => p.showThumbnails));
    final localPath = _localPath();
    // The list honours "show file extension"; the grid ignored it and showed
    // ".mp4" on every title.
    final showExt = ref.watch(
        libraryPreferencesProvider.select((p) => p.showFileExt));
    final dot = video.title.lastIndexOf('.');
    final title =
        showExt || dot <= 0 ? video.title : video.title.substring(0, dot);
    // MediaStore reports 0 for a file indexed before its metadata was ready;
    // fall back to the real length read off the header (arrives async, rebuilds
    // this tile). Mirrors the list-item behaviour.
    final effectiveDuration = video.duration > Duration.zero
        ? video.duration
        : (ref.watch(videoDurationCacheProvider).durationFor(video.uri) ??
            Duration.zero);

    return InkWell(
      onTap: selectionActive
          ? () => ref.read(selectionProvider.notifier).toggle(video.uri)
          : onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.accentBlue12
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  children: [
                    if (showThumbs && localPath != null)
                      Positioned.fill(
                        child: _VideoGridThumb(
                            path: localPath, assetId: video.id),
                      )
                    else
                      Positioned.fill(
                        child: Container(
                          color: AppColors.specSurface,
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.play_circle_outline,
                            color: AppColors.white30,
                            size: 36,
                          ),
                        ),
                      ),
                    if (showNewBadge)
                      Positioned(
                        top: 4,
                        left: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppColors.specBadge,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(AppStrings.of(context).newBadge,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    if (video.isHidden)
                      const Positioned(
                        bottom: 4,
                        left: 4,
                        child: HiddenCornerBadge(),
                      ),
                    Positioned(
                      bottom: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: const Color(0xC7000000),
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: Text(
                          _fmtDuration(effectiveDuration),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ),
                    // Phase 43: progress bar at the bottom for partially-
                    // watched videos. Same logic as the list-item variant.
                    // Code-quality audit: was using `Builder` with the
                    // outer `ref`, which still subscribed the parent
                    // grid tile to historyProvider — every progress
                    // save rebuilt every visible grid item. `Consumer`
                    // gives a fresh `ref` scope so only this small
                    // subtree rebuilds when history changes.
                    Consumer(builder: (_, innerRef, __) {
                      // Same change as the list tile: one prebuilt lookup plus
                      // `.select`, instead of every tile scanning the whole
                      // history on every save.
                      final key = normalizeMediaUri(video.uri);
                      final progress = innerRef.watch(
                          watchProgressProvider.select((m) => m[key]));
                      if (progress == null || progress <= 0.0) {
                        return const SizedBox.shrink();
                      }
                      return Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: SizedBox(
                          height: 2.5,
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: AppColors.black40,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                                AppColors.accentBlue),
                          ),
                        ),
                      );
                    }),
                    if (selectionActive)
                      Positioned(
                        top: 4,
                        right: 4,
                        child: Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          color: isSelected
                              ? AppColors.accentBlue
                              : Colors.white70,
                          size: 22,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 9),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    title,
                    // MX: one line under the thumbnail.
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ),
                // innocent_videos_grid_spec: per-item overflow kebab,
                // right edge, at the title baseline. Wired to the same
                // VideoOptionMenu the list view uses.
                if (onMoreTap != null)
                  GestureDetector(
                    onTap: onMoreTap,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 4, top: 1),
                      child: Icon(
                        Icons.more_vert,
                        size: 18,
                        color: AppColors.specTextSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoGridThumb extends StatefulWidget {
  final String path;
  final String? assetId;
  const _VideoGridThumb({required this.path, this.assetId});

  @override
  State<_VideoGridThumb> createState() => _VideoGridThumbState();
}

class _VideoGridThumbState extends State<_VideoGridThumb> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Robust MediaStore asset thumbnail first (works on SD cards / scoped
    // storage), then fall back to the raw-path decoder.
    final assetId = widget.assetId;
    if (assetId != null && assetId.isNotEmpty) {
      try {
        final bytes = await ThumbnailCache.instance.getByAsset(assetId);
        if (bytes != null) {
          if (mounted) {
            setState(() {
              _bytes = bytes;
            });
          }
          return;
        }
      } catch (_) {/* fall through */}
    }
    try {
      if (!await File(widget.path).exists()) {
        return;
      }
      final bytes = await ThumbnailCache.instance.get(widget.path);
      if (mounted) {
        setState(() {
          _bytes = bytes;
        });
      }
    } catch (_) {
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes != null) {
      return SafeThumbnail(bytes: _bytes!);
    }
    return Container(
      color: AppColors.darkSurfaceVariant,
      alignment: Alignment.center,
      // A still icon while the frame loads, not a spinner: with a large
      // library dozens of rings would animate down the screen at 60 fps for
      // as long as decoding took.
      child: const Icon(
        Icons.movie_outlined,
        color: AppColors.darkOnSurfaceMuted,
        size: 32,
      ),
    );
  }
}
