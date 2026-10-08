import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import '../../../../core/services/diagnostics/playback_log.dart';
import '../../../../core/services/network/foreground_stream.dart';
import '../../../../core/services/network/throughput_memory.dart';
import '../api/ranged_fetch.dart';
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

  /// ═══════════════════════════════════════════════════════════════════════
  /// SEVERAL CONNECTIONS, NOT ONE — WHY "4 MB/s AND STILL BUFFERING" HAPPENED
  /// ═══════════════════════════════════════════════════════════════════════
  ///
  /// A speed test opens several connections and adds them up. This proxy
  /// opened ONE, and on a mobile line one TCP connection is held to a
  /// fraction of the line by its loss and round trip: throughput falls as
  /// RTT × √loss rises, and at 150 ms and 1 % loss a single connection
  /// uses roughly a seventh of the bandwidth. The meter said 4 MB/s; the
  /// film received a few hundred KB/s of it, and the spinner was the result.
  ///
  /// Downloads already fetched three parts at once ([RangedFetch]) — the
  /// stream, which is what people watch, did not. Now it does: each stretch
  /// of film is asked for as parts of up to 2 MB ([rampedPartBytes]) on
  /// [lanes] connections at once and
  /// handed to the player in order, so a loss on one connection leaves the
  /// others running. The same thing Telegram's loader and every download
  /// manager do, and the reason a DASH/HLS player's short segments recover
  /// from loss better than one long response.
  ///
  /// AND THE CONNECTIONS ARE KEPT. Every 8 MB used to open a new HttpClient
  /// and close it: a TCP handshake, a TLS negotiation and slow start from
  /// nothing, every few seconds of a film. One pooled client per film now
  /// carries every request of the session.
  ///
  /// SIX, MEASURED (test_bench/stream_bench.dart under `tc netem`, run
  /// 37518953988, a 6 Mbps film):
  ///
  ///   150 ms RTT, 0.5 % loss   1 lane 0.25 MB/s, 60 s stalled
  ///                            3 lanes 0.87 MB/s, 5.7 s
  ///                            6 lanes 1.78 MB/s, none
  ///   250 ms RTT, 2 % loss     1 lane 0.07 MB/s, 285 s · 3 lanes 77 s · 6 lanes 18 s
  ///
  /// On a clean line every count is the same speed, so six costs nothing
  /// there. The price is memory — at most twelve 2 MB parts held while an
  /// earlier one finishes — and requests: one per 2 MB through the Worker,
  /// five hundred for a gigabyte, far inside its allowance.
  ///
  /// Settable for the bench and the lab (`lanes = 1` is the old single
  /// connection).
  @visibleForTesting
  static int lanes = 6;

  /// How much one parallel stretch covers before the loop comes round again
  /// (to check the cache, renew a link, record the speed).
  @visibleForTesting
  static int span = 32 * 1024 * 1024;

  /// A lane silent this long is taken for dead and the stretch ends; the
  /// loop reopens from the last byte the player received.
  static const Duration _laneStall = Duration(seconds: 15);

  /// THE PARTS OF A STRETCH START SMALL AND GROW BY 128 KB EACH — 128 KB,
  /// 256 KB, 384 KB … — until they are 2 MB, the sixteenth part on.
  ///
  /// A part reaches the player only once it is whole, and the lanes share the
  /// line. Six lanes opening on 512 KB and then 2 MB parts gave the second
  /// part a sixth of the line, so the player waited for 2.5 MB at a sixth of
  /// the speed before it had a picture: 12.6 s of black screen in the device
  /// lab (run 37743949143, 150 ms RTT, 1 % loss) where one lane took 2.2 s.
  ///
  /// Small parts first is the cure; GROWING ONE PART AT A TIME rather than a
  /// round at a time is what keeps it cured. Parts of a round that are all
  /// one size finish together, so the film arrives in lumps a round apart —
  /// rounds of 256 KB, then 512 KB (run 37747387105) started in 2 s but ran
  /// dry once 3 s later. Each part a little bigger than the one before
  /// finishes a little after it, so the film arrives a part at a time, in
  /// order, at the speed of the whole line. Modelled against both in
  /// eleven line/film pairings, this one was never the worse.
  static int rampedPartBytes(int index) =>
      min(RangedFetch.defaultPartBytes, 128 * 1024 * (index + 1));

  /// How far ahead of the index a stretch may start and still be taken as
  /// the index's (a stretch from 0 starts at `ftyp`, 32 bytes ahead of it).
  static const int _headBytes = 64 * 1024;

  /// The length check's read: the film's first box headers, which say where
  /// its index is, in one round trip — 8 KB fits a fresh connection's first
  /// flight, where 64 KB took three more round trips at 250 ms each.
  static const int _probeBytes = 8 * 1024;

  /// WHERE THE FILM'S INDEX IS, from its first bytes: `(start, end)` of the
  /// `moov` box, or null.
  ///
  /// The index of an MP4 grows with its running time — 4.2 MB for 108
  /// minutes (device lab run 37757920331), about 6 MB for a two-and-a-half
  /// hour film — and the player reads all of it before the first picture.
  /// Fetched like any other stretch, on parts that start small and grow, the
  /// last of it arrived seconds after the first: 8.8 s to a picture on a good
  /// 4G line where a short film took 1.4 s. Knowing where it is lets the
  /// first stretch take it whole, on every lane at once ([_indexPlan]).
  ///
  /// The top-level boxes are walked from the start: `ftyp`, `free`, then
  /// either `moov` (a faststart file — the index is right here) or `mdat`,
  /// whose size says where the box after it, the index, begins (a file
  /// written straight out, index last; it runs to the end of the file).
  @visibleForTesting
  static (int, int)? indexRange(Uint8List head, int total) {
    var at = 0;
    for (var i = 0; i < 8 && at + 8 <= head.length; i++) {
      final view = ByteData.sublistView(head);
      var size = view.getUint32(at);
      final kind = String.fromCharCodes(head.sublist(at + 4, at + 8));
      if (size == 1) {
        if (at + 16 > head.length) return null;
        size = view.getUint64(at + 8);
      } else if (size == 0) {
        size = total - at; // to the end of the file
      }
      if (size < 8) return null;
      if (kind == 'moov') return (at, min(total, at + size));
      if (kind == 'mdat') {
        final after = at + size;
        if (after >= total) return null; // no index after it
        return (after, total);
      }
      at += size;
    }
    return null;
  }

  /// The first parts of a stretch that starts in [index]: the rest of the
  /// index (and, for one at the front, 1 MB of film after it) split evenly
  /// over the lanes, in 64 KB multiples. Empty when the stretch does not
  /// start in it, or there is too little left to be worth it.
  /// Whether a stretch from [pos] begins in the index — or in the few bytes
  /// before it (a stretch from 0 starts at `ftyp`, 32 bytes ahead of it).
  static bool _startsInIndex((int, int)? index, int pos) =>
      index != null && pos >= index.$1 - _headBytes && pos < index.$2;

  static List<int> _indexPlan((int, int)? index, int start, int end) {
    if (index == null || !_startsInIndex(index, start)) return const [];
    final front = index.$1 < 1024 * 1024;
    final upto = min(end, index.$2 + (front ? 1024 * 1024 : 0));
    final len = upto - start;
    if (len < 512 * 1024) return const [];
    final each = ((len / max(1, lanes)).ceil() + 65535) & ~65535;
    return [for (var at = start; at < upto; at += each) min(each, upto - at)];
  }

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
      await _labLanes();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;

      await StreamCacheStore.instance
          .entryFor(cacheId, total: total, label: label);
      // The film's previous registration, if any, gives up its connections.
      _sources[cacheId]?.close();
      final src = _sources[cacheId] = _Source(upstream: upstream, refresh: refresh);
      // THE LENGTH CHECK STARTS NOW, while the player is still being built,
      // rather than when its first request arrives: it was 1 to 2.3 s of
      // every start in the device lab (run 37776589997), all of it before the
      // first lane opened. Its connection then carries the first lane.
      src.probing = _probeTotal(src);
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

  /// THE DEVICE LAB'S A/B SWITCH, AND ONLY THERE. A lab build reads the lane
  /// count from `lab_lanes` in the app's external files directory, which the
  /// lab writes with adb between two plays of the same film over the same
  /// shaped line — one connection, then three. A release build never looks.
  static Future<void> _labLanes() async {
    if (!const bool.fromEnvironment('INNOCENT_LAB')) return;
    try {
      final dir = await getExternalStorageDirectory();
      final f = File('${dir?.path}/lab_lanes');
      if (dir != null && await f.exists()) {
        final n = int.tryParse((await f.readAsString()).trim());
        if (n != null) lanes = n.clamp(1, 8);
      }
      PlaybackLog.add('stream lanes=$lanes');
    } catch (_) {}
  }

  /// A local address for a film that is served ENTIRELY from what is on disk.
  ///
  /// Reached only after `requestPlayback` has already answered
  /// `AccessDenial.offline` — the server could not be asked, as opposed to
  /// having said no — and only once [OfflineReplay] has read the file's own
  /// header and established that enough of it is here to open. There is no
  /// upstream, so nothing is probed and nothing is fetched: a gap in the film
  /// is where the film ends.
  ///
  /// Returns null when the loopback server will not start, and the caller then
  /// has nothing to offer, which is the truth.
  Future<String?> localUrlForHeldBytes({required String cacheId}) async {
    try {
      await StreamCacheStore.instance.load();
      await _ensureStarted();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;
      // NO `entryFor` CALL, deliberately: the entry must already exist, and
      // creating one here would mint an empty directory for a film this phone
      // does not have and then serve a 502 out of it.
      _sources[cacheId]?.close();
      _sources[cacheId] = _Source(
        upstream: '',
        refresh: () async => null,
        offline: true,
      );
      return 'http://127.0.0.1:$port/c/$token/$cacheId';
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer.localUrlForHeldBytes: $e');
      return null;
    }
  }

  /// Point an already-registered film at a fresh upstream URL.
  void updateUpstream(String cacheId, String upstream) {
    _sources[cacheId]?.upstream = upstream;
  }

  /// Stop serving a film, so a stale signed URL and its refresh closure do
  /// not outlive the screen that made them.
  void release(String cacheId) => _sources.remove(cacheId)?.close();

  /// Forget every film but these.
  ///
  /// Called when a new one opens. A `_Source` holds a signed URL and a
  /// closure over the screen that made it; left to accumulate, one per
  /// playback for the life of the process, they would keep both alive long
  /// after the screen is gone. Registering is the only moment at which it is
  /// certain which ones still matter.
  void releaseAllExcept(Set<String> keep) {
    _sources.removeWhere((id, src) {
      if (keep.contains(id)) return false;
      src.close();
      return true;
    });
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
    if (src.offline) {
      // Nothing to confirm against and nothing to fetch. The stored length is
      // all there is, and without one there is no range to answer at all.
      if (entry.total <= 0) {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
        return;
      }
    } else if (entry.total <= 0 || !src.checkedTotal) {
      // The one started when the film was registered, if it is still to be
      // had; failing that, or if it failed, once more now.
      final early = src.probing;
      src.probing = null;
      var probed = early == null ? 0 : await early;
      if (probed <= 0) probed = await _probeTotal(src);
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
    // THE BODY GOES STRAIGHT ONTO THE SOCKET, because that is the only place
    // the player hanging up can be seen.
    //
    // Measured (2026-10-08): once a client has gone, dart:io's HttpResponse
    // goes on accepting writes — a hundred megabytes of them, every flush
    // completing — and its `done` never completes. The player seeks, closes
    // its connection and opens another, and this loop carried on fetching the
    // rest of the film for nobody: in the device lab the abandoned 32 MB
    // stretch finished a minute after the seek, on the same line as the one
    // the viewer was waiting for. A detached socket says at once — its input
    // ends — and a write to it fails.
    res.headers.set(HttpHeaders.connectionHeader, 'close');
    final Socket out;
    try {
      out = await res.detachSocket(writeHeaders: true);
    } catch (_) {
      return;
    }
    final gone = _Gone();
    out.listen((_) {}, onDone: gone.hangUp, onError: (Object _) => gone.hangUp(),
        cancelOnError: true);
    var complete = false;
    try {
      while (pos <= endInclusive) {
        final before = pos;

        // ── from disk, for as far as this run reaches ──────────────────
        final part = entry.partAt(pos);
        if (part != null) {
          pos = await _fromDisk(out, part, pos, endInclusive);
          if (pos == before) break;
          continue;
        }

        // ── from upstream, keeping what passes through ─────────────────
        //
        // Offline there is no upstream, and a gap is simply where the film
        // stops. The response is already committed, so ending the write is the
        // honest signal: the player reads it as a dropped connection, which is
        // what it is, and its own retry path handles it.
        if (src.offline) break;
        if (gone.value) break;
        pos = await _fromUpstream(out, store, entry, src, pos, endInclusive, gone);
        // No progress means upstream gave nothing and will keep giving
        // nothing. The response is already committed, so the honest end is
        // to stop writing: the player sees a short read, treats it as a
        // dropped connection, and its retry path is exactly for that.
        if (pos == before) break;
      }
      complete = pos > endInclusive && !gone.value;
    } finally {
      if (complete) {
        try {
          await out.flush();
          await out.close();
        } catch (_) {
          out.destroy();
        }
      } else {
        // Short: the player sees the connection end where the bytes did,
        // reads it as a dropped connection, and reconnects from there.
        out.destroy();
      }
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
      IOSink res, CachePart part, int pos, int endInclusive) async {
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

  Future<int> _fromUpstream(IOSink res, StreamCacheStore store,
      CacheEntry entry, _Source src, int pos, int endInclusive,
      [_Gone? gone]) async {
    // Read ahead past what was asked, but never past a run already held:
    // those bytes are here, and fetching them again would waste the
    // viewer's data to write a duplicate.
    //
    // And never past what the player asked for: the response's length is
    // already promised, and a byte beyond it is a byte of the next answer.
    final until = min(min(entry.nextPartStart(pos, entry.total), entry.total),
        endInclusive + 1);

    // ── several connections at once, in order (see [lanes]) ─────────────
    //
    // Only for a stretch worth splitting: a gap of a few megabytes between
    // two cached runs is one request, as before.
    final Stream<List<int>> upstream;
    final stretchEnd = min(until, pos + span); // exclusive
    var parallel = false;
    final idx = src.index;
    final inIndex = _startsInIndex(idx, pos) && stretchEnd - pos >= 512 * 1024;
    if (lanes > 1 &&
        (inIndex ||
            RangedFetch.worthSplitting(stretchEnd - pos,
                partBytes: RangedFetch.defaultPartBytes))) {
      parallel = true;
      upstream = _lanesFetch(src, pos, stretchEnd, entry.total,
          gone: () => gone?.value ?? false,
          hungUp: gone?.hungUp,
          measured: (bytes, ms) =>
              _recordThroughput(bytes, Duration(milliseconds: ms)));
    } else {
      final fetchEnd = min(min(pos + _chunk, until) - 1, entry.total - 1);
      if (fetchEnd < pos) return pos;
      final single = await _openUpstream(src, pos, fetchEnd);
      if (single == null) return pos;
      upstream = single;
    }

    CacheWriter? writer;
    if (await store.hasRoom(protecting: entry.id)) {
      writer = await store.openWriter(entry, pos);
    }

    // Counted inside the tee rather than after it: `addStream` may stop part
    // way — the client closed, the connection dropped — and the caller has
    // to resume from what actually went out, not from what was asked for.
    var sent = 0;
    final startedAt = DateTime.now();
    // WRITTEN AND FLUSHED A PIECE AT A TIME, NOT `addStream`. A player that
    // hangs up (a seek, Back) does not stop `addStream` from pulling: it kept
    // draining the stretch into a dead socket, and the lanes kept fetching a
    // film nobody was watching. A flush fails once the socket is gone, and
    // that is where this stops — cancelling the stretch, which stops its
    // lanes. It is also the back-pressure: nothing is read from upstream
    // faster than the player takes it, past the lanes' own small window.
    final pieces = StreamIterator<List<int>>(
        _tee(upstream, writer, (n) => sent += n));
    try {
      var written = 0;
      while (await pieces.moveNext()) {
        res.add(pieces.current);
        written += pieces.current.length;
        await res.flush();
      }
      sent = min(sent, written);
      final took = DateTime.now().difference(startedAt);
      // A parallel stretch measures its own lanes (see [_lanesFetch]); this
      // figure includes the time the player was not reading.
      if (!parallel) _recordThroughput(sent, took);
      if (sent >= 1024 * 1024) {
        // Includes any time the player was not reading (its buffer full),
        // so a floor on the line's speed, not a measurement of it.
        PlaybackLog.add('stream stretch ${(sent / 1048576).toStringAsFixed(1)} MB '
            'in ${took.inMilliseconds} ms lanes=$lanes');
      }
      return pos + sent;
    } catch (e) {
      // `_tee` swallows upstream failures, so an error HERE is the player's
      // side: the response could not be written, it has hung up. The loop
      // must not open another stretch for nobody — that is exactly how a
      // seek used to leave a lane open on the server.
      gone?.value = true;
      if (kDebugMode) debugPrint('StreamCacheServer._fromUpstream: $e');
      return pos + sent;
    } finally {
      await pieces.cancel();
      if (writer != null) await store.touch(entry);
      // A stretch that stopped short — the player seeked away, or a lane
      // failed — has already destroyed the connections of its unfinished
      // parts ([_LanePart.kill]). The pool itself is left alone: the
      // stretch the player opened after its seek is using it right now.
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
      // AN UPSTREAM THAT FAILS PART WAY ENDS THIS STRETCH, NOT THE PLAYER'S
      // CONNECTION. Handed to `addStream`, an error closes the response the
      // player is reading — mpv sees a reset and reconnects, which is a
      // visible stall. Ending the stretch quietly instead lets [_serve]'s
      // loop carry on from the last byte sent, on the same response: a fresh
      // link, a fresh lane, and the player never knows.
      try {
        await for (final chunk in src) {
          // The viewer is watching this, from the network, now: background
          // downloads hold back until it stops — see ForegroundStream.
          ForegroundStream.touch();
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
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer: upstream ended: $e');
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
      HttpClientResponse? resp;
      try {
        // On the film's own pool: the connection stays open for the lanes,
        // which then start without a handshake.
        final r = await src.io.getUrl(Uri.parse(src.upstream)).timeout(_laneStall);
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${_probeBytes - 1}');
        final got = resp = await r.close().timeout(_laneStall);
        final cr = got.headers.value(HttpHeaders.contentRangeHeader);
        final code = got.statusCode;
        final len = got.contentLength;
        if (code != 206) {
          // NEVER READ A BODY NOBODY ASKED FOR. A server that ignores the
          // range answers 200 with the whole film, and draining that to
          // reuse the connection would download it.
          resp = null;
          unawaited(got.detachSocket().then((s) => s.destroy(), onError: (Object _) {}));
        }
        if (code == 206 && cr != null && cr.contains('/')) {
          final head = await got
              .fold<BytesBuilder>(BytesBuilder(copy: false), (b, c) => b..add(c))
              .timeout(_laneStall);
          resp = null;
          final total = int.tryParse(cr.split('/').last.trim()) ?? 0;
          src.index = indexRange(head.takeBytes(), total);
          if (src.index != null) {
            PlaybackLog.add('stream index ${((src.index!.$2 - src.index!.$1) / 1048576).toStringAsFixed(1)} MB '
                'at ${(src.index!.$1 / 1048576).toStringAsFixed(1)} MB');
          }
          return total;
        }
        if (code == 200 && len > 0) return len;
        if (code == 403 || code == 404 || code == 410) {
          if (await _refresh(src)) continue;
        }
        return 0;
      } catch (e) {
        // Timed out part way: that connection is not going back to the pool.
        final stuck = resp;
        if (stuck != null) {
          unawaited(stuck.detachSocket().then((s) => s.destroy(), onError: (Object _) {}));
        }
        if (kDebugMode) debugPrint('StreamCacheServer._probeTotal: $e');
        return 0;
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
        final code = resp.statusCode;
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        // THE BYTES MUST BE THE ONES ASKED FOR. A 206 says where it starts;
        // a 200 is a server that ignored the range and sent the film from
        // its first byte — right only for a stretch that starts there, and
        // only up to its end.
        if ((code == 206 && cr.startsWith('bytes $start-')) ||
            (code == 200 && start == 0)) {
          handedOver = true;
          // The client is closed when the body ends, not here, or the film
          // would be cut off mid-chunk.
          return _closing(resp, client, endInclusive - start + 1);
        }
        // Not read: the client is destroyed below, body and all.
        // 403, 404 and 410 are what an expired token looks like from here.
        // One refresh, then try again; a second failure is a real refusal
        // and belongs to the player.
        if (code == 403 || code == 404 || code == 410) {
          if (!await _refresh(src)) return null;
          continue;
        }
        if (code >= 500) continue;
        return null;
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._openUpstream: $e');
      } finally {
        if (!handedOver) client.close(force: true);
      }
    }
    return null;
  }

  /// THE STRETCH, AS [lanes] RANGE REQUESTS AT ONCE, HANDED ON IN ORDER.
  ///
  /// The same shape as [RangedFetch.ordered], which downloads use, but on
  /// dart:io directly — and the reason is the teardown. A seek abandons the
  /// parts still in flight, and through package:http an aborted part whose
  /// response had just arrived is never read and never cancelled: its socket
  /// stays in the pool, the server holds it open mid-write, and enough seeks
  /// starve the pool (test/stream_cache_server_test.dart caught one still
  /// open thirty seconds after a seek). Here every part keeps its own
  /// response, and stopping cancels it, which is what closes the socket.
  ///
  /// An expired link on the FIRST part is renewed and the stretch starts
  /// again, as a single request's would; later, a refused part ends the
  /// stretch and the serve loop renews on its next pass.
  ///
  /// [measured] gets the line's speed the way ExoPlayer's bandwidth meter
  /// takes it: bytes over the time at least one lane was actually
  /// transferring. Time the player spent not reading — its buffer full, the
  /// window of parts full — is not on the clock, so Auto does not read a
  /// fast line as a slow one and pick a rung below what it can carry.
  Stream<List<int>> _lanesFetch(_Source src, int start, int end, int total,
      {required bool Function() gone,
      Future<void>? hungUp,
      void Function(int bytes, int ms)? measured}) async* {
    final window = lanes * 2;

    for (var attempt = 0; attempt < 2; attempt++) {
      // Per attempt: parts killed by the last one still settle afterwards,
      // and must not move this attempt's clock.
      var inFlight = 0, bytesDone = 0, activeMs = 0, activeFrom = 0;
      var measuring = true;
      final clock = Stopwatch()..start();
      void began() {
        if (inFlight++ == 0) activeFrom = clock.elapsedMilliseconds;
      }

      void ended(int bytes) {
        if (!measuring) return;
        bytesDone += bytes;
        if (--inFlight == 0) activeMs += clock.elapsedMilliseconds - activeFrom;
      }

      final url = Uri.parse(src.upstream);
      final parts = <_LanePart>[];
      var next = start;
      var opened = 0;
      var failed = false;
      var stopped = false;
      // A stretch that starts in the film's index takes the index — and, at
      // the front of the film, the first second or so after it — as one
      // round of equal parts, one per lane: nothing plays until all of it
      // is here, so it should all arrive at once, at the speed of the whole
      // line. Then the ramp carries on from 1 MB parts.
      final plan = _indexPlan(src.index, start, end);
      if (plan.isNotEmpty) opened = 8;
      var planned = 0;

      void topUp() {
        if (stopped || failed || gone()) return;
        while (next < end &&
            parts.length < window &&
            parts.where((p) => !p.settled).length < lanes) {
          final size =
              planned < plan.length ? plan[planned++] : rampedPartBytes(opened++);
          final partEnd = min(next + size, end);
          final part = _LanePart(src.io, url, next, partEnd, total, _laneStall);
          began();
          part.done.then((n) {
            ended(n);
            topUp();
          }, onError: (_) {
            ended(0);
            failed = true;
          });
          parts.add(part);
          next = partEnd;
        }
      }

      var yielded = false;
      try {
        topUp();
        stretch:
        while (parts.isNotEmpty) {
          final p = parts.first;
          // THE FIRST PART GOES TO THE PLAYER AS IT ARRIVES, the parts behind
          // it once it is through. Held until whole, the index of a long
          // film — 6.4 MB over six lanes, the first part 1.25 MB of it at a
          // sixth of a 4 Mbit line — gave the player nothing for twenty
          // seconds; mpv gives up on a connection silent for ten
          // (`network-timeout`), asked again, and the stretch started over:
          // a film that never opened (device lab run 37776589997).
          while (true) {
            if (p.holding) {
              yielded = true;
              yield p.take();
              continue;
            }
            if (p.settled) break;
            // The player hanging up ends the wait at once, and the stretch
            // with it: its parts are killed below, not finished for nobody.
            await Future.any<void>([p.more, if (hungUp != null) hungUp]);
            if (gone()) return;
          }
          try {
            await p.done;
          } on _LaneRefused catch (e) {
            if (!yielded && attempt == 0 && e.expired && await _refresh(src)) {
              break stretch; // a fresh link: start the stretch again
            }
            rethrow;
          }
          parts.removeAt(0);
          topUp();
        }
        if (parts.isEmpty) return;
      } finally {
        stopped = true;
        for (final p in parts) {
          p.kill();
        }
        measuring = false;
        if (inFlight > 0) activeMs += clock.elapsedMilliseconds - activeFrom;
        if (measured != null && bytesDone > 0) measured(bytesDone, activeMs);
      }
    }
  }

  /// [resp]'s body up to [want] bytes, then its connection closed.
  Stream<List<int>> _closing(
      HttpClientResponse resp, HttpClient client, int want) async* {
    var left = want;
    try {
      await for (final chunk in resp) {
        if (chunk.length >= left) {
          yield chunk.length == left ? chunk : chunk.sublist(0, left);
          return;
        }
        left -= chunk.length;
        yield chunk;
      }
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

/// Whether the player has hung up on one request.
class _Gone {
  bool value = false;
  final Completer<void> _hung = Completer<void>();

  /// Completes when the player hangs up.
  Future<void> get hungUp => _hung.future;

  void hangUp() {
    value = true;
    if (!_hung.isCompleted) _hung.complete();
  }
}

class _Source {
  _Source({required this.upstream, required this.refresh, this.offline = false});

  String upstream;
  final Future<String?> Function() refresh;
  Future<bool>? refreshing;

  /// The length check started when the film was registered, until a request
  /// takes it.
  Future<int>? probing;

  /// One pool of connections for the whole of this film's session — kept
  /// alive between requests, so a stretch costs no new handshake.
  HttpClient? _io;
  HttpClient get io => _io ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = StreamCacheServer.lanes + 1;

  void close() {
    _io?.close(force: true);
    _io = null;
  }

  /// THIS FILM IS SERVED FROM DISK AND NOWHERE ELSE.
  ///
  /// Set by [StreamCacheServer.localUrlForHeldBytes], which is reached only
  /// after the server has already refused to answer because it could not be
  /// reached. There is no upstream to open and no length to confirm, so both
  /// are skipped — not attempted and allowed to fail. The difference is
  /// visible: probing would spend two connection timeouts, and each gap in the
  /// file three more, on the path to the first frame. A viewer in a tunnel
  /// would watch a spinner for forty-five seconds before the film they already
  /// have started.
  final bool offline;

  /// Where the film's index (`moov`) lies, `(start, end)` — at the front of
  /// a faststart file, at the end of one written straight out. Read from the
  /// first 64 KB by [StreamCacheServer.indexRange]; null when not an MP4 or
  /// not found.
  (int, int)? index;

  /// Whether this film's length has been confirmed against the server since
  /// the app started. One check per film per session: enough to catch a
  /// replaced file, cheap enough not to think about.
  bool checkedTotal = false;
}

/// A part refused by the server. [expired] is the 403 / 404 / 410 a stale
/// signed link answers with.
class _LaneRefused implements Exception {
  _LaneRefused(this.message, {this.expired = false});
  final String message;
  final bool expired;
  @override
  String toString() => '_LaneRefused: $message';
}

/// One part of a stretch on its own pooled connection. What arrives is held
/// in memory until the player reaches it — at once for the first part in
/// line, which hands its bytes on as they come ([take]). [kill] really
/// closes it: an unread response is cancelled (which drops the socket), a
/// request not yet answered aborted.
class _LanePart {
  _LanePart(HttpClient client, Uri url, this.start, this.end, int total,
      Duration stall) {
    done = _get(client, url, total, stall);
    // Held until its turn; an error before then must not count as unhandled.
    done.then((_) => _settle(), onError: (_) => _settle());
  }

  final int start;
  final int end; // exclusive

  /// The part's length once all of it has arrived; fails if it did not.
  late final Future<int> done;

  /// Arrived, failed or stopped: nothing more will come.
  bool settled = false;

  /// What has arrived and not yet been taken, in order.
  final BytesBuilder _held = BytesBuilder(copy: false);
  int _received = 0;
  Completer<void>? _arrived;

  bool get holding => _held.isNotEmpty;

  /// What has arrived since the last call.
  Uint8List take() => _held.takeBytes();

  /// Completes once more has arrived, or the part has settled.
  Future<void> get more {
    if (_held.isNotEmpty || settled) return Future<void>.value();
    return (_arrived ??= Completer<void>()).future;
  }

  void _wake() {
    final a = _arrived;
    _arrived = null;
    if (a != null && !a.isCompleted) a.complete();
  }

  void _settle() {
    settled = true;
    _wake();
  }
  bool _killed = false;
  HttpClientRequest? _req;
  HttpClientResponse? _resp;
  StreamSubscription<List<int>>? _sub;
  Completer<int>? _done;

  /// The response has been read to its end, or failed: its connection is
  /// back with the pool (or gone) and must not be touched.
  bool _ended = false;

  /// THE CONNECTION IS DESTROYED, NOT LET GO. Cancelling a dart:io response
  /// — or aborting its request — does not close it: the client goes on
  /// reading the rest of the part in the background so the connection can be
  /// reused, up to 2 MB a lane of the viewer's data after every seek
  /// (measured, 2026-10-08). Detached, it is ours to close, and the server
  /// sees it go at once.
  void _destroy() {
    final resp = _resp;
    if (resp == null || _ended) return;
    _ended = true;
    // The subscription is cancelled once the socket is ours, not before:
    // cancelled first, the client starts draining the rest of the part.
    unawaited(resp.detachSocket().then((s) => s.destroy(), onError: (Object _) {
      _drop(resp);
    }).whenComplete(() => _sub?.cancel()));
  }

  /// The request has gone out and its answer is on the way.
  bool _asked = false;

  void kill() {
    if (_killed) return;
    _killed = true;
    if (_resp != null) {
      _destroy();
    } else if (!_asked) {
      _req?.abort();
    }
    // Asked and not yet answered: NOT aborted. An abort here lets dart:io
    // read the answer to its end to reuse the connection — a whole film,
    // from a server that ignored the range (2026-10-08). The answer is
    // destroyed when it arrives ([_get]).
    final d = _done;
    if (d != null && !d.isCompleted) d.completeError(_LaneRefused('stopped'));
  }

  /// Close a response nobody will read — once. Its connection is destroyed,
  /// not cancelled: a cancelled response is read to its end for the pool,
  /// and a server that ignored the range has sent the whole film.
  bool _dropped = false;
  void _drop(HttpClientResponse r) {
    if (_dropped || _sub != null) return;
    _dropped = true;
    _ended = true;
    unawaited(r.detachSocket().then((s) => s.destroy(), onError: (Object _) {
      try {
        unawaited(r.listen(null).cancel());
      } catch (_) {}
    }));
  }

  Future<int> _get(
      HttpClient client, Uri url, int total, Duration stall) async {
    final want = end - start;
    final req = await client.getUrl(url).timeout(stall);
    _req = req;
    if (_killed) {
      req.abort();
      throw _LaneRefused('stopped');
    }
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
    _asked = true;
    final resp = await req.close().timeout(stall, onTimeout: () {
      req.abort();
      throw _LaneRefused('part $start: no answer');
    });
    _resp = resp;
    if (_killed) {
      _drop(resp);
      throw _LaneRefused('stopped');
    }
    final code = resp.statusCode;
    if (code != 206) {
      _drop(resp);
      throw _LaneRefused('HTTP $code for a range',
          expired: code == 403 || code == 404 || code == 410);
    }
    final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
    if (!cr.startsWith('bytes $start-${end - 1}/$total')) {
      _drop(resp);
      throw _LaneRefused('asked for $start-${end - 1}/$total, got $cr');
    }
    final done = Completer<int>();
    _done = done;
    Timer? quiet;
    void arm() {
      quiet?.cancel();
      quiet = Timer(stall, () {
        _destroy();
        if (!done.isCompleted) done.completeError(_LaneRefused('part $start went quiet'));
      });
    }

    arm();
    _sub = resp.listen((chunk) {
      if (done.isCompleted) return;
      // Never a byte past the part: what is held may already be on its way
      // to the player.
      if (_received + chunk.length > want) {
        quiet?.cancel();
        _destroy();
        done.completeError(_LaneRefused('part $start: too long'));
        return;
      }
      _received += chunk.length;
      _held.add(chunk);
      arm();
      _wake();
    }, onError: (Object e) {
      _ended = true;
      quiet?.cancel();
      if (!done.isCompleted) done.completeError(e);
    }, onDone: () {
      _ended = true;
      quiet?.cancel();
      if (done.isCompleted) return;
      if (_received != want) {
        done.completeError(_LaneRefused('part $start: $_received of $want bytes'));
      } else {
        done.complete(want);
      }
    }, cancelOnError: true);
    return done.future;
  }
}
