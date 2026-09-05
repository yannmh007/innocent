import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/localization/app_strings.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/ui/app_snackbar.dart';
import '../../../user_data/domain/user_data_models.dart';
import '../../../user_data/user_data_providers.dart';
import '../../domain/video.dart';
import '../library_provider.dart';
import 'bulk_actions.dart';
import '../selection_provider.dart';

/// The bar that slides up from the bottom while videos are selected.
///
/// ─── WHY A BOTTOM BAR AND NOT MORE APP-BAR ICONS ────────────────────────
///
/// The previous design put seven actions in the AppBar's `actions:` row. On a
/// phone that row has space for three or four before Flutter starts dropping
/// them, so the ones past the edge were simply invisible — including Delete.
/// Splitting selection into a top bar that says WHAT is selected and a bottom
/// bar that says WHAT CAN BE DONE is the arrangement every file manager
/// converged on, and it puts the destructive action furthest from the thumb's
/// resting position rather than next to Play.
class SelectionActionBar extends ConsumerStatefulWidget {
  /// Every video URI currently on screen, in order — the pool that
  /// "select all" selects from.
  ///
  /// Optional. When the host screen shows a list it already has in hand (a
  /// folder's contents), it passes them. When it does not, the bar reads
  /// [filteredAllVideosProvider] — the SAME provider the list is built from,
  /// so "select all" can never select something the user cannot see. Reading
  /// the provider rather than caching what was last built also avoids the
  /// one-frame staleness of recording the list during the body's build and
  /// consuming it in the bar's.
  final List<String>? visibleUris;

  const SelectionActionBar({super.key, this.visibleUris});

  @override
  ConsumerState<SelectionActionBar> createState() => _SelectionActionBarState();
}

class _SelectionActionBarState extends ConsumerState<SelectionActionBar> {
  /// True while a move or copy is running. Every button is disabled for the
  /// duration: a second move started over the first would race it for the same
  /// files, and the loser deletes a source the winner has already moved.
  bool _busy = false;

  /// The selected videos, resolved once.
  List<Video> _selected() {
    final selection = ref.read(selectionProvider);
    final all = ref.read(allVideosProvider).valueOrNull ?? const <Video>[];
    return all.where((v) => selection.contains(v.uri)).toList();
  }

  /// Move or copy, through the shared implementation both selection modes use.
  Future<void> _moveOrCopy({required bool move}) async {
    if (_busy) return;
    final videos = _selected();
    if (videos.isEmpty) return;
    setState(() => _busy = true);
    final ok = await BulkActions.moveOrCopy(
      context,
      ref,
      videos: videos,
      move: move,
    );
    if (!mounted) return;
    // Only clear on success: a cancelled destination picker used to throw the
    // selection away, so the user had to pick all twenty files again.
    if (ok) ref.read(selectionProvider.notifier).clear();
    setState(() => _busy = false);
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
              child: Text(
                s.addToPlaylist,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600),
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            ...playlists.map(
              (pl) => ListTile(
                leading: const Icon(Icons.playlist_play, color: Colors.white),
                title:
                    Text(pl.name, style: const TextStyle(color: Colors.white)),
                subtitle: Text(
                  '${pl.videoUris.length}',
                  style: const TextStyle(
                      color: AppColors.darkOnSurfaceMuted, fontSize: 12),
                ),
                onTap: () => Navigator.of(sheet).pop(pl.id),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    final selection = ref.read(selectionProvider);
    final playlistsNotifier = ref.read(playlistsProvider.notifier);
    for (final uri in selection) {
      await playlistsNotifier.addVideo(picked, uri);
    }
    if (!mounted) return;
    // `firstWhere` with no `orElse` THROWS when nothing matches. The sheet is
    // async, so a playlist deleted from another screen while it was open would
    // have crashed the tab on what is otherwise a successful add.
    final matches = playlists.where((p) => p.id == picked);
    final name = matches.isEmpty ? '' : matches.first.name;
    ref.read(selectionProvider.notifier).clear();
    AppSnackbar.global(
        AppStrings.of(context).addedToPlaylist(selection.length, name));
  }

  Future<void> _delete() async {
    final s = AppStrings.of(context);
    final count = ref.read(selectionProvider).length;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(s.moveToBinTitle,
            style: const TextStyle(color: Colors.white)),
        content: Text(
          s.confirmBinBody(count),
          style: const TextStyle(color: Colors.white70),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(s.cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(s.move,
                style: const TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final selection = ref.read(selectionProvider);
    final all = ref.read(allVideosProvider).maybeWhen(
          data: (list) => list,
          orElse: () => const [],
        );
    var moved = 0;
    // Captured outside the loop: `ref` belongs to this widget, and a long
    // selection gives the user time to leave mid-loop.
    final bin = ref.read(recycleBinProvider.notifier);
    for (final uri in selection) {
      // Look the video up rather than assuming a match. The old code fell
      // back to `allVideos.first` when the lookup missed, then relied on a
      // follow-up equality check to undo it — a bin entry for the wrong file
      // was one edit away the whole time.
      final matches = all.where((v) => v.uri == uri);
      if (matches.isEmpty) continue;
      final video = matches.first;
      await bin.add(
            RecycleBinEntry(
              videoUri: video.uri,
              videoTitle: video.title,
              folderPath: video.folderPath,
              deletedAt: DateTime.now(),
              sizeBytes: video.sizeBytes,
            ),
          );
      moved++;
    }
    ref.read(selectionProvider.notifier).clear();
    if (!mounted) return;
    AppSnackbar.global(s.movedToBin(moved));
  }

  /// The pool "select all" works over. See [SelectionActionBar.visibleUris].
  List<String> get _pool {
    final given = widget.visibleUris;
    if (given != null) return given;
    return ref.read(filteredAllVideosProvider).maybeWhen(
          data: (list) => <String>[for (final v in list) v.uri],
          orElse: () => const <String>[],
        );
  }

  void _toggleSelectAll() {
    final notifier = ref.read(selectionProvider.notifier);
    final selected = ref.read(selectionProvider);
    final pool = _pool;
    final allOnScreen = pool.toSet();
    // "Select all" when anything on screen is unselected, "deselect all" only
    // once everything is. Judged against WHAT IS VISIBLE, so a filtered list
    // cannot silently select things the user cannot see.
    if (allOnScreen.difference(selected).isEmpty) {
      notifier.clear();
    } else {
      notifier.selectAll(pool);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppStrings.of(context);
    final selected = ref.watch(selectionProvider);
    if (selected.isEmpty) return const SizedBox.shrink();

    final pool = _pool;
    final allSelected =
        pool.isNotEmpty && pool.toSet().difference(selected).isEmpty;

    return Material(
      color: AppColors.darkSurface,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _action(
                icon: allSelected ? Icons.deselect : Icons.done_all,
                tooltip: allSelected
                    ? s.selectionDeselectAll
                    : s.selectionSelectAll,
                onTap: _toggleSelectAll,
              ),
              _action(
                icon: Icons.drive_file_move_outline,
                tooltip: s.selectionMove,
                onTap: () => _moveOrCopy(move: true),
              ),
              _action(
                icon: Icons.content_copy_outlined,
                tooltip: s.selectionCopy,
                onTap: () => _moveOrCopy(move: false),
              ),
              _action(
                icon: Icons.playlist_add,
                tooltip: s.addToPlaylist,
                onTap: _addToPlaylist,
              ),
              _action(
                icon: Icons.favorite_outline,
                tooltip: s.favourite,
                onTap: () async {
                  // Notifier captured OUTSIDE the loop. `ref` belongs to this
                  // widget; a fifty-item loop gives the user plenty of time to
                  // navigate away, and a read after disposal throws.
                  final sel = ref.read(selectionProvider);
                  final favourites = ref.read(favouritesProvider.notifier);
                  final selection = ref.read(selectionProvider.notifier);
                  for (final uri in sel) {
                    await favourites.toggle(uri);
                  }
                  selection.clear();
                },
              ),
              _action(
                icon: Icons.watch_later_outlined,
                tooltip: s.watchLater,
                onTap: () async {
                  final sel = ref.read(selectionProvider);
                  final later = ref.read(watchLaterProvider.notifier);
                  final selection = ref.read(selectionProvider.notifier);
                  for (final uri in sel) {
                    await later.add(uri);
                  }
                  selection.clear();
                },
              ),
              _action(
                icon: Icons.delete_outline,
                tooltip: s.delete,
                destructive: true,
                onTap: _delete,
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
    bool destructive = false,
  }) {
    final enabled = !_busy;
    return Expanded(
      child: IconButton(
        icon: Icon(icon,
            color: !enabled
                ? Colors.white24
                : destructive
                    ? AppColors.error
                    : Colors.white),
        tooltip: tooltip,
        onPressed: enabled ? onTap : null,
      ),
    );
  }
}
