import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/data/cache/stream_cache_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'stream_cache_server_test.dart' as plain;

/// The stream cache, sealed (StreamCacheStore: "SEALED, WITH THE DOWNLOADS'
/// CIPHER").
///
/// FIRST, EVERY STREAM CACHE TEST AGAIN, WITH THE CIPHER ON: byte-exact
/// films, seeks, hang-ups, renewals, the second play from the phone. A
/// sealed run read back one byte off its place in the film is a film that
/// plays as noise, and those tests are what would see it.
///
/// Then what only sealing has: nothing on disk is the film's bytes; a run
/// is readable from any byte; a sealed run whose IV is gone is deleted
/// rather than served; what was cached plain before still plays, and
/// stays plain; and a cipher that fails stops the caching, never the film.
///
/// The phone's cipher is AES-CTR in Kotlin (MediaCrypto); here it is a
/// stand-in with the property that matters — each byte is changed by a
/// function of the IV and of its own place in the film, and the same call
/// undoes it.
bool _cipherFails = false;
int _transforms = 0;

Uint8List _keystreamXor(Uint8List iv, int offset, Uint8List bytes) {
  final out = Uint8List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    final o = offset + i;
    out[i] = bytes[i] ^ ((iv[o % 16] + o * 13 + (o >> 9) + 1) & 0xFF);
  }
  return out;
}

void _fakeCipher() {
  final rnd = Random(5);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/media_crypto'), (call) async {
    switch (call.method) {
      case 'selfTest':
        return true;
      case 'newIv':
        return base64Encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
      case 'transform':
        if (_cipherFails) return null;
        _transforms++;
        final a = call.arguments as Map<Object?, Object?>;
        return _keystreamXor(base64Decode(a['iv']! as String), (a['offset']! as num).toInt(),
            a['bytes']! as Uint8List);
    }
    return null;
  });
}

Future<List<File>> _runs(Directory root) async => [
      await for (final f in root.list(recursive: true))
        if (f is File && f.path.endsWith('.bin')) f,
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fakeCipher);

  group('every stream cache test, sealed', () {
    plain.main();
    // Inside the group, before its tearDownAll takes the folder away.
    test('the films those tests played are on disk sealed, and only sealed', () async {
      final runs = await _runs(await getApplicationSupportDirectory());
      expect(runs, isNotEmpty);
      for (final f in runs) {
        expect(p.basename(f.path), startsWith('s'), reason: '${f.path} is a plain run');
        expect(File(p.join(f.parent.path, 'seal.iv')).existsSync(), isTrue);
      }
    });
  });

  group('sealed', () {
    final store = StreamCacheStore.instance;
    final film = Uint8List.fromList(List<int>.generate(3 * 1024 * 1024 + 77, (i) => (i * 7 + (i >> 11)) & 0xFF));

    setUp(() => _cipherFails = false);

    Future<CacheEntry> cache(String id, List<(int, int)> stretches) async {
      final e = await store.entryFor(id, total: film.length, label: id);
      for (final (from, to) in stretches) {
        final w = (await store.openWriter(e, from))!;
        // In pieces of uneven size, as a network delivers them.
        var at = from;
        var n = 1;
        while (at < to) {
          final end = min(at + 1000 * n + 333, to);
          await w.write(film.sublist(at, end));
          at = end;
          n = n % 37 + 1;
        }
        await w.close();
      }
      return e;
    }

    Future<Uint8List> read(CacheEntry e, CachePart part, int from, int to) async {
      final out = BytesBuilder();
      await for (final c in e.read(part, from, to)) {
        out.add(c);
      }
      return out.takeBytes();
    }

    test('nothing on disk is the film: each run is the film ciphered at its own place', () async {
      final e = await cache('sealed-1', [(0, 1000000), (1500001, film.length)]);
      expect(e.iv, isNotNull);
      final iv = base64Decode(e.iv!);
      for (final part in e.parts) {
        expect(part.sealed, isTrue);
        final disk = await part.file.readAsBytes();
        expect(disk, _keystreamXor(iv, part.start, film.sublist(part.start, part.end)));
        expect(disk, isNot(film.sublist(part.start, part.end)));
      }
    });

    test('a run reads back exactly, from any byte, unaligned', () async {
      final e = await cache('sealed-2', [(0, 1000000), (1500001, film.length)]);
      for (final (start, from, to) in [(0, 0, 1000000), (0, 17, 999983), (1500001, 3, 100003), (1500001, 5, film.length - 1500001)]) {
        final part = e.partAt(start)!;
        expect(await read(e, part, from, to), film.sublist(start + from, start + to),
            reason: 'run at $start, $from..$to');
      }
    });

    test('a run extended later is still one film: the new bytes ciphered where they land', () async {
      final e = await cache('sealed-3', [(0, 123457)]);
      final w = (await store.openWriter(e, 123457))!;
      await w.write(film.sublist(123457, 400000));
      await w.close();
      final part = e.partAt(0)!;
      expect(part.end, 400000);
      expect(await read(e, part, 0, 400000), film.sublist(0, 400000));
    });

    test('after a restart it reads the same', () async {
      await cache('sealed-4', [(0, 777777), (2000000, film.length)]);
      await store.reloadFromDisk();
      final e = await store.entryFor('sealed-4', total: film.length);
      expect(e.parts.length, 2);
      expect(await read(e, e.partAt(0)!, 0, 777777), film.sublist(0, 777777));
      final tail = e.partAt(2000000)!;
      expect(await read(e, tail, 0, tail.length), film.sublist(2000000));
      final head = await e.readHead(e.partAt(0)!, 4096);
      expect(head, film.sublist(0, 4096), reason: 'what offline replay reads');
    });

    test('a sealed run whose IV is gone is deleted, never served', () async {
      final e = await cache('sealed-5', [(0, 50000)]);
      final dir = e.parts.first.file.parent;
      await File(p.join(dir.path, 'seal.iv')).delete();
      await store.reloadFromDisk();
      final again = await store.entryFor('sealed-5', total: film.length);
      expect(again.parts, isEmpty);
      expect((await _runs(dir)).where((f) => p.basename(f.path).startsWith('s')), isEmpty);
    });

    test('what was cached plain before still plays, and stays plain', () async {
      // An entry as 1.64.70 left it: a plain run, no seal.iv.
      final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'stream_cache', 'legacy-1'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'p0.bin')).writeAsBytes(film.sublist(0, 60000));
      await File(p.join(dir.path, 'meta.json')).writeAsString(
          jsonEncode(<String, dynamic>{'v': 1, 'total': film.length, 'label': 'old', 'used': 0}));
      await store.reloadFromDisk();
      final e = await store.entryFor('legacy-1', total: film.length);
      expect(e.iv, isNull);
      expect(await read(e, e.partAt(0)!, 0, 60000), film.sublist(0, 60000));
      final w = (await store.openWriter(e, 60000))!;
      await w.write(film.sublist(60000, 90000));
      await w.close();
      expect(await File(p.join(dir.path, 'p0.bin')).readAsBytes(), film.sublist(0, 90000));
      final w2 = (await store.openWriter(e, 100000))!;
      await w2.write(film.sublist(100000, 110000));
      await w2.close();
      expect(File(p.join(dir.path, 'p100000.bin')).existsSync(), isTrue);
    });

    test('a seal that fails writes nothing: the run ends where it was', () async {
      final e = await cache('sealed-6', [(0, 10000)]);
      final w = (await store.openWriter(e, 10000))!;
      _cipherFails = true;
      await expectLater(w.write(film.sublist(10000, 20000)), throwsA(isA<FileSystemException>()));
      await w.close();
      _cipherFails = false;
      final part = e.partAt(0)!;
      expect(part.end, 10000);
      expect(await part.file.length(), 10000);
      expect(await read(e, part, 0, 10000), film.sublist(0, 10000));
    });

    test('an unseal that fails ends the read with an error, which the server '
        'answers as a short read', () async {
      final e = await cache('sealed-7', [(0, 300000)]);
      _cipherFails = true;
      await expectLater(read(e, e.partAt(0)!, 0, 300000), throwsA(isA<FileSystemException>()));
      _cipherFails = false;
    });

    test('the cipher was really asked', () => expect(_transforms, greaterThan(100)));
  });
}
