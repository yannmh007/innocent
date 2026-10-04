import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

    // Size chip: prefer a baked-in size, otherwise the lazily-grouped
    // value from folderSizesProvider (fills in once the full video list
    // loads — the fast folder scan skips sizes for speed).
    final folderSizes = ref.watch(folderSizesProvider);
    final sizeBytes = folder.totalSizeBytes > 0
        ? folder.totalSizeBytes
        : (folderSizes[folder.path] ?? 0);
    final sizeLabel = _folderSizeLabel(sizeBytes);
    // A plain folder, as MX draws them; a glyph only where it tells the
    // folders apart at a glance (Camera, Screen recordings, Download…), never
    // the generic one.
    final Widget silhouette = CustomPaint(
      painter: const FolderShapePainter(),
      child: _iconForFolder(folder.name) == Icons.folder
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Center(
                child: Icon(
                  _iconForFolder(folder.name),
                  color: const Color(0xFF7D8790),
                  size: 22,
                ),
              ),
            ),
    );

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
        // MX: a selected row is lifted in grey.
        color: selected ? const Color(0x29FFFFFF) : Colors.transparent,
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
        // 9 + 54 + 9 = MX Player's 72 dp row pitch, 16 dp from the edge.
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        child: Row(
          children: [
            // MX PLAYER'S FOLDER, measured from its screenshots (2026-10-04,
            // a 411 dp phone at 2.625x — the density was confirmed from a
            // screenshot of this app on the same phone): a 72 x 54 dp folder
            // silhouette — a 25 x 8 tab over the body — in #525C65. It reads as "a folder" at
            // a glance where the old 64 x 41 rounded box with a glyph read
            // as "a button". A cover, when there is one and thumbnails are
            // on, fills the same footprint.
            Stack(
              clipBehavior: Clip.none,
              children: [
                SizedBox(
                  width: 72,
                  height: 54,
                  // Always the folder, never a frame from inside it (owner,
                  // 2026-10-04): a cover made folders read as videos at a
                  // glance. MX draws folders the same way.
                  child: silhouette,
                ),
                // MX marks a selected folder ON its icon — a pale disc with
                // a tick in the middle — and leaves the row where it was.
                if (selected) const Positioned.fill(child: FolderTick()),
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
            const SizedBox(width: 16),
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
                      fontSize: 15.5,
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
                        // English keeps its singular; Burmese and Thai
                        // have no plural form, so their one string serves.
                        folder.videoCount == 1 &&
                                Localizations.localeOf(context).languageCode ==
                                    'en'
                            ? '1 video'
                            : AppStrings.of(context)
                                .vhAlbumVideos(folder.videoCount),
                        style: const TextStyle(
                          color: AppColors.specTextSecondary,
                          fontSize: 12,
                        ),
                      ),
                      if (sizeLabel.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.specChipSurface,
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            sizeLabel,
                            style: const TextStyle(
                              color: AppColors.specTextSecondary,
                              fontSize: 9,
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
              style: const TextStyle(color: Colors.white54, fontSize: 11),
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
              style: const TextStyle(color: AppColors.accentBlue),
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

/// A video's picture — a folder's cover, a "Recently added" tile: a frame
/// from the video, or — while that loads, and when there is none — the
/// [placeholder].
///
/// Shared by the folder list, the folder grid and "Recently added". Two things changed from the two
/// copies it replaces:
///  * the picture comes through [ThumbnailCache.forVideo], MediaStore's
///    thumbnail first. The copies decoded the file by path only, which fails
///    on scoped storage, so most folders showed a grey box instead of a cover;
///  * no spinner while loading. Every visible cover span a progress ring
///    until its frame arrived — with a large library, rings animating at 60
///    frames a second all down the screen for as long as decoding took.
class VideoCover extends StatefulWidget {
  const VideoCover({
    super.key,
    required this.videoUri,
    this.assetId,
    required this.placeholder,
    this.radius = 6,
  });

  final String videoUri;
  final String? assetId;
  final Widget placeholder;
  final double radius;

  @override
  State<VideoCover> createState() => _VideoCoverState();
}

class _VideoCoverState extends State<VideoCover> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VideoCover old) {
    super.didUpdateWidget(old);
    if (old.videoUri != widget.videoUri || old.assetId != widget.assetId) {
      _bytes = null;
      _load();
    }
  }

  Future<void> _load() async {
    final uri = widget.videoUri;
    try {
      final bytes =
          await ThumbnailCache.instance.forVideo(uri, assetId: widget.assetId);
      if (mounted && uri == widget.videoUri && bytes != null) {
        setState(() => _bytes = bytes);
      }
    } catch (_) {
      // The placeholder stays: a cover is decoration.
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = _bytes;
    if (b == null) return widget.placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SafeThumbnail(bytes: b, fit: BoxFit.cover),
    );
  }
}

/// MX Player's folder silhouette: a tab on the upper left over a rounded
/// body. Shared by the folder list and grid so both read the same.
class FolderShapePainter extends CustomPainter {
  const FolderShapePainter({this.color = const Color(0xFF525C65)});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final w = size.width;
    final h = size.height;
    // Proportions from MX: tab 35% of the width and 15% of the height.
    final tabW = w * 0.35;
    final tabH = h * 0.15;
    final r = Radius.circular(h * 0.09);
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(0, 0, tabW, tabH + r.y,
          topLeft: r, topRight: r),
      paint,
    );
    canvas.drawRRect(
      RRect.fromLTRBAndCorners(0, tabH, w, h,
          topRight: r, bottomLeft: r, bottomRight: r),
      paint,
    );
  }

  @override
  bool shouldRepaint(FolderShapePainter old) => old.color != color;
}

/// The tick MX draws on a selected folder: a pale disc, a dark tick, centred
/// on the body of the folder (below its tab).
class FolderTick extends StatelessWidget {
  const FolderTick({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Center(
        child: Container(
          width: 28,
          height: 28,
          decoration: const BoxDecoration(
            color: Color(0xFFDCDCE0),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check, color: Color(0xFF3A3F45), size: 20),
        ),
      ),
    );
  }
}
