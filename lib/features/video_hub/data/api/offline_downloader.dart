import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../../../../core/services/connectivity/connectivity_service.dart';
import '../../../../core/services/diagnostics/playback_log.dart';
import '../../../../core/services/network/foreground_stream.dart';
import '../../../../core/services/offline/offline_service_bridge.dart';
import '../../domain/access.dart';
import '../../domain/content_repository.dart';
import '../../domain/video_content.dart';
import '../../domain/byte_size.dart';
import '../../domain/transfer_rate.dart';
import '../poster_cache.dart';
import 'download_plan.dart';
import 'ranged_fetch.dart';
import 'offline_crypto.dart';
import 'offline_library.dart';

/// Where one download has got to.
@immutable
class OfflineProgress {
  final String key;
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

  /// Current speed, or null while there is not yet enough to say honestly.
  ///
  /// THE NUMBER THE VIEWER IS ACTUALLY ASKING FOR. "412 MB of 1.8 GB" is a
  /// fact about the file; "2.1 MB/s, 11 minutes left" is the answer to "can I
  /// watch this tonight" — which is the only question being asked while a
  /// download runs. See [TransferRate] for why it is a rolling window and not
  /// an average.
  final int? bytesPerSecond;

  /// How long the rest will take at the current speed, or null when that
  /// cannot be answered. Null rather than a huge number: "stalled" and
  /// "4 million hours" are different things to say, and only one is useful.
  final Duration? remaining;

  /// True while the download is waiting out a lost connection rather than
  /// transferring. Different from [queued], which is waiting for another
  /// download, and from an error, which has given up.
  final bool waitingForNetwork;

  /// Held back because the viewer is streaming something — see
  /// ForegroundStream. Said on screen so slow is not mistaken for broken.
  final bool yielding;

  /// Set when the download stopped and will not continue on its own.
  final String? error;

  const OfflineProgress({
    required this.key,
    this.received = 0,
    this.total,
    this.done = false,
    this.queued = false,
    this.waitingForNetwork = false,
    this.yielding = false,
    this.bytesPerSecond,
    this.remaining,
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

/// Whether a download may spend this connection right now.
///
/// PASSED IN RATHER THAN READ HERE. The downloader has no business knowing
/// about Riverpod or about a settings screen, and the rule it is enforcing is a
/// product decision that belongs next to the setting. What it gets is an
/// answer: yes, or a reason to give the viewer.
typedef DownloadAllowance = Future<DownloadRefusal?> Function();

/// Why a download may not spend this connection.
enum DownloadRefusal {
  /// "Download over Wi-Fi only" is on and this connection is metered.
  ///
  /// Android's own NET_CAPABILITY_NOT_METERED decides, not the transport: a
  /// tethered phone and a paid hotspot are both Wi-Fi and both cost the viewer
  /// by the megabyte.
  meteredWhileWifiOnly,
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
    DownloadAllowance? allowance,
    int lanes = RangedFetch.defaultLanes,
    int partBytes = RangedFetch.defaultPartBytes,
    Duration stallAfter = RangedFetch.defaultStallAfter,
  })  : _http = httpClient ?? http.Client(),
        _allowance = allowance ?? _alwaysAllowed,
        _lanes = lanes,
        _partBytes = partBytes,
        _stallAfter = stallAfter;

  final ContentRepository _repo;
  final OfflineLibrary _library;
  final http.Client _http;
  final DownloadAllowance _allowance;

  /// Connections one download may use at once, and the part each fetches.
  /// See [RangedFetch]. One means a single plain response, as before.
  final int _lanes;
  final int _partBytes;

  /// A connection with no byte for this long is dead, and the pass ends so
  /// the resume loop can open a new one. Without it, a mobile link that died
  /// silently — a cell handover, Wi-Fi to data — left a socket that never
  /// errored, and the download sat at the same percentage until the app was
  /// killed. Thirty seconds of nothing is far past any real pause.
  final Duration _stallAfter;

  /// Downloads whose server answered a range with the whole file. Asked once;
  /// after that they keep to one connection rather than pay for it again.
  final Set<String> _rangesRefused = <String>{};

  static Future<DownloadRefusal?> _alwaysAllowed() async => null;

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

  /// How much is gathered before one trip to the cipher. See the loop.
  static const int _sealBatch = 512 * 1024;

  /// The longest single pause while yielding, so a cancel or the end of the
  /// stream is noticed promptly.
  static const Duration _maxPaceWait = Duration(seconds: 2);

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

  /// Album photos, fetched on a chain of their own. A photo is a few hundred
  /// kilobytes and takes a second; queueing it behind an hour-long film would
  /// leave "Download all" showing nothing for that hour. They still go one at
  /// a time, for the same reason films do.
  Future<void> _photoChain = Future<void>.value();

  /// Ticks whenever a download is registered or ends.
  ///
  /// An album draws a badge on every tile and a counter over all of them, and
  /// subscribing to every item's stream to learn that one of them started would
  /// be a listener per tile for a question asked once.
  final ValueNotifier<int> activity = ValueNotifier<int>(0);

  /// What to ask the playback endpoint for, to (re)start the download stored
  /// under this asset id: the album clip itself, or — with none — the title's
  /// film. A resume that passed the film's source for a clip's row would
  /// splice the film onto the clip's part file.
  static MediaRef sourceFor(VideoContent content, String? assetId) =>
      (assetId == null || assetId.isEmpty)
          ? content.source
          : MediaRef(provider: 'asset', locator: assetId);

  /// True while this item is being fetched or waiting its turn.
  bool isRunning(String key) => _streams.containsKey(key);

  /// Progress for a running download, or null when none is running.
  Stream<OfflineProgress>? watch(String key) => _streams[key]?.stream;

  /// Asks for the download to stop. The partial file is KEPT, so starting
  /// again resumes rather than restarts.
  ///
  /// THIS IS THE VIEWER PAUSING, and it is recorded as such. Everything that
  /// calls it is a person pressing something — the Pause button, the shade, the
  /// Cancel on a queued item — so the row is marked, and nothing will resume it
  /// on their behalf. A download stopped by the network or by the app dying
  /// leaves the row unmarked and carries on by itself. See
  /// [PendingDownload.pausedByUser]: the two look identical on disk and only
  /// this call can tell them apart.
  void cancel(String key) {
    _cancelled.add(key);
    // Fire and forget: the flag above is what stops the transfer, and a
    // preferences write must not be in that path.
    // ignore: discarded_futures
    _library.markPaused(key);
  }

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
    Future<bool> Function(int totalBytes, int freeBytes)? confirmSize,
  }) async {
    final key = offlineKeyFor(content.id, assetId: assetId);
    if (_streams.containsKey(key)) return null;

    final controller = StreamController<OfflineProgress>.broadcast();
    _streams[key] = controller;
    _cancelled.remove(key);
    activity.value++;

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
      titleId: content.id,
      key: key,
      title: content.title,
      titleMm: content.titleMm,
      posterUrl: content.poster.isEmpty ? null : content.poster.locator,
      assetId: assetId,
      startedAt: DateTime.now(),
      premium: content.accessTier == AccessTier.premium,
      // Starting or resuming clears the pause: it is being asked for again.
      pausedByUser: false,
    ));

    // Queued behind any transfer already registered. Said out loud, because a
    // Download button that reports nothing for ten minutes gets tapped again.
    //
    // MEASURED FROM THE REGISTRY, NOT FROM A "BUSY" FLAG. The flag was set
    // inside the chain, which starts on a later microtask — so two downloads
    // tapped in quick succession both saw "not busy" and neither said it was
    // waiting. This map has this download's own entry in it already, so more
    // than one entry means somebody else is ahead.
    if (_streams.length > 1) {
      emit(OfflineProgress(key: key, queued: true));
    }

    final completer = Completer<OfflineItem?>();
    _chain = _chain.then((_) async {
      try {
        if (_cancelled.contains(key)) {
          completer.complete(null);
          return;
        }
        final item = await _run(
          content: content,
          source: source,
          deviceId: deviceId,
          assetId: assetId,
          notices: notices,
          confirmSize: confirmSize,
          emit: emit,
        );
        completer.complete(item);
      } catch (e) {
        if (kDebugMode) debugPrint('offline download failed: $e');
        emit(OfflineProgress(key: key, error: '$e'));
        completer.complete(null);
      } finally {
        await controller.close();
        _streams.remove(key);
        _cancelled.remove(key);
        activity.value++;
      }
    });
    // The chain must never end in an error state or every later download would
    // be skipped — the same rule the player's surface-op chain follows.
    _chain = _chain.catchError((Object e) {
      if (kDebugMode) debugPrint('offline chain: $e');
    });
    return completer.future;
  }

  /// Fetches one album PHOTO to disk.
  ///
  /// NOT [download] WITH A DIFFERENT SOURCE. A photo has a public URL, no
  /// signed address to renew, no ladder, no foreground service and no size to
  /// agree to on its own — the album asks once for everything it is about to
  /// fetch. What it keeps from [download] is everything that protects the
  /// viewer: the Wi-Fi-only rule, a `.part` file renamed only when complete,
  /// a length check, and the same registry so a second tap cannot start a
  /// second writer.
  ///
  /// Copied from the artwork cache when the photo is already there, which it
  /// is for any photo somebody has opened: the bytes were paid for once.
  Future<OfflineItem?> downloadPhoto({
    required VideoContent content,
    required String assetId,
    required String url,
    void Function(OfflineProgress)? onProgress,
  }) async {
    final key = offlineKeyFor(content.id, assetId: assetId);
    if (_streams.containsKey(key)) return null;
    final controller = StreamController<OfflineProgress>.broadcast();
    _streams[key] = controller;
    _cancelled.remove(key);
    activity.value++;

    void emit(OfflineProgress p) {
      if (!controller.isClosed) controller.add(p);
      try {
        onProgress?.call(p);
      } catch (e) {
        if (kDebugMode) debugPrint('offline photo onProgress: $e');
      }
    }

    emit(OfflineProgress(key: key, queued: true));
    final completer = Completer<OfflineItem?>();
    _photoChain = _photoChain.then((_) async {
      try {
        completer.complete(await _fetchPhoto(
          content: content,
          assetId: assetId,
          key: key,
          url: url,
          emit: emit,
        ));
      } catch (e) {
        if (kDebugMode) debugPrint('offline photo failed: $e');
        emit(OfflineProgress(key: key, error: '$e'));
        completer.complete(null);
      } finally {
        await controller.close();
        _streams.remove(key);
        _cancelled.remove(key);
        activity.value++;
      }
    });
    _photoChain = _photoChain.catchError((Object e) {
      if (kDebugMode) debugPrint('offline photo chain: $e');
    });
    return completer.future;
  }

  /// How many times one photo is tried before it is reported as failed.
  static const int _photoAttempts = 4;

  Future<OfflineItem?> _fetchPhoto({
    required VideoContent content,
    required String assetId,
    required String key,
    required String url,
    required void Function(OfflineProgress) emit,
  }) async {
    if (_cancelled.contains(key)) return null;
    final refusal = await _allowance();
    if (refusal != null) {
      emit(OfflineProgress(key: key, error: refusal.name));
      return null;
    }
    final dir = await _library.directory();
    final finalPath = '${dir.path}/$key${photoExtension(url)}';
    final part = File('$finalPath${OfflineLibrary.partSuffix}');
    int? bytes;

    final cached = await PosterCache.onDisk(url);
    if (cached != null) {
      try {
        await File(cached).copy(part.path);
        bytes = await part.length();
        if (bytes <= 0) bytes = null;
      } catch (e) {
        if (kDebugMode) debugPrint('offline photo copy: $e');
        bytes = null;
      }
    }

    for (var attempt = 0; bytes == null && attempt < _photoAttempts; attempt++) {
      if (_cancelled.contains(key)) return null;
      if (attempt > 0) {
        if (!await _waitForNetwork(retryDelay(attempt), key)) return null;
      }
      IOSink? sink;
      try {
        // Bounded like a film: a photo whose connection went quiet would
        // otherwise hold the whole album's queue behind it.
        final response = await _http
            .send(http.Request('GET', Uri.parse(url)))
            .timeout(_stallAfter);
        if (response.statusCode != 200) {
          try {
            await response.stream.drain<void>();
          } catch (_) {}
          // A 404 is an answer, not a blip: the photo is gone, and asking three
          // more times spends data to be told so three more times.
          if (response.statusCode == 404 || response.statusCode == 403) break;
          continue;
        }
        final expected = response.contentLength;
        sink = part.openWrite();
        var got = 0;
        var broke = false;
        await for (final chunk in response.stream.timeout(_stallAfter)) {
          if (_cancelled.contains(key)) {
            broke = true;
            break;
          }
          sink.add(chunk);
          got += chunk.length;
          emit(OfflineProgress(key: key, received: got, total: expected));
        }
        await sink.flush();
        await sink.close();
        sink = null;
        if (broke) {
          try {
            if (await part.exists()) await part.delete();
          } catch (_) {}
          return null;
        }
        // SHORT IS FAILED. A photo that stopped half way draws as half a
        // photo, and "downloaded" is a promise made offline, where nobody
        // can go back and look.
        if (got > 0 && (expected == null || got == expected)) bytes = got;
      } catch (e) {
        if (kDebugMode) debugPrint('offline photo attempt: $e');
      } finally {
        try {
          await sink?.close();
        } catch (_) {}
      }
    }

    if (bytes == null) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      emit(OfflineProgress(key: key, error: 'gave_up'));
      return null;
    }

    await part.rename(finalPath);
    final item = OfflineItem(
      titleId: content.id,
      key: key,
      kind: 'photo',
      sourceUrl: url,
      title: content.title,
      titleMm: content.titleMm,
      posterUrl: content.poster.isEmpty ? null : content.poster.locator,
      path: finalPath,
      bytes: bytes,
      addedAt: DateTime.now(),
      assetId: assetId,
      premium: content.accessTier == AccessTier.premium,
    );
    await _library.put(item);
    emit(OfflineProgress(key: key, received: bytes, total: bytes, done: true));
    return item;
  }

  Future<OfflineItem?> _run({
    required VideoContent content,
    required MediaRef source,
    required String? deviceId,
    required String? assetId,
    required DownloadNotices notices,
    required Future<bool> Function(int totalBytes, int freeBytes)? confirmSize,
    required void Function(OfflineProgress) emit,
  }) async {
    final key = offlineKeyFor(content.id, assetId: assetId);
    final dir = await _library.directory();
    // Named by the TITLE ID, not by the title. A name is operator-entered
    // text that can contain anything a path cannot, and two titles can share
    // one; an id is a uuid and is unique by construction.
    final finalPath = '${dir.path}/$key.mp4';
    final partPath = '$finalPath${OfflineLibrary.partSuffix}';
    final part = File(partPath);
    // The object length as first observed, kept beside the part file so a
    // resume days later can tell whether it is still the same film.
    final sizeNote = File('$partPath.total');
    // WHICH KEYSTREAM THE BYTES ON DISK BELONG TO. A resume ciphers from where
    // it stopped, and nothing in the part file itself says which IV produced
    // it — so the IV is written beside it before the first byte and lives
    // exactly as long as the part file does. Its presence is also the answer to
    // "was this download started sealed", which is the one question a resume
    // must not guess: half a film under one cipher and half under none is noise
    // with a seam in it.
    final ivNote = File('$partPath.iv');

    var received = await part.exists() ? await part.length() : 0;
    int? total = await _readSizeNote(sizeNote);
    var sealer = await _sealerFor(part: part, ivNote: ivNote, at: received);

    // ─── KILLED BETWEEN THE TRAILER AND THE RENAME ─────────────────────────
    //
    // A narrow window, and it leaves a part file that is a COMPLETE sealed film
    // — thirty-two bytes longer than the object. Without this, `received` reads
    // as that longer number, the film finishes with a second trailer appended
    // over the first, and the shelf records a size thirty-two bytes larger than
    // anything anybody uploaded.
    //
    // A false positive here is not reachable: a trailer is recognised by its
    // magic AND by carrying this file's own length minus thirty-two, and
    // ciphertext does not produce that pair by accident.
    if (sealer != null && received > OfflineCrypto.trailerLength) {
      final already = await OfflineCrypto.inspect(part);
      if (already != null) {
        received = already.plainLength;
        sealer = _Sealer(iv: sealer.iv, at: received);
      }
    }

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
    final rate = TransferRate();

    void report({bool force = false}) {
      final now = DateTime.now();
      rate.observe(received, now);
      if (force ||
          now.difference(lastEmitAt) >= const Duration(milliseconds: 400) ||
          received - lastEmitBytes >= 4 * 1024 * 1024) {
        lastEmitAt = now;
        lastEmitBytes = received;
        emit(OfflineProgress(
          key: key,
          received: received,
          total: total,
          yielding: ForegroundStream.active,
          bytesPerSecond: rate.bytesPerSecond,
          remaining: rate.remaining(received, total),
        ));
      }
      // The notification is refreshed on its own, slower clock — but it must
      // keep being refreshed even when the number has not moved, because that
      // call is also what renews the WakeLock's safety cap.
      if (force || now.difference(lastNoticeAt) >= const Duration(seconds: 2)) {
        lastNoticeAt = now;
        final pct = total != null && total! > 0
            ? ((received / total!) * 100).clamp(0, 100).round()
            : -1;
        // THE SPEED GOES IN THE SHADE TOO. This notification is what somebody
        // who put the phone down looks at, and it is the only place they can
        // see the download at all without opening the app — so it carries the
        // same answer the screen does.
        final speed = rate.bytesPerSecond;
        final line = speed == null || speed <= 0
            ? _statusLine(received, total)
            : '${_statusLine(received, total)} · ${formatBytes(speed)}/s';
        // Fire and forget: the notification is a courtesy and the download
        // must never wait on it.
        // ignore: discarded_futures
        OfflineServiceBridge.update(label, line, pct);
        // AND ASK WHETHER THE SHADE WANTS IT PAUSED. This is the only moment
        // the downloader is certainly running and certainly talking to the
        // service, which is what makes a poll the right direction — see
        // [OfflineServiceBridge.takePauseRequest].
        // ignore: discarded_futures
        OfflineServiceBridge.takePauseRequest().then((wanted) {
          if (wanted) {
            PlaybackLog.add('offline paused from the notification');
            cancel(key);
          }
        });
      }
    }

    // Asked at most once per download. Declared out here rather than inside
    // the loop, which runs again on every resume.
    var askedSize = false;

    try {
      var failures = 0;
      var attempts = 0;
      while (failures <= maxConsecutiveFailures && attempts < maxAttempts) {
        attempts++;
        if (_cancelled.contains(key)) return null;

        // ─── ALREADY COMPLETE, AND NEVER FINISHED ─────────────────────────
        //
        // The bytes are all there but the file was never renamed and no row
        // was written. Two ways to arrive here: Android killed the app between
        // the last byte and the rename, or the trailer would not write and the
        // download was left resumable on purpose.
        //
        // WITHOUT THIS, AN ATTEMPT IS MADE ANYWAY, and it asks the object for
        // the bytes from `received` onwards — which is past the end, so R2
        // answers 416 and the loop counts a failure and waits, five hundred
        // times, on a download that is sitting finished on the disk. Costing
        // somebody their film to a rename that did not happen is the kind of
        // thing nobody would ever find.
        if (total != null && received >= total! && received > 0) {
          serviceUp = false;
          return _finish(
            content: content,
            assetId: assetId,
            part: part,
            sizeNote: sizeNote,
            ivNote: ivNote,
            sealer: sealer,
            finalPath: finalPath,
            bytes: received,
            label: label,
            notices: notices,
            emit: emit,
          );
        }

        // ─── MAY THIS CONNECTION BE SPENT? ────────────────────────────────
        //
        // Asked before every attempt, not only the first, so a download that
        // was running on wifi stops when the viewer walks out of the house
        // rather than quietly continuing on their data bundle. That is the only
        // reading of "Wi-Fi only" that means anything.
        //
        // It STOPS rather than waits. Waiting would hold the foreground service
        // and its WakeLock for however long it takes somebody to get home,
        // which is a battery drain in exchange for nothing — the bytes on disk
        // are kept and the resume is automatic the next time the app sees
        // wifi. Saying so out loud is the difference between a rule and a
        // silence.
        final refusal = await _allowance();
        if (refusal != null) {
          emit(OfflineProgress(
            key: key,
            received: received,
            total: total,
            error: refusal.name,
          ));
          return null;
        }

        if (failures > 0) {
          rate.reset();
          emit(OfflineProgress(
            key: key,
            received: received,
            total: total,
            waitingForNetwork: true,
          ));
          // ignore: discarded_futures
          OfflineServiceBridge.update(label, notices.waiting, -1);
          // ─── WAITING ON THE CONNECTION, NOT ON A CLOCK ──────────────────
          //
          // The backoff exists so a dead link is not hammered. It should not
          // also mean that a link which came back after four seconds is
          // ignored for another fifty-six — which is what a plain sleep does,
          // and on a connection that drops every few minutes those wasted
          // fifty-six seconds are most of the download.
          //
          // So the wait is broken into short steps and abandoned as soon as a
          // DNS lookup succeeds. The backoff still bounds how often the server
          // is asked; it no longer decides how long recovery takes.
          if (!await _waitForNetwork(retryDelay(failures), key)) {
            return null;
          }
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
            key: key,
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

        final abort = Completer<void>();
        final request =
            http.AbortableRequest('GET', Uri.parse(url), abortTrigger: abort.future);
        if (received > 0) {
          // Resume. A server that ignores this answers 200 with the whole file,
          // which is handled below by starting the file over rather than
          // appending a second copy to the first.
          request.headers['Range'] = 'bytes=$received-';
        }

        http.StreamedResponse response;
        try {
          response = await _http.send(request).timeout(_stallAfter);
        } catch (e) {
          if (!abort.isCompleted) abort.complete();
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
          askedSize = false; // A different film, so a different size to agree to.
          if (await part.exists()) await part.delete();
          try {
            if (await sizeNote.exists()) await sizeNote.delete();
          } catch (_) {}
          // A NEW IV FOR A NEW FILM, and this is not tidiness. One keystream
          // used for two different films is the textbook way to lose a stream
          // cipher: anybody holding both files gets the XOR of the two
          // plaintexts without needing the key at all.
          try {
            if (await ivNote.exists()) await ivNote.delete();
          } catch (_) {}
          sealer = await _sealerFor(part: part, ivNote: ivNote, at: 0);
          // Not counted as a failure: this is a decision, not a fault, and the
          // next pass starts the download properly from zero.
          continue;
        }

        if (freshTotal != null) {
          total = freshTotal;
          await _writeSizeNote(sizeNote, freshTotal);
        }

        // ─── THE SIZE IS KNOWN HERE, AND NOWHERE EARLIER ─────────────────
        //
        // The response headers say how big the film is, and they arrive before
        // a single byte of the body does. So this is the one moment at which
        // the viewer can be asked a question that costs them nothing to answer
        // — and on a metered Myanmar connection "this is 1.8 GB" is the most
        // important sentence in the whole feature. Asked ONCE, on a fresh
        // download only: somebody resuming at 700 MB has already decided, and
        // asking again would be the app forgetting what they told it.
        //
        // Nothing has been written yet, so a No costs exactly the headers.
        if (confirmSize != null && !askedSize && received == 0) {
          askedSize = true;
          if (total != null) {
            final ok = await confirmSize(total!, await _freeBytes(dir.path));
            if (!ok) {
              try {
                await response.stream.drain<void>();
              } catch (_) {}
              // Not an error: they were asked and they said no. A row in the
              // pending list for a download that never started would be a
              // gigabyte's worth of promise about nothing.
              await _library.dropPending(key);
              return null;
            }
          }
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
            key: key,
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
        var sealBroke = false;
        // ═══════════════════════════════════════════════════════════════
        // BATCHED, NOT PER CHUNK — THE SPEED AND THE HEAT
        // ═══════════════════════════════════════════════════════════════
        //
        // Reported 2026-10-03: the phone's own meter read ~3 MB/s while this
        // screen said under 1 MB/s, and the phone ran hot. The network hands
        // the body over in pieces of a few kilobytes; each piece was sent
        // across the platform channel to be enciphered (Dart → the Android
        // main thread → back, four or five copies of every byte) and AWAITED
        // before the next piece was read. At 3 MB/s that is hundreds of round
        // trips a second: the CPU busy shuttling bytes, and the socket left
        // unread between them so TCP slowed the sender down to match.
        //
        // Now the pieces gather here and go to the cipher half a megabyte at
        // a time — a handful of round trips a second instead of hundreds. CTR
        // is addressable by byte (see _Sealer), so the batch size changes
        // nothing about the file. An unsealed download is written as it
        // comes; IOSink already buffers that.
        final batch = BytesBuilder(copy: false);
        // The pacing window: when it opened, and the byte count then.
        var paceFrom = DateTime.now();
        var paceBase = received;

        // Writes what has gathered. False when the cipher failed: everything
        // already written is under the old keystream and still readable, so
        // the honest move is to stop the pass rather than write plaintext into
        // the middle of it — a file that plays until the seam and then not.
        Future<bool> drain() async {
          if (batch.isEmpty) return true;
          final plain = batch.takeBytes();
          final out = sealer == null ? plain : await sealer.take(plain);
          if (out == null) return false;
          sink.add(out);
          received += plain.length;
          report();
          return true;
        }

        // ─── SEVERAL CONNECTIONS, WHEN IT IS WORTH IT ─────────────────────
        //
        // See [RangedFetch]: the rest of the film in parts, two or three at
        // once, handed on in order — so everything below sees one stream of
        // bytes exactly as before. Not for a film nearly done, and not for a
        // server that has already refused a range.
        //
        // NOT WHILE THE VIEWER IS STREAMING, either way round. A pass that
        // starts while they watch is one connection, paced below; once they
        // stop, it ends cleanly and the next pass splits ([rejoin]). A split
        // pass that sees them start ends cleanly after the parts already on
        // their way (see [RangedFetch.ordered]), and the next pass is paced.
        final canSplit = _lanes > 1 &&
            total != null &&
            !_rangesRefused.contains(key) &&
            RangedFetch.acceptsRanges(response) &&
            RangedFetch.worthSplitting(total - received, partBytes: _partBytes);
        final split = canSplit && !ForegroundStream.active;
        final rejoin = canSplit && !split;
        // One line per pass: how it fetched and from where. With the line at
        // its end, a trace says why a download ran at the speed it did.
        PlaybackLog.add('dl pass ${split ? 'x$_lanes' : rejoin ? 'x1 (watching)' : 'x1'} '
            'from ${received >> 20}/${total == null ? '?' : total >> 20} MB '
            'http ${response.statusCode}');
        final passStarted = DateTime.now();
        final body = split
            ? RangedFetch.ordered(
                client: _http,
                url: Uri.parse(url),
                head: response.stream,
                start: received,
                total: total,
                partBytes: _partBytes,
                lanes: _lanes,
                narrow: () => ForegroundStream.active,
                stallAfter: _stallAfter,
              )
            : response.stream.timeout(_stallAfter);

        try {
          await for (final chunk in body) {
            if (_cancelled.contains(key)) {
              broke = true;
              break;
            }
            if (sealer == null) {
              sink.add(chunk);
              received += chunk.length;
              report();
            } else {
              batch.add(chunk);
              if (batch.length < _sealBatch) continue;
              if (!await drain()) {
                broke = true;
                sealBroke = true;
                break;
              }
            }
            // WHAT THE VIEWER IS WATCHING COMES FIRST. While a film streams,
            // this download keeps to ForegroundStream's pace so the film's
            // buffer fills first; the moment the viewer stops, full speed.
            if (ForegroundStream.active) {
              final wait = ForegroundStream.paceDelay(
                bytes: received - paceBase,
                elapsed: DateTime.now().difference(paceFrom),
              );
              if (wait > Duration.zero) {
                await Future<void>.delayed(
                    wait > _maxPaceWait ? _maxPaceWait : wait);
              }
            } else {
              paceFrom = DateTime.now();
              paceBase = received;
              // They stopped watching: end this one-connection pass cleanly
              // and let the next one split. Only once it has moved enough to
              // count as progress, so this can never turn into a retry delay.
              if (rejoin && received - beforePass >= _realProgress) break;
            }
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
                  key: key,
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
          if (e is RangedFetchException && e.refused) _rangesRefused.add(key);
          if (kDebugMode) debugPrint('offline stream broke at $received: $e');
          PlaybackLog.add('dl broke: ${e.runtimeType}');
        } finally {
          // What gathered but was not yet written: written now, so a pass that
          // ends — cleanly, by cancel, or by a dropped connection — leaves the
          // part file holding every byte it was handed, and a resume carries
          // on from exactly there.
          try {
            if (!sealBroke && !await drain()) sealBroke = broke = true;
          } catch (_) {
            sealBroke = broke = true;
          }
          await sink.flush();
          await sink.close();
        }

        {
          final secs = DateTime.now().difference(passStarted).inMilliseconds / 1000;
          final got = received - beforePass;
          PlaybackLog.add('dl pass end +${got >> 20} MB in ${secs.toStringAsFixed(0)} s '
              '(${secs > 0 ? (got / secs / 1048576).toStringAsFixed(2) : '-'} MB/s)'
              '${broke ? ' broke' : ''}${sealBroke ? ' seal' : ''}${ranOut ? ' full' : ''}');
        }
        if (_cancelled.contains(key)) return null;
        // REAL PROGRESS CLEARS THE BUDGET. A download that is moving, however
        // slowly and however often it is interrupted, is a download that is
        // working, and the give-up count is for the other kind. Measured
        // against [_realProgress] rather than against any byte at all, so an
        // attempt that dies during its first packet cannot keep the loop alive
        // for ever.
        final gained = received - beforePass;
        // A PASS THAT DIED IN THE CIPHER IS NOT A HEALTHY PASS, however many
        // bytes it moved first. Without this it would clear the budget and the
        // loop would keep asking a broken cipher for ever.
        if (gained >= _realProgress && !sealBroke) {
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
            ivNote: ivNote,
            sealer: sealer,
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
            ivNote: ivNote,
            sealer: sealer,
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
        key: key,
        received: received,
        total: total,
        error: 'gave_up',
      ));
      return null;
    } finally {
      // The notification and the locks go whatever happened. A download that
      // stopped must not leave a foreground service pinning the CPU.
      if (serviceUp) await OfflineServiceBridge.stop();
      // NOTHING WRITTEN MEANS NOTHING TO RESUME. A refusal, a cancel before
      // the first byte, or a No to the size question would otherwise leave a
      // row on the Downloads screen offering to continue a download that has
      // not got a single byte behind it — clutter that has to be dismissed by
      // hand, on the screen whose job is to be reassuring.
      if (received <= 0) {
        try {
          await _library.dropPending(key);
        } catch (_) {}
      }
    }
  }

  /// Decides whether this download is sealed, and under which IV.
  ///
  /// THE PART FILE DECIDES, NOT THE SETTING. A resume must continue exactly as
  /// it started: the sidecar's presence says it started sealed, its absence says
  /// it did not, and neither is overruled here. Only a download with nothing on
  /// disk gets to ask the platform.
  ///
  /// A null return is not a failure. It is "this film will be a plain file",
  /// which is what every download before this feature was and what a phone whose
  /// Keystore will not answer still gets. FAIL OPEN, DELIBERATELY: a viewer who
  /// cannot download at all is a worse outcome than a file that is not
  /// encrypted, and the decision is recorded in `docs/offline_first_plan.md` so
  /// it is not quietly reversed.
  Future<_Sealer?> _sealerFor({
    required File part,
    required File ivNote,
    required int at,
  }) async {
    try {
      if (await part.exists()) {
        if (!await ivNote.exists()) return null;
        final iv = (await ivNote.readAsString()).trim();
        if (iv.isEmpty) return null;
        return _Sealer(iv: iv, at: at);
      }
      // A stale sidecar with no part file beside it belongs to a download that
      // was deleted; reusing its IV would be reusing a keystream.
      try {
        if (await ivNote.exists()) await ivNote.delete();
      } catch (_) {}
      if (!await OfflineCrypto.available()) return null;
      final iv = await OfflineCrypto.newIv();
      if (iv == null) return null;
      await ivNote.writeAsString(iv, flush: true);
      return _Sealer(iv: iv, at: 0);
    } catch (e) {
      if (kDebugMode) debugPrint('offline sealer: $e');
      return null;
    }
  }

  Future<OfflineItem?> _finish({
    required VideoContent content,
    required String? assetId,
    required File part,
    required File sizeNote,
    required File ivNote,
    required _Sealer? sealer,
    required String finalPath,
    required int bytes,
    required String label,
    required DownloadNotices notices,
    required void Function(OfflineProgress) emit,
  }) async {
    // THE TRAILER, AND THEN NOTHING ELSE IS WRITTEN. Until it is there the file
    // is ciphertext that nothing can identify as ciphertext, which is exactly
    // what a part file should be; once it is there the film is self-describing
    // and does not need the sidecar, the shelf row or this build to be readable
    // again.
    if (sealer != null) {
      final ok = await sealer.seal(part, plainLength: bytes);
      if (!ok) {
        // A sealed film whose trailer would not write is a film nothing can
        // open. Better to say the download failed — with the bytes kept, so a
        // retry resumes rather than starting again — than to hand somebody a
        // finished row over a file that plays as noise.
        emit(OfflineProgress(
          key: offlineKeyFor(content.id, assetId: assetId),
          received: bytes,
          total: bytes,
          error: 'seal_failed',
        ));
        await OfflineServiceBridge.stop();
        return null;
      }
    }

    // RENAME LAST. Until this line there is only a `.part` file, which no
    // reader trusts; after it there is a finished file AND an index entry.
    // A crash between the two leaves a file with no entry, which the next
    // `dropAll` sweeps — far better than an entry with no file, which is a
    // row that spins forever when tapped.
    await part.rename(finalPath);
    try {
      if (await sizeNote.exists()) await sizeNote.delete();
    } catch (_) {}
    try {
      if (await ivNote.exists()) await ivNote.delete();
    } catch (_) {}

    final key = offlineKeyFor(content.id, assetId: assetId);
    final item = OfflineItem(
      titleId: content.id,
      key: key,
      title: content.title,
      titleMm: content.titleMm,
      posterUrl: content.poster.isEmpty ? null : content.poster.locator,
      path: finalPath,
      bytes: bytes,
      addedAt: DateTime.now(),
      assetId: assetId,
      // RECORDED, NOT ASSUMED. The Downloads screen used to open every item as
      // premium, which showed the paywall over a FREE film somebody had just
      // spent an hour of mobile data on.
      premium: content.accessTier == AccessTier.premium,
      // Whether this one is ciphertext. The shelf has to know: a sealed film is
      // longer than the object it came from and cannot be handed to the player
      // as a path.
      sealed: sealer != null,
    );
    await _library.put(item);
    await _library.dropPending(key);
    emit(OfflineProgress(
      key: key,
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

  /// Sleep for [total], or until the network answers, whichever is sooner.
  ///
  /// Returns false when the download was cancelled while waiting, so the caller
  /// stops instead of carrying on into a transfer nobody is waiting for.
  Future<bool> _waitForNetwork(Duration total, String key) async {
    const step = Duration(seconds: 2);
    var waited = Duration.zero;
    // The first step is always taken. Retrying the instant a request failed is
    // what makes a bad link into a hammered one, and the DNS probe itself
    // needs the radio to have come back.
    while (waited < total) {
      await Future<void>.delayed(step);
      waited += step;
      if (_cancelled.contains(key)) return false;
      if (waited >= total) break;
      // Cheap: a DNS lookup against a host the OS has almost certainly cached,
      // and it fails fast when there is no radio. Costs nothing on a link that
      // is down and saves most of a minute on one that has just come back.
      if (await const ConnectivityService().isOnline(
        timeout: const Duration(seconds: 2),
      )) {
        return true;
      }
    }
    return !_cancelled.contains(key);
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

/// The extension a downloaded photo is stored under, from its URL.
///
/// Only for the benefit of a human with a file browser — the decoder reads the
/// bytes, not the name — so anything unrecognised is `.img` rather than a
/// guess.
@visibleForTesting
String photoExtension(String url) {
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  for (final ext in const <String>['.jpg', '.jpeg', '.png', '.webp', '.gif', '.heic']) {
    if (path.endsWith(ext)) return ext;
  }
  return '.img';
}

/// Ciphers a download as it arrives.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS AS SMALL AS IT IS
/// ═══════════════════════════════════════════════════════════════════════
///
/// There is no buffer, no block alignment and no state carried across a process
/// death, because CTR is addressable by byte: the cipher is told which offset a
/// run of bytes belongs at and works out the rest. So a chunk from the network
/// goes straight through whatever its length, a resume simply starts counting
/// from the part file's own length, and there is nothing to get out of step.
///
/// The first version of this held a fifteen-byte remainder to keep every write
/// block-aligned. It was deleted once the offset interface made it unnecessary —
/// which is worth recording, because it looks like an omission.
class _Sealer {
  _Sealer({
    required this.iv,
    required int at,
  }) : _at = at;

  final String iv;

  /// How far into the FILM the next byte goes. Plaintext offsets throughout —
  /// the ciphertext is the same length, which is the whole reason this works.
  int _at;

  /// Returns the bytes to write, or null when the cipher would not answer.
  Future<List<int>?> take(List<int> chunk) async {
    if (chunk.isEmpty) return chunk;
    final bytes = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
    final out = await OfflineCrypto.transform(
      iv: iv,
      offset: _at,
      bytes: bytes,
    );
    if (out == null) return null;
    _at += bytes.length;
    return out;
  }

  /// Writes the trailer that makes the file a film rather than a part file.
  ///
  /// IDEMPOTENT, because this can be reached twice for one film: the app can be
  /// killed between this line and the rename that follows it, and the next run
  /// arrives here with the trailer already written. Appending a second one would
  /// leave the first thirty-two bytes of it inside the film.
  Future<bool> seal(File part, {required int plainLength}) async {
    IOSink? sink;
    try {
      final already = await OfflineCrypto.inspect(part);
      if (already != null && already.plainLength == plainLength) return true;
      final trailer = OfflineCrypto.composeTrailer(
        iv: Uint8List.fromList(base64Decode(iv)),
        plainLength: plainLength,
      );
      sink = part.openWrite(mode: FileMode.append);
      sink.add(trailer);
      await sink.flush();
      return true;
    } catch (e) {
      if (kDebugMode) debugPrint('offline seal: $e');
      return false;
    } finally {
      try {
        await sink?.close();
      } catch (_) {}
    }
  }
}
