import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/incomplete_file.dart';

/// A half-downloaded film: [size] bytes, data up to [dataEnd], zeros after —
/// the shape a preallocating download manager leaves behind.
Future<File> _film(Directory dir, String name, int size, int dataEnd) async {
  final f = File('${dir.path}/$name');
  final raf = await f.open(mode: FileMode.write);
  final rnd = Random(7);
  const chunk = 1 << 20;
  var written = 0;
  while (written < size) {
    final n = min(chunk, size - written);
    final bytes = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (written + i < dataEnd) bytes[i] = 1 + rnd.nextInt(255);
    }
    await raf.writeFrom(bytes);
    written += n;
  }
  await raf.close();
  return f;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('incomplete'));
  tearDown(() async => dir.delete(recursive: true));

  test('a complete file is complete, after one read', () async {
    final f = await _film(dir, 'full.mkv', 20 << 20, 20 << 20);
    expect(await IncompleteFileProbe.probe(f.path), isNull);
  });

  test('a preallocated, half-downloaded file is found, and where it stops', () async {
    const size = 40 << 20;
    const dataEnd = 31 * 1024 * 1024 + 12345;
    final f = await _film(dir, 'half.mp4', size, dataEnd);
    final r = await IncompleteFileProbe.probe(f.path);
    expect(r, isNotNull);
    // Within one block of the true boundary, never past it by more.
    expect(r!.dataEnd, greaterThanOrEqualTo(dataEnd));
    expect(r.dataEnd - dataEnd, lessThan(IncompleteFileProbe.block));
    expect(r.fraction, closeTo(dataEnd / size, 0.01));
  });

  test('the playable share holds back a margin, and never goes negative', () {
    const r = IncompleteFile(size: 1000, dataEnd: 785);
    expect(r.playablePercent, closeTo(76.5, 0.001));
    expect(r.playableOf(const Duration(minutes: 100)).inSeconds, 4590);
    const tiny = IncompleteFile(size: 1000, dataEnd: 10);
    expect(tiny.playablePercent, 0);
  });

  test('a file that is zeros from the start is left to the player', () async {
    final f = await _film(dir, 'empty.mkv', 16 << 20, 0);
    expect(await IncompleteFileProbe.probe(f.path), isNull);
  });

  test('small files and non-paths are not probed', () async {
    final f = await _film(dir, 'clip.mp4', 1 << 20, 1000);
    expect(await IncompleteFileProbe.probe(f.path), isNull);
    expect(IncompleteFileProbe.localPathOf('content://media/x'), isNull);
    expect(IncompleteFileProbe.localPathOf('https://a/b.mp4'), isNull);
    expect(IncompleteFileProbe.localPathOf('sealed:///a'), isNull);
    expect(IncompleteFileProbe.localPathOf('/sdcard/a.mp4'), '/sdcard/a.mp4');
    expect(IncompleteFileProbe.localPathOf('file:///sdcard/a%20b.mp4'),
        '/sdcard/a b.mp4');
    expect(await IncompleteFileProbe.probe('/no/such/file.mp4'), isNull);
  });

  test('isAllZero looks at every byte, including the tail', () {
    final b = Uint8List(64 * 1024 + 3);
    expect(IncompleteFileProbe.isAllZero(b), isTrue);
    b[b.length - 1] = 1;
    expect(IncompleteFileProbe.isAllZero(b), isFalse);
    b[b.length - 1] = 0;
    b[9] = 1;
    expect(IncompleteFileProbe.isAllZero(b), isFalse);
  });
}
