import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/services/user_data/user_data_service.dart';
import '../private_folder/data/private_folder_providers.dart';
import 'domain/user_data_models.dart';

/// Singleton service provider
final userDataServiceProvider = Provider<UserDataService>((ref) {
  return UserDataService();
});

// === FAVOURITES ===

class FavouritesNotifier extends StateNotifier<Set<String>> {
  final UserDataService _service;
  FavouritesNotifier(this._service) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadFavourites();
  }

  Future<bool> toggle(String videoUri) async {
    final added = await _service.toggleFavourite(videoUri);
    state = await _service.loadFavourites();
    return added;
  }

  bool contains(String videoUri) => state.contains(videoUri);
}

final favouritesProvider =
    StateNotifierProvider<FavouritesNotifier, Set<String>>((ref) {
  return FavouritesNotifier(ref.read(userDataServiceProvider));
});

// === PLAYLISTS ===

class PlaylistsNotifier extends StateNotifier<List<Playlist>> {
  final UserDataService _service;
  PlaylistsNotifier(this._service) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadPlaylists();
  }

  Future<Playlist> create(String name) async {
    final p = await _service.createPlaylist(name);
    state = await _service.loadPlaylists();
    return p;
  }

  Future<void> delete(String id) async {
    await _service.deletePlaylist(id);
    state = await _service.loadPlaylists();
  }

  /// Phase 29: Rename a playlist
  Future<void> rename(String id, String newName) async {
    final playlists = [...state];
    final idx = playlists.indexWhere((p) => p.id == id);
    if (idx < 0) return;
    final pl = playlists[idx];
    final updated = pl.copyWith(name: newName, updatedAt: DateTime.now());
    playlists[idx] = updated;
    state = playlists;
    await _service.savePlaylists(playlists);
  }

  Future<void> addVideo(String playlistId, String videoUri) async {
    await _service.addToPlaylist(playlistId, videoUri);
    state = await _service.loadPlaylists();
  }

  Future<void> removeVideo(String playlistId, String videoUri) async {
    await _service.removeFromPlaylist(playlistId, videoUri);
    state = await _service.loadPlaylists();
  }

  /// Phase 14: Reorder videos in a playlist
  Future<void> reorderVideos(
      String playlistId, int oldIndex, int newIndex) async {
    final playlists = [...state];
    final idx = playlists.indexWhere((p) => p.id == playlistId);
    if (idx < 0) return;
    final pl = playlists[idx];
    final newUris = [...pl.videoUris];
    if (oldIndex < 0 || oldIndex >= newUris.length) return;
    if (newIndex > newUris.length) newIndex = newUris.length;
    // ReorderableListView's index conversion: when moving down, target index is offset
    if (oldIndex < newIndex) newIndex -= 1;
    final item = newUris.removeAt(oldIndex);
    newUris.insert(newIndex, item);
    playlists[idx] = pl.copyWith(
      videoUris: newUris,
      updatedAt: DateTime.now(),
    );
    state = playlists;
    await _service.savePlaylists(playlists);
  }
}

final playlistsProvider =
    StateNotifierProvider<PlaylistsNotifier, List<Playlist>>((ref) {
  return PlaylistsNotifier(ref.read(userDataServiceProvider));
});

// === BOOKMARKS ===

class BookmarksNotifier extends StateNotifier<List<Bookmark>> {
  final UserDataService _service;
  BookmarksNotifier(this._service) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadBookmarks();
  }

  Future<Bookmark> add({
    required String videoUri,
    required String videoTitle,
    required Duration position,
    String? label,
  }) async {
    final b = await _service.addBookmark(
      videoUri: videoUri,
      videoTitle: videoTitle,
      position: position,
      label: label,
    );
    state = await _service.loadBookmarks();
    return b;
  }

  Future<void> delete(String bookmarkId) async {
    await _service.deleteBookmark(bookmarkId);
    state = await _service.loadBookmarks();
  }

  /// Bookmarks filtered for a single video
  List<Bookmark> forVideo(String videoUri) =>
      state.where((b) => b.videoUri == videoUri).toList()
        ..sort((a, b) => a.position.compareTo(b.position));
}

final bookmarksProvider =
    StateNotifierProvider<BookmarksNotifier, List<Bookmark>>((ref) {
  return BookmarksNotifier(ref.read(userDataServiceProvider));
});

// === HISTORY ===

class HistoryNotifier extends StateNotifier<List<HistoryEntry>> {
  final UserDataService _service;
  HistoryNotifier(this._service) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadHistory();
  }

  Future<void> record({
    required String videoUri,
    required String videoTitle,
    required Duration position,
    required Duration duration,
    bool countAsNewPlay = false,
  }) async {
    await _service.recordPlayback(
      videoUri: videoUri,
      videoTitle: videoTitle,
      position: position,
      duration: duration,
      countAsNewPlay: countAsNewPlay,
    );
    state = await _service.loadHistory();
  }

  Future<void> clear() async {
    await _service.clearHistory();
    state = [];
  }

  Future<void> deleteEntry(String videoUri) async {
    await _service.deleteHistoryEntry(videoUri);
    state = await _service.loadHistory();
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, List<HistoryEntry>>((ref) {
  return HistoryNotifier(ref.read(userDataServiceProvider));
});

/// History with Private-Folder entries stripped out. Anything stored under
/// the app-private vault (`private_vault/…`) must never surface in public
/// UI — Continue Watching, the Resume FAB, etc. Videos moved into the
/// Private Folder play from the vault, so their resume entries carry that
/// path segment; filtering on it here gives every public "recently watched"
/// surface a single, safe source. Restoring a video out of the vault
/// changes its path back, so it can legitimately reappear afterwards.
/// Normalizes a video URI for comparison. History entries and Private
/// Folder entries can store the same file with slightly different spellings
/// (with/without the `file://` scheme), which would let a privatized video
/// slip through the equality check below. Reducing both sides to a bare
/// filesystem path makes the match robust.
/// Public form of [_normalizePublicUri], for callers outside this file.
///
/// Anything comparing a library entry against a playback record has to go
/// through this. The two sides genuinely spell the same file differently — the
/// library hands out what MediaStore reports, history stores whatever the
/// player was opened with — and comparing the raw strings fails silently,
/// which looks like "the app forgot I watched this" rather than like a bug.
String normalizeMediaUri(String uri) => _normalizePublicUri(uri);

/// Every video with a playback record, keyed by normalised uri.
///
/// This is the "no playback record" half of MX Player's NEW rule, and it is
/// also what lets a tile answer "have I watched this?" in constant time. Each
/// tile used to scan the whole history list itself, so a list of twenty
/// visible items did up to four thousand string comparisons every time a
/// position was saved.
final playedUrisProvider = Provider<Set<String>>((ref) {
  final history = ref.watch(historyProvider);
  return {for (final e in history) _normalizePublicUri(e.videoUri)};
});

/// Normalised uri → when it was last watched. Backs the "Played time" sort.
final lastWatchedProvider = Provider<Map<String, DateTime>>((ref) {
  final history = ref.watch(historyProvider);
  return {
    for (final e in history) _normalizePublicUri(e.videoUri): e.lastWatched,
  };
});

/// Normalised uri → watch progress in 0..1, for the thin bar across the
/// bottom of a thumbnail. Same one-pass build, same constant-time lookup.
final watchProgressProvider = Provider<Map<String, double>>((ref) {
  final history = ref.watch(historyProvider);
  final map = <String, double>{};
  for (final e in history) {
    final p = e.progress;
    if (p > 0.0) map[_normalizePublicUri(e.videoUri)] = p;
  }
  return map;
});

String _normalizePublicUri(String uri) {
  var u = uri.trim();
  if (u.startsWith('file://')) {
    try {
      u = Uri.parse(u).toFilePath();
    } catch (_) {
      u = u.replaceFirst('file://', '');
    }
  }
  return u;
}

final publicHistoryProvider = Provider<List<HistoryEntry>>((ref) {
  final all = ref.watch(historyProvider);
  // Original URIs of every vaulted video, so an entry recorded BEFORE the
  // video was moved into the Private Folder is hidden too (while the set
  // is still loading we fall back to the path-segment check below).
  final privateUris =
      ref.watch(privateFolderUrisProvider).valueOrNull ?? const <String>{};
  final privateNorm = privateUris.map(_normalizePublicUri).toSet();
  // Recycle Bin. "Hide" has to mean hidden EVERYWHERE, not just in the grids.
  //
  // The bin filter added in v1.56.1 covered the video and folder lists, so a
  // binned video vanished from the library — and carried on appearing by name
  // in Continue Watching and behind the Resume button, which sit on the same
  // screen. Hiding something from one strip and not the one above it is not
  // hiding it; someone who binned a video before handing their phone over
  // would still have had its title on screen.
  final recycledNorm = <String>{
    for (final e in ref.watch(recycleBinProvider))
      _normalizePublicUri(e.videoUri),
  };
  return all
      .where((e) =>
          // played from inside the vault → path carries the vault segment…
          !e.videoUri.contains('private_vault') &&
          // …or watched first, then moved in → original URI is now private.
          !privateNorm.contains(_normalizePublicUri(e.videoUri)) &&
          !recycledNorm.contains(_normalizePublicUri(e.videoUri)))
      .toList();
});

// === RECYCLE BIN ===

class RecycleBinNotifier extends StateNotifier<List<RecycleBinEntry>> {
  final UserDataService _service;
  RecycleBinNotifier(this._service) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadRecycleBin();
  }

  Future<void> add(RecycleBinEntry entry) async {
    await _service.addToRecycleBin(entry);
    state = await _service.loadRecycleBin();
  }

  Future<void> restore(String videoUri) async {
    await _service.restoreFromRecycleBin(videoUri);
    state = await _service.loadRecycleBin();
  }

  Future<void> empty() async {
    await _service.emptyRecycleBin();
    state = [];
  }
}

final recycleBinProvider =
    StateNotifierProvider<RecycleBinNotifier, List<RecycleBinEntry>>((ref) {
  return RecycleBinNotifier(ref.read(userDataServiceProvider));
});

// === WATCH LATER (Phase 11) ===

class WatchLaterNotifier extends StateNotifier<List<String>> {
  final UserDataService _service;
  WatchLaterNotifier(this._service) : super(const []) {
    _load();
  }

  Future<void> _load() async {
    state = await _service.loadWatchLater();
  }

  Future<bool> add(String videoUri) async {
    final added = await _service.addToWatchLater(videoUri);
    state = await _service.loadWatchLater();
    return added;
  }

  Future<void> remove(String videoUri) async {
    await _service.removeFromWatchLater(videoUri);
    state = await _service.loadWatchLater();
  }

  bool contains(String videoUri) => state.contains(videoUri);
}

final watchLaterProvider =
    StateNotifierProvider<WatchLaterNotifier, List<String>>((ref) {
  return WatchLaterNotifier(ref.read(userDataServiceProvider));
});
