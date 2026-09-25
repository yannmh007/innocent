import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/offline_crypto.dart';

/// Gives the player a local address for a sealed film on this phone.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY THIS EXISTS AT ALL
/// ═══════════════════════════════════════════════════════════════════════
///
/// libmpv opens a URL and asks it for byte ranges. It cannot be handed a
/// decrypting file handle, there is no hook for one, and decrypting the whole
/// film to a second file before playing it would want another four gigabytes of
/// a phone that has not got them — and a minute of staring at nothing.
///
/// So the decryption wears the shape of an HTTP server, which is the same answer
/// [StreamCacheServer] arrived at for the same reason and the same one ExoPlayer
/// ships. It is a SEPARATE server rather than a branch inside that one because
/// the two have nothing in common but the shape: this one has no upstream, no
/// refresh, no store and no budget. Every film is already here.
///
/// ═══════════════════════════════════════════════════════════════════════
/// WHY ANOTHER APP ON THE PHONE CANNOT USE IT
/// ═══════════════════════════════════════════════════════════════════════
///
/// Loopback is not private on Android: any app may connect to 127.0.0.1 on any
/// port, so a server that decrypts on request would otherwise be a decryption
/// service for the whole device — the exact thing the encryption was for. The
/// address therefore carries a token minted once per process, and a request
/// without it is refused before a file is opened. The token is handed to libmpv
/// in-process and appears in no log and no URL that leaves the phone.
class SealedFileServer {
  SealedFileServer._();
  static final SealedFileServer instance = SealedFileServer._();

  HttpServer? _server;
  String? _token;

  /// id → the film it serves, and the reverse so re-opening one film twice
  /// does not register it twice.
  final Map<String, _Sealed> _open = <String, _Sealed>{};
  final Map<String, String> _idFor = <String, String>{};

  /// How much to decrypt per turn of the loop.
  ///
  /// A quarter of a megabyte. Large enough that the channel hop to the
  /// platform's AES is noise against the work it does, small enough that the
  /// socket is never waiting and nothing is held: at a film's bitrate this is a
  /// fraction of a second of video in flight.
  static const int _chunk = 256 * 1024;

  bool get running => _server != null;

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final rnd = Random.secure();
    _token = List<int>.generate(24, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_handle, onError: (Object e) {
      if (kDebugMode) debugPrint('SealedFileServer: $e');
    });
    _server = s;
  }

  /// Register a sealed film and get the address to play instead of its path.
  ///
  /// Returns null when this cannot be served, and the caller must then NOT fall
  /// back to the file itself — a sealed file played directly is noise. Failing
  /// here is "this film will not open", which is a thing to say out loud rather
  /// than a thing to paper over.
  Future<String?> localUrlFor({
    required File file,
    required SealInfo seal,
  }) async {
    try {
      await _ensureStarted();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;
      // ONE ID PER FILM PER PROCESS. Re-opening the same film — a second play,
      // an expand out of the floating window, a retry after a stall — has to
      // land on the same address, or the player's own comparisons of "is this
      // still the video I was told to play" stop matching.
      final id = _idFor.putIfAbsent(file.path, _mintId);
      _open[id] = _Sealed(file: file, seal: seal);
      return 'http://127.0.0.1:$port/s/$token/$id';
    } catch (e) {
      if (kDebugMode) debugPrint('SealedFileServer.localUrlFor: $e');
      return null;
    }
  }

  /// NOTHING IS EVER RELEASED, and that is a decision rather than an omission.
  ///
  /// [StreamCacheServer] has to release: its entries hold a signed URL that
  /// expires and a closure over the screen that made it, so one per playback
  /// for the life of the process would keep both alive long after the screen
  /// was gone. An entry here holds a path and sixteen bytes. There is nothing
  /// to go stale, nothing to keep alive, and the map is bounded by the number
  /// of distinct films somebody watches before closing the app.
  String _mintId() {
    final rnd = Random.secure();
    return List<int>.generate(8, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final parts = req.uri.pathSegments;
      if (parts.length != 3 || parts[0] != 's' || parts[1] != _token) {
        res.statusCode = HttpStatus.forbidden;
        await res.close();
        return;
      }
      final entry = _open[parts[2]];
      if (entry == null) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      if (req.method != 'GET' && req.method != 'HEAD') {
        res.statusCode = HttpStatus.methodNotAllowed;
        await res.close();
        return;
      }
      await _serve(req, res, entry);
    } catch (e) {
      if (kDebugMode) debugPrint('SealedFileServer._handle: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serve(HttpRequest req, HttpResponse res, _Sealed entry) async {
    final total = entry.seal.plainLength;
    if (total <= 0) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    // HTTP ranges are inclusive at both ends. Everything below is half-open,
    // and the conversion happens here, once.
    var start = 0;
    var endInclusive = total - 1;
    final header = req.headers.value(HttpHeaders.rangeHeader);
    final partial = header != null && header.startsWith('bytes=');
    if (partial) {
      final spec = header.substring(6).split('-');
      if (spec.isNotEmpty && spec[0].isNotEmpty) {
        start = int.tryParse(spec[0]) ?? 0;
      }
      if (spec.length > 1 && spec[1].isNotEmpty) {
        endInclusive = int.tryParse(spec[1]) ?? endInclusive;
      }
      if (start < 0 || start >= total) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$total');
        await res.close();
        return;
      }
      if (endInclusive >= total) endInclusive = total - 1;
      if (endInclusive < start) endInclusive = start;
    }

    res.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    res.headers
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set(HttpHeaders.contentTypeHeader, 'video/mp4')
      ..set(HttpHeaders.contentLengthHeader, '${endInclusive - start + 1}');
    if (partial) {
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-$endInclusive/$total');
    }
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }

    // A HANDLE PER REQUEST, not one per film. A demuxer opens a second
    // connection to read the tail while the first is still reading the head,
    // and two readers sharing one handle share its position — which is a race
    // that produces the wrong bytes rather than an error.
    RandomAccessFile? handle;
    try {
      handle = await entry.file.open();
      var pos = start;
      while (pos <= endInclusive) {
        final want = min(_chunk, endInclusive - pos + 1);
        final plain = await OfflineCrypto.readPlain(
          handle,
          entry.seal,
          offset: pos,
          length: want,
        );
        // A SHORT READ AND NOT AN ERROR. The headers are already committed, so
        // there is no status code left to send; stopping the write is what a
        // dropped connection looks like from the player's side, and its retry
        // path is exactly for that.
        if (plain == null || plain.isEmpty) break;
        res.add(plain);
        // THE FLUSH IS THE BACK-PRESSURE. `add` queues and never blocks, so a
        // loop without this would decrypt a whole film into memory at flash
        // speed while the socket drained at playback speed.
        await res.flush();
        pos += plain.length;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('SealedFileServer._serve: $e');
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

@immutable
class _Sealed {
  const _Sealed({required this.file, required this.seal});
  final File file;
  final SealInfo seal;
}
