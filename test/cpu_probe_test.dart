import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/cpu_probe.dart';

void main() {
  test('reads the name and the used ticks from a stat line', () {
    // utime 300, stime 120; a name with a space and a parenthesis in it.
    const raw = '4242 (mpv/vo (x)) S 4200 4200 0 0 -1 4194368 10 0 0 0 '
        '300 120 0 0 20 0 30 0 100 0 0';
    final s = CpuProbe.parseStat(raw)!;
    expect(s.name, 'mpv/vo (x)');
    expect(s.ticks, 420);
  });

  test('threads with the same job are folded together', () {
    expect(CpuProbe.group('DartWorker'), 'DartWorker');
    expect(CpuProbe.group('pool-3-thread-2'), 'pool-thread');
    expect(CpuProbe.group('binder:1234_5'), 'binder');
    expect(CpuProbe.group('HeapTaskDaemon'), 'HeapTaskDaemon');
    expect(CpuProbe.group('1.ui'), '1.ui');
  });

  test('a window names the busiest threads, as a share of one core', () {
    final before = {
      1: const CpuSample('1.ui', 100),
      2: const CpuSample('1.raster', 50),
      3: const CpuSample('DartWorker', 0),
    };
    final after = {
      1: const CpuSample('1.ui', 600), // 500 ticks in 10 s → 50 %
      2: const CpuSample('1.raster', 250), // 20 %
      3: const CpuSample('DartWorker', 50), // 5 %
      4: const CpuSample('DartWorker', 50), // born in the window: 5 %
    };
    final r = CpuProbe.summarise(before, after, 10, 240)!;
    expect(r.text, 'app 80% · 24.0fps · 1.ui 50% | 1.raster 20% | DartWorker 10%');
    expect(r.quiet, isFalse);
  });

  test('an app at rest is quiet', () {
    final s = {1: const CpuSample('1.ui', 100)};
    final r = CpuProbe.summarise(s, {1: const CpuSample('1.ui', 102)}, 10, 0)!;
    expect(r.quiet, isTrue);
  });
}
