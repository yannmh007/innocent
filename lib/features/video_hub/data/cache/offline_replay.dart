import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../domain/mp4_head.dart';
import 'stream_cache_id.dart';
import 'stream_cache_server.dart';
import 'stream_cache_store.dart';

/// Why a film cannot be watched from what is already on this phone.
enum ReplayRefusal {
  /// This title has never been played on this device, or the cache was cleared,
  /// or eviction took it. There is nothing to offer.
  nothingHeld,

  /// Some of it is here, but not enough to open — the index has not all
  /// arrived. Watching a minute of a film leaves a minute of it.
  notEnoughYet,

  /// The index is at the END of this file, so it cannot be opened from a
  /// partial copy at all. The two legacy `v/` uploads are like this; everything
  /// the console has processed since is not.
  indexAtEnd,

  /// The film is there and the loopback server would not start.
  cannotOpen,
}

/// Either an address to play or the reason there is not one.
@immutable
class ReplayOffer {
  const ReplayOffer.ready(this.url, {required this.heldBytes, required this.total})
      : refusal = null;
  const ReplayOffer.no(this.refusal)
      : url = null,
        heldBytes = 0,
        total = 0;

  final String? url;
  final ReplayRefusal? refusal;

  /// What is on disk, and how long the whole film is — so the caller can say
  /// "about twenty minutes of this is here" rather than just offering a button.
  final int heldBytes;
  final int total;

  bool get isReady => url != null;

  /// Whether the whole film is here. Then it is not a partial replay at all.
  bool get isComplete => total > 0 && heldBytes >= total;
}

/// WATCH WHAT WAS ALREADY WATCHED, WITH NO CONNECTION.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS DID NOT WORK, AND IT LOOKED LIKE IT SHOULD
/// ═══════════════════════════════════════════════════════════════════════
///
/// The streaming cache keeps every byte the phone receives, in app-private
/// storage, so that dragging the bar back thirty seconds costs nothing. All of
/// it was still there with the radio off — and unreachable, because every play
/// in this app goes through `requestPlayback` first and a phone with no signal
/// never gets an answer. The bytes were on the disk, already paid for, already
/// authorised once by the server that sent them, and the app refused to open
/// them.
///
/// That is what this closes. `requestPlayback` now answers
/// `AccessDenial.offline` when it could not ASK, as opposed to having been told
/// no — and only for that value does the caller come here.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHAT IT IS HONEST ABOUT
/// ═══════════════════════════════════════════════════════════════════════
///
/// **It is the same concession as `playOffline`, not a new one.** A downloaded
/// film is opened on the strength of the client's own capability table, because
/// offline there is no server to ask; these bytes are in the same position, and
/// the same table decides. A client-side check protects nothing against anyone
/// willing to modify the app. What limits it is that the bytes only exist
/// because the server authorised the stream that produced them, and that the
/// entitlement standing behind this decision is itself the server's last
/// answer, kept for thirty days and dropped on sign-out — see
/// `AccountSnapshot`.
///
/// **How much can be played is read out of the file, not guessed.** The cache
/// holds arbitrary runs of bytes: somebody who dragged the bar has a hundred
/// megabytes from the middle of a film and cannot open it at all. So the run
/// containing byte zero is found, its header is walked by [assessMp4Head] — the
/// same function the "watch while downloading" screen uses, for the same reason
/// — and a film whose index is at the end is refused rather than opened into a
/// black screen that never resolves.
///
/// **Which rung it was is not remembered, so every one is tried.** A cache id
/// is a hash of the title, the asset and the rung, precisely so a directory
/// listing is not a list of what somebody has watched; that also means the
/// mapping only goes one way. See [kStreamCacheRungs].
class OfflineReplay {
  OfflineReplay._();

  /// How much of the head to read before deciding. Two megabytes is far more
  /// than a `moov` for any ordinary film and one flash read.
  static const int _headBytes = 2 * 1024 * 1024;

  /// What can be played of [titleId] right now, from this device alone.
  ///
  /// [assetId] names an album clip when this is one, exactly as
  /// `streamCacheId` takes it — so a behind-the-scenes clip that was watched
  /// offline is found, and is not confused with the main film.
  static Future<ReplayOffer> open({
    required String titleId,
    String? assetId,
  }) async {
    try {
      final store = StreamCacheStore.instance;
      final entry = await store.bestHeadAmong(
        streamCacheCandidates(titleId: titleId, assetId: assetId),
      );
      if (entry == null) return const ReplayOffer.no(ReplayRefusal.nothingHeld);

      final head = entry.partAt(0);
      // bestHeadAmong only returns an entry that HAS a run at zero, so this is
      // belt and braces against a future change to it rather than a case that
      // can happen today.
      if (head == null) return const ReplayOffer.no(ReplayRefusal.nothingHeld);

      final bytes = await _readHead(head.file, min(_headBytes, head.length));
      if (bytes == null) return const ReplayOffer.no(ReplayRefusal.cannotOpen);

      // `onDisk` is the CONTIGUOUS run from the start and not `heldBytes`.
      // Handing over the total would claim a gap had been filled, and the
      // verdict would say a film was ready to open when its index was still
      // half missing.
      final verdict = assessMp4Head(
        bytes,
        onDisk: head.length,
        total: entry.total,
      );
      switch (verdict.state) {
        case ProgressiveState.indexAtEnd:
          // Unless the whole thing happens to be here, in which case the index
          // is here too and it opens like any complete file.
          if (head.length >= entry.total) break;
          return const ReplayOffer.no(ReplayRefusal.indexAtEnd);
        case ProgressiveState.waiting:
          return const ReplayOffer.no(ReplayRefusal.notEnoughYet);
        case ProgressiveState.ready:
          break;
      }

      final url = await StreamCacheServer.instance
          .localUrlForHeldBytes(cacheId: entry.id);
      if (url == null) return const ReplayOffer.no(ReplayRefusal.cannotOpen);
      return ReplayOffer.ready(
        url,
        heldBytes: entry.heldBytes,
        total: entry.total,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineReplay.open: $e');
      return const ReplayOffer.no(ReplayRefusal.cannotOpen);
    }
  }

  static Future<Uint8List?> _readHead(File file, int length) async {
    if (length <= 0) return null;
    RandomAccessFile? handle;
    try {
      handle = await file.open();
      final out = await handle.read(length);
      return out.isEmpty ? null : out;
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineReplay._readHead: $e');
      return null;
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
    }
  }
}
