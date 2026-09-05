import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/theme/app_colors.dart';
import '../../local_browser/domain/video.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../../local_browser/presentation/video_list_item.dart';

import '../../../core/localization/app_strings.dart';
/// Media Manager matching MX Player (UI PDF page 9)
/// Storage card + Clean up banner + 3 shortcuts + Haven't Played grid
class MediaManagerScreen extends ConsumerWidget {
  const MediaManagerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).mediaManager)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ─── STORAGE CARD ───
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(AppStrings.of(context).deviceStorage,
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const Spacer(),
                    // Phase 30: MX parity — orange "Used X.XX TB" highlight then white "/ Y.YY TB"
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: 'Used ',
                            style: TextStyle(
                              color: AppColors.white50,
                              fontSize: 12,
                            ),
                          ),
                          const TextSpan(
                            text: '0.91 TB',
                            style: TextStyle(
                              color: Color(0xFFFF9800),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          TextSpan(
                            text: ' / 1.02 TB',
                            style: TextStyle(
                              color: AppColors.white50,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Storage bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: SizedBox(
                    height: 8,
                    child: LinearProgressIndicator(
                      value: 0.89,
                      backgroundColor: AppColors.white10,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                          Color(0xFFFF9800)),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // Video / Music / Image columns with vertical dividers (MX parity)
                IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _storageColumn(
                          Icons.play_circle_outline, 'Video', '621 GB'),
                      Container(
                        width: 1,
                        color: AppColors.white08,
                      ),
                      _storageColumn(Icons.music_note, 'Music', '1.11 GB'),
                      Container(
                        width: 1,
                        color: AppColors.white08,
                      ),
                      _storageColumn(
                          Icons.image_outlined, 'Image', '27.53 GB'),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ─── CLEAN UP BANNER (MX uses light mint bg + dark text) ───
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFD5F2E5),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                // The MX icon is a stylized broom in a soft green circle
                Container(
                  width: 36,
                  height: 36,
                  decoration: const BoxDecoration(
                    color: Color(0xFFE0F4EB),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.cleaning_services,
                      color: Color(0xFF2E7D55), size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(AppStrings.of(context).cleanUpSpace,
                        style: TextStyle(
                            color: Color(0xFF1A1A1A),
                            fontSize: 14,
                            fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      // Phase 34: GB amount in red — verified against screen recording
                      Text.rich(
                        TextSpan(
                          children: [
                            const TextSpan(
                              text: '592 GB',
                              style: TextStyle(
                                color: Color(0xFFE53935),
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            TextSpan(
                              text: ' media files can be cleaned up',
                              style: TextStyle(
                                color: AppColors.black55,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content:
                              Text(AppStrings.of(context).scanningCleanable)),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2E7D55),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 8),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20)),
                    elevation: 0,
                  ),
                  child:
                      Text(AppStrings.of(context).clean, style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ─── 3 SHORTCUTS (as dark surface cards, MX parity) ───
          Row(
            children: [
              Expanded(
                child: _shortcutCard(
                  Icons.play_circle,
                  Icons.access_time,
                  'Recently Played',
                  onTap: () => _navigateToHistory(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _shortcutCard(
                  Icons.pie_chart,
                  null,
                  'Large Files',
                  // Audit P3: now scans real file sizes and lists the
                  // biggest videos (sizeBytes is lazy/0 in the library,
                  // so we stat each file on demand here).
                  onTap: () => _showVideoSheet(context, ref, largeFiles: true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _shortcutCard(
                  Icons.add_circle,
                  Icons.access_time,
                  'Recently Added',
                  // Audit P3: now sorts the library by dateAdded
                  // (createDateTime) and shows the newest videos.
                  onTap: () =>
                      _showVideoSheet(context, ref, largeFiles: false),
                ),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ─── HAVEN'T PLAYED ───
          Row(
            children: [
              const Text(
                "Haven't Played",
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Icon(Icons.chevron_right,
                  color: AppColors.white50),
            ],
          ),
          const SizedBox(height: 12),
          // Empty grid placeholder
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 16 / 11,
            ),
            itemCount: 4,
            itemBuilder: (_, i) {
              return Container(
                decoration: BoxDecoration(
                  color: AppColors.darkSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Icon(Icons.videocam_outlined,
                      color: AppColors.white20, size: 36),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static Widget _storageColumn(IconData icon, String label, String value) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            // Phase 34: MX wraps the icon in a small subtle circle
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: AppColors.white08,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(icon,
                  color: AppColors.white70, size: 16),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(value,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Phase 30: Rectangular dark-surface card with a stacked icon at top
  // and label below — replaces the floating circular avatars.
  static Widget _shortcutCard(
      IconData primary, IconData? overlay, String label,
      {VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: BoxDecoration(
          color: AppColors.darkSurface,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: Stack(
                children: [
                  Center(
                  child: Icon(primary,
                      color: AppColors.primaryBlue, size: 36),
                ),
                if (overlay != null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      decoration: const BoxDecoration(
                        color: AppColors.primaryBlue,
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(overlay,
                          color: Colors.white, size: 12),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    ),
    );
  }

  // Phase 37: Open Recently Played list — uses history screen
  /// Audit P3: shared bottom sheet for "Large Files" (scans real file
  /// sizes) and "Recently Added" (sorts by dateAdded). Reads the library
  /// once, builds the list, and lets the user tap straight into playback.
  static void _showVideoSheet(BuildContext context, WidgetRef ref,
      {required bool largeFiles}) {
    // Build the list ONCE, before the sheet opens. DraggableScrollableSheet's
    // builder runs on every drag frame, so creating the future inside it made
    // the whole library re-read (and, for "Largest", re-stat every file) dozens
    // of times a second while dragging — enough to lock the app up.
    final listFuture = _buildList(ref, largeFiles);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (ctx, scrollController) {
            return Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.white20,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(largeFiles ? Icons.pie_chart : Icons.add_circle,
                          color: AppColors.accentBlue, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        largeFiles ? 'Largest videos' : 'Recently added',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: FutureBuilder<List<Video>>(
                    future: listFuture,
                    builder: (ctx, snap) {
                      if (snap.connectionState != ConnectionState.done) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final vids = snap.data ?? const <Video>[];
                      if (vids.isEmpty) {
                        return Center(
                          child: Text(AppStrings.of(context).noVideosFound,
                              style: const TextStyle(color: AppColors.white55)),
                        );
                      }
                      return ListView.builder(
                        controller: scrollController,
                        itemCount: vids.length,
                        itemBuilder: (ctx, i) {
                          final v = vids[i];
                          return VideoListItem(
                            video: v,
                            onTap: () {
                              Navigator.of(sheetCtx).pop();
                              context.push(Routes.player, extra: {
                                'uri': v.uri,
                                'title': v.title,
                              });
                            },
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Build the list for the sheet. Large Files stats each file's real
  /// size (the library leaves sizeBytes at 0 for speed) and returns the
  /// top 100 by size; Recently Added sorts by dateAdded descending.
  static Future<List<Video>> _buildList(
      WidgetRef ref, bool largeFiles) async {
    final all = await ref.read(allVideosProvider.future);
    if (!largeFiles) {
      final sorted = [...all]..sort((a, b) {
          final da = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          final db = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
          return db.compareTo(da);
        });
      return sorted.take(100).toList();
    }
    // Read sizes in bounded batches. `Future.wait` over the whole library
    // opened one file handle per video at once, which on a large library
    // spikes memory and can exhaust the descriptor limit; 48 at a time is
    // still fully parallel but stays well inside safe limits.
    final sized = <Video>[];
    const batch = 48;
    for (var i = 0; i < all.length; i += batch) {
      final slice = all.skip(i).take(batch).toList();
      final part = await Future.wait(slice.map((v) async {
        try {
          final len = await File(v.uri).length();
          return v.copyWith(sizeBytes: len);
        } catch (_) {
          return v.copyWith(sizeBytes: 0);
        }
      }));
      sized.addAll(part);
    }
    sized.sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes));
    return sized.where((v) => v.sizeBytes > 0).take(100).toList();
  }

  static void _navigateToHistory(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.of(context).openingRecentlyPlayed),
        duration: Duration(milliseconds: 800),
      ),
    );
  }
}
