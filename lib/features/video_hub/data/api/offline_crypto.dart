import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A downloaded film, kept as something only this phone can read.
///
/// ═══════════════════════════════════════════════════════════════════════
/// THE FORMAT, AND WHY THE HEADER IS AT THE END
/// ═══════════════════════════════════════════════════════════════════════
///
/// A sealed film is the ciphertext of the original object, byte for byte, with a
/// thirty-two byte trailer after it. Nothing is prepended, and that is the one
/// decision the rest of this file rests on: with no header, **the byte at
/// offset N of the film is the byte at offset N of the file**. The downloader
/// appends as the network delivers, the resume point is the file's own length,
/// and the player's range requests need no arithmetic at all.
///
/// A header at the front would have shifted every one of those by a constant,
/// and a constant that is right in four places and forgotten in the fifth is
/// a film that plays as noise.
///
/// ```
///   0                                        plainLength      +32
///   ├────────────── ciphertext ──────────────┼─── trailer ──────┤
///
///   trailer:  "MXE1" | ver | flags | 2 reserved | plainLength | iv
///             4        1     1       2            8             16
/// ```
///
/// ═══════════════════════════════════════════════════════════════════════
/// HOW A SEALED FILM IS TOLD FROM A PLAIN ONE
/// ═══════════════════════════════════════════════════════════════════════
///
/// By the magic AND by the length agreeing with what the trailer claims. Either
/// alone would be a guess; together they are a coincidence no MP4 is going to
/// have. This matters because every download made before this existed is still
/// on somebody's phone as a plain MP4, and those must keep playing — the app
/// does not get to make people download their films again.
class OfflineCrypto {
  OfflineCrypto._();

  static const MethodChannel _ch = MethodChannel('mx_clone/media_crypto');

  /// AES's block size, and so the unit a CTR offset is counted in. A partial
  /// block can only ever be the last thing in a file.
  static const int block = 16;

  static const int trailerLength = 32;

  static const List<int> _magic = <int>[0x4D, 0x58, 0x45, 0x31]; // "MXE1"
  static const int _version = 1;

  /// Whether this phone can seal at all, asked once per process.
  ///
  /// CACHED AS A NULLABLE AND NOT AS A BOOL, so "not asked yet" and "asked and
  /// refused" are different states. A false cached from a transient Keystore
  /// failure would otherwise last the life of the process.
  static bool? _able;

  static Future<bool> available() async {
    final known = _able;
    if (known != null) return known;
    try {
      final ok = await _ch.invokeMethod<bool>('selfTest') ?? false;
      _able = ok;
      return ok;
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineCrypto.available: $e');
      _able = false;
      return false;
    }
  }

  /// A fresh IV for one film. Null when the platform will not give one, which
  /// the caller treats as "download this one unsealed".
  static Future<String?> newIv() async {
    try {
      return await _ch.invokeMethod<String>('newIv');
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineCrypto.newIv: $e');
      return null;
    }
  }

  /// Ciphers [bytes] as the run that belongs at [offset] in the film.
  ///
  /// The same call in both directions — CTR is its own inverse — so there is
  /// exactly one implementation to be wrong.
  static Future<Uint8List?> transform({
    required String iv,
    required int offset,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty) return bytes;
    try {
      return await _ch.invokeMethod<Uint8List>('transform', <String, dynamic>{
        'iv': iv,
        'offset': offset,
        'bytes': bytes,
      });
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineCrypto.transform: $e');
      return null;
    }
  }

  // ── the pure part, which is where the bugs would be ────────────────────

  /// The trailer for a finished film.
  static Uint8List composeTrailer({
    required Uint8List iv,
    required int plainLength,
  }) {
    if (iv.length != block) {
      throw ArgumentError('iv must be $block bytes, got ${iv.length}');
    }
    if (plainLength < 0) throw ArgumentError('negative length');
    final out = Uint8List(trailerLength);
    out.setRange(0, 4, _magic);
    out[4] = _version;
    out[5] = 0; // flags
    ByteData.sublistView(out).setUint64(8, plainLength, Endian.big);
    out.setRange(16, 32, iv);
    return out;
  }

  /// Reads a trailer back, given the last [trailerLength] bytes of a file and
  /// the file's whole length.
  ///
  /// Null means "this is not a sealed film", which is a normal answer and not
  /// an error: it is what every download made before this feature existed says.
  static SealInfo? readTrailer(Uint8List tail, int fileLength) {
    if (tail.length != trailerLength) return null;
    for (var i = 0; i < 4; i++) {
      if (tail[i] != _magic[i]) return null;
    }
    if (tail[4] != _version) return null;
    final claimed = ByteData.sublistView(tail).getUint64(8, Endian.big);
    // THE LENGTH HAS TO AGREE. The magic alone could occur by accident in the
    // last thirty-two bytes of some file somewhere; the magic plus a length
    // that happens to equal this file's own length minus thirty-two could not.
    if (claimed != fileLength - trailerLength) return null;
    return SealInfo(
      iv: Uint8List.fromList(tail.sublist(16, 32)),
      plainLength: claimed,
    );
  }

  /// What the file on disk should be for a film of [plainLength] bytes.
  static int fileLengthFor(int plainLength, {required bool sealed}) =>
      sealed ? plainLength + trailerLength : plainLength;

  // ── the file-shaped part ───────────────────────────────────────────────

  /// Looks at a finished download and says whether it is sealed.
  static Future<SealInfo?> inspect(File file) async {
    RandomAccessFile? handle;
    try {
      final length = await file.length();
      if (length < trailerLength) return null;
      handle = await file.open();
      await handle.setPosition(length - trailerLength);
      final tail = await handle.read(trailerLength);
      return readTrailer(tail, length);
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineCrypto.inspect: $e');
      return null;
    } finally {
      try {
        await handle?.close();
      } catch (_) {}
    }
  }

  /// Reads [length] plaintext bytes from [offset] of a sealed film.
  ///
  /// Returns fewer bytes than asked for at the end of the film, and null when
  /// the read or the cipher failed — which the server answers as a short read,
  /// because that is a thing every player already knows how to survive.
  static Future<Uint8List?> readPlain(
    RandomAccessFile handle,
    SealInfo seal, {
    required int offset,
    required int length,
  }) async {
    if (offset < 0 || offset >= seal.plainLength || length <= 0) {
      return Uint8List(0);
    }
    final want = offset + length > seal.plainLength
        ? seal.plainLength - offset
        : length;
    try {
      await handle.setPosition(offset);
      final cipherBytes = await handle.read(want);
      if (cipherBytes.isEmpty) return cipherBytes;
      return await transform(
        iv: seal.ivBase64,
        offset: offset,
        bytes: cipherBytes,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('OfflineCrypto.readPlain: $e');
      return null;
    }
  }
}

/// What a sealed film's trailer says about it.
@immutable
class SealInfo {
  const SealInfo({required this.iv, required this.plainLength});

  final Uint8List iv;

  /// The length of the ORIGINAL object — which is what the shelf shows, what
  /// the player is told, and what a viewer paid data for. The file on disk is
  /// this plus the trailer.
  final int plainLength;

  String get ivBase64 => base64Encode(iv);
}
