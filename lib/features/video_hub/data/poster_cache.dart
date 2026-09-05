import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Disk cache for catalogue artwork.
///
/// WHY THIS EXISTS
/// ───────────────
/// `Image.network` caches in MEMORY only. Every cold start therefore
/// re-downloaded every poster on screen. A hundred-title catalogue is a few
/// megabytes of artwork, and this app is used on Myanmar mobile data - so the
/// cost of scrolling the same grid twice in a day was being paid twice, by the
/// user, in money.
///
/// Deliberately hand-written rather than `cached_network_image`. That package
/// pulls in `flutter_cache_manager`, which pulls in `sqflite` - a NATIVE
/// plugin. A native dependency turns a patch release into a minor one, adds a
/// platform library to a build that cannot be compiled locally to check, and
/// buys nothing here: the whole requirement is "put the bytes in a file and
/// find them again", which is the code below.
///
/// WHAT IS STORED, AND WHERE
/// ─────────────────────────
/// `getApplicationCacheDirectory()/vh_posters/`, app-private, with SHA-1 file
/// names. The name is opaque on purpose - this catalogue is adult, and a
/// directory listing of `Some Explicit Title.jpg` is a leak even inside
/// app-private storage. Nothing about a title is recoverable from the
/// directory; the URL cannot be read back out of the hash.
///
/// The cache directory is the right one rather than the support directory: the
/// OS may reclaim it under storage pressure and "Clear cache" empties it, both
/// of which are correct for artwork that can always be fetched again.
///
/// FAILURE IS NOT FATAL, BY DESIGN
/// ───────────────────────────────
/// Every path here returns null on failure and the caller falls back to plain
/// `Image.network` - exactly today's behaviour. A full disk, a denied
/// directory or a dead cache must degrade to "works, costs data", never to
/// "posters stopped appearing".
class PosterCache {
  const PosterCache._();

  /// One line turns the whole thing off, and the app goes back to
  /// network-only artwork.
  static bool enabled = true;

  /// Total bytes of artwork kept before the oldest are evicted.
  ///
  /// Deliberately small. Posters are tens of kilobytes, so this holds a
  /// catalogue several times over, and artwork is not worth arguing with the
  /// user's photo library about space.
  static const int _maxBytes = 48 * 1024 * 1024;

  /// Refuses anything that is not plausibly a poster. A misconfigured row
  /// pointing at a video file must not quietly fill the cache directory.
  static const int _maxEntryBytes = 4 * 1024 * 1024;

  /// URLs whose file is confirmed present on disk THIS SESSION.
  ///
  /// The point of the synchronous half: once a poster is known, a rebuild
  /// during a scroll costs a map lookup, not a `File.exists()` and not a
  /// future. A future created in `build` restarts in the waiting state on
  /// every rebuild, which is what made the grid blink before.
  static final Map<String, String> _known = <String, String>{};

  /// One resolve per URL, however many tiles ask at once. A row and its
  /// see-all grid can mount the same poster twice in the same frame.
  static final Map<String, Future<String?>> _inFlight =
      <String, Future<String?>>{};

  static Directory? _dir;
  static bool _pruned = false;

  /// A path already known to be on disk, or null. Never touches the disk.
  static String? pathIfReady(String url) => _known[url];

  /// The cached file for [url], fetching and storing it if necessary.
  ///
  /// Returns null when the artwork could not be cached for any reason. The
  /// caller must treat that as "use the network directly", not as an error.
  static Future<String?> resolve(String url) {
    if (!enabled || url.isEmpty || !url.startsWith('http')) {
      return Future<String?>.value(null);
    }
    final ready = _known[url];
    if (ready != null) return Future<String?>.value(ready);
    return _inFlight[url] ??= _resolve(url).whenComplete(() {
      _inFlight.remove(url);
    });
  }

  static Future<String?> _resolve(String url) async {
    try {
      final dir = await _directory();
      if (dir == null) return null;
      final file = File(p.join(dir.path, _nameFor(url)));

      if (await file.exists() && await file.length() > 0) {
        // Touch it so the pruner treats a poster still being looked at as
        // recently used. Best effort - a filesystem that refuses this is not
        // a reason to skip the cache hit.
        try {
          await file.setLastModified(DateTime.now());
        } catch (_) {}
        _known[url] = file.path;
        return file.path;
      }

      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final bytes = response.bodyBytes;
      if (bytes.isEmpty || bytes.length > _maxEntryBytes) return null;

      // Write to a sidecar and rename. A half-written file that is renamed
      // only on success can never be read as a complete one - without this, an
      // interrupted download becomes a permanently broken poster that the
      // cache would happily serve forever.
      final part = File('${file.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(file.path);

      _known[url] = file.path;
      unawaited(_pruneOnce());
      return file.path;
    } catch (e) {
      if (kDebugMode) debugPrint('PosterCache.resolve: $e');
      return null;
    }
  }

  static Future<Directory?> _directory() async {
    final existing = _dir;
    if (existing != null) return existing;
    try {
      final base = await getApplicationCacheDirectory();
      final dir = Directory(p.join(base.path, 'vh_posters'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir;
      return dir;
    } catch (e) {
      if (kDebugMode) debugPrint('PosterCache.dir: $e');
      return null;
    }
  }

  /// SHA-1 of the URL. A hash, not the file name from the URL: two providers
  /// may both serve `poster.jpg`, and the title must not be readable from a
  /// directory listing.
  ///
  /// `utf8.encode`, not `codeUnits` - the same form the rest of this project
  /// hashes with. `codeUnits` hands UTF-16 units to a function that masks each
  /// one to a byte, so two URLs differing only outside ASCII could hash to the
  /// same name and serve each other's artwork.
  static String _nameFor(String url) =>
      '${sha1.convert(utf8.encode(url))}.img';

  /// Evicts oldest-first until the directory fits, once per session.
  ///
  /// Once is enough: a session adds artwork in the tens of kilobytes, so a
  /// directory that fits at the start still fits at the end. Running it on
  /// every write would stat the whole directory during a scroll.
  static Future<void> _pruneOnce() async {
    if (_pruned) return;
    _pruned = true;
    try {
      final dir = _dir;
      if (dir == null) return;
      final files = <File>[];
      var total = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        files.add(entity);
        total += await entity.length();
      }
      if (total <= _maxBytes) return;

      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      for (final file in files) {
        if (total <= _maxBytes) break;
        final size = await file.length();
        try {
          await file.delete();
          total -= size;
          _known.removeWhere((_, path) => path == file.path);
        } catch (_) {}
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PosterCache.prune: $e');
    }
  }

  /// Drops one entry, file included.
  ///
  /// Called when a cached file will not DECODE, which means it is corrupt -
  /// a download cut short by a dropped connection at exactly the wrong moment,
  /// or a filesystem that lost the tail. Without this the broken bytes are
  /// served from disk forever and that one poster is permanently blank, which
  /// looks like a missing image rather than a repairable cache.
  static void forget(String url) {
    final path = _known.remove(url);
    if (path == null) return;
    unawaited(() async {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }());
  }

  /// Empties the cache. For a "clear cached images" action, and for tests.
  static Future<void> clear() async {
    _known.clear();
    try {
      final dir = await _directory();
      if (dir != null && await dir.exists()) {
        await dir.delete(recursive: true);
      }
      _dir = null;
      _pruned = false;
    } catch (e) {
      if (kDebugMode) debugPrint('PosterCache.clear: $e');
    }
  }
}
