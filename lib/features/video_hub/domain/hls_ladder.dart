import 'dart:math';

import 'package:flutter/foundation.dart';

import 'cmaf_index.dart';

/// The streaming ladder as HLS: a master playlist naming every rung, and a
/// media playlist per rung that points into the rung's ONE file by byte
/// range — no re-encode, no new files, nothing uploaded.
///
/// WHY HLS NOW. A change of quality used to reopen the film on another
/// rung: libmpv cannot switch rungs inside one stream (its HLS demuxer
/// cannot seek in fragmented MP4, FFmpeg ticket #7359), so the picture
/// stopped while the new copy opened — 4 to 7 s on the real phones of Test
/// Lab run 39972176423, and a step down only after the film had already
/// stalled. Media3's ExoPlayer — the player YouTube's Android app is built
/// on — plays these same files as HLS and changes rung at a segment
/// boundary while the picture keeps moving, and drops a rung BEFORE the
/// buffer runs dry rather than after. docs/streaming_pro_plan.md.
///
/// THE FILES ALREADY ALLOW IT (`tool/transcode.sh`): every rung is one CMAF
/// file — `ftyp`, a 1 KB `moov`, a `sidx`, then a `moof`+`mdat` per
/// keyframe — and every rung has a keyframe every two seconds on the same
/// clock (`-g` fixed, `-sc_threshold 0`). So fragment N of every rung covers
/// the same two seconds of film, and a switch lands on a keyframe on both
/// sides.
///
/// PURE: bytes and numbers in, text out. The proxy serves it
/// (`StreamCacheServer`), tests read it.

/// What the head of a rung's file says about it beyond the fragment table:
/// where the init segment (`ftyp`+`moov`) ends, and the picture's codec and
/// size, for the master playlist.
@immutable
class CmafHead {
  const CmafHead({
    required this.initEnd,
    this.videoCodec,
    this.width,
    this.height,
    this.hasAudio = true,
  });

  /// One past the last byte of the `moov`: the init segment is `0..initEnd-1`.
  final int initEnd;

  /// `avc1.PPCCLL`, from the `avcC`; null when the picture is not H.264 or
  /// the box could not be read.
  final String? videoCodec;
  final int? width;
  final int? height;
  final bool hasAudio;

  /// Reads [head] — the file from byte 0 at least to the end of its `moov`.
  /// Null when that is not there or not a fragmented film's head.
  static CmafHead? parse(Uint8List head) {
    try {
      final top = _Boxes(head, 0, head.length);
      var sawFtyp = false;
      for (final b in top) {
        if (!sawFtyp) {
          if (b.kind != 'ftyp') return null;
          sawFtyp = true;
          continue;
        }
        if (b.kind == 'mdat') return null; // a plain MP4
        if (b.kind != 'moov') continue;
        if (b.end > head.length) return null;
        String? codec;
        int? w, h;
        var audio = false;
        for (final trak in _Boxes(head, b.body, b.end).where((x) => x.kind == 'trak')) {
          final mdia = _child(head, trak, 'mdia');
          if (mdia == null) continue;
          final hdlr = _child(head, mdia, 'hdlr');
          final handler = hdlr == null || hdlr.body + 12 > hdlr.end
              ? ''
              : String.fromCharCodes(head.sublist(hdlr.body + 8, hdlr.body + 12));
          if (handler == 'soun') {
            audio = true;
            continue;
          }
          if (handler != 'vide') continue;
          final stsd = _path(head, mdia, const ['minf', 'stbl', 'stsd']);
          if (stsd == null) continue;
          // stsd: version+flags, entry count, then the sample entries.
          final entry = _Boxes(head, stsd.body + 8, stsd.end).firstOrNull;
          if (entry == null || entry.kind != 'avc1' && entry.kind != 'avc3') {
            continue;
          }
          final view = ByteData.sublistView(head);
          // VisualSampleEntry: 6 reserved, 2 data_reference_index, 16
          // pre-defined/reserved, then width and height.
          if (entry.body + 28 <= entry.end) {
            w = view.getUint16(entry.body + 24);
            h = view.getUint16(entry.body + 26);
          }
          // Its own boxes follow its 78 bytes of fields.
          for (final c in _Boxes(head, entry.body + 78, entry.end)) {
            if (c.kind == 'avcC' && c.body + 4 <= c.end) {
              String hex(int v) => v.toRadixString(16).padLeft(2, '0');
              codec = '${entry.kind}.${hex(head[c.body + 1])}'
                  '${hex(head[c.body + 2])}${hex(head[c.body + 3])}';
            }
          }
        }
        return CmafHead(
          initEnd: b.end,
          videoCodec: codec,
          width: w,
          height: h,
          hasAudio: audio,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static _Box? _child(Uint8List b, _Box parent, String kind) =>
      _Boxes(b, parent.body, parent.end).where((x) => x.kind == kind).firstOrNull;

  static _Box? _path(Uint8List b, _Box from, List<String> kinds) {
    _Box? at = from;
    for (final k in kinds) {
      if (at == null) return null;
      at = _child(b, at, k);
    }
    return at;
  }
}

/// One rung, as the master and its media playlist need it.
@immutable
class HlsRung {
  const HlsRung({
    required this.height,
    required this.kbps,
    required this.url,
    this.index,
    this.head,
  });

  final int height;

  /// The rung's average rate, as the grant lists it.
  final int kbps;

  /// Where its bytes are: the proxy's address for this rung's file.
  final String url;

  /// Its fragment table and head, once read; the master is written without
  /// them (from the grant's numbers), a media playlist needs both.
  final CmafIndex? index;
  final CmafHead? head;
}

/// What the master writes as a rung's BANDWIDTH — the number ExoPlayer's
/// Auto weighs it by (a rung fits a line when this is under 70 % of it).
enum PeakRule {
  /// The fastest single fragment (two seconds), as HLS defines BANDWIDTH;
  /// a rung whose index is not read yet at 1.25 × its average.
  fragment,

  /// The fastest [HlsLadder.peakWindowMs] of film; a rung not read yet at
  /// its average times what a read rung's peak is to its own average.
  ///
  /// THE RULE SINCE 8 NOV 2026, by 32 passes of the device lab's weak line
  /// (runs 42445022401, 42450352466, 42455719742; docs/
  /// streaming_review_2026_11.md §5): against [fragment] it kept 480p 89 %
  /// of the time to 69 %, led 12 pairs of 14, and had no stop where
  /// [fragment] had one. Weighing a deep buffer against the whole line
  /// as well (`deep`, ff10144) was tried and dropped: 720p in and out,
  /// 64 %.
  window,
}

class HlsLadder {
  HlsLadder._();

  /// The span [PeakRule.window] weighs a rung over.
  ///
  /// WHY NOT ONE FRAGMENT (BACKLOG 5b, run 42384151800). With up to a
  /// minute of film in hand — and Auto never climbing on less than ten
  /// seconds of it — what has to keep up is the line over tens of seconds,
  /// not over the fastest two: one busy fragment is carried by the buffer.
  /// The fastest fragment made 480p of Sintel 1.74 × its average (1591 of
  /// 912 kbps), so it needed a 2.3 Mbit/s line, where one connection on the
  /// lab's lossy line carries 1.5-2.2. And a rung not read yet was weighed at
  /// 1.25 × its average, so 720p looked cheaper than a rung that was read.
  /// x264's `-maxrate k -bufsize 2k` (tool/transcode.sh) bounds any 20 s
  /// at 1.1 × the cap, any 2 s at 2 ×.
  static const int peakWindowMs = 20000;

  /// Sound in every rung is AAC-LC (`-c:a aac`), so this is a fact, not a
  /// guess.
  static const String audioCodec = 'mp4a.40.2';

  /// The picture's codec when its `avcC` has not been read yet: High
  /// profile (`-profile:v high`) at the level x264 picks for the size.
  /// A level a little high only makes a weak phone's decoder check
  /// stricter; the master is rewritten with the real one once read.
  static String fallbackVideoCodec(int height) => height <= 360
      ? 'avc1.64001e'
      : height <= 720
          ? 'avc1.64001f'
          : height <= 1080
              ? 'avc1.640028'
              : 'avc1.640033';

  /// The master playlist: every rung, best first — except [first], the rung
  /// the player opens with, which leads. [mediaUri] names a rung's media
  /// playlist; [aspect] (width / height, from any rung read) gives each
  /// rung its RESOLUTION.
  ///
  /// THE START RUNG LEADS (7 Nov 2026). ExoPlayer reads the FIRST variant's
  /// playlist before it can start (its primary playlist; Apple's players
  /// start on the first listed), and a rung's playlist needs its index read
  /// from the Worker. Best first, a 480p start waited for 720p's index too:
  /// one more round trip on a weak line, in the 4.6 s between the first
  /// frame and play in the device lab (run 42367973983). Auto still chooses
  /// among all of them; their order is not a preference.
  ///
  /// EVERY RUNG HAS A RESOLUTION, with 16:9 when nothing better is known:
  /// the player tells rungs apart by their height, and a master without
  /// one left every rung's height unknown — a pick of 240p then played the
  /// best rung (device-lab run 40079651806).
  static String master(
    List<HlsRung> rungs, {
    required String Function(HlsRung rung) mediaUri,
    double? aspect,
    double? frameRate,
    int? first,
    PeakRule rule = PeakRule.window,
  }) {
    final sorted = [...rungs]..sort((a, b) => b.height.compareTo(a.height));
    final lead = sorted.indexWhere((r) => r.height == first);
    if (lead > 0) sorted.insert(0, sorted.removeAt(lead));
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-INDEPENDENT-SEGMENTS');
    for (final r in sorted) {
      final avg = max(1, r.kbps) * 1000;
      final peak = weighed(r, rungs, rule);
      final codecs = [
        r.head?.videoCodec ?? fallbackVideoCodec(r.height),
        if (r.head?.hasAudio ?? true) audioCodec,
      ].join(',');
      final attrs = <String>[
        'BANDWIDTH=$peak',
        'AVERAGE-BANDWIDTH=$avg',
        'CODECS="$codecs"',
      ];
      // A rung's height is the picture's height (`scale=-2:<h>` in
      // tool/transcode.sh), portrait or not.
      final w = r.head?.width ?? _even(r.height * (aspect ?? 16 / 9));
      final h = r.head?.height ?? r.height;
      attrs.add('RESOLUTION=${w}x$h');
      if (frameRate != null && frameRate > 0) {
        attrs.add('FRAME-RATE=${frameRate.toStringAsFixed(3)}');
      }
      out
        ..writeln('#EXT-X-STREAM-INF:${attrs.join(',')}')
        ..writeln(mediaUri(r));
    }
    return out.toString();
  }

  /// The media playlist of one rung: its init segment and every fragment,
  /// by byte range of its one file. Null until its index and head are read.
  static String? media(HlsRung rung) {
    final idx = rung.index;
    final head = rung.head;
    if (idx == null || head == null || idx.length == 0) return null;
    var longest = 0;
    for (var i = 0; i < idx.length; i++) {
      longest = max(longest, idx.timesMs[i + 1] - idx.timesMs[i]);
    }
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-TARGETDURATION:${(longest / 1000).ceil()}')
      ..writeln('#EXT-X-MEDIA-SEQUENCE:0')
      ..writeln('#EXT-X-PLAYLIST-TYPE:VOD')
      ..writeln('#EXT-X-INDEPENDENT-SEGMENTS')
      ..writeln('#EXT-X-MAP:URI="${rung.url}",BYTERANGE="${head.initEnd}@0"');
    for (var i = 0; i < idx.length; i++) {
      final ms = idx.timesMs[i + 1] - idx.timesMs[i];
      out
        ..writeln('#EXTINF:${(ms / 1000).toStringAsFixed(3)},')
        ..writeln('#EXT-X-BYTERANGE:${idx.sizes[i]}@${idx.starts[i]}')
        ..writeln(rung.url);
    }
    out.writeln('#EXT-X-ENDLIST');
    return out.toString();
  }

  /// The highest rate any one fragment needs, in bits a second: what HLS
  /// calls BANDWIDTH, and what a line must carry for the rung never to wait.
  static int peakBps(CmafIndex idx) {
    var peak = 0;
    for (var i = 0; i < idx.length; i++) {
      final ms = idx.timesMs[i + 1] - idx.timesMs[i];
      if (ms <= 0) continue;
      peak = max(peak, idx.sizes[i] * 8000 ~/ ms);
    }
    return peak;
  }

  /// The highest rate any [windowMs] of film needs, in bits a second: the
  /// fragments from each one on until they cover the window. A film shorter
  /// than the window is weighed whole; [windowMs] ≤ 0 is one fragment.
  static int windowPeakBps(CmafIndex idx, int windowMs) {
    if (windowMs <= 0) return peakBps(idx);
    var peak = 0;
    var j = 0;
    var bytes = 0; // fragments i .. j-1
    for (var i = 0; i < idx.length; i++) {
      while (j < idx.length && idx.timesMs[j] - idx.timesMs[i] < windowMs) {
        bytes += idx.sizes[j];
        j++;
      }
      final span = idx.timesMs[j] - idx.timesMs[i];
      // The last windows run short of the film's end: the window that
      // starts earlier and reaches it has already been weighed.
      if (span > 0 && (span >= windowMs || i == 0)) {
        peak = max(peak, bytes * 8000 ~/ span);
      }
      bytes -= idx.sizes[i];
    }
    return peak;
  }

  /// The rung's average from its own fragments, in bits a second.
  static int averageBps(CmafIndex idx) {
    if (idx.length == 0) return 0;
    final ms = idx.timesMs.last - idx.timesMs.first;
    if (ms <= 0) return 0;
    var bytes = 0;
    for (final s in idx.sizes) {
      bytes += s;
    }
    return bytes * 8000 ~/ ms;
  }

  /// The BANDWIDTH [r] is written with under [rule], never under its
  /// average; [all] is the ladder, whose read rungs stand in for one not read.
  static int weighed(HlsRung r, List<HlsRung> all, PeakRule rule) {
    final avg = max(1, r.kbps) * 1000;
    switch (rule) {
      case PeakRule.fragment:
        return r.index == null ? (avg * 1.25).round() : max(avg, peakBps(r.index!));
      case PeakRule.window:
        final idx = r.index;
        if (idx != null && idx.length > 0) return max(avg, windowPeakBps(idx, peakWindowMs));
        // Not read: the nearest read rung's peak over its average. The rungs
        // are one encode of one film under the same cap rule, so how far a
        // busy stretch rises over the average is close from rung to rung.
        HlsRung? near;
        for (final o in all) {
          if (o.index == null || o.index!.length == 0 || o.kbps <= 0) continue;
          if (near == null || (o.height - r.height).abs() < (near.height - r.height).abs()) {
            near = o;
          }
        }
        if (near == null) return (avg * 1.25).round();
        final ratio = windowPeakBps(near.index!, peakWindowMs) / (near.kbps * 1000);
        return (avg * ratio.clamp(1.0, 2.0)).round();
    }
  }

  static int _even(double v) {
    final r = v.round();
    return r.isOdd ? r + 1 : r;
  }
}

class _Box {
  _Box(this.kind, this.start, this.size, this.headerLen);
  final String kind;
  final int start;
  final int size;
  final int headerLen;
  int get body => start + headerLen;
  int get end => start + size;
}

/// The boxes between [from] and [to] of [b]; a box whose header runs past
/// the end stops the walk, one whose body does is still listed (its `end`
/// says how much more there is).
class _Boxes extends Iterable<_Box> {
  _Boxes(this.b, this.from, this.to);
  final Uint8List b;
  final int from;
  final int to;

  @override
  Iterator<_Box> get iterator {
    final list = <_Box>[];
    final view = ByteData.sublistView(b);
    var at = from;
    while (at + 8 <= to && at + 8 <= b.length) {
      var size = view.getUint32(at);
      var header = 8;
      if (size == 1) {
        if (at + 16 > b.length) break;
        size = view.getUint64(at + 8);
        header = 16;
      } else if (size == 0) {
        size = to - at;
      }
      if (size < header) break;
      list.add(_Box(String.fromCharCodes(b.sublist(at + 4, at + 8)), at, size, header));
      at += size;
    }
    return list.iterator;
  }
}
