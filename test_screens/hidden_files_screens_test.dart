import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/features/android_data/domain/file_kind.dart';
import 'package:innocent/features/android_data/presentation/android_data_screen.dart';
import 'package:innocent/features/me/presentation/me_screen.dart';

import 'harness.dart';

const _root = kAndroidDataRoot;
const _tg = '$_root/org.telegram.messenger/files/Telegram';

/// Android/data as the ADB engine would list it.
final Map<String, List<String>> _tree = <String, List<String>>{
  _root: <String>[
    'directory|4096|$_root/com.facebook.orca',
    'directory|4096|$_root/org.telegram.messenger',
    'directory|4096|$_root/com.zing.zalo',
    'directory|4096|$_root/com.google.android.youtube',
    'directory|4096|$_root/com.viber.voip',
  ],
  _tg: <String>[
    'directory|4096|$_tg/Telegram Video',
    'directory|4096|$_tg/Telegram Images',
    'directory|4096|$_tg/Telegram Documents',
    'directory|4096|$_tg/Telegram Audio',
  ],
  '$_tg/Telegram Video': <String>[
    'directory|4096|$_tg/Telegram Video/Season 2',
    'regular file|734003200|$_tg/Telegram Video/ဇာတ်ကား အပိုင်း ၁.mp4',
    'regular file|1288490188|$_tg/Telegram Video/Episode 12 1080p.mkv',
    'regular file|52428800|$_tg/Telegram Video/trailer.mp4',
    'regular file|2097152|$_tg/Telegram Video/poster.jpg',
    'regular file|880640|$_tg/Telegram Video/subtitles.srt',
    'regular file|4194304|$_tg/Telegram Video/soundtrack.mp3',
    'regular file|409600000|$_tg/Telegram Video/film.mp4.temp',
  ],
};

void _fakeAdb() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('mx_clone/adb'),
          (call) async {
    if (call.method != 'shell') return null;
    final cmd = (call.arguments as Map)['command'] as String;
    if (cmd.startsWith('echo ok')) return 'ok';
    final m = RegExp(r"find '([^']+)'").firstMatch(cmd);
    if (m == null) return '';
    return (_tree[m.group(1)!] ?? const <String>[]).join('\n');
  });
}

void main() {
  setUpAll(loadScreenFonts);

  screens('hidden_files_apps', () {
    _fakeAdb();
    return const AndroidDataScreen();
  }, settle: const Duration(seconds: 3));

  screens('hidden_files_folder', () {
    _fakeAdb();
    return const AndroidDataScreen(startAt: '$_tg/Telegram Video');
  }, settle: const Duration(seconds: 3));

  screens('me_hidden_files', () => const MeScreen());
}
