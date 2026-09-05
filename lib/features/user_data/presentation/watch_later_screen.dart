import 'package:flutter/foundation.dart';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../../../core/router/routes.dart';
import '../../../core/services/thumbnail/thumbnail_cache.dart';
import '../../../core/theme/app_colors.dart';
import '../user_data_providers.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
class WatchLaterScreen extends ConsumerWidget {
  const WatchLaterScreen({super.key});

  String _displayName(String uri) {
    try {
      if (uri.startsWith('file://')) {
        return p.basename(Uri.parse(uri).toFilePath());
      }
      return p.basename(uri);
    } catch (_) {
      return uri;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(watchLaterProvider);

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(AppStrings.of(context).watchLater),
        actions: [
          if (queue.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear_all),
              tooltip: 'Clear all',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    backgroundColor: AppColors.darkSurface,
                    title: Text(AppStrings.of(context).clearWatchLaterTitle,
                        style: TextStyle(color: Colors.white)),
                    content: Text(AppStrings.of(context).clearWatchLaterBody,
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
                  for (final uri in [...queue]) {
                    await ref.read(watchLaterProvider.notifier).remove(uri);
                  }
                }
              },
            ),
        ],
      ),
      body: queue.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.watch_later_outlined,
                        color: AppColors.darkOnSurfaceMuted, size: 64),
                    const SizedBox(height: 16),
                    Text(AppStrings.of(context).watchLaterEmpty,
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 8),
                    Text(AppStrings.of(context).watchLaterHint,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                // Play All header
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () {
                          // Open first video; queue continues via playPreviousInFolder logic
                          final first = queue.first;
                          context.push(
                            Routes.player,
                            extra: {
                              'uri': first,
                              'title': _displayName(first),
                            },
                          );
                        },
                        icon: const Icon(Icons.play_arrow,
                            color: Colors.white, size: 20),
                        label: Text(AppStrings.of(context).playAll),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 10),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${queue.length} ${queue.length == 1 ? "video" : "videos"}',
                        style: const TextStyle(
                          color: AppColors.darkOnSurfaceMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: RefreshIndicator(
   onRefresh: () async {
     ref.invalidate(watchLaterProvider);
   },
   child: ListView.builder(
                    itemCount: queue.length,
                    itemBuilder: (_, i) {
                      final uri = queue[i];
                      final name = _displayName(uri);
                      return Dismissible(
                        key: ValueKey('wl_$uri'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: AppColors.error,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: const Icon(Icons.delete_outline,
                              color: Colors.white, size: 24),
                        ),
                        onDismissed: (_) {
                          ref.read(watchLaterProvider.notifier).remove(uri);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(AppStrings.of(context).removedName(name)),
                              behavior: SnackBarBehavior.floating,
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                        child: _WLTile(
                          index: i + 1,
                          uri: uri,
                          name: name,
                          onTap: () => context.push(
                            Routes.player,
                            extra: {'uri': uri, 'title': name},
                          ),
                          onRemove: () => ref
                              .read(watchLaterProvider.notifier)
                              .remove(uri),
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

class _WLTile extends StatefulWidget {
  final int index;
  final String uri;
  final String name;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _WLTile({
    required this.index,
    required this.uri,
    required this.name,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_WLTile> createState() => _WLTileState();
}

class _WLTileState extends State<_WLTile> {
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
      var path = widget.uri;
      if (path.startsWith('file://')) {
        path = Uri.parse(path).toFilePath();
      }
      if (!path.startsWith('/')) return;
      if (!await File(path).exists()) return;
      final bytes = await ThumbnailCache.instance.get(path);
      if (!_disposed && mounted) {
        setState(() => _thumb = bytes);
      }
    } catch (e) { if (kDebugMode) debugPrint('watch_later_screen.best-effort: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Stack(
        children: [
          Container(
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
          Positioned(
            top: 2,
            left: 2,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.black65,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                '${widget.index}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      title: Text(
        widget.name,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Close',
        icon: const Icon(
          Icons.close,
          color: AppColors.darkOnSurfaceMuted,
          size: 18,
        ),
        onPressed: widget.onRemove,
      ),
      onTap: widget.onTap,
    );
  }
}
