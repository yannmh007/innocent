import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../../core/services/offline/offline_service_bridge.dart';
import '../../domain/access.dart';
import '../../domain/content_repository.dart';
import '../../domain/video_content.dart';
import 'download_plan.dart';
import 'offline_library.dart';

/// Where one download has got to.
@immutable
class OfflineProgress {
  final String titleId;
  final int received;
  final int? total;
  final bool done;

  /// True while this title is waiting for another download to finish.
  ///
  /// Two films downloading at once over one bad connection finish LATER than
  /// the same two in sequence, and neither is watchable meanwhile. The queue
  /// is the right behaviour and it has to be visible, or a viewer who tapped
  /// Download and sees nothing move will tap it again.
  final bool queued;

  /// Set when the download stopped and will not continue on its own.
  final String? error;

  const OfflineProgress({
    required this.titleId,
    this.received = 0,
    this.total,
    this.done = false,
    this.queued = false,
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

/// The two sentences a download puts in the notification shade.
///
/// PASSED IN, BECAUSE THIS CLASS CANNOT READ THE STRING TABLE. It has no
/// `BuildContext` and should not have one — but the people this feature was
/// built for read Burmese, and a notification is the only part of a download
/// they see while it runs. An English default is here so a caller that forgets
/// still produces something, not so anyone relies on it.
///
/// The progress line itself ("412 MB / 900 MB") is deliberately not in here:
/// it is numerals and a unit, which read the same in every language this app
/// speaks.
@immutable
class DownloadNotices {
  final String waiting;
  final String ready;

  const DownloadNotices({required this.waiting, required this.ready});

  static const DownloadNotices english = DownloadNotices(
    waiting: 'Waiting for the connection…',
    ready: 'Ready to watch offline',
  );
}

/// Fetches a catalogue title onto the device, at the quality it was uploaded.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE ONE THING THIS MUST NOT DO
/// ═══════════════════════════════════════════════════════════════════════
///
/// It must not download a rung. The transcode ladder exists so that STREAMING
/// can be matched to a connection second by second — a viewer on a weak link
/// gets a smaller copy rather than a film that stops. A download is the
/// opposite situation: the whole point of waiting is to end up with the film
/// as it was uploaded, and a viewer who waited two hours for a 480p copy of a
/// 4K master has been robbed of the only thing the wait was buying.
///
/// So this uses `grant.url`, which the playback endpoint signs from the
/// ORIGINAL object key, and never touches `grant.renditions`. That is not an
/// accident of the code that can be tidied away later: the ladder and the
/// original are two different answers to two different questions, and this
/// class is on the side that wants the original. (`tool/check.py` has a
/// structural check that says so, so a later refactor cannot quietly swap it.)
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

  /// CONSECUTIVE failures tolerated before giving up, not total attempts.
  ///
  /// ─── THE BUG THIS NUMBER USED TO CARRY ───────────────────────────────
  ///
  /// It was a total budget of twenty, spent with no delay between attempts.
  /// A film that legitimately needed thirty resumes over two hours — which on
  /// the connection this feature exists for is an ORDINARY download, not a bad
  /// one — ran out of budget while making steady progress, and a ten-second
  /// tunnel burned all twenty in about a second.
  ///
  /// Counting only consecutive failures makes the budget mean what it was
  /// always meant to mean: "this is not coming back". Forty of them, with
  /// [retryDelay]'s backoff, is roughly half an hour of patience before the
  /// download stops asking — and any byte of progress resets it, so a
  /// download that is moving is never given up on.
  static const int maxConsecutiveFailures = 40;

  /// Bytes a single attempt must deliver to count as PROGRESS.
  ///
  /// The give-up budget resets when an attempt gets somewhere, which is what
  /// lets an ordinary two-hour download survive thirty interruptions. Reset on
  /// ANY number of bytes and the loop never ends: a server that delivers one
  /// byte and dies would be retried for ever, spending data on a download that
  /// is not advancing. A quarter of a megabyte separates a transfer that was
  /// running from a handshake that fell over — even a dreadful link clears it
  /// long before a signed URL's ten minutes are up.
  static const int _realProgress = 256 * 1024;

  /// Absolute ceiling on attempts for one download, whatever the progress.
  ///
  /// A backstop rather than a policy: the consecutive-failure budget above is
  /// what normally stops a download, and this only guarantees the loop
  /// terminates. Five hundred attempts is far more than any real film needs.
  static const int maxAttempts = 500;

  /// Re-check free space this often while writing.
  ///
  /// The check before the first byte cannot be the only one: another app, or
  /// this one's own stream cache, can fill the disk during the hour a film
  /// takes. Every 32 MB is a `stat` per few seconds at best and stops the
  /// download a long way before the phone becomes unusable.
  static const int _spaceCheckEvery = 32 * 1024 * 1024;

  final Map<String, StreamController<OfflineProgress>> _streams =
      <String, StreamController<OfflineProgress>>{};
  final Set<String> _cancelled = <String>{};

  /// ONE TRANSFER AT A TIME, and the queue is the point.
  ///
  /// Two downloads sharing a 1 Mbps link each go at half speed, so BOTH films
  /// are unwatchable for twice as long as the first one needed to be. In
  /// sequence, the first is watchable in half the time and the second finishes
  /// at the same moment it would have anyway. On a fast connection the
  /// difference is nothing; on the connection this feature is for it is the
  /// difference between having something to watch tonight and not.
  Future<void> _chain = Future<void>.value();

  /// True while this title is being fetched or waiting its turn.
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
  /// [onProgress] is for the caller that STARTS the download.
  ///
  /// ─── THE BUG IT FIXES ────────────────────────────────────────────────
  ///
  /// The button used to ask [watch] for a stream immediately BEFORE calling
  /// this — at which point no stream exists, because this method is what
  /// creates it — so the answer was always null and the download it had just
  /// started reported nothing. Tapping Download did visibly nothing for an
  /// hour, and the only way to see progress was to leave the screen and come
  /// back, which re-attached through [watch] and worked. On a feature whose
  /// whole job takes an hour, that is the difference between a working button
  /// and a broken one.
  ///
  /// A callback rather than fixing the call order, because the order that
  /// worked depended on this method's first `await` landing after the stream
  /// was registered. That is true today and is exactly the kind of thing a
  /// later edit breaks silently. [watch] remains, for re-attaching to a
  /// download this screen did not start.
  Future<OfflineItem?> download({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
    String? assetId,
    void Function(OfflineProgress)? onProgress,
    DownloadNotices notices = DownloadNotices.english,
  }) async {
    final titleId = content.id;
    if (_streams.containsKey(titleId)) return null;

    final controller = StreamController<OfflineProgress>.broadcast();
    _streams[titleId] = controller;
    _cancelled.remove(titleId);

    void emit(OfflineProgress p) {
      if (!controller.isClosed) controller.add(p);
      try {
        onProgress?.call(p);
      } catch (e) {
        // A listener that throws is its own problem and never the download's.
        if (kDebugMode) debugPrint('offline onProgress: $e');
      }
    }

    // Recorded BEFORE the first byte, so an interrupted download is something
    // the Downloads screen can show and offer to resume. Without this a
    // `.part` file is an anonymous blob: the shelf only learned a title's
    // name when the download finished, which is exactly the case where the
    // name was not needed.
    await _library.putPending(PendingDownload(
      titleId: titleId,
      title: content.title,
      titleMm: content.titleMm,
      posterUrl: content.poster.isEmpty ? null : content.poster.locator,
      assetId: assetId,
      startedAt: DateTime.now(),
    ));

    // Queued behind any transfer already running. Said out loud, because a
    // Download button that reports nothing for ten minutes gets tapped again.
    if (_busy) {
      emit(OfflineProgress(titleId: titleId, queued: true));
    }

    final completer = Completer<OfflineItem?>();
    _chain = _chain.then((_) async {
      _busy = true;
      try {
        if (_cancelled.contains(titleId)) {
          completer.complete(null);
          return;
        }
        final item = await _run(
          content: content,
          source: source,
          deviceId: deviceId,
          assetId: assetId,
          notices: notices,
          emit: emit,
        );
        completer.complete(item);
      } catch (e) {
        if (kDebugMode) debugPrint('offline download failed: $e');
        emit(OfflineProgress(titleId: titleId, error: '$e'));
        completer.complete(null);
      } finally {
        _busy = false;
        await controller.close();
        _streams.remove(titleId);
        _cancelled.remove(titleId);
      }
    });
    // The chain must never end in an error state or every later download would
    // be skipped — the same rule the player's surface-op chain follows.
    _chain = _chain.catchError((Object e) {
      if (kDebugMode) debugPrint('offline chain: $e');
    });
    return completer.future;
  }

  bool _busy = false;

  Future<OfflineItem?> _run({
    required VideoContent content,
    required MediaRef source,
    required String? deviceId,
    required String? assetId,
    required DownloadNotices notices,
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
    // The object length as first observed, kept beside the part file so a
    // resume days later can tell whether it is still the same film.
    final sizeNote = File('$partPath.total');

    var received = await part.exists() ? await part.length() : 0;
    int? total = await _readSizeNote(sizeNote);

    final label = content.title.trim().isEmpty ? 'Downloading' : content.title;
    await OfflineServiceBridge.start(label, _statusLine(received, total));
    var serviceUp = true;

    // Throttling state. A chunk is tens of kilobytes, so a 900 MB film is
    // tens of thousands of chunks — and the old code emitted one progress
    // event per chunk, each one a `setState` in the button that started it.
    var lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastEmitBytes = -1;
    var lastNoticeAt = DateTime.fromMillisecondsSinceEpoch(0);
    var lastSpaceCheck = received;

    void report({bool force = false}) {
      final now = DateTime.now();
      if (force ||
          now.difference(lastEmitAt) >= const Duration(milliseconds: 400) ||
          received - lastEmitBytes >= 4 * 1024 * 1024) {
        lastEmitAt = now;
        lastEmitBytes = received;
        emit(OfflineProgress(
            titleId: titleId, received: received, total: total));
      }
      // The notification is refreshed on its own, slower clock — but it must
      // keep being refreshed even when the number has not moved, because that
      // call is also what renews the WakeLock's safety cap.
      if (force || now.difference(lastNoticeAt) >= const Duration(seconds: 2)) {
        lastNoticeAt = now;
        final pct = total != null && total! > 0
            ? ((received / total!) * 100).clamp(0, 100).round()
            : -1;
        // Fire and forget: the notification is a courtesy and the download
        // must never wait on it.
        // ignore: discarded_futures
        OfflineServiceBridge.update(label, _statusLine(received, total), pct);
      }
    }

    try {
      var failures = 0;
      var attempts = 0;
      while (failures <= maxConsecutiveFailures && attempts < maxAttempts) {
        attempts++;
        if (_cancelled.contains(titleId)) return null;

        if (failures > 0) {
          final wait = retryDelay(failures);
          // ignore: discarded_futures
          OfflineServiceBridge.update(label, notices.waiting, -1);
          await Future<void>.delayed(wait);
          if (_cancelled.contains(titleId)) return null;
        }

        // A FRESH URL EVERY ATTEMPT, and a fresh entitlement check with it.
        //
        // WRAPPED, because on a dead connection this THROWS rather than
        // returning a refusal — and an uncaught throw here used to end the
        // whole download at the first blip, before the resume loop it sits
        // inside ever got to do its job.
        PlaybackGrant grant;
        try {
          grant = await _repo.requestPlayback(
            content: content,
            source: source,
            deviceId: deviceId,
          );
        } catch (e) {
          if (kDebugMode) debugPrint('offline renew failed: $e');
          failures++;
          continue;
        }
        if (!grant.isGranted) {
          // A DENIAL IS NOT A NETWORK FAILURE and must not be retried for half
          // an hour. The server has answered: this viewer may not have this
          // file. Retrying cannot change that and would hammer the endpoint.
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
        final url = grant.url;
        if (url == null || url.isEmpty) {
          failures++;
          continue;
        }

        final request = http.Request('GET', Uri.parse(url));
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
          if (kDebugMode) debugPrint('offline attempt: $e');
          failures++;
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
            debugPrint('offline attempt: HTTP ${response.statusCode}');
          }
          // Drain so the socket is reusable rather than left half-read.
          try {
            await response.stream.drain<void>();
          } catch (_) {}
          failures++;
          continue;
        }

        final reported = response.contentLength;
        final freshTotal = reported == null ? null : received + reported;

        // IS WHAT IS ON DISK STILL A PREFIX OF THIS FILM? See [planResume] —
        // an object replaced behind the same key produced a file that was half
        // of one encode and half of another, passed the length check, and
        // played until the seam.
        if (planResume(
              onDisk: received,
              expectedTotal: total,
              freshTotal: freshTotal,
            ) ==
            ResumePlan.restart) {
          if (kDebugMode) {
            debugPrint('offline restart: object changed ($total -> $freshTotal)');
          }
          try {
            await response.stream.drain<void>();
          } catch (_) {}
          received = 0;
          total = null;
          if (await part.exists()) await part.delete();
          try {
            if (await sizeNote.exists()) await sizeNote.delete();
          } catch (_) {}
          // Not counted as a failure: this is a decision, not a fault, and the
          // next pass starts the download properly from zero.
          continue;
        }

        if (freshTotal != null) {
          total = freshTotal;
          await _writeSizeNote(sizeNote, freshTotal);
        }

        // ROOM FIRST, BEFORE THE BODY. The headers already say how big the
        // film is, so the check costs nothing extra — and a film that cannot
        // fit is refused here instead of after spending the viewer's data on
        // as much of it as the disk would hold.
        if (total != null &&
            !hasRoomFor(
              freeBytes: await _freeBytes(dir.path),
              totalBytes: total!,
              alreadyOnDisk: received,
            )) {
          try {
            await response.stream.drain<void>();
          } catch (_) {}
          emit(OfflineProgress(
            titleId: titleId,
            received: received,
            total: total,
            error: 'no_space',
          ));
          return null;
        }

        report(force: true);

        final beforePass = received;
        final sink = part.openWrite(mode: FileMode.append);
        var broke = false;
        var ranOut = false;
        try {
          await for (final chunk in response.stream) {
            if (_cancelled.contains(titleId)) {
              broke = true;
              break;
            }
            sink.add(chunk);
            received += chunk.length;
            report();
            if (received - lastSpaceCheck >= _spaceCheckEvery) {
              lastSpaceCheck = received;
              final free = await _freeBytes(dir.path);
              // Only the HEADROOM is checked here, not the whole remainder: a
              // download already under way should not be abandoned because the
              // arithmetic got tighter, only because the phone is genuinely
              // about to run out.
              if (free >= 0 && free < kDownloadHeadroomBytes) {
                broke = true;
                ranOut = true;
                emit(OfflineProgress(
                  titleId: titleId,
                  received: received,
                  total: total,
                  error: 'no_space',
                ));
                break;
              }
            }
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
        // REAL PROGRESS CLEARS THE BUDGET. A download that is moving, however
        // slowly and however often it is interrupted, is a download that is
        // working, and the give-up count is for the other kind. Measured
        // against [_realProgress] rather than against any byte at all, so an
        // attempt that dies during its first packet cannot keep the loop alive
        // for ever.
        final gained = received - beforePass;
        if (gained >= _realProgress) {
          failures = 0;
        } else {
          failures++;
        }

        // DONE ONLY WHEN THE LENGTH MATCHES. A stream that ends early without
        // throwing is indistinguishable from a finished one except by this
        // check, and "downloaded" is a promise the app makes offline, where it
        // cannot go back and look.
        if (!broke && total != null && received >= total!) {
          serviceUp = false;
          return _finish(
            content: content,
            assetId: assetId,
            part: part,
            sizeNote: sizeNote,
            finalPath: finalPath,
            bytes: received,
            label: label,
            notices: notices,
            emit: emit,
          );
        }
        if (!broke && total == null && received > 0) {
          // No Content-Length at all — the transfer ended cleanly and there is
          // nothing to compare against. Accepting it is the only option that
          // does not discard a complete download, and it is why the check above
          // is preferred whenever a length exists.
          serviceUp = false;
          return _finish(
            content: content,
            assetId: assetId,
            part: part,
            sizeNote: sizeNote,
            finalPath: finalPath,
            bytes: received,
            label: label,
            notices: notices,
            emit: emit,
          );
        }
        // A full disk has already reported itself, and no amount of waiting
        // makes room. Retrying would spend the viewer's data re-reading bytes
        // that cannot be written.
        if (ranOut) return null;
      }

      emit(OfflineProgress(
        titleId: titleId,
        received: received,
        total: total,
        error: 'gave_up',
      ));
      return null;
    } finally {
      // The notification and the locks go whatever happened. A download that
      // stopped must not leave a foreground service pinning the CPU.
      if (serviceUp) await OfflineServiceBridge.stop();
    }
  }

  Future<OfflineItem> _finish({
    required VideoContent content,
    required String? assetId,
    required File part,
    required File sizeNote,
    required String finalPath,
    required int bytes,
    required String label,
    required DownloadNotices notices,
    required void Function(OfflineProgress) emit,
  }) async {
    // RENAME LAST. Until this line there is only a `.part` file, which no
    // reader trusts; after it there is a finished file AND an index entry.
    // A crash between the two leaves a file with no entry, which the next
    // `dropAll` sweeps — far better than an entry with no file, which is a
    // row that spins forever when tapped.
    await part.rename(finalPath);
    try {
      if (await sizeNote.exists()) await sizeNote.delete();
    } catch (_) {}

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
    await _library.dropPending(content.id);
    emit(OfflineProgress(
      titleId: content.id,
      received: bytes,
      total: bytes,
      done: true,
    ));
    // THE NOTICE IS HOW THEY FIND OUT. Whoever started this is not looking at
    // the screen — that is what downloading instead of streaming means — so
    // without this they have to keep opening the app to check, on a connection
    // where opening the app costs them data.
    await OfflineServiceBridge.done(label, notices.ready);
    return item;
  }

  static String _statusLine(int received, int? total) {
    String mb(int b) => '${(b / (1024 * 1024)).toStringAsFixed(0)} MB';
    if (total == null || total <= 0) return mb(received);
    return '${mb(received)} of ${mb(total)}';
  }

  Future<int?> _readSizeNote(File f) async {
    try {
      if (!await f.exists()) return null;
      final v = int.tryParse((await f.readAsString()).trim());
      return (v != null && v > 0) ? v : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSizeNote(File f, int total) async {
    try {
      await f.writeAsString('$total', flush: true);
    } catch (_) {
      // Losing the note costs the identity check on a later resume, which is
      // a weaker download rather than a broken one.
    }
  }

  /// Free bytes on the volume holding [dir], or -1 when the platform did not
  /// answer. Same channel the player's disk cache uses.
  Future<int> _freeBytes(String dir) async {
    try {
      final v = await const MethodChannel('mx_clone/media_scan')
          .invokeMethod<int>('freeBytes', <String, dynamic>{'dir': dir});
      return v ?? -1;
    } catch (e) {
      if (kDebugMode) debugPrint('offline freeBytes: $e');
      return -1;
    }
  }
}
