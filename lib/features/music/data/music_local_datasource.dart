import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;
import 'package:audio_metadata_reader/audio_metadata_reader.dart';

import '../domain/song.dart';
import '../../../core/utils/concurrency_limiter.dart';

/// Phase 32: Real device music datasource.
/// photo_manager's RequestType.audio reads the device's audio MediaStore
/// (the same source MX Player uses).
class MusicLocalDataSource {
  /// Caps concurrent album-art extraction isolates. Each `compute` spawns a
  /// fresh isolate (real CPU + memory cost); flinging through the music list
  /// would otherwise start dozens at once. Device-sized like the thumbnail
  /// limiter.
  static final ConcurrencyLimiter _artLimiter =
      ConcurrencyLimiter(adaptiveMediaConcurrency());

  Future<List<AssetEntity>> _fetchAllAudio() async {
    // Audit fix (real user report on Flutlab web preview): photo_manager
    // is a native plugin — Android / iOS only. On web it throws
    // MissingPluginException, which used to bubble up as opaque error.
    // Short-circuit to empty so the UI shows clean empty state.
    if (kIsWeb) {
      if (kDebugMode) {
        debugPrint('MusicLocalDataSource: skipping audio scan on web '
          '(photo_manager has no web implementation)');
      }
      return [];
    }
    // Phase 32: photo_manager auto-requests appropriate permission per type.
    final ps = await PhotoManager.requestPermissionExtend();
    if (!ps.hasAccess) return [];

    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.audio,
      hasAll: true,
      onlyAll: true,
    );
    if (paths.isEmpty) return [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    if (count == 0) return [];
    return all.getAssetListRange(start: 0, end: count);
  }

  /// All songs (flat list).
  ///
  /// Metadata (ID3 title/artist/album) is read in a SINGLE background
  /// isolate over every file path at once. Reading hundreds of files
  /// synchronously on the main isolate used to jank the scan; batching
  /// them into one `compute` keeps the UI responsive. File resolution
  /// itself stays on the main isolate because photo_manager is a
  /// platform plugin and can't run off it.
  Future<List<Song>> getAllSongs() async {
    final assets = await _fetchAllAudio();

    // Pass 1 (main isolate): resolve each asset to a real file path.
    final raw = <_RawAudio>[];
    for (final a in assets) {
      final file = await a.file;
      final path = file?.path ?? '';
      if (path.isEmpty) continue;
      raw.add(_RawAudio(
        id: a.id,
        path: path,
        size: file == null ? 0 : await file.length(),
        fallbackTitle: _stripExt(a.title ?? p.basename(path)),
        folderPath: p.dirname(path),
        durationSeconds: a.duration,
        dateAdded: a.createDateTime,
      ));
    }
    if (raw.isEmpty) return [];

    // Pass 2 (background isolate): batch-read tags for every path.
    Map<String, List<String>> metaMap = {};
    try {
      metaMap =
          await compute(_readMetadataBatch, raw.map((r) => r.path).toList());
    } catch (_) {
      // Non-fatal: fall back to filename titles + empty artist/album.
      metaMap = {};
    }

    // Pass 3 (main isolate): assemble Song objects.
    final songs = <Song>[];
    for (final r in raw) {
      final m = metaMap[r.path];
      songs.add(Song(
        id: r.id,
        uri: r.path,
        title: (m != null && m[0].isNotEmpty) ? m[0] : r.fallbackTitle,
        artist: m != null ? m[1] : '',
        album: m != null ? m[2] : '',
        folderPath: r.folderPath,
        duration: Duration(seconds: r.durationSeconds),
        sizeBytes: r.size,
        dateAdded: r.dateAdded,
      ));
    }
    // Default: alphabetical (Tracks tab default)
    songs.sort((a, b) =>
        a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return songs;
  }

  /// Songs grouped by parent folder.
  Future<List<MusicFolder>> getFolders() async {
    final songs = await getAllSongs();
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
    folders.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }

  /// Songs grouped by album.
  Future<List<MusicAlbum>> getAlbums() async {
    final songs = await getAllSongs();
    final map = <String, int>{};
    for (final s in songs) {
      final key = s.album.isEmpty ? 'Unknown' : s.album;
      map[key] = (map[key] ?? 0) + 1;
    }
    final albums = map.entries
        .map((e) => MusicAlbum(name: e.key, songCount: e.value))
        .toList();
    albums.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return albums;
  }

  /// Songs grouped by artist.
  Future<List<MusicArtist>> getArtists() async {
    final songs = await getAllSongs();
    final map = <String, int>{};
    for (final s in songs) {
      final key = s.artist.isEmpty ? 'Unknown' : s.artist;
      map[key] = (map[key] ?? 0) + 1;
    }
    final artists = map.entries
        .map((e) => MusicArtist(name: e.key, songCount: e.value))
        .toList();
    artists.sort((a, b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return artists;
  }

  /// Songs by a specific artist.
  Future<List<Song>> getSongsByArtist(String artistName) async {
    final all = await getAllSongs();
    return all.where((s) {
      final a = s.artist.isEmpty ? 'Unknown' : s.artist;
      return a == artistName;
    }).toList();
  }

  /// Songs in a specific album.
  Future<List<Song>> getSongsByAlbum(String albumName) async {
    final all = await getAllSongs();
    return all.where((s) {
      final a = s.album.isEmpty ? 'Unknown' : s.album;
      return a == albumName;
    }).toList();
  }

  /// Songs in a specific folder.
  Future<List<Song>> getSongsInFolder(String folderPath) async {
    final all = await getAllSongs();
    return all.where((s) => s.folderPath == folderPath).toList();
  }

  static String _stripExt(String s) {
    final dot = s.lastIndexOf('.');
    if (dot <= 0) return s;
    final ext = s.substring(dot + 1);
    if (ext.length > 5 || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) return s;
    return s.substring(0, dot);
  }

  /// Audit fix (album art): lazy art loader. Bulk scan skips art to
  /// keep memory bounded. Player screen calls this for the current
  /// song so only the visible image is held in memory.
  /// Returns null when: file doesn't exist, no embedded picture,
  /// or reader throws on malformed file.
  Future<List<int>?> loadAlbumArt(String uri) async {
    if (kIsWeb) return null;
    try {
      // Run the read + image extraction in a background isolate. Pulling
      // an embedded cover (which can be a multi-MB picture) with the
      // synchronous reader on the main isolate drops frames exactly as the
      // player screen appears. audio_metadata_reader is pure Dart, so it's
      // isolate-safe (same path as the _readMetadataBatch scan). Gated so a
      // fast music-list scroll can't spawn a swarm of isolates at once.
      return await _artLimiter.run(() => compute(_readAlbumArt, uri));
    } catch (_) {
      return null;
    }
  }
}

/// Runs in a background isolate via [compute]. Returns the bytes of the
/// first embedded picture, or null if the file is missing, has no cover,
/// or can't be parsed. Synchronous on purpose — it's the isolate body.
List<int>? _readAlbumArt(String uri) {
  try {
    final file = File(uri);
    if (!file.existsSync()) return null;
    final meta = readMetadata(file, getImage: true);
    final pics = meta.pictures;
    if (pics.isEmpty) return null;
    return pics.first.bytes;
  } catch (_) {
    return null;
  }
}

/// Lightweight holder for an asset resolved on the main isolate, before
/// its metadata is read in the background.
class _RawAudio {
  final String id;
  final String path;
  final int size;
  final String fallbackTitle;
  final String folderPath;
  final int durationSeconds;
  final DateTime? dateAdded;

  const _RawAudio({
    required this.id,
    required this.path,
    required this.size,
    required this.fallbackTitle,
    required this.folderPath,
    required this.durationSeconds,
    this.dateAdded,
  });
}

/// Runs in a background isolate via [compute]. Reads ID3 tags for every
/// path and returns `path -> [title, artist, album]`. Uses only
/// `audio_metadata_reader` (pure Dart) + `dart:io`, so it is
/// isolate-safe — no platform channels are touched. Any per-file failure
/// is swallowed and yields empty strings for that entry.
Map<String, List<String>> _readMetadataBatch(List<String> paths) {
  final result = <String, List<String>>{};
  for (final path in paths) {
    var title = '';
    var artist = '';
    var album = '';
    try {
      final meta = readMetadata(File(path), getImage: false);
      title = meta.title?.trim() ?? '';
      artist = meta.artist?.trim() ?? '';
      album = meta.album?.trim() ?? '';
    } catch (e) { if (kDebugMode) debugPrint('music_local_datasource.best-effort: $e'); }
    result[path] = [title, artist, album];
  }
  return result;
}
