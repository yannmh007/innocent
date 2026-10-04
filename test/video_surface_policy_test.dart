import 'package:flutter_test/flutter_test.dart';
import 'package:innocent/core/services/preferences/player_settings_service.dart';
import 'package:innocent/core/services/video_player/video_surface_policy.dart';
import 'package:innocent/features/updater/domain/app_release.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('VideoSurfacePolicy', () {
    test('efficient by default', () async {
      SharedPreferences.setMockInitialValues({});
      expect(PlayerSetting.decEfficientOutput.default_, isTrue);
      expect(await VideoSurfacePolicy.useEfficientSurface(), isTrue);
    });

    test('the user switch turns it off', () async {
      SharedPreferences.setMockInitialValues(
          {PlayerSetting.decEfficientOutput.key: false});
      expect(await VideoSurfacePolicy.useEfficientSurface(), isFalse);
    });

    test('the server flag turns it off for everyone, and back on', () async {
      SharedPreferences.setMockInitialValues({});
      await VideoSurfacePolicy.storeRemoteFlags({'legacy_surface'});
      expect(await VideoSurfacePolicy.useEfficientSurface(), isFalse);
      await VideoSurfacePolicy.storeRemoteFlags(<String>{});
      expect(await VideoSurfacePolicy.useEfficientSurface(), isTrue);
    });

    test('unrelated flags change nothing', () {
      expect(
        VideoSurfacePolicy.decide(
            userSwitch: true, remoteFlags: const ['something_else']),
        isTrue,
      );
    });
  });

  group('AppRelease.parsePlayerFlags', () {
    test('words, any separator, lower-cased', () {
      expect(AppRelease.parsePlayerFlags('Legacy_Surface,  other'),
          {'legacy_surface', 'other'});
    });
    test('missing, empty, wrong type → no flags', () {
      expect(AppRelease.parsePlayerFlags(null), isEmpty);
      expect(AppRelease.parsePlayerFlags(''), isEmpty);
      expect(AppRelease.parsePlayerFlags(42), isEmpty);
    });
    test('junk is dropped, not interpreted', () {
      // A word glued to punctuation is not that word.
      expect(AppRelease.parsePlayerFlags('legacy_surface;'), isEmpty);
      expect(
          AppRelease.parsePlayerFlags('https://evil/x legacy_surface'),
          {'legacy_surface'});
    });
    test('a row without the column still parses', () {
      final r = AppRelease.fromJson(
          {'version_name': '1.64.54', 'version_code': 367});
      expect(r, isNotNull);
      expect(r!.playerFlags, isEmpty);
    });
    test('a row with the column carries it', () {
      final r = AppRelease.fromJson({
        'version_name': '1.64.54',
        'version_code': 367,
        'player_flags': 'legacy_surface',
      });
      expect(r!.playerFlags, {'legacy_surface'});
    });
  });
}
