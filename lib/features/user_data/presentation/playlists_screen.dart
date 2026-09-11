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
import '../domain/user_data_models.dart';
import '../user_data_providers.dart';
import 'favourites_screen.dart';
import '../../../core/ui/safe_thumbnail.dart';

import '../../../core/localization/app_strings.dart';
/// Video Playlists screen matching MX Player (UI PDF page 9)
/// "Create New Playlist" button at top + Favourites entry + user playlists
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  Future<void> _createPlaylist(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).newPlaylistTitle,
            style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Playlist name',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(AppStrings.of(context).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(AppStrings.of(context).create,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await ref.read(playlistsProvider.notifier).create(name);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppStrings.of(context).createdPlaylist(name)),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _renamePlaylist(
      BuildContext context, WidgetRef ref, Playlist pl) async {
    final controller = TextEditingController(text: pl.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).renamePlaylist,
            style: const TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'New name',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(AppStrings.of(context).cancel,
                style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(dialogCtx).pop(controller.text.trim()),
            child: Text(AppStrings.of(context).rename,
                style: const TextStyle(color: AppColors.accentBlue)),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == pl.name) return;
    await ref.read(playlistsProvider.notifier).rename(pl.id, name);
  }

  void _playAll(BuildContext context, Playlist pl) {
    if (pl.videoUris.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppStrings.of(context).playlistEmpty)),
      );
      return;
    }
    final first = pl.videoUris.first;
    context.push(
      Routes.player,
      extra: {
        'uri': first,
        'title': _displayName(first),
      },
    );
  }

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
    final playlists = ref.watch(playlistsProvider);
    final favCount = ref.watch(favouritesProvider).length;

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(title: Text(AppStrings.of(context).videoPlaylists)),
      body: ListView(
        children: [
          // ─── CREATE NEW PLAYLIST BUTTON ───
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: InkWell(
              onTap: () => _createPlaylist(context, ref),
              borderRadius: BorderRadius.circular(8),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.accentBlue),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.playlist_add,
                        color: AppColors.accentBlue, size: 20),
                    const SizedBox(width: 8),
                    Text(AppStrings.of(context).createNewPlaylist,
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),

          // ─── FAVOURITES (built-in) — navigates to FavouritesScreen ───
          ListTile(
            leading: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.redAccent.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.favorite,
                  color: Colors.redAccent, size: 24),
            ),
            title: Text(AppStrings.of(context).favourites,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            subtitle: Text(
              '$favCount ${favCount == 1 ? "video" : "videos"}',
              style: const TextStyle(
                  color: AppColors.darkOnSurfaceMuted, fontSize: 12),
            ),
            trailing: const Icon(Icons.chevron_right,
                color: AppColors.darkOnSurfaceMuted),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const FavouritesScreen(),
              ),
            ),
          ),
          const Divider(height: 0, color: AppColors.darkDivider, indent: 72),

          // ─── USER PLAYLISTS ───
          ...playlists.map((pl) => Dismissible(
                key: ValueKey('pl_${pl.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  color: AppColors.error,
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: const Icon(Icons.delete_outline,
                      color: Colors.white, size: 24),
                ),
                confirmDismiss: (_) async {
                  return await showDialog<bool>(
                    context: context,
                    builder: (dctx) => AlertDialog(
                      backgroundColor: AppColors.darkSurface,
                      title: Text(AppStrings.of(context).deleteNameTitle(pl.name),
                          style: const TextStyle(color: Colors.white)),
                      content: Text(
                        'This will remove ${pl.videoUris.length} video reference(s) from the playlist. Files on your device are NOT deleted.',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(dctx).pop(false),
                          child: Text(AppStrings.of(context).cancel,
                              style: const TextStyle(color: Colors.white70)),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(dctx).pop(true),
                          child: Text(AppStrings.of(context).delete,
                              style: const TextStyle(color: AppColors.error)),
                        ),
                      ],
                    ),
                  );
                },
                onDismissed: (_) async {
                  await ref
                      .read(playlistsProvider.notifier)
                      .delete(pl.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(AppStrings.of(context).deletedName(pl.name)),
                        behavior: SnackBarBehavior.floating,
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  }
                },
                child: Column(
                  children: [
                    ListTile(
                      leading: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.accentBlue15,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(Icons.playlist_play,
                            color: AppColors.accentBlue, size: 24),
                      ),
                      title: Text(pl.name,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15)),
                      subtitle: Text(
                        '${pl.videoUris.length} ${pl.videoUris.length == 1 ? "video" : "videos"}',
                        style: const TextStyle(
                            color: AppColors.darkOnSurfaceMuted,
                            fontSize: 12),
                      ),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert,
                            color: AppColors.darkOnSurfaceMuted, size: 20),
                        color: AppColors.darkSurface,
                        onSelected: (v) async {
                          if (v == 'play') {
                            _playAll(context, pl);
                          } else if (v == 'rename') {
                            await _renamePlaylist(context, ref, pl);
                          } else if (v == 'delete') {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (dctx) => AlertDialog(
                                backgroundColor: AppColors.darkSurface,
                                title: Text(AppStrings.of(context).deleteNameTitle(pl.name),
                                    style: const TextStyle(
                                        color: Colors.white)),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dctx).pop(false),
                                    child: Text(AppStrings.of(context).cancel,
                                        style: const TextStyle(
                                            color: Colors.white70)),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dctx).pop(true),
                                    child: Text(AppStrings.of(context).delete,
                                        style: const TextStyle(
                                            color: AppColors.error)),
                                  ),
                                ],
                              ),
                            );
                            if (confirm == true) {
                              await ref
                                  .read(playlistsProvider.notifier)
                                  .delete(pl.id);
                            }
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                              value: 'play',
                              child: Row(children: [
                                const Icon(Icons.play_arrow, size: 18),
                                const SizedBox(width: 10),
                                Text(AppStrings.of(context).playAll),
                              ])),
                          PopupMenuItem(
                              value: 'rename',
                              child: Row(children: [
                                const Icon(Icons.edit_outlined, size: 18),
                                const SizedBox(width: 10),
                                Text(AppStrings.of(context).rename),
                              ])),
                          PopupMenuItem(
                              value: 'delete',
                              child: Row(children: [
                                const Icon(Icons.delete_outline, size: 18),
                                const SizedBox(width: 10),
                                Text(AppStrings.of(context).delete),
                              ])),
                        ],
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              PlaylistDetailScreen(playlist: pl),
                        ),
                      ),
                    ),
                    const Divider(
                        height: 0,
                        color: AppColors.darkDivider,
                        indent: 72),
                  ],
                ),
              )),

          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  Icon(
                    Icons.playlist_play,
                    size: 48,
                    color: Colors.white.withOpacity(0.25),
                  ),
                  const SizedBox(height: 12),
                  Text(AppStrings.of(context).noCustomPlaylists,
                    style: const TextStyle(
                      color: AppColors.white50,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Create one above, or tap ⋮ on any video to add it to a playlist.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.white40,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class PlaylistDetailScreen extends ConsumerWidget {
  final Playlist playlist;
  const PlaylistDetailScreen({super.key, required this.playlist});

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
    final current = ref.watch(playlistsProvider).firstWhere(
          (p) => p.id == playlist.id,
          orElse: () => playlist,
        );

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: Text(current.name),
        actions: [
          if (current.videoUris.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.play_arrow),
              tooltip: 'Play all',
              onPressed: () {
                final first = current.videoUris.first;
                context.push(
                  Routes.player,
                  extra: {
                    'uri': first,
                    'title': _displayName(first),
                  },
                );
              },
            ),
        ],
      ),
      body: current.videoUris.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.queue_music,
                      size: 64,
                      color: AppColors.white30,
                    ),
                    const SizedBox(height: 16),
                    Text(AppStrings.of(context).playlistEmpty,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Tap ⋮ on a video and choose "Add to Playlist" → "${current.name}"',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppColors.white55,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: () async {
                ref.invalidate(playlistsProvider);
              },
              child: ReorderableListView.builder(
                itemCount: current.videoUris.length,
                onReorder: (oldIndex, newIndex) {
                  ref.read(playlistsProvider.notifier).reorderVideos(
                        current.id,
                        oldIndex,
                        newIndex,
                      );
                },
                itemBuilder: (_, i) {
                  final uri = current.videoUris[i];
                  final name = _displayName(uri);
                  return Container(
                    key: ValueKey(uri),
                    color: AppColors.darkBackground,
                    child: Column(
                      children: [
                        _PlaylistItemTile(
                          index: i,
                          uri: uri,
                          name: name,
                          onTap: () => context.push(
                            Routes.player,
                            extra: {'uri': uri, 'title': name},
                          ),
                          onRemove: () => ref
                              .read(playlistsProvider.notifier)
                              .removeVideo(current.id, uri),
                        ),
                        const Divider(
                            height: 0, color: AppColors.darkDivider),
                      ],
                    ),
                  );
                },
              ),
            ),
    );
  }
}

class _PlaylistItemTile extends StatefulWidget {
  final int index;
  final String uri;
  final String name;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _PlaylistItemTile({
    required this.index,
    required this.uri,
    required this.name,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_PlaylistItemTile> createState() => _PlaylistItemTileState();
}

class _PlaylistItemTileState extends State<_PlaylistItemTile> {
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
    } catch (e) { if (kDebugMode) debugPrint('playlists_screen.best-effort: $e'); }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: widget.index,
            child: const Icon(
              Icons.drag_handle,
              color: AppColors.darkOnSurfaceMuted,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            width: 56,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.darkSurfaceVariant,
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.antiAlias,
            child: _thumb != null
                ? SafeThumbnail(bytes: _thumb!)
                : const Icon(Icons.movie_outlined,
                    color: AppColors.darkOnSurfaceMuted, size: 18),
          ),
        ],
      ),
      title: Text(
        widget.name,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '#${widget.index + 1}',
        style: const TextStyle(
          color: AppColors.darkOnSurfaceMuted,
          fontSize: 11,
        ),
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
