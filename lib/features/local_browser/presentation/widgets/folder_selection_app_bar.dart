import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/router/routes.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../private_folder/data/private_folder_providers.dart';
import '../../domain/video.dart';
import '../library_provider.dart';
import 'bulk_actions.dart';
import '../selection_provider.dart';

/// Contextual app bar shown when one or more FOLDERS are selected in the
/// Local tab (long-press to enter). Mirrors MX Player's folder multi-select:
/// bulk Lock-in-Private-Folder, Delete, Play, Share.
class FolderSelectionAppBar extends ConsumerWidget
    implements PreferredSizeWidget {
  const FolderSelectionAppBar({super.key});

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  /// All videos that live inside the currently-selected folders.
  List<Video> _videosInSelection(WidgetRef ref, Set<String> folderPaths) {
    final all = ref.read(allVideosProvider).valueOrNull ?? const <Video>[];
    return all.where((v) => folderPaths.contains(v.folderPath)).toList();
  }

  AppStrings s(BuildContext c) => AppStrings.of(c);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = AppStrings.of(context);
    final selected = ref.watch(folderSelectionProvider);
    final count = selected.length;

    return AppBar(
      backgroundColor: AppColors.specSurface,
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: s.clearSelection,
        onPressed: () =>
            ref.read(folderSelectionProvider.notifier).clear(),
      ),
      title: Text(s.selectedCount(count),
          style: const TextStyle(
              color: Colors.white, fontSize: 17, fontWeight: FontWeight.w600)),
      actions: [
        IconButton(
          icon: const Icon(Icons.play_arrow),
          tooltip: s.playAll,
          onPressed: () => _playAll(context, ref, selected),
        ),
        IconButton(
          icon: const Icon(Icons.lock_outline),
          tooltip: s.lockInPrivateFolder,
          onPressed: () => _lockInPrivate(context, ref, selected),
        ),
        IconButton(
          icon: const Icon(Icons.share_outlined),
          tooltip: s.share,
          onPressed: () => _share(context, ref, selected),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: s.delete,
          onPressed: () => _delete(context, ref, selected),
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          color: AppColors.darkSurface,
          onSelected: (v) async {
            if (v == 'all') {
              final folders =
                  ref.read(foldersProvider).valueOrNull ?? const [];
              ref
                  .read(folderSelectionProvider.notifier)
                  .selectAll(folders.map((f) => f.path).toList());
              return;
            }
            // Everything else runs on the videos UNDER the selected folders,
            // through the same [BulkActions] the video selection mode uses —
            // so an action cannot be real in one mode and a stub in the other.
            final videos = _videosInSelection(ref, selected);
            if (videos.isEmpty) return;
            var handled = false;
            switch (v) {
              case 'transfer':
                handled = await BulkActions.sendToTransfer(context, ref,
                    videos: videos);
              case 'hide':
                handled =
                    await BulkActions.hide(context, ref, videos: videos);
              case 'rebuild':
                handled = await BulkActions.rebuildThumbnails(context, ref,
                    videos: videos);
              case 'properties':
                handled = await BulkActions.properties(context, ref,
                    videos: videos);
            }
            if (handled) {
              ref.read(folderSelectionProvider.notifier).clear();
            }
          },
          itemBuilder: (_) => <PopupMenuEntry<String>>[
            _menuItem('all', Icons.select_all, s.selectAll),
            const PopupMenuDivider(),
            _menuItem('transfer', Icons.send_to_mobile, s.tabTransfer),
            _menuItem('hide', Icons.visibility_off_outlined, s.hide),
            _menuItem('rebuild', Icons.refresh, s.rebuildThumbnail),
            _menuItem('properties', Icons.info_outline, s.properties),
          ],
        ),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(
      String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: <Widget>[
        Icon(icon, size: 20, color: Colors.white70),
        const SizedBox(width: 12),
        Text(label, style: const TextStyle(color: Colors.white)),
      ]),
    );
  }

  Future<void> _playAll(
      BuildContext context, WidgetRef ref, Set<String> folders) async {
    final videos = _videosInSelection(ref, folders);
    if (videos.isEmpty) return;
    ref.read(folderSelectionProvider.notifier).clear();
    // Play the first video from the combined selection (a safe default that
    // matches MX Player's folder multi-select). The player opens on the
    // root navigator via the shared route.
    if (context.mounted) {
      context.push(Routes.player, extra: {
        'uri': videos.first.uri,
        'title': videos.first.title,
      });
    }
  }

  Future<void> _share(
      BuildContext context, WidgetRef ref, Set<String> folders) async {
    final videos = _videosInSelection(ref, folders);
    if (videos.isEmpty) return;
    // Share up to a sane number of files to avoid overwhelming the sheet.
    final paths = videos
        .map((v) => v.uri)
        .where((u) => u.startsWith('/') || u.startsWith('file://'))
        .map((u) => u.replaceFirst('file://', ''))
        .take(50)
        .toList();
    if (paths.isEmpty) return;
    ref.read(folderSelectionProvider.notifier).clear();
    try {
      await Share.shareXFiles(paths.map((p) => XFile(p)).toList());
    } catch (_) {}
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, Set<String> folders) async {
    final st = s(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(st.deleteFoldersTitle,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          st.deleteFoldersBody(),
          style: const TextStyle(color: AppColors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(st.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(st.delete,
                  style: const TextStyle(color: AppColors.error))),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;

    final svc = ref.read(privateFolderServiceProvider);
    await _runBatch(
      context,
      ref,
      folders,
      title: st.deletingFiles,
      action: (v) async {
        // Resolve the real on-disk path (handles file:// and content://
        // via the service's resolver); delete it if it's a local file.
        final path = svc.resolveFilePath(v.uri);
        if (path != null && path.startsWith('/')) {
          final f = File(path);
          if (await f.exists()) await f.delete();
        }
      },
    );
    ref.invalidate(allVideosProvider);
    ref.invalidate(foldersProvider);
  }

  Future<void> _lockInPrivate(
      BuildContext context, WidgetRef ref, Set<String> folders) async {
    final st = s(context);
    final videos = _videosInSelection(ref, folders);
    if (videos.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(st.noVideosToLock)));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(st.lockInPrivateFolder,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Text(
          st.lockFoldersBody(),
          style: const TextStyle(color: AppColors.white70, fontSize: 13.5),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(st.cancel)),
          TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(st.lock,
                  style: const TextStyle(color: AppColors.accentBlue))),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;

    final svc = ref.read(privateFolderServiceProvider);
    await _runBatch(
      context,
      ref,
      folders,
      title: st.movingToPrivate,
      action: (v) async {
        await svc.importToVault(videoUri: v.uri, videoTitle: v.title);
      },
    );
    ref.invalidate(allVideosProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(privateFolderUrisProvider);
  }

  /// Run [action] over every video in the selected folders, showing a
  /// cancellable progress dialog and yielding between files so a large
  /// batch (many big videos) never blocks the UI thread or triggers an
  /// ANR. Errors on individual files are collected, not fatal.
  Future<void> _runBatch(
    BuildContext context,
    WidgetRef ref,
    Set<String> folders, {
    required String title,
    required Future<void> Function(Video v) action,
  }) async {
    final videos = _videosInSelection(ref, folders);
    if (videos.isEmpty) {
      ref.read(folderSelectionProvider.notifier).clear();
      return;
    }
    final progress = ValueNotifier<int>(0);
    final cancelled = ValueNotifier<bool>(false);
    int failed = 0;

    // Show the progress dialog (non-dismissible; has its own Cancel). We
    // capture the dialog's own context so we can close exactly this route
    // afterwards, instead of guessing with rootNavigator.
    BuildContext? dialogCtx;
    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) {
        dialogCtx = dctx;
        return _BatchProgressDialog(
          title: title,
          total: videos.length,
          progress: progress,
          onCancel: () => cancelled.value = true,
        );
      },
    );

    for (var i = 0; i < videos.length; i++) {
      if (cancelled.value) break;
      try {
        await action(videos[i]);
      } catch (_) {
        failed++;
      }
      progress.value = i + 1;
      // Yield to the event loop so the progress bar repaints and input
      // stays responsive between (potentially large) file operations.
      await Future<void>.delayed(Duration.zero);
    }

    // Close the progress dialog via its own context.
    if (dialogCtx != null && dialogCtx!.mounted) {
      Navigator.of(dialogCtx!).pop();
    }
    await dialogFuture;

    progress.dispose();
    cancelled.dispose();
    ref.read(folderSelectionProvider.notifier).clear();

    if (context.mounted && failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(s(context).someFilesFailed(failed)),
        duration: const Duration(seconds: 2),
      ));
    }
  }
}

/// Progress dialog for a batch folder operation. Shows a determinate bar,
/// "n / total" count, and a Cancel button.
class _BatchProgressDialog extends StatefulWidget {
  final String title;
  final int total;
  final ValueNotifier<int> progress;
  final VoidCallback onCancel;

  const _BatchProgressDialog({
    required this.title,
    required this.total,
    required this.progress,
    required this.onCancel,
  });

  @override
  State<_BatchProgressDialog> createState() => _BatchProgressDialogState();
}

class _BatchProgressDialogState extends State<_BatchProgressDialog> {
  bool _cancelling = false;

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    return PopScope(
      // Can't dismiss with back — must use Cancel (keeps the batch state
      // and the dialog in sync).
      canPop: false,
      child: AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(widget.title,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: ValueListenableBuilder<int>(
          valueListenable: widget.progress,
          builder: (_, done, __) {
            final frac = widget.total > 0 ? done / widget.total : 0.0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 6,
                    backgroundColor: AppColors.darkBackground,
                    valueColor: const AlwaysStoppedAnimation(
                        AppColors.accentBlue),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _cancelling ? s.cancelling : '$done / ${widget.total}',
                  style: const TextStyle(
                      color: AppColors.white70, fontSize: 13),
                ),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() => _cancelling = true);
                    widget.onCancel();
                  },
            child: Text(s.cancel),
          ),
        ],
      ),
    );
  }
}
