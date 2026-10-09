// CVE-2026-0073: which phones are warned that wireless debugging is unsafe
// to leave on. The rule is Android 14 to 16 with a security patch older than
// 2026-05-01 — and an unreadable patch on those versions is treated as old.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/wireless_adb_risk.dart';

void main() {
  test('Android 14 to 16 before the May 2026 patch are warned', () {
    for (final sdk in [34, 35, 36]) {
      expect(wirelessAdbPossiblyExposed(sdkInt: sdk, securityPatch: '2026-04-05'), isTrue,
          reason: 'API $sdk, April 2026');
      expect(wirelessAdbPossiblyExposed(sdkInt: sdk, securityPatch: '2025-11-01'), isTrue,
          reason: 'API $sdk, November 2025');
    }
  });

  test('the May 2026 patch and later are not warned', () {
    for (final sdk in [34, 35, 36]) {
      for (final p in ['2026-05-01', '2026-05-05', '2026-10-01', '2027-01-01']) {
        expect(wirelessAdbPossiblyExposed(sdkInt: sdk, securityPatch: p), isFalse,
            reason: 'API $sdk, $p');
      }
    }
  });

  test('versions outside 14 to 16 are not warned, whatever the patch', () {
    for (final sdk in [24, 29, 30, 31, 33, 37]) {
      expect(wirelessAdbPossiblyExposed(sdkInt: sdk, securityPatch: '2024-01-01'), isFalse,
          reason: 'API $sdk');
    }
  });

  test('an unreadable patch level on an affected version counts as exposed', () {
    for (final p in [null, '', '  ', 'unknown', '2026-5-1', '20260501']) {
      expect(wirelessAdbPossiblyExposed(sdkInt: 35, securityPatch: p), isTrue,
          reason: '"$p"');
    }
    // …but never on a version the flaw does not affect.
    expect(wirelessAdbPossiblyExposed(sdkInt: 33, securityPatch: null), isFalse);
  });
}
