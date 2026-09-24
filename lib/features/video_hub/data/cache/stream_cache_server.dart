import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../../core/services/network/throughput_memory.dart';
import 'stream_cache_store.dart';

/// Gives the player a local address for a remote film, and keeps what passes
/// through.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY A SERVER INSIDE THE APP
/// ═══════════════════════════════════════════════════════════════════════
///
/// libmpv opens a URL and asks it for byte ranges. There is no way to hand it
/// "these bytes from disk and the rest from the network" — so the only place
/// a cache can go is between it and the network, wearing the shape of an HTTP
/// server. This is the same design ExoPlayer ships as `CacheDataSource` and
/// the same one Telegram's player uses. There is no lighter way that works
/// with an off-the-shelf demuxer.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IT DOES WITH AN EXPIRED LINK, WHICH IS THE QUIET WIN
/// ═══════════════════════════════════════════════════════════════════════
///
/// A signed URL lives ten minutes and a film does not. Until now that was the
/// player's problem: the stream died, an error surfaced, the retry path asked
/// for a fresh URL and reopened — a visible stumble, once every ten minutes,
/// on a long film. The proxy holds the refresh closure itself, so an expired
/// upstream is replaced and the same request continues. The player never
/// learns it happened.
///
/// A refusal that is NOT expiry — a lapsed subscription, a device limit — is
/// still a refusal and still arrives as one. The refresh goes through
/// `request-playback` exactly as the player's own renewal did, so entitlement
/// is re-decided every time rather than cached alongside the bytes.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY ANOTHER APP ON THE PHONE CANNOT USE IT
/// ═══════════════════════════════════════════════════════════════════════
///
/// Loopback is not private on Android: any app may connect to 127.0.0.1 on
/// any port. The port alone therefore protects nothing, and the address
/// carries a random token minted once per process. Without it a request is
/// refused before the store is touched. The token never leaves the device —
/// it is handed to libmpv in-process and appears in no log, no event and no
/// URL that goes out.
class StreamCacheServer {
  StreamCacheServer._();
  static final StreamCacheServer instance = StreamCacheServer._();

  HttpServer? _server;
  String? _token;

  final Map<String, _Source> _sources = <String, _Source>{};

  /// How much to ask upstream for when the player wants a small piece.
  ///
  /// Eight megabytes. A demuxer asks for a few hundred kilobytes at a time;
  /// answering exactly that would mean one HTTP request per few hundred
  /// kilobytes of film, which is the shape of a connection that never leaves
  /// slow start. Reading further ahead than asked costs nothing, because
  /// those are the bytes wanted next.
  static const int _chunk = 8 * 1024 * 1024;

  /// Record a run's growth this often rather than per packet: a viewer's
  /// flash memory should not be asked for an fsync per network chunk.
  static const int _flushEvery = 4 * 1024 * 1024;

  static const int _upstreamTries = 3;

  bool get running => _server != null;

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final rnd = Random.secure();
    _token = List<int>.generate(24, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle, onError: (Object e) {
      if (kDebugMode) debugPrint('StreamCacheServer: $e');
    });
    _server = s;
  }

  /// Register a film and get the local address to play instead.
  ///
  /// Returns null when the cache cannot be used, and the caller then plays
  /// [upstream] directly — which is what the app did before any of this
  /// existed, so a broken cache costs smoothness and never playback.
  Future<String?> localUrlFor({
    required String cacheId,
    required String upstream,
    required Future<String?> Function() refresh,
    int? total,
    String label = '',
  }) async {
    try {
      await StreamCacheStore.instance.load();
      await _ensureStarted();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;

      await StreamCacheStore.instance
          .entryFor(cacheId, total: total, label: label);
      _sources[cacheId] = _Source(upstream: upstream, refresh: refresh);
      // THE BUDGET IS NOT ENFORCED HERE, and that is deliberate. This runs on
      // the path to the first frame — the path this project has spent weeks
      // taking delays out of — and enforcing the budget can mean deleting
      // directories, which is exactly the kind of work that turns into a
      // black screen somebody notices. The first write asks instead, where a
      // pause costs nothing anyone can see.
      //
      // The id is a path segment rather than a query parameter because some
      // demuxers rewrite query strings when they build range requests, and
      // an id that changes between two reads is two cache entries.
      return 'http://127.0.0.1:$port/c/$token/$cacheId';
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer.localUrlFor: $e');
      return null;
    }
  }

  /// Point an already-registered film at a fresh upstream URL.
  void updateUpstream(String cacheId, String upstream) {
    _sources[cacheId]?.upstream = upstream;
  }

  /// Stop serving a film, so a stale signed URL and its refresh closure do
  /// not outlive the screen that made them.
  void release(String cacheId) => _sources.remove(cacheId);

  /// Forget every film but these.
  ///
  /// Called when a new one opens. A `_Source` holds a signed URL and a
  /// closure over the screen that made it; left to accumulate, one per
  /// playback for the life of the process, they would keep both alive long
  /// after the screen is gone. Registering is the only moment at which it is
  /// certain which ones still matter.
  void releaseAllExcept(Set<String> keep) {
    _sources.removeWhere((id, _) => !keep.contains(id));
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (parts.length != 3 || parts[0] != 'c' || parts[1] != _token) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      final id = parts[2];
      final src = _sources[id];
      if (src == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      await _serve(req, res, id, src);
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer._handle: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(
      HttpRequest req, HttpResponse res, String id, _Source src) async {
    final store = StreamCacheStore.instance;
    var entry = await store.entryFor(id);

    // The length must be known before a single header is written, and on a
    // cold entry nobody has asked upstream yet. One two-byte ranged request
    // settles it.
    //
    // IT IS ALSO ASKED ONCE PER FILM PER SESSION EVEN WHEN THE LENGTH IS
    // ALREADY KNOWN, and that is the only check standing between a viewer
    // and yesterday's bytes. The id is derived from the title, the asset and
    // the rung — not from the object — so an operator who replaces a file
    // keeps the same id. The length is what changes, and comparing it is
    // what turns "probably fine" into "checked". It costs two bytes.
    if (entry.total <= 0 || !src.checkedTotal) {
      final probed = await _probeTotal(src);
      if (probed <= 0 && entry.total <= 0) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }
      if (probed > 0) {
        src.checkedTotal = true;
        if (entry.total > 0 && entry.total != probed) {
          // A different file behind the same name. What is on disk belongs
          // to a video nobody asked for.
          await store.remove(id);
          entry = await store.entryFor(id, total: probed);
        } else if (entry.total <= 0) {
          entry.total = probed;
          await store.touch(entry);
        }
      }
    }
    final total = entry.total;

    // HTTP ranges are inclusive at both ends and everything inside the cache
    // is half-open. The conversion happens here, once.
    var start = 0;
    var endInclusive = total - 1;
    final header = req.headers.value(HttpHeaders.rangeHeader);
    final partial = header != null && header.startsWith('bytes=');
    if (partial) {
      final spec = header.substring(6).split('-');
      if (spec.isNotEmpty && spec[0].isNotEmpty) {
        start = int.tryParse(spec[0]) ?? 0;
      }
      if (spec.length > 1 && spec[1].isNotEmpty) {
        endInclusive = int.tryParse(spec[1]) ?? endInclusive;
      }
      if (start < 0 || start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      if (endInclusive >= total) endInclusive = total - 1;
      if (endInclusive < start) endInclusive = start;
    }

    res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.contentLengthHeader, '${endInclusive - start + 1}');
    if (partial) {
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$endInclusive/$total');
    }
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }

    var pos = start;
    try {
      while (pos <= endInclusive) {
        final before = pos;

        // ── from disk, for as far as this run reaches ──────────────────
        final part = entry.partAt(pos);
        if (part != null) {
          pos = await _fromDisk(res, part, pos, endInclusive);
          if (pos == before) break;
          continue;
        }

        // ── from upstream, keeping what passes through ─────────────────
        pos = await _fromUpstream(res, store, entry, src, pos, endInclusive);
        // No progress means upstream gave nothing and will keep giving
        // nothing. The response is already committed, so the honest end is
        // to stop writing: the player sees a short read, treats it as a
        // dropped connection, and its retry path is exactly for that.
        if (pos == before) break;
      }
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// `addStream` AND NOT `add`, AND THIS IS NOT A STYLE CHOICE.
  ///
  /// `HttpResponse.add` never blocks: it queues. Reading a cached film off
  /// flash at a hundred megabytes a second and queueing it for a socket that
  /// drains at two would hold the difference in memory — the whole film,
  /// eventually, in a process with a few hundred megabytes to live in. The
  /// first version of this file did exactly that in a tight loop.
  ///
  /// `addStream` propagates back-pressure: the socket pauses the file stream,
  /// and the read slows to the speed the player consumes. Nothing is held.
  Future<int> _fromDisk(
      HttpResponse res, CachePart part, int pos, int endInclusive) async {
    final from = pos - part.start;
    final toExclusive = min(part.end - 1, endInclusive) - part.start + 1;
    if (toExclusive <= from) return pos;
    try {
      await res.addStream(part.file.openRead(from, toExclusive));
      return pos + (toExclusive - from);
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer._fromDisk: $e');
      // The client went away, or the run is shorter than its record claimed.
      // Either way this request is over; returning [pos] unchanged stops the
      // loop rather than spinning on a read that cannot progress.
      return pos;
    }
  }

  Future<int> _fromUpstream(HttpResponse res, StreamCacheStore store,
      CacheEntry entry, _Source src, int pos, int endInclusive) async {
    // Read ahead past what was asked, but never past a run already held:
    // those bytes are here, and fetching them again would waste the
    // viewer's data to write a duplicate.
    final until = min(entry.nextPartStart(pos, entry.total), entry.total);
    final fetchEnd = min(min(pos + _chunk, until) - 1, entry.total - 1);
    if (fetchEnd < pos) return pos;

    final upstream = await _openUpstream(src, pos, fetchEnd);
    if (upstream == null) return pos;

    CacheWriter? writer;
    if (await store.hasRoom(protecting: entry.id)) {
      writer = await store.openWriter(entry, pos);
    }

    // Counted inside the tee rather than after it: `addStream` may stop part
    // way — the client closed, the connection dropped — and the caller has
    // to resume from what actually went out, not from what was asked for.
    var sent = 0;
    final startedAt = DateTime.now();
    try {
      await res.addStream(_tee(upstream, writer, (n) => sent += n));
      _recordThroughput(sent, DateTime.now().difference(startedAt));
      return pos + sent;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer._fromUpstream: $e');
      return pos + sent;
    } finally {
      if (writer != null) await store.touch(entry);
    }
  }

  /// Write each chunk to the cache, then hand it on.
  ///
  /// IN THAT ORDER. Yielding first and writing after would let `addStream`
  /// pause this generator between the two, so a client that closed mid-film
  /// would leave the last chunk sent but not recorded — a run whose file is
  /// shorter than the bytes the player received, which is the one asymmetry
  /// that cannot be detected later.
  ///
  /// The writer is closed here rather than by the caller because `addStream`
  /// can abandon the stream without an error reaching anyone, and a handle
  /// left open holds the single-writer claim for the rest of the session.
  Stream<List<int>> _tee(
    Stream<List<int>> src,
    CacheWriter? writer,
    void Function(int) counted,
  ) async* {
    var sinceFlush = 0;
    var w = writer;
    try {
      await for (final chunk in src) {
        if (w != null) {
          try {
            await w.write(chunk);
            sinceFlush += chunk.length;
            if (sinceFlush >= _flushEvery) {
              await w.flush();
              sinceFlush = 0;
            }
          } catch (e) {
            // A DISK THAT WILL NOT TAKE THE BYTES IS NOT A REASON TO STOP
            // THE FILM. Full, read-only, removed, whatever it is: give up on
            // keeping this one and keep playing. The rest of the film simply
            // is not cached, which is the state everything was in yesterday.
            if (kDebugMode) debugPrint('StreamCacheServer: cache write: $e');
            final dead = w;
            w = null;
            await dead.close();
          }
        }
        counted(chunk.length);
        yield chunk;
      }
    } finally {
      await w?.close();
    }
  }

  /// THE ONLY HONEST MEASUREMENT OF THE VIEWER'S CONNECTION once the cache
  /// exists.
  ///
  /// The player measures how fast bytes reach libmpv, and through this proxy
  /// a cached film reaches it at flash speed. Believing that would open the
  /// next film at a rung the connection cannot carry — the exact failure the
  /// ladder was built to end. These bytes, by construction, crossed the
  /// network.
  ///
  /// SMALL AND SHORT FETCHES ARE IGNORED. A quarter-megabyte that finishes
  /// in fifty milliseconds is mostly the handshake, and reading a connection
  /// speed off it says more about latency than bandwidth.
  void _recordThroughput(int bytes, Duration took) {
    if (bytes < 1024 * 1024) return;
    final ms = took.inMilliseconds;
    if (ms < 400) return;
    final kbps = (bytes * 8) ~/ ms;
    unawaited(ThroughputMemory.observe(kbps));
  }

  Future<int> _probeTotal(_Source src) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15);
      try {
        final r = await client.getUrl(Uri.parse(src.upstream));
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=0-1');
        final resp = await r.close();
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader);
        final code = resp.statusCode;
        final len = resp.contentLength;
        await resp.drain<void>();
        if (code == 206 && cr != null && cr.contains('/')) {
          return int.tryParse(cr.split('/').last.trim()) ?? 0;
        }
        if (code == 200 && len > 0) return len;
        if (code == 403 || code == 404 || code == 410) {
          if (await _refresh(src)) continue;
        }
        return 0;
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._probeTotal: $e');
        return 0;
      } finally {
        client.close(force: true);
      }
    }
    return 0;
  }

  Future<Stream<List<int>>?> _openUpstream(
      _Source src, int start, int endInclusive) async {
    for (var attempt = 0; attempt < _upstreamTries; attempt++) {
      final client = HttpClient()
        // A connection that never opens would otherwise hang this response
        // for as long as the player is willing to wait, and the player waits
        // a long time. Fifteen seconds is well past a slow handshake and
        // well short of a viewer's patience.
        ..connectionTimeout = const Duration(seconds: 15);
      var handedOver = false;
      try {
        final r = await client.getUrl(Uri.parse(src.upstream));
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endInclusive');
        final resp = await r.close();
        if (resp.statusCode == 206 || resp.statusCode == 200) {
          handedOver = true;
          // The client is closed when the body ends, not here, or the film
          // would be cut off mid-chunk.
          return _closing(resp, client);
        }
        await resp.drain<void>();
        // 403, 404 and 410 are what an expired token looks like from here.
        // One refresh, then try again; a second failure is a real refusal
        // and belongs to the player.
        if (resp.statusCode == 403 ||
            resp.statusCode == 404 ||
            resp.statusCode == 410) {
          if (!await _refresh(src)) return null;
          continue;
        }
        if (resp.statusCode >= 500) continue;
        return null;
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._openUpstream: $e');
      } finally {
        if (!handedOver) client.close(force: true);
      }
    }
    return null;
  }

  Stream<List<int>> _closing(HttpClientResponse resp, HttpClient client) async* {
    try {
      yield* resp;
    } finally {
      client.close(force: true);
    }
  }

  /// One refresh at a time per film. Two ranged reads that both meet an
  /// expired token would otherwise ask the server for two grants and race to
  /// install them.
  Future<bool> _refresh(_Source src) async {
    final inFlight = src.refreshing;
    if (inFlight != null) return inFlight;
    final work = () async {
      try {
        final fresh = await src.refresh();
        if (fresh == null || fresh.isEmpty) return false;
        src.upstream = fresh;
        return true;
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._refresh: $e');
        return false;
      }
    }();
    src.refreshing = work;
    final ok = await work;
    src.refreshing = null;
    return ok;
  }
}

class _Source {
  _Source({required this.upstream, required this.refresh});

  String upstream;
  final Future<String?> Function() refresh;
  Future<bool>? refreshing;

  /// Whether this film's length has been confirmed against the server since
  /// the app started. One check per film per session: enough to catch a
  /// replaced file, cheap enough not to think about.
  bool checkedTotal = false;
}
