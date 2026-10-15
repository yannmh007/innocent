import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/theme/app_colors.dart';
import '../domain/song.dart';
import 'music_providers.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/ui/share_media.dart';
import '../../../core/ui/app_snackbar.dart';
import '../../../core/ui/app_sheet.dart';
/// Phase 36: Song context menu shown when ⋮ tapped on a song row.
/// Matches MX Player Music's song context sheet (Play Next, Play Later,
/// Add To Playlist, Favourite, Set as Ringtone, Share, Properties, Delete).
class SongContextMenu {
  static void show(BuildContext context, WidgetRef ref, Song song) {
    showAppModalBottomSheet<void>(
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
            label: AppStrings.of(context).mcPlayNext,
            onTap: () {
              ref.read(musicPlayingProvider.notifier).playNext(song);
              Navigator.pop(context);
              _toast(context, AppStrings.current.mcPlayingNext(song.title));
            },
          ),
          _MenuItem(
            icon: Icons.playlist_play,
            label: AppStrings.of(context).mcPlayLater,
            onTap: () {
              ref.read(musicPlayingProvider.notifier).playLater(song);
              Navigator.pop(context);
              _toast(context, AppStrings.current.mcQueued);
            },
          ),
          _MenuItem(
            icon: Icons.playlist_add,
            label: AppStrings.of(context).addToPlaylist,
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
                label: isFav ? AppStrings.of(context).vomRemoveFav : AppStrings.of(context).favourite,
                iconColor: isFav ? Colors.redAccent : null,
                onTap: () {
                  innerRef
                      .read(musicPlaylistProvider.notifier)
                      .toggleFavourite(song.uri);
                  Navigator.pop(context);
                  _toast(context,
                      !isFav ? AppStrings.current.mcFavAdded : AppStrings.current.mcFavRemoved);
                },
              );
            },
          ),
          _MenuItem(
            icon: Icons.share_outlined,
            label: AppStrings.of(context).share,
            onTap: () async {
              Navigator.pop(context);
              try {
                await shareMedia(song.uri, subject: song.title);
              } catch (e) { if (kDebugMode) debugPrint('song_context_menu.best-effort: $e'); }
            },
          ),
          _MenuItem(
            icon: Icons.info_outline,
            label: AppStrings.of(context).properties,
            onTap: () {
              Navigator.pop(context);
              _showProperties(context, song);
            },
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// Raised after the sheet has closed itself, when its context is gone —
  /// so through the root messenger, which needs none.
  static void _toast(BuildContext context, String msg) {
    AppSnackbar.global(msg, duration: const Duration(milliseconds: 1200));
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
            _PropRow(AppStrings.of(context).mcTitle, song.title),
            _PropRow(AppStrings.of(context).mcArtist, song.displayArtist),
            _PropRow(AppStrings.of(context).mcAlbum, song.album.isEmpty ? AppStrings.of(context).mcUnknown : song.album),
            _PropRow(AppStrings.of(context).mcDuration, _formatDuration(song.duration)),
            _PropRow(AppStrings.of(context).propSize, song.formattedSize),
            _PropRow(AppStrings.of(context).mcPath, song.folderPath, maxLines: 2),
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
              _toast(context, AppStrings.current.mcPathCopied);
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
                title: Text(p.displayName(AppStrings.of(context)),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 14)),
                subtitle: Text(AppStrings.of(context).songsCount(p.songUris.length),
                    style:
                        const TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: () {
                  ref
                      .read(musicPlaylistProvider.notifier)
                      .addSongToPlaylist(p.id, song.uri);
                  Navigator.pop(dCtx);
                  _toast(context, AppStrings.current.vomAddedTo(p.displayName(AppStrings.current)));
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
  /// Share the songs of an album, folder or playlist — the files. This used
  /// to show "Sharing <name>" and share nothing at all.
  static Future<void> share(
      BuildContext context, String collectionName, List<Song> songs) async {
    final s = AppStrings.of(context);
    // Bounded, as the Video tab's bulk Share is: a share sheet handed
    // hundreds of files stops answering.
    final files = <XFile>[
      for (final song in songs.take(50))
        if (localPathOf(song.uri) case final path?) XFile(path),
    ];
    if (files.isEmpty) {
      AppSnackbar.global(s.noSongsFound);
      return;
    }
    try {
      await Share.shareXFiles(files, subject: collectionName);
    } catch (e) {
      if (kDebugMode) debugPrint('DetailHeaderActions.share: $e');
      AppSnackbar.globalError(s.shareFailed);
    }
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
    showAppModalBottomSheet<void>(
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
                label: AppStrings.of(context).mcPlayAll,
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
                label: AppStrings.of(context).mcShufflePlay,
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
              if (onAddToPlaylist != null)
                _MenuItem(
                  icon: Icons.playlist_add,
                  label: AppStrings.of(context).addToPlaylist,
                  onTap: () {
                    Navigator.pop(ctx);
                    onAddToPlaylist();
                  },
                ),
              if (isPlaylist)
                _MenuItem(
                  icon: Icons.drive_file_rename_outline,
                  label: AppStrings.of(context).rename,
                  onTap: () {
                    Navigator.pop(ctx);
                    onRename?.call();
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
