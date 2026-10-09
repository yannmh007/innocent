// The ADB screen's checklist: what Settings reports, which step is next, and
// which phones get a brand tip.

import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_setup_state.dart';

void main() {
  test('the steps come in the order they have to be done', () {
    const none = AdbSetupState(sdk: 34);
    expect(none.next(paired: false, connected: false), AdbSetupStep.devOptions);

    const dev = AdbSetupState(devOptions: true, sdk: 34);
    expect(dev.next(paired: false, connected: false), AdbSetupStep.wifi);

    const wifi = AdbSetupState(devOptions: true, wifi: true, sdk: 34);
    expect(wifi.next(paired: false, connected: false), AdbSetupStep.wirelessDebugging);

    const on = AdbSetupState(devOptions: true, wifi: true, wirelessDebugging: true, sdk: 34);
    expect(on.next(paired: false, connected: false), AdbSetupStep.pair);
    expect(on.next(paired: true, connected: false), AdbSetupStep.connect);
    expect(on.next(paired: true, connected: true), isNull);
  });

  test('notifications are a step only while there is still a code to type', () {
    const muted = AdbSetupState(
        devOptions: true, wifi: true, wirelessDebugging: true, notifications: false, sdk: 34);
    expect(muted.next(paired: false, connected: false), AdbSetupStep.notifications);
    expect(muted.next(paired: true, connected: false), AdbSetupStep.connect);
  });

  test('read from the platform map, missing answers read safely', () {
    final s = AdbSetupState.fromMap(<Object?, Object?>{
      'devOptions': true,
      'wirelessDebugging': false,
      'wifi': true,
      'secureSettings': true,
      'manufacturer': 'Xiaomi',
      'sdk': 35,
    });
    expect(s.devOptions, isTrue);
    expect(s.wirelessDebugging, isFalse);
    expect(s.wifi, isTrue);
    expect(s.notifications, isTrue, reason: 'unknown is not "turned off"');
    expect(s.secureSettings, isTrue);
    expect(s.brand, AdbBrand.xiaomi);
    expect(s.sdk, 35);

    final empty = AdbSetupState.fromMap(null);
    expect(empty.devOptions, isFalse);
    expect(empty.notifications, isTrue);
    expect(empty.supported, isTrue, reason: 'an unknown version is not refused');

    final odd = AdbSetupState.fromMap(<Object?, Object?>{'devOptions': 1, 'sdk': '34'});
    expect(odd.devOptions, isFalse);
    expect(odd.sdk, 0);
  });

  test('brand tips go to the phones they are about', () {
    AdbBrand of(String m) => AdbSetupState(manufacturer: m).brand;
    expect(of('xiaomi'), AdbBrand.xiaomi);
    expect(of('redmi'), AdbBrand.xiaomi);
    expect(of('poco'), AdbBrand.xiaomi);
    expect(of('oppo'), AdbBrand.oppo);
    expect(of('realme'), AdbBrand.oppo);
    expect(of('oneplus'), AdbBrand.oppo);
    expect(of('tecno mobile limited'), AdbBrand.transsion);
    expect(of('infinix'), AdbBrand.transsion);
    expect(of('itel'), AdbBrand.transsion);
    expect(of('samsung'), AdbBrand.samsung);
    expect(of('google'), AdbBrand.other);
  });

  test('wireless debugging needs Android 11', () {
    expect(const AdbSetupState(sdk: 29).supported, isFalse);
    expect(const AdbSetupState(sdk: 30).supported, isTrue);
  });
}
