import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:path/path.dart' as p;

import '../domain/folder.dart';
import '../domain/video.dart';

/// Datasource for local video files via photo_manager (wraps MediaStore).
///
/// Phase 44 rewrite — performance focus.
///
/// Previously every method called `_fetchAllVideos()` and then for EACH
/// asset called `await asset.file` and `await file.length()`. For a phone
/// with 500+ videos that's 1500+ IPC roundtrips into MediaStore on every
/// Local-tab refresh — which is exactly what MX Player avoids.
///
/// MX Player gets folder buckets directly from MediaStore in ONE query.
/// This rewrite does the same:
/// * [getFolders] uses `getAssetPathList(hasAll: false)` so folders come
///   back as `AssetPathEntity` buckets with name + count already populated.
///   No per-video iteration.
/// * [getVideosInFolder] looks up the specific bucket and pages its
///   asset list — no scanning of unrelated folders.
/// * [getAllVideos] iterates the buckets and stitches them, so each
///   video's folder path is implicit (no extra `_resolveFolderPath` call).
/// * Per-video size (`await file.length()`) is SKIPPED in the upfront
///   scan. Size is set to 0 and the UI hides the size chip gracefully.
///   Total folder size is also 0 in the fresh scan; the cache may carry
///   sizes computed by an earlier slow pass.
class LibraryLocalDataSource {
  /// Internal helper — fetch all video folder buckets once.
  Future<List<AssetPathEntity>> _fetchFolderBuckets() async {
    // Audit fix (real user report on Flutlab web preview): photo_manager
    // throws on web. Short-circuit to empty so the UI shows the empty
    // state cleanly instead of a cryptic plugin error.
    if (kIsWeb) {
      if (kDebugMode) debugPrint('LibraryLocalDataSource: skipping video scan on web '
          '(photo_manager has no web implementation)');
      return [];
    }
    // The Local screen already drives the permission dialog via
    // permission_handler before these providers run, so here we mainly need
    // photo_manager to observe the already-granted state. Guard with a
    // timeout: on some devices requestPermissionExtend can block if it
    // tries to surface its own dialog while another is pending — better to
    // fall through to an empty result the UI can retry than to hang the
    // Local tab spinner indefinitely.
    PermissionState ps;
    try {
      ps = await PhotoManager.requestPermissionExtend()
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      if (kDebugMode) {
        debugPrint('LibraryLocalDataSource: permission check timed out/failed: $e');
      }
      return [];
    }
    if (!ps.hasAccess) return [];

    // `hasAll: false` → returns the per-folder buckets only (no synthetic
    // "All Videos" entry). Each bucket is a folder we can list lazily.
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.video,
      hasAll: false,
    );
    return paths;
  }

  /// Convert a single asset to our [Video] model. Calls `asset.file` once
  /// to resolve the absolute path. Skips `file.length()` for speed — the
  /// caller decides whether to compute size lazily.
  Future<Video?> _toVideo(AssetEntity asset, String folderPath) async {
    try {
      // Guard against a single corrupt/inaccessible file hanging the whole
      // scan: if `asset.file` doesn't resolve within a few seconds, skip
      // this asset rather than blocking the Local tab forever. This is the
      // safety net behind the "spinner never finishes" report.
      final file = await asset.file
          .timeout(const Duration(seconds: 8), onTimeout: () => null);
      final uri = file?.path ?? '';
      if (uri.isEmpty) return null;

      // The physical file is already resolved above, so reading its length is
      // just a cheap stat — no extra MediaStore materialization. Guarded so a
      // stat failure yields 0 (UI hides the size chip) instead of dropping the
      // whole video from the list.
      int sizeBytes = 0;
      try {
        sizeBytes = await file!.length();
      } catch (_) {
        sizeBytes = 0;
      }

      return Video(
        id: asset.id,
        uri: uri,
        title: _stripIdTag(_stripExt(asset.title ?? p.basename(uri))),
        folderPath: folderPath,
        duration: Duration(seconds: asset.duration),
        sizeBytes: sizeBytes,
        width: asset.width,
        height: asset.height,
        mimeType: asset.mimeType,
        dateAdded: asset.createDateTime,
        dateModified: asset.modifiedDateTime,
      );
    } catch (_) {
      return null;
    }
  }

  /// Returns the folder list. Uses MediaStore folder buckets directly so
  /// it returns quickly even on phones with thousands of videos.
  ///
  /// Perf note (real user report — spinner hangs on the Local tab on some
  /// phones while Music loads fine): the previous version processed buckets
  /// serially, and for EACH bucket did `await asset.file`, which forces
  /// photo_manager to materialize the physical file (a slow MediaStore →
  /// cache copy on some devices / SD cards). With many folders that
  /// serialized into a multi-second stall. Now:
  ///  * all buckets are processed in PARALLEL (Future.wait), so total time
  ///    is roughly the slowest single bucket, not the sum;
  ///  * `asset.file` is called at most once per bucket and its result is
  ///    used only to derive the folder path — the cover thumbnail comes
  ///    from allVideosProvider separately, so a failure here no longer
  ///    blocks the folder appearing.
  Future<List<Folder>> getFolders() async {
    final buckets = await _fetchFolderBuckets();
    if (buckets.isEmpty) return [];

    final futures = buckets.map((bucket) async {
      String folderPath = bucket.name;
      String? coverPath;
      // Always zero here now. This used to be a guess — "is the newest asset
      // in this bucket under 7 days old? then say 1" — which was wrong three
      // ways: it hard-coded 7 days instead of reading the user's setting, it
      // ignored whether anything had been played, and it could only ever
      // report 1 no matter how many new files the folder held. The real count
      // is computed by `folderNewCountsProvider` from the video list the app
      // already has in memory, so it costs no extra I/O and always agrees with
      // the per-file badges.
      const int newCount = 0;
      int count = 0;
      try {
        count = await bucket.assetCountAsync;
        if (count > 0) {
          final firstAssets =
              await bucket.getAssetListRange(start: 0, end: 1);
          if (firstAssets.isNotEmpty) {
            final first = firstAssets.first;
            // Resolve the folder path from the first asset. This is the
            // one potentially-slow call; wrap it so a hang on one bucket
            // can't block the others (they run in parallel anyway).
            final f = await first.file;
            if (f != null) {
              folderPath = p.dirname(f.path);
              coverPath = f.path;
            }
          }
        }
      } catch (_) {
        // Permission glitch / transient — keep whatever we have.
      }
      if (count == 0) return null;
      return Folder(
        path: folderPath,
        name: p.basename(folderPath).isEmpty
            ? folderPath
            : p.basename(folderPath),
        videoCount: count,
        coverThumbnailPath: coverPath,
        newCount: newCount,
        totalSizeBytes: 0, // lazy — not computed in the fast path.
      );
    }).toList();

    final resolved = await Future.wait(futures);
    final folders = resolved.whereType<Folder>().toList();
    folders.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return folders;
  }

  /// Returns the videos inside the given folder. Looks up the matching
  /// bucket and pages its asset list, avoiding any work for other folders.
  Future<List<Video>> getVideosInFolder(String folderPath) async {
    final buckets = await _fetchFolderBuckets();
    if (buckets.isEmpty) return [];

    // Find the bucket matching this folder path. Try by name first
    // (cheapest), then fall back to resolving the bucket's first asset's
    // dirname (matches what getFolders does).
    final folderName = p.basename(folderPath);
    AssetPathEntity? target;
    for (final bucket in buckets) {
      if (bucket.name == folderName) {
        target = bucket;
        break;
      }
    }
    // Fall back: scan each bucket's first-asset folder to match exactly.
    if (target == null) {
      for (final bucket in buckets) {
        try {
          final first =
              await bucket.getAssetListRange(start: 0, end: 1);
          if (first.isEmpty) continue;
          final f = await first.first.file;
          if (f != null && p.dirname(f.path) == folderPath) {
            target = bucket;
            break;
          }
        } catch (e) { if (kDebugMode) debugPrint('library_local_datasource.best-effort: $e'); }
      }
    }
    if (target == null) return [];

    final count = await target.assetCountAsync;
    if (count == 0) return [];
    final assets = await target.getAssetListRange(start: 0, end: count);

    // Batched-parallel resolution (same reasoning as getAllVideos): avoids
    // a serial `asset.file` per video that stalls large folders.
    final result = <Video>[];
    const batchSize = 16;
    for (var i = 0; i < assets.length; i += batchSize) {
      final slice =
          assets.sublist(i, (i + batchSize).clamp(0, assets.length));
      final vids =
          await Future.wait(slice.map((a) => _toVideo(a, folderPath)));
      for (final v in vids) {
        if (v != null) result.add(v);
      }
    }
    result.sort((a, b) {
      final dateA = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
      final dateB = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
      return dateB.compareTo(dateA);
    });
    return result;
  }

  /// Returns every video on the device as a flat list. Used for the
  /// "Videos" view mode and for the "Recently Added" rail.
  ///
  /// Phase 44: iterates folder buckets and tags each video with the
  /// bucket's folder path. This avoids the previous design's separate
  /// `_resolveFolderPath` pass that did an extra `await asset.file` per
  /// video.
  Future<List<Video>> getAllVideos() async {
    final buckets = await _fetchFolderBuckets();
    if (buckets.isEmpty) return [];

    // Process buckets in parallel. Within each bucket, resolve the per-asset
    // files in bounded-concurrency batches: `asset.file` is the slow call
    // (MediaStore → cache materialization on some devices), and doing them
    // one-by-one across hundreds of videos is exactly what made the Local
    // tab spin for seconds on some phones. Batching keeps many in flight
    // without launching thousands of simultaneous IPC calls.
    final perBucket = await Future.wait(buckets.map((bucket) async {
      final out = <Video>[];
      try {
        final count = await bucket.assetCountAsync;
        if (count == 0) return out;
        // Folder path from the first asset (one file resolve per bucket).
        String? folderPath;
        final firstAssets =
            await bucket.getAssetListRange(start: 0, end: 1);
        if (firstAssets.isNotEmpty) {
          try {
            final f = await firstAssets.first.file;
            if (f != null) folderPath = p.dirname(f.path);
          } catch (_) {}
        }
        folderPath ??= bucket.name;
        final resolvedPath = folderPath; // non-null, safe for closures
        final assets = await bucket.getAssetListRange(start: 0, end: count);
        // Resolve in batches of 16 concurrent file lookups.
        const batchSize = 16;
        for (var i = 0; i < assets.length; i += batchSize) {
          final slice = assets.sublist(
              i, (i + batchSize).clamp(0, assets.length));
          final vids = await Future.wait(
              slice.map((a) => _toVideo(a, resolvedPath)));
          for (final v in vids) {
            if (v != null) out.add(v);
          }
        }
      } catch (_) {
        // Bucket-level failure — return whatever resolved so far.
      }
      return out;
    }));

    final result = <Video>[for (final list in perBucket) ...list];
    result.sort((a, b) {
      final ad = a.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bd = b.dateAdded ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bd.compareTo(ad);
    });
    return result;
  }

  /// Video file extensions recognised on a raw filesystem walk. MediaStore
  /// never indexes files inside a `.nomedia` directory or with a dot-prefix,
  /// so the ONLY way to surface them for "Show hidden files and folders" is to
  /// walk the tree ourselves.
  /// Extensions the filesystem walk accepts.
  ///
  /// Settings → List → "File extensions" persists a pipe-separated list that
  /// nothing read, so the walk always used the built-in set below. Assigning
  /// here (rather than reading a provider inside the walk) keeps the data
  /// source free of Riverpod, which is the reason it is testable.
  static Set<String>? _extensionOverride;

  /// Empty or null restores the built-in set.
  static void setExtensionFilter(Iterable<String>? exts) {
    if (exts == null) {
      _extensionOverride = null;
      return;
    }
    final norm = <String>{};
    for (final e in exts) {
      final t = e.trim().toLowerCase();
      if (t.isEmpty) continue;
      norm.add(t.startsWith('.') ? t : '.$t');
    }
    _extensionOverride = norm.isEmpty ? null : norm;
  }

  static Set<String> get _activeExts => _extensionOverride ?? _videoExts;

  static const Set<String> _videoExts = {
    '.mp4', '.mkv', '.webm', '.avi', '.mov', '.m4v', '.3gp', '.3g2', '.flv',
    '.wmv', '.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.vob', '.ogv', '.rm',
    '.rmvb', '.divx', '.f4v', '.asf', '.m2v', '.mxf',
  };

  /// Walk the shared-storage volumes for video files INCLUDING hidden ones
  /// (dot-prefixed files and files under `.nomedia` folders) that MediaStore
  /// deliberately omits. Backs the "Show hidden files and folders" toggle.
  ///
  /// Limits (by design, not bugs):
  ///  * `Android/data` and `Android/obb` of other apps are OS-sandboxed on
  ///    Android 11+ even with All-Files-Access, so they're skipped (listing
  ///    them just throws). `Android/media` IS readable and is included.
  ///  * duration / resolution aren't probed here — that would mean opening
  ///    every file. Hidden entries still play and still get a lazy thumbnail
  ///    from their path; they just don't display a length.
  Future<List<Video>> scanFilesystemVideos() async {
    final out = <Video>[];
    final seen = <String>{};
    final roots = <Directory>[];
    final primary = Directory('/storage/emulated/0');
    if (await primary.exists()) roots.add(primary);
    // Removable volumes (SD cards) live at /storage/XXXX-XXXX.
    try {
      final storage = Directory('/storage');
      if (await storage.exists()) {
        await for (final e in storage.list(followLinks: false)) {
          if (e is Directory) {
            final name = p.basename(e.path);
            if (name != 'emulated' && name != 'self') roots.add(e);
          }
        }
      }
    } catch (_) {/* /storage not listable — primary volume still works */}
    for (final root in roots) {
      await _walkForVideos(root, out, seen, 0);
    }
    return out;
  }

  Future<void> _walkForVideos(
      Directory dir, List<Video> out, Set<String> seen, int depth) async {
    if (depth > 16) return; // sane guard against symlink loops / silly trees
    final base = p.basename(dir.path);
    if (base == 'Android') {
      // Android/media is always readable. Android/data & Android/obb are
      // sandboxed on Android 11+ (listing throws → caught below, skipped),
      // but on Android ≤10 with storage permission they ARE readable, so we
      // attempt all three rather than skip the whole subtree. On 11+ the SAF
      // path (grantedTrees) covers Android/data instead.
      for (final sub in const ['media', 'data', 'obb']) {
        try {
          final d = Directory(p.join(dir.path, sub));
          if (await d.exists()) {
            await _walkForVideos(d, out, seen, depth + 1);
          }
        } catch (_) {/* sandboxed on 11+ — skip */}
      }
      return;
    }
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list(followLinks: false).toList();
    } catch (_) {
      return; // permission denied / not readable — skip this branch quietly
    }
    for (final entity in entries) {
      if (entity is Directory) {
        await _walkForVideos(entity, out, seen, depth + 1);
      } else if (entity is File) {
        final ext = p.extension(entity.path).toLowerCase();
        if (!_activeExts.contains(ext)) continue;
        if (!seen.add(entity.path)) continue;
        try {
          final st = await entity.stat();
          if (st.size <= 0) continue;
          out.add(Video(
            id: 'fs:${entity.path}',
            uri: entity.path,
            title: _stripIdTag(_stripExt(p.basename(entity.path))),
            folderPath: p.dirname(entity.path),
            duration: Duration.zero,
            sizeBytes: st.size,
            width: 0,
            height: 0,
            mimeType: null,
            dateAdded: st.modified,
            dateModified: st.modified,
          ));
        } catch (_) {/* stat failed — skip this file */}
      }
    }
  }

  /// Phase 16: MX Player parity — never show the file extension in titles.
  static String _stripExt(String s) {
    final dot = s.lastIndexOf('.');
    if (dot <= 0) return s;
    final ext = s.substring(dot + 1);
    if (ext.length > 5 || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) return s;
    return s.substring(0, dot);
  }

  static final RegExp _idTagRe = RegExp(r'\s\[[A-Za-z0-9_-]{6,24}\]$');

  /// Removes a trailing yt-dlp id tag — the " [<id>]" the downloader appends to
  /// keep same-titled clips from colliding on disk — so the library shows a
  /// clean title, not "Clip Title [ph64a3f2]".
  ///
  /// Deliberately tight so an ordinary filename is left alone: the tag must sit
  /// at the very end, hold 6–24 of [A-Za-z0-9_-] with no spaces, AND contain a
  /// digit — which yt-dlp ids do and ordinary title brackets ([Official Video],
  /// [HD], [Remastered]) do not.
  static String _stripIdTag(String s) {
    final Match? m = _idTagRe.firstMatch(s);
    if (m == null) return s;
    final String tag = m.group(0)!;
    if (!RegExp(r'[0-9]').hasMatch(tag)) return s;
    return s.substring(0, m.start);
  }
}
