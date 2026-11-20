import 'dart:collection';

import 'package:flutter/foundation.dart';

/// THE SEEK BAR'S PICTURES MADE IN ADVANCE (trick-play, docs/trickplay_plan.md).
///
/// The transcode's job (tool/trickplay_job.py) takes one small picture every
/// few seconds of a film from its smallest plain rung and packs them into ONE
/// file beside the rungs — `ITP1`, laid out by tool/trickplay.py (the
/// reference). The playback grant signs its address exactly as a rung's
/// (request-playback's additive `trickplay` field), and the app reads it
/// through the stream proxy like a rung (StreamCacheServer.packRange): the
/// header once, then any picture, or a run of neighbours, in ONE range
/// request. The picture is a whole JPEG: no video decode on the phone.
///
/// Without a pack — a film before its backfill, a sealed-only film, a pack
/// that does not read as this one — the seek bar takes its pictures from
/// the smallest rung's fragments, as before.
///
/// IN MEMORY ONLY. Like every preview picture (docs/MEDIA_ENCRYPTION.md,
/// ENC-4), nothing read here is ever written to disk in the clear: an LRU of
/// [TrickplayPack.cacheBytes] a film, dropped with the film.

/// What the grant says of a film's pack (`trickplay: {url, bytes,
/// interval_ms, width, height, count, codec}`). Null from [fromJson] for
/// anything this reader must not try: no field (an older server, or no pack
/// yet), a codec other than JPEG, a count, interval or size of zero or less,
/// no url, a sealed pack, or a header that could not fit in the file.
@immutable
class TrickplayInfo {
  const TrickplayInfo({
    required this.url,
    required this.bytes,
    required this.intervalMs,
    required this.width,
    required this.height,
    required this.count,
  });

  /// The pack's signed address (never written to the trail).
  final String url;

  /// The object's size: the last offset must end exactly here.
  final int bytes;

  /// Picture i is the film at i × [intervalMs].
  final int intervalMs;
  final int width;
  final int height;
  final int count;

  /// The only codec this reader takes (the job writes `jpeg`).
  static const String codec = 'jpeg';

  /// A film of ~110 hours at 4 s: anything above is not a pack this app
  /// should allocate a header for.
  static const int maxCount = 100000;

  /// ITP1's header length for [count] pictures: 24 bytes, then one offset
  /// a picture and one for the end.
  static int headerLengthFor(int count) => 24 + 4 * (count + 1);

  int get headerLength => headerLengthFor(count);

  /// Whether [other] describes the same pack, its address aside: a renewed
  /// grant's pack is read with the header already read only if so.
  bool sameObjectAs(TrickplayInfo other) =>
      bytes == other.bytes &&
      intervalMs == other.intervalMs &&
      width == other.width &&
      height == other.height &&
      count == other.count;

  static TrickplayInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    // A sealed pack is a later step (ENC-4): v1 reads plain packs only.
    if (raw['seal'] != null) return null;
    final url = raw['url'];
    if (url is! String || url.isEmpty) return null;
    if (raw['codec'] != codec) return null;
    int? n(Object? v) =>
        v is int ? v : (v is num && v.isFinite && v == v.roundToDouble() ? v.toInt() : null);
    final bytes = n(raw['bytes']);
    final interval = n(raw['interval_ms']);
    final width = n(raw['width']);
    final height = n(raw['height']);
    final count = n(raw['count']);
    if (bytes == null || interval == null || width == null || height == null || count == null) {
      return null;
    }
    if (bytes <= 0 || interval <= 0 || width <= 0 || height <= 0 || count <= 0) return null;
    if (count > maxCount || headerLengthFor(count) >= bytes) return null;
    return TrickplayInfo(
        url: url, bytes: bytes, intervalMs: interval, width: width, height: height, count: count);
  }
}

/// An ITP1 header read and checked against the grant ([parse]).
@immutable
class TrickplayHeader {
  const TrickplayHeader._(this.offsets);

  /// count + 1 offsets: picture i is bytes [offsets[i], offsets[i + 1]).
  final List<int> offsets;

  static const List<int> magic = <int>[0x49, 0x54, 0x50, 0x31]; // 'ITP1'
  static const int version = 1;
  static const int jpeg = 1;

  /// The header in [data] (the pack's first bytes), or the reason it is
  /// not one this reader takes: magic `ITP1`, version 1, JPEG, the
  /// interval, size and count the grant named, the header length that
  /// count makes, every offset there, the first at the header's end, none
  /// going back, the last at the object's end.
  static (TrickplayHeader?, String) parse(Uint8List data, TrickplayInfo expect) {
    if (data.length < 24) return (null, 'cut short inside the header');
    for (var i = 0; i < 4; i++) {
      if (data[i] != magic[i]) return (null, 'not an ITP1 pack');
    }
    final b = ByteData.sublistView(data);
    final ver = b.getUint16(4);
    final codec = b.getUint16(6);
    final interval = b.getUint32(8);
    final width = b.getUint16(12);
    final height = b.getUint16(14);
    final count = b.getUint32(16);
    final headerLen = b.getUint32(20);
    if (ver != version) return (null, 'version $ver');
    if (codec != jpeg) return (null, 'codec $codec');
    if (interval != expect.intervalMs ||
        width != expect.width ||
        height != expect.height ||
        count != expect.count) {
      return (null, 'header and grant differ');
    }
    if (headerLen != TrickplayInfo.headerLengthFor(count)) return (null, 'header length $headerLen');
    if (data.length < headerLen) return (null, 'cut short inside the offsets');
    final offsets = List<int>.generate(count + 1, (i) => b.getUint32(24 + 4 * i));
    if (offsets.first != headerLen) return (null, 'first offset not at the header end');
    for (var i = 0; i < count; i++) {
      if (offsets[i + 1] <= offsets[i]) return (null, 'offsets out of order');
    }
    if (offsets.last != expect.bytes) return (null, 'last offset not at the end');
    return (TrickplayHeader._(List<int>.unmodifiable(offsets)), 'ok');
  }
}

/// A range of the pack, [start, endExclusive), read through the stream
/// proxy (StreamCacheServer.packRange): the bytes, or null.
typedef PackRangeReader = Future<Uint8List?> Function(int start, int endExclusive);

/// One film's pack: its header read once, its pictures read by range and
/// held in memory (an LRU of [cacheBytes]).
class TrickplayPack {
  TrickplayPack(this.info, this._read, {this.cacheBytes = 2 * 1024 * 1024});

  final TrickplayInfo info;
  final PackRangeReader _read;

  /// How many bytes of pictures are held for this film.
  final int cacheBytes;

  /// The first read: the header and every offset of a film up to ~4 h at
  /// 4 s, in one request ([open]).
  static const int firstRead = 16 * 1024;

  /// After this many reads in a row that failed, the pack is not used again
  /// this film: the fragments take over.
  static const int giveUpAfter = 3;

  /// The longest one read may take before it counts as failed: a reader
  /// that never answers must not hold every picture waiting on it.
  static Duration readTimeout = const Duration(seconds: 20);

  TrickplayHeader? _header;
  Future<bool>? _opening;
  String? _broken;
  int _failures = 0;

  /// What the pack's reads cost: requests sent and bytes received.
  int requests = 0;
  int bytesRead = 0;

  /// How long the header took (ms), once read.
  int? headerMs;

  final LinkedHashMap<int, Uint8List> _held = LinkedHashMap<int, Uint8List>();
  int _heldBytes = 0;

  /// Runs of pictures on their way: [from, to] and the read.
  final List<(int, int, Future<void>)> _inFlight = <(int, int, Future<void>)>[];

  /// Why the pack is not used, once it is not (for the trail).
  String? get broken => _broken;

  /// The pack can still be asked: not found wrong, not given up on.
  bool get usable => _broken == null;

  bool get isOpen => _header != null;

  int get heldBytes => _heldBytes;
  int get heldCount => _held.length;

  /// The picture for the film's moment [at]: ⌊at / interval⌋, within
  /// [0, count - 1].
  int indexAt(Duration at) {
    final i = at.inMilliseconds ~/ info.intervalMs;
    return i < 0 ? 0 : (i >= info.count ? info.count - 1 : i);
  }

  /// The film's moment of picture [index], in ms.
  int msOf(int index) => index * info.intervalMs;

  /// The header, read and checked once. False when the pack is not to be
  /// used (cut short, foreign, not the grant's) — then never again — or
  /// when the read failed.
  Future<bool> open() {
    if (_header != null) return Future<bool>.value(true);
    if (_broken != null) return Future<bool>.value(false);
    return _opening ??= () async {
      try {
        final clock = Stopwatch()..start();
        final want = info.headerLength > firstRead ? info.headerLength : firstRead;
        final end = want < info.bytes ? want : info.bytes;
        final data = await _range(0, end);
        if (data == null) return false;
        final (h, why) = TrickplayHeader.parse(data, info);
        if (h == null) {
          _broken = why;
          return false;
        }
        _header = h;
        headerMs = clock.elapsedMilliseconds;
        return true;
      } finally {
        _opening = null;
      }
    }();
  }

  /// A picture already held, or null. Marks it the most recent.
  Uint8List? held(int index) {
    final p = _held.remove(index);
    if (p != null) _held[index] = p;
    return p;
  }

  /// The held picture nearest [index], within [within] pictures.
  (int, Uint8List)? nearestHeld(int index, int within) {
    int? best;
    for (final k in _held.keys) {
      final d = (k - index).abs();
      if (d > within) continue;
      if (best == null || d < (best - index).abs()) best = k;
    }
    return best == null ? null : (best, _held[best]!);
  }

  /// The picture of the film at [at]: from memory, from a run on its way,
  /// or one range request. Null when it cannot be had.
  Future<Uint8List?> pictureAt(Duration at) => picture(indexAt(at));

  Future<Uint8List?> picture(int index) async {
    final have = held(index);
    if (have != null) return have;
    if (!await open()) return null;
    for (final (a, b, f) in List<(int, int, Future<void>)>.of(_inFlight)) {
      if (index >= a && index <= b) {
        await f;
        final got = held(index);
        if (got != null) return got;
      }
    }
    await _run(index, index);
    return held(index);
  }

  /// The pictures [from]..[to] (clamped to the film) in ONE request, into
  /// memory; those at either end already held are not asked for again.
  /// How many came in.
  Future<int> takeRun(int from, int to) async {
    if (!await open()) return 0;
    var a = from < 0 ? 0 : from;
    var b = to >= info.count ? info.count - 1 : to;
    while (a <= b && _held.containsKey(a)) {
      a++;
    }
    while (b >= a && _held.containsKey(b)) {
      b--;
    }
    if (a > b) return 0;
    return _run(a, b);
  }

  /// Pictures [a]..[b] in one request; a run asked for while it is on its
  /// way is waited for, not asked again ([picture]).
  Future<int> _run(int a, int b) {
    final work = _readRun(a, b);
    final entry = (a, b, work.then<void>((_) {}, onError: (Object _) {}));
    _inFlight.add(entry);
    return work.whenComplete(() => _inFlight.remove(entry)).catchError((Object _) => 0);
  }

  Future<int> _readRun(int a, int b) async {
    final h = _header!;
    final start = h.offsets[a];
    final end = h.offsets[b + 1];
    final data = await _range(start, end);
    if (data == null) return 0;
    var took = 0;
    for (var i = a; i <= b; i++) {
      final pic = Uint8List.sublistView(data, h.offsets[i] - start, h.offsets[i + 1] - start);
      // A whole JPEG or nothing: a picture that is not one is never handed
      // to the seek bar (the fragment's picture is taken instead).
      if (!_looksLikeJpeg(pic)) continue;
      _keep(i, Uint8List.fromList(pic));
      took++;
    }
    return took;
  }

  static bool _looksLikeJpeg(Uint8List p) =>
      p.length > 4 && p[0] == 0xFF && p[1] == 0xD8 && p[2] == 0xFF;

  void _keep(int index, Uint8List pic) {
    final old = _held.remove(index);
    if (old != null) _heldBytes -= old.length;
    _held[index] = pic;
    _heldBytes += pic.length;
    while (_heldBytes > cacheBytes && _held.length > 1) {
      final first = _held.keys.first;
      _heldBytes -= _held.remove(first)!.length;
    }
  }

  Future<Uint8List?> _range(int start, int end) async {
    requests++;
    Uint8List? data;
    try {
      data = await _read(start, end).timeout(readTimeout);
    } catch (_) {
      data = null;
    }
    if (data == null || data.length != end - start) {
      if (++_failures >= giveUpAfter) _broken ??= 'reads failed $_failures times';
      return null;
    }
    _failures = 0;
    bytesRead += data.length;
    return data;
  }

  /// Nothing held any more.
  void clear() {
    _held.clear();
    _heldBytes = 0;
  }
}

/// What the seek bar takes ahead of the finger when the controls come up.
enum PreviewAhead {
  /// Nothing: the data saver is on and the pack is there — only the
  /// picture under the finger is read.
  none,

  /// The pack's pictures either side of the moment, in one request.
  packRun,

  /// The fragments beside the moment, one by one (a film without a pack,
  /// as before the pack existed).
  fragments,
}

/// Where the seek bar's picture comes from — the pack when there is one
/// that can be used, else the fragments — decided here, once, for
/// MediaKitPlayerService (which cannot be built in a test).
class SeekPreviewSource {
  SeekPreviewSource._();

  /// The picture of [at]: the pack's when it gives one; else, SILENTLY, the
  /// fragment's ([fragment]) — a pack missing, given up on, or a read that
  /// failed is the seek bar as it was. The picture and where it came from
  /// (`pack`, `fragment`, or null when neither gave one).
  static Future<(Uint8List?, String?)> picture(
      TrickplayPack? pack, Duration at, Future<Uint8List?> Function() fragment) async {
    if (pack != null && pack.usable) {
      final p = await pack.pictureAt(at);
      if (p != null) return (p, 'pack');
    }
    final f = await fragment();
    return (f, f == null ? null : 'fragment');
  }

  /// What to take ahead: with a usable pack, its run — or nothing with the
  /// data saver on; without one, the fragments as before (the data saver
  /// does not change a film without a pack).
  static PreviewAhead ahead({required TrickplayPack? pack, required bool saving}) {
    if (pack == null || !pack.usable) return PreviewAhead.fragments;
    return saving ? PreviewAhead.none : PreviewAhead.packRun;
  }

  /// The run around [at]: [reachMs] either side (40 s: some 20 pictures at
  /// 4 s), as picture indexes.
  static (int, int) runAround(TrickplayPack pack, Duration at, {int reachMs = 40000}) {
    final i = pack.indexAt(at);
    final span = reachMs ~/ pack.info.intervalMs;
    final s = span < 1 ? 1 : span;
    return (i - s, i + s);
  }
}
