// A sealed film downloaded (docs/MEDIA_ENCRYPTION.md §6): the downloader
// reads it through the unseal gateway, so the file on the phone is the film
// under the phone's own key exactly as before — never the sealed object's
// bytes played as noise — and a download begun on the plain twin finishes on
// the sealed object.

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:innocent/features/video_hub/data/api/offline_downloader.dart';
import 'package:innocent/features/video_hub/data/api/offline_library.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal.dart';
import 'package:innocent/features/video_hub/data/seal/unseal_gateway.dart';
import 'package:innocent/features/video_hub/domain/access.dart';
import 'package:innocent/features/video_hub/domain/content_category.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_sealed_worker.dart';
import 'support/seal_test_cipher.dart';

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

/// Grants whatever [urls] holds next (the last one again once used up).
class _Repo implements ContentRepository {
  _Repo(this.urls);
  final List<String> urls;
  int asked = 0;

  @override
  Future<PlaybackGrant> requestPlayback({
    required VideoContent content,
    required MediaRef source,
    String? deviceId,
  }) async =>
      PlaybackGrant.granted(urls[min(asked++, urls.length - 1)]);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _key = 0x5A;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late FakeWorker worker;
  late Uint8List plain;
  late SealGrant seal;
  late String sealedUrl;
  final rnd = Random(3);
  Uint8List bytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));

  setUpAll(() async {
    HttpOverrides.global = null;
    plain = bytes(1024 * 1024 + 4321);
    final dek = bytes(32);
    final sealed = sealObject(dek, 'dek-dl', plain, salt: bytes(32), prefix: bytes(7));
    worker = FakeWorker(sealed);
    sealedUrl = await worker.start();
    seal = SealGrant(
      dekId: 'dek-dl',
      plainSize: plain.length,
      sealedSize: sealed.length,
      wrap: 'tls',
      dek: base64Encode(dek),
      header: Uint8List.sublistView(sealed, 0, 40),
    );
    UnsealGateway.instance = UnsealGateway(cipher: TestSealCipher());
  });

  tearDownAll(() async {
    await UnsealGateway.instance.shutdown();
    await worker.stop();
  });

  setUp(() async {
    SealedUrls.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temp = await Directory.systemTemp.createTemp('sealdl');
    PathProviderPlatform.instance = _Paths(temp.path);
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    // The phone's own cipher, as download_throughput_test stands it in: XOR.
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_crypto'), (call) async {
      switch (call.method) {
        case 'selfTest':
          return true;
        case 'newIv':
          return base64Encode(List<int>.filled(16, 7));
        case 'transform':
          final b = (call.arguments as Map)['bytes'] as Uint8List;
          return Uint8List.fromList([for (final x in b) x ^ _key]);
      }
      return null;
    });
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/offline_service'), (_) async => null);
    m.setMockMethodCallHandler(const MethodChannel('mx_clone/media_scan'),
        (call) async => call.method == 'freeBytes' ? 64 * 1024 * 1024 * 1024 : null);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  const film = VideoContent(id: 'sealed-film', title: 'Film', category: ContentCategory.movies);

  Uint8List unXor(Uint8List onDisk) {
    final body = onDisk.sublist(0, onDisk.length - 32); // the 32-byte trailer
    return Uint8List.fromList([for (final b in body) b ^ _key]);
  }

  test('a sealed film downloads as the film, kept under the phone\'s own key', () async {
    SealedUrls.learn(sealedUrl, seal);
    final d = OfflineDownloader(_Repo([sealedUrl]), OfflineLibrary(), httpClient: http.Client());
    final errs = <String?>[];
    final item = await d.download(
        content: film,
        source: const MediaRef(provider: 'url', locator: 'x'),
        onProgress: (p) => errs.add(p.error));
    expect(item, isNotNull, reason: errs.whereType<String>().join(','));
    expect(item!.bytes, plain.length, reason: 'the film\'s own size, not the sealed object\'s');
    expect(unXor(await File(item.path).readAsBytes()), plain);
  });

  test('begun on the plain twin, finished on the sealed object: one film', () async {
    final twin = FakeWorker(plain);
    final plainUrl = await twin.start();
    // The first grant is the plain twin, which dies half way; the renewal
    // is sealed.
    twin.refuse.clear();
    final repo = _Repo([plainUrl, sealedUrl]);
    SealedUrls.learn(sealedUrl, seal);
    final d = OfflineDownloader(repo, OfflineLibrary(), httpClient: _DiesAfter(http.Client(), plainUrl, 300 * 1024));
    final item = await d.download(content: film, source: const MediaRef(provider: 'url', locator: 'x'));
    expect(item, isNotNull);
    expect(repo.asked, greaterThanOrEqualTo(2), reason: 'renewed after the cut');
    expect(unXor(await File(item!.path).readAsBytes()), plain);
    await twin.stop();
  });
}

/// The plain twin's connection dies after [after] bytes, once.
class _DiesAfter extends http.BaseClient {
  _DiesAfter(this.inner, this.prefix, this.after);
  final http.Client inner;
  final String prefix;
  final int after;
  bool done = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await inner.send(request);
    if (done || !request.url.toString().startsWith(prefix)) return res;
    done = true;
    Stream<List<int>> cut() async* {
      var n = 0;
      await for (final c in res.stream) {
        if (n + c.length > after) {
          yield c.sublist(0, after - n);
          throw const SocketException('connection reset');
        }
        n += c.length;
        yield c;
      }
    }

    return http.StreamedResponse(cut(), res.statusCode, contentLength: res.contentLength, headers: res.headers);
  }
}
