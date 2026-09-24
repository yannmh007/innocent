import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where libmpv may spill a network stream's buffer, and whether it should.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT THIS BUYS, AND IT IS NOT WHAT IT SOUNDS LIKE
/// ═══════════════════════════════════════════════════════════════════════
///
/// With `cache-on-disk`, libmpv writes the packets it has already received
/// to a file instead of holding them in memory. The consequence that matters
/// is SEEKING BACKWARDS: without it, the back buffer is whatever fits in
/// `demuxer-max-back-bytes` — thirty-two megabytes, perhaps two minutes of a
/// 1080p film — and a scrub back past that re-requests the bytes from the
/// server. With it, everything watched so far is on the phone, and scrubbing
/// backwards costs nothing at all.
///
/// IT IS NOT A CACHE BETWEEN PLAYBACKS. mpv's own documentation is explicit:
/// "The cache file is deleted when playback is closed", and a cache file is
/// "generally worthless after the media is closed". Watching the same film
/// tomorrow downloads it again. Keeping it would be a different feature with
/// a different set of problems — a storage budget, an eviction rule, and a
/// plaintext copy of premium content sitting on the disk.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE SIZE LIMIT DOES NOT APPLY TO THE FILE
/// ═══════════════════════════════════════════════════════════════════════
///
/// This is the trap, and it is in the manual: with `cache-on-disk`,
/// `demuxer-max-bytes` applies to PACKET METADATA ONLY, not to the cache
/// file. The file is append-only and "even if the player appears to prune
/// data, the file space freed by it is not reused". So the file grows to the
/// size of everything watched — a two-hour film at the 1080p rung is close
/// to a gigabyte — and no player option caps it.
///
/// That is why the free-space check below exists and is not optional. A
/// phone with 600 MB free does not get this; it keeps the memory cache and
/// the smaller back buffer, which is worse at scrubbing and cannot fill the
/// disk. Filling a viewer's phone is a worse fault than a slow scrub.
///
/// ═══════════════════════════════════════════════════════════════════════
/// AND IT IS NOT A LEAK
/// ═══════════════════════════════════════════════════════════════════════
///
/// `demuxer-cache-unlink-files=immediate` is mpv's default and is set here
/// anyway, because the security property is worth stating rather than
/// inheriting: the file is unlinked the moment after it is created, so it
/// has no name any other app could open, and the space is reclaimed by the
/// kernel when the player closes it — even if the app crashes.
class DiskCacheDir {
  DiskCacheDir._();

  /// Below this much free space, the disk cache stays off.
  ///
  /// TWO GIGABYTES, which is more than a long film at the rung most viewers
  /// get. The margin is deliberate: the file has no ceiling, the phone has
  /// other apps, and Android starts behaving badly — failed writes, refused
  /// installs, a system that cannot update — well before a disk is actually
  /// full. This is the number that decides whether a feature about smooth
  /// scrubbing is allowed to cost somebody their photo storage.
  static const int floorBytes = 2 * 1024 * 1024 * 1024;

  static String? _dir;

  /// The directory to hand libmpv, or null when the disk cache must not be
  /// used — no space, or no writable temporary directory at all.
  ///
  /// Recomputed per playback rather than cached: free space is exactly the
  /// kind of fact that changes between one film and the next.
  static Future<String?> pathIfSpaceAllows() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory(p.join(base.path, 'stream_cache'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _dir = dir.path;

      final free = await _freeBytes(dir.path);
      // A failed measurement is NOT permission. `-1` means the platform did
      // not answer, and a feature that can fill a disk does not get to
      // proceed on an unanswered question.
      if (free < floorBytes) {
        if (kDebugMode) {
          debugPrint('disk cache off: ${free ~/ (1024 * 1024)} MB free');
        }
        return null;
      }
      return dir.path;
    } catch (e) {
      if (kDebugMode) debugPrint('DiskCacheDir: $e');
      return null;
    }
  }

  /// Sweep anything a previous run left behind.
  ///
  /// SHOULD BE EMPTY AND MIGHT NOT BE. The files are unlinked at creation,
  /// so a normal run — and even a crash — leaves nothing. What this catches
  /// is the platform's exceptions to that: a process killed in a way that
  /// skips the unlink, or a future mpv whose default changes. Called once at
  /// start-up, where a stray gigabyte is worth one directory listing.
  static Future<void> sweep() async {
    try {
      final base = await getTemporaryDirectory();
      final dir = Directory(p.join(base.path, 'stream_cache'));
      if (!await dir.exists()) return;
      await for (final f in dir.list()) {
        try {
          await f.delete(recursive: true);
        } catch (_) {
          // One file that will not go is not a reason to abandon the rest.
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('DiskCacheDir.sweep: $e');
    }
  }

  /// The same native channel the vault and the Wi-Fi receiver already use to
  /// ask how much room is left. Returns -1 when the platform does not answer.
  static Future<int> _freeBytes(String dir) async {
    try {
      final v = await const MethodChannel('mx_clone/media_scan')
          .invokeMethod<int>('freeBytes', <String, dynamic>{'dir': dir});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('DiskCacheDir.freeBytes: $e');
      return -1;
    }
  }
}
