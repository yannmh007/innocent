import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:innocent/core/services/network/foreground_stream.dart';
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
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

/// Serves [body] in 4 KB chunks, the way a mobile socket hands it over.
class _Chunky extends http.BaseClient {
  _Chunky(this.body);
  final Uint8List body;
  static const int piece = 4096;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    var from = 0;
    final range = request.headers['Range'] ?? request.headers['range'];
    if (range != null) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
    }
    Stream<List<int>> pieces() async* {
      for (var i = from; i < body.length; i += piece) {
        yield body.sublist(i, i + piece > body.length ? body.length : i + piece);
      }
    }

    return http.StreamedResponse(
      pieces(),
      from == 0 ? 200 : 206,
      contentLength: body.length - from,
      headers: <String, String>{
        'content-length': '${body.length - from}',
        if (from > 0) 'content-range': 'bytes $from-${body.length - 1}/${body.length}',
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
    expect(transforms, lessThanOrEqualTo(5), reason: 'per-chunk ciphering is back: \$transforms calls');

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
}
