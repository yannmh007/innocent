// The device lab's seek plan: "AFTER:TO" in seconds, several separated by
// commas, malformed entries skipped.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/lab_stream.dart';

void main() {
  test('one seek, several seeks, and junk skipped', () {
    expect(LabStream.parseSeekPlan('45:4866'),
        [(const Duration(seconds: 45), const Duration(seconds: 4866))]);
    expect(LabStream.parseSeekPlan('45:4866,65:2433,85:7299'), [
      (const Duration(seconds: 45), const Duration(seconds: 4866)),
      (const Duration(seconds: 65), const Duration(seconds: 2433)),
      (const Duration(seconds: 85), const Duration(seconds: 7299)),
    ]);
    expect(LabStream.parseSeekPlan('45:4866,x:1,7,  ,9:'), [
      (const Duration(seconds: 45), const Duration(seconds: 4866)),
    ]);
    expect(LabStream.parseSeekPlan(''), isEmpty);
  });

  test('a jump landed: near where it was asked, never back at 00:00', () {
    const want = Duration(seconds: 600);
    expect(LabStream.landed(want, const Duration(seconds: 598)), isTrue,
        reason: 'the keyframe before it');
    expect(LabStream.landed(want, const Duration(seconds: 620)), isTrue,
        reason: 'the film played on meanwhile');
    expect(LabStream.landed(want, const Duration(seconds: 4)), isFalse,
        reason: 'back at the start: the 1.64.68 bug');
    expect(LabStream.landed(want, const Duration(seconds: 300)), isFalse,
        reason: 'stayed where it was');
    expect(LabStream.landed(want, const Duration(seconds: 700)), isFalse);
  });
}
