import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/local_browser/domain/folder.dart';
import '../../../features/local_browser/domain/video.dart';

/// Disk cache for library data — solves "long loading on each app open" (PDF page 10).
/// Strategy: on cold start, immediately return cached data, then refresh in background.
class LibraryCache {
  static const String _kFoldersKey = 'lib_cache_folders_v1';
  static const String _kAllVideosKey = 'lib_cache_all_videos_v1';
  static const Duration _maxAge = Duration(days: 7);
  static const String _kTimestampKey = 'lib_cache_ts';
  // Phase 44: per-folder cache so opening a previously-visited folder
  // shows its videos instantly while a fresh scan runs in the background.
  static const String _kFolderPrefix = 'lib_cache_folder_v1:';

  /// Save folder list snapshot
  Future<void> saveFolders(List<Folder> folders) async {
    final sp = await SharedPreferences.getInstance();
    final list = folders
        .map((f) => {
              'path': f.path,
              'name': f.name,
              'videoCount': f.videoCount,
              // Phase 18: persist these fields so thumbnails and NEW badges
              // appear on cold-start cache load (Function PDF p10).
              if (f.coverThumbnailPath != null)
                'coverThumbnailPath': f.coverThumbnailPath,
              if (f.newCount > 0) 'newCount': f.newCount,
              // Phase 28: persist size so the chip survives cold start.
              if (f.totalSizeBytes > 0) 'totalSizeBytes': f.totalSizeBytes,
            })
        .toList();
    await sp.setString(_kFoldersKey, jsonEncode(list));
    await sp.setInt(_kTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  /// Load cached folder list. Returns null if no cache or too old.
  Future<List<Folder>?> loadFolders() async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    final raw = sp.getString(_kFoldersKey);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Folder(
                path: e['path'] as String,
                name: e['name'] as String,
                videoCount: (e['videoCount'] as num).toInt(),
                coverThumbnailPath: e['coverThumbnailPath'] as String?,
                newCount: (e['newCount'] as num?)?.toInt() ?? 0,
                totalSizeBytes:
                    (e['totalSizeBytes'] as num?)?.toInt() ?? 0,
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Save all-videos snapshot
  Future<void> saveAllVideos(List<Video> videos) async {
    final sp = await SharedPreferences.getInstance();
    // Limit cached entries to avoid bloat
    final clamped = videos.take(2000).toList();
    final list = clamped
        .map((v) => {
              'id': v.id,
              'uri': v.uri,
              'title': v.title,
              'folderPath': v.folderPath,
              'durationMs': v.duration.inMilliseconds,
              'sizeBytes': v.sizeBytes,
              'width': v.width,
              'height': v.height,
              'dateAdded': v.dateAdded?.millisecondsSinceEpoch,
              'dateModified': v.dateModified?.millisecondsSinceEpoch,
            })
        .toList();
    await sp.setString(_kAllVideosKey, jsonEncode(list));
  }

  Future<List<Video>?> loadAllVideos() async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    final raw = sp.getString(_kAllVideosKey);
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Video(
                id: e['id'] as String,
                uri: e['uri'] as String,
                title: e['title'] as String,
                folderPath: e['folderPath'] as String,
                duration: Duration(milliseconds: (e['durationMs'] as num).toInt()),
                sizeBytes: (e['sizeBytes'] as num).toInt(),
                width: (e['width'] as num).toInt(),
                height: (e['height'] as num).toInt(),
                dateAdded: e['dateAdded'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (e['dateAdded'] as num).toInt())
                    : null,
                // Absent in caches written before this field existed; null
                // simply falls back to dateAdded in Video.freshestDate.
                dateModified: e['dateModified'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (e['dateModified'] as num).toInt())
                    : null,
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  bool _isStale(SharedPreferences sp) {
    final ts = sp.getInt(_kTimestampKey);
    if (ts == null) return true;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ts));
    return age > _maxAge;
  }

  // ─── Phase 44: per-folder cache ───
  // Speeds up the very common "tap a folder, see videos" interaction
  // because we don't wait for MediaStore on every visit.

  Future<void> saveVideosInFolder(
      String folderPath, List<Video> videos) async {
    final sp = await SharedPreferences.getInstance();
    final list = videos
        .take(2000)
        .map((v) => {
              'id': v.id,
              'uri': v.uri,
              'title': v.title,
              'folderPath': v.folderPath,
              'durationMs': v.duration.inMilliseconds,
              'sizeBytes': v.sizeBytes,
              'width': v.width,
              'height': v.height,
              'dateAdded': v.dateAdded?.millisecondsSinceEpoch,
              'dateModified': v.dateModified?.millisecondsSinceEpoch,
            })
        .toList();
    await sp.setString('$_kFolderPrefix$folderPath', jsonEncode(list));
    await sp.setInt(_kTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<List<Video>?> loadVideosInFolder(String folderPath) async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    final raw = sp.getString('$_kFolderPrefix$folderPath');
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Video(
                id: e['id'] as String,
                uri: e['uri'] as String,
                title: e['title'] as String,
                folderPath: e['folderPath'] as String,
                duration:
                    Duration(milliseconds: (e['durationMs'] as num).toInt()),
                sizeBytes: (e['sizeBytes'] as num).toInt(),
                width: (e['width'] as num).toInt(),
                height: (e['height'] as num).toInt(),
                dateAdded: e['dateAdded'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (e['dateAdded'] as num).toInt())
                    : null,
                // Absent in caches written before this field existed; null
                // simply falls back to dateAdded in Video.freshestDate.
                dateModified: e['dateModified'] != null
                    ? DateTime.fromMillisecondsSinceEpoch(
                        (e['dateModified'] as num).toInt())
                    : null,
              ))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kFoldersKey);
    await sp.remove(_kAllVideosKey);
    await sp.remove(_kTimestampKey);
    // Phase 44: also wipe per-folder entries.
    for (final key in sp.getKeys()) {
      if (key.startsWith(_kFolderPrefix)) {
        await sp.remove(key);
      }
    }
  }
}
