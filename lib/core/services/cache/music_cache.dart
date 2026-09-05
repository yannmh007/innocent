import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/music/domain/song.dart';

/// Disk cache for the scanned music library — the music counterpart of
/// `LibraryCache`.
///
/// Without it the Music tab re-scans the device on every cold start. With it,
/// the tab shows the last-known song list **instantly** on every launch while
/// a fresh scan runs in the background and quietly reconciles any changes.
///
/// Only lightweight metadata is stored. Embedded album-art bytes
/// ([Song.coverBytes]) are deliberately **not** cached — they can be large
/// and are loaded lazily per-URI by the player — which keeps this cache small
/// and fast to read/write.
class MusicCache {
  static const String _kSongsKey = 'music_cache_songs_v1';
  static const String _kTimestampKey = 'music_cache_ts';
  static const Duration _maxAge = Duration(days: 7);

  /// Save a snapshot of the song list (metadata only, no album art).
  Future<void> saveSongs(List<Song> songs) async {
    final sp = await SharedPreferences.getInstance();
    final list = songs
        .take(5000) // bound cache size for very large libraries
        .map((s) => {
              'id': s.id,
              'uri': s.uri,
              'title': s.title,
              'artist': s.artist,
              'album': s.album,
              'folderPath': s.folderPath,
              'durationMs': s.duration.inMilliseconds,
              'sizeBytes': s.sizeBytes,
              'dateAdded': s.dateAdded?.millisecondsSinceEpoch,
            })
        .toList();
    await sp.setString(_kSongsKey, jsonEncode(list));
    await sp.setInt(_kTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Load the cached song list. Returns null when missing or stale.
  Future<List<Song>?> loadSongs() async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    final raw = sp.getString(_kSongsKey);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Song(
                id: e['id'] as String,
                uri: e['uri'] as String,
                title: e['title'] as String,
                artist: e['artist'] as String,
                album: e['album'] as String,
                folderPath: e['folderPath'] as String,
                duration:
                    Duration(milliseconds: (e['durationMs'] as num).toInt()),
                sizeBytes: (e['sizeBytes'] as num).toInt(),
                dateAdded: e['dateAdded'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (e['dateAdded'] as num).toInt())
                    : null,
                // coverBytes intentionally omitted — fetched lazily per URI.
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  bool _isStale(SharedPreferences sp) {
    final ts = sp.getInt(_kTimestampKey);
    if (ts == null) return true;
    final age =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts));
    return age > _maxAge;
  }

  /// Clear the cached song list (e.g. before a forced rescan).
  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kSongsKey);
    await sp.remove(_kTimestampKey);
  }
}
