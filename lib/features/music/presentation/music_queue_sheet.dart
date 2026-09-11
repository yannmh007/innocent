import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'music_providers.dart';

import '../../../core/localization/app_strings.dart';
/// Phase 39: Playing Queue bottom sheet — shows the real playback queue from
/// [musicPlayingProvider]. Tapping a row jumps to that track. The currently
/// playing row is highlighted with the equalizer-bars icon (MX parity).
class MusicQueueSheet extends ConsumerWidget {
  const MusicQueueSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const MusicQueueSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(musicPlayingProvider);
    final queue = playing.queue;

    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8, bottom: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.queue_music,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(AppStrings.of(context).playingQueueTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${queue.length} ${queue.length == 1 ? "song" : "songs"}',
                    style: const TextStyle(
                      color: AppColors.darkOnSurfaceMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            if (queue.isEmpty)
              Padding(
                padding: const EdgeInsets.all(28),
                child: Text(AppStrings.of(context).queueEmpty,
                  style: const TextStyle(color: Colors.white54),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: queue.length,
                  itemBuilder: (_, i) {
                    final s = queue[i];
                    final isCurrent = i == playing.currentIndex;
                    return ListTile(
                      dense: true,
                      leading: isCurrent
                          ? const Icon(Icons.equalizer,
                              color: AppColors.primaryBlue, size: 22)
                          : Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: AppColors.darkOnSurfaceMuted,
                                fontSize: 13,
                              ),
                            ),
                      title: Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: isCurrent
                              ? AppColors.primaryBlue
                              : Colors.white,
                          fontSize: 14,
                          fontWeight:
                              isCurrent ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                      subtitle: Text(
                        s.displayArtist,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 12,
                        ),
                      ),
                      onTap: () {
                        Navigator.of(context).pop();
                        ref.read(musicPlayingProvider.notifier).jumpTo(i);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
