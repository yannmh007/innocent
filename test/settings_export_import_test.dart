// Unit test for the Export/Import preferences JSON schema. Verifies
// that every setting in the three enums (PlayerSetting, StringSetting,
// IntSetting) round-trips through JSON encode/decode without loss.
//
// We don't touch the filesystem here — Export/Import writes/reads a
// file in the docs directory, which would need path_provider mocking.
// Instead we build the same nested map structure the export code
// produces and verify each leaf survives a JSON round-trip with the
// expected runtime type.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:innocent/core/services/preferences/extra_settings_service.dart';
import 'package:innocent/core/services/preferences/player_settings_service.dart';

void main() {
  group('Settings export / import JSON schema', () {
    test('every PlayerSetting bool survives JSON round-trip', () {
      // Build the same player_settings map the export code emits, but
      // alternate true/false so we know we're not just reading
      // defaults back. (Flipping by index gives us both directions.)
      final original = <String, bool>{
        for (var i = 0; i < PlayerSetting.values.length; i++)
          PlayerSetting.values[i].name: i.isEven,
      };
      final encoded = jsonEncode({'player_settings': original});
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final roundTripped =
          (decoded['player_settings'] as Map).cast<String, bool>();
      expect(roundTripped, equals(original));
    });

    test('every StringSetting survives JSON round-trip', () {
      final original = <String, String>{
        for (final s in StringSetting.values)
          // Use a recognisable sentinel that includes the enum name
          // so a mistaken value would be obvious.
          s.name: 'value:${s.name}',
      };
      final encoded = jsonEncode({'string_settings': original});
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final roundTripped =
          (decoded['string_settings'] as Map).cast<String, String>();
      expect(roundTripped, equals(original));
    });

    test('every IntSetting survives JSON round-trip', () {
      final original = <String, int>{
        for (var i = 0; i < IntSetting.values.length; i++)
          IntSetting.values[i].name: i - 7, // mix positives and negatives
      };
      final encoded = jsonEncode({'int_settings': original});
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      final roundTripped =
          (decoded['int_settings'] as Map).cast<String, int>();
      expect(roundTripped, equals(original));
    });

    test('full export payload shape decodes cleanly', () {
      // Mirror the structure _exportSettings() builds.
      final payload = {
        'schema_version': 1,
        'app_build': 62,
        'exported_at': '2026-06-07T00:00:00.000Z',
        'player_settings': <String, bool>{
          for (final s in PlayerSetting.values) s.name: s.default_,
        },
        'string_settings': <String, String>{
          for (final s in StringSetting.values) s.name: s.default_,
        },
        'int_settings': <String, int>{
          for (final s in IntSetting.values) s.name: s.default_,
        },
      };
      final json = jsonEncode(payload);
      final decoded = jsonDecode(json) as Map<String, dynamic>;

      // Top-level shape.
      expect(decoded['schema_version'], 1);
      expect(decoded['app_build'], isA<int>());
      expect(decoded['exported_at'], isA<String>());
      expect(decoded['player_settings'], isA<Map>());
      expect(decoded['string_settings'], isA<Map>());
      expect(decoded['int_settings'], isA<Map>());

      // Per-section size.
      expect((decoded['player_settings'] as Map).length,
          PlayerSetting.values.length);
      expect((decoded['string_settings'] as Map).length,
          StringSetting.values.length);
      expect((decoded['int_settings'] as Map).length,
          IntSetting.values.length);
    });

    test('import is tolerant of unknown keys (forward compat)', () {
      // A future build may add settings; older clients reading that
      // file should ignore the unknown ones instead of crashing.
      final futurePayload = {
        'schema_version': 99,
        'player_settings': {
          'audioEffectsEnabled': true,
          'unknownFutureSetting_xyz': true, // doesn't exist today
        },
        'string_settings': {
          'audioDevice': 'speaker',
          'someFutureString': 'foo',
        },
        'int_settings': {
          'subtitleScale': 150,
          'someFutureInt': 999,
        },
      };
      // The import code uses `for (final s in PlayerSetting.values)`
      // and only reads keys that match known enum names. Simulate
      // that same lookup here.
      final pmap =
          (futurePayload['player_settings'] as Map).cast<String, dynamic>();
      var applied = 0;
      for (final s in PlayerSetting.values) {
        final v = pmap[s.name];
        if (v is bool) applied++;
      }
      // Should have applied only audioEffectsEnabled (the one known
      // key in the payload), and ignored unknownFutureSetting_xyz.
      expect(applied, 1);
    });
  });
}
