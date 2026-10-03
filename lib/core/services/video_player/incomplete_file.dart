import 'dart:io';
import 'dart:typed_data';

/// How much of a local video file actually holds the film.
///
/// WHY THIS EXISTS. Download managers — the Bioscope app, browsers, most
/// torrent clients — create the file at its FULL size the moment a download
/// starts and fill it in as bytes arrive. A download that stops part-way
/// leaves a file that is the right size, has a perfectly good header (so the
/// container reports the full running time), and is ZEROS from the point the
/// download stopped to the end.
///
/// Played as it is, the demuxer hands the decoder packets made of zeros. The
/// hardware decoder (MediaCodec) does not fail fast on that: it errors, is
/// re-opened ("Could not open codec."), and on many phones gets stuck inside
/// the codec. libmpv runs that on its core thread, every synchronous libmpv
/// call from the UI thread then waits for it, and Android reports the app as
/// not responding. The stuck codec also keeps its hardware slot, so the NEXT
/// video's decoder cannot open either. That is exactly what was reported on
/// 2026-10-02 with a half-downloaded "Inception" from the Bioscope folder.
///
/// The fix is to never play into the zeros: find where the data ends, stop
/// playback there, and say so — the way MX Player treats a partial file.
///
/// THE TEST IS DELIBERATELY NARROW. A finished video never holds 64 KiB of
/// zeros in a row: MKV is cues, tags and clusters, MP4 its index and
/// compressed samples, and compressed data is never a long run of zero bytes.
/// So "a 64 KiB block that is all zeros" is a reliable sign of a hole a
/// download never filled — at the end, or, from a manager that downloads in
/// parallel segments, in the middle. Anything else is treated as complete. A file that is
/// simply SHORT (a download that never preallocated) needs none of this:
/// libmpv reaches a real end of file and stops cleanly.
class IncompleteFile {
  const IncompleteFile({required this.size, required this.dataEnd});

  /// The file's length on disk.
  final int size;

  /// The first byte offset from which the rest of the file is zeros (to
  /// within [IncompleteFileProbe.block]).
  final int dataEnd;

  /// The share of the file that holds data, 0..1.
  double get fraction => size <= 0 ? 0 : dataEnd / size;

  /// The share of the RUNNING TIME that can safely be played, 0..100, as the
  /// percentage libmpv's `end` option takes.
  ///
  /// Bytes are not seconds: a video's bitrate varies along the film, so the
  /// byte share is only an estimate of the time share. Two per cent is held
  /// back for that, which on a two-hour film is under two and a half minutes
  /// — and the decoder never reaches the zeros, which is the whole point.
  double get playablePercent {
    final p = fraction * 100 - _safetyPercent;
    if (p < 0) return 0;
    if (p > 100) return 100;
    return p;
  }

  /// How long can be played of a file [total] long.
  Duration playableOf(Duration total) => Duration(
      milliseconds: (total.inMilliseconds * playablePercent / 100).floor());

  static const double _safetyPercent = 2.0;

  @override
  String toString() =>
      'IncompleteFile(size: $size, dataEnd: $dataEnd, '
      '${(fraction * 100).toStringAsFixed(1)}%)';
}

class IncompleteFileProbe {
  IncompleteFileProbe._();

  /// The granularity of the search. 64 KiB is far longer than any run of
  /// zeros inside real compressed video, and short enough that the search
  /// reads about a megabyte of a two-gigabyte file.
  static const int block = 64 * 1024;

  /// Blocks sampled across the file when looking for a hole.
  static const int samples = 96;

  /// Smaller files are not worth the reads; nobody preallocates a clip.
  static const int minSize = 8 * 1024 * 1024;

  /// Null when the file is complete, unreadable, or not a plain local path.
  ///
  /// Never throws: a probe that fails must leave playback exactly as it was.
  static Future<IncompleteFile?> probe(String pathOrUri) async {
    final path = localPathOf(pathOrUri);
    if (path == null) return null;
    RandomAccessFile? raf;
    try {
      final file = File(path);
      final size = await file.length();
      if (size < minSize) return null;
      raf = await file.open();
      final blocks = (size + block - 1) ~/ block;

      Future<bool> zeroAt(int index) async {
        final start = index * block;
        final len = (start + block > size) ? size - start : block;
        await raf!.setPosition(start);
        final bytes = await raf.read(len);
        return isAllZero(bytes);
      }

      // A file that is zeros from the very start is not a film at all; leave
      // it to libmpv to say so.
      if (await zeroAt(0)) return null;

      // SAMPLED ACROSS THE WHOLE FILE, not only at its end. A download
      // manager that fetches in parallel segments leaves an unfinished file
      // with zero-filled HOLES in the middle and real data after them — the
      // end can look complete while 1:10:00 to 1:25:00 was never fetched.
      // Diagnostics from 2026-10-03 show exactly that: a flood of audio
      // decode errors part-way through a file the end-only check had passed.
      // [samples] blocks spread evenly (the first and last included) find
      // any hole wider than the spacing — on a 1.6 GB film about 17 MB, far
      // smaller than the segments those managers use — for ~6 MB read.
      final n = blocks < samples ? blocks : samples;
      var prevData = 0;
      int? firstZero;
      for (var i = 1; i < n; i++) {
        final idx = (i * (blocks - 1)) ~/ (n - 1);
        if (idx <= prevData) continue;
        if (await zeroAt(idx)) {
          firstZero = idx;
          break;
        }
        prevData = idx;
      }
      if (firstZero == null) return null;

      // Binary search for the boundary. Invariant: block [lo] holds data,
      // block [hi] is zeros.
      var lo = prevData;
      var hi = firstZero;
      while (hi - lo > 1) {
        final mid = lo + (hi - lo) ~/ 2;
        if (await zeroAt(mid)) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      final dataEnd = (lo + 1) * block;
      return IncompleteFile(size: size, dataEnd: dataEnd > size ? size : dataEnd);
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// A plain filesystem path from what the player is handed, or null for
  /// anything that is not one (content://, http, sealed://, adb://).
  static String? localPathOf(String uri) {
    if (uri.startsWith('/')) return uri;
    if (uri.startsWith('file://')) {
      try {
        return Uri.parse(uri).toFilePath();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  /// True when every byte is zero. Eight bytes at a time, because this runs
  /// over a megabyte per probe.
  static bool isAllZero(Uint8List bytes) {
    if (bytes.isEmpty) return true;
    final words = bytes.lengthInBytes ~/ 8;
    final view = bytes.buffer.asByteData(bytes.offsetInBytes, bytes.lengthInBytes);
    for (var i = 0; i < words; i++) {
      if (view.getUint64(i * 8, Endian.little) != 0) return false;
    }
    for (var i = words * 8; i < bytes.length; i++) {
      if (bytes[i] != 0) return false;
    }
    return true;
  }
}
