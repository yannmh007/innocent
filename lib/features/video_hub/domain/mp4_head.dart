import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Whether a film can be watched while it is still downloading.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS A QUESTION AT ALL
/// ═══════════════════════════════════════════════════════════════════════
///
/// An MP4 keeps its frames in `mdat` and its index — every frame's offset,
/// size and timestamp — in `moov`. A demuxer cannot play one frame without the
/// index, so where `moov` sits decides everything:
///
///   ftyp moov mdat   the index is at the FRONT. The first few megabytes are
///                    enough to start playing, and the rest can arrive while
///                    somebody is watching.
///
///   ftyp mdat moov   the index is at the END. Nothing is playable until the
///                    very last byte, however much of the film is on disk.
///
/// The console rewrites uploads into the first shape, which is what makes this
/// worth offering. But every film uploaded before that existed is in the second,
/// and offering "watch now" on one of those would open a black screen that never
/// resolves — so the shape is read out of the bytes rather than assumed.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY IT IS PURE, AND TESTED
/// ═══════════════════════════════════════════════════════════════════════
///
/// Its answer is a button. `ready` when the film is not is a black screen with
/// a spinner on it; `indexAtEnd` when the film is fine is a feature nobody can
/// find. Neither throws, and neither is visible in a screenshot of the case
/// somebody thought to check — so the walk takes bytes and returns a verdict,
/// with no file and no player anywhere near it.
enum ProgressiveState {
  /// Not enough on disk yet to tell, or to start. Ask again as it grows.
  waiting,

  /// The index is at the end of the file: nothing to do but wait for all of it.
  indexAtEnd,

  /// Playable now.
  ready,
}

/// How much of the film past its index has to be on disk before playing.
///
/// Four megabytes. At the bitrate of a film somebody would download this is a
/// handful of seconds — enough that the demuxer fills its buffer and starts
/// instead of stalling on its first read, and little enough that "watch now"
/// appears within a minute of starting a download on a Myanmar connection.
const int kProgressiveMargin = 4 * 1024 * 1024;

@immutable
class HeadVerdict {
  const HeadVerdict(this.state, {this.moovEnd = 0, this.needed = 0});

  final ProgressiveState state;

  /// Where the index finishes, once it has been found. Zero until then.
  final int moovEnd;

  /// How many bytes have to be on disk before playback may start. Zero when
  /// that cannot be said yet.
  final int needed;
}

/// Walks the top-level boxes of [head] and says whether playback can start.
///
/// [head] is the first bytes of the FILM — decrypted, if the download is
/// sealed — and need not be the whole index. [onDisk] is how much of the film
/// has arrived; [total] is how long the whole film is.
HeadVerdict assessMp4Head(
  Uint8List head, {
  required int onDisk,
  required int total,
  int margin = kProgressiveMargin,
}) {
  var at = 0;
  while (at + 8 <= head.length) {
    final view = ByteData.sublistView(head, at);
    final declared = view.getUint32(0, Endian.big);
    final type = String.fromCharCodes(head, at + 4, at + 8);

    var size = declared;
    var headerLength = 8;
    if (declared == 1) {
      // A 64-bit box: the real size follows the type. Films big enough for
      // this exist — a 4K master is one — and reading the 32-bit field as the
      // size would walk to a nonsense offset and answer confidently.
      if (at + 16 > head.length) return const HeadVerdict(ProgressiveState.waiting);
      final large = ByteData.sublistView(head, at + 8).getUint64(0, Endian.big);
      // NEGATIVE MEANS ABOVE 2^63. Dart's `getUint64` hands back a signed
      // integer, so a box claiming more than nine exabytes arrives as a
      // negative number — and a negative size would walk the cursor BACKWARDS,
      // which is not a wrong answer but an endless loop. Anything below the
      // 64-bit header's own length is equally impossible.
      if (large < 16) return const HeadVerdict(ProgressiveState.indexAtEnd);
      size = large;
      headerLength = 16;
    } else if (declared == 0) {
      // "To the end of the file". Only legal on the last box.
      if (type == 'moov') {
        // An index that runs to the end of the file IS an index at the end.
        return const HeadVerdict(ProgressiveState.indexAtEnd);
      }
      if (type == 'mdat') {
        // Frames to the end, and no index before them.
        return const HeadVerdict(ProgressiveState.indexAtEnd);
      }
      return const HeadVerdict(ProgressiveState.waiting);
    } else if (declared < 8) {
      // Malformed. REFUSE RATHER THAN GUESS: the cost of being wrong here is a
      // black screen somebody has to back out of, and the film is still
      // perfectly watchable once it finishes.
      return const HeadVerdict(ProgressiveState.indexAtEnd);
    }

    if (type == 'mdat') {
      // Frames before the index. Nothing is playable until the last byte.
      return const HeadVerdict(ProgressiveState.indexAtEnd);
    }

    if (type == 'moov') {
      final end = at + size;
      // THE WHOLE INDEX, not just its header. A demuxer reads all of `moov`
      // before it will play anything, so a film whose index has only started
      // to arrive is not ready — it is waiting.
      final needed = end + margin > total ? total : end + margin;
      return HeadVerdict(
        onDisk >= needed && onDisk >= end
            ? ProgressiveState.ready
            : ProgressiveState.waiting,
        moovEnd: end,
        needed: needed,
      );
    }

    if (size < headerLength) {
      return const HeadVerdict(ProgressiveState.indexAtEnd);
    }
    at += size;
  }
  // Ran out of head without meeting either box. That is the ordinary state in
  // the first seconds of a download; it is also what a file full of `free`
  // boxes looks like, and both are answered the same way — ask again when there
  // is more.
  return const HeadVerdict(ProgressiveState.waiting);
}
