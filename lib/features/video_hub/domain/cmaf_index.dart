import 'dart:math';

import 'package:flutter/foundation.dart';

/// Where each two-second fragment of a streaming rung sits, read from the
/// `sidx` at its front.
///
/// WHY THE PHONE NEEDS TO KNOW. A rung switch reopens the film on another
/// copy at the same moment (libmpv cannot change rung inside one stream:
/// its HLS demuxer cannot seek in fragmented-MP4 playlists at all, FFmpeg
/// ticket #7359, and a rung switch is a seek). Reopened cold, the new copy's
/// first picture waits for its bytes to cross the network — 1.8 s of frozen
/// picture at 6 Mbit, 3 s at 3.5 Mbit, measured. Fetched first, while the
/// old copy plays on, the same reopen waits only for the decoder: 0.1 to
/// 0.2 s. To fetch "the next ten seconds of the 720p copy from 41:12", the
/// phone has to turn a moment into bytes, and the `sidx` is exactly that
/// table.
///
/// THE LADDER'S LAYOUT (`tool/transcode.sh`): `ftyp`, a 1 KB `moov`, one
/// `sidx` per track, then the film as `moof`+`mdat` pairs, one per keyframe,
/// every two seconds. Sound and picture share each fragment, so the first
/// `sidx` — the picture's — locates both.
///
/// PURE: bytes in, a table out, so every edge is a unit test rather than a
/// device run. Null for anything that is not that layout (an Original, a
/// faststart MP4): the caller then reopens exactly as before.
@immutable
class CmafIndex {
  const CmafIndex._(this.starts, this.sizes, this.timesMs);

  /// Byte offset of each fragment's `moof`.
  final List<int> starts;

  /// Bytes in each fragment, `moof` and `mdat` together.
  final List<int> sizes;

  /// When each fragment starts, in ms of film; one more entry than there are
  /// fragments, the last being where the film ends.
  final List<int> timesMs;

  int get length => starts.length;

  /// How many bytes from the start of the file [parse] needs: where the first
  /// `moof` begins, once [head] reaches it. While a box runs past the end of
  /// [head], a number larger than `head.length` — read that much and ask
  /// again (an index grows about 50 KB an hour per track). Null when the
  /// file is not laid out as above.
  static int? headBytes(Uint8List head) => _walk(head)?.$1;

  /// The fragment table, or null when [head] is not a complete CMAF head.
  static CmafIndex? parse(Uint8List head) {
    final walk = _walk(head);
    if (walk == null) return null;
    final (need, sidxAt) = walk;
    if (sidxAt < 0 || need > head.length) return null;
    try {
      return _sidx(head, sidxAt);
    } catch (_) {
      return null;
    }
  }

  /// The fragment holding the moment [at]. Half a second early, so a seek
  /// that lands just past a boundary still finds its keyframe in the bytes
  /// fetched: the film's first frame is presented a few frames after
  /// decoding starts, so its clock and the table's differ by that much.
  int fragmentAt(Duration at) {
    final ms = max(0, at.inMilliseconds - 500);
    var lo = 0, hi = length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (timesMs[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// The bytes (inclusive range) to fetch so that a reopen at [at] can play
  /// [lead] of film without the network: from the fragment holding [at]
  /// through the one that reaches [at] + [lead], never more than [capBytes].
  /// Null past the end of the film.
  (int, int, Duration)? rangeFor(Duration at, Duration lead, {required int capBytes}) {
    if (length == 0 || at.inMilliseconds >= timesMs.last) return null;
    final first = fragmentAt(at);
    final until = at.inMilliseconds + lead.inMilliseconds;
    var last = first;
    var bytes = sizes[first];
    while (last + 1 < length &&
        timesMs[last + 1] < until &&
        bytes + sizes[last + 1] <= capBytes) {
      last++;
      bytes += sizes[last];
    }
    final film = Duration(milliseconds: timesMs[last + 1] - timesMs[first]);
    return (starts[first], starts[last] + sizes[last] - 1, film);
  }

  /// The top-level boxes before the first `moof`: `(where it starts, offset
  /// of the first sidx or -1)` — or, while [head] stops short of it, `(bytes
  /// to read, -1 or the sidx)` with the first larger than `head.length`.
  static (int, int)? _walk(Uint8List head) {
    if (head.length < 16) return null;
    final view = ByteData.sublistView(head);
    var at = 0;
    var sawMoov = false;
    var sidxAt = -1;
    for (var i = 0; i < 64; i++) {
      // The next box's header is not here yet: read up to and including it.
      if (at + 16 > head.length) return (at + 16, sidxAt);
      var size = view.getUint32(at);
      final kind = String.fromCharCodes(head.sublist(at + 4, at + 8));
      if (size == 1) size = view.getUint64(at + 8);
      if (size < 8) return null;
      if (i == 0 && kind != 'ftyp') return null;
      if (kind == 'moof') return sawMoov && sidxAt >= 0 ? (at, sidxAt) : null;
      if (kind == 'mdat') return null; // a plain MP4: no fragments
      if (kind == 'moov') sawMoov = true;
      if (kind == 'sidx' && sidxAt < 0) sidxAt = at;
      at += size;
    }
    return null;
  }

  static CmafIndex? _sidx(Uint8List b, int at) {
    final view = ByteData.sublistView(b);
    final size = view.getUint32(at);
    final boxEnd = at + size;
    var p = at + 8;
    final version = b[p];
    p += 4; // version + flags
    p += 4; // reference_ID
    final timescale = view.getUint32(p);
    p += 4;
    if (timescale == 0) return null;
    int ept, firstOffset;
    if (version == 0) {
      ept = view.getUint32(p);
      firstOffset = view.getUint32(p + 4);
      p += 8;
    } else {
      ept = view.getUint64(p);
      firstOffset = view.getUint64(p + 8);
      p += 16;
    }
    p += 2; // reserved
    final count = view.getUint16(p);
    p += 2;
    if (count == 0 || p + count * 12 > boxEnd) return null;
    final starts = <int>[];
    final sizes = <int>[];
    final times = <int>[];
    var offset = boxEnd + firstOffset;
    var t = ept;
    for (var i = 0; i < count; i++) {
      final word = view.getUint32(p);
      final duration = view.getUint32(p + 4);
      p += 12;
      if (word >> 31 != 0) return null; // points at another sidx, not film
      final n = word & 0x7fffffff;
      if (n == 0) return null;
      starts.add(offset);
      sizes.add(n);
      times.add((t - ept) * 1000 ~/ timescale);
      offset += n;
      t += duration;
    }
    times.add((t - ept) * 1000 ~/ timescale);
    return CmafIndex._(
      List<int>.unmodifiable(starts),
      List<int>.unmodifiable(sizes),
      List<int>.unmodifiable(times),
    );
  }
}
