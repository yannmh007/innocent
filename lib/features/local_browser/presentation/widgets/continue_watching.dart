import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/routes.dart';
import '../../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../user_data/user_data_providers.dart';
import '../../../../core/ui/safe_thumbnail.dart';

import '../../../../core/localization/app_strings.dart';
/// Horizontal "Continue Watching" carousel — partial-watch videos.
/// Shown at top of Local tab when there's at least 1 in-progress entry.
class ContinueWatchingSection extends ConsumerWidget {
  const ContinueWatchingSection({super.key});

  String _fmtRemaining(Duration remaining) {
    if (remaining.inHours > 0) {
      return '${remaining.inHours}h ${remaining.inMinutes.remainder(60)}m left';
    }
    if (remaining.inMinutes > 0) {
      return '${remaining.inMinutes}m left';
    }
    return '${remaining.inSeconds}s left';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(publicHistoryProvider);

    // Only entries that are 5%-95% watched (i.e. in-progress)
    final inProgress = history
        .where((e) => e.progress > 0.05 && e.progress < 0.95)
        .take(8)
        .toList();

    if (inProgress.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                const Icon(Icons.play_circle_outline,
                    color: AppColors.accentBlue, size: 18),
                const SizedBox(width: 8),
                Text(AppStrings.of(context).continueWatching,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 130,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: inProgress.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final entry = inProgress[i];
                final remaining = entry.totalDuration - entry.lastPosition;
                return _ContinueCard(
              key: ValueKey(entry.videoUri),
                  title: entry.videoTitle,
                  videoUri: entry.videoUri,
                  progress: entry.progress,
                  remaining: _fmtRemaining(remaining),
                  onTap: () => context.push(
                    Routes.player,
                    extra: {
                      'uri': entry.videoUri,
                      'title': entry.videoTitle,
                    },
                  ),
                  // Phase 45 (audit): long-press to remove from continue
                  // watching. MX Player has the same gesture — users
                  // often want to dismiss finished/abandoned videos
                  // from this list without playing them again.
                  onRemove: () async {
                    try {
                      await ref
                          .read(userDataServiceProvider)
                          .removeFromHistory(entry.videoUri);
                      // Invalidate the provider so the list refreshes.
                      ref.invalidate(historyProvider);
                    } catch (e) { if (kDebugMode) debugPrint('continue_watching.best-effort: $e'); }
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ContinueCard extends StatefulWidget {
  final String title;
  final String videoUri;
  final double progress;
  final String remaining;
  final VoidCallback onTap;
  final VoidCallback? onRemove;

  const _ContinueCard({
    super.key,
    required this.title,
    required this.videoUri,
    required this.progress,
    required this.remaining,
    required this.onTap,
    this.onRemove,
  });

  @override
  State<_ContinueCard> createState() => _ContinueCardState();
}

class _ContinueCardState extends State<_ContinueCard> {
  Uint8List? _thumb;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  Future<void> _loadThumbnail() async {
    try {
      var path = widget.videoUri;
      if (path.startsWith('file://')) {
        path = Uri.parse(path).toFilePath();
      }
      if (!path.startsWith('/')) return;
      if (!await File(path).exists()) return;
      final bytes = await ThumbnailCache.instance.get(path);
      if (!_disposed && mounted) {
        setState(() => _thumb = bytes);
      }
    } catch (e) { if (kDebugMode) debugPrint('continue_watching.best-effort: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      // Phase 45 (audit): long-press a Continue-Watching card → small
      // dialog to remove it from the list. MX Player's UX. We use a
      // confirmation dialog because accidentally deleting watch
      // history with a stray long-press would be annoying.
      onLongPress: widget.onRemove == null
          ? null
          : () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (dctx) => AlertDialog(
                  backgroundColor: AppColors.darkSurface,
                  title: Text(AppStrings.of(context).removeContinueTitle,
                    style: const TextStyle(color: Colors.white),
                  ),
                  content: Text(
                    widget.title,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(dctx).pop(false),
                      child: Text(AppStrings.of(context).cancel,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(dctx).pop(true),
                      child: Text(AppStrings.of(context).remove,
                        style: const TextStyle(color: AppColors.accentBlue),
                      ),
                    ),
                  ],
                ),
              );
              if (ok == true && widget.onRemove != null) {
                widget.onRemove!();
              }
            },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 144,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                Container(
                  height: 82,
                  decoration: BoxDecoration(
                    color: AppColors.darkSurfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _thumb != null
                      ? SafeThumbnail(
                          bytes: _thumb!,
                          width: double.infinity,
                          height: 82,
                        )
                      : const Center(
                          child: Icon(
                            Icons.play_arrow,
                            color: Colors.white54,
                            size: 36,
                          ),
                        ),
                ),
                if (_thumb != null)
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.black25,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      alignment: Alignment.center,
                      child: const Icon(
                        Icons.play_circle_filled,
                        color: Colors.white,
                        size: 28,
                      ),
                    ),
                  ),
                Positioned(
                  left: 4,
                  right: 4,
                  bottom: 4,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: widget.progress,
                      minHeight: 3,
                      backgroundColor: Colors.black54,
                      valueColor: const AlwaysStoppedAnimation(
                          AppColors.accentBlue),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              widget.remaining,
              style: const TextStyle(
                color: AppColors.darkOnSurfaceMuted,
                fontSize: 10,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
