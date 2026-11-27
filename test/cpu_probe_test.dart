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

  test('the 10 s line carries the frames\' timing when there is one', () {
    final s = {1: const CpuSample('1.ui', 100)};
    final r = CpuProbe.summarise(s, {1: const CpuSample('1.ui', 200)}, 10, 100,
        timing: 'b90 2.0 r90 9.0 ms')!;
    expect(r.text, 'app 10% · 10.0fps · b90 2.0 r90 9.0 ms · 1.ui 10%');
  });

  group('FrameWindow', () {
    test('percentiles by nearest rank', () {
      final xs = [for (var i = 1; i <= 100; i++) i];
      expect(FrameWindow.percentile(xs, 50), 50);
      expect(FrameWindow.percentile(xs, 90), 90);
      expect(FrameWindow.percentile(xs, 99), 99);
      expect(FrameWindow.percentile([7], 99), 7);
      expect(FrameWindow.percentile([], 50), 0);
    });

    test('a frame is late when its build or its raster overran', () {
      final w = FrameWindow();
      // 120 frames: 100 quick, 15 with a slow raster, 5 with a slow build.
      for (var i = 0; i < 100; i++) {
        w.addMicros(2000, 6000);
      }
      for (var i = 0; i < 15; i++) {
        w.addMicros(2000, 21000);
      }
      for (var i = 0; i < 5; i++) {
        w.addMicros(30000, 6000);
      }
      expect(w.count, 120);
      expect(w.over(16667), 20);
      expect(w.over(8333), 20);
      expect(w.brief(), 'b90 2.0 r90 21 ms · late 20');
      final d = w.describe(2, 120);
      expect(d, startsWith('n=120 fps=60.0 hz=120 '));
      expect(d, contains('build=2.0/2.0/30/30 raster=6.0/21/21/21 ms'));
      expect(d, contains('over16=20 (16.7%) over8.3=20 (16.7%)'));
      w.clear();
      expect(w.brief(), isNull);
      expect(w.describe(1, 60), 'n=0 fps=0.0');
    });

    test('at 60 Hz there is no second budget', () {
      final w = FrameWindow()..addMicros(1000, 1000);
      expect(w.describe(1, 60), isNot(contains('over8')));
    });
  });
}
