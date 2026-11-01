/// A stand-in for the stream Worker holding one object (sealed or not):
/// ranges with 206, and the faults a real line and a real Worker produce.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:innocent/features/video_hub/data/seal/media_seal_layout.dart';

/// A stand-in for the Worker: one object, ranges, and the faults to inject.
class FakeWorker {
  FakeWorker(this.body);

  Uint8List body;
  HttpServer? _s;
  int requests = 0, bytesSent = 0, headerRequests = 0;
  final List<String> ranges = <String>[];

  /// Answers to give before serving normally, one per request: a status,
  /// optionally with a retry-after.
  final List<(int, String?)> refuse = <(int, String?)>[];

  /// Sealed offsets whose byte is flipped, for this many more requests.
  int corruptAt = -1, corruptTimes = 0;

  /// Bytes a second, or 0 for as fast as it goes.
  int trickle = 0;

  /// The total named in Content-Range, when it should lie.
  int? claimTotal;

  Future<String> start() async {
    final s = _s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    s.listen(_serve);
    return 'http://127.0.0.1:${s.port}/v/token';
  }

  Future<void> stop() async => _s?.close(force: true);

  Future<void> _serve(HttpRequest req) async {
    requests++;
    final res = req.response;
    final range = req.headers.value(HttpHeaders.rangeHeader) ?? '';
    ranges.add(range);
    if (refuse.isNotEmpty) {
      final (code, retry) = refuse.removeAt(0);
      res.statusCode = code;
      if (retry != null) res.headers.set('retry-after', retry);
      await res.close();
      return;
    }
    // A bounded range, an open one (`bytes=a-`, a downloader's resume), or
    // none at all: the whole object, 200.
    final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
    final a = m == null ? 0 : int.parse(m.group(1)!);
    final b = m == null || m.group(2)!.isEmpty
        ? body.length - 1
        : min(int.parse(m.group(2)!), body.length - 1);
    if (a == 0 && b == MediaSealLayout.header - 1) headerRequests++;
    final slice = Uint8List.fromList(body.sublist(a, b + 1));
    if (corruptTimes > 0 && corruptAt >= a && corruptAt <= b) {
      corruptTimes--;
      slice[corruptAt - a] ^= 1;
    }
    res.statusCode = m == null ? HttpStatus.ok : HttpStatus.partialContent;
    res.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (m != null) res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $a-$b/${claimTotal ?? body.length}');
    res.contentLength = slice.length;
    try {
      if (trickle <= 0) {
        res.add(slice);
        bytesSent += slice.length;
      } else {
        const piece = 16 * 1024;
        for (var o = 0; o < slice.length; o += piece) {
          final e = min(slice.length, o + piece);
          res.add(Uint8List.sublistView(slice, o, e));
          await res.flush();
          bytesSent += e - o;
          await Future<void>.delayed(Duration(milliseconds: (piece * 1000) ~/ trickle));
        }
      }
      await res.close();
    } catch (_) {
      // The gateway hung up: what a seek does.
    }
  }
}

