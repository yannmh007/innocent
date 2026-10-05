import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/cache/scan_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final t0 = DateTime(2026, 10, 4, 12);
  String saved(DateTime at, String stamp) =>
      '${at.millisecondsSinceEpoch}#$stamp';

  group('ScanGate.trusts', () {
    test('same stamp, scanned an hour ago → trust', () {
      expect(
        ScanGate.trusts(
          saved: saved(t0, 'v1|external_primary:v1:812|p:10'),
          current: 'v1|external_primary:v1:812|p:10',
          clock: t0.add(const Duration(hours: 1)),
        ),
        isTrue,
      );
    });
    test('generation moved → scan', () {
      expect(
        ScanGate.trusts(
          saved: saved(t0, 'v1|external_primary:v1:812|p:10'),
          current: 'v1|external_primary:v1:813|p:10',
          clock: t0,
        ),
        isFalse,
      );
    });
    test('access revoked → scan', () {
      expect(
        ScanGate.trusts(
          saved: saved(t0, 'v1|external_primary:v1:812|p:10'),
          current: 'v1|external_primary:v1:812|p:00',
          clock: t0,
        ),
        isFalse,
      );
    });
    test('older than a day → scan anyway', () {
      expect(
        ScanGate.trusts(
          saved: saved(t0, 's'),
          current: 's',
          clock: t0.add(const Duration(hours: 25)),
        ),
        isFalse,
      );
    });
    test('clock went backwards, no stamp, garbage → scan', () {
      expect(
          ScanGate.trusts(
              saved: saved(t0, 's'),
              current: 's',
              clock: t0.subtract(const Duration(minutes: 5))),
          isFalse);
      expect(ScanGate.trusts(saved: saved(t0, 's'), current: null, clock: t0),
          isFalse);
      expect(ScanGate.trusts(saved: 'junk', current: 'junk', clock: t0),
          isFalse);
    });
  });

  group('ScanGate.trustCache', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      ScanGate.resetForTest();
    });

    test('trusts a matching stamp once per process, then always scans',
        () async {
      ScanGate.readStamp = () async => 'g1';
      await ScanGate.record('all', 'g1');
      ScanGate.resetForTest();
      expect(await ScanGate.trustCache('all'), isTrue);
      // Pull to refresh, a delete, a move: every later load scans.
      expect(await ScanGate.trustCache('all'), isFalse);
    });

    test('a change since the last scan is seen', () async {
      ScanGate.readStamp = () async => 'g1';
      await ScanGate.record('folders', 'g1');
      ScanGate.resetForTest();
      ScanGate.readStamp = () async => 'g2';
      expect(await ScanGate.trustCache('folders'), isFalse);
    });

    test('no platform stamp (Android 10) → never trusted', () async {
      ScanGate.readStamp = () async => null;
      await ScanGate.record('all', null);
      ScanGate.resetForTest();
      expect(await ScanGate.trustCache('all'), isFalse);
    });

    test('clear() forgets stamps', () async {
      ScanGate.readStamp = () async => 'g1';
      await ScanGate.record('folder:/a', 'g1');
      await ScanGate.clear();
      ScanGate.resetForTest();
      expect(await ScanGate.trustCache('folder:/a'), isFalse);
    });
  });
}
