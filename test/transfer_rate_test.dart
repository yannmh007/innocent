import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/video_hub/domain/transfer_rate.dart';

void main() {
  final t0 = DateTime.utc(2026, 1, 1, 12);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('TransferRate', () {
    test('says nothing until there is enough to say honestly', () {
      final r = TransferRate();
      expect(r.bytesPerSecond, isNull);
      r.observe(0, at(0));
      expect(r.bytesPerSecond, isNull);
      // One second of samples is below the minimum span: two readings 80 ms
      // apart can claim 40 MB/s on a link doing two, and a number that swings
      // by twenty times is worse than no number.
      r.observe(1000000, at(1));
      expect(r.bytesPerSecond, isNull);
    });

    test('measures across the window', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(2000000, at(2));
      expect(r.bytesPerSecond, 1000000);
      r.observe(4000000, at(4));
      expect(r.bytesPerSecond, 1000000);
    });

    // THE POINT OF THE WINDOW. A film that stalled for ten minutes and is now
    // running at 3 MB/s has a lifetime average of almost nothing, so a
    // whole-download average would promise two hours when the truth is four
    // minutes — and the viewer decides whether to keep waiting on that number.
    test('a stall that has ended stops dragging the estimate down', () {
      final r = TransferRate(window: const Duration(seconds: 10));
      r.observe(0, at(0));
      // Ten minutes of nothing.
      r.observe(0, at(600));
      // Then 3 MB/s for six seconds.
      r.observe(3000000, at(601));
      r.observe(6000000, at(602));
      r.observe(9000000, at(603));
      r.observe(12000000, at(604));
      r.observe(15000000, at(605));
      r.observe(18000000, at(606));
      final speed = r.bytesPerSecond!;
      expect(speed, greaterThan(2500000));
      expect(speed, lessThan(3500000));
    });

    test('a stall in progress reports zero, not the speed before it', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(1000000, at(1));
      r.observe(1000000, at(30));
      expect(r.bytesPerSecond, 0);
    });

    test('a resume that restarts the byte count is not a negative speed', () {
      final r = TransferRate();
      r.observe(5000000, at(0));
      r.observe(9000000, at(4));
      expect(r.bytesPerSecond, 1000000);
      // The download restarted from zero — everything before describes a
      // different attempt.
      r.observe(0, at(5));
      expect(r.bytesPerSecond, isNull);
      r.observe(2000000, at(7));
      expect(r.bytesPerSecond, 1000000);
    });

    test('time remaining is the question a progress bar cannot answer', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(2000000, at(2)); // 1 MB/s
      expect(
        r.remaining(2000000, 12000000),
        const Duration(seconds: 10),
      );
    });

    test('a stalled transfer has no estimate rather than a huge one', () {
      final r = TransferRate();
      r.observe(1000, at(0));
      r.observe(1000, at(10));
      expect(r.bytesPerSecond, 0);
      expect(r.remaining(1000, 100000000), isNull);
    });

    test('an unknown total has no estimate', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(2000000, at(2));
      expect(r.remaining(2000000, null), isNull);
      expect(r.remaining(2000000, 0), isNull);
    });

    test('a finished transfer has nothing left', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(2000000, at(2));
      expect(r.remaining(2000000, 2000000), Duration.zero);
    });

    test('reset forgets the previous download', () {
      final r = TransferRate();
      r.observe(0, at(0));
      r.observe(2000000, at(2));
      expect(r.bytesPerSecond, isNotNull);
      r.reset();
      expect(r.bytesPerSecond, isNull);
    });
  });
}
