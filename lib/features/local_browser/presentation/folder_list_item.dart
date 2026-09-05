import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/preferences_provider.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../../player/presentation/floating_pip_provider.dart';
import '../domain/folder.dart';
import 'library_provider.dart';
import 'new_badge_providers.dart';
import 'hidden_badge.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
/// Folder list item — MX Player parity (Image 1 reference).
/// - Compact 56×52 folder-shape thumbnail
/// - No divider lines between rows (controlled by parent)
/// - Tighter padding than before
class FolderListItem extends ConsumerWidget {
  final Folder folder;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool selectionMode;
  final bool selected;

  const FolderListItem({
    super.key,
    required this.folder,
    required this.onTap,
    this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Real count from folderNewCountsProvider, narrowed with `.select` so a
    // save for one video does not rebuild every folder row.
    final newCount = ref.watch(
        folderNewCountsProvider.select((m) => m[folder.path] ?? 0));
    // Code-quality audit: `.select` narrows the subscription to the
    // single boolean we actually consume, so unrelated preference
    // changes no longer rebuild this list item.
    final showThumbs = ref.watch(
        preferencesProvider.select((p) => p.showThumbnails));
    final coverPaths = ref.watch(folderCoverPathsProvider);

    // Size chip: prefer a baked-in size, otherwise the lazily-grouped
    // value from folderSizesProvider (fills in once the full video list
    // loads — the fast folder scan skips sizes for speed).
    final folderSizes = ref.watch(folderSizesProvider);
    final sizeBytes = folder.totalSizeBytes > 0
        ? folder.totalSizeBytes
        : (folderSizes[folder.path] ?? 0);
    final sizeLabel = _folderSizeLabel(sizeBytes);
    // Phase 44: prefer the cover path baked into the Folder model by the
    // fast bucket-based scan (no dependency on allVideosProvider being
    // ready). Fall back to the map for older cached folders.
    final coverUri = folder.coverThumbnailPath ?? coverPaths[folder.path];

    // Phase 31: MX highlights the folder containing the currently-playing
    // (or recently-played) video in accent-blue. Verified screen recording
    // frame 1: "Camera" rendered in blue while PiP shows a Camera video.
    final pipUri = ref.watch(floatingPipProvider).activeUri;
    bool isActiveFolder = false;
    if (pipUri != null) {
      final folderPath = folder.path;
      // pipUri is either file:// or content://; match by parent folder path
      try {
        if (pipUri.startsWith('file://')) {
          final p = Uri.parse(pipUri).toFilePath();
          isActiveFolder = p.startsWith(folderPath);
        } else {
          // content URIs: we just match folder name suffix in the uri
          isActiveFolder = pipUri.contains(folder.name);
        }
      } catch (_) {
        isActiveFolder = false;
      }
    }

    // Audit: same RepaintBoundary trick as video_list_item — limit
    // the repaint surface so a cover-thumb update doesn't redraw
    // neighbouring folder tiles.
    return Semantics(
      label: 'Folder: ${folder.name}, ${folder.videoCount} videos',
      button: true,
      selected: selected,
      child: RepaintBoundary(
      child: Material(
        color: selected
            ? AppColors.accentBlue.withValues(alpha: 0.16)
            : Colors.transparent,
        child: InkWell(
      // In selection mode a tap toggles this folder; otherwise it opens.
      onTap: selectionMode ? onLongPress : onTap,
      // Long-press enters (or extends) folder selection mode. The folder
      // properties sheet is still reachable via a normal long-press when
      // NOT in selection mode? No — long-press now always drives selection
      // (matches MX Player). Properties remain available from the folder's
      // own info affordance elsewhere.
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            // Selection checkbox (leading) — shown only in selection mode.
            if (selectionMode)
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: selected
                      ? AppColors.accentBlue
                      : AppColors.white40,
                  size: 24,
                ),
              ),
            // innocent_folders_spec: 64×41 dp landscape thumbnail, r8,
            // surface #444D56 (shown as the placeholder when no cover).
            Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: 64,
                  height: 41,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: (showThumbs && coverUri != null)
                        ? _FolderThumbnail(videoUri: coverUri)
                        : Container(
                            color: AppColors.specSurface,
                            alignment: Alignment.center,
                            child: Icon(
                              // Phase 17: Special folder icons for known
                              // names (Movies, Camera, Screen recordings, etc).
                              _iconForFolder(folder.name),
                              color: AppColors.specTextSecondary,
                              size: 26,
                            ),
                          ),
                  ),
                ),
                // NEW count badge (MX Player parity). Real count from
                // folderNewCountsProvider — see the note in grid_tiles.
                if (newCount > 0)
                  Positioned(
                    top: -4,
                    right: -4,
                    child: Container(
                      constraints: const BoxConstraints(
                        minWidth: 18,
                        minHeight: 18,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: const BoxDecoration(
                        color: AppColors.specBadge,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        newCount > 99 ? '99+' : '$newCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          height: 1.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    folder.name,
                    style: TextStyle(
                      color: isActiveFolder
                          ? AppColors.specSelectedLabel
                          : AppColors.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (_isHiddenFolder(folder)) ...[
                    const SizedBox(height: 3),
                    const HiddenBadge(),
                  ],
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        '${folder.videoCount} ${folder.videoCount == 1 ? "video" : "videos"}',
                        style: const TextStyle(
                          color: AppColors.specTextSecondary,
                          fontSize: 13,
                        ),
                      ),
                      if (sizeLabel.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppColors.specChipSurface,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            sizeLabel,
                            style: const TextStyle(
                              color: AppColors.specTextSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    ),
    ),
    );
  }

  /// Phase 45 (audit): folder properties dialog shown via long-press.
  /// Shows path, video count, total size, and last modified. MX Player
  /// V3 has the same dialog and users do consult it surprisingly often
  /// — e.g., "where exactly is this folder?" or "how big is it?".
  Future<void> _showFolderProperties(
      BuildContext context, WidgetRef ref) async {
    // Compute properties on demand, off the build thread.
    String sizeStr = 'Calculating...';
    String modifiedStr = '—';
    try {
      final dir = Directory(folder.path);
      if (await dir.exists()) {
        // File size — sum up videos in the folder (cheap because the
        // folder model already knows count; we re-read sizes lazily).
        var totalBytes = 0;
        try {
          await for (final ent in dir.list(recursive: false)) {
            if (ent is File) {
              try {
                totalBytes += await ent.length();
              } catch (e) { if (kDebugMode) debugPrint('folder_list_item.best-effort: $e'); }
            }
          }
        } catch (e) { if (kDebugMode) debugPrint('folder_list_item.best-effort: $e'); }
        sizeStr = _humanSize(totalBytes);
        try {
          final stat = await dir.stat();
          modifiedStr = _fmtDate(stat.modified);
        } catch (e) { if (kDebugMode) debugPrint('folder_list_item.best-effort: $e'); }
      }
    } catch (e) { if (kDebugMode) debugPrint('folder_list_item.best-effort: $e'); }

    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(
          folder.name,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PropRow(label: 'Videos', value: '${folder.videoCount}'),
            _PropRow(label: 'Size', value: sizeStr),
            _PropRow(label: 'Modified', value: modifiedStr),
            const SizedBox(height: 6),
            Text(AppStrings.of(context).path,
              style: TextStyle(color: Colors.white54, fontSize: 11),
            ),
            const SizedBox(height: 2),
            Text(
              folder.path,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: Text(AppStrings.of(context).close,
              style: TextStyle(color: AppColors.accentBlue),
            ),
          ),
        ],
      ),
    );
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  String _fmtDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }
}

/// Property row inside the folder properties dialog (Phase 45 audit).
class _PropRow extends StatelessWidget {
  final String label;
  final String value;
  const _PropRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// Human-readable folder size ("174 GB", "641 MB", "88 KB"). Empty for
/// zero so the size chip is simply omitted until the value is known.
String _folderSizeLabel(int b) {
  if (b <= 0) return '';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) {
    return '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
  final gb = b / (1024 * 1024 * 1024);
  return gb < 10 ? '${gb.toStringAsFixed(1)} GB' : '${gb.toStringAsFixed(0)} GB';
}

/// True when a folder lives where normal galleries hide media — Android/data
/// or Android/obb caches (surfaced over ADB/iADB) or dot-folders. Drives the
/// small "Hidden" label under the folder name.
bool _isHiddenFolder(Folder folder) {
  final cover = folder.coverThumbnailPath ?? '';
  if (cover.startsWith('adb://')) return true;
  final path = folder.path;
  if (path.contains('/Android/data/') || path.contains('/Android/obb/')) {
    return true;
  }
  return folder.name.startsWith('.');
}

/// Phase 17: Special folder icons for known well-known folder names.
/// MX Player uses clapperboard for "Movies", camera for "Camera", etc.
IconData _iconForFolder(String name) {
  final n = name.toLowerCase();
  if (n.contains('movie') || n == 'full movies') return Icons.movie_outlined;
  if (n.contains('camera')) return Icons.photo_camera_outlined;
  if (n.contains('screen recording') || n.contains('screen-recording')) {
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

class _FolderThumbnail extends StatefulWidget {
  final String videoUri;
  const _FolderThumbnail({required this.videoUri});

  @override
  State<_FolderThumbnail> createState() => _FolderThumbnailState();
}

class _FolderThumbnailState extends State<_FolderThumbnail> {
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
    try {
      String path;
      if (widget.videoUri.startsWith('file://')) {
        path = Uri.parse(widget.videoUri).toFilePath();
      } else if (widget.videoUri.startsWith('/')) {
        path = widget.videoUri;
      } else {
        if (!_disposed && mounted) setState(() => _loading = false);
        return;
      }
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
    if (_bytes != null) {
      return SafeThumbnail(
        bytes: _bytes!,
        fit: BoxFit.cover,
      );
    }
    return Container(
      color: AppColors.specSurface,
      child: _loading
          ? const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.specTextSecondary,
                ),
              ),
            )
          : const Icon(
              Icons.folder,
              color: AppColors.specTextSecondary,
              size: 26,
            ),
    );
  }
}
