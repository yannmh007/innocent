// Unit tests for ExtraSettingsService — the string + int preferences
// layer used for non-boolean settings (audio device, subtitle scale,
// HW decoder mode, etc.). Verifies defaults, round-trip persistence,
// and resetAll().

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:innocent/core/services/preferences/extra_settings_service.dart';

void main() {
  group('ExtraSettingsService — String settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('load() returns declared defaults for every StringSetting',
        () async {
      final svc = ExtraSettingsService();
      final loaded = await svc.load();
      for (final s in StringSetting.values) {
        expect(loaded.getStr(s), s.default_,
            reason: 'StringSetting.${s.name} default mismatch');
      }
    });

    test('setStr + load round-trip preserves the value', () async {
      final svc = ExtraSettingsService();
      await svc.setStr(StringSetting.audioDevice, 'speaker');
      await svc.setStr(StringSetting.userLocale, 'my');
      final loaded = await svc.load();
      expect(loaded.getStr(StringSetting.audioDevice), 'speaker');
      expect(loaded.getStr(StringSetting.userLocale), 'my');
    });

    test('StringSetting.key is unique across the enum', () {
      final keys = StringSetting.values.map((s) => s.key).toList();
      expect(keys.toSet().length, keys.length,
          reason: 'Duplicate StringSetting.key would corrupt persistence');
    });
  });

  group('ExtraSettingsService — Int settings', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('load() returns declared defaults for every IntSetting',
        () async {
      final svc = ExtraSettingsService();
      final loaded = await svc.load();
      for (final s in IntSetting.values) {
        expect(loaded.getInt(s), s.default_,
            reason: 'IntSetting.${s.name} default mismatch');
      }
    });

    test('setInt + load round-trip preserves the value', () async {
      final svc = ExtraSettingsService();
      await svc.setInt(IntSetting.subtitleScale, 150);
      await svc.setInt(IntSetting.audioDelay, -300);
      final loaded = await svc.load();
      expect(loaded.getInt(IntSetting.subtitleScale), 150);
      expect(loaded.getInt(IntSetting.audioDelay), -300);
    });

    test('IntSetting min/max bounds are sane', () {
      // Static invariant check — guards against typos like swapping
      // min/max in a new declaration.
      for (final s in IntSetting.values) {
        expect(s.min <= s.max, true,
            reason: 'IntSetting.${s.name} has min > max');
        expect(s.default_ >= s.min, true,
            reason: 'IntSetting.${s.name} default below min');
        expect(s.default_ <= s.max, true,
            reason: 'IntSetting.${s.name} default above max');
      }
    });

    test('IntSetting.key is unique across the enum', () {
      final keys = IntSetting.values.map((s) => s.key).toList();
      expect(keys.toSet().length, keys.length,
          reason: 'Duplicate IntSetting.key would corrupt persistence');
    });
  });

  group('ExtraSettingsService — resetAll', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('resetAll wipes both string and int settings', () async {
      final svc = ExtraSettingsService();
      // Write some non-default values.
      await svc.setStr(StringSetting.audioDevice, 'speaker');
      await svc.setInt(IntSetting.subtitleScale, 150);
      // Reset and verify defaults are back.
      await svc.resetAll();
      final loaded = await svc.load();
      expect(loaded.getStr(StringSetting.audioDevice),
          StringSetting.audioDevice.default_);
      expect(loaded.getInt(IntSetting.subtitleScale),
          IntSetting.subtitleScale.default_);
    });
  });
}
