import 'package:flutter/foundation.dart';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../utils/concurrency_limiter.dart';

/// Lazy-generates and caches video thumbnails to app cache directory.
/// On second access, reads from disk cache (fast).
///
/// Phase 28.2: replaced `video_thumbnail` plugin (v1 embedding, deleted)
/// with a native platform channel implementation backed by Android's
/// `MediaMetadataRetriever` in `MainActivity.kt`.
/// Whether generated thumbnails may be written to disk.
///
/// Settings → General → "Cache thumbnail". Off, thumbnails are still generated
/// and still held in memory for the session — they just aren't persisted, so
/// nothing about the library survives in app storage. That is the point of the
/// setting for people who share a phone. It had no reader, so thumbnails were
/// always written.
///
/// A plain global rather than a provider because the cache is a plain service
/// used from isolate-free background paths; the settings layer sets it once at
/// startup and whenever the switch changes.
bool thumbnailDiskCacheEnabled = true;

class ThumbnailCache {
  static final ThumbnailCache instance = ThumbnailCache._();
  ThumbnailCache._();

  static const MethodChannel _channel = MethodChannel('mx_clone/thumbnail');

  final Map<String, Future<Uint8List?>> _inflight = {};
  final Map<String, Uint8List> _memoryCache = {};
  static const int _maxMemoryEntries = 100;
  Directory? _cacheDir;

  /// Caps how many native thumbnail decodes run at once. Without this, a fast
  /// scroll through a large uncached folder spawns one native decoder thread
  /// per visible tile simultaneously and spikes the CPU. Sized to the device.
  static final ConcurrencyLimiter _genLimiter =
      ConcurrencyLimiter(adaptiveMediaConcurrency());

  Future<Directory> _getCacheDir() async {
    if (_cacheDir != null) return _cacheDir!;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'thumbnails'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;
    return dir;
  }

  String _cacheKey(String videoPath) {
    // Stable hash; safe filename
    return '${videoPath.hashCode.toUnsigned(32).toRadixString(16)}.jpg';
  }

  /// Robust thumbnail via photo_manager, keyed by the MediaStore asset id.
  /// Unlike the path-based [get] (native MediaMetadataRetriever, which fails
  /// for files under scoped storage / SD cards / content URIs), this uses
  /// Android's MediaStore thumbnail pipeline and works for essentially any
  /// indexed video on any device — the MX-Player-style thumbnail path.
  /// Disk-cached like [get] so scrolling a folder twice is instant.
  Future<Uint8List?> getByAsset(String assetId) async {
    if (assetId.isEmpty) return null;
    final key = 'a_${assetId.hashCode.toUnsigned(32).toRadixString(16)}.jpg';
    if (_memoryCache.containsKey(key)) return _memoryCache[key];
    if (_inflight.containsKey(key)) return _inflight[key]!;
    final future = _generateByAsset(assetId, key);
    _inflight[key] = future;
    try {
      final result = await future;
      if (result != null) _addToMemory(key, result);
      return result;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<Uint8List?> _generateByAsset(String assetId, String key) async {
    try {
      final dir = await _getCacheDir();
      final file = File(p.join(dir.path, key));
      // Disk cache hit
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        } catch (_) {/* fall through to regenerate */}
      }
      final bytes = await _genLimiter.run<Uint8List?>(() async {
        final asset = await AssetEntity.fromId(assetId);
        if (asset == null) return null;
        return asset.thumbnailDataWithSize(
          const ThumbnailSize(256, 144),
          quality: 72,
        );
      });
      if (bytes == null || bytes.isEmpty) return null;
      try {
        if (thumbnailDiskCacheEnabled) {
          await file.writeAsBytes(bytes, flush: false);
        }
      } catch (_) {/* best-effort disk cache */}
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Get thumbnail bytes for the given video path.
  /// Returns null if generation fails or on unsupported platforms.
  Future<Uint8List?> get(String videoPath) async {
    final key = _cacheKey(videoPath);

    // Memory cache hit
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }

    // Coalesce concurrent requests for same key
    if (_inflight.containsKey(key)) {
      return _inflight[key]!;
    }

    final future = _generate(videoPath, key);
    _inflight[key] = future;
    try {
      final result = await future;
      if (result != null) {
        _addToMemory(key, result);
      }
      return result;
    } finally {
      _inflight.remove(key);
    }
  }

  /// Phase 45: get a thumbnail for a specific time offset (seconds).
  /// Used by the seek-bar scrub preview — MX Player shows a small
  /// frame above the seek bar as you drag, telling you what's at that
  /// position before you release.
  ///
  /// Frames are bucketed by 5-second granularity to limit cache size
  /// and reuse work between adjacent scrub positions. We don't write
  /// these to disk because they're transient — the user typically
  /// only scrubs once per video.
  Future<Uint8List?> getAtTime(String videoPath, int seconds) async {
    if (seconds < 0) seconds = 0;
    final bucket = (seconds ~/ 5) * 5; // 5s granularity
    final key = '${_cacheKey(videoPath)}_t$bucket';

    // Memory cache hit
    if (_memoryCache.containsKey(key)) {
      return _memoryCache[key];
    }
    // Coalesce
    if (_inflight.containsKey(key)) {
      return _inflight[key]!;
    }
    final future = _generateAtTime(videoPath, bucket * 1000);
    _inflight[key] = future;
    try {
      final result = await future;
      if (result != null) _addToMemory(key, result);
      return result;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<Uint8List?> _generateAtTime(String videoPath, int timeMs) async {
    try {
      // Always go through the native channel; we don't disk-cache scrub
      // previews because they're transient and would explode the cache.
      // Shares the same decode limiter as list thumbnails so a rapid scrub
      // drag can't pile up unbounded native decoders either.
      final result = await _genLimiter.run(
        () => _channel.invokeMethod<Uint8List>('generate', {
          'path': videoPath,
          'maxWidth': 192,
          'quality': 50,
          'timeMs': timeMs,
        }),
      );
      return (result == null || result.isEmpty) ? null : result;
    } on PlatformException catch (_) {
      return null;
    } on MissingPluginException catch (_) {
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> _generate(String videoPath, String key) async {
    try {
      final dir = await _getCacheDir();
      final file = File(p.join(dir.path, key));

      // Disk cache hit
      if (await file.exists()) {
        try {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty) return bytes;
        } catch (e) { if (kDebugMode) debugPrint('thumbnail_cache.best-effort: $e'); }
      }

      // Generate via native platform channel (Android only for now).
      // Gated by _genLimiter so we never run more than a device-sized number
      // of native decodes at once (disk-cache hits above never reach here, so
      // they're not blocked by the queue).
      Uint8List? bytes;
      try {
        final result = await _genLimiter.run(
          () => _channel.invokeMethod<Uint8List>('generate', {
            'path': videoPath,
            'maxWidth': 256,
            'quality': 60,
            'timeMs': 2000,
          }),
        );
        bytes = result;
      } on PlatformException catch (_) {
        return null;
      } on MissingPluginException catch (_) {
        // Non-Android platforms; thumbnails unavailable.
        return null;
      }
      if (bytes == null || bytes.isEmpty) return null;

      // Persist to disk (best-effort), unless the user asked us not to.
      try {
        if (thumbnailDiskCacheEnabled) {
          await file.writeAsBytes(bytes, flush: false);
        }
      } catch (e) { if (kDebugMode) debugPrint('thumbnail_cache.best-effort: $e'); }

      return bytes;
    } catch (_) {
      return null;
    }
  }

  void _addToMemory(String key, Uint8List bytes) {
    if (_memoryCache.length >= _maxMemoryEntries) {
      // Simple FIFO eviction
      _memoryCache.remove(_memoryCache.keys.first);
    }
    _memoryCache[key] = bytes;
  }

  /// Phase 41: empty the in-memory cache and delete every cached file on
  /// disk. Used by Settings → General → "Clear thumbnail cache". Errors are
  /// swallowed so a partial failure (e.g. a single locked file) doesn't
  /// surface as a crash to the user.
  /// Drop the cached thumbnail for ONE video, in memory and on disk.
  ///
  /// This is what "Rebuild thumbnails" needs. [clear] throws away every
  /// thumbnail the library has ever generated, so using it to refresh a single
  /// file makes the whole grid regenerate — hundreds of frame extractions,
  /// several seconds of stutter, and a lot of battery, to fix one tile.
  ///
  /// The next [get] for this path finds nothing cached and regenerates, which
  /// is exactly the intent: the file changed on disk (renamed, re-encoded,
  /// replaced) and the stored frame no longer matches it.
  ///
  /// Also drops any in-flight generation for the same key, or a request that
  /// started before the file changed could complete afterwards and re-cache
  /// the stale frame.
  Future<void> invalidate(String videoPath) async {
    final key = _cacheKey(videoPath);
    _memoryCache.remove(key);
    _inflight.remove(key);
    try {
      final dir = await _getCacheDir();
      final file = File('${dir.path}/$key');
      if (await file.exists()) await file.delete();
    } catch (e) {
      // Best-effort: a thumbnail that could not be deleted is a stale
      // picture, not a broken app.
      if (kDebugMode) debugPrint('thumbnail_cache.invalidate: $e');
    }
  }

  /// [invalidate] for many paths, for the multi-select "Rebuild thumbnails"
  /// action. One cache-directory lookup instead of one per file.
  Future<void> invalidateAll(Iterable<String> videoPaths) async {
    if (videoPaths.isEmpty) return;
    Directory? dir;
    try {
      dir = await _getCacheDir();
    } catch (e) {
      if (kDebugMode) debugPrint('thumbnail_cache.invalidateAll: $e');
    }
    for (final path in videoPaths) {
      final key = _cacheKey(path);
      _memoryCache.remove(key);
      _inflight.remove(key);
      if (dir == null) continue;
      try {
        final file = File('${dir.path}/$key');
        if (await file.exists()) await file.delete();
      } catch (e) {
        if (kDebugMode) debugPrint('thumbnail_cache.invalidateAll: $e');
      }
    }
  }

  Future<void> clear() async {
    _memoryCache.clear();
    _inflight.clear();
    try {
      final dir = await _getCacheDir();
      if (await dir.exists()) {
        await for (final entity in dir.list()) {
          try {
            if (entity is File) await entity.delete();
          } catch (e) { if (kDebugMode) debugPrint('thumbnail_cache.best-effort: $e'); }
        }
      }
    } catch (_) {
      // Cache dir unavailable; nothing more we can do.
    }
  }
}
