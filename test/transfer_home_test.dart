import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/file_transfer/file_transfer_service.dart';

void main() {
  test('Turbo is on by default (owner, 2026-10-06)', () {
    expect(const TransferState().turboRequested, isTrue);
    expect(const TransferState().forComputer, isFalse);
  });

  group('the Wi-Fi QR a camera can join from', () {
    test('plain network', () {
      expect(TransferNotifier.wifiQr('DIRECT-ab-Innocent', 'k3y5ecret'),
          'WIFI:T:WPA;S:DIRECT-ab-Innocent;P:k3y5ecret;;');
    });

    test('reserved characters are escaped', () {
      expect(TransferNotifier.wifiQr(r'My;Net,"x"', r'p:a\ss'),
          r'WIFI:T:WPA;S:My\;Net\,\"x\";P:p\:a\\ss;;');
    });

    test('an open network says nopass and carries no P field', () {
      expect(TransferNotifier.wifiQr('Open', ''), 'WIFI:T:nopass;S:Open;;');
    });
  });
}
