import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/localization/app_strings.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/song.dart';
import 'album_detail_screen.dart';
import 'artist_detail_screen.dart';
import 'music_folder_detail_screen.dart';
import 'music_player_screen.dart';
import 'music_providers.dart';
import 'music_queue_sheet.dart';
import 'playlist_detail_screen.dart';
import 'song_context_menu.dart';
import '../../../core/utils/async_value_extensions.dart';
import '../../../core/ui/tablet_constrained_width.dart';
import '../../../core/theme/tab_title.dart';
import '../../shell/shell_back.dart';
import '../../../core/ui/app_sheet.dart';

/// Music tab — Tracks / Playlists / Albums / Artists / Folders
/// Matches MX Player UI (PDF page 5)
class MusicScreen extends ConsumerStatefulWidget {
  const MusicScreen({super.key});

  @override
  ConsumerState<MusicScreen> createState() => _MusicScreenState();
}

class _MusicScreenState extends ConsumerState<MusicScreen>
    with SingleTickerProviderStateMixin, TabBack<MusicScreen> {
  @override
  int get tabIndex => 1;

  late final TabController _tabController;
  bool _searching = false;
  final _searchController = TextEditingController();

  static const _tabs = ['Tracks', 'Playlists', 'Albums', 'Artists', 'Folders'];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Back closes the search first (the shell does it: shell_back.dart).
    tabBack(_searching
        ? () => setState(() {
              _searching = false;
              _searchController.clear();
            })
        : null);
    final s = AppStrings.of(context);
    return Scaffold(
      backgroundColor: AppColors.darkBackground,
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: AppStrings.of(context).searchSongs,
                  hintStyle:
                      const TextStyle(color: AppColors.white50),
                  border: InputBorder.none,
                ),
              )
            : Text(s.tabMusic,
                style: kTabTitleStyle.copyWith(color: Colors.white)),
        actions: [
          if (_searching)
            IconButton(
              tooltip: AppStrings.of(context).close,
              icon: const Icon(Icons.close),
              onPressed: () => setState(() {
                _searching = false;
                _searchController.clear();
              }),
            )
          else ...[
            IconButton(
              tooltip: AppStrings.of(context).search,
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
            // There was a ⋮ menu here: "Add to home screen" and "Add
            // widget" said "added" and added nothing, and "Resume play
            // settings" was three radio buttons wired to nothing.
          ],
        ],
        bottom: TabBar(
          controller: _tabController,
          isScrollable: true,
          indicatorColor: AppColors.primaryBlue,
          labelColor: AppColors.primaryBlue,
          unselectedLabelColor: AppColors.darkOnSurfaceMuted,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(text: s.musicTracks),
            Tab(text: s.playlists),
            Tab(text: s.musicAlbums),
            Tab(text: s.musicArtists),
            Tab(text: s.musicFolders),
          ],
        ),
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                // A phone-width column on a tablet or TV, as the Video tab.
                child: TabletConstrainedWidth(
                  maxWidth: 840,
                  child: TabBarView(
                  controller: _tabController,
                  children: [
                    _TracksTab(searchQuery: _searchController.text),
                    const _PlaylistsTab(),
                    const _AlbumsTab(),
                    const _ArtistsTab(),
                    const _FoldersTab(),
                  ],
                ),
                ),
              ),
              // ─── MINI PLAYER BAR ───
              const _MiniPlayerBar(),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── TRACKS TAB ───
class _TracksTab extends ConsumerStatefulWidget {
  final String searchQuery;
  const _TracksTab({required this.searchQuery});

  @override
  ConsumerState<_TracksTab> createState() => _TracksTabState();
}

class _TracksTabState extends ConsumerState<_TracksTab> {
  @override
  void initState() {
    super.initState();
    // Phase 34: Mutate provider after frame to avoid build-time write warnings
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ref.read(musicSearchProvider.notifier).state = widget.searchQuery;
      }
    });
  }

  @override
  void didUpdateWidget(_TracksTab old) {
    super.didUpdateWidget(old);
    if (old.searchQuery != widget.searchQuery) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(musicSearchProvider.notifier).state = widget.searchQuery;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final songsAsync = ref.watch(filteredSongsProvider);
    final playing = ref.watch(musicPlayingProvider);

    return Column(
      children: [
        // Search bar + Shuffle All + Sort
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 10),
                      const Icon(Icons.search,
                          size: 18,
                          color: AppColors.white50),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          // Phase 34: Real search input
                          onChanged: (v) {
                            ref
                                .read(musicSearchProvider.notifier)
                                .state = v;
                          },
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            isDense: true,
                            border: InputBorder.none,
                            hintText: AppStrings.of(context).searchSongs,
                            hintStyle: const TextStyle(
                              color: AppColors.white50,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // May shrink to half the row (the search box keeps the other
              // half): a long label in a large font cuts short rather than
              // pushing the sort button off the screen.
              Flexible(
                child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () {
                  final list = songsAsync.value ?? const [];
                  if (list.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(AppStrings.of(context).noSongsToShuffle)),
                    );
                    return;
                  }
                  // Phase 39 update: use playback-queue notifier so Next/Prev
                  // navigate through the full shuffled list, not just one
                  // song. Mirrors the same behaviour as Play All Shuffle in
                  // detail screens.
                  ref
                      .read(musicPlayingProvider.notifier)
                      .shufflePlayQueue(list);
                  Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
                    builder: (_) => const MusicPlayerScreen(),
                  ));
                },
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.shuffle,
                          size: 16,
                          color: AppColors.white70),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(AppStrings.of(context).shuffleAll,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.white70,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ),
              const SizedBox(width: 8),
              // Phase 45 (audit): Sort icon was just visual. Wire it
              // to the music sort sheet so it actually works.
              // A named 48 dp button (it was a nameless 30 dp InkWell); the
              // row's padding gave up the 18 dp it needs.
              IconButton(
                tooltip: AppStrings.of(context).sortBy,
                onPressed: () => _showMusicSortSheet(context, ref),
                icon: const Icon(Icons.sort,
                    color: AppColors.white70, size: 22),
              ),
            ],
          ),
        ),
        // Real song list
        Expanded(
          child: songsAsync.whenOrFallback(
            data: (songs) {
              if (songs.isEmpty) {
                return Center(
                  child: Text(AppStrings.of(context).noSongsFound,
                    style: const TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: songs.length,
                itemBuilder: (_, i) {
                  final s = songs[i];
                  final ps = playing.song;
                  final isPlaying = ps != null && ps.uri == s.uri;
                  return _TrackTile(
                    title: s.title,
                    artist: s.displayArtist,
                    isPlaying: isPlaying,
                    onTap: () => _playSong(context, ref, songs, i),
                    onMore: () => SongContextMenu.show(context, ref, s),
                  );
                },
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${AppStrings.of(context).errorReadingMusic}: $e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  static void _playSong(
      BuildContext context, WidgetRef ref, List<Song> songs, int index) {
    // Phase 39: hand the whole Tracks list to the player as the queue so
    // Next/Previous/Shuffle/Repeat work, starting at the tapped song.
    ref.read(musicPlayingProvider.notifier).playQueue(songs, startIndex: index);
    ref.read(musicPlaylistProvider.notifier).markPlayed(songs[index].uri);
    Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
      builder: (_) => const MusicPlayerScreen(),
    ));
  }
}

// ─── TRACK TILE ───
class _TrackTile extends StatelessWidget {
  final String title;
  final String artist;
  final bool isPlaying;
  final VoidCallback? onTap;
  final VoidCallback? onMore;

  const _TrackTile({
    required this.title,
    required this.artist,
    this.isPlaying = false,
    this.onTap,
    this.onMore,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap ?? () {},
      child: Container(
        color: isPlaying ? AppColors.white06 : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            // Thumbnail — light purple bg, music note OR audio bars if playing
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isPlaying
                    ? const Color(0xFF3A3F50)
                    : const Color(0xFFE8D5F0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                isPlaying ? Icons.graphic_eq : Icons.music_note,
                color: isPlaying
                    ? AppColors.primaryBlue
                    : const Color(0xFF9C5BC0),
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: isPlaying ? AppColors.primaryBlue : Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    artist,
                    style: TextStyle(
                      color: isPlaying
                          ? AppColors.primaryBlue.withOpacity(0.85)
                          : Colors.white54,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.of(context).moreOptions,
              icon: const Icon(Icons.more_vert,
                  color: Colors.white54, size: 20),
              onPressed: onMore,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── PLAYLISTS TAB ───
class _PlaylistsTab extends ConsumerStatefulWidget {
  const _PlaylistsTab();

  @override
  ConsumerState<_PlaylistsTab> createState() => _PlaylistsTabState();
}

class _PlaylistsTabState extends ConsumerState<_PlaylistsTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final playlists = ref
        .watch(musicPlaylistProvider)
        .where((p) =>
            _nameMatches(p.displayName(AppStrings.of(context)), _query))
        .toList();
    return Column(
      children: [
        // Search Playlists + New Playlist
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: _MusicSearchField(
                  hint: AppStrings.of(context).searchPlaylists,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              InkWell(
                onTap: () => _showNewPlaylistDialog(context, ref),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  height: 36,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.primaryBlue),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.playlist_add,
                          size: 16, color: AppColors.primaryBlue),
                      const SizedBox(width: 6),
                      Text(
                        AppStrings.of(context).newPlaylist,
                        style: const TextStyle(
                          color: AppColors.primaryBlue,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        // Real playlists
        Expanded(
          child: playlists.isEmpty && _query.isNotEmpty
              ? const _NoMatch()
              : ListView.builder(
            padding: const EdgeInsets.only(bottom: 80),
            itemCount: playlists.length,
            itemBuilder: (_, i) {
              final p = playlists[i];
              final isFavs = p.id == 'favs';
              final isRecent = p.id == 'recent';
              return _PlaylistTile(
                playlistId: p.id,
                icon: isFavs
                    ? Icons.favorite
                    : isRecent
                        ? Icons.access_time
                        : Icons.queue_music,
                iconColor: isFavs
                    ? const Color(0xFFE91E63)
                    : isRecent
                        ? const Color(0xFFFF9800)
                        : AppColors.primaryBlue,
                bgColor: isFavs
                    ? const Color(0xFFFCE4EC)
                    : isRecent
                        ? const Color(0xFFFFF3E0)
                        : const Color(0xFFE3F2FD),
                title: p.displayName(AppStrings.of(context)),
                subtitle:
                    AppStrings.of(context).songsCount(p.songUris.length),
              );
            },
          ),
        ),
      ],
    );
  }

  static void _showNewPlaylistDialog(BuildContext context, WidgetRef ref) {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.darkSurface,
          title: Text(AppStrings.of(ctx).newPlaylist,
              style: const TextStyle(color: Colors.white)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: AppStrings.of(ctx).playlistName,
              hintStyle: const TextStyle(color: AppColors.white40),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(AppStrings.of(ctx).cancel,
                  style: const TextStyle(color: Colors.white70)),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  Navigator.pop(ctx);
                  return;
                }
                ref.read(musicPlaylistProvider.notifier).createPlaylist(name);
                Navigator.pop(ctx);
              },
              child: Text(AppStrings.of(ctx).create,
                  style: const TextStyle(color: AppColors.primaryBlue)),
            ),
          ],
        );
      },
    );
  }
}

class _PlaylistTile extends StatelessWidget {
  final String playlistId;
  final IconData icon;
  final Color iconColor;
  final Color bgColor;
  final String title;
  final String subtitle;

  const _PlaylistTile({
    required this.playlistId,
    required this.icon,
    required this.iconColor,
    required this.bgColor,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlaylistDetailScreen(
            playlistId: playlistId,
            icon: icon,
            iconColor: iconColor,
            bgColor: bgColor,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── ALBUMS TAB ───
class _AlbumsTab extends ConsumerStatefulWidget {
  const _AlbumsTab();

  @override
  ConsumerState<_AlbumsTab> createState() => _AlbumsTabState();
}

class _AlbumsTabState extends ConsumerState<_AlbumsTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final albumsAsync = ref.watch(musicAlbumsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _MusicSearchField(
                  hint: AppStrings.of(context).searchAlbums,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
        ),
        Expanded(
          child: albumsAsync.whenOrFallback(
            data: (albums) {
              if (albums.isEmpty) {
                return Center(
                  child: Text(AppStrings.of(context).noAlbumsFound,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 14)),
                );
              }
              // Generate deterministic tint per album name
              const palette = <Color>[
                Color(0xFF536DFE),
                Color(0xFF7B5E48),
                Color(0xFFE6D5B8),
                Color(0xFFB8A4D4),
                Color(0xFF6B4226),
                Color(0xFF2C3E50),
                Color(0xFFE6C9A8),
              ];
              final shown = albums
                  .where((a) => _nameMatches(a.name, _query))
                  .toList();
              if (shown.isEmpty) return const _NoMatch();
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final a = shown[i];
                  final color = palette[a.name.hashCode.abs() % palette.length];
                  return _AlbumTile(
                    data: _AlbumData(a.name, a.songCount, color),
                  );
                },
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
              child: Text(AppStrings.of(context).errorLoadingAlbums,
                  style: const TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ],
    );
  }
}

class _AlbumData {
  final String name;
  final int songCount;
  final Color tintColor;
  const _AlbumData(this.name, this.songCount, this.tintColor);
}

class _AlbumTile extends ConsumerWidget {
  final _AlbumData data;
  const _AlbumTile({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => AlbumDetailScreen(
            name: data.name,
            tintColor: data.tintColor,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Album art placeholder — square with tint color
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: data.tintColor,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.album, color: Colors.white38, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                      // The scan files songs without an album under 'Unknown'.
                      data.name == 'Unknown'
                          ? AppStrings.of(context).mcUnknown
                          : data.name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    AppStrings.of(context).songsCount(data.songCount),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.of(context).moreOptions,
              icon: const Icon(Icons.more_vert,
                  color: Colors.white54, size: 20),
                onPressed: () => DetailHeaderActions.showOverflow(
                  context,
                  data.name,
                  onPlayAll: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsByAlbumProvider(data.name).future),
                    shuffle: false,
                  ),
                  onShuffle: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsByAlbumProvider(data.name).future),
                    shuffle: true,
                  ),
                ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── ARTISTS TAB ───
class _ArtistsTab extends ConsumerStatefulWidget {
  const _ArtistsTab();

  @override
  ConsumerState<_ArtistsTab> createState() => _ArtistsTabState();
}

class _ArtistsTabState extends ConsumerState<_ArtistsTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final artistsAsync = ref.watch(musicArtistsProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: _MusicSearchField(
                  hint: AppStrings.of(context).searchArtists,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
        ),
        Expanded(
          child: artistsAsync.when(
            data: (artists) {
              if (artists.isEmpty) {
                return Center(
                  child: Text(AppStrings.of(context).noArtistsFound,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 14)),
                );
              }
              final shown = artists
                  .where((a) => _nameMatches(a.name, _query))
                  .toList();
              if (shown.isEmpty) return const _NoMatch();
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: shown.length,
                itemBuilder: (_, i) => _ArtistTile(
                  name: shown[i].name,
                  songCount: shown[i].songCount,
                ),
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
              child: Text(AppStrings.of(context).errorLoadingArtists,
                  style: const TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ],
    );
  }
}

class _ArtistTile extends ConsumerWidget {
  final String name;
  final int songCount;
  const _ArtistTile({required this.name, this.songCount = 1});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final initial =
        name.isNotEmpty ? name[0].toUpperCase() : '?';
    return InkWell(
      onTap: () {
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ArtistDetailScreen(
            name: name,
            songCount: songCount,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // Circular avatar — light mint/teal with letter initial
            Container(
              width: 44,
              height: 44,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFD0EBE3),
              ),
              alignment: Alignment.center,
              child: Text(
                initial,
                style: const TextStyle(
                  color: Color(0xFF1B5E50),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                      name == 'Unknown' ? AppStrings.of(context).mcUnknown : name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 2),
                  // Phase 30: Use real songCount, not hardcoded "1 Song"
                  Text(
                    AppStrings.of(context).songsCount(songCount),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.of(context).moreOptions,
              icon: const Icon(Icons.more_vert,
                  color: Colors.white54, size: 20),
                onPressed: () => DetailHeaderActions.showOverflow(
                  context,
                  name,
                  onPlayAll: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsByArtistProvider(name).future),
                    shuffle: false,
                  ),
                  onShuffle: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsByArtistProvider(name).future),
                    shuffle: true,
                  ),
                ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── FOLDERS TAB ───
class _FoldersTab extends ConsumerStatefulWidget {
  const _FoldersTab();

  @override
  ConsumerState<_FoldersTab> createState() => _FoldersTabState();
}

class _FoldersTabState extends ConsumerState<_FoldersTab> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final foldersAsync = ref.watch(musicFoldersProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 2, 4, 2),
          child: Row(
            children: [
              Expanded(
                child: _MusicSearchField(
                  hint: AppStrings.of(context).searchFolders,
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
              const SizedBox(width: 8),
              // A named 48 dp button (it was a nameless 30 dp InkWell); the
              // row's padding gave up the 18 dp it needs.
              IconButton(
                tooltip: AppStrings.of(context).sortBy,
                onPressed: () => _showMusicSortSheet(context, ref),
                icon: const Icon(Icons.sort,
                    color: AppColors.white70, size: 22),
              ),
            ],
          ),
        ),
        Expanded(
          child: foldersAsync.when(
            data: (folders) {
              if (folders.isEmpty) {
                return Center(
                  child: Text(AppStrings.of(context).noMusicFoldersFound,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 14)),
                );
              }
              final shown = folders
                  .where((f) => _nameMatches(f.name, _query))
                  .toList();
              if (shown.isEmpty) return const _NoMatch();
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: shown.length,
                itemBuilder: (_, i) => _MusicFolderTile(
                  data: _FolderData(
                    shown[i].name,
                    shown[i].songCount,
                    shown[i].path,
                  ),
                ),
              );
            },
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (_, __) => Center(
              child: Text(AppStrings.of(context).errorLoadingFolders,
                  style: const TextStyle(color: Colors.white54)),
            ),
          ),
        ),
      ],
    );
  }
}

class _FolderData {
  final String name;
  final int songCount;
  final String path;
  const _FolderData(this.name, this.songCount, [this.path = '']);
}

class _MusicFolderTile extends ConsumerWidget {
  final _FolderData data;
  const _MusicFolderTile({required this.data});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: () {
        if (data.path.isEmpty) return;
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MusicFolderDetailScreen(
            name: data.name,
            path: data.path,
          ),
        ));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            // Folder icon — same dark slate as Local folders
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF3A4253),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Icon(Icons.folder,
                  color: Color(0xFF505968), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(data.name,
                      style:
                          const TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    AppStrings.of(context).songsCount(data.songCount),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.of(context).moreOptions,
              icon: const Icon(Icons.more_vert,
                  color: Colors.white54, size: 20),
                onPressed: () => DetailHeaderActions.showOverflow(
                  context,
                  data.name,
                  onPlayAll: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsInFolderProvider(data.path).future),
                    shuffle: false,
                  ),
                  onShuffle: () => _playCollectionFromFuture(
                    context,
                    ref,
                    ref.read(songsInFolderProvider(data.path).future),
                    shuffle: true,
                  ),
                ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── MINI PLAYER BAR ───
class _MiniPlayerBar extends ConsumerWidget {
  const _MiniPlayerBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playing = ref.watch(musicPlayingProvider);
    // Phase 32: Hide bar entirely when nothing's playing (MX parity).
    if (playing.song == null) return const SizedBox.shrink();
    final song = playing.song!;
    return InkWell(
      onTap: () {
        Navigator.of(context, rootNavigator: true)
                        .push(MaterialPageRoute(
          builder: (_) => const MusicPlayerScreen(),
        ));
      },
      child: Container(
        height: 56,
        decoration: const BoxDecoration(
          color: AppColors.darkSurface,
          border: Border(
            top: BorderSide(color: AppColors.white06),
          ),
        ),
        child: Row(
          children: [
            const SizedBox(width: 12),
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: const Color(0xFFE8D5F0),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Icon(Icons.music_note,
                  color: Color(0xFF9C5BC0), size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    song.displayArtist,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.45),
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: AppStrings.of(context).plPause,
              icon: Icon(
                playing.isPlaying
                    ? Icons.pause_circle_outline
                    : Icons.play_circle_outline,
                color: Colors.white,
                size: 30,
              ),
              onPressed: () {
                ref.read(musicPlayingProvider.notifier).togglePlay();
              },
            ),
            IconButton(
              tooltip: AppStrings.of(context).mpShowQueue,
              icon: const Icon(Icons.playlist_play,
                  color: Colors.white, size: 26),
              onPressed: () => MusicQueueSheet.show(context),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

/// Phase 39: fetch a collection's songs (async via a family provider) and start
/// playback. Shared by the Album/Artist/Folder browse-card overflow menus so
/// their "Play All" / "Shuffle Play" rows are functional, not just toasts.
Future<void> _playCollectionFromFuture(
  BuildContext context,
  WidgetRef ref,
  Future<List<Song>> future, {
  required bool shuffle,
}) async {
  final List<Song> songs;
  try {
    songs = await future;
  } catch (_) {
    return;
  }
  if (songs.isEmpty || !context.mounted) return;
  final notifier = ref.read(musicPlayingProvider.notifier);
  if (shuffle) {
    notifier.shufflePlayQueue(songs);
  } else {
    notifier.playQueue(songs, startIndex: 0);
  }
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute(builder: (_) => const MusicPlayerScreen()),
  );
}

/// Phase 45 (audit): show the music sort bottom-sheet. Mirrors the
/// MX Player V3 sort options for the music tab (Title / Album /
/// Artist / Date added / Duration / Size / Path) plus an Ascending /
/// Descending toggle. Tapping a row selects that field and dismisses;
/// tapping the same field flips direction.
Future<void> _showMusicSortSheet(BuildContext context, WidgetRef ref) async {
  await showAppModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.darkSurface,
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (sheetCtx) {
      return Consumer(builder: (innerCtx, innerRef, _) {
        final sort = innerRef.watch(musicSortProvider);
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Text(AppStrings.of(context).sortBy,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              ...MusicSortBy.values.map((opt) {
                final selected = sort.by == opt;
                return InkWell(
                  onTap: () {
                    if (selected) {
                      innerRef.read(musicSortProvider.notifier).state =
                          sort.copyWith(ascending: !sort.ascending);
                    } else {
                      innerRef.read(musicSortProvider.notifier).state =
                          sort.copyWith(by: opt);
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 14),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            opt.labelIn(AppStrings.of(context)),
                            style: TextStyle(
                              color: selected
                                  ? AppColors.accentBlue
                                  : Colors.white,
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(
                            sort.ascending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            color: AppColors.accentBlue,
                            size: 18,
                          ),
                      ],
                    ),
                  ),
                );
              }),
              const SizedBox(height: 4),
            ],
          ),
        );
      });
    },
  );
}

/// Whether [name] holds what was typed, ignoring case.
bool _nameMatches(String name, String query) =>
    query.isEmpty || name.toLowerCase().contains(query.toLowerCase());

/// The search box at the top of the Albums, Artists, Playlists and Folders
/// tabs. It used to be a picture of one — the words "Search…" in a grey box
/// that did nothing when tapped; now it filters the tab by name as you type,
/// as the Songs tab's always did.
class _MusicSearchField extends StatelessWidget {
  const _MusicSearchField({required this.hint, required this.onChanged});
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: AppColors.darkSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          const Icon(Icons.search, size: 18, color: AppColors.white50),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: hint,
                hintStyle: const TextStyle(
                  color: AppColors.white50,
                  fontSize: 13,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What a tab shows when nothing in it matches the search.
class _NoMatch extends StatelessWidget {
  const _NoMatch();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(AppStrings.of(context).searchNoMatches,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 14)),
      ),
    );
  }
}
