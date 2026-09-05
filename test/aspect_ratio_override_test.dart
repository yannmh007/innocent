// Unit tests for AspectRatioOverride enum — verifies the 12-ratio
// list, the numeric values used for libmpv's video-aspect-override
// property, and the safety of fromString() when given unknown input.

import 'package:flutter_test/flutter_test.dart';

import 'package:innocent/features/player/presentation/aspect_ratio_mode.dart';

void main() {
  group('AspectRatioOverride', () {
    test('has the expected 12 entries', () {
      expect(AspectRatioOverride.values.length, 12);
    });

    test('defaultAuto has null value (libmpv intrinsic)', () {
      // null means "let libmpv use the file's embedded SAR/DAR".
      expect(AspectRatioOverride.defaultAuto.value, isNull);
    });

    test('numeric ratios match their label arithmetic', () {
      // Each preset should compute to the ratio its label implies.
      expect(AspectRatioOverride.r1x1.value, 1.0);
      expect(AspectRatioOverride.r4x3.value, closeTo(4.0 / 3.0, 0.0001));
      expect(AspectRatioOverride.r16x9.value, closeTo(16.0 / 9.0, 0.0001));
      expect(AspectRatioOverride.r16x10.value,
          closeTo(16.0 / 10.0, 0.0001));
      expect(AspectRatioOverride.r21x9.value,
          closeTo(21.0 / 9.0, 0.0001));
      expect(AspectRatioOverride.r64x27.value,
          closeTo(64.0 / 27.0, 0.0001));
      expect(AspectRatioOverride.r221.value, 2.21);
      expect(AspectRatioOverride.r235.value, 2.35);
      expect(AspectRatioOverride.r239.value, 2.39);
      expect(AspectRatioOverride.r5x4.value, closeTo(5.0 / 4.0, 0.0001));
    });

    test('custom has null value', () {
      // "Custom" is a UI affordance for entering an arbitrary ratio
      // later. Until then, behave like defaultAuto.
      expect(AspectRatioOverride.custom.value, isNull);
    });

    test('fromString round-trips every enum entry', () {
      for (final v in AspectRatioOverride.values) {
        expect(AspectRatioOverride.fromString(v.name), v,
            reason: 'fromString failed to round-trip ${v.name}');
      }
    });

    test('fromString returns defaultAuto for null / empty / unknown',
        () {
      expect(AspectRatioOverride.fromString(null),
          AspectRatioOverride.defaultAuto);
      expect(AspectRatioOverride.fromString(''),
          AspectRatioOverride.defaultAuto);
      expect(AspectRatioOverride.fromString('garbage'),
          AspectRatioOverride.defaultAuto);
      // Case sensitivity: enum names are lowerCamelCase, so 'R16X9'
      // is unknown and should also fall back.
      expect(AspectRatioOverride.fromString('R16X9'),
          AspectRatioOverride.defaultAuto);
    });

    test('all labels are non-empty', () {
      for (final v in AspectRatioOverride.values) {
        expect(v.label.isNotEmpty, true,
            reason: '${v.name} has an empty label');
      }
    });
  });
}
