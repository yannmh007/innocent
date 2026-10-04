import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../features/local_browser/domain/folder.dart';
import '../../../features/local_browser/domain/video.dart';
import 'scan_gate.dart';

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

  // ─── Video lists live in FILES, whole ─────────────────────────────────
  //
  // They used to be SharedPreferences strings cut to the first 2000 videos.
  // On a phone with more than 2000 (the owner's has well over: Camera alone
  // holds 1221) the cut copy could never equal a fresh scan, and the
  // providers refresh whenever the two differ — so every refresh found a
  // "change", invalidated, re-read the cut cache, scanned MediaStore again,
  // and round it went for as long as the app was open: a whole-library
  // MediaStore scan (photo_manager's pool thread, ~40 % of a core) and a
  // 600 KB JSON encode and preferences write (the Dart thread, ~25 %),
  // without pause, idle or playing. Measured on the owner's phone by
  // CpuProbe, report HKUND9RY, 2026-10-04.
  //
  // A file holds any number of videos, and is not rewritten along with every
  // other setting the way a big preferences entry is.

  static const String _dirName = 'library_cache_v2';
  static const String _allVideosFile = 'all_videos.json';
  Directory? _dir;

  Future<Directory> _cacheDir() async {
    final d = _dir;
    if (d != null) return d;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, _dirName));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// One folder's cache file. Hashed: a path is not a safe file name.
  String _folderFile(String folderPath) =>
      'folder_${folderPath.hashCode.toUnsigned(32).toRadixString(16)}.json';

  static Map<String, Object?> _videoToJson(Video v) => {
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
      };

  static Video _videoFromJson(Map<String, dynamic> e) => Video(
        id: e['id'] as String,
        uri: e['uri'] as String,
        title: e['title'] as String,
        folderPath: e['folderPath'] as String,
        duration: Duration(milliseconds: (e['durationMs'] as num).toInt()),
        sizeBytes: (e['sizeBytes'] as num).toInt(),
        width: (e['width'] as num).toInt(),
        height: (e['height'] as num).toInt(),
        dateAdded: e['dateAdded'] != null
            ? DateTime.fromMillisecondsSinceEpoch((e['dateAdded'] as num).toInt())
            : null,
        // Absent in caches written before this field existed; null simply
        // falls back to dateAdded in Video.freshestDate.
        dateModified: e['dateModified'] != null
            ? DateTime.fromMillisecondsSinceEpoch(
                (e['dateModified'] as num).toInt())
            : null,
      );

  Future<void> _writeVideos(String name, List<Video> videos) async {
    final dir = await _cacheDir();
    final file = File(p.join(dir.path, name));
    // Written beside and renamed over, so a crash mid-write never leaves a
    // half file to be read back as the library.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(videos.map(_videoToJson).toList()),
        flush: true);
    await tmp.rename(file.path);
  }

  Future<List<Video>?> _readVideos(String name) async {
    try {
      final dir = await _cacheDir();
      final file = File(p.join(dir.path, name));
      if (!await file.exists()) return null;
      final list = jsonDecode(await file.readAsString()) as List;
      return list
          .map((e) => _videoFromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// The old preferences copies are only dead weight now: every value in
  /// SharedPreferences is held in memory and rewritten with each save.
  Future<void> _dropLegacyVideoKeys(SharedPreferences sp) async {
    if (sp.containsKey(_kAllVideosKey)) await sp.remove(_kAllVideosKey);
    for (final key in sp.getKeys().toList()) {
      if (key.startsWith(_kFolderPrefix)) await sp.remove(key);
    }
  }

  /// Save all-videos snapshot — every video, however many.
  Future<void> saveAllVideos(List<Video> videos) async {
    await _writeVideos(_allVideosFile, videos);
    final sp = await SharedPreferences.getInstance();
    await _dropLegacyVideoKeys(sp);
  }

  Future<List<Video>?> loadAllVideos() async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    return _readVideos(_allVideosFile);
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
    await _writeVideos(_folderFile(folderPath), videos);
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kTimestampKey, DateTime.now().millisecondsSinceEpoch);
  }

  Future<List<Video>?> loadVideosInFolder(String folderPath) async {
    final sp = await SharedPreferences.getInstance();
    if (_isStale(sp)) return null;
    return _readVideos(_folderFile(folderPath));
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kFoldersKey);
    await sp.remove(_kAllVideosKey);
    await sp.remove(_kTimestampKey);
    // Phase 44: also wipe per-folder entries.
    await _dropLegacyVideoKeys(sp);
    // A stamp without its cache would let the next launch trust nothing.
    await ScanGate.clear();
    try {
      final dir = await _cacheDir();
      if (await dir.exists()) await dir.delete(recursive: true);
      _dir = null;
    } catch (_) {
      // A cache that could not be deleted is rebuilt over on the next scan.
    }
  }
}
