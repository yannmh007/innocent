import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

import '../../../../core/localization/app_strings.dart';
/// Playing Queue sheet — shows current video queue in player
class PlayingQueueSheet extends StatelessWidget {
  final String currentTitle;
  final List<String> queue;
  final int currentIndex;

  const PlayingQueueSheet({
    super.key,
    this.currentTitle = '',
    this.queue = const [],
    this.currentIndex = 0,
  });

  static Future<void> show(BuildContext context,
      {String currentTitle = '', List<String> queue = const []}) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.8,
        minChildSize: 0.3,
        expand: false,
        builder: (_, controller) => PlayingQueueSheet(
          currentTitle: currentTitle,
          queue: queue,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Handle
        Container(
          margin: const EdgeInsets.only(top: 12),
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Text(AppStrings.of(context).playingQueueTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '${queue.isEmpty ? 1 : queue.length} item${queue.length != 1 ? "s" : ""}',
                style: const TextStyle(
                  color: AppColors.white50,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 0, color: Colors.white10),
        Expanded(
          child: queue.isEmpty
              ? _singleItemList()
              : ListView.builder(
                  itemCount: queue.length,
                  itemBuilder: (_, i) {
                    final isPlaying = i == currentIndex;
                    return Container(
                      color: isPlaying
                          ? AppColors.accentBlue10
                          : Colors.transparent,
                      child: ListTile(
                        leading: isPlaying
                            ? const Icon(Icons.equalizer,
                                color: AppColors.primaryBlue, size: 20)
                            : Text(
                                '${i + 1}',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 14,
                                ),
                              ),
                        title: Text(
                          queue[i],
                          style: TextStyle(
                            color:
                                isPlaying ? AppColors.primaryBlue : Colors.white,
                            fontSize: 14,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: const Icon(Icons.drag_handle,
                            color: Colors.white24, size: 20),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _singleItemList() {
    return ListView(
      children: [
        Container(
          color: AppColors.accentBlue10,
          child: ListTile(
            leading: const Icon(Icons.equalizer,
                color: AppColors.primaryBlue, size: 20),
            title: Text(
              currentTitle.isEmpty ? 'Current video' : currentTitle,
              style: const TextStyle(color: AppColors.primaryBlue, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}
