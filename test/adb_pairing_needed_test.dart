import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';

/// When adbd refuses the app's key, every screen is told "pair again" — not
/// "check the port" — and the next command that works clears it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const refused = 'ERROR: PAIRING_REQUIRED — this phone no longer accepts '
      "Innocent's pairing. Pair once more: Wireless debugging → Pair device "
      'with pairing code.';
  late String answer;

  setUp(() {
    answer = refused;
    AdbService.instance.pairingNeeded.value = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
            (call) async {
      switch (call.method) {
        case 'shell':
        case 'autoConnectAndRun':
        case 'reconnectAndRun':
        case 'connectAndRun':
          return answer;
      }
      return null;
    });
  });

  test('the engine answer is recognised', () {
    expect(AdbService.needsPairing(refused), isTrue);
    expect(AdbService.needsPairing('ERROR: not connected'), isFalse);
    expect(AdbService.needsPairing('uid=2000(shell)'), isFalse);
  });

  test('a refused reconnect raises it; a working command clears it', () async {
    await AdbService.instance.reconnectAndRun('id');
    expect(AdbService.instance.pairingNeeded.value, isTrue);

    answer = 'OK — connected.\n\n\$ id\nuid=2000(shell)';
    await AdbService.instance.autoConnectAndRun('id');
    expect(AdbService.instance.pairingNeeded.value, isFalse);
  });

  test('the lost card probe and plain commands raise it too', () async {
    expect(await AdbService.instance.isConnected(timeoutMs: 3000), isFalse);
    expect(AdbService.instance.pairingNeeded.value, isTrue);

    answer = 'ok\n';
    expect(await AdbService.instance.isConnected(timeoutMs: 3000), isTrue);
    expect(AdbService.instance.pairingNeeded.value, isFalse);

    answer = refused;
    await AdbService.instance.shell('ls');
    expect(AdbService.instance.pairingNeeded.value, isTrue);
  });

  test('an ordinary failure leaves it as it was', () async {
    AdbService.instance.pairingNeeded.value = true;
    answer = 'ERROR: not connected — open the ADB screen and connect first.';
    await AdbService.instance.shell('ls');
    expect(AdbService.instance.pairingNeeded.value, isTrue,
        reason: 'a drop says nothing about the key either way');
  });
}
