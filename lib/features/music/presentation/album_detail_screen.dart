import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import 'music_player_screen.dart';
import 'music_providers.dart';
import 'song_context_menu.dart';
import '../../../core/utils/async_value_extensions.dart';

import '../../../core/localization/app_strings.dart';
/// Phase 34: Album detail screen — same layout as Artist Detail.
class AlbumDetailScreen extends ConsumerWidget {
  final String name;
  final Color tintColor;

  const AlbumDetailScreen({
    super.key,
    required this.name,
    required this.tintColor,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final songsAsync = ref.watch(songsByAlbumProvider(name));

    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    tintColor.withOpacity(0.4),
                    Colors.transparent,
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
              child: Column(
                children: [
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back,
                            color: Colors.white, size: 24),
                        onPressed: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Share',
                        icon: const Icon(Icons.share_outlined,
                            color: Colors.white70, size: 22),
                        onPressed: () =>
                            DetailHeaderActions.share(context, name),
                      ),
                      IconButton(
                        tooltip: 'More options',
                        icon: const Icon(Icons.more_vert,
                            color: Colors.white70, size: 22),
                        onPressed: () => DetailHeaderActions.showOverflow(
                          context,
                          name,
                          onPlayAll: () {
                            final songs = songsAsync.value ?? const [];
                            if (songs.isEmpty) return;
                            ref
                                .read(musicPlayingProvider.notifier)
                                .playQueue(songs, startIndex: 0);
                            Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                              builder: (_) => const MusicPlayerScreen(),
                            ));
                          },
                          onShuffle: () {
                            final songs = songsAsync.value ?? const [];
                            if (songs.isEmpty) return;
                            ref
                                .read(musicPlayingProvider.notifier)
                                .shufflePlayQueue(songs);
                            Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                              builder: (_) => const MusicPlayerScreen(),
                            ));
                          },
                        ),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: tintColor,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(Icons.album,
                              color: Colors.white54, size: 36),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: songsAsync.whenOrFallback(
                            data: (songs) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${songs.length} Song${songs.length == 1 ? '' : 's'}',
                                  style: TextStyle(
                                    color: AppColors.white60,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                            loading: () => Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            error: (_, __) => Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Play All
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  borderRadius: BorderRadius.circular(24),
                  onTap: () {
                    final songs = songsAsync.value ?? const [];
                    if (songs.isEmpty) return;
                    ref
                        .read(musicPlayingProvider.notifier)
                        .playQueue(songs, startIndex: 0);
                    ref
                        .read(musicPlaylistProvider.notifier)
                        .markPlayed(songs.first.uri);
                    Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                      builder: (_) => const MusicPlayerScreen(),
                    ));
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 22, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppColors.primaryBlue,
                      borderRadius: BorderRadius.circular(24),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow,
                            color: Colors.white, size: 20),
                        const SizedBox(width: 6),
                        Text(AppStrings.of(context).playAll,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // Song list
            Expanded(
              child: songsAsync.whenOrFallback(
                data: (songs) {
                  if (songs.isEmpty) {
                    return Center(
                      child: Text(AppStrings.of(context).noSongsIn(name),
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 13),
                      ),
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.only(bottom: 80),
                    itemCount: songs.length,
                    itemBuilder: (_, i) {
                      final s = songs[i];
                      return InkWell(
                        onTap: () {
                          ref
                              .read(musicPlayingProvider.notifier)
                              .playQueue(songs, startIndex: i);
                          ref
                              .read(musicPlaylistProvider.notifier)
                              .markPlayed(s.uri);
                          Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                            builder: (_) => const MusicPlayerScreen(),
                          ));
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Row(
                            children: [
                              Container(
                                width: 40,
                                height: 40,
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8D5F0),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Icon(Icons.music_note,
                                    color: Color(0xFF9C5BC0), size: 20),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisAlignment:
                                      MainAxisAlignment.center,
                                  children: [
                                    Text(
                                      s.title,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      s.displayArtist,
                                      style: const TextStyle(
                                          color: Colors.white54,
                                          fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'More options',
                                icon: const Icon(Icons.more_vert,
                                    color: Colors.white54, size: 20),
                                onPressed: () =>
                                    SongContextMenu.show(context, ref, s),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (_, __) => Center(
                  child: Text(AppStrings.of(context).errorLoadingAlbum,
                      style: const TextStyle(color: Colors.white54)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
