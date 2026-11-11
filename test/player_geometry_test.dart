// The player's pure rules: the bottom row's width budget and the rotate
// button's round (lib/features/player/presentation/player_screen.dart).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/player/domain/speed_format.dart';
import 'package:innocent/features/player/presentation/player_screen.dart';

void main() {
  group('transportLayout', () {
    test('a wide row keeps the designed gaps, Play centred', () {
      final f = transportLayout(width: 393, transportButtons: 3, spacing: 8);
      expect(f, (spacing: 8.0, sideGap: 9.0, centred: true));
    });

    test('360 dp: the gaps close before the buttons overlap', () {
      // 360 less the row's 4 + 14 dp of padding.
      final f = transportLayout(width: 342, transportButtons: 3, spacing: 8);
      expect(f.centred, isTrue);
      expect(f.sideGap, 0);
      // Centred transport + both side groups fit the width exactly or less.
      expect(3 * 48 + 2 * f.spacing + 2 * (2 * 48 + f.sideGap),
          lessThanOrEqualTo(342));
    });

    test('320 dp: side by side, never overlapping', () {
      final f = transportLayout(width: 302, transportButtons: 3, spacing: 8);
      expect(f, (spacing: 0.0, sideGap: 0.0, centred: false));
    });

    test('landscape keeps its wide spacing', () {
      final f = transportLayout(width: 762, transportButtons: 3, spacing: 56);
      expect(f, (spacing: 56.0, sideGap: 9.0, centred: true));
    });
  });

  group('nextRotationMode', () {
    test('from portrait: landscape, portrait, then follow the phone', () {
      var r = nextRotationMode(0, Orientation.portrait, null);
      expect(r.mode, 2);
      r = nextRotationMode(r.mode, Orientation.landscape, r.start);
      expect(r.mode, 1);
      r = nextRotationMode(r.mode, Orientation.portrait, r.start);
      expect(r.mode, 0);
    });

    test('from landscape: portrait, landscape, then follow the phone', () {
      var r = nextRotationMode(0, Orientation.landscape, null);
      expect(r.mode, 1);
      r = nextRotationMode(r.mode, Orientation.portrait, r.start);
      expect(r.mode, 2);
      r = nextRotationMode(r.mode, Orientation.landscape, r.start);
      expect(r.mode, 0);
    });

    test('pinned by the settings: the other one, then follow the phone', () {
      var r = nextRotationMode(2, Orientation.landscape, null);
      expect(r.mode, 1);
      r = nextRotationMode(r.mode, Orientation.portrait, r.start);
      expect(r.mode, 0);
    });
  });

  group('speeds', () {
    test('are written as people write them', () {
      expect(formatSpeed(1.25), '1.25');
      expect(formatSpeed(0.75), '0.75');
      expect(formatSpeed(1.5), '1.5');
      expect(formatSpeed(2.0), '2');
      expect(formatSpeed(1.0), '1');
      expect(formatSpeed(0.25), '0.25');
    });

    test('the 1X shortcut goes up from wherever it is', () {
      const cycle = [0.5, 1.0, 1.25, 1.5, 2.0];
      expect(nextSpeedInCycle(1.0, cycle), 1.25);
      expect(nextSpeedInCycle(2.0, cycle), 0.5);
      // Off the cycle (the speed slider's 1.75): up, not back to 0.5.
      expect(nextSpeedInCycle(1.75, cycle), 2.0);
      expect(nextSpeedInCycle(3.0, cycle), 0.5);
    });
  });
}
