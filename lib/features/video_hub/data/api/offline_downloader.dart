import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../../domain/access.dart';
import '../../domain/content_repository.dart';
import '../../domain/video_content.dart';
import 'offline_library.dart';

/// Where one download has got to.
@immutable
class OfflineProgress {
  final String titleId;
  final int received;
  final int? total;
  final bool done;

  /// Set when the download stopped and will not continue on its own.
  final String? error;

  const OfflineProgress({
    required this.titleId,
    this.received = 0,
    this.total,
    this.done = false,
    this.error,
  });

  /// 0..1, or null while the size is unknown.
  ///
  /// Null rather than 0: a progress bar pinned at zero for the first minute
  /// of a download that IS running reads as a stall, while an indeterminate
  /// bar reads as work.
  double? get fraction {
    final t = total;
    if (t == null || t <= 0) return null;
    return (received / t).clamp(0.0, 1.0);
  }
}

/// Fetches a catalogue title onto the device.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE PROBLEM THIS EXISTS TO SOLVE
/// ═══════════════════════════════════════════════════════════════════════
///
/// A signed R2 URL lives about ten minutes. A 900 MB film on a Myanmar mobile
/// connection takes considerably longer than that. So the naive version — ask
/// for a URL, GET it, write the bytes — fails part-way through EVERY large
/// download, and fails in the least helpful way available: the connection
/// simply ends, and what is on disk is a truncated file that looks finished.
///
/// The fix is the one `StreamRenewal` already uses for playback, applied to a
/// download: never hold a URL, hold the ABILITY TO ASK FOR ONE. When a
/// transfer dies, request a fresh URL and resume with a `Range` header from
/// the byte already on disk.
///
/// THE RENEWAL IS ALSO A RE-AUTHORISATION, and that is a feature rather than
/// an accident. Every renewal goes back through `requestPlayback`, which
/// re-checks the subscription, the tier and the device binding — so a
/// subscription that lapses forty minutes into a download stops the download.
/// There is deliberately no path in this class that produces a URL on its
/// own: not a cache, not a fallback, not a retry with different arguments.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT THE FINISHED FILE IS
/// ═══════════════════════════════════════════════════════════════════════
///
/// A plain file in app-private storage. See the note on [OfflineLibrary] —
/// this is decision B1(a), and it is friction rather than enforcement. Saying
/// so is part of shipping it.
class OfflineDownloader {
  OfflineDownloader(
    this._repo,
    this._library, {
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final ContentRepository _repo;
  final OfflineLibrary _library;
  final http.Client _http;

  /// How many times a stalled transfer is resumed before giving up.
  ///
  /// Generous, because each attempt makes REAL PROGRESS: the range request
  /// starts from what is already on disk, so ten attempts on a flaky train
  /// journey is ten stretches of download, not ten restarts. It is bounded
  /// only so a permanently broken URL cannot spin forever.
  static const int maxResumes = 20;

  final Map<String, StreamController<OfflineProgress>> _streams =
      <String, StreamController<OfflineProgress>>{};
  final Set<String> _cancelled = <String>{};

  /// True while this title is being fetched.
  bool isRunning(String titleId) => _streams.containsKey(titleId);

  /// Progress for a running download, or null when none is running.
  Stream<OfflineProgress>? watch(String titleId) => _streams[titleId]?.stream;

  /// Asks for the download to stop. The partial file is KEPT, so starting
  /// again resumes rather than restarts.
  void cancel(String titleId) => _cancelled.add(titleId);

  /// Fetches [content] to disk.
  ///
  /// Returns the finished item, or null if it was cancelled or failed. Never
  /// throws: a download is something a user starts and walks away from, and
  /// an exception surfacing minutes later has nowhere useful to go.
  Future<OfflineItem?> download({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
    String? assetId,
  }) async {
    final titleId = content.id;
    if (_streams.containsKey(titleId)) return null;

    final controller = StreamController<OfflineProgress>.broadcast();
    _streams[titleId] = controller;
    _cancelled.remove(titleId);

    try {
      return await _run(
        content: content,
        source: source,
        deviceId: deviceId,
        assetId: assetId,
        emit: controller.add,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('offline download failed: $e');
      controller.add(OfflineProgress(titleId: titleId, error: '$e'));
      return null;
    } finally {
      await controller.close();
      _streams.remove(titleId);
      _cancelled.remove(titleId);
    }
  }

  Future<OfflineItem?> _run({
    required VideoContent content,
    required MediaRef source,
    required String? deviceId,
    required String? assetId,
    required void Function(OfflineProgress) emit,
  }) async {
    final titleId = content.id;
    final dir = await _library.directory();
    // Named by the TITLE ID, not by the title. A name is operator-entered
    // text that can contain anything a path cannot, and two titles can share
    // one; an id is a uuid and is unique by construction.
    final finalPath = '${dir.path}/$titleId.mp4';
    final partPath = '$finalPath${OfflineLibrary.partSuffix}';
    final part = File(partPath);

    var received = await part.exists() ? await part.length() : 0;
    int? total;

    for (var attempt = 0; attempt <= maxResumes; attempt++) {
      if (_cancelled.contains(titleId)) return null;

      // A FRESH URL EVERY ATTEMPT, and a fresh entitlement check with it.
      final grant = await _repo.requestPlayback(
        content: content,
        source: source,
        deviceId: deviceId,
      );
      if (!grant.isGranted) {
        emit(OfflineProgress(
          titleId: titleId,
          received: received,
          total: total,
          // The denial reason, not a generic failure: a lapsed subscription
          // and a dead network want completely different sentences, and only
          // one of them is the user's to fix.
          error: 'denied:${grant.denial?.name ?? 'unknown'}',
        ));
        return null;
      }

      final request = http.Request('GET', Uri.parse(grant.url!));
      if (received > 0) {
        // Resume. A server that ignores this answers 200 with the whole file,
        // which is handled below by starting the file over rather than
        // appending a second copy to the first.
        request.headers['Range'] = 'bytes=$received-';
      }

      http.StreamedResponse response;
      try {
        response = await _http.send(request);
      } catch (e) {
        if (kDebugMode) debugPrint('offline attempt ${attempt + 1}: $e');
        continue;
      }

      final resumed = response.statusCode == 206;
      if (response.statusCode == 200) {
        // Range ignored, or a first attempt. Whatever is on disk is not part
        // of THIS response, so it has to go — appending would produce a file
        // that is longer than the film and plays as garbage after the seam.
        received = 0;
        if (await part.exists()) await part.delete();
      } else if (!resumed) {
        if (kDebugMode) {
          debugPrint('offline attempt ${attempt + 1}: HTTP ${response.statusCode}');
        }
        continue;
      }

      final reported = response.contentLength;
      if (reported != null) total = received + reported;

      final sink = part.openWrite(mode: FileMode.append);
      var broke = false;
      try {
        await for (final chunk in response.stream) {
          if (_cancelled.contains(titleId)) {
            broke = true;
            break;
          }
          sink.add(chunk);
          received += chunk.length;
          emit(OfflineProgress(
            titleId: titleId,
            received: received,
            total: total,
          ));
        }
      } catch (e) {
        // The expected failure, not an exceptional one: this is what a signed
        // URL expiring mid-transfer looks like from here. The loop asks for a
        // new one and carries on from the byte it reached.
        broke = true;
        if (kDebugMode) debugPrint('offline stream broke at $received: $e');
      } finally {
        await sink.flush();
        await sink.close();
      }

      if (_cancelled.contains(titleId)) return null;

      // DONE ONLY WHEN THE LENGTH MATCHES. A stream that ends early without
      // throwing is indistinguishable from a finished one except by this
      // check, and "downloaded" is a promise the app makes offline, where it
      // cannot go back and look.
      if (!broke && total != null && received >= total) {
        return _finish(
          content: content,
          assetId: assetId,
          part: part,
          finalPath: finalPath,
          bytes: received,
          emit: emit,
        );
      }
      if (!broke && total == null && received > 0) {
        // No Content-Length at all — the transfer ended cleanly and there is
        // nothing to compare against. Accepting it is the only option that
        // does not discard a complete download, and it is why the check above
        // is preferred whenever a length exists.
        return _finish(
          content: content,
          assetId: assetId,
          part: part,
          finalPath: finalPath,
          bytes: received,
          emit: emit,
        );
      }
    }

    emit(OfflineProgress(
      titleId: titleId,
      received: received,
      total: total,
      error: 'gave_up',
    ));
    return null;
  }

  Future<OfflineItem> _finish({
    required VideoContent content,
    required String? assetId,
    required File part,
    required String finalPath,
    required int bytes,
    required void Function(OfflineProgress) emit,
  }) async {
    // RENAME LAST. Until this line there is only a `.part` file, which no
    // reader trusts; after it there is a finished file AND an index entry.
    // A crash between the two leaves a file with no entry, which the next
    // `dropAll` sweeps — far better than an entry with no file, which is a
    // row that spins forever when tapped.
    await part.rename(finalPath);

    final item = OfflineItem(
      titleId: content.id,
      title: content.title,
      titleMm: content.titleMm,
      posterUrl: content.poster.isEmpty ? null : content.poster.locator,
      path: finalPath,
      bytes: bytes,
      addedAt: DateTime.now(),
      assetId: assetId,
    );
    await _library.put(item);
    emit(OfflineProgress(
      titleId: content.id,
      received: bytes,
      total: bytes,
      done: true,
    ));
    return item;
  }
}
