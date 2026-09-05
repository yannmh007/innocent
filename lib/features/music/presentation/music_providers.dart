import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path/path.dart' as p;

import '../data/music_audio_service.dart';
import '../data/music_local_datasource.dart';
import '../domain/song.dart';
import '../../../core/di/core_providers.dart';
import '../../../core/services/video_player/media_kit_player_service.dart';
import '../../../core/services/cache/music_cache.dart';
import '../../../core/services/audio_focus/audio_focus_service.dart';
import '../../../core/services/haptic/haptic_service.dart';
import '../../../core/services/music_background/music_audio_handler.dart';

/// Phase 32: Music data providers backed by real device audio scan.

final musicDataSourceProvider = Provider<MusicLocalDataSource>((ref) {
  return MusicLocalDataSource();
});

/// Phase 32: Audio playback service (singleton).
/// Audit fix (background music): overridden by main.dart with the
/// shared instance so AudioService handler + notifier share player.
final musicAudioServiceProvider = Provider<MusicAudioService>((ref) {
  final svc = MusicAudioService();
  ref.onDispose(() => svc.dispose());
  return svc;
});

/// Audit fix (background music): audio_service handler. Overridden
/// by main.dart with the instance returned from AudioService.init().
/// Null if init failed (web preview); notifier checks for null.
final musicAudioHandlerProvider =
    Provider<MusicAudioHandler?>((ref) => null);

/// Disk cache for the scanned music library — gives an instant Music tab on
/// every launch, not just the first scan of the session.
final musicCacheProvider = Provider<MusicCache>((ref) {
  return MusicCache();
});

/// All songs. Cache-first (mirrors `foldersProvider`): returns the cached
/// snapshot immediately, then refreshes from a fresh device scan in the
/// background and reconciles any change. The heavy metadata work runs inside
/// a `compute` isolate in [MusicLocalDataSource], so the refresh stays off
/// the UI thread.
final allSongsProvider = FutureProvider<List<Song>>((ref) async {
  final ds = ref.watch(musicDataSourceProvider);
  final cache = ref.watch(musicCacheProvider);

  // Try the disk cache first for an instant load.
  final cached = await cache.loadSongs();
  if (cached != null && cached.isNotEmpty) {
    // Refresh in the background; keep showing the cached list meanwhile.
    // ignore: discarded_futures
    () async {
      try {
        final fresh = await ds.getAllSongs();
        await cache.saveSongs(fresh);
        // Only nudge consumers if the library actually changed.
        if (_hasSongDiff(cached, fresh)) {
          ref.invalidateSelf();
        }
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('allSongsProvider background refresh failed: $e\n$st');
        }
      }
    }();
    return cached;
  }

  // No cache → fetch fresh, then save for next launch.
  final fresh = await ds.getAllSongs();
  await cache.saveSongs(fresh);
  return fresh;
});

bool _hasSongDiff(List<Song> a, List<Song> b) {
  if (a.length != b.length) return true;
  final aIds = a.map((s) => s.id).toSet();
  final bIds = b.map((s) => s.id).toSet();
  return aIds.length != bIds.length || !aIds.containsAll(bIds);
}

/// Audit fix (album art): lazy art loader keyed by URI. Returns null
/// for songs with no embedded picture or unreadable metadata.
final albumArtProvider =
    FutureProvider.family<List<int>?, String>((ref, uri) async {
  final ds = ref.watch(musicDataSourceProvider);
  return ds.loadAlbumArt(uri);
});

// The grouping/filtering providers below all derive from the single
// cached library scan (allSongsProvider). Previously each one called the
// datasource directly, which re-fetched every audio asset AND re-ran the
// ID3 batch over the whole library — so opening the Albums tab, the
// Artists tab, then drilling into an album each triggered a full rescan
// (5-7 scans for ordinary navigation on a large library). Deriving in
// memory means the library is scanned once; this also keeps every tab
// consistent with allSongsProvider (they used to bypass its cache and
// could show a different snapshot).

final musicFoldersProvider = FutureProvider<List<MusicFolder>>((ref) async {
  final songs = await ref.watch(allSongsProvider.future);
  final map = <String, int>{};
  for (final s in songs) {
    map[s.folderPath] = (map[s.folderPath] ?? 0) + 1;
  }
  final folders = map.entries
      .map((e) => MusicFolder(
            path: e.key,
            name: p.basename(e.key).isEmpty ? e.key : p.basename(e.key),
            songCount: e.value,
          ))
      .toList();
  folders.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return folders;
});

final musicAlbumsProvider = FutureProvider<List<MusicAlbum>>((ref) async {
  final songs = await ref.watch(allSongsProvider.future);
  final map = <String, int>{};
  for (final s in songs) {
    final key = s.album.isEmpty ? 'Unknown' : s.album;
    map[key] = (map[key] ?? 0) + 1;
  }
  final albums = map.entries
      .map((e) => MusicAlbum(name: e.key, songCount: e.value))
      .toList();
  albums.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return albums;
});

final musicArtistsProvider = FutureProvider<List<MusicArtist>>((ref) async {
  final songs = await ref.watch(allSongsProvider.future);
  final map = <String, int>{};
  for (final s in songs) {
    final key = s.artist.isEmpty ? 'Unknown' : s.artist;
    map[key] = (map[key] ?? 0) + 1;
  }
  final artists = map.entries
      .map((e) => MusicArtist(name: e.key, songCount: e.value))
      .toList();
  artists.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return artists;
});

final songsByArtistProvider =
    FutureProvider.family<List<Song>, String>((ref, artist) async {
  final songs = await ref.watch(allSongsProvider.future);
  return songs
      .where((s) => (s.artist.isEmpty ? 'Unknown' : s.artist) == artist)
      .toList();
});

final songsByAlbumProvider =
    FutureProvider.family<List<Song>, String>((ref, album) async {
  final songs = await ref.watch(allSongsProvider.future);
  return songs
      .where((s) => (s.album.isEmpty ? 'Unknown' : s.album) == album)
      .toList();
});

final songsInFolderProvider =
    FutureProvider.family<List<Song>, String>((ref, folder) async {
  final songs = await ref.watch(allSongsProvider.future);
  return songs.where((s) => s.folderPath == folder).toList();
});

/// Music search query
final musicSearchProvider = StateProvider<String>((ref) => '');

/// Phase 45 (audit): music sort options to match MX Player V3's music
/// sort menu. MX Player offers: Title, Album, Artist, Date Added,
/// Duration, Length, Path. We mirror that set so users have parity.
enum MusicSortBy {
  title('Title'),
  album('Album'),
  artist('Artist'),
  dateAdded('Date added'),
  duration('Duration'),
  size('Size'),
  path('Path');

  final String label;
  const MusicSortBy(this.label);
}

/// Phase 45 (audit): current music sort selection. Defaults to Title +
/// ascending, the MX Player V3 default.
class MusicSortState {
  final MusicSortBy by;
  final bool ascending;
  const MusicSortState({this.by = MusicSortBy.title, this.ascending = true});

  MusicSortState copyWith({MusicSortBy? by, bool? ascending}) =>
      MusicSortState(
        by: by ?? this.by,
        ascending: ascending ?? this.ascending,
      );
}

final musicSortProvider =
    StateProvider<MusicSortState>((ref) => const MusicSortState());

/// Filtered + sorted songs (Tracks tab search). Phase 45 (audit) adds
/// the [musicSortProvider] dimension so the Sort icon in the music tab
/// actually does something.
final filteredSongsProvider = Provider<AsyncValue<List<Song>>>((ref) {
  final async = ref.watch(allSongsProvider);
  final q = ref.watch(musicSearchProvider).trim().toLowerCase();
  final sort = ref.watch(musicSortProvider);
  return async.whenData((songs) {
    Iterable<Song> result = songs;
    if (q.isNotEmpty) {
      result = result.where((s) =>
          s.title.toLowerCase().contains(q) ||
          s.artist.toLowerCase().contains(q) ||
          s.album.toLowerCase().contains(q));
    }
    final list = result.toList();
    int cmp(Song a, Song b) {
      int c;
      switch (sort.by) {
        case MusicSortBy.title:
          c = a.title.toLowerCase().compareTo(b.title.toLowerCase());
          break;
        case MusicSortBy.album:
          c = a.album.toLowerCase().compareTo(b.album.toLowerCase());
          break;
        case MusicSortBy.artist:
          c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
          break;
        case MusicSortBy.dateAdded:
          final ad = a.dateAdded?.millisecondsSinceEpoch ?? 0;
          final bd = b.dateAdded?.millisecondsSinceEpoch ?? 0;
          c = ad.compareTo(bd);
          break;
        case MusicSortBy.duration:
          c = a.duration.compareTo(b.duration);
          break;
        case MusicSortBy.size:
          c = a.sizeBytes.compareTo(b.sizeBytes);
          break;
        case MusicSortBy.path:
          c = a.uri.toLowerCase().compareTo(b.uri.toLowerCase());
          break;
      }
      return sort.ascending ? c : -c;
    }
    list.sort(cmp);
    return list;
  });
});

/// Phase 32: Music playlists (user-created + built-in My Favourites, Recently Played).
/// Persisted to SharedPreferences as JSON.
class MusicPlaylist {
  final String id; // 'favs', 'recent', or user-generated uuid
  final String name;
  final List<String> songUris;
  final bool builtIn;

  const MusicPlaylist({
    required this.id,
    required this.name,
    required this.songUris,
    this.builtIn = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'songUris': songUris,
        'builtIn': builtIn,
      };

  factory MusicPlaylist.fromJson(Map<String, dynamic> j) => MusicPlaylist(
        id: j['id'] as String,
        name: j['name'] as String,
        songUris: List<String>.from(j['songUris'] as List? ?? const []),
        builtIn: j['builtIn'] as bool? ?? false,
      );

  MusicPlaylist copyWith({String? name, List<String>? songUris}) =>
      MusicPlaylist(
        id: id,
        name: name ?? this.name,
        songUris: songUris ?? this.songUris,
        builtIn: builtIn,
      );
}

class MusicPlaylistNotifier extends StateNotifier<List<MusicPlaylist>> {
  static const _kKey = 'music_playlists_v1';
  static const _maxRecent = 50;

  MusicPlaylistNotifier() : super(const []) {
    _load();
  }

  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_kKey);
    if (raw == null || raw.isEmpty) {
      // Seed built-ins
      state = const [
        MusicPlaylist(
            id: 'favs',
            name: 'My Favourites',
            songUris: [],
            builtIn: true),
        MusicPlaylist(
            id: 'recent',
            name: 'Recently Played',
            songUris: [],
            builtIn: true),
      ];
      return;
    }
    try {
      final list = raw.map((s) {
        final parts = s.split('|||');
        return MusicPlaylist(
          id: parts[0],
          name: parts[1],
          songUris: parts[2].split('@@').where((u) => u.isNotEmpty).toList(),
          builtIn: parts.length > 3 && parts[3] == '1',
        );
      }).toList();
      // Ensure built-ins exist
      if (!list.any((p) => p.id == 'favs')) {
        list.add(const MusicPlaylist(
            id: 'favs',
            name: 'My Favourites',
            songUris: [],
            builtIn: true));
      }
      if (!list.any((p) => p.id == 'recent')) {
        list.add(const MusicPlaylist(
            id: 'recent',
            name: 'Recently Played',
            songUris: [],
            builtIn: true));
      }
      state = list;
    } catch (_) {
      state = const [];
    }
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    final encoded = state
        .map((p) =>
            '${p.id}|||${p.name}|||${p.songUris.join("@@")}|||${p.builtIn ? "1" : "0"}')
        .toList();
    await sp.setStringList(_kKey, encoded);
  }

  Future<void> createPlaylist(String name) async {
    final id = 'pl_${DateTime.now().millisecondsSinceEpoch}';
    state = [
      ...state,
      MusicPlaylist(id: id, name: name, songUris: const []),
    ];
    await _persist();
  }

  Future<void> deletePlaylist(String id) async {
    state = state.where((p) => p.id != id || p.builtIn).toList();
    await _persist();
  }

  Future<void> addSongToPlaylist(String playlistId, String songUri) async {
    state = state.map((p) {
      if (p.id != playlistId) return p;
      if (p.songUris.contains(songUri)) return p;
      return p.copyWith(songUris: [...p.songUris, songUri]);
    }).toList();
    await _persist();
  }

  Future<void> toggleFavourite(String songUri) async {
    state = state.map((p) {
      if (p.id != 'favs') return p;
      final list = [...p.songUris];
      if (list.contains(songUri)) {
        list.remove(songUri);
      } else {
        list.add(songUri);
      }
      return p.copyWith(songUris: list);
    }).toList();
    await _persist();
  }

  /// Append song to Recently Played (most-recent first, capped).
  Future<void> markPlayed(String songUri) async {
    state = state.map((p) {
      if (p.id != 'recent') return p;
      final list = [...p.songUris];
      list.remove(songUri);
      list.insert(0, songUri);
      if (list.length > _maxRecent) list.removeRange(_maxRecent, list.length);
      return p.copyWith(songUris: list);
    }).toList();
    await _persist();
  }

  bool isFavourite(String songUri) {
    final favs = state.firstWhere(
      (p) => p.id == 'favs',
      orElse: () => const MusicPlaylist(
          id: 'favs', name: 'My Favourites', songUris: [], builtIn: true),
    );
    return favs.songUris.contains(songUri);
  }
}

final musicPlaylistProvider =
    StateNotifierProvider<MusicPlaylistNotifier, List<MusicPlaylist>>((ref) {
  return MusicPlaylistNotifier();
});

/// Phase 38: repeat modes for the music player.
enum MusicRepeatMode { off, all, one }

/// Phase 32: Currently-playing music state (mini player bar uses this).
/// Phase 38: Added playbackSpeed + A-B repeat points.
/// Phase 39: Added a real playback QUEUE (Next/Previous/Shuffle/Repeat now work).
class MusicPlayingState {
  final Song? song;
  final bool isPlaying;
  final Duration position;
  final Duration duration;
  final double playbackSpeed;
  final Duration? abPointA;
  final Duration? abPointB;

  /// The ordered list of songs currently queued for playback.
  final List<Song> queue;

  /// Index of [song] within [queue]. -1 when there is no queue.
  final int currentIndex;

  final bool isShuffled;
  final MusicRepeatMode repeatMode;

  /// Phase 39: remaining sleep-timer duration, or null when inactive.
  final Duration? sleepRemaining;

  /// Audit fix (M3): surfaced playback error, or null when no error
  /// is active. The music player UI watches this and shows a brief
  /// banner so failures aren't swallowed silently.
  final String? errorMessage;

  const MusicPlayingState({
    this.song,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.playbackSpeed = 1.0,
    this.abPointA,
    this.abPointB,
    this.queue = const [],
    this.currentIndex = -1,
    this.isShuffled = false,
    this.repeatMode = MusicRepeatMode.off,
    this.sleepRemaining,
    this.errorMessage,
  });

  /// True once both A and B points are set — playback loops between them.
  bool get isAbActive => abPointA != null && abPointB != null;

  /// True while waiting for the user to set the B point.
  bool get isAbArmed => abPointA != null && abPointB == null;

  bool get hasQueue => queue.isNotEmpty;

  MusicPlayingState copyWith({
    Song? song,
    bool? isPlaying,
    Duration? position,
    Duration? duration,
    double? playbackSpeed,
    Duration? abPointA,
    Duration? abPointB,
    bool clearAb = false,
    List<Song>? queue,
    int? currentIndex,
    bool? isShuffled,
    MusicRepeatMode? repeatMode,
    Duration? sleepRemaining,
    bool clearSleep = false,
    String? errorMessage,
    bool clearError = false,
  }) =>
      MusicPlayingState(
        song: song ?? this.song,
        isPlaying: isPlaying ?? this.isPlaying,
        position: position ?? this.position,
        duration: duration ?? this.duration,
        playbackSpeed: playbackSpeed ?? this.playbackSpeed,
        abPointA: clearAb ? null : (abPointA ?? this.abPointA),
        abPointB: clearAb ? null : (abPointB ?? this.abPointB),
        queue: queue ?? this.queue,
        currentIndex: currentIndex ?? this.currentIndex,
        isShuffled: isShuffled ?? this.isShuffled,
        repeatMode: repeatMode ?? this.repeatMode,
        sleepRemaining:
            clearSleep ? null : (sleepRemaining ?? this.sleepRemaining),
        errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      );
}

class MusicPlayingNotifier extends StateNotifier<MusicPlayingState> {
  final MusicAudioService _audio;
  // Phase 43: keep a Ref so we can stop the video player when music starts
  // (and vice-versa in player_provider). MX Player V3 routes audio focus
  // between the two surfaces so they never play simultaneously.
  final Ref _ref;
  late final StreamSubscription<Duration> _posSub;
  late final StreamSubscription<bool> _playSub;
  late final StreamSubscription<Duration> _durSub;
  late final StreamSubscription<bool> _completedSub;
  /// Audit fix (M3): listen for music playback errors and surface
  /// them via [MusicPlayingState.errorMessage].
  StreamSubscription<String>? _errorSub;

  final _rng = Random();

  /// Shuffle play order — a permutation of queue indices. Phase 39.
  /// We walk this list when [isShuffled] is true so every song plays once
  /// before any repeats (MX/standard shuffle behaviour), rather than picking
  /// a fresh random song each time (which can repeat immediately).
  List<int> _shuffleOrder = const [];

  /// Our position within [_shuffleOrder].
  int _shufflePos = 0;

  /// Phase 39: sleep-timer ticker.
  Timer? _sleepTicker;

  /// Wall-clock moment the music sleep timer should fire. Kept on the notifier
  /// rather than in the state object because nothing draws it — the countdown
  /// the UI shows is [MusicPlayingState.sleepRemaining].
  DateTime? _sleepDeadline;

  /// Debounce for the A-B repeat jump.
  DateTime _lastAbJumpAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Phase 45: audio focus event subscription. The music plays in the
  /// background most of the time, so phone calls / other media apps
  /// need to pause it cleanly. Cancelled in dispose.
  StreamSubscription<AudioFocusEvent>? _focusSub;

  /// Phase 45: track whether music paused due to an audio-focus loss
  /// so we know whether to auto-resume on focus regain.
  bool _pausedByFocusLoss = false;

  /// Audit fix (real gap: position never persisted): throttle the
  /// ResumeStorage write to once every 5 s. Without this we'd write
  /// on every position tick (~10 Hz).
  int _lastSaveMs = 0;

  /// Phase 45: track whether we've already claimed audio focus. We
  /// only claim it once playback actually starts, and release when
  /// the user explicitly stops or the notifier disposes.
  bool _hasFocusClaim = false;

  MusicPlayingNotifier(this._audio, this._ref) : super(const MusicPlayingState()) {
    // Phase 45: subscribe to audio focus events. We don't claim focus
    // here — only when the user starts playback. The PlayerController
    // and us share the broadcast stream so both can react.
    final focusSvc = _ref.read(audioFocusServiceProvider);
    _focusSub = focusSvc.events.listen(_handleAudioFocusEvent);

    _posSub = _audio.positionStream.listen((p) {
      if (!mounted) return;
      // Phase 38: A-B repeat — when playback passes point B, loop to A.
      final a = state.abPointA;
      final b = state.abPointB;
      if (a != null && b != null && p >= b) {
        // BATTERY/CORRECTNESS FIX — libmpv keeps reporting positions past B
        // for a moment after a seek is queued, and the old code fired a fresh
        // seek on every one of them: a burst of seeks (and of demuxer work)
        // each time the loop came round. One jump per lap.
        final nowAb = DateTime.now();
        if (nowAb.difference(_lastAbJumpAt) >
            const Duration(milliseconds: 700)) {
          _lastAbJumpAt = nowAb;
          _audio.seek(a);
          state = state.copyWith(position: a);
        }
        return;
      }
      // BATTERY FIX — this used to write a brand-new state object on every
      // position report from libmpv, which is roughly ten to twenty times a
      // second, and every widget watching the music state rebuilt with it.
      // Background music with the screen off is the longest-running thing this
      // app does, so that churn ran for hours to move a progress bar nobody
      // was looking at. Quarter-second granularity keeps the bar and the lyric
      // highlight looking live while cutting the work by four to eight times.
      const posGranularityMs = 250;
      if ((p.inMilliseconds ~/ posGranularityMs) ==
          (state.position.inMilliseconds ~/ posGranularityMs)) {
        return;
      }
      state = state.copyWith(position: p);
      // Audit fix (real gap: position never persisted): write to
      // ResumeStorage every 5 s while playing so user can pick up
      // exactly where they left off.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastSaveMs >= 5000) {
        _lastSaveMs = now;
        final s = state.song;
        if (s != null) {
          _ref.read(resumeStorageProvider).savePosition(
                uri: s.uri,
                position: p,
                duration: state.duration,
              );
        }
      }
    });
    _playSub = _audio.playingStream.listen((playing) {
      if (mounted) state = state.copyWith(isPlaying: playing);
      _updateMusicWidget(playing: playing);
    });
    _durSub = _audio.durationStream.listen((d) {
      if (mounted && d > Duration.zero) state = state.copyWith(duration: d);
    });
    _completedSub = _audio.completedStream.listen((c) {
      if (!mounted || !c) return;
      // Audit fix: clear saved position when song completes cleanly.
      final s = state.song;
      if (s != null) {
        _ref.read(resumeStorageProvider).clearPosition(s.uri);
      }
      _onTrackCompleted();
    });
    // Audit fix (M3): wire the music error stream. Errors surface
    // in the UI via state.errorMessage; we don't auto-retry music
    // playback because most failures are "codec not supported"
    // which retries won't fix.
    _errorSub = _audio.errorStream.listen((e) {
      if (!mounted) return;
      state = state.copyWith(errorMessage: e);
    });

    // Audit fix (background music): wire AudioService handler's OS
    // control callbacks. When user taps Play/Pause/Next on lock
    // screen or sends Bluetooth headset prev/next, those events
    // arrive on handler and we delegate to notifier methods.
    final handler = _ref.read(musicAudioHandlerProvider);
    if (handler != null) {
      handler.onPlayPressed = () {
        if (!state.isPlaying) togglePlay();
      };
      handler.onPausePressed = () {
        if (state.isPlaying) togglePlay();
      };
      handler.onSkipNextPressed = () => next();
      handler.onSkipPreviousPressed = () => previous();
      handler.onSeekRequested = (pos) => setPosition(pos);
      handler.onStopPressed = () => stop();
    }
  }

  /// Audit fix (background music): push current song metadata to OS
  /// notification + lock screen. Fires on each track change.
  Future<void> _publishNowPlaying(Song s) async {
    final handler = _ref.read(musicAudioHandlerProvider);
    if (handler == null) return;
    await handler.setNowPlaying(
      id: s.uri,
      title: s.title,
      artist: s.displayArtist,
      album: s.album,
      duration: s.duration,
      artBytes: null,
    );
    // Then load art async and update notification when ready.
    // Only update if user is still on this song.
    try {
      final ds = _ref.read(musicDataSourceProvider);
      final bytes = await ds.loadAlbumArt(s.uri);
      if (bytes == null || bytes.isEmpty) return;
      if (!mounted || state.song?.uri != s.uri) return;
      await handler.setNowPlaying(
        id: s.uri,
        title: s.title,
        artist: s.displayArtist,
        album: s.album,
        duration: s.duration,
        artBytes: Uint8List.fromList(bytes),
      );
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
  }

  // ─── Queue control (Phase 39) ───

  /// Play a list of songs starting at [startIndex]. This becomes the new queue,
  /// so Next/Previous/auto-advance navigate through [songs].
  Future<void> playQueue(List<Song> songs, {int startIndex = 0}) async {
    if (songs.isEmpty) return;
    final idx = startIndex.clamp(0, songs.length - 1);
    state = state.copyWith(queue: List<Song>.unmodifiable(songs), currentIndex: idx);
    if (state.isShuffled) _buildShuffleOrder(startAt: idx);
    await _playAt(idx);
  }

  /// Backwards-compatible single-song play. Builds a 1-item queue.
  Future<void> setSong(Song s) async {
    await playQueue([s], startIndex: 0);
  }

  /// Phase 39: shuffle a whole collection — turns shuffle on and starts from a
  /// random song. Used by "Shuffle Play" in detail/overflow menus.
  Future<void> shufflePlayQueue(List<Song> songs) async {
    if (songs.isEmpty) return;
    final start = _rng.nextInt(songs.length);
    state = state.copyWith(
      queue: List<Song>.unmodifiable(songs),
      currentIndex: start,
      isShuffled: true,
    );
    _buildShuffleOrder(startAt: start);
    await _playAt(start);
  }

  /// Open & play the song at [index] in the current queue.
  Future<void> _playAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final s = state.queue[index];
    // Phase 43: MX Player V3 parity — never let music and video play at the
    // same time. Pause the video player first if it's running.
    //
    // Performance: only touch the video player when it actually exists.
    // Reading videoPlayerServiceProvider *creates and initializes* the
    // whole libmpv video stack (Player + VideoController + hwdec), so a
    // music-only session would otherwise pay that cost on the first song
    // just to pause nothing. The static flag is a free check, and the
    // pause is fire-and-forget so audio open() never waits on it.
    if (MediaKitPlayerService.anyInitialized) {
      try {
        // ignore: discarded_futures
        _ref.read(videoPlayerServiceProvider).pause();
      } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
    }
    state = state.copyWith(
      song: s,
      currentIndex: index,
      duration: s.duration,
      position: Duration.zero,
      isPlaying: true,
      clearAb: true,
      // Audit fix (M3): clear any stale error from the previous
      // failed track when a new one starts. Otherwise an error
      // banner from the previous song would linger.
      clearError: true,
    );
    // Audit fix (background music): refresh lock-screen notification.
    // ignore: discarded_futures
    _publishNowPlaying(s);
    _updateMusicWidget(title: s.title, artist: s.displayArtist, playing: true);
    try {
      // Phase 45: claim audio focus so phone calls / other media apps
      // pause us cleanly. Idempotent across multiple play calls.
      await _claimAudioFocus();
      await _audio.open(s.uri);
      // Audit fix (real gap: music never resumed): check if user had
      // previously stopped this song mid-listen, seek there. Uses the
      // SAME ResumeStorage that video uses. ≥30 s in, ≤95 % through
      // gates the save (handled by ResumeStorage internally).
      try {
        final saved = await _ref
            .read(resumeStorageProvider)
            .getPosition(s.uri);
        if (saved != null && mounted && state.song?.uri == s.uri) {
          await _audio.seek(saved);
          state = state.copyWith(position: saved);
        }
      } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
      await _audio.play();
      // Phase 38: re-apply playback speed for the newly opened media.
      if (state.playbackSpeed != 1.0) {
        await _audio.setRate(state.playbackSpeed);
      }
    } catch (_) {
      // Some audio files may not be supported by libmpv; UI still reflects "selected"
    }
  }

  /// Jump directly to a queue entry (used by the Playing Queue sheet).
  Future<void> jumpTo(int index) async {
    if (state.isShuffled) {
      // Re-anchor the shuffle walk on the chosen song.
      _buildShuffleOrder(startAt: index);
    }
    await _playAt(index);
  }

  /// Phase 39: insert [s] right after the current song. If the queue is empty,
  /// start playing [s]. Keeps the shuffle order consistent.
  Future<void> playNext(Song s) async {
    await _insertSong(s, asNext: true);
  }

  /// Phase 39: append [s] to the end of the queue. If empty, play it.
  Future<void> playLater(Song s) async {
    await _insertSong(s, asNext: false);
  }

  Future<void> _insertSong(Song s, {required bool asNext}) async {
    if (state.queue.isEmpty) {
      await playQueue([s], startIndex: 0);
      return;
    }
    final q = List<Song>.from(state.queue);
    final insertAt = asNext ? state.currentIndex + 1 : q.length;
    q.insert(insertAt, s);
    // currentIndex is unaffected because insertAt is always > currentIndex here.
    if (state.isShuffled && _shuffleOrder.isNotEmpty) {
      final newOrder =
          _shuffleOrder.map((idx) => idx >= insertAt ? idx + 1 : idx).toList();
      if (asNext) {
        newOrder.insert(_shufflePos + 1, insertAt);
      } else {
        newOrder.add(insertAt);
      }
      _shuffleOrder = newOrder;
    }
    state = state.copyWith(queue: List<Song>.unmodifiable(q));
  }

  /// Advance to the next track honouring shuffle + repeat. Phase 39.
  Future<void> next({bool isAuto = false}) async {
    if (!state.hasQueue) return;

    // Repeat-one only auto-replays; an explicit Next still moves on.
    if (isAuto && state.repeatMode == MusicRepeatMode.one) {
      await _audio.seek(Duration.zero);
      await _audio.play();
      return;
    }

    final nextIndex = _computeNextIndex();
    if (nextIndex == null) {
      // End of queue with repeat off — stop at the last song's end.
      await _audio.pause();
      state = state.copyWith(isPlaying: false, position: state.duration);
      return;
    }
    await _playAt(nextIndex);
  }

  /// Go to previous track. MX behaviour: if we're >3s into the song, restart it;
  /// otherwise move to the previous queue entry. Phase 39.
  Future<void> previous() async {
    if (!state.hasQueue) return;
    if (state.position.inSeconds > 3) {
      await _audio.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
      return;
    }
    final prevIndex = _computePrevIndex();
    if (prevIndex == null) {
      await _audio.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
      return;
    }
    await _playAt(prevIndex);
  }

  void _onTrackCompleted() {
    if (!state.hasQueue) {
      state = state.copyWith(position: Duration.zero, isPlaying: false);
      return;
    }
    if (state.repeatMode == MusicRepeatMode.one) {
      _audio.seek(Duration.zero);
      _audio.play();
      return;
    }
    next(isAuto: true);
  }

  int? _computeNextIndex() {
    final n = state.queue.length;
    if (n == 0) return null;
    if (state.isShuffled) {
      if (_shuffleOrder.length != n) _buildShuffleOrder(startAt: state.currentIndex);
      if (_shufflePos < _shuffleOrder.length - 1) {
        _shufflePos++;
        return _shuffleOrder[_shufflePos];
      }
      // Reached end of shuffle order.
      if (state.repeatMode == MusicRepeatMode.all) {
        _buildShuffleOrder(startAt: -1); // fresh permutation
        _shufflePos = 0;
        return _shuffleOrder[0];
      }
      return null;
    }
    // Sequential
    if (state.currentIndex < n - 1) return state.currentIndex + 1;
    if (state.repeatMode == MusicRepeatMode.all) return 0;
    return null;
  }

  int? _computePrevIndex() {
    final n = state.queue.length;
    if (n == 0) return null;
    if (state.isShuffled) {
      if (_shuffleOrder.length != n) _buildShuffleOrder(startAt: state.currentIndex);
      if (_shufflePos > 0) {
        _shufflePos--;
        return _shuffleOrder[_shufflePos];
      }
      if (state.repeatMode == MusicRepeatMode.all) {
        _shufflePos = _shuffleOrder.length - 1;
        return _shuffleOrder[_shufflePos];
      }
      return null;
    }
    if (state.currentIndex > 0) return state.currentIndex - 1;
    if (state.repeatMode == MusicRepeatMode.all) return n - 1;
    return null;
  }

  /// Build a shuffled permutation of queue indices. If [startAt] is a valid
  /// index, it is placed first so the currently-playing song stays put.
  void _buildShuffleOrder({required int startAt}) {
    final n = state.queue.length;
    final order = List<int>.generate(n, (i) => i);
    order.shuffle(_rng);
    if (startAt >= 0 && startAt < n) {
      order.remove(startAt);
      order.insert(0, startAt);
      _shufflePos = 0;
    } else {
      _shufflePos = 0;
    }
    _shuffleOrder = order;
  }

  /// Phase 39: toggle shuffle. Rebuilds the shuffle order anchored on the
  /// current song so the now-playing track isn't interrupted.
  void toggleShuffle() {
    // Audit fix (M5): haptic so toggles feel deliberate.
    HapticService.selection();
    final next = !state.isShuffled;
    state = state.copyWith(isShuffled: next);
    if (next) {
      _buildShuffleOrder(startAt: state.currentIndex);
    } else {
      _shuffleOrder = const [];
      _shufflePos = 0;
    }
  }

  /// Phase 39: cycle repeat off → all → one → off.
  void cycleRepeat() {
    // Audit fix (M5): haptic on cycle step.
    HapticService.selection();
    final order = [
      MusicRepeatMode.off,
      MusicRepeatMode.all,
      MusicRepeatMode.one,
    ];
    final cur = order.indexOf(state.repeatMode);
    state = state.copyWith(repeatMode: order[(cur + 1) % order.length]);
  }

  // ─── Existing controls ───

  /// Phase 38: change playback speed (0.25x–2.0x). Persists across tracks.
  Future<void> setSpeed(double rate) async {
    // Audit fix (M5): haptic on speed change.
    HapticService.selection();
    state = state.copyWith(playbackSpeed: rate);
    try {
      await _audio.setRate(rate);
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
  }

  /// Phase 38: cycle A-B repeat — first tap sets A, second sets B, third clears.
  /// If the second tap is before A, it is treated as a new A instead.
  void cycleAbRepeat() {
    if (state.abPointA == null) {
      state = state.copyWith(abPointA: state.position);
    } else if (state.abPointB == null) {
      if (state.position > state.abPointA!) {
        state = state.copyWith(abPointB: state.position);
      } else {
        state = state.copyWith(abPointA: state.position);
      }
    } else {
      state = state.copyWith(clearAb: true);
    }
  }

  void clearAbRepeat() {
    state = state.copyWith(clearAb: true);
  }

  // ─── Home-screen music widget ───
  // Pushed from THIS notifier (main isolate) whose platform channels are
  // known-good. The same call from the audio_service handler did not reach
  // the Activity, so the widget never updated — driving it from here fixes
  // that. Best-effort; never throws into playback.
  static const MethodChannel _musicWidgetChannel =
      MethodChannel('mx_clone/music_widget');

  void _updateMusicWidget({String? title, String? artist, bool? playing}) {
    final args = <String, dynamic>{};
    if (title != null) args['title'] = title;
    if (artist != null) args['artist'] = artist.isEmpty ? 'Innocent' : artist;
    if (playing != null) args['playing'] = playing;
    if (args.isEmpty) return;
    unawaited(_safeWidgetUpdate(args));
  }

  Future<void> _safeWidgetUpdate(Map<String, dynamic> args) async {
    try {
      await _musicWidgetChannel.invokeMethod('update', args);
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
  }

  Future<void> togglePlay() async {
    try {
      // Phase 45: claim audio focus when starting playback. If we're
      // pausing, we DON'T release focus immediately — pausing is
      // typically momentary, and re-claiming on every play would
      // create unnecessary system churn. Focus is released on stop()
      // or dispose().
      if (!state.isPlaying) {
        await _claimAudioFocus();
      }
      await _audio.playOrPause();
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
  }

  Future<void> setPosition(Duration p) async {
    // Audit fix (M1): clamp to [0, duration] like video does. libmpv
    // tolerates out-of-range but the optimistic state update below
    // would briefly show invalid positions until libmpv corrects.
    final dur = state.duration;
    final clamped = p < Duration.zero
        ? Duration.zero
        : (dur > Duration.zero && p > dur ? dur : p);
    state = state.copyWith(position: clamped);
    try {
      await _audio.seek(clamped);
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
  }

  // ─── Sleep timer (Phase 39) ───

  /// Start a sleep timer that pauses playback after [total]. Pass null to cancel.
  void setSleepTimer(Duration? total) {
    _sleepTicker?.cancel();
    if (total == null || total <= Duration.zero) {
      _sleepDeadline = null;
      state = state.copyWith(clearSleep: true);
      return;
    }
    // CORRECTNESS + BATTERY FIX — this used to count DOWN by subtracting one
    // second per tick. Android throttles and coalesces Dart timers once the
    // device is asleep, so ticks get skipped and a counter-based timer drifts
    // long: a 30-minute sleep timer could still be playing well past the hour,
    // with the wake lock held the whole time. Anchoring to a wall-clock
    // deadline means it fires as soon as any tick runs past the moment it was
    // asked for, no matter how many ticks the OS swallowed. (Same fix the
    // video player's sleep timer already had.)
    _sleepDeadline = DateTime.now().add(total);
    state = state.copyWith(sleepRemaining: total);
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final dl = _sleepDeadline;
      if (dl == null) {
        t.cancel();
        return;
      }
      final remaining = dl.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        t.cancel();
        _sleepDeadline = null;
        _audio.pause();
        state = state.copyWith(isPlaying: false, clearSleep: true);
      } else {
        // Only publish when the displayed second actually changes, so the
        // screen is not rebuilt for a value that reads identically.
        final shown = Duration(seconds: remaining.inSeconds + 1);
        if (state.sleepRemaining?.inSeconds != shown.inSeconds) {
          state = state.copyWith(sleepRemaining: shown);
        }
      }
    });
  }

  void cancelSleepTimer() => setSleepTimer(null);

  Future<void> stop() async {
    try {
      await _audio.pause();
    } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
    _shuffleOrder = const [];
    _shufflePos = 0;
    // Phase 45: release audio focus when the user explicitly stops.
    await _releaseAudioFocus();
    state = const MusicPlayingState();
  }

  /// Phase 45: handle Android audio-focus events. Music plays in the
  /// background most of the time, so phone calls / nav prompts / other
  /// media apps need to pause it cleanly.
  void _handleAudioFocusEvent(AudioFocusEvent event) {
    if (!mounted) return;
    switch (event) {
      case AudioFocusEvent.loss:
        // Permanent loss — another app took over playback. Pause and
        // don't auto-resume on later focus regain.
        if (state.isPlaying) {
          _audio.pause();
          state = state.copyWith(isPlaying: false);
          _pausedByFocusLoss = false;
        }
        break;
      case AudioFocusEvent.lossTransient:
      case AudioFocusEvent.lossTransientCanDuck:
        // Phone call, navigation voice, brief interruption — pause
        // and remember so we auto-resume on focus regain. Treat ducking
        // as transient because MX Player doesn't lower its own volume.
        if (state.isPlaying) {
          _audio.pause();
          state = state.copyWith(isPlaying: false);
          _pausedByFocusLoss = true;
        }
        break;
      case AudioFocusEvent.gain:
        // Interruption ended. Auto-resume iff WE were the ones who
        // paused for the interruption.
        if (_pausedByFocusLoss && !state.isPlaying) {
          _audio.play();
          state = state.copyWith(isPlaying: true);
        }
        _pausedByFocusLoss = false;
        break;
    }
  }

  /// Phase 45: claim audio focus. Idempotent — only the first call
  /// per playback session actually hits the system.
  Future<void> _claimAudioFocus() async {
    if (_hasFocusClaim) return;
    final ok = await _ref.read(audioFocusServiceProvider).request();
    if (ok) _hasFocusClaim = true;
  }

  /// Phase 45: release audio focus. Idempotent.
  Future<void> _releaseAudioFocus() async {
    if (!_hasFocusClaim) return;
    await _ref.read(audioFocusServiceProvider).abandon();
    _hasFocusClaim = false;
  }

  @override
  void dispose() {
    _sleepTicker?.cancel();
    _posSub.cancel();
    _playSub.cancel();
    _durSub.cancel();
    _completedSub.cancel();
    _errorSub?.cancel();
    // Phase 45: release audio focus + cancel subscription.
    _focusSub?.cancel();
    if (_hasFocusClaim) {
      try {
        _ref.read(audioFocusServiceProvider).abandon();
      } catch (e) { if (kDebugMode) debugPrint('music_providers.best-effort: $e'); }
      _hasFocusClaim = false;
    }
    super.dispose();
  }
}

final musicPlayingProvider =
    StateNotifierProvider<MusicPlayingNotifier, MusicPlayingState>((ref) {
  final audio = ref.watch(musicAudioServiceProvider);
  return MusicPlayingNotifier(audio, ref);
});
