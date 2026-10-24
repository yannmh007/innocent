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

class HlsLadder {
  HlsLadder._();

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

  /// The master playlist: every rung, best first. [mediaUri] names a
  /// rung's media playlist; [aspect] (width / height, from any rung read)
  /// gives each rung its RESOLUTION, which the player weighs against the
  /// screen it is drawn on.
  static String master(
    List<HlsRung> rungs, {
    required String Function(HlsRung rung) mediaUri,
    double? aspect,
    double? frameRate,
  }) {
    final sorted = [...rungs]..sort((a, b) => b.height.compareTo(a.height));
    final out = StringBuffer()
      ..writeln('#EXTM3U')
      ..writeln('#EXT-X-VERSION:7')
      ..writeln('#EXT-X-INDEPENDENT-SEGMENTS');
    for (final r in sorted) {
      final avg = max(1, r.kbps) * 1000;
      final peak = r.index == null ? (avg * 1.25).round() : max(avg, peakBps(r.index!));
      final codecs = [
        r.head?.videoCodec ?? fallbackVideoCodec(r.height),
        if (r.head?.hasAudio ?? true) audioCodec,
      ].join(',');
      final attrs = <String>[
        'BANDWIDTH=$peak',
        'AVERAGE-BANDWIDTH=$avg',
        'CODECS="$codecs"',
      ];
      final w = r.head?.width ??
          (aspect == null ? null : _even(r.height * aspect));
      final h = r.head?.height ?? r.height;
      if (w != null) attrs.add('RESOLUTION=${w}x$h');
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
