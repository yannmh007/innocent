/// The unseal gateway: a sealed object in R2, read as the plain film it holds
/// (docs/MEDIA_ENCRYPTION.md §6).
///
/// WHERE IT SITS. Between the stream proxy (StreamCacheServer) and the
/// Worker. The proxy registers a sealed film's URL here and gets a loopback
/// address back, which it then fetches exactly as it fetched the Worker:
/// ranges of the film, a 206 with the film's own length, 403 for an expired
/// link, 429 to slow down. Everything the proxy does — lanes, seeks, the
/// hand-over, the ladder as HLS, its sealed cache on disk — is unchanged and
/// does not know a seal exists.
///
/// WHAT IT DOES WITH A RANGE. Plain bytes `[a, b]` are in segments
/// `segmentOf(a)..segmentOf(b)`; it asks the Worker for exactly those whole
/// segments (one aligned range), opens each as it arrives (the platform's
/// AES-GCM, one call per run of segments that have arrived — never per
/// segment, never per network read), and sends on the bytes asked for. A
/// segment is checked before a byte of it is passed on: one that does not
/// open is fetched once more, and if it still does not, the request ends
/// with an error — never a corrupt frame.
///
/// A SEGMENT ABOUT TO ARRIVE IS NOT FETCHED TWICE. The proxy's lanes split
/// a stretch at points of their own, so two parts can start and end inside
/// the same segment. A segment on its way for one request, and close to
/// arriving, is waited for by the other ([_Pending], [_joinReach]); the last
/// few opened are kept ([_recentCap]). One FAR down another read's way is
/// fetched on this request's own: a jump into a read-ahead, or the next lane
/// starting where a long part ends, does not wait for the read before it to
/// get there (device lab run 41293034978: 3.9 s for a skip's first byte).
///
/// ON LOOPBACK, BEHIND A TOKEN, as the proxy is: nothing else on the phone
/// can read a film through it.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../../../core/services/diagnostics/playback_log.dart';
import '../stream_door.dart';
import 'media_seal.dart';
import 'media_seal_layout.dart';

class UnsealGateway {
  UnsealGateway({SealCipher? cipher}) : _cipher = cipher ?? PlatformSealCipher.instance;

  /// The one the stream proxy routes through. Replaced only by tests, with
  /// a gateway on a cipher written for them.
  static UnsealGateway instance = UnsealGateway();

  final SealCipher _cipher;
  HttpServer? _server;
  Future<void>? _starting;
  String? _token;
  final Map<String, _Sealed> _objects = <String, _Sealed>{};

  /// What a run of segments may be, at most, per call to the platform.
  static const int _runSegments = 16;

  /// How far down another fetch's way a segment may be and still be waited
  /// for there: the one arriving now, or the one after it — 128 KB, less
  /// than a round trip to the Worker on the lines the films are made for.
  /// Further, its own fetch is the quicker; the cost is at most one segment
  /// read twice where a lane's part ends.
  static const int _joinReach = 1;

  /// Opened segments kept for the next request, per object: half a
  /// megabyte, enough for the neighbour a lane reaches a moment later.
  static const int _recentCap = 8;

  /// Objects registered at once, the least recently registered let go
  /// first: a ladder's rungs and the film before it, with room to spare.
  static const int _objectCap = 12;

  /// How long the Worker may send nothing before the fetch is taken as
  /// stalled — the proxy's own lane stall.
  static Duration stall = const Duration(seconds: 15);

  /// Counted for the lab's trail and the tests.
  static int upstreamRequests = 0, segmentsOpened = 0, refetches = 0, refused = 0;

  /// Worker answers that came on a connection opened for them.
  static int newConnections = 0;

  /// ONE POOL FOR EVERY OBJECT, kept a minute between reads, as the proxy's
  /// ladder pool is: every rung is on the same Worker, so a change of rung,
  /// or a jump after the last read was cut (a cut connection cannot be used
  /// again), finds a connection already open instead of a new handshake —
  /// two or three round trips. One pool per object left a rung with nothing
  /// open after a jump: answers of 0.55-2.2 s where plain films had
  /// 0.25-0.9 s (device lab run 41984466643).
  HttpClient? _io;
  HttpClient get io => _io ??= HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 60)
    ..maxConnectionsPerHost = 16;

  /// Local ports of the connections answers came on, to tell a new one.
  final LinkedHashSet<int> _ports = LinkedHashSet<int>();

  /// Starts the loopback server; registering an object needs it running.
  Future<void> start() {
    if (_server != null) return Future<void>.value();
    return _starting ??= () async {
      final rnd = Random.secure();
      _token = List<int>.generate(24, (_) => rnd.nextInt(256))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s.listen(_handle, onError: (Object e) {
        if (kDebugMode) debugPrint('UnsealGateway: $e');
      });
      _server = s;
    }();
  }

  /// Registers a sealed object read from [upstream] and returns the
  /// loopback address its plaintext is read from; null when the gateway
  /// cannot start. The DEK is handed to the platform now, so its unwrap
  /// (one Keystore operation) runs beside the first fetch.
  Future<String?> urlFor({required String id, required String upstream, required SealGrant seal}) async {
    try {
      await start();
      return route(id, upstream, seal);
    } catch (e) {
      if (kDebugMode) debugPrint('UnsealGateway.urlFor: $e');
      return null;
    }
  }

  /// [urlFor] once the gateway is running ([start]); null before. A
  /// renewed link of the same object only moves its upstream: what it has
  /// opened, and its DEK, stay.
  String? route(String id, String upstream, SealGrant seal) {
    final port = _server?.port;
    final token = _token;
    if (port == null || token == null) return null;
    final old = _objects.remove(id);
    if (old != null && old.seal.dekId == seal.dekId && old.seal.plainSize == seal.plainSize) {
      old.upstream = upstream;
      _objects[id] = old; // most recent last
    } else {
      old?.close();
      _objects[id] = _Sealed(this, upstream, seal);
      while (_objects.length > _objectCap) {
        _objects.remove(_objects.keys.first)?.close();
      }
    }
    return 'http://127.0.0.1:$port/u/$token/$id';
  }

  /// A renewed link for a registered object. False when the renewal is not
  /// the same object (another DEK or size): the caller then registers it
  /// afresh.
  bool update(String id, String upstream, SealGrant seal) {
    final o = _objects[id];
    if (o == null || o.seal.dekId != seal.dekId || o.seal.plainSize != seal.plainSize) return false;
    o.upstream = upstream;
    return true;
  }

  void forget(String id) => _objects.remove(id)?.close();

  @visibleForTesting
  Future<void> shutdown() async {
    for (final o in _objects.values) {
      o.close();
    }
    _objects.clear();
    _io?.close(force: true);
    _io = null;
    _ports.clear();
    await _server?.close(force: true);
    _server = null;
    _starting = null;
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      if (seg.length != 3 || seg[0] != 'u' || seg[1] != _token) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      final o = _objects[seg[2]];
      if (o == null) {
        // Not registered (any more): what an expired link looks like, so
        // the proxy renews and registers again.
        res.statusCode = HttpStatus.gone;
        await res.close();
        return;
      }
      await o.serve(req);
    } catch (e) {
      if (kDebugMode) debugPrint('UnsealGateway._handle: $e');
      try {
        final s = await res.detachSocket(writeHeaders: false);
        s.destroy();
      } catch (_) {}
    }
  }
}

/// Why a segment did not come: the Worker's answer, the network, or a
/// segment that did not open twice.
class _Fail {
  const _Fail(this.status, {this.retryAfter, this.why = ''});
  final int status;
  final String? retryAfter;
  final String why;

  static const _Fail network = _Fail(HttpStatus.badGateway, why: 'network');
}

/// A segment on its way: the request that sent for it and any that wait on
/// it share one answer.
class _Pending {
  final Completer<Object> done = Completer<Object>(); // Uint8List | _Fail
  int waiters = 0;
}

/// One fetch from the Worker: segments [s0]..[s1], one aligned range, and
/// how far it has got ([next], the first segment not yet opened).
class _Run {
  _Run(this.s0, this.s1) : next = s0;
  final int s0, s1;
  int next;

  /// Its segments not yet delivered, each with the requests waiting on it.
  final Map<int, _Pending> own = <int, _Pending>{};

  /// Whether a request may wait here for segment [i]: on its way in this
  /// fetch, and close to arriving.
  _Pending? joinable(int i) {
    final p = own[i];
    if (p == null || p.done.isCompleted) return null;
    return i - next <= UnsealGateway._joinReach ? p : null;
  }
}

class _Sealed {
  _Sealed(this.gateway, this.upstream, this.seal)
      : count = MediaSealLayout.segmentCount(seal.plainSize) {
    // Handed to the platform now: its unwrap runs beside the first fetch.
    unawaited(keyReady());
    final h = seal.header;
    if (h != null) _header = Future<Uint8List?>.value(h);
  }

  final UnsealGateway gateway;
  String upstream;
  final SealGrant seal;
  final int count;
  Future<bool>? _registered;
  Future<Uint8List?>? _header;

  /// What the Worker last said about this install's bound token (`x-bind`),
  /// passed on so the proxy's trail counts sealed films too.
  String? lastBind;

  /// The DEK held by the platform. A registration that failed (a Keystore
  /// that was busy) is tried again by the next fetch, not given up for good.
  Future<bool> keyReady() => _registered ??= gateway._cipher.register(seal).then((ok) {
        PlaybackLog.add('seal: key ${ok ? 'held' : 'NOT held'} (${seal.wrap})');
        if (!ok) _registered = null;
        return ok;
      });
  bool _closed = false;

  final LinkedHashMap<int, Uint8List> _recent = LinkedHashMap<int, Uint8List>();

  /// The fetches going on: a handful at most (the proxy's lanes, a
  /// download's parts).
  final List<_Run> _live = <_Run>[];

  void close() {
    _closed = true;
    for (final r in _live) {
      for (final p in r.own.values) {
        if (!p.done.isCompleted) p.done.complete(const _Fail(HttpStatus.gone, why: 'closed'));
      }
      r.own.clear();
    }
    _live.clear();
    _recent.clear();
  }

  Future<void> serve(HttpRequest req) async {
    final res = req.response;
    final total = seal.plainSize;
    final range = _parseRange(req.headers.value(HttpHeaders.rangeHeader), total);
    if (range == null || total == 0) {
      res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
      await res.close();
      return;
    }
    final (a, b, ranged) = range;
    final first = MediaSealLayout.segmentOf(a);
    final last = MediaSealLayout.segmentOf(b);

    // Every segment this request needs: opened already, about to arrive
    // for another request, or sent for now — in runs of consecutive
    // segments, one aligned range each.
    final want = <int, Future<Object>>{};
    final held = <int, _Pending>{}; // what this request counts as waiting on
    final mine = <int>[];
    for (var i = first; i <= last; i++) {
      final r = _recent.remove(i);
      if (r != null) {
        _recent[i] = r; // most recent last
        want[i] = Future<Object>.value(r);
        continue;
      }
      _Pending? p;
      for (final run in _live) {
        p = run.joinable(i);
        if (p != null) break;
      }
      if (p != null) {
        p.waiters++;
        held[i] = p;
        want[i] = p.done.future;
        continue;
      }
      mine.add(i);
    }
    for (final (s0, s1) in _runs(mine)) {
      final run = _Run(s0, s1);
      for (var i = s0; i <= s1; i++) {
        final p = run.own[i] = held[i] = _Pending()..waiters = 1;
        want[i] = p.done.future;
      }
      unawaited(_drive(run));
    }
    void release(int i) {
      final p = held.remove(i);
      if (p != null && p.waiters > 0) p.waiters--;
    }

    var i = first;
    Socket? out;
    try {
      // THE STATUS WAITS FOR THE FIRST SEGMENT. After a 206 has gone out,
      // an expired link can no longer be said; before it, the proxy is
      // told exactly what the Worker said and renews as it always has.
      final head = await want[first]!;
      // ONE REQUEST, ONE CONNECTION, as the proxy answers its player: on
      // loopback a connection costs nothing, and a detached socket says at
      // once when the proxy lets go of a part (its input ends) — which is
      // what stops the Worker's fetch for bytes nobody wants any more.
      res.headers.set(HttpHeaders.connectionHeader, 'close');
      if (head is _Fail) {
        res.statusCode = head.status;
        if (head.retryAfter != null) res.headers.set('retry-after', head.retryAfter!);
        await res.close();
        return;
      }
      res.statusCode = ranged ? HttpStatus.partialContent : HttpStatus.ok;
      res.headers.contentType = ContentType.binary;
      res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      if (ranged) res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $a-$b/$total');
      final bind = lastBind;
      if (bind != null) res.headers.set('x-bind', bind);
      res.contentLength = b - a + 1;
      final sock = out = await res.detachSocket(writeHeaders: true);
      final hung = Completer<void>();
      sock.listen((_) {}, onDone: () {
        if (!hung.isCompleted) hung.complete();
      }, onError: (Object _) {
        if (!hung.isCompleted) hung.complete();
      }, cancelOnError: true);
      for (; i <= last; i++) {
        final got = i == first ? head : await _orHangUp(want[i]!, hung);
        release(i);
        if (got == null) {
          i++;
          return; // the proxy let go
        }
        if (got is! Uint8List) {
          // Part way through: the length promised cannot be kept. The
          // connection is cut, and the proxy reads a short part as the
          // failure it is.
          i++;
          return;
        }
        final p0 = MediaSealLayout.plainStart(i);
        final from = max(a, p0) - p0;
        final to = min(b + 1, p0 + got.length) - p0;
        sock.add(from == 0 && to == got.length ? got : Uint8List.sublistView(got, from, to));
        if (await _orHangUp(sock.flush().then((_) => true), hung) == null) {
          i++;
          return;
        }
      }
      await sock.close();
      out = null;
    } finally {
      // Whatever this request did not reach, it no longer waits for.
      for (; i <= last; i++) {
        release(i);
      }
      out?.destroy();
    }
  }

  /// [f], or null once the proxy has hung up — whichever is first.
  static Future<Object?> _orHangUp(Future<Object> f, Completer<void> hung) {
    if (hung.isCompleted) return Future<Object?>.value(null);
    final c = Completer<Object?>();
    f.then((v) {
      if (!c.isCompleted) c.complete(v);
    }, onError: (Object _) {
      if (!c.isCompleted) c.complete(_Fail.network);
    });
    hung.future.then((_) {
      if (!c.isCompleted) c.complete(null);
    });
    return c.future;
  }

  /// [segments] (ascending) as runs of consecutive ones.
  static Iterable<(int, int)> _runs(List<int> segments) sync* {
    if (segments.isEmpty) return;
    var s = segments.first, e = s;
    for (final i in segments.skip(1)) {
      if (i == e + 1) {
        e = i;
        continue;
      }
      yield (s, e);
      s = e = i;
    }
    yield (s, e);
  }

  /// The object's header: from the grant, or its first 40 bytes.
  Future<Uint8List?> header() => _header ??= () async {
        for (var attempt = 0; attempt < 2; attempt++) {
          final got = await _get(0, MediaSealLayout.header);
          if (got is _Got) {
            // Forty bytes and no more, even from a server that ignored the
            // range and is sending the whole object.
            final bb = BytesBuilder(copy: false);
            final enough = Completer<void>();
            final sub = got.resp.listen((c) {
              bb.add(c);
              if (bb.length >= MediaSealLayout.header && !enough.isCompleted) enough.complete();
            }, onError: (Object _) {
              if (!enough.isCompleted) enough.complete();
            }, onDone: () {
              if (!enough.isCompleted) enough.complete();
            }, cancelOnError: true);
            await enough.future.timeout(UnsealGateway.stall, onTimeout: () {});
            _destroy(got.resp, sub);
            final all = bb.takeBytes();
            if (all.length < MediaSealLayout.header) continue;
            final h = Uint8List.fromList(Uint8List.sublistView(all, 0, MediaSealLayout.header));
            return h[0] == MediaSealLayout.header ? h : null;
          }
        }
        return null;
      }().then((h) {
        if (h == null) _header = null; // asked again by the next request
        return h;
      });

  /// Fetch [r]: its segments as one range, each delivered as it opens.
  /// Segments that do not open are fetched once more before they are given
  /// up; whatever is left undelivered at the end has failed.
  Future<void> _drive(_Run r) async {
    _live.add(r);
    try {
      final from = await _attempt(r, r.s0);
      if (from != null && !_closed) await _attempt(r, from, again: true);
    } finally {
      _live.remove(r);
      for (final p in r.own.values) {
        if (!p.done.isCompleted) p.done.complete(_Fail.network);
      }
      r.own.clear();
    }
  }

  /// Segments [s0]..`r.s1` of [r], sent for as one range; each completes
  /// its [_Pending] as it opens. Returns the segment to fetch again from
  /// when one did not open (and this was not [again] already), else null.
  Future<int?> _attempt(_Run r, int s0, {bool again = false}) async {
    final s1 = r.s1;
    r.next = s0;
    int? refetchFrom;
    void failFrom(int from, _Fail f) {
      for (var i = from; i <= s1; i++) {
        final p = r.own.remove(i);
        if (p != null && !p.done.isCompleted) p.done.complete(f);
      }
    }

    final start = MediaSealLayout.sealedStart(s0);
    final end = s1 + 1 < count ? MediaSealLayout.sealedStart(s1 + 1) : seal.sealedSize;
    final headerF = header();
    final ok = keyReady();
    final got = await _get(start, end);
    if (got is _Fail) {
      failFrom(s0, got);
      return null;
    }
    final resp = (got as _Got).resp;
    final hdr = await headerF;
    if (hdr == null || !await ok) {
      _destroy(resp);
      UnsealGateway.refused++;
      PlaybackLog.add('seal: ${hdr == null ? 'no header' : 'the key did not register'} for ${seal.dekId.substring(0, min(8, seal.dekId.length))}');
      failFrom(s0, const _Fail(HttpStatus.badGateway, why: 'no key'));
      return null;
    }

    final buf = BytesBuilder(copy: false);
    var at = start; // sealed offset of buf's first byte
    var opening = Future<void>.value();
    var busy = false;
    final done = Completer<void>();
    // SILENCE IS CHECKED, NOT TIMED PER PIECE: one look a quarter of the
    // stall apart, where a timer re-armed for every 16 KB piece was 64
    // timers a megabyte on the thread that draws the app.
    final quiet = Stopwatch()..start();
    Timer? watch;
    StreamSubscription<List<int>>? sub;
    var stopped = false;
    var received = 0;
    var ended = false;

    // A FETCH READ TO ITS END GIVES ITS CONNECTION BACK. Every finished
    // fetch used to destroy its socket like a cut one, so no connection to
    // the Worker was ever used twice: every fetch paid a new TCP and TLS
    // handshake, two or three round trips. Only a fetch cut short, or one
    // that is not exactly the range asked for, is destroyed now; one whose
    // last byte has come is left to end, and dart:io puts it back in the
    // pool ([UnsealGateway.io]).
    void stop(_Fail? f, {bool whole = false}) {
      if (stopped) return;
      stopped = true;
      watch?.cancel();
      final complete = whole && resp.contentLength == end - start && received == end - start;
      if (!ended && !complete) _destroy(resp, sub);
      if (f != null) failFrom(r.next, f);
      if (!done.isCompleted) done.complete();
    }

    // Opens every whole segment gathered, up to a run's worth, while the
    // next bytes keep arriving.
    Future<void> openWhat() async {
      if (busy) return;
      busy = true;
      try {
        while (!stopped && r.next <= s1) {
          var n = 0, len = 0;
          while (n < UnsealGateway._runSegments && r.next + n <= s1) {
            final l = _sealedLength(r.next + n);
            if (len + l > buf.length) break;
            len += l;
            n++;
          }
          if (n == 0) break;
          final all = buf.takeBytes();
          final run = Uint8List.sublistView(all, 0, len);
          if (all.length > len) buf.add(Uint8List.sublistView(all, len));
          final plain = await gateway._cipher.openRun(
              dekId: seal.dekId, header: hdr, plainTotal: seal.plainSize, first: r.next, sealed: run);
          if (stopped) return;
          if (plain == null) {
            // NOT OPENED. Which one, segment by segment from the bytes
            // already here — so the good ones before it still go on — then
            // that one fetched once more, then given up.
            if (n > 1) {
              var o = 0;
              while (!stopped && r.next <= s1) {
                final l = _sealedLength(r.next);
                if (o + l > run.length) break;
                final one = await gateway._cipher.openRun(
                    dekId: seal.dekId, header: hdr, plainTotal: seal.plainSize, first: r.next,
                    sealed: Uint8List.sublistView(run, o, o + l));
                if (stopped) return;
                if (one == null) break;
                _deliver(r.next, one);
                UnsealGateway.segmentsOpened++;
                o += l;
                at += l;
                r.next++;
              }
              if (stopped) return;
            }
            final from = r.next;
            stop(null);
            if (!again) {
              UnsealGateway.refetches++;
              PlaybackLog.add('seal: segments $from..${from + n - 1} did not open; fetched again');
              refetchFrom = from;
            } else {
              UnsealGateway.refused++;
              PlaybackLog.add('seal: segments $from..${from + n - 1} did not open twice');
              failFrom(from, const _Fail(HttpStatus.badGateway, why: 'does not open'));
            }
            return;
          }
          var o = 0;
          for (var k = 0; k < n; k++) {
            final pl = _sealedLength(r.next) - MediaSealLayout.tag;
            _deliver(r.next, Uint8List.sublistView(plain, o, o + pl));
            o += pl;
            at += _sealedLength(r.next);
            r.next++;
          }
          UnsealGateway.segmentsOpened += n;
          if (r.next > s1) {
            stop(null, whole: true);
            return;
          }
          if (!_wanted(r)) {
            // Nobody waits for the rest any more (a seek moved on): the
            // connection is cut rather than read on.
            stop(const _Fail(HttpStatus.gone, why: 'not wanted'));
            return;
          }
        }
      } finally {
        busy = false;
      }
    }

    final every = UnsealGateway.stall ~/ 4;
    watch = Timer.periodic(every < const Duration(milliseconds: 50) ? const Duration(milliseconds: 50) : every, (_) {
      if (quiet.elapsed >= UnsealGateway.stall) stop(_Fail.network);
    });
    // The opener is woken when a whole segment has gathered, not for every
    // piece: one that is opening already takes up what arrives meanwhile.
    var woken = false;
    sub = resp.listen((chunk) {
      received += chunk.length;
      if (stopped) return;
      quiet.reset();
      buf.add(chunk);
      if (at + buf.length > end) {
        // Never more than was asked for: a server that ignored the range.
        final keep = end - at;
        final all = buf.takeBytes();
        buf.add(Uint8List.sublistView(all, 0, keep));
      }
      if (!woken && r.next <= s1 && buf.length >= _sealedLength(r.next)) {
        woken = true;
        opening = opening.then((_) {
          woken = false;
          return openWhat();
        });
      }
    }, onError: (Object e) {
      opening.whenComplete(() => stop(_Fail.network));
    }, onDone: () {
      ended = true;
      opening.then((_) => openWhat()).whenComplete(() {
        if (r.next <= s1) stop(_Fail.network);
        stop(null);
      });
    }, cancelOnError: true);
    await done.future;
    return refetchFrom;
  }

  /// Whether a request still waits for any of [r]'s segments not yet opened.
  bool _wanted(_Run r) {
    for (var i = r.next; i <= r.s1; i++) {
      final p = r.own[i];
      if (p != null && p.waiters > 0) return true;
    }
    return false;
  }

  void _deliver(int i, Uint8List plain) {
    _recent.remove(i);
    // A view into a run of several is copied: kept as it is it would hold
    // the whole run (up to a megabyte) for one segment. A run of one is
    // kept as it came.
    _recent[i] = plain.offsetInBytes == 0 && plain.lengthInBytes == plain.buffer.lengthInBytes
        ? plain
        : Uint8List.fromList(plain);
    while (_recent.length > UnsealGateway._recentCap) {
      _recent.remove(_recent.keys.first);
    }
    // To every fetch that has it on the way: one opened first is as good
    // for the requests waiting on the other.
    for (final r in _live) {
      final p = r.own.remove(i);
      if (p != null && !p.done.isCompleted) p.done.complete(plain);
    }
  }

  int _sealedLength(int i) {
    final s = MediaSealLayout.sealedStart(i);
    final e = i + 1 < count ? MediaSealLayout.sealedStart(i + 1) : seal.sealedSize;
    return e - s;
  }

  /// One range from the Worker on this object's pool: the answer, or why
  /// not. An expired link, a refusal and "slow down" are passed back as
  /// they came, for the proxy to act on as it always has.
  Future<Object> _get(int start, int end) async {
    if (_closed) return const _Fail(HttpStatus.gone, why: 'closed');
    try {
      final up = Uri.parse(upstream);
      final asked = Stopwatch()..start();
      final r = await gateway.io.getUrl(up).timeout(UnsealGateway.stall);
      UnsealGateway.upstreamRequests++;
      StreamDoor.apply(r, up);
      r.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-${end - 1}');
      final resp = await r.close().timeout(UnsealGateway.stall);
      _noteAnswer(resp, asked.elapsedMilliseconds);
      lastBind = resp.headers.value('x-bind') ?? lastBind;
      final code = resp.statusCode;
      final cr = resp.headers.value(HttpHeaders.contentRangeHeader) ?? '';
      if (code == HttpStatus.partialContent && cr == 'bytes $start-${end - 1}/${seal.sealedSize}') {
        return _Got(resp);
      }
      if (code == HttpStatus.ok && start == 0 && resp.contentLength == seal.sealedSize) {
        return _Got(resp);
      }
      final retryAfter = resp.headers.value('retry-after');
      _destroy(resp);
      if (code == HttpStatus.partialContent || code == HttpStatus.ok) {
        // A length that is not the sealed object the grant described.
        PlaybackLog.add('seal: the Worker sent $cr, not ${seal.sealedSize} sealed bytes');
        return const _Fail(HttpStatus.badGateway, why: 'not this object');
      }
      return _Fail(code >= 500 ? HttpStatus.badGateway : code, retryAfter: retryAfter, why: 'HTTP $code');
    } catch (e) {
      if (kDebugMode) debugPrint('UnsealGateway._get: $e');
      return _Fail.network;
    }
  }

  /// The trail's line for a Worker answer worth a look: one on a new
  /// connection (a handshake paid), or a slow one.
  void _noteAnswer(HttpClientResponse resp, int ms) {
    final port = resp.connectionInfo?.localPort;
    final ports = gateway._ports;
    final fresh = port != null && !ports.contains(port);
    if (port != null) {
      ports.remove(port);
      ports.add(port);
      while (ports.length > 64) {
        ports.remove(ports.first);
      }
    }
    if (fresh) UnsealGateway.newConnections++;
    if (fresh || ms >= 400) {
      PlaybackLog.add('seal: Worker answered in $ms ms${fresh ? ', on a new connection' : ''}');
    }
  }

  /// THE CONNECTION IS DESTROYED, NOT DRAINED: cancelling a dart:io
  /// response reads the rest of it for the pool (see _LanePart._destroy).
  static void _destroy(HttpClientResponse resp, [StreamSubscription<List<int>>? sub]) {
    unawaited(resp.detachSocket().then((s) => s.destroy(), onError: (Object _) {
      try {
        unawaited((sub ?? resp.listen(null)).cancel());
      } catch (_) {}
    }).whenComplete(() => sub?.cancel()));
  }

  /// `bytes=a-b` / `bytes=a-` / no header, against [total]: (a, b, ranged),
  /// or null when unsatisfiable.
  static (int, int, bool)? _parseRange(String? header, int total) {
    if (header == null || header.isEmpty) return total > 0 ? (0, total - 1, false) : null;
    final m = RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(header.trim());
    if (m == null) return null;
    final a = int.parse(m.group(1)!);
    final b = m.group(2)!.isEmpty ? total - 1 : min(int.parse(m.group(2)!), total - 1);
    if (a > b || a >= total) return null;
    return (a, b, true);
  }
}

class _Got {
  const _Got(this.resp);
  final HttpClientResponse resp;
}

