import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// One film fetched as several byte ranges at once, handed on IN ORDER.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY MORE THAN ONE CONNECTION
/// ═══════════════════════════════════════════════════════════════════════
///
/// A single TCP connection on a mobile line is held back by the line's loss,
/// not by its capacity: every dropped packet halves that connection's window,
/// and on a cellular link with a long round trip it climbs back slowly. Two or
/// three connections share the line, and a loss on one leaves the others
/// running. This is why Telegram's loader asks for several parts of a large
/// file at once, and why download managers do the same. The bytes fetched
/// are the same bytes — nothing is paid twice for this.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY IN ORDER, AND NOT EACH PART STRAIGHT TO ITS PLACE ON DISK
/// ═══════════════════════════════════════════════════════════════════════
///
/// Everything downstream relies on the part file being a PREFIX of the film:
/// resume asks for the bytes from its length onwards, the cipher seals by
/// offset as it appends, and watch-while-downloading plays up to its length.
/// A file with holes would break all three. So parts finish in any order but
/// are released in order — a part that finishes early waits in memory for the
/// one before it — and the consumer sees exactly what one long response would
/// have given it. At most [lanes] parts are held, a few megabytes.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE HEAD
/// ═══════════════════════════════════════════════════════════════════════
///
/// The download has already opened one open-ended response — it needed its
/// headers for the size, the resume check and the "this is 1.8 GB" question.
/// Its bytes are used for the first part and passed on as they arrive, while
/// the other lanes start on the parts after it. When the head reaches the
/// first of those, it is closed. What was in flight on it at that moment is
/// the only cost of this: once per pass, a fraction of a megabyte.
///
/// Any failure — a dropped lane, a short part, a server that answers a range
/// with something else — ends the stream with an error. The downloader's own
/// resume loop is what handles that, from the last byte released, exactly as
/// it handles a dropped single connection.
class RangedFetch {
  RangedFetch._();

  /// The size of one part. Large enough that the round trip that starts each
  /// one is a small share of its time; small enough that a part held waiting
  /// for the one before it is not much memory.
  static const int defaultPartBytes = 2 * 1024 * 1024;

  /// Connections at once, the head included. Three takes most of the gain;
  /// past that a phone's line is shared more finely for little more speed.
  ///
  /// Each part is its own request through the stream Worker, which checks the
  /// link every time: a gigabyte is about five hundred of them, far inside
  /// the Worker's allowance. And a link expires after ten minutes — a part
  /// asked for after that is refused, the pass ends, and the downloader
  /// renews it exactly as it does for a dropped connection.
  static const int defaultLanes = 3;

  /// How long a connection may go without a single byte before it is taken
  /// for dead. See [OfflineDownloader] — a mobile link that dies silently
  /// (a cell handover, Wi-Fi to data) leaves a socket that never errors, and
  /// without this a download would sit at the same percentage for ever.
  static const Duration defaultStallAfter = Duration(seconds: 30);

  /// Whether a download of [remaining] bytes is worth splitting at all.
  static bool worthSplitting(int remaining, {int partBytes = defaultPartBytes}) =>
      remaining >= partBytes * 4;

  /// Whether a response says its server will answer byte ranges: a 206 is the
  /// proof; a 200 may say so in `Accept-Ranges`.
  static bool acceptsRanges(http.BaseResponse r) {
    if (r.statusCode == 206) return true;
    final h = r.headers['accept-ranges'];
    return h != null && h.toLowerCase().contains('bytes');
  }

  /// The bytes of [url] from [start] to [total], in order.
  ///
  /// [head] is an already-open response body starting at [start].
  ///
  /// WHEN [narrow] TURNS TRUE — the viewer has started streaming something —
  /// no new part is asked for. The parts already on their way are let finish
  /// (abandoning them would pay for their bytes twice) and handed on, and
  /// then the stream ENDS, cleanly and short of [total]. The downloader takes
  /// a short clean end as "carry on from here" and opens its next pass as a
  /// single paced connection — which, unlike parts held in memory, a slow
  /// reader genuinely slows down.
  static Stream<List<int>> ordered({
    required http.Client client,
    required Uri url,
    required Stream<List<int>> head,
    required int start,
    required int total,
    int partBytes = defaultPartBytes,
    int lanes = defaultLanes,
    bool Function()? narrow,
    Duration stallAfter = defaultStallAfter,
  }) async* {
    final stop = Completer<void>();
    final queue = <_Part>[];
    final headEnd = start + partBytes < total ? start + partBytes : total;
    var next = headEnd;
    var headOpen = true;
    var failed = false;

    // Connections at once. While the head is still open it is one of them.
    int width() => headOpen ? lanes - 1 : lanes;

    // HOW FAR AHEAD. A lane that finishes its part while an earlier one is
    // still coming starts the next part rather than idling — one slow lane
    // must not hold the others up — but only so far: [window] parts held at
    // most, a few megabytes.
    final window = lanes * 2;

    void topUp() {
      if (stop.isCompleted || failed || (narrow?.call() ?? false)) return;
      while (next < total &&
          queue.length < window &&
          queue.where((p) => !p.settled).length < width()) {
        final end = next + partBytes < total ? next + partBytes : total;
        queue.add(_Part.fetch(client, url, next, end, total, stop.future,
            stallAfter: stallAfter, onSettled: (ok) {
          // One part refused (an expired link, a dropped lane): the rest
          // would be refused too. Stop asking; what came back is still used.
          if (!ok) failed = true;
          topUp();
        }));
        next = end;
      }
    }

    try {
      topUp();

      // The head, passed straight through until it reaches the first lane's
      // territory.
      var at = start;
      final it = StreamIterator<List<int>>(head.timeout(stallAfter));
      try {
        while (at < headEnd && await it.moveNext()) {
          final chunk = it.current;
          final room = headEnd - at;
          if (chunk.length <= room) {
            at += chunk.length;
            yield chunk;
          } else {
            at += room;
            yield chunk is Uint8List
                ? Uint8List.sublistView(chunk, 0, room)
                : chunk.sublist(0, room);
          }
        }
      } finally {
        await it.cancel();
      }
      headOpen = false;
      if (at < headEnd) {
        throw RangedFetchException('the first part ended at $at of $headEnd');
      }

      topUp();
      while (queue.isNotEmpty) {
        final bytes = await queue.first.bytes;
        queue.removeAt(0);
        topUp();
        yield bytes;
      }
    } finally {
      if (!stop.isCompleted) stop.complete();
      // Lanes still running are aborted by `stop`; their errors are expected
      // and are nobody's to handle.
      for (final p in queue) {
        unawaited(p.bytes.then((_) {}, onError: (_) {}));
      }
    }
  }
}

/// A part did not come back as asked — short, the wrong range, or no range at
/// all. [refused] is the last: the server will not do ranges, and asking it
/// again would cost the same again.
class RangedFetchException implements Exception {
  RangedFetchException(this.message, {this.refused = false});
  final String message;
  final bool refused;
  @override
  String toString() => 'RangedFetchException: $message';
}

class _Part {
  _Part(this.bytes);
  final Future<Uint8List> bytes;
  bool settled = false;

  factory _Part.fetch(
    http.Client client,
    Uri url,
    int start,
    int end, // exclusive
    int total,
    Future<void> stop, {
    required Duration stallAfter,
    required void Function(bool ok) onSettled,
  }) {
    final f = _get(client, url, start, end, total, stop, stallAfter);
    final part = _Part(f);
    // Held until its turn; an error before then must not count as unhandled.
    f.then((_) {
      part.settled = true;
      onSettled(true);
    }, onError: (_) {
      part.settled = true;
      onSettled(false);
    });
    return part;
  }

  static Future<Uint8List> _get(
    http.Client client,
    Uri url,
    int start,
    int end,
    int total,
    Future<void> stop,
    Duration stallAfter,
  ) async {
    final want = end - start;
    // Aborted when the whole fetch stops, or when this part goes quiet.
    final abort = Completer<void>();
    unawaited(stop.then((_) {
      if (!abort.isCompleted) abort.complete();
    }));
    final req = http.AbortableRequest('GET', url, abortTrigger: abort.future)
      ..headers['Range'] = 'bytes=$start-${end - 1}';
    final http.StreamedResponse res;
    try {
      res = await client.send(req).timeout(stallAfter);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      rethrow;
    }
    if (res.statusCode != 206) {
      unawaited(res.stream.listen(null).cancel());
      throw RangedFetchException('HTTP ${res.statusCode} for a range',
          refused: res.statusCode == 200);
    }
    final range = parseContentRange(res.headers['content-range']);
    if (range != null &&
        (range.start != start || range.end != end - 1 ||
            (range.total != null && range.total != total))) {
      unawaited(res.stream.listen(null).cancel());
      throw RangedFetchException('asked for $start-${end - 1}/$total, '
          'got ${res.headers['content-range']}');
    }
    final out = BytesBuilder(copy: false);
    await for (final chunk in res.stream.timeout(stallAfter)) {
      out.add(chunk);
      if (out.length > want) break;
    }
    if (out.length != want) {
      throw RangedFetchException('part $start: ${out.length} of $want bytes');
    }
    return out.takeBytes();
  }
}

/// `bytes 200-1023/146515` → (200, 1023, 146515). The total may be `*`.
({int start, int end, int? total})? parseContentRange(String? header) {
  if (header == null) return null;
  final m = RegExp(r'^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$').firstMatch(header);
  if (m == null) return null;
  return (
    start: int.parse(m.group(1)!),
    end: int.parse(m.group(2)!),
    total: m.group(3) == '*' ? null : int.parse(m.group(3)!),
  );
}
