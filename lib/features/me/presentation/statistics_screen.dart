import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../local_browser/presentation/library_provider.dart';
import '../../user_data/user_data_providers.dart';

import '../../../core/localization/app_strings.dart';
class StatisticsScreen extends ConsumerWidget {
  const StatisticsScreen({super.key});

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtDuration(Duration d) {
    if (d.inHours == 0) return '${d.inMinutes}m';
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String _displayPath(String path) {
    final segments = path.split('/');
    return segments.isNotEmpty ? segments.last : path;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(foldersProvider);
    final allVideosAsync = ref.watch(allVideosProvider);
    final history = ref.watch(historyProvider);
    final favourites = ref.watch(favouritesProvider);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).statistics)),
      body: foldersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => Center(
            child: Text(AppStrings.of(context).failedToLoad,
                style: const TextStyle(color: AppColors.error))),
        data: (folders) => allVideosAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
              child: Text(AppStrings.of(context).failedToLoad,
                  style: const TextStyle(color: AppColors.error))),
          data: (videos) {
            // Aggregate stats
            final totalVideos = videos.length;
            final totalBytes =
                videos.fold<int>(0, (sum, v) => sum + v.sizeBytes);
            final totalDuration = videos.fold<Duration>(
              Duration.zero,
              (sum, v) => sum + v.duration,
            );

            // Watch time
            int watchedMs = 0;
            for (final h in history) {
              watchedMs += h.lastPosition.inMilliseconds * h.watchCount;
            }
            final watchTime = Duration(milliseconds: watchedMs);

            // Top folders by video count
            final foldersByCount = [...folders]
              ..sort((a, b) => b.videoCount.compareTo(a.videoCount));
            final topFolders = foldersByCount.take(5).toList();

            // Most-watched videos
            final mostWatched = [...history]
              ..sort((a, b) => b.watchCount.compareTo(a.watchCount));
            final top5Watched = mostWatched.take(5).toList();

            return ListView(
              children: [
                const SizedBox(height: 8),
                _SectionHeader('LIBRARY'),
                _StatGrid(items: [
                  _StatItem(
                    icon: Icons.movie_outlined,
                    value: totalVideos.toString(),
                    label: 'Videos',
                  ),
                  _StatItem(
                    icon: Icons.folder_outlined,
                    value: folders.length.toString(),
                    label: 'Folders',
                  ),
                  _StatItem(
                    icon: Icons.storage_outlined,
                    value: _fmtSize(totalBytes),
                    label: 'Total size',
                  ),
                  _StatItem(
                    icon: Icons.timer_outlined,
                    value: _fmtDuration(totalDuration),
                    label: 'Total length',
                  ),
                ]),
                const SizedBox(height: 16),
                _SectionHeader('YOUR ACTIVITY'),
                _StatGrid(items: [
                  _StatItem(
                    icon: Icons.history,
                    value: history.length.toString(),
                    label: 'Watched',
                  ),
                  _StatItem(
                    icon: Icons.access_time,
                    value: _fmtDuration(watchTime),
                    label: 'Watch time',
                  ),
                  _StatItem(
                    icon: Icons.favorite_outline,
                    value: favourites.length.toString(),
                    label: 'Favourites',
                  ),
                ]),
                if (topFolders.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader('TOP FOLDERS'),
                  ...topFolders.map(
                    (f) => ListTile(
                      leading: const Icon(Icons.folder,
                          color: AppColors.accentBlue),
                      title: Text(
                        f.name,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _displayPath(f.path),
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Text(
                        '${f.videoCount}',
                        style: const TextStyle(
                          color: AppColors.accentBlue,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                if (top5Watched.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader('MOST WATCHED'),
                  ...top5Watched.map(
                    (e) => ListTile(
                      leading: const Icon(Icons.replay,
                          color: AppColors.accentBlue),
                      title: Text(
                        e.videoTitle,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${e.watchCount} ${e.watchCount == 1 ? "play" : "plays"} • ${(e.progress * 100).toInt()}% completed',
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.accentBlue,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

class _StatItem {
  final IconData icon;
  final String value;
  final String label;
  _StatItem({required this.icon, required this.value, required this.label});
}

class _StatGrid extends StatelessWidget {
  final List<_StatItem> items;
  const _StatGrid({required this.items});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 2.4,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final item = items[i];
          return Container(
              key: ValueKey(item.label),
            decoration: BoxDecoration(
              color: AppColors.darkSurface,
              borderRadius: BorderRadius.circular(8),
            ),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(item.icon, color: AppColors.accentBlue, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.value,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.label,
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
