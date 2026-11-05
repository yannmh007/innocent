// Sealed posters and photos (docs/MEDIA_ENCRYPTION.md §6, images): kept on
// the phone as they came from R2, opened with the DEK their row carried, and
// decoded in memory. A file that is cut, altered or not the sealed size never
// shows; a sealed URL is never drawn from the network, where its bytes are
// noise.

import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/api/api_content_repository.dart';
import 'package:innocent/features/video_hub/data/poster_cache.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal_layout.dart';
import 'package:innocent/features/video_hub/data/seal/sealed_image.dart';
import 'package:innocent/features/video_hub/domain/content_repository.dart';
import 'package:innocent/features/video_hub/domain/video_content.dart';
import 'package:innocent/features/video_hub/presentation/video_hub_provider.dart';
import 'package:innocent/features/video_hub/presentation/widgets/poster_image.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'support/seal_test_cipher.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getApplicationCachePath() async => '$root/cache';
}

/// Resolves a poster ref to its locator, as the API repository does.
class _Repo implements ContentRepository {
  @override
  String? resolveImageUrlSync(MediaRef ref) => ref.locator;
  @override
  Future<String?> resolveImageUrl(MediaRef ref) async => ref.locator;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// A 1×1 PNG.
final Uint8List _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final rnd = Random(11);
  Uint8List bytes(int n) => Uint8List.fromList(List<int>.generate(n, (_) => rnd.nextInt(256)));
  late Directory temp;
  late TestSealCipher cipher;

  (Uint8List, SealGrant) sealImage(Uint8List plain, String dekId) {
    final dek = bytes(32);
    final sealed = sealObject(dek, dekId, plain, salt: bytes(32), prefix: bytes(7));
    return (
      sealed,
      SealGrant(
        dekId: dekId,
        plainSize: plain.length,
        sealedSize: sealed.length,
        wrap: 'tls',
        dek: base64Encode(dek),
        header: Uint8List.sublistView(sealed, 0, MediaSealLayout.header),
      ),
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sealimg');
    PathProviderPlatform.instance = _Paths(temp.path);
    cipher = TestSealCipher();
    SealedFileImage.cipher = cipher;
    SealedUrls.reset();
  });

  tearDown(() async {
    SealedFileImage.cipher = PlatformSealCipher.instance;
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Object> load(ImageProvider provider) async {
    final done = Future<Object>(() async {
      final stream = provider.resolve(ImageConfiguration.empty);
      final c = Completer<Object>();
      stream.addListener(ImageStreamListener(
        (info, _) => c.complete(info.image),
        onError: (e, _) => c.complete(e),
      ));
      return c.future;
    });
    return done;
  }

  test('a row\'s image is fetched from its sealed twin only with a usable seal', () {
    final (_, seal) = sealImage(_png, 'row-1');
    const plain = 'https://cdn.example/photo/a.jpg';
    const twin = 'https://cdn.example/s/00112233445566778899aabbccddeeff';
    Map<String, Object?> block({Object? url = twin, String wrap = 'tls', int? sealed}) => <String, Object?>{
          'v': 1, 'url': url, 'dek_id': seal.dekId, 'plain_size': seal.plainSize,
          'sealed_size': sealed ?? seal.sealedSize, 'wrap': wrap, 'dek': seal.dek,
          'header': base64Encode(seal.header!),
        };
    expect(ApiContentRepository.imageUrlFor(plain, block(), asks: true), twin);
    expect(SealedUrls.of(twin)?.dekId, 'row-1', reason: 'learned, so every loader opens it');
    expect(ApiContentRepository.imageUrlFor(plain, block(), asks: false), plain,
        reason: 'a build that does not open seals keeps the plain address');
    expect(ApiContentRepository.imageUrlFor(plain, null, asks: true), plain);
    expect(ApiContentRepository.imageUrlFor(plain, block(sealed: seal.sealedSize + 1), asks: true), plain,
        reason: 'sizes that disagree describe some other object');
    expect(ApiContentRepository.imageUrlFor(plain, block(wrap: 'rsa'), asks: true), plain,
        reason: 'an image key comes in the row, never wrapped for the install');
    expect(ApiContentRepository.imageUrlFor(plain, block(url: 'http://cdn.example/s/x'), asks: true), plain);
    expect(ApiContentRepository.imageUrlFor(plain, block(url: null), asks: true), plain);
    expect(ApiContentRepository.imageUrlFor(null, block(), asks: true), twin,
        reason: 'once the plain copy is gone, the twin is the only address');
  });

  testWidgets('a sealed image opens to its picture; cut, altered or another key, never',
      (tester) async {
    await tester.runAsync(() async {
      final (sealed, seal) = sealImage(_png, 'img-1');
      final file = File('${temp.path}/a')..writeAsBytesSync(sealed);
      final got = await load(SealedFileImage(file, seal));
      expect(got, isA<ui.Image>());
      expect((got as ui.Image).width, 1);
      expect(cipher.wholes, 1);

      final altered = Uint8List.fromList(sealed)..[sealed.length - 2] ^= 1;
      final f2 = File('${temp.path}/b')..writeAsBytesSync(altered);
      expect(await load(SealedFileImage(f2, seal)), isNot(isA<ui.Image>()));

      final f3 = File('${temp.path}/c')..writeAsBytesSync(Uint8List.sublistView(sealed, 0, sealed.length - 1));
      expect(await load(SealedFileImage(f3, seal)), isNot(isA<ui.Image>()));

      final (_, other) = sealImage(_png, 'img-1');
      final f4 = File('${temp.path}/d')..writeAsBytesSync(sealed);
      expect(await load(SealedFileImage(f4, other)), isNot(isA<ui.Image>()),
          reason: 'another DEK under the same id opens nothing');
      // A photo larger than one segment.
      final big = bytes(MediaSealLayout.firstPlain + MediaSealLayout.plainSegment + 5);
      final (bs, bseal) = sealImage(big, 'img-2');
      expect(await cipher.openWhole(seal: bseal, sealed: bs), big);
    });
  });

  testWidgets('a sealed poster is drawn from the sealed cache, never from the network',
      (tester) async {
    HttpOverrides.global = null;
    final (sealed, seal) = sealImage(_png, 'poster-1');
    late HttpServer server;
    var asked = 0;
    late String url;
    await tester.runAsync(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        asked++;
        req.response.headers.contentType = ContentType.binary;
        req.response.add(sealed);
        await req.response.close();
      });
      url = 'http://127.0.0.1:${server.port}/s/0123456789abcdef0123456789abcdef';
      SealedUrls.learn(url, seal);
      expect(await PosterCache.resolve(url), isNotNull);
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [contentRepositoryProvider.overrideWithValue(_Repo())],
      child: MaterialApp(
        home: SizedBox(
          width: 100,
          height: 150,
          child: PosterImage(mediaRef: MediaRef(provider: 'url', locator: url), title: 'Sintel'),
        ),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    final images = tester.widgetList<Image>(find.byType(Image)).toList();
    expect(images, isNotEmpty);
    expect(images.every((i) => i.image is SealedFileImage), isTrue,
        reason: 'the sealed file, opened — not a FileImage or a NetworkImage');
    expect(asked, 1, reason: 'fetched once, into the cache');
    await tester.runAsync(() => server.close(force: true));
  });

  testWidgets('a sealed poster the cache cannot hold is a placeholder, not the network',
      (tester) async {
    final (_, seal) = sealImage(_png, 'poster-2');
    const url = 'http://127.0.0.1:9/s/ffffffffffffffffffffffffffffffff';
    SealedUrls.learn(url, seal);
    PosterCache.enabled = false;
    addTearDown(() => PosterCache.enabled = true);
    await tester.pumpWidget(ProviderScope(
      overrides: [contentRepositoryProvider.overrideWithValue(_Repo())],
      child: const MaterialApp(
        home: SizedBox(
          width: 100,
          height: 150,
          child: PosterImage(mediaRef: MediaRef(provider: 'url', locator: url), title: 'Sintel'),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.byWidgetPredicate((w) => w is Image && w.image is NetworkImage), findsNothing);
  });
}
