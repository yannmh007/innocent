// Unit tests for PlayerSettingsService — the boolean preferences layer
// that backs every toggle in the Settings screens. Verifies defaults,
// round-trip persistence, and the resetAll() wipe behaviour.
//
// These tests use the `shared_preferences` in-memory mock so they run
// instantly on CI without touching disk.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:innocent/core/services/preferences/player_settings_service.dart';

void main() {
  group('PlayerSettingsService', () {
    setUp(() {
      // Reset to a clean store before every test so prior writes don't
      // leak between cases.
      SharedPreferences.setMockInitialValues({});
    });

    test('load() returns every setting at its declared default', () async {
      final svc = PlayerSettingsService();
      final loaded = await svc.load();
      for (final s in PlayerSetting.values) {
        expect(
          loaded.get(s),
          s.default_,
          reason: 'PlayerSetting.${s.name} default should be ${s.default_}',
        );
      }
    });

    test('setValue + load round-trip preserves the written value',
        () async {
      final svc = PlayerSettingsService();
      // Pick a setting whose default is true and flip it to false, then
      // a setting whose default is false and flip it to true. This way
      // we exercise both write directions.
      final flipToFalse =
          PlayerSetting.values.firstWhere((s) => s.default_ == true);
      final flipToTrue =
          PlayerSetting.values.firstWhere((s) => s.default_ == false);
      await svc.setValue(flipToFalse, false);
      await svc.setValue(flipToTrue, true);

      final loaded = await svc.load();
      expect(loaded.get(flipToFalse), false);
      expect(loaded.get(flipToTrue), true);

      // Every OTHER setting must still be at its declared default.
      for (final s in PlayerSetting.values) {
        if (s == flipToFalse || s == flipToTrue) continue;
        expect(loaded.get(s), s.default_);
      }
    });

    test('resetAll() wipes every previously-written value', () async {
      final svc = PlayerSettingsService();
      // Flip a handful of settings.
      final flipped = PlayerSetting.values.take(5).toList();
      for (final s in flipped) {
        await svc.setValue(s, !s.default_);
      }
      // Sanity: confirm the flips landed.
      var loaded = await svc.load();
      for (final s in flipped) {
        expect(loaded.get(s), !s.default_);
      }
      // Reset and confirm every setting is back to default.
      await svc.resetAll();
      loaded = await svc.load();
      for (final s in PlayerSetting.values) {
        expect(loaded.get(s), s.default_);
      }
    });

    test('PlayerSetting.key is unique across the enum', () {
      // Catch accidental key collisions early — two settings sharing
      // the same SharedPreferences key would silently overwrite each
      // other.
      final keys = PlayerSetting.values.map((s) => s.key).toList();
      final unique = keys.toSet();
      expect(unique.length, keys.length,
          reason: 'Duplicate PlayerSetting.key would corrupt persistence');
    });
  });
}
