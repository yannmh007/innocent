import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../../../user_data/user_data_providers.dart';
import '../../domain/video.dart';
import '../library_provider.dart';
import '../selection_provider.dart';
import 'bulk_actions.dart';

/// The bottom bar for FOLDER multi-select.
///
/// ─── WHY FOLDERS GET THE SAME BAR ────────────────────────────────────────
///
/// Selecting three folders means "every video underneath these three", so the
/// actions are the same actions — and offering them in one selection mode but
/// not the other is the kind of gap that makes an app feel half-finished. The
/// folder mode had four icons in its AppBar and no bottom bar at all: no Move,
/// no Copy, no playlist, no Transfer, no Properties.
///
/// Every action runs through [BulkActions], the same code the video bar calls,
/// so an action cannot be real in one mode and a stub in the other.
class FolderSelectionActionBar extends ConsumerStatefulWidget {
  const FolderSelectionActionBar({super.key});

  @override
  ConsumerState<FolderSelectionActionBar> createState() =>
      _FolderSelectionActionBarState();
}

class _FolderSelectionActionBarState
    extends ConsumerState<FolderSelectionActionBar> {
  bool _busy = false;

  /// Every video under the selected folders.
  ///
  /// Matched on `folderPath` rather than a path prefix: a prefix match would
  /// pull in `/Movies 2` when the user picked `/Movies`, and moving a folder
  /// nobody selected is not a mistake that can be undone.
  List<Video> _videos() {
    final selected = ref.read(folderSelectionProvider);
    if (selected.isEmpty) return const <Video>[];
    final all = ref.read(allVideosProvider).valueOrNull ?? const <Video>[];
    return all.where((v) => selected.contains(v.folderPath)).toList();
  }

  Future<void> _run(Future<bool> Function(List<Video>) action) async {
    if (_busy) return;
    final videos = _videos();
    if (videos.isEmpty) {
      AppSnackbar.global(AppStrings.of(context).selectionNoFiles);
      return;
    }
    setState(() => _busy = true);
    final ok = await action(videos);
    if (!mounted) return;
    if (ok) ref.read(folderSelectionProvider.notifier).clear();
    setState(() => _busy = false);
  }

  void _toggleSelectAll() {
    final folders = ref.read(foldersProvider).valueOrNull ?? const [];
    final paths = <String>[for (final f in folders) f.path];
    final selected = ref.read(folderSelectionProvider);
    final notifier = ref.read(folderSelectionProvider.notifier);
    if (paths.isNotEmpty && paths.toSet().difference(selected).isEmpty) {
      notifier.clear();
    } else {
      notifier.selectAll(paths);
    }
  }

  Future<void> _addToPlaylist() async {
    final s = AppStrings.of(context);
    final playlists = ref.read(playlistsProvider);
    if (playlists.isEmpty) {
      AppSnackbar.global(s.noPlaylistsHint);
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      builder: (sheet) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(s.addToPlaylist,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600)),
            ),
            const Divider(height: 1, color: Colors.white12),
            ...playlists.map(
              (pl) => ListTile(
                leading: const Icon(Icons.playlist_play, color: Colors.white),
                title:
                    Text(pl.name, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.of(sheet).pop(pl.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final videos = _videos();
    final playlistsNotifier = ref.read(playlistsProvider.notifier);
    for (final v in videos) {
      await playlistsNotifier.addVideo(picked, v.uri);
    }
    if (!mounted) return;
    // The sheet returns the playlist's ID, not its name — showing the raw id
    // would put something like "pl_1724..." in front of the user. Resolve it
    // back to the name they picked.
    final matches = playlists.where((pl) => pl.id == picked);
    final name = matches.isEmpty ? '' : matches.first.name;
    ref.read(folderSelectionProvider.notifier).clear();
    AppSnackbar.global(
        AppStrings.of(context).addedToPlaylist(videos.length, name));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final selected = ref.watch(folderSelectionProvider);
    if (selected.isEmpty) return const SizedBox.shrink();

    final folders = ref.watch(foldersProvider).valueOrNull ?? const [];
    final allSelected = folders.isNotEmpty &&
        <String>{for (final f in folders) f.path}
            .difference(selected)
            .isEmpty;

    return Material(
      color: AppColors.darkSurface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              _action(
                icon: allSelected ? Icons.deselect : Icons.done_all,
                tooltip:
                    allSelected ? s.selectionDeselectAll : s.selectionSelectAll,
                onTap: _toggleSelectAll,
              ),
              _action(
                icon: Icons.drive_file_move_outline,
                tooltip: s.selectionMove,
                onTap: () => _run((v) => BulkActions.moveOrCopy(context, ref,
                    videos: v, move: true)),
              ),
              _action(
                icon: Icons.content_copy_outlined,
                tooltip: s.selectionCopy,
                onTap: () => _run((v) => BulkActions.moveOrCopy(context, ref,
                    videos: v, move: false)),
              ),
              _action(
                icon: Icons.playlist_add,
                tooltip: s.addToPlaylist,
                onTap: _addToPlaylist,
              ),
              _action(
                icon: Icons.send_to_mobile,
                tooltip: s.tabTransfer,
                onTap: () => _run(
                    (v) => BulkActions.sendToTransfer(context, ref, videos: v)),
              ),
              _action(
                icon: Icons.info_outline,
                tooltip: s.properties,
                onTap: () => _run(
                    (v) => BulkActions.properties(context, ref, videos: v)),
              ),
              _action(
                icon: Icons.visibility_off_outlined,
                tooltip: s.hide,
                onTap: () =>
                    _run((v) => BulkActions.hide(context, ref, videos: v)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: IconButton(
        icon: Icon(icon, color: _busy ? Colors.white24 : Colors.white),
        tooltip: tooltip,
        onPressed: _busy ? null : onTap,
      ),
    );
  }
}
