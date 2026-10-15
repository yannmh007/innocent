import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/adb/adb_service.dart';
import 'package:innocent/features/android_data/domain/file_kind.dart';
import 'package:innocent/features/android_data/presentation/android_data_screen.dart';
import 'package:innocent/features/local_browser/domain/video.dart';
import 'package:innocent/features/local_browser/presentation/folder_visibility.dart';
import 'package:innocent/features/local_browser/presentation/folder_visibility_screen.dart';
import 'package:innocent/features/local_browser/presentation/library_provider.dart';
import 'package:innocent/features/local_browser/presentation/local_screen.dart';
import 'package:innocent/features/shell/shell_screen.dart';

import 'fakes.dart';
import 'harness.dart';

/// Show / hide folders, and Hidden files opened without ADB.
const _tg = '$kAndroidDataRoot/org.telegram.messenger/files/Telegram';
const _tgCache = '$kAndroidDataRoot/org.telegram.messenger/cache';
const _fb = '$kAndroidDataRoot/com.facebook.katana/cache/video';

Video _v(String folder, String name, int size) => Video(
      id: 'adb:$folder/$name',
      uri: 'adb://$folder/$name',
      title: name,
      folderPath: folder,
      duration: Duration.zero,
      sizeBytes: size,
      width: 0,
      height: 0,
    );

List<Video> _adbVideos() => <Video>[
      _v('$_tg/Telegram Video', 'ဇာတ်ကား အပိုင်း ၁.mp4', 734003200),
      _v('$_tg/Telegram Video', 'Episode 12 1080p.mkv', 1288490188),
      _v(_tgCache, '-6012345_99.mp4', 5242880),
      _v(_tgCache, '-6012346_99.mp4', 4194304),
      _v(_fb, 'reel_2210.mp4', 9437184),
    ];

List<Override> _overrides() => <Override>[
      ...libraryOverrides(),
      adbVideosProvider.overrideWith((ref) async => _adbVideos()),
    ];

/// A Telegram cache folder and the phone's Download folder, hidden.
const Map<String, Object> _someHidden = <String, Object>{
  FolderVisibilityNotifier.hiddenKey: <String>[
    _tgCache,
    '/storage/emulated/0/Download',
  ],
};

enum _Adb { connected, off, never, slow }

var _adb = _Adb.connected;

void _fakeAdb() {
  AdbService.instance.pairingNeeded.value = false;
  // Unknown until the screen asks, as on a fresh start of the app.
  AdbService.instance.live.value = _adb == _Adb.connected ? true : null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
          (call) async {
    switch (call.method) {
      case 'lastConnect':
        return _adb == _Adb.never ? '' : '127.0.0.1:37123';
      case 'adbSetupState':
        return <String, Object>{
          'devOptions': _adb != _Adb.never,
          'wirelessDebugging': _adb == _Adb.connected,
          'wifi': true,
          'notifications': true,
          'secureSettings': false,
          'manufacturer': 'samsung',
          'sdk': 35,
        };
      case 'shell':
        if (_adb == _Adb.slow) return Completer<String>().future;
        if (_adb != _Adb.connected) return 'ERROR: not connected';
        final cmd = (call.arguments as Map)['command'] as String;
        if (cmd.startsWith('echo ok')) return 'ok';
        return '';
      default:
        return null;
    }
  });
}

void main() {
  setUpAll(loadScreenFonts);
  setUp(reportOverflowsInsteadOfFailing);

  // The list: Android/data's folders with Hide / Show on each, the "only
  // while connected" switch, and a hidden phone folder below.
  screens('folder_visibility', () {
    _adb = _Adb.connected;
    _fakeAdb();
    return const FolderVisibilityScreen();
  }, overrides: _overrides, prefs: _someHidden, scrolls: 1);

  // Nothing hidden and no Android/data: what to do instead.
  screens('folder_visibility_empty', () {
    _adb = _Adb.connected;
    _fakeAdb();
    return const FolderVisibilityScreen();
  }, overrides: libraryOverrides);

  // The Video tab with two folders hidden: the line under the list says so.
  screens('folder_visibility_video_tab', () {
    _adb = _Adb.connected;
    _fakeAdb();
    return const ShellScreen(child: LocalScreen());
  }, overrides: _overrides, prefs: _someHidden, scrolls: 2);

  // Select an Android/data folder → Hide: it leaves the list, with Undo.
  screens('folder_visibility_hide', () {
    _adb = _Adb.connected;
    _fakeAdb();
    return const ShellScreen(child: LocalScreen());
  }, overrides: _overrides, act: (t) async {
    await t.longPress(find.text('Telegram Video').last);
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.visibility_off_outlined).first);
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  });

  // Hidden files opened with ADB off: why, where the phone stands, Connect.
  screens('hidden_files_no_adb', () {
    _adb = _Adb.off;
    _fakeAdb();
    return const AndroidDataScreen();
  }, settle: const Duration(seconds: 6), scrolls: 1);

  // Never set up on this phone: "Set up ADB".
  screens('hidden_files_never_set_up', () {
    _adb = _Adb.never;
    _fakeAdb();
    return const AndroidDataScreen();
  }, settle: const Duration(seconds: 6));

  // The few seconds of asking: said in words.
  screens('hidden_files_checking', () {
    _adb = _Adb.slow;
    _fakeAdb();
    return const AndroidDataScreen();
  }, settle: const Duration(milliseconds: 600));
}
