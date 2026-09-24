import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/video_player/stall_diagnosis.dart';

void main() {
  group('diagnoseStall', () {
    test('an empty buffer is the network, whatever else is true', () {
      // The decisive case. Cache at zero means the demuxer has nothing left
      // to hand the decoder, and no amount of decoding power changes that.
      final d = diagnoseStall(const StallReading(
        cacheSeconds: 0.0,
        haveBitsPerSecond: 2000000,
        needBitsPerSecond: 35000000,
      ));
      expect(d.cause, StallCause.network);
    });

    test('a starving buffer with frame drops is STILL the network', () {
      // THE ORDERING TEST, and the reason the order is written down. A
      // decoder handed a truncated packet stream drops frames as a
      // CONSEQUENCE of starvation. Testing drops first would file every slow
      // connection in Myanmar as a slow phone.
      final d = diagnoseStall(const StallReading(
        cacheSeconds: 0.4,
        droppedFrames: 40,
      ));
      expect(d.cause, StallCause.network);
    });

    test('a full buffer with dropped frames is the device', () {
      final d = diagnoseStall(const StallReading(
        cacheSeconds: 18.0,
        haveBitsPerSecond: 48000000,
        needBitsPerSecond: 35000000,
        droppedFrames: 12,
      ));
      expect(d.cause, StallCause.decode);
    });

    test('a full buffer with no drops is unknown, not decode', () {
      // "Likely" is not a diagnosis. A wrong confident answer is what sent
      // three weeks of work at the wrong layer.
      final d = diagnoseStall(const StallReading(
        cacheSeconds: 18.0,
        droppedFrames: 0,
      ));
      expect(d.cause, StallCause.unknown);
    });

    test('no readings at all is unknown', () {
      expect(diagnoseStall(const StallReading()).cause, StallCause.unknown);
    });

    test('throughput below the requirement is the network with no cache '
        'reading', () {
      final d = diagnoseStall(const StallReading(
        haveBitsPerSecond: 12000000,
        needBitsPerSecond: 35000000,
      ));
      expect(d.cause, StallCause.network);
    });

    test('a zero requirement never makes a link look sufficient', () {
      // `need` of 0 would pass `have < need` as false and quietly report
      // unknown as "fine". It must stay unknown, and for the right reason.
      final d = diagnoseStall(const StallReading(
        haveBitsPerSecond: 0,
        needBitsPerSecond: 0,
      ));
      expect(d.cause, StallCause.unknown);
    });

    test('meta carries kilobits, a rounded cache and the resolution', () {
      final m = diagnoseStall(const StallReading(
        cacheSeconds: 0.6,
        haveBitsPerSecond: 5_400_000,
        needBitsPerSecond: 35_200_000,
        droppedFrames: 3,
        hwdec: 'mediacodec',
        width: 3840,
        height: 2160,
      )).toMeta();
      expect(m['reason'], 'network');
      expect(m['cache_s'], 1);
      expect(m['have_kbps'], 5400);
      expect(m['need_kbps'], 35200);
      expect(m['dropped'], 3);
      expect(m['hwdec'], 'mediacodec');
      expect(m['res'], '3840x2160');
    });

    test('an absent reading is absent from meta, not zero', () {
      // A zero that means "not measured" is indistinguishable from a zero
      // that means "nothing was arriving", and the second is a diagnosis.
      final m = diagnoseStall(const StallReading(cacheSeconds: 0.0)).toMeta();
      expect(m.containsKey('have_kbps'), isFalse);
      expect(m.containsKey('need_kbps'), isFalse);
      expect(m.containsKey('res'), isFalse);
    });
  });
}
