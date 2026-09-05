import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../user_data/user_data_providers.dart';
import '../player_provider.dart';

import '../../../../core/localization/app_strings.dart';
/// Bottom sheet listing bookmarks for the current video with tap-to-seek
class BookmarksSheet extends ConsumerWidget {
  final String videoUri;
  final ValueChanged<Duration> onSeek;

  const BookmarksSheet({
    super.key,
    required this.videoUri,
    required this.onSeek,
  });

  /// Audit fix (B1): pause playback while the bookmark list is open
  /// (frame-stable preview when the user taps a bookmark) and resume
  /// only if we were the ones who paused.
  static Future<void> show(
    BuildContext context,
    WidgetRef ref, {
    required String videoUri,
    required ValueChanged<Duration> onSeek,
  }) async {
    final controller = ref.read(playerControllerProvider.notifier);
    final wasPlaying = ref.read(playerControllerProvider).isPlaying;
    if (wasPlaying) {
      await controller.pause();
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => BookmarksSheet(videoUri: videoUri, onSeek: onSeek),
    );
    if (wasPlaying) {
      try {
        await controller.play();
      } catch (e) { if (kDebugMode) debugPrint('bookmarks_sheet.best-effort: $e'); }
    }
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref
        .watch(bookmarksProvider.notifier)
        .forVideo(videoUri);

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 12),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.bookmark, color: AppColors.accentBlue, size: 20),
                  const SizedBox(width: 12),
                  Text(AppStrings.of(context).bookmarksTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 12, color: Colors.white12),
            if (bookmarks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: const Text(
                  'No bookmarks for this video.\nTap ⋮ → Bookmark while playing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 13),
                ),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: bookmarks.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, color: Colors.white10),
                  itemBuilder: (_, i) {
                    final b = bookmarks[i];
                    return ListTile(
                      leading: const Icon(
                        Icons.bookmark_outline,
                        color: AppColors.accentBlue,
                      ),
                      title: Text(
                        _fmt(b.position),
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                      subtitle: b.label != null
                          ? Text(
                              b.label!,
                              style: const TextStyle(
                                color: AppColors.darkOnSurfaceMuted,
                                fontSize: 12,
                              ),
                            )
                          : null,
                      trailing: IconButton(
                        tooltip: 'Close',
                        icon: const Icon(
                          Icons.close,
                          color: AppColors.darkOnSurfaceMuted,
                          size: 18,
                        ),
                        onPressed: () => ref
                            .read(bookmarksProvider.notifier)
                            .delete(b.id),
                      ),
                      onTap: () {
                        onSeek(b.position);
                        Navigator.of(context).pop();
                      },
                    );
                  },
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
