// A resume opens on the rung the app chose and warmed (19 Nov 2026).
//
// The ladder's first open passed Auto its start rung only when the film
// opened at 0: a resume from Continue watching (579 s on the owner's phone)
// was taken for a reconnect, Auto chose from the meter — 360p with nothing
// measured, 720p on the owner's line — and the first segment waited for that
// rung's index behind the start rung's (device lab S1 44534768953). The
// arm's FIRST open is the film's first open, wherever it starts; every
// later open of it (a reconnect, a renewal) is Auto's from the start.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/diagnostics/playback_log.dart';
import 'package:innocent/core/services/video_player/media_kit_player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('innocent/exo');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const uri = 'http://127.0.0.1:41234/h/t0k3n/ladder-1/master.m3u8';
  final opens = <Map<Object?, Object?>>[];

  setUp(() {
    PlaybackLog.clear();
    opens.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'create':
          return <String, Object?>{'id': 1, 'texture': 7};
        case 'open':
          opens.add(call.arguments as Map<Object?, Object?>);
          return true;
      }
      return true;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    MediaKitPlayerService.startOnResume = true;
  });

  test('a resume\'s first open starts on the warmed rung; a reopen is Auto\'s',
      () async {
    final s = MediaKitPlayerService();
    MediaKitPlayerService.armLadder(uri,
        start: 480, rungs: const {480: 912, 360: 578});
    await s.open(uri, startAt: const Duration(seconds: 579));
    expect(opens, hasLength(1));
    expect(opens.single['start'], 480);
    expect(opens.single['startMs'], 579000);
    // A reconnect of the same film, later in it.
    await s.open(uri, startAt: const Duration(seconds: 640));
    expect(opens, hasLength(2));
    expect(opens.last['start'], isNull);
  });

  test(
      'with startOnResume off (the lab\'s base), a resume is Auto\'s, as 1.64.85 made it',
      () async {
    MediaKitPlayerService.startOnResume = false;
    final s = MediaKitPlayerService();
    MediaKitPlayerService.armLadder(uri,
        start: 480, rungs: const {480: 912, 360: 578});
    await s.open(uri, startAt: const Duration(seconds: 579));
    expect(opens.single['start'], isNull);
  });

  test('from 0 the start rung is passed either way', () async {
    final s = MediaKitPlayerService();
    MediaKitPlayerService.armLadder(uri,
        start: 360, rungs: const {480: 912, 360: 578});
    await s.open(uri);
    expect(opens.single['start'], 360);
  });
}
