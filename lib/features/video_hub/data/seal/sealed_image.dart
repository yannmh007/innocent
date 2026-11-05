/// A sealed poster or photo on the phone's disk, shown as the picture it
/// holds (docs/MEDIA_ENCRYPTION.md §6, images).
///
/// WHAT IS ON DISK. The poster cache keeps a sealed image as it came from
/// R2 — the sealed bytes, never the picture. This reads them, has the
/// platform open the whole object with the DEK its catalogue row carried
/// (one call; the DEK is not kept), and decodes the plaintext in memory.
/// Nothing in the clear is written anywhere.
///
/// A file that is not the sealed size, or does not open, is an error the
/// widget answers with its placeholder — never a broken picture, and never
/// the network: a sealed URL fetched as an image would be noise.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'media_seal.dart';

class SealedFileImage extends ImageProvider<SealedFileImage> {
  const SealedFileImage(this.file, this.seal);

  final File file;
  final SealGrant seal;

  /// Who opens it. The platform's; tests put their own here.
  static SealCipher cipher = PlatformSealCipher.instance;

  /// Opened and decoded, and refused, since the app started: the lab's trail.
  static int opened = 0, refused = 0;

  @override
  Future<SealedFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<SealedFileImage>(this);

  @override
  ImageStreamCompleter loadImage(SealedFileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(key, decode),
        scale: 1.0,
        debugLabel: 'sealed ${key.seal.dekId}',
      );

  static Future<ui.Codec> _load(SealedFileImage key, ImageDecoderCallback decode) async {
    final sealed = await key.file.readAsBytes();
    final plain = await cipher.openWhole(seal: key.seal, sealed: sealed);
    if (plain == null || plain.length != key.seal.plainSize) {
      refused++;
      throw StateError('a sealed image that does not open');
    }
    opened++;
    return decode(await ui.ImmutableBuffer.fromUint8List(plain));
  }

  @override
  bool operator ==(Object other) =>
      other is SealedFileImage && other.file.path == file.path && other.seal.dekId == seal.dekId;

  @override
  int get hashCode => Object.hash(file.path, seal.dekId);
}
