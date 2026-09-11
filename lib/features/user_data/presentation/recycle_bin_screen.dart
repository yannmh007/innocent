import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../user_data_providers.dart';

import '../../../core/localization/app_strings.dart';
class RecycleBinScreen extends ConsumerWidget {
  const RecycleBinScreen({super.key});

  String _fmtSize(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(recycleBinProvider);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).recycleBin),
        actions: [
          IconButton(
            tooltip: 'Info',
            icon: const Icon(Icons.info_outline),
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AppColors.darkSurface,
                  title: Text(AppStrings.of(context).recycleBin,
                      style: const TextStyle(color: Colors.white)),
                  content: const Text(
                    'Items in the recycle bin will be kept for up to 30 days before being automatically removed.',
                    style: TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(AppStrings.of(context).ok),
                    ),
                  ],
                ),
              );
            },
          ),
          if (items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppColors.darkSurface,
                    title: Text(AppStrings.of(context).emptyBinTitle,
                        style: const TextStyle(color: Colors.white)),
                    content: const Text(
                      'All entries will be permanently removed from this list. The actual video files are NOT deleted from your device.',
                      style: TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(_).pop(false),
                        child: Text(AppStrings.of(context).cancel,
                            style: const TextStyle(color: Colors.white70)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(_).pop(true),
                        child: Text(AppStrings.of(context).emptyVerb,
                            style: const TextStyle(color: AppColors.error)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ref.read(recycleBinProvider.notifier).empty();
                }
              },
              child: Text(AppStrings.of(context).emptyVerb,
                  style: const TextStyle(color: AppColors.error)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Orange info banner (MX Player parity)
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF3A2E1A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline,
                    color: Color(0xFFFFB74D), size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Files will be stored in the Recycle Bin for up to 30 days before being permanently deleted from your device.',
                    style: TextStyle(
                      color: Color(0xFFFFB74D),
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Simple recycle-bin illustration (icon-based)
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              Container(
                                width: 96,
                                height: 96,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFC9A98A)
                                      .withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              const Icon(
                                Icons.delete_outline,
                                color: Color(0xFFC9A98A),
                                size: 56,
                              ),
                            ],
                          ),
                          const SizedBox(height: 20),
                          Text(AppStrings.of(context).binEmpty,
                            style: const TextStyle(
                              color: AppColors.white55,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : RefreshIndicator(
   onRefresh: () async {
     ref.invalidate(recycleBinProvider);
   },
   child: ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final entry = items[i];
                      final daysLeft = 30 -
                          DateTime.now().difference(entry.deletedAt).inDays;
                      return Dismissible(
                        key: ValueKey('rb_${entry.videoUri}'),
                        // Phase 29: swipe right → restore, swipe left → permanent delete
                        background: Container(
                          color: AppColors.accentBlue,
                          alignment: Alignment.centerLeft,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.restore,
                                  color: Colors.white, size: 24),
                              const SizedBox(width: 6),
                              Text(AppStrings.of(context).restore.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        secondaryBackground: Container(
                          color: AppColors.error,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(AppStrings.of(context).delete.toUpperCase(),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 6),
                              const Icon(Icons.delete_forever,
                                  color: Colors.white, size: 24),
                            ],
                          ),
                        ),
                        confirmDismiss: (direction) async {
                          if (direction == DismissDirection.endToStart) {
                            // Confirm permanent delete
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (_) => AlertDialog(
                                backgroundColor: AppColors.darkSurface,
                                title: Text(AppStrings.of(context).permDeleteTitle,
                                    style: const TextStyle(color: Colors.white)),
                                content: Text(AppStrings.of(context).permDeleteBody,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(_).pop(false),
                                    child: Text(AppStrings.of(context).cancel,
                                        style:
                                            const TextStyle(color: Colors.white70)),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(_).pop(true),
                                    child: Text(AppStrings.of(context).delete,
                                        style: const TextStyle(
                                            color: AppColors.error)),
                                  ),
                                ],
                              ),
                            );
                            return confirmed == true;
                          }
                          return true; // restore direction
                        },
                        onDismissed: (direction) {
                          if (direction == DismissDirection.startToEnd) {
                            ref
                                .read(recycleBinProvider.notifier)
                                .restore(entry.videoUri);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content:
                                    Text(AppStrings.of(context).restoredName(entry.videoTitle)),
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          } else {
                            ref
                                .read(recycleBinProvider.notifier)
                                .restore(entry.videoUri);
                          }
                        },
                        child: ListTile(
                          leading: Container(
                            width: 56,
                            height: 40,
                            decoration: BoxDecoration(
                              color: AppColors.darkSurfaceVariant,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.delete_outline,
                              color: AppColors.darkOnSurfaceMuted,
                            ),
                          ),
                          title: Text(
                            entry.videoTitle,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Row(
                            children: [
                              Text(
                                _fmtSize(entry.sizeBytes),
                                style: const TextStyle(
                                  color: AppColors.darkOnSurfaceMuted,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(
                                  color: daysLeft <= 7
                                      ? AppColors.error
                                          .withOpacity(0.18)
                                      : AppColors.darkSurfaceVariant,
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  '${daysLeft}d left',
                                  style: TextStyle(
                                    color: daysLeft <= 7
                                        ? const Color(0xFFFF7676)
                                        : AppColors.darkOnSurfaceMuted,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            icon: const Icon(
                              Icons.restore,
                              color: AppColors.accentBlue,
                              size: 20,
                            ),
                            tooltip: 'Restore',
                            onPressed: () => ref
                                .read(recycleBinProvider.notifier)
                                .restore(entry.videoUri),
                          ),
                        ),
                      );
                    },
                  ),
 ),
          ),
        ],
      ),
    );
  }
}
