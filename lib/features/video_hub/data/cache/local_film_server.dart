import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../api/offline_crypto.dart';

/// Gives the player a local address for a film on this phone that it cannot
/// open by path: one that is ciphertext, one that is still downloading, or both.
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
class LocalFilmServer {
  LocalFilmServer._();
  static final LocalFilmServer instance = LocalFilmServer._();

  HttpServer? _server;
  String? _token;

  /// id → the film it serves, and the reverse so re-opening one film twice
  /// does not register it twice.
  final Map<String, _Film> _open = <String, _Film>{};
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
      if (kDebugMode) debugPrint('LocalFilmServer: $e');
    });
    _server = s;
  }

  /// Register a sealed film and get the address to play instead of its path.
  ///
  /// Returns null when this cannot be served, and the caller must then NOT fall
  /// back to the file itself — a sealed file played directly is noise. Failing
  /// here is "this film will not open", which is a thing to say out loud rather
  /// than a thing to paper over.
  /// A finished film, sealed, read straight off the disk.
  Future<String?> localUrlFor({
    required File file,
    required SealInfo seal,
  }) =>
      _register(_Film(
        file: file,
        seal: seal,
        total: seal.plainLength,
      ));

  /// A film that is STILL DOWNLOADING.
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// WHAT THIS IS FOR, AND WHY IT IS THE FEATURE PEOPLE ASKED FOR
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// Telegram plays a video while it downloads, and that is what this audience
  /// is used to: you start it, you watch the beginning, and the rest arrives
  /// behind you. Waiting for a whole film before it will open is the thing that
  /// makes downloading feel worse than streaming even when it is better.
  ///
  /// [total] is the length of the WHOLE film, from the object's own
  /// Content-Length, so the seek bar is the film's and not the part file's.
  /// Bytes that have not arrived are WAITED FOR rather than refused — see
  /// `_waitFor`, which is the whole difference between this and an error.
  ///
  /// [seal] is null for an unsealed download, in which case the part file is
  /// read as it is.
  Future<String?> localUrlForGrowing({
    required File part,
    required File finished,
    required SealInfo? seal,
    required int total,
  }) =>
      _register(_Film(
        file: part,
        seal: seal,
        total: total,
        growing: true,
        finished: finished,
      ));

  Future<String?> _register(_Film film) async {
    try {
      await _ensureStarted();
      final port = _server?.port;
      final token = _token;
      if (port == null || token == null) return null;
      final file = film.file;
      // ONE ID PER FILM PER PROCESS. Re-opening the same film — a second play,
      // an expand out of the floating window, a retry after a stall — has to
      // land on the same address, or the player's own comparisons of "is this
      // still the video I was told to play" stop matching.
      final id = _idFor.putIfAbsent(file.path, _mintId);
      _open[id] = film;
      return 'http://127.0.0.1:$port/s/$token/$id';
    } catch (e) {
      if (kDebugMode) debugPrint('LocalFilmServer._register: $e');
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
      if (kDebugMode) debugPrint('LocalFilmServer._handle: $e');
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  /// Waits until [pos] has arrived, and says how far the film now reaches.
  ///
  /// ═══════════════════════════════════════════════════════════════════
  /// WHY A POLL AND NOT A NOTIFICATION
  /// ═══════════════════════════════════════════════════════════════════
  ///
  /// The writer is the downloader, in this same isolate, and it could be made to
  /// signal. It is not, because the reader must also survive the writer being
  /// gone: a download that was cancelled, paused, or finished and renamed while
  /// somebody was watching. A poll asks the filesystem, which is the only thing
  /// that knows all three of those; a subscription would need every one of them
  /// to remember to fire.
  ///
  /// A quarter-second tick against a download measured in minutes is free, and
  /// it only ever runs while a player is genuinely ahead of the bytes.
  ///
  /// THE CEILING IS A MINUTE AND A HALF. Past that, a download is not slow, it
  /// has stopped — and holding the socket open for ever would leave the player
  /// showing a spinner with nothing behind it. Giving up writes a short
  /// response, which the player treats as a dropped connection and retries: if
  /// the download resumes, the retry succeeds.
  static const Duration _waitStep = Duration(milliseconds: 250);
  static const int _waitSteps = 360; // 90 seconds

  Future<int> _waitFor(_Film entry, int pos) async {
    for (var i = 0; i < _waitSteps; i++) {
      await Future<void>.delayed(_waitStep);
      final reach = await entry.available();
      // NEGATIVE IS NOT "NOT YET". The part file is gone and there is no
      // finished file either, so the download was cancelled or deleted and no
      // amount of waiting will produce this byte.
      if (reach < 0) return -1;
      if (reach > pos) return reach;
    }
    return -1;
  }

  /// A plain read, for a download that is not sealed.
  Future<Uint8List?> _readPlainBytes(
    RandomAccessFile handle, {
    required int offset,
    required int length,
  }) async {
    try {
      await handle.setPosition(offset);
      return await handle.read(length);
    } catch (e) {
      if (kDebugMode) debugPrint('LocalFilmServer._readPlainBytes: $e');
      return null;
    }
  }

  Future<void> _serve(HttpRequest req, HttpResponse res, _Film entry) async {
    final total = entry.total;
    if (total <= 0) {
      res.statusCode = HttpStatus.notFound;
      await res.close();
      return;
    }

    // ─── OPENED BEFORE A HEADER IS WRITTEN ────────────────────────────────
    //
    // Once a status line has gone out there is no status code left to send, so
    // a file that cannot be opened has to be discovered here or not reported at
    // all. This is reachable in the ordinary course of things: a demuxer opens a
    // second connection on a large seek, and by then a download may have
    // finished and its part file been renamed — which is why the open falls back
    // to the finished name rather than failing.
    //
    // A HANDLE PER REQUEST, not one per film. Two readers sharing a handle share
    // its position, which is a race that produces the WRONG BYTES rather than an
    // error.
    final handle = await entry.openForRead();
    if (handle == null) {
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
        // As with the HEAD return below: the handle is open above this line, so
        // each early return closes it. A leaked handle per refused range is a
        // file descriptor per seek, and a process runs out of those.
        try {
          await handle.close();
        } catch (_) {}
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
      // The handle is opened above a header write, so this early return owns
      // closing it — the `finally` below is on a block this never enters.
      try {
        await handle.close();
      } catch (_) {}
      await res.close();
      return;
    }

    try {
      var pos = start;
      while (pos <= endInclusive) {
        // ─── IS THIS BYTE HERE YET? ──────────────────────────────────────
        //
        // For a finished film the answer is always yes. For one still
        // downloading, a demuxer that seeks ahead — which every demuxer does,
        // to read the end of the index or to honour somebody dragging the seek
        // bar — asks for bytes that have not arrived. Answering short there
        // would look to the player exactly like a dropped connection, and it
        // would give up on a film that is arriving perfectly well.
        //
        // So it WAITS. That is what Telegram does, it is what somebody dragging
        // a seek bar expects, and it is the whole difference between "watch
        // while it downloads" and "an error halfway through".
        var reach = await entry.available();
        if (pos >= reach) {
          reach = await _waitFor(entry, pos);
          if (reach <= pos) break;
        }
        final ceiling = min(endInclusive, reach - 1);
        final want = min(_chunk, ceiling - pos + 1);
        if (want <= 0) break;
        final plain = entry.seal == null
            ? await _readPlainBytes(handle, offset: pos, length: want)
            : await OfflineCrypto.readPlain(
                handle,
                entry.seal!,
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
      if (kDebugMode) debugPrint('LocalFilmServer._serve: $e');
    } finally {
      try {
        await handle.close();
      } catch (_) {}
      try {
        await res.close();
      } catch (_) {}
    }
  }
}

@immutable
class _Film {
  const _Film({
    required this.file,
    required this.seal,
    required this.total,
    this.growing = false,
    this.finished,
  });

  /// What to open. For a growing film this is the `.part` file — and an open
  /// handle on it SURVIVES THE RENAME that finishes the download, because a
  /// rename moves a name and not an inode. Somebody watching while the last
  /// megabytes arrive does not have their playback interrupted by the download
  /// completing.
  final File file;

  /// Null for a plain file. Sealed films carry their IV here; a growing sealed
  /// download has no trailer yet, so the IV comes from the sidecar beside the
  /// part file and the length from the object's own Content-Length.
  final SealInfo? seal;

  /// The length of the WHOLE film, which for a growing one is more than is on
  /// disk. It is what the seek bar and the duration are drawn from.
  final int total;

  final bool growing;

  /// Where the part file lands when it finishes. Read only to answer "how much
  /// is there now" once the rename has happened.
  final File? finished;

  /// Opens the film for reading, whichever name it is under now.
  ///
  /// A download that finishes while somebody is watching renames its part file,
  /// and a request that arrives after that — a demuxer's second connection on a
  /// large seek — would otherwise find nothing. The layout is identical either
  /// way: ciphertext from byte zero, with the trailer only ever at the end, so
  /// every offset in this file still means the same thing.
  Future<RandomAccessFile?> openForRead() async {
    try {
      if (await file.exists()) return await file.open();
    } catch (_) {/* fall through to the finished name */}
    final done = finished;
    if (done != null) {
      try {
        if (await done.exists()) return await done.open();
      } catch (_) {}
    }
    return null;
  }

  /// How much of the film can be read right now.
  ///
  /// Returns a negative number when the download has gone — cancelled, or
  /// deleted from the shelf — which is different from "not yet" and is the one
  /// case where waiting would be waiting for ever.
  Future<int> available() async {
    if (!growing) return total;
    try {
      if (await file.exists()) return await file.length();
    } catch (_) {/* fall through to the finished name */}
    final done = finished;
    if (done != null) {
      try {
        if (await done.exists()) {
          final length = await done.length();
          // The finished file carries the trailer; the film does not.
          return seal == null
              ? length
              : length - OfflineCrypto.trailerLength;
        }
      } catch (_) {}
    }
    return -1;
  }
}
