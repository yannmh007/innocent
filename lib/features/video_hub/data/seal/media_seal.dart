/// Media seal v1 on the phone (docs/MEDIA_ENCRYPTION.md §5-6): what a grant
/// says about a sealed object, which granted URLs are sealed, and the
/// platform calls that open them.
///
/// THE RULE THIS FILE KEEPS. A sealed URL is never handed to a player, a
/// downloader or anything else that would read its bytes as a film: they are
/// noise without the DEK. Everything that fetches a granted URL asks
/// [SealedUrls.of] first, the way it asks StreamDoor for the install id.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'media_seal_layout.dart';

/// Whether this build asks for sealed objects (`seal: 1` in a grant
/// request). True only once every path that can be handed a granted URL
/// opens a sealed one — the stream proxy, downloads, the warm-up — because
/// once the server's SEAL_MODE is on, an app that said yes gets sealed
/// bytes. `--dart-define=MEDIA_SEAL=1` turns it on for a lab build ahead of
/// a release (the canary: only those builds ask).
const bool kAsksForSealed = bool.fromEnvironment('MEDIA_SEAL');

/// The `seal` block request-playback sends beside a URL it signed for a
/// sealed object (docs/edge/media_grant.js, `sealBlock`).
@immutable
class SealGrant {
  const SealGrant({
    required this.dekId,
    required this.plainSize,
    required this.sealedSize,
    required this.wrap,
    required this.dek,
    this.header,
  });

  /// The media_keys row; also the AAD every segment was sealed under.
  final String dekId;
  final int plainSize;
  final int sealedSize;

  /// `rsa`: [dek] is wrapped for this install's Keystore key. `tls`: the DEK
  /// itself, sent over TLS because the grant went without a device key.
  final String wrap;
  final String dek;

  /// The object's first 40 bytes (salt and nonce prefix, not secret) when
  /// the server sends them; otherwise read from the object itself.
  final Uint8List? header;

  /// Null for anything malformed. A sealed URL without a usable block is
  /// unplayable, so the caller drops it rather than guessing.
  static SealGrant? fromJson(Object? raw) {
    if (raw is! Map) return null;
    if (raw['v'] != 1) return null;
    final id = raw['dek_id'];
    final plain = raw['plain_size'];
    final sealed = raw['sealed_size'];
    final wrap = raw['wrap'];
    final dek = raw['dek'];
    if (id is! String || id.isEmpty) return null;
    if (plain is! num || sealed is! num) return null;
    if (wrap != 'rsa' && wrap != 'tls') return null;
    if (dek is! String || dek.isEmpty) return null;
    final p = plain.toInt();
    final s = sealed.toInt();
    // The two sizes must agree with the format: a block that says otherwise
    // describes some other object, and every range computed from it would
    // land in the wrong place.
    if (p < 0 || MediaSealLayout.sealedSize(p) != s) return null;
    Uint8List? header;
    final h = raw['header'];
    if (h is String && h.isNotEmpty) {
      try {
        final b = base64Decode(h);
        if (b.length != MediaSealLayout.header || b[0] != MediaSealLayout.header) return null;
        header = b;
      } on FormatException {
        return null;
      }
    }
    return SealGrant(
        dekId: id, plainSize: p, sealedSize: s, wrap: wrap as String, dek: dek, header: header);
  }
}

/// Which granted URLs are sealed objects, as the grants said.
///
/// Learned when a grant is read (ApiContentRepository), the way StreamDoor
/// learns the Worker's origin, and asked by everything that fetches a granted
/// URL. A URL carries its own short-lived token, so the map is small and
/// bounded: the oldest are let go first.
class SealedUrls {
  SealedUrls._();

  static const int _limit = 256;
  static final Map<String, SealGrant> _byUrl = <String, SealGrant>{};

  static void learn(String url, SealGrant seal) {
    _byUrl.remove(url);
    _byUrl[url] = seal;
    while (_byUrl.length > _limit) {
      _byUrl.remove(_byUrl.keys.first);
    }
  }

  /// The seal of [url], or null for a plain object (and anything unknown).
  static SealGrant? of(String? url) => url == null ? null : _byUrl[url];

  @visibleForTesting
  static void reset() => _byUrl.clear();
}

/// The platform's half: this install's key, the DEKs it holds, and opening
/// runs of segments. An interface so the unseal gateway is tested against a
/// cipher written for the test (test/support/seal_test_cipher.dart).
abstract class SealCipher {
  /// Holds [seal]'s DEK for [SealGrant.dekId]; false when it cannot (not
  /// this install's, or no Keystore).
  Future<bool> register(SealGrant seal);

  /// Segments [first].. of one object, laid end to end in [sealed], opened;
  /// null when any of them does not open.
  Future<Uint8List?> openRun({
    required String dekId,
    required Uint8List header,
    required int plainTotal,
    required int first,
    required Uint8List sealed,
  });
}

/// [SealCipher] on Android (MainActivity: `innocent/media_seal_keys`,
/// `innocent/media_seal`). Each call is null or false on any failure, never
/// an exception: the gateway reads that as "does not open", which it can
/// say plainly, where an exception would look like the network.
class PlatformSealCipher implements SealCipher {
  PlatformSealCipher._();

  static final PlatformSealCipher instance = PlatformSealCipher._();

  static const MethodChannel _keys = MethodChannel('innocent/media_seal_keys');
  static const MethodChannel _bulk = MethodChannel('innocent/media_seal');

  static Future<String?>? _deviceKey;
  static String? _deviceKeyNow;

  /// This install's public key (base64 SPKI), made the first time. Started
  /// at app start ([warmUp]); a grant asks [deviceKeyNow] and never waits.
  static Future<String?> deviceKey() => _deviceKey ??= () async {
        try {
          final k = await _keys.invokeMethod<String>('deviceKey');
          _deviceKeyNow = (k != null && k.isNotEmpty) ? k : null;
        } catch (e) {
          if (kDebugMode) debugPrint('PlatformSealCipher.deviceKey: $e');
          _deviceKeyNow = null;
        }
        return _deviceKeyNow;
      }();

  /// The key if it is ready, without waiting for it.
  static String? get deviceKeyNow => _deviceKeyNow;

  /// Makes (or reads) the device key in the background. Only for a build
  /// that asks for sealed objects: no other has a use for it.
  static void warmUp() {
    if (!kAsksForSealed) return;
    deviceKey().ignore();
  }

  @override
  Future<bool> register(SealGrant seal) async {
    try {
      return await _keys.invokeMethod<bool>('register', <String, dynamic>{
            'dek_id': seal.dekId,
            'wrap': seal.wrap,
            'dek': seal.dek,
          }) ??
          false;
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformSealCipher.register: $e');
      return false;
    }
  }

  @override
  Future<Uint8List?> openRun({
    required String dekId,
    required Uint8List header,
    required int plainTotal,
    required int first,
    required Uint8List sealed,
  }) async {
    try {
      return await _bulk.invokeMethod<Uint8List>('openRun', <String, dynamic>{
        'dek_id': dekId,
        'header': header,
        'plain': plainTotal,
        'first': first,
        'bytes': sealed,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformSealCipher.openRun: $e');
      return null;
    }
  }

  /// The DEK held for [dekId], wrapped for this install: what a download
  /// keeps beside its sealed bytes. Null without a device key.
  Future<String?> wrapForStorage(String dekId) async {
    try {
      return await _keys.invokeMethod<String>('wrapForStorage', <String, dynamic>{'dek_id': dekId});
    } catch (e) {
      if (kDebugMode) debugPrint('PlatformSealCipher.wrapForStorage: $e');
      return null;
    }
  }
}
