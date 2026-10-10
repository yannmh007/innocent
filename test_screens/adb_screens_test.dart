import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/ui/adb_lost_card.dart';
import 'package:innocent/features/settings/presentation/adb_connect_screen.dart';

import 'harness.dart';

/// The ADB engine, answered from memory: a fresh phone, one that was paired
/// and has dropped, and one that is connected.
enum _State { fresh, off, connected }

var _state = _State.fresh;

void _fakeAdb() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
          (call) async {
    final connected = _state == _State.connected;
    switch (call.method) {
      case 'adbSetupState':
        return <String, Object>{
          'devOptions': _state != _State.fresh,
          'wirelessDebugging': connected,
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
        return connected
            ? 'uid=2000(shell) gid=2000(shell)'
            : 'ERROR: not connected';
      case 'shell':
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
}
