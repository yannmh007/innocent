// Why ExoPlayer refused, in the trail (14 Nov 2026).
//
// After the double open of 14 Nov the next film's open answered false within
// a tenth of a second and fell back to libmpv, and the trail could not say
// why: ExoStreamEngine answers false when it holds no engine by that id, and
// a Kotlin exception came back as the same false. Now each refusal says
// which, once per method and reason, with any address left out.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/playback_log.dart';
import 'package:innocent/core/services/video_player/exo_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('innocent/exo');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(PlaybackLog.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('no engine by that id: said so', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    final e = ExoEngine.forTest();
    expect(
        await e.open('http://127.0.0.1:41234/hls/t0k3n/master.m3u8'), isFalse);
    expect(PlaybackLog.text, contains('exo open refused: no engine 0'));
  });

  test('a Kotlin exception: its class and message, no address, once', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
          code: 'exo',
          message: 'IllegalStateException: no surface for '
              'http://127.0.0.1:41234/hls/t0k3n/master.m3u8');
    });
    final e = ExoEngine.forTest();
    await e.open('http://127.0.0.1:41234/hls/t0k3n/master.m3u8');
    await e.open('http://127.0.0.1:41234/hls/t0k3n/master.m3u8');
    final lines = PlaybackLog.text
        .split('\n')
        .where((l) => l.contains('exo open refused'))
        .toList();
    expect(lines, hasLength(1), reason: 'once per method and reason');
    expect(
        lines.single,
        contains(
            'exo open refused: IllegalStateException: no surface for <address>'));
    expect(PlaybackLog.text, isNot(contains('t0k3n')));
  });

  test('an answer of true says nothing', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => true);
    final e = ExoEngine.forTest();
    expect(await e.play(), isTrue);
    expect(PlaybackLog.text, isNot(contains('refused')));
  });
}
