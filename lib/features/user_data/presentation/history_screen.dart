import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/routes.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/user_data_models.dart';
import '../user_data_providers.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  String _fmtAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inDays > 7) return '${diff.inDays}d ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  /// Group history entries by relative date for section headers.
  /// Returns ordered list of (header, [entries]) groups.
  List<MapEntry<String, List<HistoryEntry>>> _groupByDate(
      List<HistoryEntry> entries) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final weekStart = today.subtract(const Duration(days: 7));

    final groups = <String, List<HistoryEntry>>{
      'Today': [],
      'Yesterday': [],
      'This week': [],
      'Earlier': [],
    };
    for (final e in entries) {
      final d = DateTime(
          e.lastWatched.year, e.lastWatched.month, e.lastWatched.day);
      if (d.isAtSameMomentAs(today)) {
        groups['Today']!.add(e);
      } else if (d.isAtSameMomentAs(yesterday)) {
        groups['Yesterday']!.add(e);
      } else if (d.isAfter(weekStart)) {
        groups['This week']!.add(e);
      } else {
        groups['Earlier']!.add(e);
      }
    }
    return groups.entries.where((g) => g.value.isNotEmpty).toList();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(historyProvider);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).history),
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Clear all',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppColors.darkSurface,
                    title: Text(AppStrings.of(context).clearHistoryTitle,
                        style: TextStyle(color: Colors.white)),
                    content: Text(AppStrings.of(context).clearHistoryBody,
                      style: TextStyle(color: Colors.white70),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(_).pop(false),
                        child: Text(AppStrings.of(context).cancel,
                            style: TextStyle(color: Colors.white70)),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(_).pop(true),
                        child: Text(AppStrings.of(context).clear,
                            style: TextStyle(color: AppColors.error)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ref.read(historyProvider.notifier).clear();
                }
              },
            ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history,
                      size: 64,
                      color: AppColors.darkOnSurfaceMuted
                          .withOpacity(0.5)),
                  const SizedBox(height: 16),
                  Text(AppStrings.of(context).noHistoryYet,
                    style: TextStyle(color: AppColors.darkOnSurfaceMuted),
                  ),
                ],
              ),
            )
          : _buildGroupedList(context, ref, history),
    );
  }

  Widget _buildGroupedList(
      BuildContext context, WidgetRef ref, List<HistoryEntry> history) {
    final groups = _groupByDate(history);
    final children = <Widget>[];
    for (final group in groups) {
      children.add(_SectionHeader(label: group.key));
      for (final entry in group.value) {
        children.add(
          Dismissible(
            key: ValueKey(entry.videoUri),
            direction: DismissDirection.endToStart,
            background: Container(
              color: AppColors.error,
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: const Icon(Icons.delete_outline,
                  color: Colors.white, size: 24),
            ),
            onDismissed: (_) {
              ref.read(historyProvider.notifier).deleteEntry(entry.videoUri);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(AppStrings.of(context).removedName(entry.videoTitle)),
                  behavior: SnackBarBehavior.floating,
                  duration: const Duration(seconds: 2),
                ),
              );
            },
            child: _HistoryTile(
              entry: entry,
              onTap: () => context.push(
                Routes.player,
                extra: {
                  'uri': entry.videoUri,
                  'title': entry.videoTitle,
                },
              ),
              onDelete: () => ref
                  .read(historyProvider.notifier)
                  .deleteEntry(entry.videoUri),
              fmtAgo: _fmtAgo,
            ),
          ),
        );
      }
    }
    return ListView(children: children);
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.accentBlue,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _HistoryTile extends StatefulWidget {
  final HistoryEntry entry;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String Function(DateTime) fmtAgo;

  const _HistoryTile({
    required this.entry,
    required this.onTap,
    required this.onDelete,
    required this.fmtAgo,
  });

  @override
  State<_HistoryTile> createState() => _HistoryTileState();
}

class _HistoryTileState extends State<_HistoryTile> {
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
      var path = widget.entry.videoUri;
      if (path.startsWith('file://')) {
        path = Uri.parse(path).toFilePath();
      }
      if (!path.startsWith('/')) return;
      if (!await File(path).exists()) return;
      final bytes = await ThumbnailCache.instance.get(path);
      if (!_disposed && mounted) {
        setState(() => _thumb = bytes);
      }
    } catch (e) { if (kDebugMode) debugPrint('history_screen.best-effort: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 64,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.darkSurfaceVariant,
          borderRadius: BorderRadius.circular(4),
        ),
        clipBehavior: Clip.antiAlias,
        child: _thumb != null
            ? SafeThumbnail(bytes: _thumb!)
            : const Icon(Icons.movie_outlined,
                color: AppColors.darkOnSurfaceMuted),
      ),
      title: Text(
        widget.entry.videoTitle,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              // Code-quality audit: wrap the relative-time Text in
              // Expanded so a long localised value ("yesterday at
              // 14:30") cannot push the percentage label off the
              // edge on narrow screens. Ellipsis handles the rare
              // case where the time string itself exceeds the
              // available width.
              Expanded(
                child: Text(
                  widget.fmtAgo(widget.entry.lastWatched),
                  style: const TextStyle(
                    color: AppColors.darkOnSurfaceMuted,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(widget.entry.progress * 100).toInt()}% watched',
                style: const TextStyle(
                  color: AppColors.accentBlue,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(1.5),
            child: LinearProgressIndicator(
              value: widget.entry.progress,
              minHeight: 3,
              backgroundColor: Colors.white12,
              valueColor:
                  const AlwaysStoppedAnimation(AppColors.accentBlue),
            ),
          ),
        ],
      ),
      trailing: IconButton(
        tooltip: 'Close',
        icon: const Icon(
          Icons.close,
          color: AppColors.darkOnSurfaceMuted,
          size: 18,
        ),
        onPressed: widget.onDelete,
      ),
      onTap: widget.onTap,
    );
  }
}
