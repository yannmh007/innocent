import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:path_provider/path_provider.dart';

import '../../../../core/services/diagnostics/playback_log.dart';
import '../../../../core/services/network/foreground_stream.dart';
import '../../../../core/services/network/throughput_memory.dart';
import '../../domain/cmaf_index.dart';
import '../../domain/hls_ladder.dart';
import '../api/ranged_fetch.dart';
import '../stream_door.dart';
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
  /// (to check the cache, renew a link).
  @visibleForTesting
  static int span = 32 * 1024 * 1024;

  /// What one measurement of the line needs behind it: a megabyte, over at
  /// least two seconds of the lanes actually transferring. Less is mostly
  /// round trips and parts still on their way, and says little about the
  /// speed ([_recordThroughput]).
  static const int _sampleBytes = 1024 * 1024;
  static const int _sampleMs = 2000;

  /// Measurements taken since the app started. For the tests.
  @visibleForTesting
  static int measurements = 0;

  /// How much each round of a seek's parts grows on the one before
  /// ([seekPartBytes]). Settable for the bench.
  @visibleForTesting
  static double seekGrowth = 1.25;

  /// A STRETCH THAT STARTS PART WAY THROUGH THE FILM — a seek, or the gap
  /// after a run already held — IS FETCHED IN ROUNDS OF EQUAL PARTS: one
  /// part per lane, 64 KB each, then every round a quarter bigger than the
  /// one before, up to 2 MB.
  ///
  /// The player wants the first few hundred kilobytes after a seek — the
  /// keyframe and a second of sound; a fragmented film, two fragments (the
  /// one it seeks into and, for its sound, the one before). On a long lossy
  /// line each connection is held to a fraction of the line, and what
  /// reaches the player in order arrives at the speed of the part at the
  /// head. The ramp below grows ONE PART at a time — 128 KB, then 256, 384 …
  /// — so after a seek the second part was twice the first and took twice
  /// as long, the third three times: on a 4 Mbit line at 300 ms and 1 % loss
  /// a fragmented film's seek waited ten seconds, a faststart one four
  /// (device lab run 37885968378, and the same line modelled locally). Six
  /// equal parts finish together, at the speed of the whole line: with the
  /// parts a jump leaves behind kept ([_Source.keepSpare]), the same seeks
  /// took 3.3 to 4.3 s and 1.9 to 3.5 s, and on a 4G-like line the
  /// fragmented film's went from 2.6 s to 0.9–1.5. A quarter, not a half,
  /// per round: half again had the parts outgrow the line while the player
  /// was still reading, and a seek waited 1.2 s for a read already under
  /// way to finish; a quarter costs about a tenth more requests.
  ///
  /// The film's start keeps the ramp: its first stretch takes the index as
  /// one round of its own ([_indexPlan]), and the ramp carries on from there.
  ///
  /// [first] is the first round's part: 64 KB, or what one connection of
  /// this film has been carrying in half a second, up to 512 KB
  /// ([_Source.seekFirstPart]) — on a fast line 64 KB is mostly round trip,
  /// and twice the requests through the Worker for nothing.
  /// The largest part the proxy asks the Worker for: 2 MB, as measured in
  /// every bench and lab run behind the numbers above. Its own constant, not
  /// the downloader's ([RangedFetch.defaultPartBytes], 4 MB since 1.64.70):
  /// a download is one long read in order, a stream is read, jumped and
  /// thrown away, and a part a seek abandons is data the viewer paid for.
  static const int maxPartBytes = 2 * 1024 * 1024;

  static int seekPartBytes(int index, {int first = 64 * 1024}) {
    final grown = first * pow(seekGrowth, index ~/ max(1, lanes));
    return min(maxPartBytes, (grown.round() + 16383) & ~16383);
  }

  /// A STEP BACK IS NOT A SEEK. libavformat's MP4 demuxer reads a
  /// fragment's picture until it is a second ahead of its sound, reaches
  /// forward for the sound, then steps back a few hundred kilobytes for the
  /// rest of the picture (`mov_find_next_sample`, its one-second rule). mpv
  /// meets each step with a new request — into bytes this proxy has just
  /// given it — and the stretch on the line was stopped and started again
  /// from 64 KB parts every time: 7.8 requests through the Worker for every
  /// megabyte of a 1.7 Mbit film played straight through
  /// (test_bench/mpv_seek_bench.dart, mpv 0.37 over this proxy). A request
  /// that starts inside the run the stretch on the line has delivered is
  /// the same reading going on, so the stretch is HANDED OVER: its parts in
  /// flight, and the size its parts had grown to, go on with the request
  /// that replaced it. Off for the bench's before-and-after.
  @visibleForTesting
  static bool handOver = true;

  /// Stretches handed over, and taken up, since the app started. For the
  /// bench and the lab's trail.
  static int handedOver = 0, carriedOn = 0, stepsSeen = 0;

  /// Requests made upstream, and the bytes they brought, since the app
  /// started — what the Worker sees of this phone. For the lab's trail.
  static int upstreamRequests = 0, upstreamBytes = 0;

  /// What the Worker said about this phone's bound tokens (`X-Bind`: ok,
  /// missing, mismatch), counted per answer since the app started. For the
  /// lab's trail: the Worker's own log is the operator's, and this is how a
  /// test run on a real phone shows every fetch naming its install.
  static final Map<String, int> bindAnswers = <String, int>{};

  static void _noteBind(HttpClientResponse r) {
    final v = r.headers.value('x-bind');
    if (v != null) bindAnswers[v] = (bindAnswers[v] ?? 0) + 1;
  }

  /// How long parts handed over wait for the request that is to take them.
  static const Duration _handOverFor = Duration(seconds: 3);

  /// AFTER A SEEK, SMALL PARTS ONLY UNTIL THE PICTURE. The rounds of equal
  /// parts ([seekPartBytes]) are what bring a seek's first picture at the
  /// speed of the whole line, but growing a quarter a round they took 93
  /// requests and some 54 MB to reach 2 MB parts — the rest of every
  /// stretch after every jump at three and a half requests a megabyte. Once
  /// the stretch has handed the player this much (a fragment and its sound
  /// at 6 Mbit/s), the parts grow as a stretch from the start's do, one
  /// part at a time ([rampedPartBytes]). 0 keeps the rounds throughout.
  @visibleForTesting
  static int seekSettledBytes = 2 * 1024 * 1024;

  /// The [rampedPartBytes] index whose part is at least [bytes].
  static int _rampIndexFor(int bytes) =>
      max(0, (bytes + 128 * 1024 - 1) ~/ (128 * 1024) - 1);

  /// A lane silent this long is taken for dead and the stretch ends; the
  /// loop reopens from the last byte the player received.
  static const Duration _laneStall = Duration(seconds: 15);

  /// How long a stretch's first part streams to the player alone before the
  /// other lanes open (see [_lanesFetch]). Longer than a demuxer takes to
  /// read a fragment header and jump; short against a second of film.
  static const Duration _fanOutAfter = Duration(milliseconds: 250);

  /// A part this close to done is kept when the player hangs up, its
  /// connection with it (see [_LanePart.release]): taken over by the next
  /// stretch if it reaches those bytes, finished for the pool if not. Six of
  /// them is at most 1.5 MB of a viewer's data per seek, against a handshake
  /// saved for each.
  static const int _finishOnHangUpBelow = 256 * 1024;

  /// How long a request waits for the one its player is leaving to end
  /// (see [_serve]). A seek's old connection closes the moment the new one
  /// answers; this is only the bound for one that does not.
  static const Duration _supersedeWait = Duration(milliseconds: 300);

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
      min(maxPartBytes, 128 * 1024 * (index + 1));

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

  /// Whether [head] begins with a `moof` box: the header of one fragment of
  /// a fragmented film.
  static bool _isMoof(List<int> head) =>
      head.length >= 8 &&
      head[4] == 0x6d && // m
      head[5] == 0x6f && // o
      head[6] == 0x6f && // o
      head[7] == 0x66; // f

  /// Whether a stretch from [pos] begins in the index — or in the few bytes
  /// before it (a stretch from 0 starts at `ftyp`, 32 bytes ahead of it).
  static bool _startsInIndex((int, int)? index, int pos) =>
      index != null && pos >= index.$1 - _headBytes && pos < index.$2;

  /// The first parts of a stretch that starts in [index]: the rest of the
  /// index (and, for one at the front, 1 MB of film after it) split evenly
  /// over the lanes, in 64 KB multiples. Empty when the stretch does not
  /// start in it, or there is too little left to be worth it.
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
    bool probeNow = true,
  }) async {
    try {
      await StreamCacheStore.instance.load();
      await _ensureStarted();
      await _labLanes();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;

      final entry = await StreamCacheStore.instance
          .entryFor(cacheId, total: total, label: label);
      // The film's previous registration, if any, gives up its connections.
      _sources[cacheId]?.close();
      final src = _sources[cacheId] = _Source(upstream: upstream, refresh: refresh);
      // CONFIRMED A MOMENT AGO, BY A WARM-UP (see [warmOpening]): its length
      // was read from the server and where its index is with it. Asking again
      // would put one round trip — on a Myanmar line, the whole of a warmed
      // start's network time — in front of a first frame whose bytes are
      // already on the phone. Taken once, and only while fresh.
      final known = _confirmed.remove(cacheId);
      if (known != null && known.fresh && entry.total == known.total) {
        src.checkedTotal = true;
        src.index = known.index;
      } else if (probeNow) {
        // THE LENGTH CHECK STARTS NOW, while the player is still being
        // built, rather than when its first request arrives: it was 1 to
        // 2.3 s of every start in the device lab (run 37776589997), all of
        // it before the first lane opened. Its connection then carries the
        // first lane.
        src.probing = _probeTotal(src);
      }
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

  // ─── THE LADDER AS HLS, FOR A PLAYER THAT SWITCHES RUNG ON ITS OWN ────
  //
  // ExoPlayer plays the ladder as one HLS stream (domain/hls_ladder.dart):
  // a master playlist from here, a media playlist per rung, and segments
  // that are byte ranges of each rung's file — read through the same /c/
  // addresses, the same store and the same sealed cache as before. It
  // changes rung at a segment boundary while the picture keeps moving, so
  // nothing here reopens anything.

  final Map<String, _Ladder> _ladders = <String, _Ladder>{};

  /// How far past a segment the proxy reads, in the same request: the next
  /// segments' bytes, which the player asks for a moment later and finds on
  /// the phone. Two megabytes is one request a megabyte or two where one a
  /// segment would be five a megabyte at 240p — the Worker's free daily
  /// requests are what this spends — and it is all film the player reads
  /// next unless it jumps.
  static int segmentReadAhead = 2 * 1024 * 1024;

  /// The line's speed as the last stretch from the Worker measured it, in
  /// kbps: what the player's rung choice is fed (its own meter sees this
  /// loopback, where a cached segment arrives at flash speed). Null until
  /// one is measured.
  static final ValueNotifier<int?> networkKbps = ValueNotifier<int?>(null);

  /// Register a whole ladder and get the local address of its master
  /// playlist. Each rung becomes a film of its own here (its /c/ address,
  /// its cache entry, its own refresh), so a rung played as a file and the
  /// same rung played as HLS share every byte already on the phone.
  ///
  /// Only the rung the player starts on is checked against the server at
  /// once; the others when first read. Null when the proxy cannot start or
  /// a rung cannot be registered: the caller then plays one rung as before.
  Future<String?> hlsUrlFor({
    required String ladderId,
    required List<HlsRungSource> rungs,
    String label = '',
    double? aspect,
    double? frameRate,
    String? startCacheId,
  }) async {
    if (rungs.isEmpty) return null;
    try {
      await StreamCacheStore.instance.load();
      await _ensureStarted();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;
      final entries = <_LadderRung>[];
      for (final r in rungs) {
        final url = await localUrlFor(
          cacheId: r.cacheId,
          upstream: r.upstream,
          refresh: r.refresh,
          total: r.bytes,
          label: label,
          probeNow: r.cacheId == (startCacheId ?? rungs.first.cacheId),
        );
        if (url == null) return null;
        _sources[r.cacheId]?.segmented = true;
        entries.add(_LadderRung(height: r.height, kbps: r.kbps, cacheId: r.cacheId, url: url));
      }
      _ladders[ladderId] =
          _Ladder(rungs: entries, aspect: aspect, frameRate: frameRate);
      return 'http://127.0.0.1:$port/h/$token/$ladderId/master.m3u8';
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer.hlsUrlFor: $e');
      return null;
    }
  }

  /// Stop serving a ladder and all of its rungs.
  void releaseLadder(String ladderId) {
    final l = _ladders.remove(ladderId);
    if (l == null) return;
    for (final r in l.rungs) {
      release(r.cacheId);
    }
  }

  /// The rung's head — its fragment table and init segment — read once,
  /// through its own address (so the bytes land in its cache entry, where
  /// the first segments will be found).
  Future<_LadderRung?> _rungWithHead(_Ladder l, int height) async {
    final r = l.rungs.where((x) => x.height == height).firstOrNull;
    if (r == null) return null;
    if (r.index != null && r.head != null) return r;
    final loading = r.loading ??= () async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final head = BytesBuilder(copy: false);
        var want = 64 * 1024;
        for (var i = 0; i < 4; i++) {
          final req = await client.getUrl(Uri.parse(r.url));
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=${head.length}-${want - 1}');
          final resp = await req.close();
          if (resp.statusCode != HttpStatus.partialContent) {
            await resp.drain<void>();
            return;
          }
          await for (final chunk in resp) {
            head.add(chunk);
          }
          final bytes = head.toBytes();
          final idx = CmafIndex.parse(bytes);
          if (idx != null) {
            r.index = idx;
            r.head = CmafHead.parse(bytes);
            return;
          }
          final need = CmafIndex.headBytes(bytes);
          if (need == null || need <= bytes.length || need > _switchHeadCap) return;
          want = need;
        }
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._rungWithHead: $e');
      } finally {
        client.close(force: true);
      }
    }();
    await loading;
    if (r.index == null || r.head == null) r.loading = null; // asked again next time
    return r;
  }

  Future<void> _servePlaylist(HttpResponse res, String ladderId, String name) async {
    final l = _ladders[ladderId];
    String? body;
    if (l != null) {
      final port = _server?.port;
      final token = _token;
      if (name == 'master.m3u8') {
        // Any rung already read gives the picture's shape to all of them.
        final read = l.rungs.where((r) => r.head?.width != null).firstOrNull;
        final aspect = read == null
            ? l.aspect
            : read.head!.width! / max(1, read.head!.height ?? read.height);
        body = HlsLadder.master(
          [for (final r in l.rungs) r.hls],
          mediaUri: (r) => 'http://127.0.0.1:$port/h/$token/$ladderId/${r.height}.m3u8',
          aspect: aspect,
          frameRate: l.frameRate,
        );
      } else if (name.endsWith('.m3u8')) {
        final h = int.tryParse(name.substring(0, name.length - 5));
        final r = h == null ? null : await _rungWithHead(l, h);
        if (r != null) {
          body = HlsLadder.media(r.hls);
          if (body != null) {
            PlaybackLog.add('hls: ${r.height}p playlist, ${r.index!.length} segments');
            // The rungs either side are where Auto goes next: their heads
            // read now, a change of rung waits for no index.
            final heights = [for (final x in l.rungs) x.height]..sort();
            final i = heights.indexOf(r.height);
            for (final n in [if (i > 0) heights[i - 1], if (i + 1 < heights.length) heights[i + 1]]) {
              unawaited(_rungWithHead(l, n));
            }
          }
        }
      }
    }
    if (body == null) {
      PlaybackLog.add('hls: $name not served (${l == null ? 'no ladder' : 'no index'})');
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }
    res.statusCode = HttpStatus.ok;
    res.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/vnd.apple.mpegurl')
      ..set(HttpHeaders.cacheControlHeader, 'no-store');
    res.write(body);
    await res.close();
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

  // ─── WARM START ──────────────────────────────────────────────────────
  //
  // TikTok and YouTube start a video in a blink because its first seconds
  // are already on the phone when the finger lands. This is that, for the
  // film whose page the viewer is looking at: its index and first seconds
  // are fetched into the cache while they read the synopsis, so Play opens
  // from flash with no network round trip in front of the first frame.

  /// How much film after the index a warm-up takes: a few seconds at a
  /// streaming rung, which is what the player reads before its first frame.
  static const int warmFilmBytes = 2 * 1024 * 1024;

  /// The most one warm-up may fetch, index included. A long faststart
  /// original's index alone can be 6 MB.
  static const int warmCapBytes = 8 * 1024 * 1024;

  /// How long a warm-up's length check stands in for the player's own.
  static const Duration _confirmedFor = Duration(minutes: 10);

  /// Films warmed, or tried, in this process: never twice.
  final Set<String> _warmed = <String>{};
  String? _warming;
  final Map<String, _Confirmed> _confirmed = <String, _Confirmed>{};

  /// Whether a player is reading a film through here, or was a moment ago
  /// from the network ([ForegroundStream]). A warm-up never takes that line.
  bool get servingAPlayer =>
      ForegroundStream.active ||
      _sources.entries.any((e) => e.key != _warming && e.value.serving.isNotEmpty);

  /// Fetch the opening of a film into the cache before anyone presses Play.
  ///
  /// True when something was warmed. Never throws and never retries, and
  /// steps aside at once when it should not be running at all: another
  /// warm-up under way, this film warmed before (one at a time, once each),
  /// the film already registered (the player has it, or is about to), or any
  /// film being played (its line is not ours to take). Whether to warm at
  /// all — an unmetered line, no data saver, not a film on disk — is the
  /// caller's question (see `warmAllowed`).
  ///
  /// THE BYTES COME THROUGH THIS SERVER'S OWN ADDRESS, so they take exactly
  /// the path a player's would — the same lanes, the same store, the same
  /// rung's cache entry — and Play finds them as if it had read them itself.
  /// What the warm-up learnt of the film's length and index is handed to
  /// that play ([localUrlFor]), so it does not ask again.
  Future<bool> warmOpening({
    required String cacheId,
    required String upstream,
    required Future<String?> Function() refresh,
    int? total,
    String label = '',
  }) async {
    if (_warming != null || _warmed.contains(cacheId)) return false;
    if (_sources.containsKey(cacheId) || servingAPlayer) return false;
    _warming = cacheId;
    _warmed.add(cacheId);
    _Source? mine;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final local = await localUrlFor(
          cacheId: cacheId, upstream: upstream, refresh: refresh, total: total, label: label);
      mine = _sources[cacheId];
      if (local == null || mine == null) return false;
      mine.warmOnly = true;
      final length = await (mine.probing ?? Future<int>.value(0));
      if (length <= 0) return false;
      final idx = mine.index;
      final ranges = <(int, int)>[]; // inclusive
      if (idx != null && idx.$1 < 1024 * 1024) {
        // The index at the front — a faststart film's, or a fragmented one's
        // 1 KB — and the seconds after it, as one read.
        ranges.add((0, min(length, min(warmCapBytes, idx.$2 + warmFilmBytes)) - 1));
      } else {
        ranges.add((0, min(length, warmFilmBytes) - 1));
        // The index at the end: the player reads the front, then jumps for it.
        if (idx != null && idx.$2 - idx.$1 <= warmCapBytes - warmFilmBytes) {
          ranges.add((idx.$1, idx.$2 - 1));
        }
      }
      var got = 0;
      for (final (from, to) in ranges) {
        if (!identical(_sources[cacheId], mine)) break; // Play took over
        final req = await client.getUrl(Uri.parse(local));
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
        final resp = await req.close();
        await for (final chunk in resp) {
          got += chunk.length;
        }
      }
      _confirmed[cacheId] = _Confirmed(length, idx);
      PlaybackLog.add('warm: ${(got / 1048576).toStringAsFixed(1)} MB of the opening held');
      return got > 0;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer.warmOpening: $e');
      return false;
    } finally {
      client.close(force: true);
      _warming = null;
      // Its signed link and refresh closure go with it — unless Play has
      // registered this film meanwhile, and then the source is the player's.
      if (mine != null && identical(_sources[cacheId], mine)) release(cacheId);
    }
  }

  // ─── WARM SWITCH ─────────────────────────────────────────────────────
  //
  // A rung switch is a reopen: libmpv cannot change rung inside one stream
  // (FFmpeg's HLS demuxer cannot seek in fragmented-MP4 playlists, ticket
  // #7359, and a switch is a seek). Reopened cold, the new copy's first
  // picture waits for its bytes to cross the line — measured, 1.8 s of
  // frozen picture at 6 Mbit and 80 ms, 3 s at 3.5 Mbit. So the bytes cross
  // FIRST, while the copy on screen plays on, and the reopen finds them on
  // the phone: 0.1 to 0.2 s, the decoder's own time. YouTube does the same
  // in spirit — the old quality keeps playing until the new one is ready.

  /// How much of the new copy a switch holds before reopening on it.
  static const Duration switchLead = Duration(seconds: 10);

  /// The most a switch fetches past the index: ten seconds of a 6 Mbit rung.
  static const int switchCapBytes = 8 * 1024 * 1024;

  /// The longest index a switch will read to find its moment. 1 MB of `sidx`
  /// is ten hours of film; anything longer is not the ladder's layout.
  static const int _switchHeadCap = 1024 * 1024;

  /// Fetch the copy [cacheId] — registered with [localUrlFor] a moment ago,
  /// not yet playing — from the moment [at] for [lead] of film, so that
  /// reopening on it there needs no network.
  ///
  /// [limit] bounds the whole of it. [paceOver] tightens that for a climb:
  /// the film must arrive at least that many times faster than it plays
  /// (1.25 — the margin a rung needs to be watched without stalls), or the
  /// line cannot carry this copy and the switch is not worth making.
  ///
  /// Null when the copy is not the ladder's fragmented layout (an Original,
  /// a faststart file) or anything else stops it before it starts: the
  /// caller then reopens as it always did. Otherwise [WarmSwitch.complete]
  /// says whether everything planned arrived inside the limit. Never throws.
  ///
  /// THROUGH THIS SERVER'S OWN ADDRESS, like [warmOpening]: the same lanes,
  /// the same store, the same entry the reopen will read.
  Future<WarmSwitch?> warmSwitch(
    String cacheId,
    Duration at, {
    required Duration limit,
    Duration lead = switchLead,
    double? paceOver,
  }) async {
    final src = _sources[cacheId];
    final port = _server?.port;
    final token = _token;
    if (src == null || src.offline || port == null || token == null) return null;
    final local = Uri.parse('http://127.0.0.1:$port/c/$token/$cacheId');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    final clock = Stopwatch()..start();
    var timedOut = false;
    Timer arm(Duration d) => Timer(d, () {
          timedOut = true;
          client.close(force: true);
        });
    var stop = arm(limit);
    // Counted as the bytes come, so a read the limit cuts short still says
    // how much it got: that is the line's speed for this copy.
    var arrived = 0;
    Future<void> fetch(int from, int to, [BytesBuilder? into]) async {
      arrived = 0;
      final req = await client.getUrl(local);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-$to');
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.partialContent) {
        await resp.drain<void>();
        return;
      }
      await for (final chunk in resp) {
        arrived += chunk.length;
        into?.add(chunk);
      }
    }

    var headBytes = 0;
    try {
      // The index: the first 64 KB, and on to wherever it says it ends.
      final head = BytesBuilder(copy: false);
      CmafIndex? idx;
      var want = 64 * 1024;
      for (var i = 0; i < 4; i++) {
        await fetch(head.length, want - 1, head);
        headBytes += arrived;
        final bytes = head.toBytes();
        idx = CmafIndex.parse(bytes);
        if (idx != null) break;
        final need = CmafIndex.headBytes(bytes);
        if (need == null || need <= bytes.length || need > _switchHeadCap) {
          return null;
        }
        want = need;
      }
      if (idx == null) return null;
      final plan = idx.rangeFor(at, lead, capBytes: switchCapBytes);
      if (plan == null) return null;
      final (from, to, film) = plan;
      var left = limit - clock.elapsed;
      if (paceOver != null && paceOver > 0) {
        final paced = film * (1 / paceOver);
        if (paced < left) left = paced;
      }
      stop.cancel();
      if (left <= Duration.zero) {
        return WarmSwitch(complete: false, bytes: headBytes, took: clock.elapsed, film: film);
      }
      stop = arm(left);
      final t = Stopwatch()..start();
      try {
        await fetch(from, to);
      } catch (_) {
        // The limit closed the connection mid-film: what came is kept, and
        // the answer is "not in time".
      }
      final got = arrived;
      final result = WarmSwitch(
        complete: !timedOut && got >= to - from + 1,
        bytes: headBytes + got,
        took: clock.elapsed,
        film: film,
        filmTook: t.elapsed,
        filmBytes: got,
      );
      PlaybackLog.add('warm switch: ${(result.bytes / 1048576).toStringAsFixed(1)} MB '
          'for ${film.inSeconds} s of film in ${result.took.inMilliseconds} ms '
          '(${result.kbps} kbps)${result.complete ? '' : ' — not in time'}');
      return result;
    } catch (e) {
      if (kDebugMode) debugPrint('StreamCacheServer.warmSwitch: $e');
      // Out of time before the film's bytes were even asked for: that is an
      // answer too — this line could not carry it.
      return timedOut
          ? WarmSwitch(
              complete: false, bytes: headBytes + arrived, took: clock.elapsed, film: Duration.zero)
          : null;
    } finally {
      stop.cancel();
      client.close(force: true);
    }
  }

  /// For tests: forget which films were warmed.
  @visibleForTesting
  void resetWarmForTest() {
    _warmed.clear();
    _confirmed.clear();
    _warming = null;
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
    // A ladder with none of its rungs left is gone with them.
    _ladders.removeWhere((_, l) => l.rungs.every((r) => !_sources.containsKey(r.cacheId)));
  }

  /// The address of one rung of a ladder, for libmpv to play on its own —
  /// the way back when ExoPlayer cannot start a ladder. Read as libmpv
  /// reads, not segment by segment.
  String? ladderFallback(String ladderId, int height) {
    final r = _ladders[ladderId]?.rungs.where((x) => x.height == height).firstOrNull;
    if (r == null) return null;
    playAsFile(r.cacheId);
    return r.url;
  }

  /// A rung registered for a ladder, now played as one file (by libmpv):
  /// its reads are answered as a file's, not a segment's.
  void playAsFile(String cacheId) => _sources[cacheId]?.segmented = false;

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (parts.length == 4 && parts[0] == 'h' && parts[1] == _token) {
        await _servePlaylist(res, parts[2], parts[3]);
        return;
      }
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
    // A player that seeks opens its next request BEFORE it closes the last
    // (ffmpeg keeps the old connection until the new one answers), so the
    // stretch it is leaving is still running when this one starts. Wait —
    // briefly — for it to end and put away the parts it is keeping, or this
    // stretch asks again for the very bytes it is about to be handed.
    final leaving = [for (final g in src.serving) if (!g.isOver) g];
    // Where this request starts, for the stretch it replaces to decide
    // whether it is being handed over ([handOver]).
    if (leaving.isNotEmpty) {
      src.nextStart = start;
      src.nextRunEnd = entry.partAt(start)?.end;
    }
    src.serving.add(gone);
    var complete = false;
    try {
      if (leaving.isNotEmpty) {
        await Future.any<void>([
          Future.wait([for (final g in leaving) g.over]),
          Future<void>.delayed(_supersedeWait),
        ]);
        // Looked at by now, or not to be: a stretch that outlives the wait
        // gives its parts up as it always did.
        src.nextStart = null;
        src.nextRunEnd = null;
      }
      while (pos <= endInclusive) {
        final before = pos;

        // ── from disk, for as far as this run reaches ──────────────────
        final part = entry.partAt(pos);
        if (part != null) {
          pos = await _fromDisk(out, entry, part, pos, endInclusive);
          if (pos == before) break;
          continue;
        }

        // ── a segment of the ladder as HLS: wait for, or read ahead ────
        if (src.segmented) {
          final f = src.fill;
          if (f != null && !f.done && f.from <= pos && pos < f.to) {
            // Its bytes are already on their way, read ahead with the
            // segment before: wait for them rather than ask twice.
            await f.until(() => entry.partAt(pos) != null, gone);
            if (entry.partAt(pos) != null) continue;
            if (gone.value) break;
          } else if (f != null && !f.done) {
            // A jump: what that read is bringing is not where the player is.
            f.cancel();
          }
          if (src.offline || gone.value) break;
          pos = await _segmentFromUpstream(out, store, entry, src, pos, endInclusive, gone);
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
      src.serving.remove(gone);
      gone.finish();
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
  Future<int> _fromDisk(IOSink res, CacheEntry entry, CachePart part, int pos,
      int endInclusive) async {
    final from = pos - part.start;
    final toExclusive = min(part.end - 1, endInclusive) - part.start + 1;
    if (toExclusive <= from) return pos;
    try {
      // Through the entry, which unseals a sealed run (StreamCacheStore).
      await res.addStream(entry.read(part, from, toExclusive));
      final n = toExclusive - from;
      if (n >= 1024 * 1024) {
        // The lab's proof that a sealed run played back on a real phone.
        PlaybackLog.add('stream from the phone ${(n / 1048576).toStringAsFixed(1)} MB '
            '${part.sealed ? 'sealed' : 'plain'}');
      }
      return pos + n;
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
    // For a long stretch, the index, and any gap part way through the film
    // of more than a part: a seek into a fragmented film leaves runs a
    // fragment apart, and the gap between two of them is exactly what the
    // player waits for next. As one request it went out on a client of its
    // own — a fresh handshake, at one connection's speed — where the lanes
    // reuse the film's warm connections and the parts a jump left behind.
    final Stream<List<int>> upstream;
    final stretchEnd = min(until, pos + span); // exclusive
    var parallel = false;
    final idx = src.index;
    final inIndex = _startsInIndex(idx, pos) && stretchEnd - pos >= 512 * 1024;
    if (lanes > 1 &&
        (inIndex ||
            (pos > 0 && stretchEnd - pos >= 64 * 1024) ||
            RangedFetch.worthSplitting(stretchEnd - pos,
                partBytes: maxPartBytes))) {
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
        _tee(upstream, writer, (n) => sent += n, foreground: !src.warmOnly));
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

  /// A segment of the ladder as HLS, and what follows it.
  ///
  /// ONE REQUEST, ON THE FILM'S POOLED CONNECTION: no lanes (a segment is a
  /// few hundred KB, and lanes cut it into parts, each a request of its own
  /// to the Worker) and no handshake (the pool keeps the connection).
  /// The request reaches [segmentReadAhead] past the segment: the client
  /// gets its range, and the read carries on into the cache, where the
  /// player's next requests find it — or wait for it ([_Fill.until]).
  /// Sealed like every write ([CacheWriter]). Returns where the client's
  /// answer got to.
  Future<int> _segmentFromUpstream(Socket out, StreamCacheStore store,
      CacheEntry entry, _Source src, int pos, int endInclusive, _Gone gone) async {
    final total = entry.total;
    // The head (from byte 0: the index, the init segment) is read for
    // itself; reading the film's opening on behind it would be two
    // megabytes of a beginning a viewer resuming at minute forty never sees.
    final ahead = pos == 0 ? 0 : segmentReadAhead;
    final aheadEnd = min(
        min(entry.nextPartStart(pos, total), total), // exclusive
        max(endInclusive + 1, pos + ahead));
    if (aheadEnd <= pos) return pos;
    final up = await _openPooled(src, pos, aheadEnd - 1);
    if (up == null) return pos;
    CacheWriter? writer;
    if (await store.hasRoom(protecting: entry.id)) {
      writer = await store.openWriter(entry, pos);
    }
    final fill = src.fill = _Fill(pos, aheadEnd);
    final clientEnd = min(endInclusive + 1, aheadEnd);
    final answered = Completer<int>();
    var at = pos;
    var sent = pos;
    final clock = Stopwatch()..start();
    unawaited(() async {
      try {
        final pieces = StreamIterator<List<int>>(up);
        fill.onCancel = () => unawaited(pieces.cancel());
        while (!fill.cancelled && await pieces.moveNext()) {
          final chunk = pieces.current;
          ForegroundStream.touch();
          final w = writer;
          if (w != null) {
            try {
              await w.write(chunk);
            } catch (e) {
              // A disk that will not take it is not a reason to stop the film.
              writer = null;
              await w.close();
            }
          }
          final from = at;
          at += chunk.length;
          upstreamBytes += chunk.length;
          if (!answered.isCompleted && from < clientEnd) {
            final take = min(at, clientEnd) - from;
            try {
              out.add(take == chunk.length ? chunk : chunk.sublist(0, take));
              await out.flush();
              sent = from + take;
            } catch (_) {
              // The player hung up — a seek, or Back. What it was reading is
              // not wanted ahead of it either.
              gone.hangUp();
              answered.complete(sent);
              break;
            }
            if (sent >= clientEnd) answered.complete(sent);
          }
          fill.ping();
        }
        await pieces.cancel();
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._segmentFromUpstream: $e');
      } finally {
        await writer?.close();
        fill.finish();
        final bytes = at - pos;
        if (bytes >= 256 * 1024) _recordNetwork(bytes, clock.elapsed);
        if (!answered.isCompleted) answered.complete(sent);
        await store.touch(entry);
      }
    }());
    return answered.future;
  }

  /// A range from the Worker on the film's pooled connection, renewed once
  /// when the link has expired. The body, or null.
  Future<Stream<List<int>>?> _openPooled(_Source src, int start, int endInclusive) async {
    for (var attempt = 0; attempt < _upstreamTries; attempt++) {
      try {
        final up = Uri.parse(src.upstream);
        final r = await src.io.getUrl(up);
        upstreamRequests++;
        StreamDoor.apply(r, up);
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endInclusive');
        final resp = await r.close();
        _noteBind(resp);
        final code = resp.statusCode;
        final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
        if ((code == 206 && cr.startsWith('bytes $start-')) || (code == 200 && start == 0)) {
          return resp;
        }
        await resp.drain<void>().catchError((_) {});
        if (code == 403 || code == 404 || code == 410) {
          if (!await _refresh(src)) return null;
          continue;
        }
        if (code >= 500) continue;
        return null;
      } catch (e) {
        if (kDebugMode) debugPrint('StreamCacheServer._openPooled: $e');
      }
    }
    return null;
  }

  /// A reading of the line from a read that crossed it, for Auto and for
  /// the HLS player's rung choice ([networkKbps]). Smaller and shorter
  /// reads than [_recordThroughput] takes, because a segment is small:
  /// still never one so short it measures the handshake.
  void _recordNetwork(int bytes, Duration took) {
    final ms = took.inMilliseconds;
    if (ms < 200) return;
    final kbps = (bytes * 8) ~/ ms;
    networkKbps.value = kbps;
    _recordThroughput(bytes, took);
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
    void Function(int) counted, {
    bool foreground = true,
  }) async* {
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
          // downloads hold back until it stops — see ForegroundStream. Not
          // for a warm-up: nobody is watching it yet, and a download slowed
          // for a page somebody merely opened is a cost with no viewer.
          if (foreground) ForegroundStream.touch();
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
          upstreamBytes += chunk.length;
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
    measurements++;
    // In the trail: what Auto's next choice — a climb, a step down, the next
    // film's first copy — will be made from.
    PlaybackLog.add('measured $kbps kbps');
    unawaited(ThroughputMemory.observe(kbps));
  }

  Future<int> _probeTotal(_Source src) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      HttpClientResponse? resp;
      try {
        // On the film's own pool: the connection stays open for the lanes,
        // which then start without a handshake.
        final up = Uri.parse(src.upstream);
        final r = await src.io.getUrl(up).timeout(_laneStall);
        StreamDoor.apply(r, up);
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=0-${_probeBytes - 1}');
        final got = resp = await r.close().timeout(_laneStall);
        _noteBind(got);
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
        final up = Uri.parse(src.upstream);
        final r = await client.getUrl(up);
        upstreamRequests++;
        StreamDoor.apply(r, up);
        r.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-$endInclusive');
        final resp = await r.close();
        _noteBind(resp);
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

      // REPORTED AS IT IS EARNED, NOT ONLY WHEN THE STRETCH ENDS. A stretch
      // runs to [span] (32 MB), and a player reading a 360p film at its own
      // pace takes seven minutes to get through one: Auto heard nothing for
      // all of that, so it could never climb (device lab run 37972782851 —
      // Sintel at 360p for 240 s on a fast line, not one measurement). Like
      // ExoPlayer's meter, a sample as the transfers come in: whenever a
      // part ends with [_sampleBytes] and [_sampleMs] of the lanes'
      // transferring time on the clock since the last. Not at the moments
      // the lanes fall idle — while a buffer fills they overlap for many
      // seconds without one.
      void ended(int bytes) {
        if (!measuring) return;
        bytesDone += bytes;
        final now = clock.elapsedMilliseconds;
        if (--inFlight == 0) activeMs += now - activeFrom;
        final active = activeMs + (inFlight > 0 ? now - activeFrom : 0);
        if (measured != null &&
            bytesDone >= _sampleBytes &&
            active >= _sampleMs) {
          measured(bytesDone, active);
          bytesDone = 0;
          activeMs = 0;
          if (inFlight > 0) activeFrom = now;
        }
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
      // A stretch handed over: the parts in flight are the ones before it
      // ([_Source.takeSpare] adopts them), and its own grow on from the
      // size they had reached.
      final carried = handOver ? src.takeRamp(start) : null;
      if (carried != null) {
        opened = carried;
        carriedOn++;
      }
      // Part way through the film: rounds of equal parts ([seekPartBytes]),
      // until the player has had [seekSettledBytes] of it.
      var rounds = plan.isEmpty && start > 0 && carried == null;
      final firstPart = src.seekFirstPart;
      var planned = 0;
      // Where this stretch has handed the player up to, and the size of the
      // last part it asked for.
      var yieldedTo = start;
      var lastSize = 0;

      // ONE LANE UNTIL THE PLAYER HAS SHOWN IT WILL READ ON. A seek into a
      // fragmented film reads a fragment's header and jumps — two or three
      // times per seek — and every jump destroyed all six lanes in flight:
      // 97 new connections for one short session where faststart took 23,
      // each a handshake (two round trips over TLS) before a byte. The
      // other lanes open once the first part is through, or [_fanOutAfter]
      // after its first byte if the player is still there. The index plan
      // fans out at once: that read is never abandoned.
      var fanned = plan.isNotEmpty || lanes <= 1 || carried != null;
      Timer? fanTimer;
      late final void Function() fanOut;

      void topUp() {
        if (stopped || failed || gone()) return;
        while (next < end &&
            parts.length < window &&
            parts.where((p) => !p.settled).length < (fanned ? lanes : 1)) {
          // A part the last stretch gave up is taken over where it covers
          // this byte — the bytes a jump left behind ([_Source.spare]).
          final kept = src.takeSpare(next, end);
          if (kept != null) {
            // A block, not `=> failed = true`: the handler's value becomes
            // the future's, which is void, and a bool there is an uncaught
            // error each time a kept part is let go (the mpv seek bench).
            kept.done.then((_) {
              fanned = true;
              topUp();
            }, onError: (Object _) {
              failed = true;
            });
            parts.add(kept);
            next = min(kept.end, end);
            continue;
          }
          if (rounds &&
              seekSettledBytes > 0 &&
              yieldedTo - start >= seekSettledBytes) {
            rounds = false;
            opened = _rampIndexFor(seekPartBytes(opened, first: firstPart));
          }
          final size = planned < plan.length
              ? plan[planned++]
              : rounds
                  ? seekPartBytes(opened++, first: firstPart)
                  : rampedPartBytes(opened++);
          lastSize = size;
          // …and a new part stops where a kept one starts.
          final partEnd = src.spareStartIn(next, min(next + size, end));
          final part = _LanePart(src.io, url, next, partEnd, total, _laneStall);
          began();
          part.done.then((n) {
            ended(n);
            src.noteLaneSpeed(part.bytesPerSecond);
            fanned = true;
            topUp();
          }, onError: (_) {
            ended(0);
            failed = true;
          });
          parts.add(part);
          next = partEnd;
        }
      }

      fanOut = () {
        if (fanned) return;
        fanned = true;
        fanTimer?.cancel();
        topUp();
      };

      var yielded = false;
      try {
        // Parts the last stretch kept that this one will never reach are
        // given up now, before they take the line from it: after a seek to
        // the other end of the film they were the last few hundred
        // kilobytes of where it had been.
        src.pruneSpare(start, carrying: carried != null);
        // And parts kept just ahead of this stretch mean the player has
        // jumped back a little — a fragmented film's seek, going back for
        // the fragment before — and will read on into them: every lane now.
        if (src.spareAhead(start)) fanned = true;
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
              if (!fanned && fanTimer == null) {
                fanTimer = Timer(_fanOutAfter, fanOut);
              }
              final bytes = p.take();
              if (bytes.isEmpty) continue;
              // A fragment's header where the stretch starts: the player has
              // sought into a fragmented film, and whether it jumps back
              // for the fragment before or not, it reads straight through
              // this one next — fetch it on every lane now. The parts it
              // leaves behind are kept for the stretch after the jump.
              if (!yielded && !fanned && _isMoof(bytes)) fanOut();
              yielded = true;
              yieldedTo += bytes.length;
              yield bytes;
              continue;
            }
            if (p.settled || p.through) break;
            // The player hanging up ends the wait at once, and the stretch
            // with it: its parts are released below, not finished for nobody.
            await Future.any<void>([p.more, if (hungUp != null) hungUp]);
            if (gone()) return;
          }
          // A kept part taken over for less than all of it is through once
          // the bytes this stretch wanted are; the rest of it is not waited
          // for.
          if (!p.through) {
            try {
              await p.done;
            } on _LaneRefused catch (e) {
              if (!yielded && attempt == 0 && e.expired && await _refresh(src)) {
                break stretch; // a fresh link: start the stretch again
              }
              rethrow;
            }
          }
          parts.removeAt(0);
          topUp();
        }
        if (parts.isEmpty) return;
      } finally {
        stopped = true;
        fanTimer?.cancel();
        // The player hung up (a seek). Parts already here, and parts nearly
        // through, are KEPT — bytes, connection and all — for the stretch it
        // opens next ([_Source.spare]): a fragmented film's seek reads one
        // fragment's header, jumps back to the fragment before for its
        // sound, and then reads straight on through the bytes it just left.
        // The rest are destroyed. A failure destroys everything: those
        // connections are not to be trusted.
        //
        // UNLESS THE PLAYER STEPPED BACK into what this stretch has given it
        // ([handOver]): then it will read on into every part still coming,
        // and all of them are kept for the request that replaced this one,
        // with the size they had grown to.
        final step = src.nextStart;
        final run = src.nextRunEnd;
        src.nextStart = null;
        src.nextRunEnd = null;
        if (step != null) stepsSeen++;
        // Inside what this stretch delivered, or further back in a run held
        // on the phone that reaches into it: either way the request reads
        // the phone's copy up to where this stretch is, and on from there.
        final handing = handOver &&
            !failed &&
            yielded &&
            step != null &&
            step <= yieldedTo &&
            (step >= start || (run != null && run >= start));
        if (handing) {
          handedOver++;
          src.noteRamp(yieldedTo,
              _rampIndexFor(max(lastSize, rampedPartBytes(opened))));
        }
        for (final p in parts) {
          if (failed || !(handing ? p.usable : p.release(_finishOnHangUpBelow))) {
            p.kill();
          } else {
            src.keepSpare(p, handedOver: handing);
          }
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
  final Completer<void> _over = Completer<void>();

  /// Completes when the player hangs up.
  Future<void> get hungUp => _hung.future;

  /// Completes once the answer is over and its stretch has put away what it
  /// kept.
  Future<void> get over => _over.future;
  bool get isOver => _over.isCompleted;

  void hangUp() {
    value = true;
    if (!_hung.isCompleted) _hung.complete();
  }

  void finish() {
    if (!_over.isCompleted) _over.complete();
  }
}

class _Source {
  _Source({required this.upstream, required this.refresh, this.offline = false});

  String upstream;

  /// Read as segments of the ladder as HLS ([StreamCacheServer.hlsUrlFor]):
  /// one pooled request each, reading ahead, never lanes.
  bool segmented = false;

  /// The read ahead in flight for this film, if any.
  _Fill? fill;
  final Future<String?> Function() refresh;
  Future<bool>? refreshing;

  /// The length check started when the film was registered, until a request
  /// takes it.
  Future<int>? probing;

  /// One pool of connections for the whole of this film's session — kept
  /// alive between requests, so a stretch costs no new handshake. Room for
  /// two stretches' lanes: the parts a seek leaves behind finish on theirs
  /// while the stretch after it opens its own.
  HttpClient? _io;
  HttpClient get io => _io ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = StreamCacheServer.lanes * 2 + 1;

  /// The player's requests for this film that are still being answered.
  final List<_Gone> serving = [];

  /// What one connection of this film carries, bytes a second: a moving
  /// average over the parts that arrived whole. 0 until one has.
  double _laneSpeed = 0;

  void noteLaneSpeed(int bytesPerSecond) {
    if (bytesPerSecond <= 0) return;
    _laneSpeed = _laneSpeed == 0
        ? bytesPerSecond.toDouble()
        : _laneSpeed * 0.7 + bytesPerSecond * 0.3;
  }

  /// The first round's part after a seek ([StreamCacheServer.seekPartBytes]):
  /// half a second of one connection, 64 KB to 512 KB.
  int get seekFirstPart {
    final half = (_laneSpeed / 2).round().clamp(64 * 1024, 512 * 1024);
    return (half + 16383) & ~16383;
  }

  /// PARTS A STRETCH GAVE UP, KEPT FOR THE NEXT ONE.
  ///
  /// A fragmented film's seek is a jump and a jump back: the player reads
  /// the header of the fragment it seeks into, goes back to the fragment
  /// before for its sound, and then reads straight on into the bytes it has
  /// just left. Those bytes were in flight on six lanes; destroyed, they
  /// were asked for again a moment later, behind the parts that had replaced
  /// them (and a part let finish to keep its connection warm threw its
  /// bytes away). Kept, the next stretch takes them over where it reaches
  /// them ([takeSpare]). A few, briefly: [_spareParts] at most, 8 MB
  /// between them, for [_spareFor].
  ///
  /// Parts HANDED OVER ([StreamCacheServer.handOver]) are outside those
  /// limits — they are the film the player reads next, all of it wanted —
  /// and live for [StreamCacheServer._handOverFor] instead.
  final List<(_LanePart, DateTime, bool)> _spare = [];
  static const Duration _spareFor = Duration(seconds: 20);
  static int get _spareParts => StreamCacheServer.lanes * 2;
  static const int _spareBytes = 8 * 1024 * 1024;

  /// Where the request that replaced the one being answered starts, until
  /// the stretch it replaces has looked ([StreamCacheServer.handOver]).
  int? nextStart;

  /// Where the run held on the phone that [nextStart] is in ends, if it is.
  int? nextRunEnd;

  /// A stretch handed over: where it had reached, the [rampedPartBytes]
  /// index its parts had grown to, and when.
  (int, int, DateTime)? _ramp;

  void noteRamp(int at, int index) => _ramp = (at, index, DateTime.now());

  /// The part-size index to carry on from, for a stretch starting at [at]
  /// where a stretch just handed over had reached; null otherwise.
  int? takeRamp(int at) {
    final r = _ramp;
    _ramp = null;
    if (r == null ||
        DateTime.now().difference(r.$3) > StreamCacheServer._handOverFor ||
        (at - r.$1).abs() > 256 * 1024) {
      return null;
    }
    return r.$2;
  }

  void keepSpare(_LanePart p, {bool handedOver = false}) {
    _spare.add((p, DateTime.now(), handedOver));
    _expireSpare();
  }

  void _expireSpare() {
    final now = DateTime.now();
    _spare.removeWhere((e) {
      if (!e.$3 || now.difference(e.$2) <= StreamCacheServer._handOverFor) {
        return false;
      }
      e.$1.discard();
      return true;
    });
    final kept = [for (final e in _spare) if (!e.$3) e];
    int bytes() => kept.fold(0, (n, e) => n + e.$1.end - e.$1.from);
    while (kept.isNotEmpty &&
        (kept.length > _spareParts ||
            now.difference(kept.first.$2) > _spareFor ||
            bytes() > _spareBytes)) {
      final e = kept.removeAt(0);
      _spare.remove(e);
      e.$1.discard();
    }
    _spare.removeWhere((e) {
      if (!e.$1.usable) e.$1.discard();
      return !e.$1.usable;
    });
  }

  /// A kept part that has [at] still to give, taken over for a stretch that
  /// ends at [end]; null when none does.
  _LanePart? takeSpare(int at, int end) {
    _expireSpare();
    for (var i = 0; i < _spare.length; i++) {
      final p = _spare[i].$1;
      if (p.from <= at && at < p.end) {
        _spare.removeAt(i);
        return p..adopt(at, end);
      }
    }
    return null;
  }

  /// Give up the kept parts a stretch from [at] will not reach: anything
  /// outside the next [_spareReach] bytes. Destroyed, unless what is left of
  /// one comes in a third of a second at this film's speed — on a slow line
  /// a kept part's last 256 KB held the line for seconds after a seek to the
  /// other end of the film, against a handshake saved.
  ///
  /// Parts handed over reach as far as their stretch did, for the stretch
  /// [carrying] it on; for any other — the player jumped again before it
  /// got there — they are spares like the rest.
  void pruneSpare(int at, {bool carrying = false}) {
    final soon = max(32 * 1024, (_laneSpeed * 0.3).round());
    _spare.removeWhere((e) {
      final p = e.$1;
      if (p.end > at && ((e.$3 && carrying) || p.from < at + _spareReach)) {
        return false;
      }
      p.discard(finishBelow: soon);
      return true;
    });
  }

  static const int _spareReach = 4 * 1024 * 1024;

  /// Whether a kept part starts in the 2 MB after [at].
  bool spareAhead(int at) => _spare.any(
      (e) => e.$1.from > at && e.$1.from <= at + 2 * 1024 * 1024);

  /// Where a part from [from] should stop so as not to fetch what a kept
  /// part already holds: the first kept part starting after [from], or [to].
  int spareStartIn(int from, int to) {
    var cut = to;
    for (final e in _spare) {
      final at = e.$1.from;
      if (at > from && at < cut && e.$1.usable) cut = at;
    }
    return cut;
  }

  void close() {
    fill?.cancel();
    fill = null;
    for (final e in _spare) {
      e.$1.discard();
    }
    _spare.clear();
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

  /// Registered by [StreamCacheServer.warmOpening], not by a player.
  bool warmOnly = false;
}

/// How a [StreamCacheServer.warmSwitch] went.
@immutable
class WarmSwitch {
  const WarmSwitch({
    required this.complete,
    required this.bytes,
    required this.took,
    required this.film,
    this.filmTook = Duration.zero,
    this.filmBytes = 0,
  });

  /// Everything planned arrived inside the limit.
  final bool complete;

  /// Bytes fetched in all, index included.
  final int bytes;
  final Duration took;

  /// How much film the fetch was for.
  final Duration film;

  /// The film's bytes alone, and how long they took: the line's speed for
  /// this copy, with the copy on screen playing alongside.
  final Duration filmTook;
  final int filmBytes;

  /// Kilobits a second the film's bytes arrived at; 0 when none did.
  int get kbps => filmTook.inMilliseconds <= 0
      ? 0
      : filmBytes * 8 ~/ filmTook.inMilliseconds;
}

/// What a warm-up learnt of a film, for the play that follows it.
class _Confirmed {
  _Confirmed(this.total, this.index) : at = DateTime.now();
  final int total;
  final (int, int)? index;
  final DateTime at;
  bool get fresh => DateTime.now().difference(at) < StreamCacheServer._confirmedFor;
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
    StreamCacheServer.upstreamRequests++;
    done = _get(client, url, total, stall);
    // Held until its turn; an error before then must not count as unhandled.
    done.then((_) {
      _ok = true;
      _settle();
    }, onError: (_) {
      _failed = true;
      _settle();
    });
  }

  final int start;
  final int end; // exclusive

  /// The part's length once all of it has arrived; fails if it did not.
  late final Future<int> done;

  /// Arrived, failed or stopped: nothing more will come.
  bool settled = false;

  /// Arrived whole, or failed.
  bool _ok = false, _failed = false;

  /// From its answer's headers to its last byte.
  final Stopwatch _clock = Stopwatch();

  /// How fast this part's own connection carried it, in bytes a second, once
  /// it has arrived whole; 0 for a part too small to say.
  int get bytesPerSecond {
    final ms = _clock.elapsedMilliseconds;
    if (!_ok || end - start < 32 * 1024 || ms < 50) return 0;
    return (end - start) * 1000 ~/ ms;
  }

  /// What has arrived and not yet been taken, in order, from [from].
  final BytesBuilder _held = BytesBuilder(copy: false);
  int _received = 0;
  Completer<void>? _arrived;

  /// Where the bytes not yet taken begin.
  late int _heldFrom = start;
  int get from => _heldFrom;

  /// What the stretch reading this part wants of it: [start] to [end], or
  /// less of it for a kept part taken over part way ([adopt]).
  late int _want = start;
  late int _limit = end;

  bool get holding => _held.isNotEmpty && _heldFrom < _limit;

  /// Everything the reading stretch wants of this part has been taken.
  bool get through => _heldFrom >= _limit;

  /// What has arrived since the last call, of what is wanted.
  Uint8List take() {
    var b = _held.takeBytes();
    final at = _heldFrom;
    _heldFrom += b.length;
    final skip = min(b.length, max(0, _want - at));
    final keep = min(b.length, max(0, _limit - at));
    if (skip > 0 || keep < b.length) {
      b = keep <= skip ? Uint8List(0) : Uint8List.sublistView(b, skip, keep);
    }
    return b;
  }

  /// Still worth keeping for another stretch: not failed, not stopped, and
  /// with bytes to give.
  bool get usable => !_failed && !_killed && !_dropped && _heldFrom < end;

  /// Taken over by a stretch that wants it from [at] and ends at [stop].
  void adopt(int at, int stop) {
    _want = at;
    _limit = min(stop, end);
  }

  /// Given up by its stretch: whether it is worth keeping for the next one
  /// ([_Source.keepSpare]) — whole and waiting, or with no more than
  /// [finishBelow] still to come. A part not yet sent for is not kept: it
  /// would take a connection ahead of what the next stretch needs first.
  bool release(int finishBelow) {
    if (!usable) return false;
    if (_ok) return true;
    if (_resp != null) return !_ended && end - start - _received <= finishBelow;
    return _asked && end - start <= finishBelow;
  }

  /// Not wanted after all: nothing more is kept. Its connection is let
  /// finish for the pool when no more than [finishBelow] is still to come —
  /// by default all of a kept part, which is never more than its last
  /// 256 KB; otherwise it is destroyed, and the line is the next stretch's
  /// at once.
  void discard({int finishBelow = StreamCacheServer._finishOnHangUpBelow}) {
    _held.clear();
    if (settled || _killed) return;
    final resp = _resp;
    if (resp != null && !_ended && end - start - _received <= finishBelow) {
      // Read on to the end and dropped ([_get]'s listener).
      _released = true;
      return;
    }
    kill(finishBelow: finishBelow);
  }

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

  /// Stopped, but let finish so its connection goes back to the pool warm:
  /// what still arrives is read and dropped (see [kill]).
  bool _released = false;
  int _finishBelow = 0;

  /// Stop this part. [finishBelow]: a part with no more than this many bytes
  /// still to come is let finish instead, read and dropped, so its
  /// connection returns to the pool rather than being destroyed. A seek
  /// costs the next request a fresh connection otherwise — a TCP and TLS
  /// handshake, two round trips before its first byte — and a fragmented
  /// film's seek is two requests in a row (the fragment, then the one
  /// before it for the audio).
  void kill({int finishBelow = 0}) {
    if (_killed) return;
    _killed = true;
    _finishBelow = finishBelow;
    final resp = _resp;
    if (resp != null) {
      if (!_ended && finishBelow > 0 && end - start - _received <= finishBelow) {
        _released = true;
        _held.clear();
      } else {
        _destroy();
      }
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
    StreamDoor.apply(req, url);
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
    _asked = true;
    final resp = await req.close().timeout(stall, onTimeout: () {
      req.abort();
      throw _LaneRefused('part $start: no answer');
    });
    StreamCacheServer._noteBind(resp);
    _resp = resp;
    if (_killed) {
      // Stopped while the answer was on its way. A small one is read to its
      // end — bounded by its own length, the range just asked for — so the
      // connection is kept; anything else is destroyed.
      if (_finishBelow > 0 &&
          want <= _finishBelow &&
          resp.statusCode == 206 &&
          resp.contentLength == want) {
        _released = true;
        _sub = resp.listen((_) {}, onDone: () => _ended = true,
            onError: (Object _) => _ended = true, cancelOnError: true);
      } else {
        _drop(resp);
      }
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
    _clock.start();
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
      // Released by [kill]: read on to the end for the pool, keep nothing.
      if (_released) {
        _received += chunk.length;
        arm();
        if (_received > want) {
          quiet?.cancel();
          _destroy();
        }
        return;
      }
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
        _clock.stop();
        done.complete(want);
      }
    }, cancelOnError: true);
    return done.future;
  }
}

/// One rung of a ladder registered as HLS.
class HlsRungSource {
  const HlsRungSource({
    required this.height,
    required this.kbps,
    required this.cacheId,
    required this.upstream,
    required this.refresh,
    this.bytes,
  });

  final int height;
  final int kbps;
  final String cacheId;
  final String upstream;
  final Future<String?> Function() refresh;
  final int? bytes;
}

class _Ladder {
  _Ladder({required this.rungs, this.aspect, this.frameRate});
  final List<_LadderRung> rungs;
  final double? aspect;
  final double? frameRate;
}

class _LadderRung {
  _LadderRung({required this.height, required this.kbps, required this.cacheId, required this.url});
  final int height;
  final int kbps;
  final String cacheId;
  final String url;
  CmafIndex? index;
  CmafHead? head;
  Future<void>? loading;

  HlsRung get hls => HlsRung(height: height, kbps: kbps, url: url, index: index, head: head);
}

/// A read ahead in flight: where it started, where it will stop, and a
/// signal each time more of it is on the phone.
class _Fill {
  _Fill(this.from, this.to);
  final int from;
  final int to;
  bool done = false;
  bool cancelled = false;
  void Function()? onCancel;
  final StreamController<void> _more = StreamController<void>.broadcast();

  void ping() {
    if (!_more.isClosed) _more.add(null);
  }

  void finish() {
    done = true;
    ping();
    unawaited(_more.close());
  }

  void cancel() {
    if (cancelled) return;
    cancelled = true;
    onCancel?.call();
  }

  /// Until [ready] is true, the read has ended, the player has hung up, or
  /// twenty seconds have gone by — a read stuck that long is a read to
  /// replace, not to wait for.
  Future<void> until(bool Function() ready, _Gone gone) async {
    if (ready() || done) return;
    final c = Completer<void>();
    late final StreamSubscription<void> sub;
    void check() {
      if (!c.isCompleted && (ready() || done || gone.value)) c.complete();
    }

    sub = _more.stream.listen((_) => check(), onDone: () {
      if (!c.isCompleted) c.complete();
    });
    unawaited(gone.hungUp.then((_) => check()));
    check();
    await c.future.timeout(const Duration(seconds: 20), onTimeout: () {});
    await sub.cancel();
  }
}
