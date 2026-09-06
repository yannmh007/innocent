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
/// `content://` handoff — that is step 4.
///
/// THIS CLASS DOES NOT DECIDE WHETHER A DOWNLOAD MAY START. It is the worker;
/// [UpdateDownloadNotifier] is the owner. Calling [download] twice
/// concurrently for the same release would put two writers on one `.part` and
/// corrupt it — which is exactly the bug that produced a 100% hash failure on
/// a real phone. The controller guarantees one caller at a time; nothing else
/// may call this directly.
///
/// Nothing in the transport is new. Every mechanism is the one the project
/// already proved on a device:
///
///   * `.part` sidecar renamed only on success — `PosterCache` and
///     `FileReceiverService` both do this.
///   * `Range: bytes=N-` resume, `FileMode.append` on a 206 and
///     `FileMode.write` on a 200 — from `DownloadEngine._runSequential` in
///     `download_isolate.dart`, including the reason it uses `addStream`.
///   * Free space before the first byte — `PrivateFolderService`, the same
///     64 MB headroom the vault and the receiver use.
///   * `TransferForegroundService` for the notification, unchanged.
class UpdateDownloadService {
  const UpdateDownloadService({
    this.downloadDirOverride,
    this.httpClientFactory,
  });

  /// Test seam. Null in the app, where the directory is the app cache dir.
  ///
  /// Only here so a test can drive the real transport against a temp
  /// directory without `path_provider`. Nothing in the app passes it.
  final Future<Directory> Function()? downloadDirOverride;

  /// Test seam. Null in the app, which builds its own client.
  ///
  /// Exists because [AppRelease.canDownload] requires an `https` URL and that
  /// requirement is NOT relaxed for tests: the test therefore serves real TLS
  /// from a loopback socket with a self-signed certificate, and needs a client
  /// that will accept it. Weakening the scheme check instead would have made
  /// the test easy and the product worse.
  final HttpClient Function()? httpClientFactory;

  /// Matches the vault and the receiver. A volume driven to exactly zero
  /// misbehaves in ways that have nothing to do with this app.
  static const int _headroomBytes = 64 * 1024 * 1024;

  /// Read in 1 MB slices while hashing. Big enough that an 88 MB file is ~88
  /// reads, small enough that the buffer never shows up in a memory profile.
  static const int _hashChunkBytes = 1024 * 1024;

  /// A whole download is re-fetched from zero at most this many times. The
  /// second pass exists for the "finished file is the wrong size" case in
  /// [download]; a third would just be burning someone's data bundle.
  static const int _maxAttempts = 2;

  /// Where the APK is written.
  ///
  /// The app cache directory, because it is the ONE root already exported by
  /// `android/app/src/main/res/xml/innocent_file_paths.xml`
  /// (`<cache-path name="innocent_cache" path="." />`). Step 4 has to hand
  /// this file to the package installer as a `content://` URI, and a file
  /// outside the provider's declared paths cannot be handed over at all.
  Future<Directory> _downloadDir() async {
    final override = downloadDirOverride;
    if (override != null) return override();
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'updates'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// The final name for [versionCode]: `innocent-<versionCode>.apk`.
  ///
  /// KEYED BY VERSION CODE, and that is load-bearing rather than cosmetic. It
  /// is what makes "the manifest published a new build" discard the right
  /// partial: the new version writes a different `.part`, so a half-fetched
  /// 320 can never be appended to and served as 321. The version name would
  /// not do — two builds may legitimately share one.
  static String fileNameFor(int versionCode) => 'innocent-$versionCode.apk';

  /// Matches `innocent-<digits>.apk` and `innocent-<digits>.apk.part`.
  static final RegExp _ourFile =
      RegExp(r'^innocent-(\d+)\.apk(\.part)?$');

  /// Download, verify, and return the finished file.
  ///
  /// WHAT SURVIVES A FAILURE, AND WHAT DOES NOT. §5 says to delete the partial
  /// on failure, and gives the reason: "a stale `.part` that a later resume
  /// appends to produces a hash mismatch that looks like tampering". Deleting
  /// every partial is one way to honour that. It is also the way that throws
  /// away 80 MB of an 88 MB download because a train went into a tunnel, on
  /// phones where that download is metered.
  ///
  /// So the danger is answered directly instead, and the bytes are kept:
  ///
  ///   * a resume sends `Range` from the CURRENT `.part` length and refuses to
  ///     append unless the server's 206 `Content-Range` names the same total
  ///     as `apk_bytes` — a re-published APK cannot be appended onto an old
  ///     partial, which is the "looks like tampering" case;
  ///   * the finished length is checked against `apk_bytes` BEFORE hashing;
  ///   * the `.part` is named by version code, so a new build never sees the
  ///     old build's partial.
  ///
  /// The partial is therefore deleted in exactly three places: a SHA-256
  /// mismatch on a complete file, a completed file of the wrong length, and a
  /// version change. A network drop or an app kill keeps it.
  ///
  /// [onProgress] reports received/total bytes and a smoothed bytes-per-second.
  /// [onVerifying] fires when the bytes are all down and the hash is about to
  /// be computed — hashing 88 MB is visible on a phone, and a screen still
  /// reading "Downloading 100%" during it looks stuck.
  /// [notificationTitle] and [notificationDone] are already localized: this
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
    // Re-asked here rather than trusted from the caller: a null URL would
    // otherwise become a confusing parse error several frames down.
    if (!release.canDownload) {
      throw const UpdateDownloadFailure.unsupported();
    }
    final url = release.apkUrl!;
    final expectedSha = release.apkSha256!;
    final expectedBytes = release.apkBytes ?? 0;

    final dir = await _downloadDir();
    final finalPath = p.join(dir.path, fileNameFor(release.versionCode));
    final part = File('$finalPath.part');

    // (b) THE VERSION CHANGED. Every partial and every finished APK belonging
    // to some other build is dead weight the moment this row names a new one,
    // and it is sitting in a cache directory the OS may be trying to reclaim.
    await _discardOtherVersions(dir, release.versionCode);

    // An already-verified download from a previous run. Re-verified rather
    // than trusted: it has sat in a cache directory that the OS, and any file
    // manager, may have touched since.
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
      for (var attempt = 1;; attempt++) {
        try {
          await _fetch(
            url: url,
            target: part,
            expectedTotal: expectedBytes,
            notificationTitle: notificationTitle,
            onProgress: onProgress,
          );
        } on _RestartDownload {
          // _fetch has already removed the unusable partial. Whatever it found
          // (a 416, or a Content-Range naming a different object) means the
          // bytes on disk cannot belong to the file being fetched.
          if (attempt >= _maxAttempts) {
            throw const UpdateDownloadFailure.damaged();
          }
          continue;
        }

        // THE 100%-FAILURE GATE. A file that is complete but the wrong length
        // is the signature of two writers having appended to one `.part` —
        // the bug this ownership rework exists to kill. Hashing it would
        // report "damaged", which is true but says nothing about the cause;
        // worse, appending further would grow it forever. Start over once.
        final actualBytes = await _sizeOf(part);
        if (expectedBytes > 0 && actualBytes != expectedBytes) {
          await _deleteQuietly(part);
          if (attempt >= _maxAttempts) {
            throw const UpdateDownloadFailure.damaged();
          }
          continue;
        }

        // (a) VERIFY BEFORE ANYTHING ELSE, on every path into this line — a
        // fresh download and a resumed one both land here. §5: "a resumed
        // download is exactly where a corrupt file comes from".
        onVerifying?.call();
        if (await _sha256OfFile(part) != expectedSha) {
          await _deleteQuietly(part);
          throw const UpdateDownloadFailure.damaged();
        }

        // Renamed only now. Until this line no file on disk carries an .apk
        // name, so nothing — not step 4, not a file manager — can install a
        // half-written one.
        final saved = await part.rename(finalPath);
        await TransferForegroundService.notifyDone(title: notificationDone);
        return saved;
      }
    } on UpdateDownloadFailure {
      rethrow;
    } on SocketException {
      // THE PARTIAL STAYS. This is the case resume exists for.
      throw const UpdateDownloadFailure.network();
    } on TimeoutException {
      throw const UpdateDownloadFailure.network();
    } on HttpException {
      throw const UpdateDownloadFailure.network();
    } catch (e) {
      if (kDebugMode) debugPrint('UpdateDownloadService.download: $e');
      throw const UpdateDownloadFailure.io();
    } finally {
      await TransferForegroundService.stop();
    }
  }

  /// How many bytes of [release] are already on disk, for a resumed UI.
  Future<int> bytesOnDisk(AppRelease release) async {
    if (kIsWeb) return 0;
    try {
      final dir = await _downloadDir();
      return _sizeOf(
        File(p.join(dir.path, '${fileNameFor(release.versionCode)}.part')),
      );
    } catch (_) {
      return 0;
    }
  }

  /// Delete every partial and finished APK that is not [keepVersionCode].
  ///
  /// Rule (b) of the delete policy. Files are matched by name, so nothing else
  /// living in the cache directory is touched.
  Future<void> _discardOtherVersions(Directory dir, int keepVersionCode) async {
    try {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = _ourFile.firstMatch(p.basename(entity.path));
        if (match == null) continue;
        if (int.tryParse(match.group(1)!) == keepVersionCode) continue;
        await _deleteQuietly(entity);
      }
    } catch (e) {
      // A directory we cannot list is not a reason to fail the download.
      if (kDebugMode) debugPrint('UpdateDownloadService.discard: $e');
    }
  }

  /// Refuse up front, with the two numbers, exactly as the vault does.
  ///
  /// The arithmetic is the plan's: "The APK needs its own size plus the
  /// installer's working room." So the ask is what is left to fetch, plus a
  /// second full copy for the installer to expand into at step 4, plus the
  /// project's usual headroom.
  ///
  /// THE PARTIAL SURVIVES A REFUSAL. It is not corrupt — nothing has been
  /// written yet — so it is not one of the three delete cases, and discarding
  /// it would make the next attempt strictly worse: the bytes come back but
  /// the ask grows by the same amount, because the check credits what is
  /// already fetched. 80 MB of an 88 MB download would be thrown away in
  /// order to ask for MORE space.
  Future<void> _refuseIfSpaceIsShort(AppRelease release, File part) async {
    final size = release.apkBytes ?? 0;
    if (size <= 0) return; // Nothing to reason about; the download self-limits.

    final onDisk = await _sizeOf(part);
    final remaining = size - onDisk;
    final needed = (remaining > 0 ? remaining : 0) + size + _headroomBytes;

    // The vault dir and this cache dir are both app-internal storage, so this
    // measures the volume actually written to. That is why the method used is
    // PrivateFolderService's rather than the receiver's, whose copy measures
    // public external storage — possibly another volume, and a reassuring
    // number about somewhere else is worse than no number.
    final free = await PrivateFolderService().freeSpaceBytes();

    // free < 0 means the platform would not say. Proceeding is right: refusing
    // on an unknown would block every update on any device whose answer we
    // cannot read.
    if (free >= 0 && free < needed) {
      throw UpdateDownloadFailure.noSpace(needed: needed, free: free);
    }
  }

  /// One resumable GET into [target], appending to whatever is already there.
  ///
  /// Throws [_RestartDownload] — after removing the partial — when the bytes
  /// on disk provably do not belong to the object the server is serving.
  Future<void> _fetch({
    required String url,
    required File target,
    required int expectedTotal,
    required String notificationTitle,
    void Function(int received, int total, double bytesPerSec)? onProgress,
  }) async {
    var existing = await _sizeOf(target);

    // A partial longer than the finished file can ever be cannot be resumed.
    if (expectedTotal > 0 && existing > expectedTotal) {
      await _deleteQuietly(target);
      existing = 0;
    }

    final client = (httpClientFactory?.call() ?? HttpClient())
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
        await resp.drain<void>();
        // 416: our partial is longer than the object now at this URL, so the
        // APK was re-published under the same name. The partial is not
        // resumable and never will be.
        if (resp.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          await _deleteQuietly(target);
          throw const _RestartDownload();
        }
        throw UpdateDownloadFailure.server(resp.statusCode);
      }

      final serverResumed = resp.statusCode == HttpStatus.partialContent;

      // VALIDATE CONTENT-RANGE BEFORE A SINGLE BYTE IS APPENDED. `Content-
      // Range: bytes 80000000-87999999/88000000` names the total size of the
      // object being served. If that total is not the `apk_bytes` the manifest
      // promised, the bytes already on disk belong to some other file and
      // appending would splice two different APKs into one — the exact shape
      // of corruption that reads as tampering when the hash finally fails.
      if (serverResumed && expectedTotal > 0) {
        final servedTotal = _totalFromContentRange(
          resp.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (servedTotal != null && servedTotal != expectedTotal) {
          await resp.drain<void>();
          await _deleteQuietly(target);
          throw const _RestartDownload();
        }
      }

      // A 200 in reply to a Range request means the server ignored it — R2
      // honours ranges, but a proxy in front of it may not. Truncate and
      // refetch rather than appending a second copy onto the first.
      final startAt = serverResumed ? existing : 0;

      // The `expectedTotal - existing` fallback is not decoration. A 206 with
      // no Content-Length would otherwise make total == existing, so
      // `received` would run past it and the truncation guard below would
      // reject a PERFECTLY GOOD resumed download as incomplete. The receiver's
      // engine carries the same fallback for the same reason.
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
      // partial stays: this is precisely what the next resume continues from.
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

  /// The `N` in `bytes 0-1/N`, or null when the header is absent or unparsable
  /// (including the legal `bytes 0-1/*`, which names no total).
  static int? _totalFromContentRange(String? header) {
    if (header == null) return null;
    final slash = header.lastIndexOf('/');
    if (slash < 0 || slash + 1 >= header.length) return null;
    return int.tryParse(header.substring(slash + 1).trim());
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

/// Internal signal: the partial has been removed, fetch the whole file again.
///
/// Never escapes [UpdateDownloadService.download] — the loop there either
/// retries or converts it into a `damaged` failure the screen has words for.
class _RestartDownload implements Exception {
  const _RestartDownload();
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

  /// True when waiting for the network and trying again is the whole fix.
  ///
  /// Drives auto-resume: the controller re-arms itself on these and on
  /// nothing else. A `damaged` file or a full disk does not get better
  /// because Wi-Fi came back.
  bool get isTransient =>
      kind == UpdateDownloadFailureKind.network ||
      kind == UpdateDownloadFailureKind.server;

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
