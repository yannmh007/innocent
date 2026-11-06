/// Media seal v1 in plain Dart, for tests only: AES-256, GCM and HKDF-SHA256
/// written out, so the unseal gateway and the stream proxy are tested
/// against real sealed objects — the same bytes the shared vectors pin
/// (test/fixtures/media_seal_vectors.json, which Tink opens).
///
/// SLOW AND UNHARDENED ON PURPOSE: table-free AES and a bit-by-bit GHASH.
/// Never imported by the app; on a phone the platform's AES-GCM opens
/// (MediaSeal.kt, tested in tool/sealjvm).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal.dart';
import 'package:innocent/features/video_hub/data/seal/media_seal_layout.dart';

// ── AES-256, forward cipher only (CTR and GCM need no other) ─────────────

final Uint8List _sbox = _makeSbox();

Uint8List _makeSbox() {
  final s = Uint8List(256);
  var p = 1, q = 1;
  do {
    p = p ^ ((p << 1) & 0xff) ^ ((p & 0x80) != 0 ? 0x1b : 0);
    q ^= q << 1;
    q ^= q << 2;
    q ^= q << 4;
    q &= 0xff;
    if ((q & 0x80) != 0) q ^= 0x09;
    final x = q ^ _rotl8(q, 1) ^ _rotl8(q, 2) ^ _rotl8(q, 3) ^ _rotl8(q, 4);
    s[p] = (x ^ 0x63) & 0xff;
  } while (p != 1);
  s[0] = 0x63;
  return s;
}

int _rotl8(int x, int n) => ((x << n) | (x >> (8 - n))) & 0xff;
int _xt(int b) => ((b << 1) ^ ((b & 0x80) != 0 ? 0x1b : 0)) & 0xff;

class Aes256 {
  Aes256(Uint8List key) : _rk = _expand(key);

  final Uint8List _rk; // 15 round keys, 240 bytes

  static Uint8List _expand(Uint8List key) {
    if (key.length != 32) throw ArgumentError('AES-256 key is 32 bytes');
    final w = Uint8List(240)..setRange(0, 32, key);
    var rcon = 1;
    for (var i = 32; i < 240; i += 4) {
      var t0 = w[i - 4], t1 = w[i - 3], t2 = w[i - 2], t3 = w[i - 1];
      if (i % 32 == 0) {
        final u = t0;
        t0 = _sbox[t1] ^ rcon;
        t1 = _sbox[t2];
        t2 = _sbox[t3];
        t3 = _sbox[u];
        rcon = _xt(rcon);
      } else if (i % 32 == 16) {
        t0 = _sbox[t0];
        t1 = _sbox[t1];
        t2 = _sbox[t2];
        t3 = _sbox[t3];
      }
      w[i] = w[i - 32] ^ t0;
      w[i + 1] = w[i - 31] ^ t1;
      w[i + 2] = w[i - 30] ^ t2;
      w[i + 3] = w[i - 29] ^ t3;
    }
    return w;
  }

  Uint8List encryptBlock(Uint8List input) {
    final s = Uint8List.fromList(input);
    for (var i = 0; i < 16; i++) {
      s[i] ^= _rk[i];
    }
    final t = Uint8List(16);
    for (var round = 1; round <= 14; round++) {
      for (var i = 0; i < 16; i++) {
        s[i] = _sbox[s[i]];
      }
      // ShiftRows: row r moves left by r (column-major state).
      for (var c = 0; c < 4; c++) {
        for (var r = 0; r < 4; r++) {
          t[4 * c + r] = s[4 * ((c + r) % 4) + r];
        }
      }
      if (round != 14) {
        for (var c = 0; c < 4; c++) {
          final a0 = t[4 * c], a1 = t[4 * c + 1], a2 = t[4 * c + 2], a3 = t[4 * c + 3];
          final all = a0 ^ a1 ^ a2 ^ a3;
          s[4 * c] = a0 ^ all ^ _xt(a0 ^ a1);
          s[4 * c + 1] = a1 ^ all ^ _xt(a1 ^ a2);
          s[4 * c + 2] = a2 ^ all ^ _xt(a2 ^ a3);
          s[4 * c + 3] = a3 ^ all ^ _xt(a3 ^ a0);
        }
      } else {
        s.setAll(0, t);
      }
      for (var i = 0; i < 16; i++) {
        s[i] ^= _rk[16 * round + i];
      }
    }
    return s;
  }
}

// ── GCM with a 96-bit nonce ───────────────────────────────────────────────

class _Gf {
  _Gf(this.hi, this.lo);
  int hi, lo;
}

_Gf _load(Uint8List b, int off) {
  var hi = 0, lo = 0;
  for (var i = 0; i < 8; i++) {
    hi = (hi << 8) | b[off + i];
    lo = (lo << 8) | b[off + 8 + i];
  }
  return _Gf(hi, lo);
}

/// X · Y in GF(2^128), GCM's bit order (SP 800-38D, algorithm 1).
_Gf _mul(_Gf x, _Gf y) {
  var zh = 0, zl = 0, vh = y.hi, vl = y.lo;
  for (var i = 0; i < 128; i++) {
    final bit = i < 64 ? (x.hi >>> (63 - i)) & 1 : (x.lo >>> (127 - i)) & 1;
    if (bit == 1) {
      zh ^= vh;
      zl ^= vl;
    }
    final lsb = vl & 1;
    vl = (vl >>> 1) | ((vh & 1) << 63);
    vh = vh >>> 1;
    if (lsb == 1) vh ^= 0xE100000000000000;
  }
  return _Gf(zh, zl);
}

class AesGcm {
  AesGcm(Uint8List key) : _aes = Aes256(key) {
    _h = _load(_aes.encryptBlock(Uint8List(16)), 0);
  }

  final Aes256 _aes;
  late final _Gf _h;

  Uint8List _counter(Uint8List nonce, int n) {
    final c = Uint8List(16)..setRange(0, 12, nonce);
    ByteData.sublistView(c).setUint32(12, n);
    return c;
  }

  Uint8List _ctr(Uint8List nonce, Uint8List data) {
    final out = Uint8List(data.length);
    for (var off = 0, n = 2; off < data.length; off += 16, n++) {
      final ks = _aes.encryptBlock(_counter(nonce, n));
      final m = data.length - off < 16 ? data.length - off : 16;
      for (var i = 0; i < m; i++) {
        out[off + i] = data[off + i] ^ ks[i];
      }
    }
    return out;
  }

  Uint8List _tag(Uint8List nonce, Uint8List ct) {
    // No AAD here: media seal binds the dek_id through the key (HKDF info).
    final y = _Gf(0, 0);
    void absorb(Uint8List b, int off, int len) {
      final block = Uint8List(16)..setRange(0, len, b, off);
      final x = _load(block, 0);
      final r = _mul(_Gf(y.hi ^ x.hi, y.lo ^ x.lo), _h);
      y.hi = r.hi;
      y.lo = r.lo;
    }

    for (var off = 0; off < ct.length; off += 16) {
      absorb(ct, off, ct.length - off < 16 ? ct.length - off : 16);
    }
    final lens = Uint8List(16);
    ByteData.sublistView(lens).setUint64(8, ct.length * 8);
    absorb(lens, 0, 16);
    final s = Uint8List(16);
    final bd = ByteData.sublistView(s);
    bd.setInt64(0, y.hi);
    bd.setInt64(8, y.lo);
    final ek = _aes.encryptBlock(_counter(nonce, 1));
    for (var i = 0; i < 16; i++) {
      s[i] ^= ek[i];
    }
    return s;
  }

  Uint8List seal(Uint8List nonce, Uint8List plain) {
    final ct = _ctr(nonce, plain);
    return Uint8List.fromList([...ct, ..._tag(nonce, ct)]);
  }

  /// Null when the tag does not match.
  Uint8List? open(Uint8List nonce, Uint8List sealed) {
    if (sealed.length < 16) return null;
    final ct = Uint8List.sublistView(sealed, 0, sealed.length - 16);
    final want = _tag(nonce, ct);
    var diff = 0;
    for (var i = 0; i < 16; i++) {
      diff |= want[i] ^ sealed[sealed.length - 16 + i];
    }
    return diff == 0 ? _ctr(nonce, ct) : null;
  }
}

// ── media seal v1 ─────────────────────────────────────────────────────────

Uint8List aadFor(String dekId) => Uint8List.fromList(utf8.encode('inv-media-v1|$dekId'));

Uint8List deriveKey(Uint8List dek, Uint8List salt, Uint8List aad) {
  final prk = Hmac(sha256, salt).convert(dek).bytes;
  return Uint8List.fromList(Hmac(sha256, prk).convert([...aad, 1]).bytes);
}

Uint8List nonceFor(Uint8List prefix, int i, bool last) {
  final n = Uint8List(12)..setRange(0, 7, prefix);
  ByteData.sublistView(n).setUint32(7, i);
  n[11] = last ? 1 : 0;
  return n;
}

/// The whole object, sealed as tool/media_seal.py seals it.
Uint8List sealObject(Uint8List dek, String dekId, Uint8List plain, {required Uint8List salt, required Uint8List prefix}) {
  final gcm = AesGcm(deriveKey(dek, salt, aadFor(dekId)));
  final count = MediaSealLayout.segmentCount(plain.length);
  final out = BytesBuilder(copy: false)
    ..addByte(MediaSealLayout.header)
    ..add(salt)
    ..add(prefix);
  for (var i = 0; i < count; i++) {
    final p0 = MediaSealLayout.plainStart(i);
    final p1 = i + 1 < count ? MediaSealLayout.plainStart(i + 1) : plain.length;
    out.add(gcm.seal(nonceFor(prefix, i, i == count - 1), Uint8List.sublistView(plain, p0, p1)));
  }
  return out.takeBytes();
}

/// The plaintext pattern the shared vectors use: SHA-256 of "seed:i", end
/// to end.
Uint8List vectorPlain(int n, String seed) {
  final out = BytesBuilder(copy: false);
  for (var i = 0; out.length < n; i++) {
    out.add(sha256.convert(utf8.encode('$seed:$i')).bytes);
  }
  return Uint8List.sublistView(out.takeBytes(), 0, n);
}

Uint8List unhex(String h) =>
    Uint8List.fromList([for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)]);

/// [SealCipher] for tests: DEKs registered over "TLS" (base64), runs opened
/// by [AesGcm]. Counts its calls, and can be told to refuse.
class TestSealCipher implements SealCipher {
  final Map<String, Uint8List> _deks = <String, Uint8List>{};
  int registers = 0, runs = 0, segments = 0;
  bool refuseRegister = false;

  @override
  Future<bool> register(SealGrant seal) async {
    registers++;
    if (refuseRegister || seal.wrap != 'tls') return false;
    _deks[seal.dekId] = base64Decode(seal.dek);
    return true;
  }

  @override
  Future<Uint8List?> openRun({
    required String dekId,
    required Uint8List header,
    required int plainTotal,
    required int first,
    required Uint8List sealed,
  }) async {
    runs++;
    final dek = _deks[dekId];
    if (dek == null || header.length != MediaSealLayout.header || header[0] != MediaSealLayout.header) return null;
    final gcm = AesGcm(deriveKey(dek, Uint8List.sublistView(header, 1, 33), aadFor(dekId)));
    final prefix = Uint8List.sublistView(header, 33, 40);
    final count = MediaSealLayout.segmentCount(plainTotal);
    final out = BytesBuilder(copy: false);
    var at = 0;
    for (var i = first; at < sealed.length; i++) {
      if (i >= count) return null;
      final end = i + 1 < count ? MediaSealLayout.sealedStart(i + 1) : MediaSealLayout.sealedSize(plainTotal);
      final len = end - MediaSealLayout.sealedStart(i);
      if (at + len > sealed.length) return null;
      final p = gcm.open(nonceFor(prefix, i, i == count - 1), Uint8List.sublistView(sealed, at, at + len));
      if (p == null) return null;
      out.add(p);
      at += len;
      segments++;
    }
    return out.takeBytes();
  }

  int wholes = 0;

  @override
  Future<Uint8List?> openWhole({required SealGrant seal, required Uint8List sealed}) async {
    wholes++;
    if (seal.wrap != 'tls' || sealed.length != seal.sealedSize || sealed.length < MediaSealLayout.header) {
      return null;
    }
    final header = Uint8List.sublistView(sealed, 0, MediaSealLayout.header);
    if (header[0] != MediaSealLayout.header) return null;
    final gcm = AesGcm(deriveKey(base64Decode(seal.dek), Uint8List.sublistView(header, 1, 33), aadFor(seal.dekId)));
    final prefix = Uint8List.sublistView(header, 33, 40);
    final count = MediaSealLayout.segmentCount(seal.plainSize);
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < count; i++) {
      final a = MediaSealLayout.sealedStart(i);
      final b = i + 1 < count ? MediaSealLayout.sealedStart(i + 1) : seal.sealedSize;
      final p = gcm.open(nonceFor(prefix, i, i == count - 1), Uint8List.sublistView(sealed, a, b));
      if (p == null) return null;
      out.add(p);
    }
    return out.takeBytes();
  }
}
