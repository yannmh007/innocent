import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/file_transfer/download_isolate.dart';
import 'package:innocent/core/services/file_transfer/file_receiver_service.dart';
import 'package:innocent/core/services/file_transfer/file_transfer_service.dart';

/// How fast the APP can move a file when the link is not the limit: the
/// real sender server and the real receiver engine (in its isolate, with the
/// parallel ranges it uses on a phone) over loopback. Whatever this says is
/// the ceiling the software puts on a transfer; the radio decides the rest.
///
///   BENCH_MB=1024 flutter test test_bench/transfer_speed_bench.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  test('1 GB, sender → receiver', () async {
    final mb = int.tryParse(Platform.environment['BENCH_MB'] ?? '') ?? 1024;
    final tmp = await Directory.systemTemp.createTemp('bench');
    final src = File('${tmp.path}/big.mkv');
    final r = Random(7);
    final block = List<int>.generate(1 << 20, (_) => r.nextInt(256));
    final sink = src.openWrite();
    for (var i = 0; i < mb; i++) {
      sink.add(block);
    }
    await sink.close();
    final size = src.lengthSync();

    final svc = FileTransferService();
    final s = await svc.start(
        [SharedFile(id: '0', path: src.path, displayName: 'big.mkv', sizeBytes: size)],
        preferredIp: '127.0.0.1');
    final base = 'http://127.0.0.1:${s.port}/${svc.token}';
    final w = await IsolateDownloader.spawn();
    final segs = FileReceiverService.segmentsFor(size);
    final sw = Stopwatch()..start();
    await w!.run(
        TransferJob(baseUrl: base, index: 0, partPath: '${tmp.path}/out.part', size: size, segments: segs),
        (_, __, ___, ____) {});
    sw.stop();
    final got = File('${tmp.path}/out.part').lengthSync();
    expect(got, size);
    final secs = sw.elapsedMilliseconds / 1000;
    // ignore: avoid_print
    print('BENCH ${mb}MB in ${secs.toStringAsFixed(1)} s = '
        '${(size / secs / 1e6).toStringAsFixed(1)} MB/s with $segs streams');
    await w.dispose();
    await svc.stop();
    await tmp.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}
