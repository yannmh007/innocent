// Settings migration scaffolding.
//
// Real-world risk this addresses: when we change a `PlayerSetting`
// enum value name (or change the key under which an `IntSetting` /
// `StringSetting` is stored), every existing user's saved preference
// becomes orphaned — their stored choice still sits in
// `SharedPreferences` under the old key, but the new code reads the
// new key and finds nothing, so the user silently reverts to the
// default. That is the classic "I updated the app and lost my
// settings" complaint.
//
// This service introduces a single integer `_schemaVersion` key in
// SharedPreferences. On every cold start, `runMigrations()` reads
// that integer, then runs each `_v0_to_v1`, `_v1_to_v2`, ...
// migration in order until the stored version catches up with the
// app's current `currentSchemaVersion`. After a successful run, the
// new schema version is written back.
//
// This file ships at v1 with no concrete migrations — the
// scaffolding is the value. When a future phase renames or removes
// an enum value, add a method `_v1_to_v2(SharedPreferences sp)` that
// copies the old key over and bump `currentSchemaVersion`.
import 'package:shared_preferences/shared_preferences.dart';

class SettingsMigrationService {
  SettingsMigrationService._();

  static const String _schemaKey = '_schemaVersion';

  /// Bump this whenever a migration is added.
  static const int currentSchemaVersion = 1;

  /// Idempotent. Safe to call on every app start. Returns the version
  /// the user was on before the migration ran (useful for analytics
  /// or showing a "what changed" prompt to long-running users).
  static Future<int> runMigrations() async {
    final sp = await SharedPreferences.getInstance();
    final stored = sp.getInt(_schemaKey) ?? 0;
    if (stored >= currentSchemaVersion) return stored;
    var v = stored;
    // Migration ladder. Each step is no-throw, idempotent.
    if (v < 1) {
      await _v0_to_v1(sp);
      v = 1;
    }
    // Future: if (v < 2) { await _v1_to_v2(sp); v = 2; }
    await sp.setInt(_schemaKey, v);
    return stored;
  }

  /// First migration. v0 means "no migration has ever run" — i.e. a
  /// fresh install or an upgrade from a build that predated this
  /// service. There is no concrete data transformation needed yet;
  /// the act of writing `_schemaVersion = 1` is the migration.
  static Future<void> _v0_to_v1(SharedPreferences sp) async {
    // Intentionally empty. Reserve this slot so the migration ladder
    // has a deterministic baseline for future versions to build on.
  }
}
