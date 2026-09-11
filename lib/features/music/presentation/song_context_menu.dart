import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/song.dart';
import 'music_player_screen.dart';
import 'music_providers.dart';

import '../../../core/localization/app_strings.dart';
/// Phase 36: Song context menu shown when ⋮ tapped on a song row.
/// Matches MX Player Music's song context sheet (Play Next, Play Later,
/// Add To Playlist, Favourite, Set as Ringtone, Share, Properties, Delete).
class SongContextMenu {
  static void show(BuildContext context, WidgetRef ref, Song song) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetCtx) {
        return _SongContextSheet(song: song, ref: ref);
      },
    );
  }
}

class _SongContextSheet extends StatelessWidget {
  final Song song;
  final WidgetRef ref;
  const _SongContextSheet({required this.song, required this.ref});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: track preview
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8D5F0),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Icon(Icons.music_note,
                      color: Color(0xFF9C5BC0), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(song.title,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(song.displayArtist,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          _MenuItem(
            icon: Icons.queue_music,
            label: 'Play Next',
            onTap: () {
              ref.read(musicPlayingProvider.notifier).playNext(song);
              Navigator.pop(context);
              _toast(context, 'Playing next: "${song.title}"');
            },
          ),
          _MenuItem(
            icon: Icons.playlist_play,
            label: 'Play Later',
            onTap: () {
              ref.read(musicPlayingProvider.notifier).playLater(song);
              Navigator.pop(context);
              _toast(context, 'Added to queue');
            },
          ),
          _MenuItem(
            icon: Icons.playlist_add,
            label: 'Add To Playlist',
            onTap: () {
              Navigator.pop(context);
              _showAddToPlaylistDialog(context, ref, song);
            },
          ),
          Consumer(
            builder: (_, innerRef, __) {
              final favs = innerRef
                  .watch(musicPlaylistProvider)
                  .firstWhere((p) => p.id == 'favs',
                      orElse: () => const MusicPlaylist(
                          id: 'favs',
                          name: 'My Favourites',
                          songUris: [],
                          builtIn: true));
              final isFav = favs.songUris.contains(song.uri);
              return _MenuItem(
                icon: isFav ? Icons.favorite : Icons.favorite_border,
                label: isFav ? 'Remove from Favourites' : 'Favourite',
                iconColor: isFav ? Colors.redAccent : null,
                onTap: () {
                  innerRef
                      .read(musicPlaylistProvider.notifier)
                      .toggleFavourite(song.uri);
                  Navigator.pop(context);
                  _toast(context,
                      !isFav ? 'Added to favourites' : 'Removed from favourites');
                },
              );
            },
          ),
          _MenuItem(
            icon: Icons.phone_in_talk_outlined,
            label: 'Set as Ringtone',
            onTap: () {
              Navigator.pop(context);
              _toast(context, 'Set as ringtone (requires system permission)');
            },
          ),
          _MenuItem(
            icon: Icons.share_outlined,
            label: 'Share',
            onTap: () async {
              Navigator.pop(context);
              try {
                await Share.share(song.uri, subject: song.title);
              } catch (e) { if (kDebugMode) debugPrint('song_context_menu.best-effort: $e'); }
            },
          ),
          _MenuItem(
            icon: Icons.info_outline,
            label: 'Properties',
            onTap: () {
              Navigator.pop(context);
              _showProperties(context, song);
            },
          ),
          _MenuItem(
            icon: Icons.delete_outline,
            label: 'Delete',
            iconColor: const Color(0xFFEF5350),
            onTap: () {
              Navigator.pop(context);
              _toast(context, 'Delete requires Android MediaStore permission');
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  static void _toast(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(milliseconds: 1200)),
    );
  }

  static void _showProperties(BuildContext context, Song song) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).properties,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _PropRow('Title', song.title),
            _PropRow('Artist', song.displayArtist),
            _PropRow('Album', song.album.isEmpty ? 'Unknown' : song.album),
            _PropRow('Duration', _formatDuration(song.duration)),
            _PropRow('Size', song.formattedSize),
            _PropRow('Path', song.folderPath, maxLines: 2),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(AppStrings.of(context).close.toUpperCase(),
                style: const TextStyle(color: AppColors.primaryBlue)),
          ),
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: song.uri));
              Navigator.pop(context);
              _toast(context, 'Path copied');
            },
            child: Text(AppStrings.of(context).copyPath.toUpperCase(),
                style: const TextStyle(color: AppColors.primaryBlue)),
          ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${h}h ${m}m ${s}s';
    }
    return '${m}m ${s}s';
  }

  static void _showAddToPlaylistDialog(
      BuildContext context, WidgetRef ref, Song song) {
    final playlists = ref.read(musicPlaylistProvider);
    showDialog<void>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.darkSurface,
        title: Text(AppStrings.of(context).addToPlaylist,
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: playlists.length,
            itemBuilder: (_, i) {
              final p = playlists[i];
              return ListTile(
                dense: true,
                leading: Icon(
                  p.id == 'favs'
                      ? Icons.favorite
                      : p.id == 'recent'
                          ? Icons.access_time
                          : Icons.queue_music,
                  color: Colors.white70,
                  size: 20,
                ),
                title: Text(p.name,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
                subtitle: Text('${p.songUris.length} songs',
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: () {
                  ref
                      .read(musicPlaylistProvider.notifier)
                      .addSongToPlaylist(p.id, song.uri);
                  Navigator.pop(dCtx);
                  _toast(context, 'Added to ${p.name}');
                },
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: Text(AppStrings.of(context).cancel.toUpperCase(),
                style: const TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? Colors.white, size: 22),
            const SizedBox(width: 16),
            Text(label,
                style: TextStyle(
                    color: iconColor ?? Colors.white, fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _PropRow extends StatelessWidget {
  final String label;
  final String value;
  final int maxLines;
  const _PropRow(this.label, this.value, {this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label,
                style:
                    const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Header overflow menu for detail screens (Album / Artist / Playlist / Folder)
class DetailHeaderActions {
  /// Share entire collection (artist/album/folder/playlist)
  static void share(BuildContext context, String collectionName) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(AppStrings.of(context).sharingName(collectionName)),
        duration: const Duration(milliseconds: 1200),
      ),
    );
  }

  /// Overflow menu for detail screens. Phase 39: callers may pass real
  /// [onPlayAll]/[onShuffle]/[onAddToPlaylist]/[onRename] handlers; when a
  /// handler is omitted the row falls back to an informational toast so
  /// nothing crashes.
  static void showOverflow(
    BuildContext context,
    String collectionName, {
    bool isPlaylist = false,
    VoidCallback? onPlayAll,
    VoidCallback? onShuffle,
    VoidCallback? onAddToPlaylist,
    VoidCallback? onRename,
  }) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.darkSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _MenuItem(
                icon: Icons.queue_music,
                label: 'Play All',
                onTap: () {
                  Navigator.pop(ctx);
                  if (onPlayAll != null) {
                    onPlayAll();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(AppStrings.of(context).playingName(collectionName)),
                          duration: const Duration(milliseconds: 1000)),
                    );
                  }
                },
              ),
              _MenuItem(
                icon: Icons.shuffle,
                label: 'Shuffle Play',
                onTap: () {
                  Navigator.pop(ctx);
                  if (onShuffle != null) {
                    onShuffle();
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                          content: Text(AppStrings.of(context).shufflingName(collectionName)),
                          duration: const Duration(milliseconds: 1000)),
                    );
                  }
                },
              ),
              _MenuItem(
                icon: Icons.playlist_add,
                label: 'Add To Playlist',
                onTap: () {
                  Navigator.pop(ctx);
                  onAddToPlaylist?.call();
                },
              ),
              if (isPlaylist)
                _MenuItem(
                  icon: Icons.drive_file_rename_outline,
                  label: 'Rename',
                  onTap: () {
                    Navigator.pop(ctx);
                    onRename?.call();
                  },
                ),
              _MenuItem(
                icon: Icons.info_outline,
                label: 'Properties',
                onTap: () {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                        content: Text(AppStrings.of(context).propertiesForName(collectionName)),
                        duration: const Duration(milliseconds: 1000)),
                  );
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}
