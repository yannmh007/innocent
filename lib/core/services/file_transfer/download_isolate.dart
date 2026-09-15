import 'dart:async';
import 'dart:io';
import 'dart:isolate';

/// ---------------------------------------------------------------------------
/// The byte-moving half of the receiver, deliberately free of Flutter.
///
/// WHY IT LIVES HERE
/// Until now the download loop ran on the UI isolate, which meant the socket
/// pump, the file writes and every widget rebuild took turns on one thread. At
/// 25 MB/s the loop wakes hundreds of times a second, so a busy frame directly
/// throttled the transfer and a fast transfer directly janked the list. Moving
/// it to a background isolate is the largest software lever left.
///
/// Nothing in this file imports package:flutter. That is not tidiness — a
/// background isolate has no Flutter binding, so a stray `debugPrint` or
/// `kDebugMode` would throw the moment it ran there. It also means the SAME
/// code can run in-process as a fallback when Isolate.spawn is unavailable,
/// which is the point: one implementation, two hosts, no divergence to drift.
///
/// The isolate does ONLY networking and file writes. Media scanning, the
/// resume record, history and the final rename stay on the main isolate, where
/// the plugins and SharedPreferences already are — so no platform channel and
/// no RootIsolateToken is needed here at all.
/// ---------------------------------------------------------------------------

/// One file to fetch. Everything is resolved before it crosses the isolate
/// boundary: the destination is an absolute ".part" path, never a directory to
/// work out on the far side.
class TransferJob {
  final String baseUrl;
  final int index;
  final String partPath;

  /// Expected size from the manifest. 0 means unknown, which disables both the
  /// parallel split and the completeness check.
  final int size;

  /// How many concurrent range requests to use. 1 forces the sequential path.
  final int segments;

  const TransferJob({
    required this.baseUrl,
    required this.index,
    required this.partPath,
    required this.size,
    required this.segments,
  });

  Map<String, Object> toMap() => {
        'baseUrl': baseUrl,
        'index': index,
        'partPath': partPath,
        'size': size,
        'segments': segments,
      };

  factory TransferJob.fromMap(Map<Object?, Object?> m) => TransferJob(
        baseUrl: m['baseUrl'] as String,
        index: (m['index'] as num).toInt(),
        partPath: m['partPath'] as String,
        size: (m['size'] as num).toInt(),
        segments: (m['segments'] as num).toInt(),
      );
}

/// Progress callback. [paused] is true while the sender is holding the
/// transfer — a state that must look different from "stalled", or the user
/// stares at a frozen bar wondering whether it died.
typedef EngineProgress = void Function(
    int received, int total, double bytesPerSec, bool paused);

/// Thrown internally when the sender answers 503: not a failure, a wait.
class _PausedBySender implements Exception {
  final int seconds;
  const _PausedBySender(this.seconds);
}

/// Raised when the caller cancels. Distinct from a network error so the retry
/// logic doesn't treat a deliberate stop as something to fight through.
class TransferCancelled implements Exception {
  const TransferCancelled();
  @override
  String toString() => 'Cancelled';
}

class TransferEngine {
  /// Files at or above this size use parallel range requests.
  static const int parallelThreshold = 4 * 1024 * 1024;

  /// Buffer incoming chunks to ~1 MB before each positioned write, so the disk
  /// sees a few large writes instead of thousands of small ones.
  static const int _writeBufBytes = 1024 * 1024;

  /// Total time we are willing to sit in "sender paused" before calling it a
  /// failure. Long, because a pause is a deliberate human act — someone taking
  /// a call, walking to the other room — and killing their transfer after
  /// thirty seconds would be worse than useless.
  static const int _maxPausedWaitMs = 10 * 60 * 1000;

  /// How long a response body may deliver NOTHING before the attempt is
  /// abandoned.
  ///
  /// WHY THIS EXISTS. `connectionTimeout` bounds the TCP connect and
  /// `idleTimeout` bounds a POOLED, NON-ACTIVE connection. Neither bounds a
  /// body that started arriving and then stopped — and that is the ordinary
  /// case here, not an exotic one: the sending phone's screen goes off,
  /// Android freezes the app mid-share, and the TCP connection is left
  /// half-open with nothing to signal it. See docs/audit_transfer.md T1.
  ///
  /// The retry loop in [run] was already correct and already generous — four
  /// attempts with backoff. It simply never got to run, because attempt one
  /// never ended. This turns a permanent hang into the retry the code was
  /// already built for.
  ///
  /// 30 seconds, not the 60 the audit suggested, because the clock measures
  /// ZERO BYTES rather than throughput: a link delivering one byte every 29
  /// seconds resets it. Half a minute of complete silence mid-body on a LAN
  /// means the peer is gone. Four attempts then cost ~2 minutes before the
  /// file is given up and the batch moves on, which matters because
  /// `state.batchRunning` gates the Turbo idle release — a batch that never
  /// ends is a phone that never gets its internet back.
  ///
  /// A PAUSE IS NOT A STALL and cannot be caught by this. The sender signals
  /// a pause with HTTP 503 on a new request, and truncates the body on an
  /// in-flight one — a truncation ENDS the stream rather than stalling it, so
  /// it lands on the byte-count check and the 503 path, both of which already
  /// exist and are deliberately outside the error budget.
  static const Duration defaultStallTimeout = Duration(seconds: 30);

  /// Overridable only so a test can prove the watchdog fires without waiting
  /// half a minute for it. Production always takes the default — the isolate
  /// worker constructs `TransferEngine()` with no arguments, and so does the
  /// in-process fallback.
  final Duration stallTimeout;

  TransferEngine({Duration? stallTimeout})
      : stallTimeout = stallTimeout ?? defaultStallTimeout;

  HttpClient? _client;
  HttpClientRequest? _activeReq;
  final List<HttpClientRequest> _activeReqs = [];
  bool _cancelled = false;
  bool _pausedBySender = false;

  bool get isCancelled => _cancelled;
  bool get isPausedBySender => _pausedBySender;

  /// One client for the whole batch. Every file used to dial a fresh TCP
  /// connection; on a 300-photo batch that is 300 handshakes paid in series.
  HttpClient _http() {
    final existing = _client;
    if (existing != null) return existing;
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 40)
      // The sender never gzips (autoCompress = false), so skip the whole
      // negotiate-and-inflate path between the socket and the file sink.
      ..autoUncompress = false
      ..maxConnectionsPerHost = 12;
    _client = c;
    return c;
  }

  void closeClient() {
    final c = _client;
    _client = null;
    try {
      c?.close(force: true);
    } catch (_) {}
  }

  void cancel() {
    _cancelled = true;
    try {
      _activeReq?.abort();
    } catch (_) {}
    for (final r in List<HttpClientRequest>.of(_activeReqs)) {
      try {
        r.abort();
      } catch (_) {}
    }
    _activeReqs.clear();
    _activeReq = null;
    closeClient();
  }

  void resetCancel() {
    _cancelled = false;
    _pausedBySender = false;
  }

  /// Sleep in short slices so a cancel lands promptly instead of after the
  /// whole backoff has elapsed.
  Future<void> _sleep(int ms) async {
    var left = ms;
    while (left > 0 && !_cancelled) {
      final slice = left > 250 ? 250 : left;
      await Future<void>.delayed(Duration(milliseconds: slice));
      left -= slice;
    }
  }

  static int _retryAfterSeconds(HttpClientResponse resp) {
    // Literal rather than HttpHeaders.retryAfterHeader: one less constant
    // whose presence depends on the SDK version, in a file the compiler
    // has not yet had a chance to check.
    final raw = resp.headers.value('retry-after');
    final n = int.tryParse((raw ?? '').trim());
    if (n == null) return 2;
    return n < 1 ? 1 : (n > 15 ? 15 : n);
  }

  /// Fetch one job into its ".part" file. Throws on failure; the partial file
  /// is deliberately left on disk so the next attempt resumes by byte.
  Future<void> run(TransferJob job, EngineProgress onProgress) async {
    final file = File(job.partPath);
    final hasPartial = await file.exists() && (await file.length()) > 0;

    // Parallel path only for a FRESH download: it opens with FileMode.write
    // and writes segments at offsets, so running it over an existing ".part"
    // would wipe the resume progress.
    if (job.size >= parallelThreshold &&
        job.segments > 1 &&
        !_cancelled &&
        !hasPartial) {
      try {
        await _runParallel(job, file, onProgress);
        return;
      } catch (e) {
        // A failed parallel run can leave holes at segment boundaries. Never
        // hand that file to the sequential RESUME path — it would append after
        // the holes and produce a corrupt file that passes the size check.
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        if (_cancelled) rethrow;
      }
    }

    const maxErrorAttempts = 4;
    var errors = 0;
    var pausedWaitMs = 0;
    Object? lastError;
    while (true) {
      if (_cancelled) throw const TransferCancelled();
      try {
        await _runSequential(job, file, onProgress);
        _pausedBySender = false;
        return;
      } on _PausedBySender catch (p) {
        // A pause is not an error and must not eat the error budget, or a
        // two-minute pause would end the transfer.
        _pausedBySender = true;
        onProgress(await _sizeOf(file), job.size, 0, true);
        if (pausedWaitMs >= _maxPausedWaitMs) {
          lastError = Exception('The sender paused for too long.');
          break;
        }
        await _sleep(p.seconds * 1000);
        pausedWaitMs += p.seconds * 1000;
        continue;
      } catch (e) {
        _pausedBySender = false;
        lastError = e;
        if (_cancelled) break;
        errors++;
        if (errors >= maxErrorAttempts) break;
        await _sleep(400 * errors);
      }
    }
    if (_cancelled) throw const TransferCancelled();
    throw lastError ?? Exception('Download failed');
  }

  static Future<int> _sizeOf(File f) async {
    try {
      return await f.exists() ? await f.length() : 0;
    } catch (_) {
      return 0;
    }
  }

  // ---- sequential / resume path ----------------------------------------

  Future<void> _runSequential(
      TransferJob job, File target, EngineProgress onProgress) async {
    final existing = await _sizeOf(target);
    final client = _http();
    IOSink? sink;
    try {
      final req = await client.getUrl(Uri.parse('${job.baseUrl}/${job.index}'));
      if (existing > 0) {
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
      }
      _activeReq = req;
      final resp = await req.close();
      if (resp.statusCode == HttpStatus.serviceUnavailable) {
        // The sender is paused. Drain so the connection can be reused.
        try {
          await resp.drain();
        } catch (_) {}
        throw _PausedBySender(_retryAfterSeconds(resp));
      }
      final serverResumed = resp.statusCode == 206;
      if (resp.statusCode != 200 && resp.statusCode != 206) {
        throw Exception('Download failed (HTTP ${resp.statusCode}).');
      }
      final int total;
      if (serverResumed) {
        total = existing +
            (resp.contentLength > 0
                ? resp.contentLength
                : (job.size - existing));
      } else {
        total = resp.contentLength > 0 ? resp.contentLength : job.size;
      }
      final startAt = serverResumed ? existing : 0;
      sink = target.openWrite(
          mode: serverResumed ? FileMode.append : FileMode.write);
      var received = startAt;
      var lastTick = DateTime.now();
      var lastReported = received;
      double speed = 0;
      // addStream rather than a manual loop with sink.add: IOSink.add applies
      // NO back-pressure, so when the link outruns the flash write the
      // unwritten chunks pile up in RAM until the OS kills us.
      final counted = resp.timeout(stallTimeout).map((chunk) {
        received += chunk.length;
        final now = DateTime.now();
        final ms = now.difference(lastTick).inMilliseconds;
        if (ms >= 120) {
          final instant = (received - lastReported) * 1000 / ms;
          speed = speed == 0 ? instant : (speed * 0.4 + instant * 0.6);
          onProgress(received, total, speed, false);
          lastReported = received;
          lastTick = now;
        }
        return chunk;
      });
      await sink.addStream(counted);
      onProgress(received, total, speed, false);
      await sink.flush();
      await sink.close();
      sink = null;
      // A dropped link can end the response stream early WITHOUT throwing, so
      // a byte-count mismatch is the only way to notice a truncated file.
      if (total > 0 && received != total) {
        throw Exception(
            'Incomplete download: received $received of $total bytes.');
      }
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      rethrow;
    } finally {
      _activeReq = null;
    }
  }

  // ---- parallel path -----------------------------------------------------

  Future<void> _runParallel(
      TransferJob job, File target, EngineProgress onProgress) async {
    final total = job.size;
    final segCount = job.segments;
    final client = _http();

    final raf = await target.open(mode: FileMode.write);
    try {
      // Preallocate so every positioned write lands inside the file. Purely an
      // optimisation, so a filesystem that refuses truncate doesn't fail us.
      await raf.truncate(total);
    } catch (_) {}

    var written = 0;
    var lastReported = 0;
    var lastTick = DateTime.now();
    double speed = 0;
    void report({bool force = false}) {
      final now = DateTime.now();
      final ms = now.difference(lastTick).inMilliseconds;
      if (!force && ms < 150) return;
      if (ms > 0) {
        final instant = (written - lastReported) * 1000 / ms;
        speed = speed == 0 ? instant : (speed * 0.4 + instant * 0.6);
      }
      onProgress(written, total, speed, _pausedBySender);
      lastReported = written;
      lastTick = now;
    }

    // One shared handle, serialised as a promise chain: each write waits for
    // the previous, so no segment can interleave its setPosition with
    // another's writeFrom. Errors reach the segment that queued the write; the
    // chain itself stays alive for the others.
    Future<void> tail = Future<void>.value();
    Future<void> writeAt(int offset, List<int> bytes) {
      final task = tail.then((_) async {
        await raf.setPosition(offset);
        await raf.writeFrom(bytes);
      });
      tail = task.then((_) {}, onError: (_) {});
      return task;
    }

    Future<void> fetchSegment(int start, int endIncl) async {
      var offset = start;
      var attempt = 0;
      var pausedWaitMs = 0;
      while (true) {
        if (_cancelled) throw const TransferCancelled();
        HttpClientRequest? req;
        try {
          req = await client.getUrl(Uri.parse('${job.baseUrl}/${job.index}'));
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-$endIncl');
          _activeReqs.add(req);
          final resp = await req.close();
          if (resp.statusCode == HttpStatus.serviceUnavailable) {
            try {
              await resp.drain();
            } catch (_) {}
            throw _PausedBySender(_retryAfterSeconds(resp));
          }
          if (resp.statusCode != 206) {
            throw Exception(
                'Sender did not honour ranges (HTTP ${resp.statusCode}).');
          }
          final buf = BytesBuilder(copy: false);
          await for (final chunk in resp.timeout(stallTimeout)) {
            buf.add(chunk);
            if (buf.length >= _writeBufBytes) {
              final bytes = buf.takeBytes();
              await writeAt(offset, bytes);
              offset += bytes.length;
              written += bytes.length;
              report();
            }
          }
          if (buf.isNotEmpty) {
            final bytes = buf.takeBytes();
            await writeAt(offset, bytes);
            offset += bytes.length;
            written += bytes.length;
          }
          report();
          if (offset != endIncl + 1) {
            throw Exception('Segment ended early ($offset of ${endIncl + 1}).');
          }
          return;
        } on _PausedBySender catch (p) {
          // Wait it out WITHOUT spending an attempt, and resume this segment
          // from [offset] — the bytes already written stay written. Handling
          // the pause per segment is what keeps a paused parallel download
          // alive; letting it bubble would abort the run and throw away every
          // segment's progress.
          _pausedBySender = true;
          report(force: true);
          if (pausedWaitMs >= _maxPausedWaitMs) {
            rethrow;
          }
          await _sleep(p.seconds * 1000);
          pausedWaitMs += p.seconds * 1000;
        } catch (e) {
          attempt++;
          if (_cancelled || attempt >= 3) rethrow;
          await _sleep(300 * attempt);
        } finally {
          if (req != null) _activeReqs.remove(req);
        }
      }
    }

    try {
      final per = (total + segCount - 1) ~/ segCount;
      final tasks = <Future<void>>[];
      for (var s = 0; s < segCount; s++) {
        final start = s * per;
        if (start >= total) break;
        final end = (start + per < total ? start + per : total) - 1;
        tasks.add(fetchSegment(start, end));
      }
      await Future.wait(tasks);
      await tail;
      if (written != total) {
        throw Exception('Incomplete download: $written of $total bytes.');
      }
      _pausedBySender = false;
      report(force: true);
    } finally {
      try {
        await tail;
      } catch (_) {}
      try {
        await raf.close();
      } catch (_) {}
      _activeReqs.clear();
    }
  }
}

// ---------------------------------------------------------------------------
// Isolate host
// ---------------------------------------------------------------------------

/// Runs a [TransferEngine] on a background isolate.
///
/// One job at a time, matching how the receiver actually works: files are
/// pulled in order, and running several at once on one Wi-Fi link only splits
/// the same airtime while multiplying the seek load on the flash.
class IsolateDownloader {
  Isolate? _isolate;
  SendPort? _toIsolate;
  ReceivePort? _fromIsolate;
  StreamSubscription<dynamic>? _sub;

  Completer<void>? _jobDone;
  EngineProgress? _onProgress;

  bool get isAlive => _toIsolate != null;

  /// Spawn the worker. Returns null on any failure, and the caller runs the
  /// same engine in-process instead — an isolate is a performance win, never a
  /// requirement, and a device that refuses to spawn one must still transfer.
  static Future<IsolateDownloader?> spawn() async {
    final host = IsolateDownloader();
    try {
      final rp = ReceivePort();
      final iso = await Isolate.spawn(
        _downloadIsolateEntry,
        rp.sendPort,
        errorsAreFatal: false,
        debugName: 'innocent-transfer',
        // TELL US WHEN IT DIES. See docs/audit_transfer.md T2.
        //
        // The worker's own try/catch around engine.run is thorough, so the
        // only way to hang was the isolate ITSELF dying — an out-of-memory
        // kill during a large transfer on a low-RAM phone, which is the
        // realistic case for this app's devices. Without these ports nothing
        // noticed: _jobDone was never completed, isAlive still returned true
        // because _toIsolate was still non-null, and the batch loop waited
        // forever. Same end state as a stalled body, and it held the Turbo
        // idle release shut the same way.
        //
        // Both are routed to the one port this class already listens on, so
        // _onMessage is the single place that decides what a message means.
        onExit: rp.sendPort,
        onError: rp.sendPort,
      ).timeout(const Duration(seconds: 8));
      host._isolate = iso;
      host._fromIsolate = rp;
      final ready = Completer<SendPort>();
      host._sub = rp.listen((msg) => host._onMessage(msg, ready));
      host._toIsolate = await ready.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw TimeoutException('isolate never reported ready'),
      );
      return host;
    } catch (_) {
      await host.dispose();
      return null;
    }
  }

  void _onMessage(dynamic msg, Completer<SendPort> ready) {
    if (msg is SendPort) {
      if (!ready.isCompleted) ready.complete(msg);
      return;
    }
    // THE ISOLATE DIED. `onExit` sends null; `onError` sends a two-element
    // list of [error, stackTrace], both already converted to strings by the
    // VM. Neither is a Map, so both used to fall through the check below and
    // vanish — which is precisely how a dead worker went unnoticed.
    //
    // Fail the job in flight and mark the worker dead, so isAlive stops lying
    // and downloadFile falls back to the in-process engine on the next file.
    // That fallback already exists and is already correct; it was simply
    // unreachable.
    if (msg == null || msg is List) {
      _toIsolate = null;
      final c = _jobDone;
      _jobDone = null;
      _onProgress = null;
      if (c != null && !c.isCompleted) {
        c.completeError(
          Exception(msg is List && msg.isNotEmpty
              ? 'Transfer worker died: ${msg.first}'
              : 'Transfer worker exited unexpectedly'),
        );
      }
      // The spawn handshake can also die here — never leave it hanging for
      // its full eight seconds when we already know the answer.
      if (!ready.isCompleted) {
        ready.completeError(Exception('isolate died before reporting ready'));
      }
      return;
    }
    if (msg is! Map) return;
    switch (msg['t']) {
      case 'p':
        _onProgress?.call(
          (msg['r'] as num).toInt(),
          (msg['tt'] as num).toInt(),
          (msg['s'] as num).toDouble(),
          msg['pa'] == true,
        );
        break;
      case 'done':
        final c = _jobDone;
        _jobDone = null;
        _onProgress = null;
        if (c != null && !c.isCompleted) c.complete();
        break;
      case 'err':
        final c = _jobDone;
        _jobDone = null;
        _onProgress = null;
        if (c != null && !c.isCompleted) {
          c.completeError(msg['cancelled'] == true
              ? const TransferCancelled()
              : Exception(msg['m'] as String? ?? 'Download failed'));
        }
        break;
    }
  }

  Future<void> run(TransferJob job, EngineProgress onProgress) {
    final port = _toIsolate;
    if (port == null) {
      return Future<void>.error(StateError('isolate not running'));
    }
    if (_jobDone != null) {
      return Future<void>.error(StateError('a job is already running'));
    }
    final c = Completer<void>();
    _jobDone = c;
    _onProgress = onProgress;
    port.send({'t': 'job', ...job.toMap()});
    return c.future;
  }

  void cancel() => _toIsolate?.send({'t': 'cancel'});
  void resetCancel() => _toIsolate?.send({'t': 'reset'});
  void closeClient() => _toIsolate?.send({'t': 'close'});

  Future<void> dispose() async {
    try {
      _toIsolate?.send({'t': 'quit'});
    } catch (_) {}
    _toIsolate = null;
    // Give the worker a beat to close its sockets before the hard kill, so a
    // half-written ".part" is flushed rather than truncated mid-write.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    try {
      _fromIsolate?.close();
    } catch (_) {}
    _fromIsolate = null;
    try {
      _isolate?.kill(priority: Isolate.immediate);
    } catch (_) {}
    _isolate = null;
    final c = _jobDone;
    _jobDone = null;
    _onProgress = null;
    if (c != null && !c.isCompleted) {
      c.completeError(const TransferCancelled());
    }
  }
}

/// Worker entry point. Must be a top-level function — Isolate.spawn cannot
/// take a closure.
void _downloadIsolateEntry(SendPort toMain) {
  final engine = TransferEngine();
  final rp = ReceivePort();
  toMain.send(rp.sendPort);

  rp.listen((msg) async {
    if (msg is! Map) return;
    switch (msg['t']) {
      case 'job':
        final job = TransferJob.fromMap(msg.cast<Object?, Object?>());
        try {
          await engine.run(job, (r, tt, s, pa) {
            toMain.send({'t': 'p', 'r': r, 'tt': tt, 's': s, 'pa': pa});
          });
          toMain.send({'t': 'done'});
        } catch (e) {
          toMain.send({
            't': 'err',
            'm': '$e',
            'cancelled': e is TransferCancelled || engine.isCancelled,
          });
        }
        break;
      case 'cancel':
        engine.cancel();
        break;
      case 'reset':
        engine.resetCancel();
        break;
      case 'close':
        engine.closeClient();
        break;
      case 'quit':
        engine.cancel();
        rp.close();
        break;
    }
  });
}
