import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:innocent/core/services/network/foreground_stream.dart';
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/data/api/ranged_fetch.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// THE SPEED AND THE HEAT (reported 2026-10-03): the phone's meter read about
/// 3 MB/s while the Downloads screen said under 1 MB/s, and the phone ran hot.
/// Every few-kilobyte piece of the body went across the platform channel to
/// be enciphered, and the next piece was not read until it came back.
///
/// These pin the fix: pieces are gathered and enciphered half a megabyte at a
/// time, the file is still exactly right, and a film streaming in the
/// foreground slows a download down rather than competing with it.

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
  @override
  Future<String?> getApplicationCachePath() async => dir;
}

class _Repo implements ContentRepository {
  @override
  Future<PlaybackGrant> requestPlayback({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
  }) async =>
      const PlaybackGrant.granted('https://media.test/film.mp4');

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// Serves [body] in 4 KB chunks, the way a mobile socket hands it over —
/// honouring `bytes=a-` and `bytes=a-b`, and counting what it does.
class _Chunky extends http.BaseClient {
  _Chunky(this.body, {this.ignoreBoundedRanges = false, this.failPartAt, this.slowPartAt, this.stallAt, this.pieceDelay = Duration.zero});
  final Uint8List body;
  static const int piece = 4096;

  /// A server (or a proxy) that answers a bounded range with the whole file.
  final bool ignoreBoundedRanges;

  /// The first request starting here dies halfway through its body.
  int? failPartAt;

  /// The first request starting here goes silent halfway: no error, no bytes,
  /// a socket a dead mobile link leaves behind.
  int? stallAt;

  /// Between packets: a line of a given speed.
  final Duration pieceDelay;

  /// The request starting here takes its time: a lossy lane.
  final int? slowPartAt;
  int startedWhileSlow = 0;
  bool _slowRunning = false;

  int inFlight = 0;
  int maxInFlight = 0;
  int served = 0;
  int requests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests++;
    var from = 0;
    int? to;
    final range = request.headers['Range'] ?? request.headers['range'];
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
      from = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) to = int.parse(m.group(2)!);
    }
    final ignored = to != null && ignoreBoundedRanges;
    if (ignored) {
      from = 0;
      to = null;
    }
    final last = to ?? body.length - 1;
    final slow = slowPartAt == from;
    if (_slowRunning) startedWhileSlow++;
    final fail = failPartAt != null && failPartAt == from;
    if (fail) failPartAt = null;
    final status = range == null || ignored ? 200 : 206;

    Stream<List<int>> pieces() async* {
      inFlight++;
      if (inFlight > maxInFlight) maxInFlight = inFlight;
      if (slow) _slowRunning = true;
      try {
        if (slow) await Future<void>.delayed(const Duration(milliseconds: 400));
        for (var i = from; i <= last; i += piece) {
          if (fail && i - from >= (last - from) ~/ 2) {
            throw const SocketException('connection reset');
          }
          // A real socket yields to the event loop between packets; this is
          // what lets several lanes run at once.
          await Future<void>.delayed(pieceDelay);
          final e = i + piece > last + 1 ? last + 1 : i + piece;
          served += e - i;
          yield body.sublist(i, e);
        }
      } finally {
        inFlight--;
        if (slow) _slowRunning = false;
      }
    }

    Stream<List<int>> silent() {
      // ignore: close_sinks — never closed on purpose: a dead socket.
      late final StreamController<List<int>> c;
      c = StreamController<List<int>>(onCancel: () {
        inFlight--;
      });
      inFlight++;
      () async {
        for (var i = from; i < from + (last - from) ~/ 2; i += piece) {
          await Future<void>.delayed(Duration.zero);
          if (c.isClosed || !c.hasListener) return;
          served += piece;
          c.add(body.sublist(i, i + piece));
        }
        // ...and then nothing, for ever.
      }();
      return c.stream;
    }

    final stall = stallAt == from;
    if (stall) stallAt = null;
    final n = last - from + 1;
    return http.StreamedResponse(
      stall ? silent() : pieces(),
      status,
      contentLength: n,
      headers: <String, String>{
        'content-length': '$n',
        if (status == 206) 'content-range': 'bytes $from-$last/${body.length}',
        'accept-ranges': 'bytes',
      },
    );
  }
}

const _key = 0x5A;
int transforms = 0;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    transforms = 0;
    ForegroundStream.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('throughput');
    PathProviderPlatform.instance = _Paths(temp.path);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // A stand-in cipher: XOR, counted. Addressable by offset like CTR, which
    // is the property the batching relies on.
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_crypto'), (call) async {
      switch (call.method) {
        case 'selfTest':
          return true;
        case 'newIv':
          return base64Encode(List<int>.filled(16, 7));
        case 'transform':
          transforms++;
          final bytes = (call.arguments as Map)['bytes'] as Uint8List;
          return Uint8List.fromList([for (final b in bytes) b ^ _key]);
      }
      return null;
    });
    m.setMockMethodCallHandler(
        const MethodChannel('mx_clone/offline_service'), (_) async => null);
    // Plenty of room on the "phone".
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
        (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  const film = VideoContent(id: 'f', title: 'Film', category: ContentCategory.movies);

  Uint8List body(int n) => Uint8List.fromList([for (var i = 0; i < n; i++) (i * 31 + 7) & 0xff]);

  test('a 2 MB film in 4 KB pieces: a handful of cipher calls, not five hundred', () async {
    final data = body(2 * 1024 * 1024);
    final library = OfflineLibrary();
    final d = OfflineDownloader(_Repo(), library, httpClient: _Chunky(data));
    final events = <String>[];
    final item = await d.download(
        content: film,
        source: const MediaRef(provider: 'url', locator: 'x'),
        onProgress: (p) => events.add('${p.received}/${p.total} err=${p.error} q=${p.queued} w=${p.waitingForNetwork}'));
    expect(item, isNotNull, reason: events.take(6).join(' | '));
    // 2 MB / 512 KB = 4, plus at most one remainder. It was one per piece:
    // 512 round trips across the platform channel for this one file.
    expect(transforms, lessThanOrEqualTo(5), reason: 'per-chunk ciphering is back: $transforms calls');

    // And the file is exactly right: undo the stand-in cipher on everything
    // but the 32-byte trailer and compare.
    final onDisk = await File(item!.path).readAsBytes();
    final sealedBody = onDisk.sublist(0, onDisk.length - 32);
    expect(sealedBody.length, data.length);
    final plain = Uint8List.fromList([for (final b in sealedBody) b ^ _key]);
    expect(plain, data);
  });

  test('pacing: the delay that holds a download to the yield rate', () {
    // 384 KB moved in half a second at a 192 KB/s cap: wait the other 1.5 s.
    expect(
      ForegroundStream.paceDelay(
          bytes: 384 * 1024, elapsed: const Duration(milliseconds: 500)),
      const Duration(milliseconds: 1500),
    );
    // Already slower than the cap: no wait.
    expect(
      ForegroundStream.paceDelay(bytes: 100 * 1024, elapsed: const Duration(seconds: 2)),
      Duration.zero,
    );
  });

  test('while a film streams, a download yields — and says so', () async {
    final data = body(1024 * 1024);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(), httpClient: _Chunky(data));
    ForegroundStream.touch(); // a film is playing from the network
    final seen = <OfflineProgress>[];
    final t0 = DateTime.now();
    // Keep the "watching" signal alive for the length of the download.
    final keepAlive = Timer.periodic(
        const Duration(milliseconds: 200), (_) => ForegroundStream.touch());
    try {
      await d.download(
        content: film,
        source: const MediaRef(provider: 'url', locator: 'x'),
        onProgress: seen.add,
      );
    } finally {
      keepAlive.cancel();
    }
    final took = DateTime.now().difference(t0);
    // 1 MB at 192 KB/s is over five seconds; unthrottled it is milliseconds.
    // The first half-megabyte goes before the pace can bite, so at least ~2 s.
    expect(took, greaterThan(const Duration(seconds: 2)));
    expect(seen.any((p) => p.yielding), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ─── SEVERAL CONNECTIONS (RangedFetch) ─────────────────────────────────

  const source = MediaRef(provider: 'url', locator: 'x');
  const part = 64 * 1024;

  Future<void> expectExact(OfflineItem? item, Uint8List data, List<String> log) async {
    expect(item, isNotNull, reason: log.take(8).join(' | '));
    final onDisk = await File(item!.path).readAsBytes();
    final sealedBody = onDisk.sublist(0, onDisk.length - 32);
    expect(sealedBody.length, data.length);
    expect(Uint8List.fromList([for (final b in sealedBody) b ^ _key]), data,
        reason: 'parts arrived out of order or with a hole');
  }

  test('a large film comes down over several connections, in order, paid for once',
      () async {
    final data = body(1024 * 1024); // 16 parts of 64 KB
    final net = _Chunky(data);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    final log = <String>[];
    final item = await d.download(
        content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    await expectExact(item, data, log);
    expect(net.maxInFlight, 3, reason: 'one connection at a time: not split');
    // The only cost: what was in flight on the first response when it closed.
    expect(net.served, lessThanOrEqualTo(data.length + 2 * _Chunky.piece));
  });

  test('a server that answers a range with the whole file: back to one connection',
      () async {
    final data = body(1024 * 1024);
    final net = _Chunky(data, ignoreBoundedRanges: true);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    final log = <String>[];
    final item = await d.download(
        content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    await expectExact(item, data, log);
    // Refused once, and not asked again: nowhere near twice the film.
    expect(net.served, lessThan(data.length * 13 ~/ 10));
  });

  test('a lane that drops mid-part costs a retry, not the film', () async {
    final data = body(1024 * 1024);
    final net = _Chunky(data, failPartAt: 5 * part);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    final log = <String>[];
    final item = await d.download(
        content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    await expectExact(item, data, log);
    expect(net.failPartAt, isNull, reason: 'the failure never happened');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('while a film streams, the download narrows to one connection', () async {
    final data = body(1024 * 1024);
    final net = _Chunky(data);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    ForegroundStream.touch();
    final keepAlive = Timer.periodic(
        const Duration(milliseconds: 200), (_) => ForegroundStream.touch());
    final log = <String>[];
    OfflineItem? item;
    try {
      item = await d.download(
          content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    } finally {
      keepAlive.cancel();
    }
    await expectExact(item, data, log);
    expect(net.maxInFlight, 1);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('one slow lane does not hold the others up', () async {
    final data = body(1024 * 1024);
    final net = _Chunky(data, slowPartAt: part); // the first part after the head
    final head = (await net.send(http.Request('GET', Uri.parse('https://media.test/f')))).stream;
    final out = BytesBuilder();
    await for (final c in RangedFetch.ordered(
        client: net,
        url: Uri.parse('https://media.test/f'),
        head: head,
        start: 0,
        total: data.length,
        partBytes: part,
        lanes: 3)) {
      out.add(c);
    }
    expect(out.takeBytes(), data);
    // While it lagged, the other lanes kept starting parts — up to the window.
    expect(net.startedWhileSlow, greaterThanOrEqualTo(3));
    expect(net.maxInFlight, lessThanOrEqualTo(3));
  });

  test('Content-Range is read strictly', () {
    expect(parseContentRange('bytes 200-1023/146515'),
        (start: 200, end: 1023, total: 146515));
    expect(parseContentRange('bytes 0-9/*'), (start: 0, end: 9, total: null));
    expect(parseContentRange('bytes */146515'), isNull);
    expect(parseContentRange(null), isNull);
  });

  for (final lanes in const [1, 3]) {
    test('a connection that goes silent is dropped and the film finishes ($lanes lane${lanes == 1 ? '' : 's'})',
        () async {
      final data = body(1024 * 1024);
      // A resume-shaped stall for one lane; mid-film for the other.
      final net = _Chunky(data, stallAt: lanes == 1 ? 0 : 6 * part);
      final d = OfflineDownloader(_Repo(), OfflineLibrary(),
          httpClient: net,
          lanes: lanes,
          partBytes: part,
          stallAfter: const Duration(milliseconds: 300));
      final log = <String>[];
      final item = await d
          .download(content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'))
          .timeout(const Duration(seconds: 30));
      await expectExact(item, data, log);
      expect(net.stallAt, isNull, reason: 'the stall never happened');
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('the viewer starts streaming mid-download: no more parts are asked for', () async {
    final data = body(2 * 1024 * 1024);
    // About 0.8 MB/s a lane: the film takes most of a second unhindered.
    final net = _Chunky(data, pieceDelay: const Duration(milliseconds: 5));
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    Timer? keepAlive;
    int? requestsThen; // requests made once they had been watching a moment
    Timer(const Duration(milliseconds: 150), () {
      ForegroundStream.touch();
      keepAlive = Timer.periodic(
          const Duration(milliseconds: 200), (_) => ForegroundStream.touch());
    });
    // The parts already on their way have landed by now.
    Timer(const Duration(milliseconds: 500), () => requestsThen = net.requests);
    final log = <String>[];
    final item = await d.download(
        content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    keepAlive?.cancel();
    await expectExact(item, data, log);
    expect(requestsThen, isNotNull, reason: 'finished before the viewer started');
    // At most the one paced single-connection pass — no more parts racing
    // the film for the line.
    expect(net.requests - requestsThen!, lessThanOrEqualTo(1),
        reason: 'parts kept being fetched while the viewer was streaming');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the viewer stops streaming: the download splits again', () async {
    final data = body(2 * 1024 * 1024);
    final net = _Chunky(data);
    final d = OfflineDownloader(_Repo(), OfflineLibrary(),
        httpClient: net, lanes: 3, partBytes: part);
    ForegroundStream.touch();
    final keepAlive = Timer.periodic(
        const Duration(milliseconds: 200), (_) => ForegroundStream.touch());
    Timer(const Duration(milliseconds: 1500), () {
      keepAlive.cancel();
      ForegroundStream.reset(); // the film closed
    });
    final log = <String>[];
    final item = await d.download(
        content: film, source: source, onProgress: (p) => log.add('${p.received} ${p.error}'));
    keepAlive.cancel();
    await expectExact(item, data, log);
    expect(net.maxInFlight, 3, reason: 'stayed on one connection after the film closed');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
