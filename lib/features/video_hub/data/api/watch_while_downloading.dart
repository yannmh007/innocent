import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../../domain/mp4_head.dart';
import '../cache/local_film_server.dart';
import 'offline_crypto.dart';
import 'offline_library.dart';

/// Why a download cannot be watched yet.
enum PartialRefusal {
  /// Not enough of the film has arrived. Ask again in a moment.
  notEnoughYet,

  /// The index is at the end of this file, so there is nothing to do but wait
  /// for all of it. Films uploaded before the console started reordering them
  /// are all like this.
  indexAtEnd,

  /// The part file is not there. Cancelled, deleted, or finished and renamed
  /// while the screen was open.
  gone,

  /// The film is there and readable and something else went wrong — the local
  /// server would not start, or the sidecar is unreadable.
  cannotOpen,
}

/// Either an address to play or the reason there is not one.
@immutable
class PartialPlay {
  const PartialPlay.ready(this.url) : refusal = null;
  const PartialPlay.no(this.refusal) : url = null;

  final String? url;
  final PartialRefusal? refusal;
}

/// Opens a download that has not finished.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS IS WORTH HAVING
/// ═══════════════════════════════════════════════════════════════════════
///
/// Telegram plays a video while it downloads, and that is what this audience is
/// used to. Waiting for a whole film before it will open is the thing that makes
/// downloading feel worse than streaming even when it is the better choice — and
/// on a connection where a film takes an hour, "you can start watching now" is
/// the difference between a feature people use and one they try once.
///
/// HOW MUCH HAS TO BE THERE IS READ OUT OF THE FILE, not guessed. See
/// [assessMp4Head]: the index has to be at the front and it has to have
/// arrived, and a film whose index is at the end can only be watched when the
/// last byte lands. Offering it anyway would open a black screen that never
/// resolves, on a screen whose whole job is to be reassuring.
class WatchWhileDownloading {
  WatchWhileDownloading._();

  /// How much of the film to read when looking for the index.
  ///
  /// Two megabytes. An index for a feature-length film is tens to hundreds of
  /// kilobytes; two megabytes covers a long one with several audio tracks and
  /// subtitle streams, and is still a single read.
  static const int _headBytes = 2 * 1024 * 1024;

  static Future<PartialPlay> open({
    required OfflineLibrary library,
    required String titleId,
    required int? total,
  }) async {
    RandomAccessFile? handle;
    try {
      final dir = await library.directory();
      final finalPath = '${dir.path}/$titleId.mp4';
      final part = File('$finalPath${OfflineLibrary.partSuffix}');
      final finished = File(finalPath);
      if (!await part.exists()) {
        return const PartialPlay.no(PartialRefusal.gone);
      }
      // WITHOUT A LENGTH THERE IS NO SEEK BAR AND NO DURATION. The object's
      // Content-Length is written beside the part file on the first pass, so
      // this is only null in the seconds before the first response arrives.
      if (total == null || total <= 0) {
        return const PartialPlay.no(PartialRefusal.notEnoughYet);
      }
      final onDisk = await part.length();
      if (onDisk <= 0) {
        return const PartialPlay.no(PartialRefusal.notEnoughYet);
      }

      // The IV, if this download is sealed. A growing sealed film has no
      // trailer yet — that is written at the end — so the IV comes from the
      // sidecar and the length from the size note.
      SealInfo? seal;
      final ivFile = File('${part.path}.iv');
      if (await ivFile.exists()) {
        final raw = (await ivFile.readAsString()).trim();
        Uint8List iv;
        try {
          iv = Uint8List.fromList(base64Decode(raw));
        } catch (_) {
          return const PartialPlay.no(PartialRefusal.cannotOpen);
        }
        if (iv.length != OfflineCrypto.block) {
          return const PartialPlay.no(PartialRefusal.cannotOpen);
        }
        seal = SealInfo(iv: iv, plainLength: total);
      }

      handle = await part.open();
      final wanted = min(_headBytes, onDisk);
      Uint8List? head;
      if (seal == null) {
        head = await handle.read(wanted);
      } else {
        head = await OfflineCrypto.readPlain(
          handle,
          seal,
          offset: 0,
          length: wanted,
        );
      }
      if (head == null || head.isEmpty) {
        return const PartialPlay.no(PartialRefusal.notEnoughYet);
      }

      final verdict = assessMp4Head(head, onDisk: onDisk, total: total);
      switch (verdict.state) {
        case ProgressiveState.indexAtEnd:
          return const PartialPlay.no(PartialRefusal.indexAtEnd);
        case ProgressiveState.waiting:
          return const PartialPlay.no(PartialRefusal.notEnoughYet);
        case ProgressiveState.ready:
          final url = await LocalFilmServer.instance.localUrlForGrowing(
            part: part,
            finished: finished,
            seal: seal,
            total: total,
          );
          return url == null
              ? const PartialPlay.no(PartialRefusal.cannotOpen)
              : PartialPlay.ready(url);
      }
    } catch (e) {
      if (kDebugMode) debugPrint('WatchWhileDownloading.open: $e');
      return const PartialPlay.no(PartialRefusal.cannotOpen);
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
    }
  }
}
