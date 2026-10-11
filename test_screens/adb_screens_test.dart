import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';
import 'package:innocent/core/ui/adb_lost_card.dart';
import 'package:innocent/features/settings/presentation/adb_connect_screen.dart';

import 'harness.dart';

/// The ADB engine, answered from memory: a fresh phone, one that was paired
/// and has dropped, one that is connected, and one whose adbd refuses the
/// app's key (it has to be paired again).
enum _State { fresh, off, connected, refused }

const _refused = 'ERROR: PAIRING_REQUIRED \u2014 this phone no longer accepts '
    "Innocent's pairing. Pair once more: Wireless debugging \u2192 Pair device "
    'with pairing code.';

var _state = _State.fresh;

void _fakeAdb() {
  // A singleton: what one screen left behind must not leak into the next.
  AdbService.instance.pairingNeeded.value = _state == _State.refused;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
          (call) async {
    final connected = _state == _State.connected;
    switch (call.method) {
      case 'adbSetupState':
        return <String, Object>{
          'devOptions': _state != _State.fresh,
          'wirelessDebugging': connected || _state == _State.refused,
          'wifi': true,
          'notifications': true,
          'secureSettings': false,
          'manufacturer': 'realme',
          'sdk': 35,
        };
      case 'autoEnableStatus':
        return <String, Object>{'granted': false, 'on': false};
      case 'lastConnect':
        return _state == _State.fresh ? '' : '192.168.1.5:37011';
      case 'reconnectAndRun':
      case 'autoConnectAndRun':
        if (_state == _State.refused) return _refused;
        return connected
            ? 'uid=2000(shell) gid=2000(shell)'
            : 'ERROR: not connected';
      case 'shell':
        if (_state == _State.refused) return _refused;
        return connected ? 'ok' : 'ERROR: not connected';
      case 'scannedVideos':
      case 'scanAndroidDataVideos':
        return <String>[];
      default:
        return null;
    }
  });
}

void main() {
  setUpAll(loadScreenFonts);

  for (final st in _State.values) {
    screens('adb_${st.name}', () {
      _state = st;
      _fakeAdb();
      return const AdbConnectScreen();
    }, scrolls: 3, settle: const Duration(seconds: 3));
  }

  // The on/off guide, opened.
  screens('adb_guide', () {
    _state = _State.connected;
    _fakeAdb();
    return const AdbConnectScreen();
  }, act: (tester) async {
    final tile = find.byIcon(Icons.power_settings_new_rounded);
    await tester.scrollUntilVisible(tile, 300,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -250));
    await tester.pumpAndSettle();
  }, scrolls: 2, settle: const Duration(seconds: 3));

  screens('adb_lost_card', () {
    _state = _State.off;
    _fakeAdb();
    return Scaffold(
      appBar: AppBar(title: const Text('Android/data')),
      body: AdbLostCard(onBack: () {}),
    );
  });

  // The phone refused the key: the card says "pair again", not "reconnect".
  screens('adb_lost_card_refused', () {
    _state = _State.refused;
    _fakeAdb();
    return Scaffold(
      appBar: AppBar(title: const Text('Android/data')),
      body: AdbLostCard(onBack: () {}),
    );
  });
}
