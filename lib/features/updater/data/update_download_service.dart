import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/services/file_transfer/transfer_foreground_service.dart';
import '../../../core/services/private_folder/private_folder_service.dart';
import '../domain/app_release.dart';

/// Downloads the APK named by one `app_releases` row, and proves it arrived
/// intact. Step 3 of `docs/updater_plan.md` §5.
///
/// IT STOPS AT "DOWNLOADED". No install intent, no package installer, no
/// `content://` handoff — that is step 4, deliberately a separate change, so
/// that the half that writes a file to disk can be reviewed and tested on a
/// real phone without the half that hands a file to Android.
///
/// Nothing here is new. Every mechanism is the one the project already uses:
///
///   * `.part` sidecar renamed only on success — `PosterCache` (a poster) and
///     `FileReceiverService` (a 4 GB video) both do exactly this.
///   * `Range: bytes=N-` resume, `FileMode.append` on a 206 and
///     `FileMode.write` on a 200 — lifted from `DownloadEngine._runSequential`
///     in `download_isolate.dart`, including the reason it uses `addStream`.
///   * Free space before the first byte — `PrivateFolderService`, the same
///     64 MB headroom the vault and the receiver use.
///   * `TransferForegroundService` for the notification, unchanged.
///
/// A NEW DOWNLOADER WOULD BE THE WRONG THING TO WRITE. Each of those pieces
/// exists because a specific failure happened on a real device; a second
/// implementation would have to rediscover all of them.
class UpdateDownloadService {
  const UpdateDownloadService();

  /// Matches the vault and the receiver. A volume driven to exactly zero
  /// misbehaves in ways that have nothing to do with this app.
  static const int _headroomBytes = 64 * 1024 * 1024;

  /// Read in 1 MB slices while hashing. Big enough that an 88 MB file is ~88
  /// reads, small enough that the buffer never shows up in a memory profile.
  static const int _hashChunkBytes = 1024 * 1024;

  /// Where the APK is written.
  ///
  /// The app cache directory, because it is the ONE root already exported by
  /// `android/app/src/main/res/xml/innocent_file_paths.xml`
  /// (`<cache-path name="innocent_cache" path="." />`). Step 4 has to hand
  /// this file to the package installer as a `content://` URI, and a file
  /// outside the provider's declared paths cannot be handed over at all.
  /// Downloading somewhere else now would mean either moving the file later
  /// or widening the provider — and a provider that exports more than it must
  /// is an app-wide read primitive for anything that can reach it.
  static Future<Directory> _downloadDir() async {
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'updates'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// The final name for [release]. Keyed by version code, never by version
  /// name: the code is the thing the updater compares, and two builds can
  /// legitimately share a name.
  static String _fileName(AppRelease release) =>
      'innocent-${release.versionCode}.apk';

  /// Download, verify, and return the finished file.
  ///
  /// Throws [UpdateDownloadFailure] for everything the screen has a sentence
  /// for. On ANY failure the partial file is deleted before the throw: the
  /// plan is explicit that a stale `.part` which a later resume appends to
  /// produces a hash mismatch that looks like tampering.
  ///
  /// [onProgress] reports received/total bytes and a smoothed bytes-per-second.
  /// [onVerifying] fires once, when the bytes are all down and the hash is
  /// about to be computed — hashing 88 MB is visible on a phone, and a screen
  /// that still says "Downloading 100%" during it looks stuck.
  /// [notificationTitle] and [notificationDone] are already localized — this
  /// layer has no `BuildContext` and must not acquire one.
  Future<File> download(
    AppRelease release, {
    required String notificationTitle,
    required String notificationDone,
    void Function(int received, int total, double bytesPerSec)? onProgress,
    void Function()? onVerifying,
  }) async {
    if (kIsWeb) {
      throw const UpdateDownloadFailure.unsupported();
    }
    // Re-asked here rather than trusted from the caller. This method is
    // reachable from anywhere, and a null URL would otherwise become a
    // confusing parse error several frames down.
    if (!release.canDownload) {
      throw const UpdateDownloadFailure.unsupported();
    }
    final url = release.apkUrl!;
    final expectedSha = release.apkSha256!;

    final dir = await _downloadDir();
    final finalPath = p.join(dir.path, _fileName(release));
    final partPath = '$finalPath.part';
    final part = File(partPath);

    // An already-verified download from a previous run. Re-verified rather
    // than trusted: it has been sitting in a cache directory that the OS, and
    // any file manager, may have touched since.
    final done = File(finalPath);
    if (await done.exists()) {
      onVerifying?.call();
      if (await _sha256OfFile(done) == expectedSha) return done;
      await _deleteQuietly(done);
    }

    await _refuseIfSpaceIsShort(release, part);

    await TransferForegroundService.start(
      title: notificationTitle,
      progress: 0,
    );
    try {
      await _fetch(
        url: url,
        target: part,
        expectedTotal: release.apkBytes ?? 0,
        notificationTitle: notificationTitle,
        onProgress: onProgress,
      );

      // VERIFY BEFORE ANYTHING ELSE, and on every path into this line —
      // a fresh download and a resumed one both land here. §5: "a resumed
      // download is exactly where a corrupt file comes from".
      onVerifying?.call();
      final actual = await _sha256OfFile(part);
      if (actual != expectedSha) {
        await _deleteQuietly(part);
        throw const UpdateDownloadFailure.damaged();
      }

      // Renamed only now. Until this line there is no file on disk with an
      // .apk name, so nothing — not step 4, not a file manager — can install
      // a half-written one.
      final saved = await part.rename(finalPath);
      await TransferForegroundService.notifyDone(title: notificationDone);
      return saved;
    } catch (e) {
      // Every failure leaves the disk as it was found.
      await _deleteQuietly(part);
      if (e is UpdateDownloadFailure) rethrow;
      if (e is SocketException || e is TimeoutException || e is HttpException) {
        throw const UpdateDownloadFailure.network();
      }
      if (kDebugMode) debugPrint('UpdateDownloadService.download: $e');
      throw const UpdateDownloadFailure.io();
    } finally {
      await TransferForegroundService.stop();
    }
  }

  /// Refuse up front, with the two numbers, exactly as the vault does — and
  /// take any partial file down with the refusal.
  ///
  /// The arithmetic is the plan's: "The APK needs its own size plus the
  /// installer's working room." So the ask is what is left to fetch, plus a
  /// second full copy for the installer to expand into at step 4, plus the
  /// project's usual headroom. Refusing now costs a sentence; running out at
  /// 80 MB of 88 costs the whole download and, on a metered bundle, real
  /// money.
  ///
  /// A REFUSAL DELETES THE `.part`, and the cost of that is accepted
  /// deliberately: the fetched bytes are thrown away, so the next attempt
  /// starts from zero. §5 asks for the partial to be deleted on failure and
  /// gives the reason — "a stale `.part` that a later resume appends to
  /// produces a hash mismatch that looks like tampering". That rule is worth
  /// more than the progress, because the file this rule protects is the one
  /// that gets handed to the package installer. A partial left behind here
  /// also sits on the very volume the user has just been told is full.
  Future<void> _refuseIfSpaceIsShort(AppRelease release, File part) async {
    final size = release.apkBytes ?? 0;
    if (size <= 0) return; // Nothing to reason about; the download self-limits.

    final onDisk = await _sizeOf(part);
    final remaining = size - onDisk;
    final needed = (remaining > 0 ? remaining : 0) + size + _headroomBytes;

    // The vault dir and this cache dir are both app-internal storage, so this
    // measures the volume actually written to. That is the whole point of the
    // method living on PrivateFolderService rather than on the receiver,
    // whose copy measures public external storage — possibly another volume,
    // and a reassuring number about somewhere else is worse than no number.
    // Constructing the service is cheap (a plain constructor; the app gets it
    // from a provider elsewhere). Its `_vaultDir()` creates an empty
    // `private_vault` folder in app-support as a side effect, which is
    // invisible, app-internal and harmless — worth knowing about, not worth a
    // second copy of the free-space channel call to avoid.
    final free = await PrivateFolderService().freeSpaceBytes();

    // free < 0 means the platform would not say. Proceeding is right: refusing
    // on an unknown would block every update on any device whose answer we
    // cannot read.
    if (free >= 0 && free < needed) {
      // Same rule as every failure inside the download: nothing partial
      // survives a failure. See this method's doc for why the lost progress
      // is the right trade.
      await _deleteQuietly(part);
      final reclaimed = onDisk - await _sizeOf(part);

      // The numbers reported describe the NEXT attempt, not the one just
      // refused. The partial is gone, so that attempt re-fetches the whole
      // APK, and the bytes it occupied are back on the volume. Quoting the
      // pre-deletion figures would send someone to free exactly `needed` and
      // then refuse them a second time with a larger number — the check would
      // no longer have a partial to credit. `reclaimed` is measured rather
      // than assumed, because _deleteQuietly swallows a failed delete and the
      // sentence must not claim space that is still occupied.
      throw UpdateDownloadFailure.noSpace(
        needed: size + size + _headroomBytes,
        free: free + reclaimed,
      );
    }
  }

  /// One resumable GET into [target].
  ///
  /// Follows `DownloadEngine._runSequential`. The comments that explain WHY
  /// each line is shaped this way live there; the ones repeated here are the
  /// ones that would otherwise look like they could be simplified away.
  Future<void> _fetch({
    required String url,
    required File target,
    required int expectedTotal,
    required String notificationTitle,
    void Function(int received, int total, double bytesPerSec)? onProgress,
  }) async {
    var existing = await _sizeOf(target);

    // A .part longer than the finished file can ever be is garbage from an
    // interrupted write or a re-published APK. Appending to it would produce
    // a hash mismatch that reads as tampering, so it goes.
    if (expectedTotal > 0 && existing > expectedTotal) {
      await _deleteQuietly(target);
      existing = 0;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 40);
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse(url));
      if (existing > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      final resp = await req.close();

      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        // A 416 means our .part is longer than the object now on the server —
        // the APK was re-published under the same URL. Starting over is the
        // only correct answer, and the caller's retry will do it.
        if (resp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          await resp.drain<void>();
          await _deleteQuietly(target);
          throw const UpdateDownloadFailure.damaged();
        }
        await resp.drain<void>();
        throw UpdateDownloadFailure.server(resp.statusCode);
      }

      // 200 to a Range request means the server ignored it — R2 honours
      // ranges, but a proxy in front of it may not. Truncate and refetch
      // rather than appending a second copy of the whole file onto the first.
      final serverResumed = resp.statusCode == HttpStatus.partialContent;
      final startAt = serverResumed ? existing : 0;

      // The `expectedTotal - existing` fallback is not decoration. A 206 with
      // no Content-Length would otherwise make total == existing, so `received`
      // would run past it and the truncation guard below would reject a
      // PERFECTLY GOOD download as incomplete. The receiver's engine carries
      // the same fallback for the same reason.
      final total = serverResumed
          ? existing +
              (resp.contentLength > 0
                  ? resp.contentLength
                  : (expectedTotal - existing))
          : (resp.contentLength > 0 ? resp.contentLength : expectedTotal);

      sink = target.openWrite(
        mode: serverResumed ? FileMode.append : FileMode.write,
      );

      var received = startAt;
      var lastTick = DateTime.now();
      var lastReported = received;
      var speed = 0.0;
      var lastNotified = -1;

      // addStream rather than a manual loop with sink.add: IOSink.add applies
      // NO back-pressure, so when the link outruns the flash write the
      // unwritten chunks pile up in RAM until the OS kills us. (The receiver
      // learned this the same way.)
      final counted = resp.map((chunk) {
        received += chunk.length;
        final now = DateTime.now();
        final ms = now.difference(lastTick).inMilliseconds;
        if (ms >= 120) {
          final instant = (received - lastReported) * 1000 / ms;
          speed = speed == 0 ? instant : (speed * 0.4 + instant * 0.6);
          onProgress?.call(received, total, speed);
          if (total > 0) {
            final percent = (received * 100 / total).clamp(0, 100).round();
            if (percent != lastNotified) {
              lastNotified = percent;
              // Not awaited: a MethodChannel round trip per notification tick
              // would throttle the download to the speed of the UI thread.
              unawaited(TransferForegroundService.update(
                title: notificationTitle,
                progress: percent,
              ));
            }
          }
          lastReported = received;
          lastTick = now;
        }
        return chunk;
      });

      await sink.addStream(counted);
      onProgress?.call(received, total, speed);
      await sink.flush();
      await sink.close();
      sink = null;

      // A dropped link can end the response stream early WITHOUT throwing, so
      // a byte-count mismatch is the only way to notice a truncated file. The
      // hash would catch it too, but only after hashing 88 MB to say so.
      if (total > 0 && received != total) {
        throw const UpdateDownloadFailure.network();
      }
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
      client.close(force: true);
    }
  }

  /// Lowercase hex SHA-256 of [file], hashed in slices.
  ///
  /// Streamed, not `sha256.convert(await file.readAsBytes())`: the second form
  /// holds the whole APK in memory, and 88 MB of it is exactly the allocation
  /// a mid-range phone refuses.
  ///
  /// `ChunkedConversionSink.withCallback` comes from `dart:convert`, so this
  /// needs no dependency on `package:convert` — which is only in the lockfile
  /// transitively, through `crypto`.
  static Future<String> _sha256OfFile(File file) async {
    Digest? digest;
    final sink = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback(
        (accumulated) => digest = accumulated.single,
      ),
    );
    final handle = await file.open();
    try {
      while (true) {
        final chunk = await handle.read(_hashChunkBytes);
        if (chunk.isEmpty) break;
        sink.add(chunk);
      }
    } finally {
      await handle.close();
    }
    sink.close();
    final result = digest;
    if (result == null) return '';
    return result.toString().toLowerCase();
  }

  static Future<int> _sizeOf(File f) async {
    try {
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<void> _deleteQuietly(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {
      // A file we cannot delete is not a reason to fail differently; the next
      // attempt re-verifies whatever is there anyway.
    }
  }
}

/// Why a download could not be completed.
///
/// One case per sentence the user is shown, and no server text carried along:
/// `docs/updater_plan.md` §6 fixes those sentences, and none of them quote a
/// status code at the reader.
class UpdateDownloadFailure implements Exception {
  const UpdateDownloadFailure.unsupported()
      : kind = UpdateDownloadFailureKind.unsupported,
        statusCode = null,
        neededBytes = null,
        freeBytes = null;
  const UpdateDownloadFailure.network()
      : kind = UpdateDownloadFailureKind.network,
        statusCode = null,
        neededBytes = null,
        freeBytes = null;
  const UpdateDownloadFailure.server(this.statusCode)
      : kind = UpdateDownloadFailureKind.server,
        neededBytes = null,
        freeBytes = null;
  const UpdateDownloadFailure.damaged()
      : kind = UpdateDownloadFailureKind.damaged,
        statusCode = null,
        neededBytes = null,
        freeBytes = null;
  const UpdateDownloadFailure.io()
      : kind = UpdateDownloadFailureKind.io,
        statusCode = null,
        neededBytes = null,
        freeBytes = null;
  const UpdateDownloadFailure.noSpace({
    required int needed,
    required int free,
  })  : kind = UpdateDownloadFailureKind.noSpace,
        statusCode = null,
        neededBytes = needed,
        freeBytes = free;

  final UpdateDownloadFailureKind kind;
  final int? statusCode;

  /// Set only for [UpdateDownloadFailureKind.noSpace]: the two numbers the
  /// vault shows, so the screen can say "need X, have Y" rather than "no".
  final int? neededBytes;
  final int? freeBytes;

  @override
  String toString() => 'UpdateDownloadFailure(${kind.name}, $statusCode)';
}

enum UpdateDownloadFailureKind {
  /// No APK published, or not a platform that can install one.
  unsupported,
  network,
  server,

  /// The bytes on disk are not the bytes that were published.
  ///
  /// Shown as "Download was damaged. Try again." and never as anything with
  /// the word "verification" in it — §6: that reads as an accusation.
  damaged,
  noSpace,
  io,
}
