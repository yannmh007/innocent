import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/di/preferences_provider.dart';
import '../../player/presentation/floating_pip_provider.dart';
import '../../user_data/user_data_providers.dart';
import 'library_provider.dart';
import 'selection_provider.dart';

import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/services/media/video_duration_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/video.dart';
import 'hidden_badge.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
/// Video list item — MX Player parity.
/// - Compact: ~96×56 thumb
/// - Title + metadata line (size/date/path/resolution/etc) per Fields prefs
/// - Length-over-thumb togglable
/// - Currently-playing video is highlighted in blue (Phase 17)
class VideoListItem extends ConsumerWidget {
  final Video video;
  final VoidCallback onTap;
  final VoidCallback? onMoreTap;
  final VoidCallback? onLongPress;
  final bool showNewBadge;

  const VideoListItem({
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

  /// Build the meta-data line(s) under the title from per-Fields prefs.
  /// Mirrors MX Player's behaviour: when more than one field is toggled
  /// on, the values are joined by " · ".
  List<String> _buildMetaLines(
    LibraryPreferences libPrefs,
    Duration effectiveDuration,
  ) {
    final parts = <String>[];
    if (libPrefs.showSize && video.sizeBytes > 0) {
      parts.add(video.formattedSize);
    }
    if (libPrefs.showDate && video.dateAdded != null) {
      parts.add(DateFormat('MMM d').format(video.dateAdded!));
    }
    if (libPrefs.showResolution && video.height > 0) {
      parts.add(video.resolutionLabel);
    }
    if (libPrefs.showFrameRate) {
      // Frame rate isn't reliably exposed by MediaStore; show placeholder
      // value only when explicitly toggled. (Real impl would query metadata.)
      parts.add('—fps');
    }
    if (libPrefs.showPlayedTime) {
      // Same — exposed via resume storage in real impl; placeholder here.
      // We intentionally don't add anything noisy.
    }
    // Length is shown either over-thumb or inline depending on
    // displayLengthOverThumb preference; we handle it separately.
    if (libPrefs.showLength && !libPrefs.displayLengthOverThumb) {
      parts.add(_fmtDuration(effectiveDuration));
    }
    return parts;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selection = ref.watch(selectionProvider);
    final selectionActive = selection.isNotEmpty;
    final isSelected = selection.contains(video.uri);
    final pipUri = ref.watch(floatingPipProvider).activeUri;
    final isPlaying = pipUri != null && pipUri == video.uri;
    final libPrefs = ref.watch(libraryPreferencesProvider);
    // MediaStore reports 0 for a file it indexed before its metadata was ready
    // (every fresh download). Fall back to the real length read off the header,
    // which arrives asynchronously and rebuilds this tile when it does.
    final effectiveDuration = video.duration > Duration.zero
        ? video.duration
        : (ref.watch(videoDurationCacheProvider).durationFor(video.uri) ??
            Duration.zero);
    final metaParts = _buildMetaLines(libPrefs, effectiveDuration);

    // Title with optional file extension stripped
    final displayTitle = libPrefs.showFileExt
        ? video.title
        : _stripExtension(video.title);

    // Audit: wrap the entire tile in RepaintBoundary so neighbour
    // tiles don't repaint when only one updates (e.g., its progress
    // bar after a watch session). Measurable smoothness win on long
    // scroll lists.
    return Semantics(
      label: 'Video: ${displayTitle}',
      button: true,
      child: RepaintBoundary(
      child: InkWell(
      onTap: selectionActive
          ? () => ref.read(selectionProvider.notifier).toggle(video.uri)
          : onTap,
      onLongPress: onLongPress,
      child: Container(
        color: isSelected
            ? AppColors.accentBlue12
            : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              if (selectionActive)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    isSelected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: isSelected
                        ? AppColors.accentBlue
                        : AppColors.darkOnSurfaceMuted,
                    size: 22,
                  ),
                ),
              if (libPrefs.showThumbnail &&
                  // Code-quality audit: was watching the full
                  // preferencesProvider, which rebuilt the tile when
                  // ANY preference changed. `.select` narrows the
                  // subscription to just `showThumbnails`.
                  ref.watch(preferencesProvider
                      .select((p) => p.showThumbnails)))
                Stack(
                  children: [
                    _Thumbnail(videoPath: _localPath(video), assetId: video.id),
                    if (showNewBadge)
                      Positioned(
                        top: 0,
                        left: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: const BoxDecoration(
                            color: AppColors.error,
                            borderRadius: BorderRadius.only(
                              topLeft: Radius.circular(4),
                              bottomRight: Radius.circular(4),
                            ),
                          ),
                          child: Text(AppStrings.of(context).newBadge,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    if (libPrefs.showLength && libPrefs.displayLengthOverThumb)
                      Positioned(
                        bottom: 3,
                        left: 3,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.black75,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            _fmtDuration(effectiveDuration),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    // Phase 43: progress bar at the bottom of the
                    // thumbnail for partially-watched videos. Reads
                    // HistoryEntry.progress for this exact URI.
                    //
                    // Code-quality audit: was using `Builder` with the
                    // outer `ref`, which still subscribed the parent
                    // tile to historyProvider — meaning every progress
                    // save anywhere rebuilt every visible list item.
                    // `Consumer` gives a fresh `ref` scope so only this
                    // small subtree rebuilds when history changes.
                    Consumer(builder: (_, innerRef, __) {
                      // Was: watch the whole history list and scan it here.
                      // That is up to 200 string comparisons per visible tile
                      // every time any position is saved — with twenty tiles
                      // on screen, four thousand comparisons for one write.
                      // `watchProgressProvider` builds the lookup once, and
                      // `.select` narrows this subtree to THIS file's value,
                      // so a save for a different video rebuilds nothing here.
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
                  ],
                )
              else if (libPrefs.showThumbnail)
                const _ThumbnailPlaceholder(),
              if (libPrefs.showThumbnail) const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayTitle,
                      style: TextStyle(
                        color: isPlaying
                            ? AppColors.accentBlue
                            : AppColors.darkOnSurface,
                        fontSize: 14,
                        height: 1.25,
                        fontWeight:
                            isPlaying ? FontWeight.w500 : FontWeight.w400,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (video.isHidden || metaParts.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      // Phase 30: MX renders each meta item as a SEPARATE
                      // dark rounded pill badge (verified screen recording).
                      // Earlier impl joined them with " · " in a single Text.
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          if (video.isHidden) const HiddenBadge(),
                          for (final part in metaParts)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.white08,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                part,
                                style: TextStyle(
                                  color: AppColors.darkOnSurface
                                      .withOpacity(0.75),
                                  fontSize: 10,
                                  height: 1.2,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                    if (libPrefs.showPath) ...[
                      const SizedBox(height: 2),
                      Text(
                        video.folderPath,
                        style: TextStyle(
                          color: AppColors.darkOnSurface
                              .withOpacity(0.4),
                          fontSize: 10,
                          height: 1.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (onMoreTap != null && !selectionActive)
                IconButton(
                  tooltip: 'More options',
                  icon: const Icon(
                    Icons.more_vert,
                    color: AppColors.darkOnSurfaceMuted,
                    size: 20,
                  ),
                  onPressed: onMoreTap,
                ),
            ],
          ),
        ),
      ),
    ),
    ),
    );
  }

  String _stripExtension(String s) {
    final i = s.lastIndexOf('.');
    if (i <= 0) return s;
    return s.substring(0, i);
  }

  String _localPath(Video v) {
    final uri = v.uri;
    if (uri.startsWith('file://')) {
      return Uri.parse(uri).toFilePath();
    }
    if (uri.startsWith('content://')) {
      return uri;
    }
    return uri;
  }
}

/// Compact thumbnail (~96×56, 16:9.3).
class _Thumbnail extends StatefulWidget {
  final String videoPath;
  final String? assetId;
  const _Thumbnail({required this.videoPath, this.assetId});

  @override
  State<_Thumbnail> createState() => _ThumbnailState();
}

class _ThumbnailState extends State<_Thumbnail> {
  Uint8List? _bytes;
  bool _loading = true;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _load() async {
    // Preferred path: MediaStore asset id → photo_manager thumbnail. This is
    // the robust, MX-Player-style route that works for files on SD cards /
    // scoped storage / content URIs, where the raw-path decoder below fails.
    final assetId = widget.assetId;
    if (assetId != null && assetId.isNotEmpty) {
      try {
        final bytes = await ThumbnailCache.instance.getByAsset(assetId);
        if (bytes != null) {
          if (!_disposed && mounted) {
            setState(() {
              _bytes = bytes;
              _loading = false;
            });
          }
          return;
        }
        // else fall through to the path-based decoder as a second attempt.
      } catch (_) {/* fall through */}
    }
    if (!widget.videoPath.startsWith('/') &&
        !widget.videoPath.startsWith('file://')) {
      if (!_disposed && mounted) {
        setState(() => _loading = false);
      }
      return;
    }
    try {
      final path = widget.videoPath.startsWith('file://')
          ? Uri.parse(widget.videoPath).toFilePath()
          : widget.videoPath;
      if (!await File(path).exists()) {
        if (!_disposed && mounted) setState(() => _loading = false);
        return;
      }
      final bytes = await ThumbnailCache.instance.get(path);
      if (!_disposed && mounted) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }
    } catch (_) {
      if (!_disposed && mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.darkSurfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
      clipBehavior: Clip.antiAlias,
      child: _bytes != null
          ? SafeThumbnail(
              bytes: _bytes!,
              fit: BoxFit.cover,
            )
          : Center(
              child: _loading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.5,
                        color: AppColors.darkOnSurfaceMuted,
                      ),
                    )
                  : const Icon(
                      Icons.movie_outlined,
                      color: AppColors.darkOnSurfaceMuted,
                      size: 28,
                    ),
            ),
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.darkSurfaceVariant,
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Icon(
        Icons.movie_outlined,
        color: AppColors.darkOnSurfaceMuted,
        size: 28,
      ),
    );
  }
}
